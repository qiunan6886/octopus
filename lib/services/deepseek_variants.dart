import 'deepseek_client.dart';

/// 生成出来的一道变式题。
class Variant {
  const Variant({required this.text, this.answer});

  final String text;

  /// 参考答案。孩子做完之后家长可以对照。
  final String? answer;
}

/// 按一道错题生成同知识点、同难度的新题。
///
/// 变式题的价值在于**换个数字或换个情境再练一遍**，而不是原题重做——原题重做
/// 孩子可能在背答案。所以提示词里明确要求保持知识点和难度、只换表面。
class DeepSeekVariants {
  DeepSeekVariants({required String apiKey, String? model})
    : _client = DeepSeekClient(
        apiKey: apiKey,
        model: model ?? 'deepseek-flash',
      );

  final DeepSeekClient _client;

  /// 从题干文字生成。
  ///
  /// 优先走这条路：便宜、快，而且文字是已经校对过的。
  Future<List<Variant>> fromText({
    required String question,
    required int grade,
    String? subject,
    int count = 3,
  }) async {
    if (question.trim().isEmpty) {
      throw DeepSeekException('这道题还没有题干文字，先生成文字或改用图片');
    }
    final reply = await _client.chatJsonOnly(_prompt(
      grade: grade,
      subject: subject,
      count: count,
      source: '题目原文：\n$question',
    ));
    return parseVariants(reply);
  }

  /// 从题目图片生成，给还没识别出文字的题用。
  Future<List<Variant>> fromImage({
    required List<int> imageBytes,
    required int grade,
    String? subject,
    int count = 3,
  }) async {
    final reply = await _client.chatWithImage(
      prompt: _prompt(
        grade: grade,
        subject: subject,
        count: count,
        source: '题目在图片里，请先读懂题目，再出变式题。',
      ),
      imageBytes: imageBytes,
      detail: 'high',
    );
    return parseVariants(reply);
  }

  /// 解析模型返回的变式题。
  ///
  /// 单独暴露是为了能离线测——模型可能少给一道、把 text 写成 question、
  /// 或者干脆返回一个裸数组。
  static List<Variant> parseVariants(String raw) {
    final decoded = DeepSeekClient.firstJsonObject(
      DeepSeekClient.extractContent(raw),
    );
    final list = decoded?['variants'];
    if (list is! List) {
      throw DeepSeekException('模型没有返回变式题');
    }

    final variants = <Variant>[];
    for (final item in list) {
      if (item is! Map) continue;
      final text = (item['text'] ?? item['question'] ?? item['content'])
          ?.toString()
          .trim();
      if (text == null || text.isEmpty) continue;
      final answer = item['answer']?.toString().trim();
      variants.add(
        Variant(
          text: text,
          answer: (answer == null || answer.isEmpty) ? null : answer,
        ),
      );
    }

    if (variants.isEmpty) {
      throw DeepSeekException('模型返回的变式题是空的');
    }
    return variants;
  }

  static String _prompt({
    required int grade,
    String? subject,
    required int count,
    required String source,
  }) {
    final gradeText = switch (grade) {
      <= 6 => '小学${_cn(grade)}年级',
      <= 9 => '初中${_cn(grade - 6)}年级',
      _ => '高中${_cn(grade - 9)}年级',
    };
    final subjectText = (subject == null || subject.isEmpty)
        ? ''
        : '科目：$subject。';

    return '''
你是一位$gradeText的数学/语文老师。$subjectText

请根据下面这道题，出 $count 道**变式题**——同一个知识点、同一个难度，
但换掉数字、情境或问法。目的是让孩子再练一遍这个知识点，而不是背原题的答案。

$source

按下面的 JSON 格式回答，不要输出别的内容：

{
  "variants": [
    {"text": "第一道变式题的完整题干", "answer": "参考答案"},
    {"text": "第二道变式题的完整题干", "answer": "参考答案"}
  ]
}

要求：
1. 每道题必须是**完整可做的**，孩子拿到就能做，不需要看原题。
2. 知识点和难度与原题一致，不要拔高也不要降低。
3. 数字要换掉。原题是应用题就换个情境（比如把「苹果」换成「铅笔」）。
4. answer 要给出正确答案，计算题给出结果，应用题给出完整解答的关键步骤。
5. **不要复制原题**。如果原题本身已经很特殊、换不了，就换一个角度问同一个知识点。
6. 题干里如果涉及图形，用文字描述清楚（例如「一个长 8 厘米、宽 5 厘米的长方形」），
   不要依赖图片。
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
