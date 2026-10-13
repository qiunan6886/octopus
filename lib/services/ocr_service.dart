import 'dart:io';
import 'dart:ui';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'deepseek_client.dart';
import 'question_splitter.dart';

/// OCR 结果。
class OcrOutcome {
  const OcrOutcome({
    required this.text,
    required this.engine,
    this.lines = const [],
  });

  final String text;

  /// local / cloud —— 记下来是因为两者质量不同，出问题时能知道是谁识别的。
  final String engine;

  /// 带坐标的文字行，供自动切题使用。
  ///
  /// 云端引擎（DeepSeek）只返回纯文本，拿不到坐标，所以这里可能为空——
  /// 自动切题会退回手动框选。
  final List<PageLine> lines;

  bool get hasGeometry => lines.isNotEmpty;
}

/// 文字识别的统一接口。
///
/// 设计文档定的是**本地和云端两种都做、用户在设置里选**：本地胜在照片不出设备，
/// 云端胜在对手写体和复杂版面的识别率。
abstract class OcrEngine {
  String get id;
  Future<OcrOutcome> recognize(String imagePath);
}

/// 本地识别：Google ML Kit 的端上文字识别。
///
/// 选它而不是 PaddleOCR，是因为它能直接跑在设备上、不需要打包几十兆的模型权重，
/// 中文模型由 Google Play 服务提供。代价是**对手写体识别很差**——它擅长印刷体，
/// 而错题的题干正好是印刷体，所以够用；孩子的手写答案本来也不是靠 OCR 读的，
/// 那是批改模型的事。
class MlKitOcrEngine implements OcrEngine {
  MlKitOcrEngine();

  @override
  String get id => 'local';

  @override
  Future<OcrOutcome> recognize(String imagePath) async {
    final file = File(imagePath);
    if (!file.existsSync()) {
      throw DeepSeekException('找不到题目图片');
    }

    final recognizer = TextRecognizer(script: TextRecognitionScript.chinese);
    try {
      final input = InputImage.fromFilePath(imagePath);
      final result = await recognizer.processImage(input);

      // ML Kit 按块返回，块内还有行。这里把块按位置拼起来——直接 join 所有行会
      // 打乱阅读顺序，因为块之间不一定按坐标排列。
      final blocks = [...result.blocks]
        ..sort((a, b) {
          final dy = a.boundingBox.top.compareTo(b.boundingBox.top);
          return dy != 0
              ? dy
              : a.boundingBox.left.compareTo(b.boundingBox.left);
        });

      final buffer = StringBuffer();
      final lines = <PageLine>[];
      for (final block in blocks) {
        for (final line in block.lines) {
          final text = line.text.trim();
          if (text.isEmpty) continue;
          buffer.writeln(text);
          // ML Kit 给的是整数像素坐标，转成 Rect 供切题用。
          final box = line.boundingBox;
          lines.add(
            PageLine(
              text: text,
              box: Rect.fromLTRB(
                box.left.toDouble(),
                box.top.toDouble(),
                box.right.toDouble(),
                box.bottom.toDouble(),
              ),
            ),
          );
        }
      }
      return OcrOutcome(
        text: buffer.toString().trim(),
        engine: id,
        lines: lines,
      );
    } finally {
      await recognizer.close();
    }
  }
}

/// 云端识别：把题目图片交给 DeepSeek 的视觉模型读出文字。
///
/// 相比端上识别，它**能读手写体、能理解版面**（比如把选项归到题干下面），也
/// 能顺手把公式转成 LaTeX。代价是照片要上传，且需要 API Key。
class DeepSeekVisionOcrEngine implements OcrEngine {
  DeepSeekVisionOcrEngine({required String apiKey, String? model})
    : _client = DeepSeekClient(
        apiKey: apiKey,
        model: model ?? 'deepseek-flash',
      );

  final DeepSeekClient _client;

  @override
  String get id => 'cloud';

  @override
  Future<OcrOutcome> recognize(String imagePath) async {
    final file = File(imagePath);
    if (!file.existsSync()) {
      throw DeepSeekException('找不到题目图片');
    }
    final bytes = await file.readAsBytes();

    final reply = await _client.chatWithImage(
      prompt: _prompt,
      imageBytes: bytes,
      // 印刷体文字用 high 更稳；题目里常有上下标和公式，low 会糊。
      detail: 'high',
    );

    final text = parseTextResponse(reply);
    if (text == null || text.isEmpty) {
      throw DeepSeekException('没有从图片里读出文字');
    }
    return OcrOutcome(text: text, engine: id);
  }

  /// 从模型回复里取 `text` 字段。
  ///
  /// 单独暴露是为了能离线测——模型可能加解释、包代码围栏，解析比网络调用更容易
  /// 出错。
  static String? parseTextResponse(String raw) {
    final decoded = DeepSeekClient.firstJsonObject(
      DeepSeekClient.extractContent(raw),
    );
    final text = decoded?['text']?.toString().trim();
    if (text == null || text.isEmpty) return null;
    return text;
  }

  static const _prompt = '''
图片是一道学生作业或试卷上的题目。请把题目里的**印刷体文字**完整抄录下来。

按下面的 JSON 格式回答，不要输出别的内容：

{
  "text": "题目的完整文字"
}

要求：
1. 只抄题目本身的文字，**不要抄学生手写的答案**，也不要抄批改痕迹。
2. 保持原有的换行和分条结构（如「（1）（2）」「A. B. C. D.」）。
3. 数学式子用普通文本写清楚，例如「3/4」「x²」「12 × 5 =」。
4. 图片里有图形、表格且无法用文字表达时，在该位置写「[图]」。
5. 一个字都读不出来时，text 填空字符串。
''';
}

/// 批量识别时，逐题报告失败，而不是整批停下。
class OcrFailure {
  const OcrFailure({required this.path, required this.message});

  final String path;
  final String message;
}
