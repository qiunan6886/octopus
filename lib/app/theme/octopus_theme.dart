import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Octopus 的视觉语言：**纸、墨、彩**。
///
/// * [octopusPaper]（浅色）—— 暖白纸面，纯黑作强调色
/// * [octopusInk]（深色）—— 纯黑墨面，纯白作强调色
/// * [octopusVivid]（浅色，彩色）—— 明亮的淡紫纸面，紫 + 珊瑚 + 琥珀
///
/// 纸和墨互为反色、严格单色。理由：这是个**错题**应用，内容本身是试卷照片和
/// 印刷体文字，彩色会和题目内容抢注意力，打印时也会失真。所以**单色是默认**。
///
/// [octopusVivid] 是给想换个心情的用户准备的**第三个选项**，不替换前两个。
/// 它不只是在单色上加一个强调色——[accentAlt]、[success]、[warning] 和
/// [heroGradient] 都会真正参与界面，否则「彩色」只是个摆设。
///
/// 结构沿用 Spark 的做法：调色板是数据，[OctopusColors] 是全局静态访问点。
/// 代价是颜色不再是 `const`，且 Flutter 无法自动感知切换——由 app 根节点
/// 在每次 build 前调用 [OctopusColors.apply]，并用 palette id 作 key 强制重建。
@immutable
class OctopusPalette {
  const OctopusPalette({
    required this.id,
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceHigh,
    required this.accent,
    required this.onAccent,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.border,
    required this.danger,
    this.accentAlt,
    this.success,
    this.warning,
    this.heroGradient,
    this.isColorful = false,
  });

  /// 稳定标识。同时用作 widget key：颜色走静态读取，Flutter 观察不到变化。
  final String id;

  final Brightness brightness;

  /// 页面底色。
  final Color background;

  /// 卡片、列表行、底部栏。
  final Color surface;

  /// 比 [surface] 高一层的底色（按下态、未选中的 chip）。
  final Color surfaceHigh;

  /// 主强调色。纸是黑、墨是白、彩是紫。
  final Color accent;

  /// 压在 [accent] 上的内容色。
  final Color onAccent;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  /// 分隔线、卡片描边。
  final Color border;

  /// 删除、丢弃。破坏性操作必须一眼可辨，所以单色主题也保留它。
  final Color danger;

  /// 第二强调色。单色主题里等于 [accent]（等于没用），只有彩主题给不同的值。
  final Color? accentAlt;

  /// 已掌握。单色主题里是灰阶。
  final Color? success;

  /// 复习中。单色主题里是灰阶。
  final Color? warning;

  /// 顶部/头部的渐变。单色主题给一个几乎看不见的同色渐变，保持结构一致。
  final Gradient? heroGradient;

  /// 是否处于彩色模式。
  ///
  /// 界面据此决定要不要用装饰性颜色（学科标签、进度条、头像渐变）。
  /// 用显式的标志而不是「accent 是不是灰」来判断，是因为后者太隐晦。
  final bool isColorful;

  /// 取第二强调色，单色主题回退到主强调色。
  Color get accentAltOrAccent => accentAlt ?? accent;

  Color get successOrPrimary => success ?? textSecondary;

  Color get warningOrPrimary => warning ?? textSecondary;
}

/// 「纸」——浅色主题。
///
/// 背景用带一点暖调的灰白而不是纯白，这样白色卡片（surface）能浮起来；
/// 纯白背景 + 纯白卡片会让卡片边界完全消失。
const octopusPaper = OctopusPalette(
  id: 'paper',
  brightness: Brightness.light,
  background: Color(0xFFF4F4F2),
  surface: Color(0xFFFFFFFF),
  surfaceHigh: Color(0xFFEAEAE7),
  accent: Color(0xFF111111),
  onAccent: Color(0xFFFFFFFF),
  textPrimary: Color(0xFF121212),
  textSecondary: Color(0xFF5A5A5A),
  textTertiary: Color(0xFF8E8E8E),
  border: Color(0xFFE2E2DE),
  danger: Color(0xFFB3261E),
);

/// 「墨」——深色主题。
///
/// 用真正的纯黑作底：OLED 屏幕上省电，且暗环境下灰色底会发灰。
const octopusInk = OctopusPalette(
  id: 'ink',
  brightness: Brightness.dark,
  background: Color(0xFF000000),
  surface: Color(0xFF0D0D0D),
  surfaceHigh: Color(0xFF1A1A1A),
  accent: Color(0xFFFFFFFF),
  onAccent: Color(0xFF0A0A0A),
  textPrimary: Color(0xFFFFFFFF),
  textSecondary: Color(0xFFA2A2A2),
  textTertiary: Color(0xFF6E6E6E),
  border: Color(0xFF262626),
  danger: Color(0xFFFF6B6B),
);

/// 「彩」——彩色主题。
///
/// 淡紫的纸面配紫 + 珊瑚两个强调色，加上琥珀和青绿做语义色。
///
/// 和纸/墨的关键区别不是「换了个颜色」，而是**颜色真的参与了界面**：
/// 头部有渐变、学科标签按科目上色、掌握状态用琥珀/青绿区分。为此专门带了
/// [isColorful] 标志，界面据此决定要不要用装饰性颜色。
///
/// 底色仍然偏亮、对比度足够，因为屏幕上的主角始终是试卷照片。
const octopusVivid = OctopusPalette(
  id: 'vivid',
  brightness: Brightness.light,
  background: Color(0xFFF7F4FF),
  surface: Color(0xFFFFFFFF),
  surfaceHigh: Color(0xFFEDE7FF),
  accent: Color(0xFF6C4CE0),
  onAccent: Color(0xFFFFFFFF),
  accentAlt: Color(0xFFFF6B4A),
  success: Color(0xFF0E9F8A),
  warning: Color(0xFFE08A00),
  textPrimary: Color(0xFF1B1633),
  textSecondary: Color(0xFF5F5878),
  textTertiary: Color(0xFF948CAB),
  border: Color(0xFFE3DCF7),
  danger: Color(0xFFD92D3C),
  heroGradient: LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF6C4CE0), Color(0xFFB44BD6), Color(0xFFFF6B4A)],
  ),
  isColorful: true,
);

/// 全局颜色访问点。
///
/// 保持静态读取（`OctopusColors.accent`）而不是 `ThemeExtension`，
/// 因为绝大多数调用点只关心颜色值本身。
abstract final class OctopusColors {
  static OctopusPalette _active = octopusPaper;

  static OctopusPalette get active => _active;

  /// 由 app 根节点在 build 之前调用一次。
  static void apply(OctopusPalette palette) => _active = palette;

  static Brightness get brightness => _active.brightness;
  static bool get isDark => _active.brightness == Brightness.dark;

  static Color get background => _active.background;
  static Color get surface => _active.surface;
  static Color get surfaceHigh => _active.surfaceHigh;
  static Color get accent => _active.accent;
  static Color get onAccent => _active.onAccent;
  static Color get textPrimary => _active.textPrimary;
  static Color get textSecondary => _active.textSecondary;
  static Color get textTertiary => _active.textTertiary;
  static Color get border => _active.border;
  static Color get danger => _active.danger;

  /// 第二强调色。单色主题里等于主强调色。
  static Color get accentAlt => _active.accentAltOrAccent;

  /// 已掌握 / 成功。单色主题里是次要灰。
  static Color get success => _active.successOrPrimary;

  /// 复习中 / 提醒。单色主题里是次要灰。
  static Color get warning => _active.warningOrPrimary;

  /// 头部渐变。单色主题给一个同色渐变，界面不用为两套主题写分支。
  static Gradient get heroGradient =>
      _active.heroGradient ??
      LinearGradient(colors: [accent, accent], begin: Alignment.topLeft);

  /// 是否彩色模式。界面据此决定要不要用装饰性颜色。
  static bool get isColorful => _active.isColorful;

  /// 学科标签配色。
  ///
  /// 单色主题下全部返回中性色——「色彩丰富」不该渗透到纸和墨里。
  /// 用固定的一组色相而不是随机，这样同一科永远同一个颜色，孩子能记住。
  static Color subjectColor(String? subject) {
    if (!isColorful || subject == null || subject.isEmpty) {
      return textSecondary;
    }
    const palette = [
      Color(0xFF6C4CE0), // 紫
      Color(0xFF0E9F8A), // 青绿
      Color(0xFFE08A00), // 琥珀
      Color(0xFFD6336C), // 玫红
      Color(0xFF2F6FED), // 蓝
      Color(0xFF7A5AF8), // 蓝紫
    ];
    // 用字符码之和取模：同一个学科名永远落到同一个颜色。
    var hash = 0;
    for (final unit in subject.codeUnits) {
      hash = (hash + unit) % palette.length;
    }
    return palette[hash];
  }

  /// 强调色上的半透明填充，用于选中态背景而不是整块反色。
  static Color get accentSoft => accent.withValues(alpha: isDark ? 0.14 : 0.07);

  /// 系统栏图标要跟着主题走，否则深色主题下状态栏图标会看不见。
  static SystemUiOverlayStyle get systemOverlay => isDark
      ? SystemUiOverlayStyle.light
      : SystemUiOverlayStyle.dark;
}

/// 圆角尺度。与 Spark 保持一致，两个项目的观感才能连上。
abstract final class OctopusRadius {
  static const card = 20.0;
  static const sheet = 24.0;
  static const pill = 999.0;
}

/// 间距尺度。
abstract final class OctopusSpacing {
  static const page = 20.0;
  static const gap = 12.0;
  static const section = 28.0;
}

/// 由调色板构造 [ThemeData]。
///
/// 只覆盖用得到的部分：这是单色设计，Material 默认的彩色（涟漪、选中态、
/// 各种 tint）会破坏它，所以这里把能定死的都定死。
ThemeData buildOctopusTheme(OctopusPalette palette) {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: palette.accent,
        brightness: palette.brightness,
      ).copyWith(
        primary: palette.accent,
        onPrimary: palette.onAccent,
        secondary: palette.accent,
        onSecondary: palette.onAccent,
        surface: palette.surface,
        onSurface: palette.textPrimary,
        surfaceContainerHighest: palette.surfaceHigh,
        outline: palette.border,
        error: palette.danger,
        onError: palette.brightness == Brightness.dark
            ? const Color(0xFF1A0000)
            : Colors.white,
      );

  final base = ThemeData(
    useMaterial3: true,
    brightness: palette.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.background,
    // InkSparkle is tinted by the colour scheme; the default ripple is subtler
    // and does not fight the monochrome palette.
    splashFactory: InkRipple.splashFactory,
    dividerColor: palette.border,
    dividerTheme: DividerThemeData(color: palette.border, thickness: 1, space: 1),
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: palette.textPrimary,
      displayColor: palette.textPrimary,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: palette.background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: palette.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: palette.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
      systemOverlayStyle: OctopusColors.isDark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
    ),
    cardTheme: CardThemeData(
      color: palette.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OctopusRadius.card),
        side: BorderSide(color: palette.border),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(OctopusRadius.sheet),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OctopusRadius.card),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: palette.accent,
      contentTextStyle: TextStyle(color: palette.onAccent),
      actionTextColor: palette.onAccent,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OctopusRadius.pill),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.accent,
        foregroundColor: palette.onAccent,
        minimumSize: const Size(0, 48),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: palette.textPrimary,
        side: BorderSide(color: palette.border),
        minimumSize: const Size(0, 48),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: palette.textPrimary,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: palette.accent,
      foregroundColor: palette.onAccent,
      elevation: 0,
      highlightElevation: 0,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? palette.onAccent
            : palette.textTertiary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? palette.accent
            : palette.surfaceHigh,
      ),
      trackOutlineColor: WidgetStateProperty.all(palette.border),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? palette.accent
            : Colors.transparent,
      ),
      checkColor: WidgetStateProperty.all(palette.onAccent),
      side: BorderSide(color: palette.textTertiary, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? palette.accent
            : palette.textTertiary,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: palette.accent,
      linearTrackColor: palette.surfaceHigh,
      circularTrackColor: palette.surfaceHigh,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: palette.textSecondary,
      textColor: palette.textPrimary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OctopusRadius.card),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: palette.surfaceHigh,
      selectedColor: palette.accent,
      labelStyle: TextStyle(color: palette.textPrimary, fontSize: 13),
      secondaryLabelStyle: TextStyle(color: palette.onAccent, fontSize: 13),
      side: BorderSide(color: palette.border),
      shape: const StadiumBorder(),
      showCheckmark: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: palette.accent,
      elevation: 0,
      height: 64,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected)
              ? palette.onAccent
              : palette.textSecondary,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? palette.textPrimary
              : palette.textSecondary,
        ),
      ),
    ),
  );
}
