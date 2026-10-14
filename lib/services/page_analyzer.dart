import 'dart:math' as math;
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
- **不要把两道题放进同一个 box**，也不要一道题拆成两个 box。
- 学生写在题目旁边或下面的解答、算式、涂改，属于这道题，要包进去。
- 相邻两道题的 box 不要重叠。

关于 box 的左右边界——**这一点很重要，请特别注意**：
- 试卷的版面是**分栏**的，同一栏里的题目**上下对齐**：左边距一样，右边距也一样。
- 所以**同一栏里所有题目的 box，左边 x0 应当几乎相同，右边 x1 也应当几乎相同**。
- 把 box 画到**这一栏的宽度**，不要只框到文字结束的地方。文字短的那一题，
  box 的右边也要和上下相邻的题目对齐，把右边留白一起包进来。
- 量一下：假设一栏从 x0=100 到 x1=900，那么这一栏里每一道题的 box 都应该是
  从 100 到 900，不管这题的文字只占左边一半还是写满整行。
- 只有确实**缩进**的题目（比如大题下面的小问「（1）（2）」）才允许左边距不同，
  而且同一层级的小问之间仍然要互相对齐。
- 如果整页只有一栏，那就所有题目共用同一个左右边距。

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

/// 用「试卷题目上下对齐」这条版面规律把框拉齐。
///
/// 同一栏里的题目共用一个左边距和一个右边距——这是试卷排版的基本特点。所以所有
/// 框的左右边缘本来就**应当几乎相同**，不同的那些多半是模型报歪了。
///
/// 于是可以用**中位数**当基准：偏离小的拉回来，偏离大的不动。
///
/// **为什么偏差大的不动**：真正缩进的题目是存在的（大题下面的「（1）（2）」小问），
/// 强行拉齐会把它们的框盖到别的题上。这条规则只该用来**去噪声，不该覆盖信号**。
///
/// 用中位数而不是平均值：个别歪得离谱的框不该把基准带偏。
List<PageQuestion> alignBoxColumns(
  List<PageQuestion> questions, {
  double tolerance = 0.12,
}) {
  if (questions.length < 3) return questions;

  final lefts = questions.map((q) => q.box.left).toList()..sort();
  final rights = questions.map((q) => q.box.right).toList()..sort();
  final medianLeft = _median(lefts);
  final medianRight = _median(rights);

  return [
    for (final question in questions)
      question.copyWith(
        box: Rect.fromLTRB(
          (question.box.left - medianLeft).abs() <= tolerance
              ? medianLeft
              : question.box.left,
          question.box.top,
          (question.box.right - medianRight).abs() <= tolerance
              ? medianRight
              : question.box.right,
          question.box.bottom,
        ),
      ),
  ];
}

/// 中位数。
///
/// 偶数个样本时取**中间两个的平均**，而不是直接取上中位——后者会被单个样本
/// 带偏（例如 [0.10, 0.10, 0.11, 0.95] 取上中位会得到 0.11）。
double _median(List<double> sorted) {
  if (sorted.isEmpty) return 0;
  final mid = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[mid];
  return (sorted[mid - 1] + sorted[mid]) / 2;
}

/// 用 ML Kit 的文字行把模型给的边界「吸附」到真实文字上。
///
/// **为什么需要这一步**：模型报的坐标是猜的，经常差几十个像素。而 ML Kit 给的
/// 是**真实的文字行位置**。
///
/// 混合的分工是：**「哪几行属于这道题」由模型判断（懂内容），「边界画在哪」由
/// 文字位置决定（不会切字）**。
///
/// 两个关键细节：
///
/// 1. **归属按重叠比例判断，不是「中心是否在框内」**。模型给的框经常短一点点，
///    这时最后一行只有一部分落在框里——按中心判断会把这一行丢掉，于是**这道题
///    的尾巴被切掉**。按重叠比例就容忍了这种偏差。
///
/// 2. **一行被两个框同时认领时，给重叠更多的那一个**。模型虽然被要求「相邻框
///    不要重叠」，但它做不到，直接取并集会让两道题都多出一块。
///
/// 一个文字行都没落进框里时保留模型原框——宁可位置不完美，也不能把题丢掉。
List<PageQuestion> snapToLines({
  required List<PageQuestion> questions,
  required List<PageLine> lines,
  required Size pageSize,
  double grow = 0.012,
  double minOverlap = 0.4,
}) {
  if (lines.isEmpty || pageSize.width <= 0 || pageSize.height <= 0) {
    return questions;
  }

  // 归一化一次，后面反复用。
  final normalized = [
    for (final line in lines)
      _NormLine(
        box: Rect.fromLTRB(
          line.box.left / pageSize.width,
          line.box.top / pageSize.height,
          line.box.right / pageSize.width,
          line.box.bottom / pageSize.height,
        ),
      ),
  ];

  // 每行选出重叠比例最高的那个框。用「先算所有权、再分配」而不是边扫边塞，
  // 才能处理一行同时落在两个框里的情况。
  final owner = List<int>.filled(normalized.length, -1);
  final bestRatio = List<double>.filled(normalized.length, 0);

  for (var q = 0; q < questions.length; q++) {
    for (var i = 0; i < normalized.length; i++) {
      final ratio = _overlapRatio(normalized[i].box, questions[q].box);
      if (ratio >= minOverlap && ratio > bestRatio[i]) {
        bestRatio[i] = ratio;
        owner[i] = q;
      }
    }
  }

  final result = <PageQuestion>[];
  for (var q = 0; q < questions.length; q++) {
    var union = const Rect.fromLTRB(1, 1, 0, 0);
    var found = false;
    for (var i = 0; i < normalized.length; i++) {
      if (owner[i] != q) continue;
      union = found ? union.expandToInclude(normalized[i].box) : normalized[i].box;
      found = true;
    }

    if (!found) {
      // 没有行认领这个框：保留模型原框。可能是一张纯图形的题，
      // 也可能模型框错了，但丢掉一定更糟。
      result.add(questions[q]);
      continue;
    }

    result.add(
      questions[q].copyWith(
        box: Rect.fromLTRB(
          // 横向：取文字行和模型框的**并集**，也就是只扩不缩。
          //
          // 模型是被明确要求「把框画到这一栏的宽度」的（试卷题目上下对齐，
          // 共用一个右边距）。如果这里按文字行的宽度收紧，文字短的那道题就会
          // 被缩成一条——恰好把模型做对的事情毁掉。宁可多带一点右边留白。
          (math.min(union.left, questions[q].box.left) - grow).clamp(0.0, 1.0),
          (union.top - grow).clamp(0.0, 1.0),
          (math.max(union.right, questions[q].box.right) + grow).clamp(0.0, 1.0),
          (union.bottom + grow).clamp(0.0, 1.0),
        ),
      ),
    );
  }

  return _separateOverlaps(result);
}

class _NormLine {
  const _NormLine({required this.box});

  final Rect box;
}

/// [inner] 有多大比例落在 [outer] 里，按面积算。
///
/// 用面积而不是高度，是因为横向也可能只落进来一半（模型框窄了）。
double _overlapRatio(Rect inner, Rect outer) {
  final intersection = inner.intersect(outer);
  if (intersection.width <= 0 || intersection.height <= 0) return 0;
  final area = inner.width * inner.height;
  if (area <= 0) return 0;
  return (intersection.width * intersection.height) / area;
}

/// 让相邻的框不再重叠。
///
/// 模型被要求过「相邻 box 不要重叠」，但它做不到。重叠的后果是同一个区域出现在
/// 两道题里，打印出来会重复。
///
/// 处理方式是**在两者之间的空白正中切一刀**，切的落点取「上一题本来的下缘」和
/// 「下一题本来的上缘」的中点。
///
/// **不要额外留缝**。一开始我在切口两侧各留了 0.008 的间隙，结果下题的框被推进
/// 它自己第一行里——为了分开而切掉了内容。切在正中就既不重叠也不切字：上一题的
/// 最后一行在切口上方，下一题的第一行在下方。
List<PageQuestion> _separateOverlaps(List<PageQuestion> questions) {
  if (questions.length < 2) return questions;

  // 先按纵坐标排，保证「上一题 / 下一题」的关系成立。
  final sorted = [...questions]..sort((a, b) => a.box.top.compareTo(b.box.top));
  final out = [...sorted];

  for (var i = 0; i < out.length - 1; i++) {
    final current = out[i].box;
    final next = out[i + 1].box;
    if (current.bottom <= next.top) continue; // 本来就不重叠

    // 在上一题的下缘和下一题的上缘之间取中点。不能取两者中心的中间——
    // 那会把题目的内容切掉。
    final cut = (current.bottom + next.top) / 2;

    out[i] = out[i].copyWith(
      box: Rect.fromLTRB(current.left, current.top, current.right, cut),
    );
    out[i + 1] = out[i + 1].copyWith(
      box: Rect.fromLTRB(next.left, cut, next.right, next.bottom),
    );
  }

  return out;
}
