import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:octopus/services/deepseek_variants.dart';

/// 变式题的响应解析。
///
/// 模型可能少给一道、把 text 写成 question、或者返回一个裸数组，这些都要处理，
/// 而且都能离线测。
void main() {
  String envelope(String content) => jsonEncode({
    'choices': [
      {
        'message': {'role': 'assistant', 'content': content},
      },
    ],
  });

  test('标准响应', () {
    final variants = DeepSeekVariants.parseVariants(
      envelope(
        '{"variants": ['
        '{"text": "小明有 7 个苹果，又买了 4 个，一共几个？", "answer": "11 个"},'
        '{"text": "小明有 9 支铅笔，用掉 3 支，还剩几支？", "answer": "6 支"}'
        ']}',
      ),
    );
    expect(variants.length, 2);
    expect(variants.first.text, contains('7 个苹果'));
    expect(variants.first.answer, '11 个');
  });

  test('字段名写成 question 也认', () {
    final variants = DeepSeekVariants.parseVariants(
      envelope('{"variants": [{"question": "题目一", "answer": "答案一"}]}'),
    );
    expect(variants.single.text, '题目一');
  });

  test('没有 answer 的题也保留，只是答案为空', () {
    final variants = DeepSeekVariants.parseVariants(
      envelope('{"variants": [{"text": "一道没有答案的题"}]}'),
    );
    expect(variants.single.text, '一道没有答案的题');
    expect(variants.single.answer, isNull);
  });

  test('答案写成空白串归一成 null', () {
    final variants = DeepSeekVariants.parseVariants(
      envelope('{"variants": [{"text": "题目", "answer": "   "}]}'),
    );
    expect(variants.single.answer, isNull);
  });

  test('缺文字的条目直接跳过，而不是塞一道空题', () {
    final variants = DeepSeekVariants.parseVariants(
      envelope(
        '{"variants": ['
        '{"text": ""},'
        '{"answer": "只有答案"},'
        '{"text": "唯一完整的一道", "answer": "答案"}'
        ']}',
      ),
    );
    expect(variants.length, 1);
    expect(variants.single.text, '唯一完整的一道');
  });

  test('带代码围栏和解释也能解析', () {
    final variants = DeepSeekVariants.parseVariants(
      envelope(
        '好的：\n```json\n{"variants": [{"text": "换过数字的题", "answer": "42"}]}\n```',
      ),
    );
    expect(variants.single.text, '换过数字的题');
  });

  test('variants 不是数组时报错', () {
    expect(
      () => DeepSeekVariants.parseVariants(envelope('{"variants": "没有"}')),
      throwsA(isA<Exception>()),
    );
  });

  test('所有条目都无效时报错，而不是返回空列表让界面显示空白', () {
    expect(
      () => DeepSeekVariants.parseVariants(envelope('{"variants": []}')),
      throwsA(isA<Exception>()),
    );
  });

  test('完全不是 JSON 时报错', () {
    expect(
      () => DeepSeekVariants.parseVariants(envelope('我出了几道题，但是不告诉你。')),
      throwsA(isA<Exception>()),
    );
  });

  test('题干里的引号和换行不会破坏解析', () {
    final inner = jsonEncode({
      'variants': [
        {'text': '集合 {1, 2} 中的 "2" 是什么？\n请说明理由。', 'answer': '是 2'},
      ],
    });
    final variants = DeepSeekVariants.parseVariants(envelope(inner));
    expect(variants.single.text, contains('{1, 2}'));
    expect(variants.single.text, contains('\n'));
  });

  test('没有 API Key 时立即失败，不发请求', () async {
    final service = DeepSeekVariants(apiKey: '');
    await expectLater(
      service.fromText(question: '一道题', grade: 4),
      throwsA(isA<Exception>()),
    );
  });

  test('题干为空时直接报错，不浪费一次请求', () async {
    final service = DeepSeekVariants(apiKey: 'sk-test');
    await expectLater(
      service.fromText(question: '   ', grade: 4),
      throwsA(isA<Exception>()),
    );
  });
}
