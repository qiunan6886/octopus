import 'dart:io';

import 'deepseek_client.dart';

/// 重绘结果。
class RedrawOutcome {
  const RedrawOutcome({required this.svg, this.note});

  /// 干净的 SVG 源码。
  final String svg;

  /// 模型对重绘内容的一句话说明，展示在对照页帮用户判断。
  final String? note;
}

/// 把题目里的图形和公式重绘成干净的 SVG。
///
/// **为什么是 SVG 而不是让模型画一张图**：DeepSeek 的接口是对话补全，输出的是
/// 文本。SVG 正好是「文本形式的图」，而且两边都能用——屏幕上用 `flutter_svg`
/// 显示，打印时用 `pdf` 包的 `pw.SvgImage` 直接嵌进 PDF。如果输出位图，就没法
/// 做到既精确排版又清晰打印。
///
/// **为什么值得重绘**：孩子做过的题上面有笔迹、涂改、勾叉，直接裁原图打出来
/// 很脏。让模型看着原图重画一遍，得到的是一张干净的线稿。
///
/// **为什么必须让用户对照**：模型会画错。角度、标注、数字都可能和原题不一致，
/// 所以界面强制并排显示「原图 / AI 重绘」，用户选过之后才用。
class DeepSeekRedrawer {
  DeepSeekRedrawer({required String apiKey, String? model})
    : _client = DeepSeekClient(
        apiKey: apiKey,
        model: model ?? 'deepseek-flash',
      );

  final DeepSeekClient _client;

  Future<RedrawOutcome> redraw({
    required String imagePath,
    required int grade,
  }) async {
    final file = File(imagePath);
    if (!file.existsSync()) {
      throw DeepSeekException('找不到题目图片');
    }
    final bytes = await file.readAsBytes();

    final reply = await _client.chatWithImage(
      prompt: _prompt(grade),
      imageBytes: bytes,
      // 公式的上标下标、图形上的标注都要看清，必须用 high。
      detail: 'high',
    );

    final decoded = DeepSeekClient.firstJsonObject(
      DeepSeekClient.extractContent(reply),
    );
    final raw = decoded?['svg']?.toString();
    if (raw == null) {
      throw DeepSeekException('模型没有返回可用的图形');
    }

    final svg = extractSvg(raw);
    if (svg == null) {
      throw DeepSeekException('模型返回的内容不是有效的 SVG');
    }
    return RedrawOutcome(svg: svg, note: decoded?['note']?.toString().trim());
  }

  /// 从模型回复里抠出 `<svg>...</svg>`。
  ///
  /// 模型经常在 SVG 外面包一层 markdown 代码围栏，或者加一句解释，所以不能直接
  /// 当成 SVG 用。单独暴露是为了能离线测。
  static String? extractSvg(String raw) {
    final start = raw.indexOf('<svg');
    if (start == -1) return null;
    final end = raw.indexOf('</svg>', start);
    if (end == -1) return null;

    final svg = raw.substring(start, end + '</svg>'.length).trim();
    // 一个连 viewBox 或 width/height 都没有的 svg 渲染出来是空的，不如报错让
    // 用户重试。
    if (!svg.contains('viewBox') &&
        !svg.contains('width') &&
        !svg.contains('height')) {
      return null;
    }
    return svg;
  }

  static String _prompt(int grade) {
    final gradeText = switch (grade) {
      <= 6 => '小学${_cn(grade)}年级',
      <= 9 => '初中${_cn(grade - 6)}年级',
      _ => '高中${_cn(grade - 9)}年级',
    };

    return '''
图片是一道$gradeText的题目，上面有学生写过的笔迹、涂改和批改痕迹。

请把这道题**重画成一张干净的 SVG**，去掉所有手写痕迹，只保留题目原本的内容。

按下面的 JSON 格式回答，不要输出别的内容：

{
  "svg": "<svg ...>...</svg>",
  "note": "一句话说明你画的图形是什么，或者哪些地方看不清"
}

绘图要求：
1. 用**纯黑线条 + 白色背景**，不超过 3 种颜色，适合黑白打印。
2. `viewBox` 设成图形的实际范围，例如 `viewBox="0 0 400 200"`。
   图形外的空白不要留。
3. **文字用 `<text>` 标签**写上题目原文，字号不小于 14，
   中文字体写 `font-family="sans-serif"`。
4. 数学公式用普通文字表达，例如 `3/4`、`x²` 写成 `x<tspan baseline-shift="super">2</tspan>`，
   或者直接写 `x2` 并加上标注——**不要依赖 MathML 或 LaTeX**，SVG 里不支持。
5. 只画图里的**几何图形、表格、坐标轴、示意图**，
   以及它们上面的标注数字和字母。
6. 看不清的地方不要猜，在 note 里说明。
7. 不要加边框、水印、页码、说明文字。
''';
  }

  static String _cn(int n) => const [
    '',
    '一',
    '二',
    '三',
    '四',
    '五',
    '六',
  ].elementAt(n.clamp(0, 6));
}
