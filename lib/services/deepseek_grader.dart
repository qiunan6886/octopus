import 'dart:io';
import 'dart:typed_data';

import 'deepseek_client.dart';

/// 批改结果。
class GradeOutcome {
  const GradeOutcome({
    required this.isCorrect,
    this.correctAnswer,
    this.reason,
    this.subject,
    this.knowledgePoints = const [],
  });

  final bool isCorrect;

  /// 正确答案。做错的题尤其需要——孩子重做时可以直接对照。
  final String? correctAnswer;

  /// 模型给出的判断依据。
  ///
  /// 这个字段存在的意义是**让家长能核对 AI 判得对不对**。只给一个「错」字，
  /// 家长没法判断是孩子错了还是模型看错了。
  final String? reason;

  /// 学科，如「数学」。批改时模型已经看过题目了，顺手识别出来。
  ///
  /// 有了它错题库才能按科目筛选，也才谈得上按科目统计正确率。
  final String? subject;

  /// 知识点，如「两位数乘法」「进位」。
  final List<String> knowledgePoints;

  String get gradeResult => isCorrect ? 'correct' : 'wrong';

  /// 知识点拼成一行存库。
  String? get knowledgeTags =>
      knowledgePoints.isEmpty ? null : knowledgePoints.join('、');
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

    // 知识点可能是数组，也可能被写成顿号分隔的字符串，两种都收。
    final rawPoints =
        decoded['knowledgePoints'] ??
        decoded['knowledge_points'] ??
        decoded['knowledgeTags'];
    final points = <String>[];
    if (rawPoints is List) {
      for (final item in rawPoints) {
        final text = clean(item);
        if (text != null) points.add(text);
      }
    } else {
      final text = clean(rawPoints);
      if (text != null) {
        points.addAll(
          text.split(RegExp(r'[、,，;；]')).map((s) => s.trim()).where(
            (s) => s.isNotEmpty,
          ),
        );
      }
    }

    return GradeOutcome(
      isCorrect: isCorrect,
      correctAnswer: clean(
        decoded['correctAnswer'] ?? decoded['correct_answer'],
      ),
      reason: clean(decoded['reason']),
      subject: clean(decoded['subject']),
      knowledgePoints: points,
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

请完成三件事：判断对错、给出正确答案、识别这道题的学科和知识点。
按下面的 JSON 格式回答，不要输出别的内容：

{
  "correct": true 或 false,
  "correctAnswer": "这道题的正确答案",
  "reason": "一句话说明判断依据",
  "subject": "数学",
  "knowledgePoints": ["知识点1", "知识点2"]
}

判断要求：
1. 仔细辨认学生的手写答案。字迹潦草时结合上下文推断，不要因为看不清就判错。
2. 如果学生没有作答、或者答案被涂改得无法辨认，correct 填 false，并在 reason 里说明。
3. correctAnswer 要给出**这道题本身**的正确答案（不是学生的答案）。
   如果题目有多个空，把每个空的答案都写出来。
4. **reason 要说清判断依据**，例如「竖式第二行忘了进位」而不是只写「算错了」。
   家长要靠这句话核对你的判断，所以它必须具体。
5. subject 从这几个里选：语文、数学、英语、科学、道德与法治、其他。
6. knowledgePoints 给 1–3 个，具体到能拿来出同类题，
   例如「两位数乘一位数·进位」而不是「乘法」。
7. 只判断对错和分类，不要重新出题，不要评价学生。
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
