import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:octopus/services/deepseek_grader.dart';

/// 批改响应的解析。
///
/// 这段逻辑要对付模型的各种不听话：加解释、包代码围栏、字段名写成下划线、
/// 把布尔值写成字符串。它比网络调用更值得测，而且完全离线可测。
void main() {
  String envelope(String content) => jsonEncode({
    'choices': [
      {
        'message': {'role': 'assistant', 'content': content},
      },
    ],
  });

  test('标准响应', () {
    final outcome = DeepSeekGrader.parseResponse(
      envelope('{"correct": false, "correctAnswer": "42", "reason": "算错了进位"}'),
    );
    expect(outcome.isCorrect, isFalse);
    expect(outcome.gradeResult, 'wrong');
    expect(outcome.correctAnswer, '42');
    expect(outcome.reason, '算错了进位');
  });

  test('判对', () {
    final outcome = DeepSeekGrader.parseResponse(
      envelope('{"correct": true, "correctAnswer": "8", "reason": "正确"}'),
    );
    expect(outcome.isCorrect, isTrue);
    expect(outcome.gradeResult, 'correct');
  });

  test('模型加了代码围栏和解释文字，仍能解析', () {
    final outcome = DeepSeekGrader.parseResponse(
      envelope(
        '好的，我来判断一下：\n```json\n'
        '{"correct": false, "correctAnswer": "7", "reason": "少算了一步"}\n'
        '```\n以上。',
      ),
    );
    expect(outcome.isCorrect, isFalse);
    expect(outcome.correctAnswer, '7');
  });

  test('字段名写成下划线也认', () {
    final outcome = DeepSeekGrader.parseResponse(
      envelope('{"correct": false, "correct_answer": "12", "reason": "错"}'),
    );
    expect(outcome.correctAnswer, '12');
  });

  test('布尔值写成字符串也认', () {
    expect(
      DeepSeekGrader.parseResponse(envelope('{"correct": "true"}')).isCorrect,
      isTrue,
    );
    expect(
      DeepSeekGrader.parseResponse(envelope('{"correct": "false"}')).isCorrect,
      isFalse,
    );
  });

  test('答案里带花括号和引号不会截断解析', () {
    final outcome = DeepSeekGrader.parseResponse(
      envelope(
        '{"correct": false, "correctAnswer": "集合 {1, 2} 里的 \\"2\\"", "reason": "漏了"}',
      ),
    );
    expect(outcome.correctAnswer, contains('{1, 2}'));
    expect(outcome.correctAnswer, contains('"2"'));
  });

  test('空字符串的答案归一成 null', () {
    final outcome = DeepSeekGrader.parseResponse(
      envelope('{"correct": true, "correctAnswer": "", "reason": "  "}'),
    );
    expect(outcome.correctAnswer, isNull);
    expect(outcome.reason, isNull);
  });

  test('直接给裸对象（没有 choices 包装）也能解析', () {
    final outcome = DeepSeekGrader.parseResponse(
      '{"correct": true, "correctAnswer": "5"}',
    );
    expect(outcome.isCorrect, isTrue);
    expect(outcome.correctAnswer, '5');
  });

  test('完全看不懂的内容会报错，而不是当成判对', () {
    expect(
      () => DeepSeekGrader.parseResponse(envelope('我判断这道题是对的。')),
      throwsA(isA<GradeException>()),
    );
  });

  test('解析出学科和知识点', () {
    final outcome = DeepSeekGrader.parseResponse(
      envelope(
        '{"correct": false, "correctAnswer": "42", "reason": "竖式第二行忘了进位",'
        '"subject": "数学", "knowledgePoints": ["两位数乘一位数", "进位"]}',
      ),
    );
    expect(outcome.subject, '数学');
    expect(outcome.knowledgePoints, ['两位数乘一位数', '进位']);
    expect(outcome.knowledgeTags, '两位数乘一位数、进位');
    expect(outcome.reason, '竖式第二行忘了进位');
  });

  test('知识点写成顿号分隔的字符串也认', () {
    final outcome = DeepSeekGrader.parseResponse(
      envelope('{"correct": true, "knowledgePoints": "分数加法、通分"}'),
    );
    expect(outcome.knowledgePoints, ['分数加法', '通分']);
  });

  test('知识点写成下划线字段名或 knowledgeTags 也认', () {
    expect(
      DeepSeekGrader.parseResponse(
        envelope('{"correct": true, "knowledge_points": ["A", "B"]}'),
      ).knowledgePoints,
      ['A', 'B'],
    );
    expect(
      DeepSeekGrader.parseResponse(
        envelope('{"correct": true, "knowledgeTags": ["C"]}'),
      ).knowledgePoints,
      ['C'],
    );
  });

  test('知识点里的空条目被剔掉', () {
    final outcome = DeepSeekGrader.parseResponse(
      envelope('{"correct": true, "knowledgePoints": ["A", "", "  ", "B"]}'),
    );
    expect(outcome.knowledgePoints, ['A', 'B']);
  });

  test('没有学科知识点时为 null / 空，而不是报错', () {
    final outcome = DeepSeekGrader.parseResponse(
      envelope('{"correct": true, "correctAnswer": "8"}'),
    );
    expect(outcome.subject, isNull);
    expect(outcome.knowledgePoints, isEmpty);
    expect(outcome.knowledgeTags, isNull);
  });

  test('没有 API Key 时立即报错，不发请求', () async {
    final grader = DeepSeekGrader(apiKey: '  ');
    expect(
      () => grader.grade(imageBytes: Uint8List(0), grade: 4),
      throwsA(
        isA<GradeException>().having(
          (e) => e.message,
          'message',
          contains('API Key'),
        ),
      ),
    );
  });

  test('图片过大时拒绝，不浪费一次请求', () async {
    final grader = DeepSeekGrader(apiKey: 'sk-test');
    expect(
      () => grader.grade(
        imageBytes: Uint8List(DeepSeekGrader.maxImageBytes + 1),
        grade: 4,
      ),
      throwsA(isA<GradeException>()),
    );
  });
}
