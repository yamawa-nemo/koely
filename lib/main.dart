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
  static const _kAutoOpen = 'auto_open';
  static const _kLongMode = 'long_mode';
  static const _kThemeMode = 'theme_mode';

  final SpeechToText _speech = SpeechToText();

  String _provider = 'telegram';
  String _customTemplate = '';
  String _bot = '';
  bool _autoListen = true;
  bool _autoOpen = true;
  // 長文モード：無音で勝手に送らず、自分で停止するまで聞き続ける。
  bool _longMode = false;
  bool _speechReady = false;
  bool _didAutoStart = false;
  // Telegram を開いて戻ってきた直後は、勝手に聞き始めない。
  bool _returningFromTelegram = false;
  // 長文モードで、ユーザーが「停止して送信」を押したか。
  bool _finishing = false;

  AppStatus _status = AppStatus.idle;
  String _partial = ''; // 現在の認識セグメント
  String _accumulated = ''; // 確定済みの積み上げ（長文モード）
  String _lastText = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _speech.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // 「OK Google、◯◯を開いて」で前面に戻るたびに自動で聞き始める。
    if (_returningFromTelegram) {
      _returningFromTelegram = false;
      return;
    }
    if (_autoListen && _isConfigured && _speechReady && _status == AppStatus.idle) {
      _startListening();
    }
  }

  Future<void> _boot() async {
    final prefs = await SharedPreferences.getInstance();
    _bot = prefs.getString(_kBot) ?? '';
    _provider = prefs.getString(_kProvider) ?? 'telegram';
    _customTemplate = prefs.getString(_kCustomTemplate) ?? '';
    _autoListen = prefs.getBool(_kAutoListen) ?? true;
    _autoOpen = prefs.getBool(_kAutoOpen) ?? true;
    _longMode = prefs.getBool(_kLongMode) ?? false;
    themeMode.value = _parseMode(prefs.getString(_kThemeMode));

    _speechReady = await _speech.initialize(
      onStatus: _onSpeechStatus,
      onError: (_) => _onSpeechError(),
    );
    if (!mounted) return;
    setState(() {});

    if (_autoListen && _isConfigured && _speechReady && !_didAutoStart) {
      _didAutoStart = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _startListening());
    }
  }

  bool get _isConfigured => _provider == 'telegram'
      ? _bot.isNotEmpty
      : _customTemplate.contains('{text}');

  void _onSpeechStatus(String status) {
    if (!mounted) return;
    if (status != 'done' && status != 'notListening') return;
    if (_status != AppStatus.listening) return;
    _commitSegment();
    // 長文モードかつ未確定なら、無音で切れても聞き直して continue。
    if (_longMode && !_finishing) {
      _scheduleLongRestart();
      return;
    }
    _finalizeAndOpen();
  }

  /// 認識エラー（無音タイムアウト等）。長文モード中は終了扱いにせず聞き直す。
  void _onSpeechError() {
    if (!mounted) return;
    if (_longMode && !_finishing && _status == AppStatus.listening) {
      _commitSegment();
      _scheduleLongRestart();
      return;
    }
    setState(() => _status = AppStatus.idle);
  }

  void _commitSegment() {
    if (_partial.trim().isNotEmpty) {
      _accumulated = '$_accumulated ${_partial.trim()}'.trim();
    }
    _partial = '';
  }

  void _scheduleLongRestart() {
    Future.delayed(const Duration(milliseconds: 400), () async {
      if (!mounted || _finishing || _status != AppStatus.listening) return;
      if (_speech.isListening) return;
      await _startListening(resume: true);
    });
  }

  void _finalizeAndOpen() {
    final text = _accumulated.trim();
    _accumulated = '';
    _finishing = false;
    setState(() {
      _status = AppStatus.idle;
      _lastText = text;
    });
    // 長文モードは「停止して送信」操作なので必ず開く。通常モードは設定に従う。
    final shouldOpen = _longMode || _autoOpen;
    if (text.isNotEmpty && shouldOpen) {
      _openTarget(text);
    }
  }

  Future<void> _startListening({bool resume = false}) async {
    if (_speech.isListening) return;
    if (!_speechReady) {
      _speechReady = await _speech.initialize();
      if (!_speechReady) return;
    }
    if (!_isConfigured) {
      _openSettings();
      return;
    }
    if (!resume) {
      _accumulated = '';
      _finishing = false;
    }
    setState(() {
      _status = AppStatus.listening;
      _partial = '';
    });
    await _speech.listen(
      listenOptions: SpeechListenOptions(
        partialResults: true,
        // 長文モードはエラーでセッションを切らず自前で聞き直す。
        cancelOnError: !_longMode,
        listenMode: ListenMode.dictation,
        localeId: 'ja_JP',
        // 通常モードは長めにして思考の間で切れにくく。長文モードは継続するので短め。
        pauseFor: Duration(seconds: _longMode ? 3 : 5),
      ),
      onResult: (result) {
        if (!mounted) return;
        setState(() => _partial = result.recognizedWords);
      },
    );
  }

  /// 長文モードでは「停止して送信」を意味する。
  Future<void> _stopListening() async {
    if (_longMode) _finishing = true;
    await _speech.stop();
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
    _returningFromTelegram = true;

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
    String provider = _provider;
    bool autoListen = _autoListen;
    bool autoOpen = _autoOpen;
    bool longMode = _longMode;
    ThemeMode mode = themeMode.value;

    final saved = await showDialog<bool>(
      context: context,
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
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('起動時に自動で聞き始める'),
                  value: autoListen,
                  onChanged: (v) => setLocal(() => autoListen = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('話し終えたら自動で送信先を開く'),
                  value: autoOpen,
                  onChanged: (v) => setLocal(() => autoOpen = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('長文モード'),
                  subtitle: const Text('無音で勝手に送らず、自分で停止するまで聞き続ける'),
                  value: longMode,
                  onChanged: (v) => setLocal(() => longMode = v),
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
      _autoOpen = autoOpen;
      _longMode = longMode;
      await prefs.setString(_kBot, _bot);
      await prefs.setString(_kProvider, _provider);
      await prefs.setString(_kCustomTemplate, _customTemplate);
      await prefs.setBool(_kAutoListen, _autoListen);
      await prefs.setBool(_kAutoOpen, _autoOpen);
      await prefs.setBool(_kLongMode, _longMode);
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
    final running = '$_accumulated $_partial'.trim();
    final shown = listening ? running : _lastText;
    final iconBrightness = isDark ? Brightness.light : Brightness.dark;

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
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        listening
                            ? '聞いてるよ…'
                            : shown.isEmpty
                                ? 'マイクを押して話しかけてね'
                                : '認識したよ',
                        style: TextStyle(
                          color: listening ? t.accent : t.text,
                          fontSize: 15,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (shown.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: t.surface,
                            borderRadius:
                                BorderRadius.circular(AppRadius.surface),
                            border: Border.all(color: t.hairline),
                          ),
                          child: Text(
                            shown,
                            style: TextStyle(
                              fontSize: 20,
                              color: t.textHover,
                              height: 1.4,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (_lastText.isNotEmpty && !listening)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: OutlinedButton.icon(
                    onPressed: opening ? null : () => _openTarget(_lastText),
                    icon: const Icon(Icons.send),
                    label: const Text('送信先をもう一度開く'),
                  ),
                ),
              _MicButton(
                listening: listening,
                opening: opening,
                longMode: _longMode,
                onTap: () {
                  if (listening) {
                    _stopListening();
                  } else if (!opening) {
                    _startListening();
                  }
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
    required this.longMode,
    required this.onTap,
  });

  final bool listening;
  final bool opening;
  final bool longMode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final active = listening;
    final label = opening
        ? '送信先を開いてるよ…'
        : listening
            ? (longMode ? 'タップで停止して送信' : 'タップで停止')
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
