import 'dart:ui';

import 'deepseek_client.dart';
import 'question_splitter.dart';

/// 模型从整页里读出的一道题。
class PageQuestion {
  const PageQuestion({
    required this.box,
    required this.text,
    required this.isCorrect,
    this.correctAnswer,
    this.reason,
    this.subject,
    this.knowledgePoints = const [],
  });

  /// 归一化坐标（0..1）。
  final Rect box;
  final String text;
  final bool isCorrect;
  final String? correctAnswer;
  final String? reason;
  final String? subject;
  final List<String> knowledgePoints;

  String get gradeResult => isCorrect ? 'correct' : 'wrong';

  String? get knowledgeTags =>
      knowledgePoints.isEmpty ? null : knowledgePoints.join('、');

  PageQuestion copyWith({Rect? box}) => PageQuestion(
    box: box ?? this.box,
    text: text,
    isCorrect: isCorrect,
    correctAnswer: correctAnswer,
    reason: reason,
    subject: subject,
    knowledgePoints: knowledgePoints,
  );
}

/// 一次整页分析的结果。
class PageAnalysis {
  const PageAnalysis({required this.questions, required this.raw});

  final List<PageQuestion> questions;

  /// 模型原文，排查问题时用。
  final String raw;
}

/// 整页交给模型：一次调用同时完成**切题和批改**。
///
/// 为什么不用几何算法切题：几何切题只看行距和行首数字，**看不懂内容**。一道题
/// 内部的分条、应用题的多行、题号和正文被识别成两行，都会让它切错。而且它错了
/// 之后没有任何补救——切不出来就是漏题。
///
/// 模型能读懂整页，知道哪里是一道题的结尾，也知道哪一行是学生的答案。代价是
/// **它报坐标不准**，所以结果还要用 ML Kit 的文字行对齐，见 [snapToLines]。
class DeepSeekPageAnalyzer {
  DeepSeekPageAnalyzer({required String apiKey, String? model})
    : _client = DeepSeekClient(
        apiKey: apiKey,
        model: model ?? 'deepseek-flash',
      );

  final DeepSeekClient _client;

  Future<PageAnalysis> analyze({
    required List<int> imageBytes,
    required int grade,
    String? subject,
  }) async {
    final reply = await _client.chatWithImage(
      prompt: buildPrompt(grade: grade, subject: subject),
      imageBytes: imageBytes,
      // 要看清手写答案，也要看清题号；low 会缩到 512×512，不够。
      detail: 'high',
    );
    return parseAnalysis(reply);
  }

  /// 解析模型的整页返回。单独暴露以便离线测试。
  static PageAnalysis parseAnalysis(String raw) {
    final content = DeepSeekClient.extractContent(raw);
    final decoded = DeepSeekClient.firstJsonObject(content);
    if (decoded == null) {
      throw DeepSeekException('模型返回的内容看不懂');
    }

    final list = decoded['questions'];
    if (list is! List) {
      throw DeepSeekException('模型没有返回题目列表');
    }

    final questions = <PageQuestion>[];
    for (final item in list) {
      if (item is! Map) continue;
      final box = _parseBox(item['box'] ?? item['bbox'] ?? item['rect']);
      if (box == null) continue;
      if (box.width < 0.02 || box.height < 0.01) continue;

      final text = (item['text'] ?? item['question'] ?? '').toString().trim();
      final correct = item['correct'];
      final isCorrect = correct is bool
          ? correct
          : correct?.toString().toLowerCase() == 'true';

      questions.add(
        PageQuestion(
          box: box,
          text: text,
          isCorrect: isCorrect,
          correctAnswer: _clean(item['correctAnswer'] ?? item['correct_answer']),
          reason: _clean(item['reason']),
          subject: _clean(item['subject']),
          knowledgePoints: _parsePoints(
            item['knowledgePoints'] ?? item['knowledge_points'],
          ),
        ),
      );
    }

    if (questions.isEmpty) {
      throw DeepSeekException('没有从这一页里读出一道题');
    }
    // 按纵向位置排序，保证和纸面上的顺序一致。
    questions.sort((a, b) => a.box.top.compareTo(b.box.top));
    return PageAnalysis(questions: questions, raw: content);
  }

  /// 解析坐标。
  ///
  /// 提示词里要求的是 **0–1000 的相对坐标**，不是像素——模型对相对位置的判断
  /// 明显比绝对像素准。但也可能返回 0–1 的小数或别的尺度，所以这里统一归一化。
  static Rect? _parseBox(Object? value) {
    if (value is! List || value.length < 4) return null;
    final nums = <double>[];
    for (final v in value.take(4)) {
      final d = v is num ? v.toDouble() : double.tryParse(v.toString());
      if (d == null) return null;
      nums.add(d);
    }

    // 判断尺度：只要有一个值大于 1，就认为用的是 0–1000。
    final scale = nums.any((n) => n > 1.0) ? 1000.0 : 1.0;
    var (x0, y0, x1, y1) = (
      nums[0] / scale,
      nums[1] / scale,
      nums[2] / scale,
      nums[3] / scale,
    );

    // 模型偶尔会把顺序写反。
    if (x1 < x0) (x0, x1) = (x1, x0);
    if (y1 < y0) (y0, y1) = (y1, y0);

    final rect = Rect.fromLTRB(
      x0.clamp(0.0, 1.0),
      y0.clamp(0.0, 1.0),
      x1.clamp(0.0, 1.0),
      y1.clamp(0.0, 1.0),
    );
    if (rect.width <= 0 || rect.height <= 0) return null;
    return rect;
  }

  static List<String> _parsePoints(Object? value) {
    if (value == null) return const [];
    if (value is List) {
      return [
        for (final item in value)
          if (_clean(item) != null) _clean(item)!,
      ];
    }
    final text = _clean(value);
    if (text == null) return const [];
    return text
        .split(RegExp(r'[、,，;；]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  static String? _clean(Object? value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static String buildPrompt({required int grade, String? subject}) {
    final gradeText = switch (grade) {
      <= 6 => '小学${_cn(grade)}年级',
      <= 9 => '初中${_cn(grade - 6)}年级',
      _ => '高中${_cn(grade - 9)}年级',
    };
    final subjectText = (subject == null || subject.isEmpty)
        ? ''
        : '这应该是$subject题。';

    return '''
图片是一整页学生作业或试卷的照片，上面有**多道题**和学生的**手写答案**。

学生情况：$gradeText。$subjectText

请你**一次完成两件事**：把这页切成一道一道的题，并逐题批改。

按下面的 JSON 格式回答，不要输出别的内容：

{
  "questions": [
    {
      "box": [x0, y0, x1, y1],
      "text": "这道题的完整题干",
      "correct": true 或 false,
      "correctAnswer": "这道题的正确答案",
      "reason": "一句话说明判断依据",
      "subject": "数学",
      "knowledgePoints": ["知识点1", "知识点2"]
    }
  ]
}

关于 box 坐标：
- 用 **0 到 1000 的相对坐标**，不是像素。(0,0) 是图片左上角，(1000,1000) 是右下角。
- box 要**紧紧包住这一道题**：从题号开始，到这道题最后一个字结束。
- **不要把两道题放进同一个 box**，也不要一道题拆成两个 box。
- 学生写在题目旁边或下面的解答、算式、涂改，属于这道题，要包进去。
- 相邻两道题的 box 不要重叠。

关于切题：
- 题号（如「1.」「（2）」「一、」「第3题」）是题目边界，**每见到一个新题号就开一个新的 box**。
- 「（1）（2）（3）」这种小题号，如果属于同一道大题的多个小问，算**同一道题**，
  放在同一个 box 里。
- 「一、填空题」「二、选择题」这类**大题标题**，单独成一道题，text 里保留标题文字。
- 图片里如果有图形、表格，属于包含它的那道题。

关于批改：
- 仔细辨认学生的手写答案，字迹潦草时结合上下文推断，不要因为看不清就判错。
- 学生没作答或答案涂改得无法辨认时，correct 填 false，并在 reason 里说明。
- correctAnswer 给出**这道题本身**的正确答案（不是学生的答案），多个空就都写出来。
- reason 要说清依据，例如「竖式第二行忘了进位」而不是「算错了」。
- subject 从这几个里选：语文、数学、英语、科学、道德与法治、其他。
- knowledgePoints 给 1–3 个，具体到能拿来出同类题。

没有题目的空白区域不要放进 questions。一张题都识别不出来时，questions 填空数组。
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

/// 用 ML Kit 的文字行把模型给的边界「吸附」到真实文字上。
///
/// **为什么需要这一步**：模型报的坐标是猜的，经常差几十个像素，直接用会把字切
/// 掉半行或者多带一块空白。而 ML Kit 给的是**真实的文字行位置**。
///
/// 做法：把中心落在模型框内的文字行取并集，用这个并集当最终边界。这样
/// **「哪几行属于这道题」由模型判断（懂内容），「边界画在哪」由文字位置决定
/// （不会切字）**。
///
/// 一个文字行都没落在框里时保留模型原框——总比丢掉这道题强。
List<PageQuestion> snapToLines({
  required List<PageQuestion> questions,
  required List<PageLine> lines,
  required Size pageSize,
  double grow = 0.012,
}) {
  if (lines.isEmpty || pageSize.width <= 0 || pageSize.height <= 0) {
    return questions;
  }

  return [
    for (final question in questions)
      question.copyWith(box: _snapOne(question.box, lines, pageSize, grow)),
  ];
}

Rect _snapOne(Rect box, List<PageLine> lines, Size pageSize, double grow) {
  var union = const Rect.fromLTRB(1, 1, 0, 0);
  var found = false;

  for (final line in lines) {
    final center = Offset(
      line.box.center.dx / pageSize.width,
      line.box.center.dy / pageSize.height,
    );
    // 判断用中心点：一行横跨两个框时，归给中心所在的那个才符合直觉。
    if (!box.contains(center)) continue;

    final lineRect = Rect.fromLTRB(
      line.box.left / pageSize.width,
      line.box.top / pageSize.height,
      line.box.right / pageSize.width,
      line.box.bottom / pageSize.height,
    );
    union = found ? union.expandToInclude(lineRect) : lineRect;
    found = true;
  }

  if (!found) return box;

  // 纵向留一点余量，免得把字的上下缘切掉；横向也稍微放宽一点。
  return Rect.fromLTRB(
    (union.left - grow).clamp(0.0, 1.0),
    (union.top - grow).clamp(0.0, 1.0),
    (union.right + grow).clamp(0.0, 1.0),
    (union.bottom + grow).clamp(0.0, 1.0),
  );
}
