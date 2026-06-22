import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';

import 'theme.dart';

/// アプリ全体のテーマモード（システム / ライト / ダーク）。
final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.system);

void main() {
  runApp(const KoeSecretaryApp());
}

class KoeSecretaryApp extends StatelessWidget {
  const KoeSecretaryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeMode,
      builder: (_, mode, _) => MaterialApp(
        title: 'Koely',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: mode,
        home: const HomePage(),
      ),
    );
  }
}

enum AppStatus { idle, listening, opening }

ThemeMode _parseMode(String? v) {
  switch (v) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}

String _modeToString(ThemeMode m) => m.name; // system / light / dark

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const _kBot = 'bot_username';
  static const _kProvider = 'provider'; // telegram / custom
  static const _kCustomTemplate = 'custom_template';
  static const _kAutoListen = 'auto_listen';
  static const _kTrigger = 'trigger_phrase';
  static const _kResetTrigger = 'reset_trigger';
  static const _kCountdownSecs = 'countdown_secs';
  static const _kThemeMode = 'theme_mode';

  final ScrollController _previewScroll = ScrollController();

  // iOS: Apple Speech / Android: Google 認識（speech_to_text）。
  final SpeechToText _speech = SpeechToText();
  bool _speechReady = false;

  String _provider = 'telegram';
  String _customTemplate = '';
  String _bot = '';
  bool _autoListen = true;
  // 文末でこの語を言うと送信カウントダウン開始。
  String _trigger = '送信して';
  // 文末でこの語を言うと書き起こしをリセット。
  String _resetTrigger = 'リセット';
  int _countdownSecs = 3;
  bool _didAutoStart = false;
  // 送信先アプリへ離れて戻ってきた直後は、勝手に聞き始めない。
  bool _returningFromTarget = false;
  // 自動継続（聞き直し）の二重起動防止＆連続失敗フォールバック。
  bool _restarting = false;
  int _failCount = 0;
  DateTime? _lastErrorAt;
  // セッションID：古いセッションの遅延コールバックを無視して混線を防ぐ。
  int _sessionId = 0;

  AppStatus _status = AppStatus.idle;
  String _partial = ''; // 現在の認識中（interim）
  String _accumulated = ''; // 確定済みの積み上げ
  String _lastText = '';

  // 送信カウントダウン（null = 非カウント中）。
  int? _countdown;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _countdownTimer?.cancel();
    _previewScroll.dispose();
    _speech.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // 送信先アプリから戻ってきた直後の1回は、勝手に聞き始めない。
    if (_returningFromTarget) {
      _returningFromTarget = false;
      return;
    }
    if (_autoListen &&
        _isConfigured &&
        _speechReady &&
        _status == AppStatus.idle &&
        !_speech.isListening &&
        _accumulated.isEmpty &&
        _partial.isEmpty &&
        _countdown == null) {
      _startFresh();
    }
  }

  Future<void> _boot() async {
    final prefs = await SharedPreferences.getInstance();
    _bot = prefs.getString(_kBot) ?? '';
    _provider = prefs.getString(_kProvider) ?? 'telegram';
    _customTemplate = prefs.getString(_kCustomTemplate) ?? '';
    _autoListen = prefs.getBool(_kAutoListen) ?? true;
    _trigger = prefs.getString(_kTrigger) ?? '送信して';
    _resetTrigger = prefs.getString(_kResetTrigger) ?? 'リセット';
    _countdownSecs = prefs.getInt(_kCountdownSecs) ?? 3;
    themeMode.value = _parseMode(prefs.getString(_kThemeMode));

    _speechReady = await _speech.initialize(
      onStatus: _onSpeechStatus,
      onError: (_) => _onSpeechError(),
    );
    if (!mounted) return;
    setState(() {});

    if (_autoListen && _isConfigured && _speechReady && !_didAutoStart) {
      _didAutoStart = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _startFresh());
    }
  }

  bool get _isConfigured => _provider == 'telegram'
      ? _bot.isNotEmpty
      : _customTemplate.contains('{text}');

  // フレーズで区切れても自動で聞き直して継続（確定は finalResult で積み上げ済み）。
  void _onSpeechStatus(String status) {
    if (!mounted) return;
    if (status != 'done' && status != 'notListening') return;
    if (_status != AppStatus.listening) return;
    if (_restarting) return;
    _commitSegment();
    _relisten();
  }

  void _onSpeechError() {
    if (!mounted) return;
    if (_status != AppStatus.listening) {
      setState(() => _status = AppStatus.idle);
      return;
    }
    if (_restarting) return;
    _commitSegment();
    final now = DateTime.now();
    if (_lastErrorAt != null &&
        now.difference(_lastErrorAt!).inMilliseconds < 1200) {
      _failCount++;
    } else {
      _failCount = 1;
    }
    _lastErrorAt = now;
    if (_failCount >= 5) {
      _failCount = 0;
      try {
        _speech.cancel();
      } catch (_) {}
      setState(() => _status = AppStatus.idle);
      return;
    }
    _relisten();
  }

  /// 直前セッションを確実に止めてから聞き直す（本文は保持）。
  void _relisten() {
    if (_restarting) return;
    _restarting = true;
    Future.delayed(const Duration(milliseconds: 250), () async {
      try {
        if (!mounted || _status != AppStatus.listening) return;
        if (_speech.isListening) {
          try {
            await _speech.stop();
          } catch (_) {}
          await Future.delayed(const Duration(milliseconds: 120));
        }
        if (!mounted || _status != AppStatus.listening) return;
        await _beginListen();
      } finally {
        _restarting = false;
      }
    });
  }

  void _commitSegment() {
    if (_partial.trim().isNotEmpty) {
      _accumulated = '$_accumulated ${_partial.trim()}'.trim();
    }
    _partial = '';
    _evaluateTrigger();
  }

  /// 余分な空白・末尾の句読点を落とす。
  String _norm(String s) =>
      s.replaceAll(RegExp(r'[\s。、，．！？!?,.]+$'), '').trim();

  String get _triggerKey => _trigger.replaceAll(RegExp(r'\s'), '');
  String get _resetKey => _resetTrigger.replaceAll(RegExp(r'\s'), '');

  /// 認識テキストの末尾が「リセット語」なら即クリア、「送信語」ならカウントダウン。
  void _evaluateTrigger() {
    final full = '$_accumulated $_partial';
    final key = _norm(full).replaceAll(RegExp(r'\s'), '');

    // リセット語が末尾 → 書き起こしを消してまっさらで聞き直す。
    if (_resetKey.isNotEmpty && key.endsWith(_resetKey)) {
      _reset();
      return;
    }

    // 送信語が末尾 → カウントダウン開始/維持。それ以外は取りやめ。
    final trig = _triggerKey;
    final hit = trig.isNotEmpty && key.endsWith(trig);
    if (hit) {
      if (_countdown == null) _startCountdown();
    } else {
      if (_countdown != null) _cancelCountdown();
    }
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    setState(() => _countdown = _countdownSecs);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final next = (_countdown ?? 0) - 1;
      if (next <= 0) {
        _sendNow();
      } else {
        setState(() => _countdown = next);
      }
    });
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    if (mounted) setState(() => _countdown = null);
  }

  /// 送信本文。トリガー語は（途中で取りやめた分も含め）全て除去し、本文は引き継ぐ。
  String _sendBody() {
    var body = '$_accumulated $_partial';
    final trig = _trigger.trim();
    if (trig.isNotEmpty) body = body.replaceAll(trig, ' ');
    return body.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// 今すぐ送信（カウントダウン0・「今すぐ送信」・手動タップ共通）。
  void _sendNow() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _countdown = null;
    final text = _sendBody();
    _speech.cancel();
    _accumulated = '';
    _partial = '';
    if (text.isEmpty) {
      setState(() {});
      _startFresh();
      return;
    }
    setState(() {
      _status = AppStatus.idle;
      _lastText = text;
    });
    _openTarget(text);
  }

  /// 新規に聞き始める（本文クリア）。アイドルからのタップ／起動時／送信後用。
  Future<void> _startFresh() async {
    if (!_speechReady) {
      _speechReady = await _speech.initialize(
        onStatus: _onSpeechStatus,
        onError: (_) => _onSpeechError(),
      );
      if (!_speechReady) return;
    }
    if (!_isConfigured) {
      _openSettings();
      return;
    }
    _accumulated = '';
    _partial = '';
    _failCount = 0;
    _cancelCountdown();
    if (_speech.isListening) {
      try {
        await _speech.stop();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 120));
    }
    await _beginListen();
  }

  /// 実際の listen 呼び出し（本文は保持）。
  Future<void> _beginListen() async {
    if (!mounted || _speech.isListening) return;
    final myId = ++_sessionId;
    setState(() {
      _status = AppStatus.listening;
      _partial = '';
    });
    await _speech.listen(
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: false,
        listenMode: ListenMode.dictation,
        localeId: 'ja_JP',
        pauseFor: const Duration(seconds: 4),
      ),
      onResult: (result) {
        if (!mounted || myId != _sessionId) return;
        if (result.finalResult) {
          // 確定は追記専用で固定。確定が空/短い時は表示中(partial)を採用して欠落防止。
          final w = result.recognizedWords.trim();
          final p = _partial.trim();
          final keep = w.length >= p.length ? w : p;
          if (keep.isNotEmpty) _accumulated = '$_accumulated $keep'.trim();
          _partial = '';
        } else {
          _partial = result.recognizedWords;
        }
        setState(() {});
        _evaluateTrigger();
      },
    );
  }

  /// リセット：書き起こしを全部消して、まっさらで聞き直す。
  void _reset() {
    _lastText = '';
    _startFresh();
  }

  /// マイクタップ：本文があれば今すぐ送信、無ければ停止/開始。
  void _toggleMic() {
    if (_status == AppStatus.listening) {
      if (_sendBody().isNotEmpty) {
        _sendNow();
      } else {
        _cancelCountdown();
        _speech.cancel();
        _accumulated = '';
        setState(() {
          _status = AppStatus.idle;
          _partial = '';
        });
      }
    } else if (_status == AppStatus.idle) {
      _startFresh();
    }
  }

  /// 設定中の送信先を、本文入力済みの状態で開く。送信はユーザーが1タップ。
  /// telegram: tg:// スキーム（web フォールバックあり）/ custom: {text} 入りURLテンプレ。
  Future<void> _openTarget(String text) async {
    final encoded = Uri.encodeComponent(text);
    Uri? primary;
    Uri? fallback;

    if (_provider == 'telegram') {
      final bot = _bot.replaceAll('@', '').trim();
      if (bot.isEmpty) {
        _openSettings();
        return;
      }
      primary = Uri.tryParse('tg://resolve?domain=$bot&text=$encoded');
      fallback = Uri.tryParse('https://t.me/$bot?text=$encoded');
    } else {
      final tmpl = _customTemplate.trim();
      if (!tmpl.contains('{text}')) {
        _openSettings();
        return;
      }
      primary = Uri.tryParse(tmpl.replaceAll('{text}', encoded));
    }

    if (primary == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('送信先のURLが不正です')),
        );
      }
      return;
    }

    setState(() => _status = AppStatus.opening);
    // この直後に外部アプリへ離れる。戻ってきた時の自動リスンを1回だけ抑止。
    _returningFromTarget = true;

    bool ok = false;
    try {
      ok = await launchUrl(primary, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && fallback != null) {
      try {
        ok = await launchUrl(fallback, mode: LaunchMode.externalApplication);
      } catch (_) {
        ok = false;
      }
    }
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('送信先アプリを開けませんでした')),
      );
    }
    if (mounted) setState(() => _status = AppStatus.idle);
  }

  Future<void> _openSettings() async {
    final botCtrl = TextEditingController(text: _bot);
    final customCtrl = TextEditingController(text: _customTemplate);
    final triggerCtrl = TextEditingController(text: _trigger);
    final resetCtrl = TextEditingController(text: _resetTrigger);
    String provider = _provider;
    bool autoListen = _autoListen;
    double secs = _countdownSecs.toDouble();
    ThemeMode mode = themeMode.value;

    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false, // 誤タップで閉じないように
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('設定'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('送信先', style: TextStyle(color: ctx.tokens.text)),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    segments: const [
                      ButtonSegment(value: 'telegram', label: Text('Telegram')),
                      ButtonSegment(value: 'custom', label: Text('カスタム')),
                    ],
                    selected: {provider},
                    onSelectionChanged: (s) =>
                        setLocal(() => provider = s.first),
                  ),
                ),
                const SizedBox(height: 12),
                if (provider == 'telegram')
                  TextField(
                    controller: botCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Telegram bot のユーザー名',
                      hintText: 'my_secretary_bot（@は不要）',
                    ),
                    autocorrect: false,
                  )
                else ...[
                  TextField(
                    controller: customCtrl,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'URL テンプレ（{text} が本文に置換）',
                      hintText: 'https://wa.me/8190xxxx?text={text}',
                    ),
                    autocorrect: false,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '例:\n  LINE公式  https://line.me/R/oaMessage/@xxx/?{text}\n  WhatsApp  https://wa.me/番号?text={text}\n  SMS  sms:?body={text}',
                    style: TextStyle(
                      color: ctx.tokens.text.withValues(alpha: 0.6),
                      fontSize: 11,
                      height: 1.5,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                _ThemeToggle(
                  mode: mode,
                  onChanged: (m) {
                    setLocal(() => mode = m);
                    themeMode.value = m; // 即プレビュー
                  },
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: triggerCtrl,
                  decoration: const InputDecoration(
                    labelText: '送信トリガー語',
                    hintText: '送信して',
                    helperText: '文末でこの語を言うとカウントダウン開始',
                  ),
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: resetCtrl,
                  decoration: const InputDecoration(
                    labelText: 'リセット語',
                    hintText: 'リセット',
                    helperText: '文末でこの語を言うと書き起こしを消去',
                  ),
                  autocorrect: false,
                ),
                const SizedBox(height: 16),
                Text(
                  '送信までの秒数: ${secs.round()}秒',
                  style: TextStyle(color: ctx.tokens.text),
                ),
                Slider(
                  value: secs,
                  min: 2,
                  max: 8,
                  divisions: 6,
                  label: '${secs.round()}秒',
                  onChanged: (v) => setLocal(() => secs = v),
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('起動時に自動で聞き始める'),
                  value: autoListen,
                  onChanged: (v) => setLocal(() => autoListen = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    final prefs = await SharedPreferences.getInstance();
    if (saved == true) {
      _bot = botCtrl.text.trim();
      _provider = provider;
      _customTemplate = customCtrl.text.trim();
      _autoListen = autoListen;
      _trigger = triggerCtrl.text.trim().isEmpty
          ? '送信して'
          : triggerCtrl.text.trim();
      _resetTrigger = resetCtrl.text.trim().isEmpty
          ? 'リセット'
          : resetCtrl.text.trim();
      _countdownSecs = secs.round();
      await prefs.setString(_kBot, _bot);
      await prefs.setString(_kProvider, _provider);
      await prefs.setString(_kCustomTemplate, _customTemplate);
      await prefs.setBool(_kAutoListen, _autoListen);
      await prefs.setString(_kTrigger, _trigger);
      await prefs.setString(_kResetTrigger, _resetTrigger);
      await prefs.setInt(_kCountdownSecs, _countdownSecs);
      await prefs.setString(_kThemeMode, _modeToString(mode));
      themeMode.value = mode;
      if (mounted) setState(() {});
    } else {
      // キャンセル時はプレビューしたテーマを元に戻す。
      themeMode.value = _parseMode(prefs.getString(_kThemeMode));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final listening = _status == AppStatus.listening;
    final opening = _status == AppStatus.opening;
    final counting = _countdown != null;
    final running = '$_accumulated $_partial'.trim();
    final composed = _sendBody(); // 確定待ちの本文（トリガー語除去済み）
    // 待機中（セッション終了・本文あり・カウントなし）＝追記/送信できる状態。
    final paused = !listening && !counting && composed.isNotEmpty;
    final shown = listening
        ? running
        : (composed.isNotEmpty ? composed : _lastText);
    final iconBrightness = isDark ? Brightness.light : Brightness.dark;

    // 認識中は最新の行が見えるよう、毎フレーム最下部へ追従。
    if (listening) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_previewScroll.hasClients) {
          _previewScroll.jumpTo(_previewScroll.position.maxScrollExtent);
        }
      });
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: iconBrightness,
        systemNavigationBarColor: t.bg,
        systemNavigationBarIconBrightness: iconBrightness,
      ),
      child: Scaffold(
        appBar: AppBar(
          leadingWidth: 52,
          leading: Padding(
            padding: const EdgeInsets.only(left: 16, top: 10, bottom: 10),
            child: ClipOval(
              child: Image.asset(
                isDark
                    ? 'assets/icon/app_icon_dark.png'
                    : 'assets/icon/app_icon_light.png',
              ),
            ),
          ),
          title: const Text('Koely'),
          actions: [
            IconButton(
              onPressed: _openSettings,
              icon: const Icon(Icons.settings),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_isConfigured)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: t.surface,
                    borderRadius: BorderRadius.circular(AppRadius.button),
                    border: Border.all(color: t.hairline),
                  ),
                  child: Text(
                    '右上の設定から送信先を設定してね',
                    style: TextStyle(color: t.text),
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                counting
                    ? '送信まで $_countdown'
                    : listening
                        ? '聞いてるよ…（「$_trigger」で送信）'
                        : paused
                            ? '続けて話す or 送信'
                            : shown.isEmpty
                                ? 'マイクを押して話しかけてね'
                                : '送信したよ',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: (listening || counting) ? t.accent : t.text,
                  fontSize: counting ? 22 : 15,
                  fontWeight: counting ? FontWeight.w700 : FontWeight.w400,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 12),
              // プレビュー：残りの縦スペースいっぱい＋中身はスクロール可能。
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: t.surface,
                    borderRadius: BorderRadius.circular(AppRadius.surface),
                    border: Border.all(color: t.hairline),
                  ),
                  child: shown.isEmpty
                      ? Center(
                          child: Text(
                            'ここに認識結果が出るよ',
                            style: TextStyle(
                              color: t.text.withValues(alpha: 0.4),
                              fontSize: 14,
                            ),
                          ),
                        )
                      : Scrollbar(
                          controller: _previewScroll,
                          child: SingleChildScrollView(
                            controller: _previewScroll,
                            child: Text(
                              shown,
                              style: TextStyle(
                                fontSize: 20,
                                color: t.textHover,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 16),
              if (_lastText.isNotEmpty && !listening && !counting && !paused)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: OutlinedButton.icon(
                    onPressed: opening ? null : () => _openTarget(_lastText),
                    icon: const Icon(Icons.send),
                    label: const Text('送信先をもう一度開く'),
                  ),
                ),
              // リセット（書き起こしがズレた時にやり直す）。
              if (!counting && !opening && (listening || paused))
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Center(
                    child: TextButton.icon(
                      onPressed: _reset,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('リセット'),
                    ),
                  ),
                ),
              if (counting)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _cancelCountdown,
                          child: const Text('キャンセル'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _sendNow,
                          icon: const Icon(Icons.send),
                          label: const Text('今すぐ送信'),
                        ),
                      ),
                    ],
                  ),
                )
              else if (paused)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: opening ? null : () => _beginListen(),
                          icon: const Icon(Icons.mic),
                          label: const Text('続けて話す'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: opening ? null : _sendNow,
                          icon: const Icon(Icons.send),
                          label: const Text('送信'),
                        ),
                      ),
                    ],
                  ),
                )
              else
                _MicButton(
                  listening: listening,
                  opening: opening,
                  onTap: () {
                    if (!opening) _toggleMic();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「現在のテーマ名 ＋ 3連トグル」。選択中はアクセント丸ノブが乗り、非選択はアイコンが覗く。
class _ThemeToggle extends StatelessWidget {
  const _ThemeToggle({required this.mode, required this.onChanged});

  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;

  static const _modes = [ThemeMode.system, ThemeMode.light, ThemeMode.dark];
  static const _icons = [
    Icons.brightness_auto,
    Icons.light_mode,
    Icons.dark_mode,
  ];
  static const _names = ['システム', 'ライト', 'ダーク'];

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final index = _modes.indexOf(mode);
    const slotW = 46.0;
    const h = 40.0;
    const thumb = 34.0;

    return Row(
      children: [
        Expanded(
          child: Text(
            _names[index],
            style: TextStyle(
              color: t.textHover,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Container(
          width: slotW * 3,
          height: h,
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(h / 2),
            border: Border.all(color: t.hairline),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 選択中に乗る丸ノブ（アクティブアイコンを載せる）。
              AnimatedAlign(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment(index - 1.0, 0),
                child: SizedBox(
                  width: slotW,
                  child: Center(
                    child: Container(
                      width: thumb,
                      height: thumb,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: t.accent,
                        boxShadow: [
                          BoxShadow(
                            color: t.accent.withValues(alpha: 0.35),
                            blurRadius: 12,
                          ),
                        ],
                      ),
                      child: Icon(_icons[index], size: 18, color: t.onAccent),
                    ),
                  ),
                ),
              ),
              // 3スロット（非選択はアイコンが見える、選択中はノブの下に隠れる）。
              Row(
                children: List.generate(3, (i) {
                  return Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onChanged(_modes[i]),
                      child: Center(
                        child: Icon(
                          _icons[i],
                          size: 18,
                          color: i == index
                              ? Colors.transparent
                              : t.text.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.listening,
    required this.opening,
    required this.onTap,
  });

  final bool listening;
  final bool opening;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final active = listening;
    final label = opening
        ? '送信先を開いてるよ…'
        : listening
            ? 'タップで今すぐ送信'
            : 'タップで話す';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: opening ? null : onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 104,
            width: 104,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? t.accent.withValues(alpha: 0.14) : t.surface,
              border: Border.all(
                color: active ? t.accent : t.hairline,
                width: active ? 1.5 : 1,
              ),
              boxShadow: [
                if (active)
                  BoxShadow(
                    color: t.accent.withValues(alpha: 0.30),
                    blurRadius: 28,
                    spreadRadius: 2,
                  ),
              ],
            ),
            child: Icon(
              opening
                  ? Icons.open_in_new
                  : listening
                      ? Icons.stop
                      : Icons.mic,
              size: 44,
              color: active ? t.accent : t.text,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          label,
          style: TextStyle(
            color: active ? t.accent : t.text,
            fontSize: 13,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
