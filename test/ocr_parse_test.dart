import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:octopus/services/ocr_service.dart';

/// 云端 OCR 的响应解析。
///
/// 和批改一样，模型可能不按格式回答（加解释、包代码围栏、把 text 写成别的
/// 字段名），所以这段离线可测的逻辑值得单独覆盖。
void main() {
  String envelope(String content) => jsonEncode({
    'choices': [
      {
        'message': {'role': 'assistant', 'content': content},
      },
    ],
  });

  test('标准响应', () {
    expect(
      DeepSeekVisionOcrEngine.parseTextResponse(
        envelope('{"text": "一个长方形的长是 8 厘米，宽是 5 厘米。"}'),
      ),
      '一个长方形的长是 8 厘米，宽是 5 厘米。',
    );
  });

  test('多行题目保持换行', () {
    final text = DeepSeekVisionOcrEngine.parseTextResponse(
      envelope('{"text": "计算下列各题：\\n（1）12 + 5 =\\n（2）9 × 3 ="}'),
    );
    expect(text, contains('（1）'));
    expect(text, contains('\n'));
    expect(text!.split('\n').length, 3);
  });

  test('带代码围栏和解释文字也能解析', () {
    expect(
      DeepSeekVisionOcrEngine.parseTextResponse(
        envelope('好的：\n```json\n{"text": "3/4 + 1/4 ="}\n```'),
      ),
      '3/4 + 1/4 =',
    );
  });

  test('空字符串当成没读出来', () {
    expect(
      DeepSeekVisionOcrEngine.parseTextResponse(envelope('{"text": ""}')),
      isNull,
    );
    expect(
      DeepSeekVisionOcrEngine.parseTextResponse(envelope('{"text": "   "}')),
      isNull,
    );
  });

  test('没有 text 字段时返回 null，而不是抛错', () {
    expect(
      DeepSeekVisionOcrEngine.parseTextResponse(envelope('{"answer": "x"}')),
      isNull,
    );
  });

  test('完全不是 JSON 时返回 null', () {
    expect(
      DeepSeekVisionOcrEngine.parseTextResponse(envelope('图片里没有文字。')),
      isNull,
    );
  });

  test('题目文字里带引号和花括号不会截断', () {
    expect(
      DeepSeekVisionOcrEngine.parseTextResponse(
        envelope('{"text": "集合 {1, 2} 中的 \\"2\\" 是什么"}'),
      ),
      contains('{1, 2}'),
    );
  });

  test('图形占位符保留', () {
    expect(
      DeepSeekVisionOcrEngine.parseTextResponse(
        envelope('{"text": "如图，[图] 中阴影部分的面积是多少？"}'),
      ),
      contains('[图]'),
    );
  });

  test('云端引擎没配 Key 时立即失败，不发请求', () async {
    final engine = DeepSeekVisionOcrEngine(apiKey: '');
    await expectLater(
      engine.recognize('不存在的文件.jpg'),
      throwsA(isA<Exception>()),
    );
  });
}
