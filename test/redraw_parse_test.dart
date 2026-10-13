import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:octopus/services/deepseek_client.dart';
import 'package:octopus/services/deepseek_redraw.dart';

/// AI 重绘的 SVG 提取。
///
/// 模型很少老老实实只输出一个 `<svg>`，所以这段比网络调用更需要测。
void main() {
  String envelope(String content) => jsonEncode({
    'choices': [
      {
        'message': {'role': 'assistant', 'content': content},
      },
    ],
  });

  const clean = '<svg viewBox="0 0 400 200"><rect x="10" y="10" width="100" height="50"/></svg>';

  test('干净输出', () {
    expect(DeepSeekRedrawer.extractSvg(clean), clean);
  });

  test('包在 markdown 代码围栏里也能提取', () {
    final raw = '好的，这是重绘结果：\n```svg\n$clean\n```\n希望有帮助。';
    expect(DeepSeekRedrawer.extractSvg(raw), clean);
  });

  test('前后有解释文字也能提取', () {
    final raw = '我画了一个长方形。\n$clean\n就是这样。';
    expect(DeepSeekRedrawer.extractSvg(raw), clean);
  });

  test('从完整响应里提取', () {
    // 走一遍 redraw() 的真实路径：先从响应里解析出 svg 字段，再对字段内容做提取。
    // 直接对 JSON 文本调 extractSvg 是不对的——文本里的引号是转义过的。
    final inner = jsonEncode({'svg': clean, 'note': '一个长方形'});
    final reply = envelope(inner);

    final field = DeepSeekClient.firstJsonObject(
      DeepSeekClient.extractContent(reply),
    )?['svg'] as String?;
    expect(field, isNotNull);
    expect(DeepSeekRedrawer.extractSvg(field!), clean);
  });

  test('解析出来的字段已经是反转义的，可以直接提取', () {
    // 这段是上面那条的注解：转义只在传输层存在，解析之后就没有了。
    final reply = envelope(jsonEncode({'svg': clean}));
    final content = DeepSeekClient.extractContent(reply);
    expect(content, contains(r'\"'), reason: '原始文本里引号是转义的');

    final field =
        DeepSeekClient.firstJsonObject(content)?['svg'] as String?;
    expect(field, isNot(contains(r'\"')), reason: '解析之后转义就没了');
    expect(field, clean);
  });

  test('只有 viewBox 没有 width/height 也算有效', () {
    const svg = '<svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="4"/></svg>';
    expect(DeepSeekRedrawer.extractSvg(svg), svg);
  });

  test('只有 width/height 也算有效', () {
    const svg = '<svg width="100" height="50"><line x1="0" y1="0" x2="9" y2="9"/></svg>';
    expect(DeepSeekRedrawer.extractSvg(svg), svg);
  });

  test('没有尺寸的空 svg 判为无效，让用户重试而不是打出空白', () {
    expect(
      DeepSeekRedrawer.extractSvg('<svg><rect/></svg>'),
      isNull,
    );
  });

  test('根本不是 SVG 时返回 null', () {
    expect(DeepSeekRedrawer.extractSvg('这道题是一个长方形。'), isNull);
    expect(DeepSeekRedrawer.extractSvg('<svg viewBox="0 0 1 1">'), isNull);
  });

  test('取第一个完整的 svg，不把后面的内容带进来', () {
    const first = '<svg viewBox="0 0 1 1"><rect/></svg>';
    const second = '<svg viewBox="0 0 9 9"><circle/></svg>';
    expect(DeepSeekRedrawer.extractSvg('$first 然后 $second'), first);
  });

  test('换行和缩进不影响提取', () {
    const svg = '''<svg viewBox="0 0 400 200">
  <rect x="10" y="10" width="100" height="50" fill="none" stroke="black"/>
  <text x="20" y="80">长 8 厘米</text>
</svg>''';
    expect(DeepSeekRedrawer.extractSvg('```\n$svg\n```'), svg);
  });
}
