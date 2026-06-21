import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// PhonePad と統一したデザイントークン（light / dark 両対応）。
/// このファイルごと次のアプリにコピーすれば同じ世界観を確立できる。
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.bg,
    required this.surface,
    required this.hairline,
    required this.text,
    required this.textHover,
    required this.accent,
    required this.onAccent,
  });

  final Color bg; // 地色
  final Color surface; // フラットな機能面（薄いオーバーレイ）
  final Color hairline; // 主張しない極薄ボーダー
  final Color text; // 本文
  final Color textHover; // 強調・アクティブ
  final Color accent; // アクセント
  final Color onAccent; // アクセント上の文字色

  /// Dark（既定）
  static const dark = AppTokens(
    bg: Color(0xFF16191C),
    surface: Color(0x0DFFFFFF), // white 5%
    hairline: Color(0x14FFFFFF), // white 8%
    text: Color(0xFFD1D5DB),
    textHover: Color(0xFFFFFFFF),
    accent: Color(0xFF60A5FA),
    onAccent: Color(0xFF16191C),
  );

  /// Light（PhonePad のライトグレー）
  static const light = AppTokens(
    bg: Color(0xFFF5F5F5),
    surface: Color(0x08000000), // black 3%
    hairline: Color(0x1F000000), // black 12%
    text: Color(0xFF4B5563), // gray-600
    textHover: Color(0xFF1F2937), // gray-800
    accent: Color(0xFF3B82F6), // blue-500
    onAccent: Color(0xFFFFFFFF),
  );

  @override
  AppTokens copyWith({
    Color? bg,
    Color? surface,
    Color? hairline,
    Color? text,
    Color? textHover,
    Color? accent,
    Color? onAccent,
  }) {
    return AppTokens(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      hairline: hairline ?? this.hairline,
      text: text ?? this.text,
      textHover: textHover ?? this.textHover,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
    );
  }

  @override
  AppTokens lerp(AppTokens? other, double t) {
    if (other == null) return this;
    return AppTokens(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      text: Color.lerp(text, other.text, t)!,
      textHover: Color.lerp(textHover, other.textHover, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
    );
  }
}

/// `context.tokens` で現在のテーマのトークンに最短アクセス。
extension AppTokensX on BuildContext {
  AppTokens get tokens => Theme.of(this).extension<AppTokens>()!;
}

class AppRadius {
  const AppRadius._();
  static const button = 12.0; // 0.75rem
  static const surface = 24.0; // 1.5rem
}

class AppTheme {
  const AppTheme._();

  /// Inter は日本語グリフを持たないので日本語は Noto Sans JP にフォールバック。
  static final List<String> _jpFallback = [
    if (GoogleFonts.notoSansJp().fontFamily != null)
      GoogleFonts.notoSansJp().fontFamily!,
  ];

  static TextStyle font({
    double? size,
    FontWeight? weight,
    Color? color,
    double? letterSpacing,
    double? height,
  }) {
    return GoogleFonts.inter(
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
    ).copyWith(fontFamilyFallback: _jpFallback);
  }

  static ThemeData get dark => _build(AppTokens.dark, Brightness.dark);
  static ThemeData get light => _build(AppTokens.light, Brightness.light);

  static ThemeData _build(AppTokens t, Brightness brightness) {
    final base = ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: t.bg,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: t.accent,
        onPrimary: t.onAccent,
        secondary: t.accent,
        onSecondary: t.onAccent,
        surface: t.bg,
        onSurface: t.text,
        error: const Color(0xFFF87171),
        onError: Colors.white,
      ),
      useMaterial3: true,
    );

    return base.copyWith(
      extensions: [t],
      textTheme: GoogleFonts.interTextTheme(base.textTheme).apply(
        bodyColor: t.text,
        displayColor: t.text,
        fontFamilyFallback: _jpFallback,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: t.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: font(
          color: t.textHover,
          size: 20,
          weight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(color: t.text),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.bg,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.surface),
          side: BorderSide(color: t.hairline),
        ),
        titleTextStyle: font(
          color: t.textHover,
          size: 18,
          weight: FontWeight.w600,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.accent,
          foregroundColor: t.onAccent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: t.text,
          side: BorderSide(color: t.hairline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: t.text),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll(font(size: 13)),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? t.onAccent : t.text,
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? t.accent
                : Colors.transparent,
          ),
          side: WidgetStatePropertyAll(BorderSide(color: t.hairline)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        labelStyle: TextStyle(color: t.text),
        hintStyle: TextStyle(color: t.text.withValues(alpha: 0.4)),
        enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: t.text.withValues(alpha: 0.2)),
        ),
        focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: t.accent),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.accent : t.text,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? t.accent.withValues(alpha: 0.3)
              : t.surface,
        ),
      ),
    );
  }
}
