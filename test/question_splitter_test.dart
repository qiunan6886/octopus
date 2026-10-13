import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:octopus/services/question_splitter.dart';

/// 自动切题。
///
/// 这是纯逻辑，不碰 ML Kit 也不碰网络，所以可以拿构造出来的版面反复验证。
/// 真实试卷的排版千变万化，这里覆盖的是最常见的那几种。
void main() {
  // 一张 1000x1400 的「纸」，行高约 40，行距 20。
  const page = Size(1000, 1400);

  PageLine line(String text, double top, {double left = 80, double height = 40}) =>
      PageLine(
        text: text,
        box: Rect.fromLTWH(left, top, 840, height),
      );

  List<Rect> boxesOf(List<QuestionRegion> regions) =>
      regions.map((r) => r.box).toList();

  test('按数字题号切', () {
    final regions = splitIntoQuestions(
      lines: [
        line('1. 计算 12 + 5 =', 100),
        line('2. 计算 9 × 3 =', 300),
        line('3. 一个长方形长 8 厘米。', 500),
      ],
      pageSize: page,
    );

    expect(regions.length, 3);
    expect(regions.map((r) => r.marker).toList(), ['1.', '2.', '3.']);
    // 从上到下、互不重叠。
    expect(regions[0].box.top, lessThan(regions[1].box.top));
    expect(regions[1].box.top, lessThan(regions[2].box.top));
  });

  test('同一道题内部的多行不会切成多道', () {
    final regions = splitIntoQuestions(
      lines: [
        line('1. 应用题：', 100),
        line('小明有 5 个苹果，', 150),
        line('又买了 3 个，一共几个？', 200),
        line('2. 计算 7 + 8 =', 400),
      ],
      pageSize: page,
    );

    expect(regions.length, 2, reason: '第一道题的三行要合成一道');
    final first = regions.first.box;
    // 第一道题要盖住三行：从 y=100 附近到 y=240 附近。
    expect(first.top * page.height, lessThan(100));
    expect(first.bottom * page.height, greaterThan(200));
  });

  test('第一道题之前的卷头归到第一道题，不丢内容', () {
    final regions = splitIntoQuestions(
      lines: [
        line('四年级数学 第三单元测试', 40),
        line('姓名：____ 班级：____', 80),
        line('1. 计算 12 + 5 =', 160),
        line('2. 计算 9 × 3 =', 400),
      ],
      pageSize: page,
    );

    expect(regions.length, 2);
    // 卷头被并进第一道题，所以第一道题的区域从页面上方开始。
    expect(regions.first.box.top * page.height, lessThan(60));
  });

  test('括号题号也认', () {
    final regions = splitIntoQuestions(
      lines: [
        line('（1）12 + 5 =', 100),
        line('（2）9 × 3 =', 250),
        line('（3）7 - 4 =', 400),
      ],
      pageSize: page,
    );
    expect(regions.length, 3);
    expect(regions.map((r) => r.marker).toList(), ['（1）', '（2）', '（3）']);
  });

  test('中文数字题号也认', () {
    final regions = splitIntoQuestions(
      lines: [
        line('一、填空题', 100),
        line('二、选择题', 300),
        line('三、计算题', 500),
      ],
      pageSize: page,
    );
    expect(regions.length, 3);
    expect(regions.map((r) => r.marker).toList(), ['一、', '二、', '三、']);
  });

  test('「第 3 题」这种写法也认', () {
    final regions = splitIntoQuestions(
      lines: [
        line('第 1 题 计算 12 + 5 =', 100),
        line('第 2 题 计算 9 × 3 =', 300),
      ],
      pageSize: page,
    );
    expect(regions.length, 2);
  });

  test('没有题号时按空白切', () {
    final regions = splitIntoQuestions(
      lines: [
        line('先把下面的句子补充完整', 100),
        line('太阳从东边升起。', 150),
        // 大段空白
        line('写出三个带「木」字旁的字', 500),
        line('树、林、森', 550),
        // 又一段空白
        line('用「春天」写一句话', 900),
      ],
      pageSize: page,
    );

    expect(regions.length, 3, reason: '三块内容之间有明显的空白');
  });

  test('行距均匀的一段文字不会被切碎', () {
    final lines = <PageLine>[];
    for (var i = 0; i < 10; i++) {
      lines.add(line('这是一段连续的题目文字第 $i 行', 100 + i * 52.0));
    }
    final regions = splitIntoQuestions(lines: lines, pageSize: page);
    // 要么切成一整块，要么一块都不切——绝不能切成十块。
    expect(regions.length, lessThanOrEqualTo(1));
  });

  test('行中间的数字不会被当成题号', () {
    final regions = splitIntoQuestions(
      lines: [
        line('小明有 3 个苹果，又买了 2 个，一共几个？', 100),
        line('小华有 5 支铅笔。', 160),
      ],
      pageSize: page,
    );
    // 没有行首题号，应当按空白处理：两行挨得近，属于同一块。
    expect(regions.length, lessThanOrEqualTo(1));
  });

  test('只有一道题时也能切出来', () {
    final regions = splitIntoQuestions(
      lines: [line('1. 计算 12 + 5 =', 100)],
      pageSize: page,
    );
    expect(regions.length, 1);
    expect(regions.single.marker, '1.');
  });

  test('空输入返回空，调用方回退到手动框选', () {
    expect(splitIntoQuestions(lines: [], pageSize: page), isEmpty);
  });

  test('页面尺寸非法时返回空，而不是除零', () {
    final lines = [line('1. 题目', 100), line('2. 题目', 300)];
    expect(splitIntoQuestions(lines: lines, pageSize: Size.zero), isEmpty);
    expect(
      splitIntoQuestions(lines: lines, pageSize: const Size(0, 100)),
      isEmpty,
    );
  });

  test('切出来的区域是归一化坐标且在页面内', () {
    final regions = splitIntoQuestions(
      lines: [
        line('1. 计算 12 + 5 =', 100),
        line('2. 计算 9 × 3 =', 900),
      ],
      pageSize: page,
    );
    for (final r in regions) {
      expect(r.box.left, inInclusiveRange(0.0, 1.0));
      expect(r.box.top, inInclusiveRange(0.0, 1.0));
      expect(r.box.right, lessThanOrEqualTo(1.0));
      expect(r.box.bottom, lessThanOrEqualTo(1.0));
      expect(r.box.width, greaterThan(0));
      expect(r.box.height, greaterThan(0));
    }
    // 归一化之后，坐标应该能还原成合理的像素位置。
    expect(regions.first.box.top * page.height, lessThan(100));
  });

  test('贴边的内容不会因为加 padding 而越界', () {
    final regions = splitIntoQuestions(
      lines: [
        PageLine(text: '1. 顶格的题', box: const Rect.fromLTWH(0, 0, 1000, 40)),
        PageLine(
          text: '2. 底部的题',
          box: const Rect.fromLTWH(0, 1360, 1000, 40),
        ),
      ],
      pageSize: page,
    );
    expect(boxesOf(regions).every((b) => b.left >= 0 && b.top >= 0), isTrue);
    expect(
      boxesOf(regions).every((b) => b.right <= 1 && b.bottom <= 1),
      isTrue,
    );
  });
}
