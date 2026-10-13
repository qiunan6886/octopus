import 'dart:io';
import 'dart:typed_data';

import 'deepseek_client.dart';

/// 批改结果。
class GradeOutcome {
  const GradeOutcome({
    required this.isCorrect,
    this.correctAnswer,
    this.reason,
  });

  final bool isCorrect;

  /// 正确答案。做错的题尤其需要——孩子重做时可以直接对照。
  final String? correctAnswer;

  /// 模型给出的简短理由，展示在确认页帮助家长复核。
  final String? reason;

  String get gradeResult => isCorrect ? 'correct' : 'wrong';
}

/// 批改失败。保留这个名字是因为调用方和测试都在用它；实现和 [DeepSeekException]
/// 是同一个东西——网络、鉴权、解析的失败原因都由客户端统一措辞。
typedef GradeException = DeepSeekException;

/// 用 DeepSeek 的视觉模型批改一道题。
///
/// 为什么走模型而不是传统的答案比对：题目是**手写**在纸上的，答案也是手写的，
/// 而且题型五花八门（计算、填空、应用题）。要对上答案得先有一份标准答案，这里
/// 没有。视觉模型能同时看见题干和孩子写的答案，直接判断对错并给出正确答案。
///
/// 用的是 `deepseek-flash`，它是多模态的（见
/// https://api-docs.deepseek.com/zh-cn/guides/vision/）。
class DeepSeekGrader {
  DeepSeekGrader({
    required String apiKey,
    String model = 'deepseek-flash',
    String? endpoint,
    Duration? timeout,
  }) : _client = DeepSeekClient(
         apiKey: apiKey,
         model: model,
         endpoint: endpoint ?? 'https://api.deepseek.com/chat/completions',
         timeout: timeout,
       );

  final DeepSeekClient _client;

  static const maxImageBytes = DeepSeekClient.maxImageBytes;

  /// 批改一道题。[imageBytes] 是切出来的那道题（含孩子的手写答案）。
  Future<GradeOutcome> grade({
    required Uint8List imageBytes,
    required int grade,
    String? subject,
  }) async {
    final reply = await _client.chatWithImage(
      prompt: _prompt(grade: grade, subject: subject),
      imageBytes: imageBytes,
      // 手写字要看清笔迹，low 会缩到 512×512，不够。
      detail: 'high',
    );
    return parseResponse(reply);
  }

  /// 解析模型的响应。
  ///
  /// 单独暴露出来是为了能在离线状态下测——这段逻辑要处理模型不听话的各种情况
  /// （加了解释、包了代码围栏、字段名写错），比网络调用更需要测试。
  static GradeOutcome parseResponse(String raw) {
    final content = DeepSeekClient.extractContent(raw);
    final decoded = DeepSeekClient.firstJsonObject(content);
    if (decoded == null) {
      throw GradeException('模型返回的内容看不懂');
    }

    final correct = decoded['correct'];
    final isCorrect = correct is bool
        ? correct
        : correct?.toString().toLowerCase() == 'true';

    String? clean(Object? value) {
      if (value == null) return null;
      final text = value.toString().trim();
      return text.isEmpty ? null : text;
    }

    return GradeOutcome(
      isCorrect: isCorrect,
      correctAnswer: clean(
        decoded['correctAnswer'] ?? decoded['correct_answer'],
      ),
      reason: clean(decoded['reason']),
    );
  }

  String _prompt({required int grade, String? subject}) {
    final gradeText = switch (grade) {
      <= 6 => '小学${_cn(grade)}年级',
      <= 9 => '初中${_cn(grade - 6)}年级',
      _ => '高中${_cn(grade - 9)}年级',
    };
    final subjectText = (subject == null || subject.isEmpty)
        ? ''
        : '这应该是$subject题。';

    return '''
你是批改作业的老师。图片是一道题的照片，上面有题目和学生的**手写答案**。

学生情况：$gradeText。$subjectText

请判断学生这道题**做对了还是做错了**，并按下面的 JSON 格式回答，不要输出别的内容：

{
  "correct": true 或 false,
  "correctAnswer": "这道题的正确答案",
  "reason": "一句话说明判断依据"
}

判断要求：
1. 仔细辨认学生的手写答案。字迹潦草时结合上下文推断，不要因为看不清就判错。
2. 如果学生没有作答、或者答案被涂改得无法辨认，correct 填 false，并在 reason 里说明。
3. correctAnswer 要给出**这道题本身**的正确答案（不是学生的答案）。
   如果题目有多个空，把每个空的答案都写出来。
4. 只判断对错，不要重新出题，不要评价学生。
''';
  }

  String _cn(int n) => const [
    '',
    '一',
    '二',
    '三',
    '四',
    '五',
    '六',
  ].elementAt(n.clamp(0, 6));
}

/// 从磁盘读一张题图，读不到就抛 [GradeException]。
Future<Uint8List> readQuestionImage(String path) async {
  final file = File(path);
  if (!file.existsSync()) {
    throw GradeException('找不到题目图片');
  }
  return file.readAsBytes();
}
