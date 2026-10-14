import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:octopus/services/deepseek_client.dart';
import 'package:octopus/services/page_analyzer.dart';
import 'package:octopus/services/question_splitter.dart';

/// 整页分析：解析模型的返回 + 用文字行吸附边界。
///
/// 这两段都是纯逻辑，而它们恰好是最容易出错的地方——坐标尺度搞错会整页错位，
/// 吸附写错会把字切掉半行。
void main() {
  String envelope(String content) => jsonEncode({
    'choices': [
      {
        'message': {'role': 'assistant', 'content': content},
      },
    ],
  });

  String pageJson(List<Map<String, Object?>> questions) =>
      jsonEncode({'questions': questions});

  group('解析', () {
    test('标准返回', () {
      final analysis = DeepSeekPageAnalyzer.parseAnalysis(
        envelope(
          pageJson([
            {
              'box': [50, 100, 900, 300],
              'text': '1. 计算 12 + 5 =',
              'correct': true,
              'correctAnswer': '17',
              'reason': '计算正确',
              'subject': '数学',
              'knowledgePoints': ['两位数加法'],
            },
          ]),
        ),
      );
      expect(analysis.questions.length, 1);
      final q = analysis.questions.single;
      expect(q.box, const Rect.fromLTRB(0.05, 0.1, 0.9, 0.3));
      expect(q.text, '1. 计算 12 + 5 =');
      expect(q.isCorrect, isTrue);
      expect(q.correctAnswer, '17');
      expect(q.subject, '数学');
      expect(q.knowledgePoints, ['两位数加法']);
      expect(q.knowledgeTags, '两位数加法');
    });

    test('坐标是 0-1 小数时也能认出尺度', () {
      final analysis = DeepSeekPageAnalyzer.parseAnalysis(
        envelope(
          pageJson([
            {'box': [0.1, 0.2, 0.8, 0.4], 'text': '题', 'correct': false},
          ]),
        ),
      );
      expect(
        analysis.questions.single.box,
        const Rect.fromLTRB(0.1, 0.2, 0.8, 0.4),
      );
    });

    test('坐标写反了会自动纠正', () {
      final analysis = DeepSeekPageAnalyzer.parseAnalysis(
        envelope(
          pageJson([
            {'box': [900, 300, 50, 100], 'text': '题', 'correct': true},
          ]),
        ),
      );
      expect(
        analysis.questions.single.box,
        const Rect.fromLTRB(0.05, 0.1, 0.9, 0.3),
      );
    });

    test('超出 0-1000 的坐标会被夹回范围内', () {
      final analysis = DeepSeekPageAnalyzer.parseAnalysis(
        envelope(
          pageJson([
            {'box': [-50, -20, 1200, 1400], 'text': '题', 'correct': true},
          ]),
        ),
      );
      final box = analysis.questions.single.box;
      expect(box.left, 0.0);
      expect(box.top, 0.0);
      expect(box.right, 1.0);
      expect(box.bottom, 1.0);
    });

    test('按纵坐标排序，保证和纸面顺序一致', () {
      final analysis = DeepSeekPageAnalyzer.parseAnalysis(
        envelope(
          pageJson([
            {'box': [0, 800, 1000, 900], 'text': '第三题', 'correct': true},
            {'box': [0, 100, 1000, 200], 'text': '第一题', 'correct': true},
            {'box': [0, 400, 1000, 500], 'text': '第二题', 'correct': true},
          ]),
        ),
      );
      expect(
        analysis.questions.map((q) => q.text).toList(),
        ['第一题', '第二题', '第三题'],
      );
    });

    test('box 缺字段或太小的条目被跳过，不塞进一道坏题', () {
      final analysis = DeepSeekPageAnalyzer.parseAnalysis(
        envelope(
          pageJson([
            {'text': '没有 box', 'correct': true},
            {'box': [0, 0, 0, 0], 'text': '零面积', 'correct': true},
            {'box': [10, 10, 12, 12], 'text': '太小', 'correct': true},
            {'box': [0, 100, 1000, 200], 'text': '正常', 'correct': true},
          ]),
        ),
      );
      expect(analysis.questions.length, 1);
      expect(analysis.questions.single.text, '正常');
    });

    test('一道题都没有时报错，让界面提示重试', () {
      expect(
        () => DeepSeekPageAnalyzer.parseAnalysis(envelope(pageJson([]))),
        throwsA(isA<DeepSeekException>()),
      );
    });

    test('questions 不是数组时报错', () {
      expect(
        () => DeepSeekPageAnalyzer.parseAnalysis(
          envelope('{"questions": "没有"}'),
        ),
        throwsA(isA<DeepSeekException>()),
      );
    });

    test('知识点写成顿号分隔的字符串也认', () {
      final analysis = DeepSeekPageAnalyzer.parseAnalysis(
        envelope(
          pageJson([
            {
              'box': [0, 0, 1000, 100],
              'text': '题',
              'correct': true,
              'knowledgePoints': '分数加法、通分',
            },
          ]),
        ),
      );
      expect(analysis.questions.single.knowledgePoints, ['分数加法', '通分']);
    });

    test('correct 写成字符串也认', () {
      final analysis = DeepSeekPageAnalyzer.parseAnalysis(
        envelope(
          pageJson([
            {'box': [0, 0, 1000, 100], 'text': 'a', 'correct': 'false'},
            {'box': [0, 200, 1000, 300], 'text': 'b', 'correct': 'true'},
          ]),
        ),
      );
      expect(analysis.questions[0].isCorrect, isFalse);
      expect(analysis.questions[1].isCorrect, isTrue);
      expect(analysis.questions[0].gradeResult, 'wrong');
    });
  });

  group('按栏宽拉齐', () {
    // 试卷同一栏里的题目共用一个左边距和右边距。用中位数当基准把歪的拉回来。
    PageQuestion q(double l, double r, String text) => PageQuestion(
      box: Rect.fromLTRB(l, 0.1, r, 0.2),
      text: text,
      isCorrect: true,
    );

    test('偏离小的框被拉齐到中位数', () {
      final aligned = alignBoxColumns([
        q(0.10, 0.90, 'a'),
        q(0.11, 0.89, 'b'), // 差一点点，应当拉齐
        q(0.10, 0.91, 'c'),
      ]);
      expect(aligned.map((e) => e.box.left).toSet(), {0.10});
      expect(aligned.map((e) => e.box.right).toSet(), {0.90});
    });

    test('真正缩进的题目不动', () {
      // 大题下面的小问「（1）（2）」确实左缩进，强行拉齐会盖到别的题上。
      final aligned = alignBoxColumns([
        q(0.10, 0.90, '大题'),
        q(0.10, 0.90, '题二'),
        q(0.10, 0.90, '题三'),
        q(0.45, 0.90, '缩进的小问'),
      ]);
      expect(aligned[3].box.left, 0.45, reason: '缩进是真实的版面信息，不能抹掉');
      expect(aligned[0].box.left, 0.10);
    });

    test('个别歪得离谱的框不会把基准带偏', () {
      // 用中位数而不是平均值的理由。平均数会被那个 0.95 拉走，
      // 结果所有正常的框都被拽偏。
      final aligned = alignBoxColumns([
        q(0.10, 0.90, 'a'),
        q(0.10, 0.90, 'b'),
        q(0.11, 0.90, 'c'),
        q(0.95, 0.99, '模型报歪了'),
      ]);
      // 前三个的左边应当完全一致（具体值是多少不重要，一致才重要）。
      expect(aligned[0].box.left, aligned[1].box.left);
      expect(aligned[1].box.left, aligned[2].box.left);
      expect(
        aligned[0].box.left,
        lessThan(0.2),
        reason: '基准不能被那个 0.95 带跑',
      );
      expect(aligned[3].box.left, 0.95, reason: '偏离太大，保留原样交给吸附去处理');
    });

    test('题目太少时不拉齐，避免拿一两个样本瞎猜', () {
      final aligned = alignBoxColumns([q(0.10, 0.9, 'a'), q(0.30, 0.5, 'b')]);
      expect(aligned[0].box.left, 0.10);
      expect(aligned[1].box.left, 0.30);
    });

    test('只动左右边缘，上下不动', () {
      final aligned = alignBoxColumns([
        q(0.10, 0.90, 'a'),
        q(0.11, 0.90, 'b'),
        q(0.10, 0.90, 'c'),
      ]);
      expect(aligned[1].box.top, 0.1);
      expect(aligned[1].box.bottom, 0.2);
    });
  });

  group('吸附到文字行', () {
    const page = Size(1000, 2000);

    PageLine line(double top, double bottom, {double left = 50, double right = 900}) =>
        PageLine(
          text: 'x',
          box: Rect.fromLTRB(left, top, right, bottom),
        );

    test('边界收紧到实际文字行，不留空白', () {
      // 模型给了一大块，但文字只占中间一小段。
      final questions = [
        const PageQuestion(
          box: Rect.fromLTRB(0.0, 0.10, 1.0, 0.50),
          text: '题',
          isCorrect: true,
        ),
      ];
      final snapped = snapToLines(
        questions: questions,
        lines: [line(300, 380), line(400, 480)],
        pageSize: page,
      );
      final box = snapped.single.box;
      // 文字实际是 y 300..480 → 0.15..0.24，加了余量。
      expect(box.top, closeTo(0.15 - 0.012, 0.001));
      expect(box.bottom, closeTo(0.24 + 0.012, 0.001));
      expect(box.height, lessThan(0.2), reason: '应当比模型原来给的 0.4 收紧很多');
    });

    test('框外的文字行不参与，边界不会被拉大', () {
      final questions = [
        const PageQuestion(
          box: Rect.fromLTRB(0.0, 0.10, 1.0, 0.20),
          text: '题',
          isCorrect: true,
        ),
      ];
      final snapped = snapToLines(
        questions: questions,
        lines: [
          line(220, 300), // 落在框内 0.11..0.15
          line(900, 980), // 远在框外
        ],
        pageSize: page,
      );
      expect(snapped.single.box.bottom, lessThan(0.25));
    });

    test('一个文字行都没落在框里时保留模型原框', () {
      // 宁可位置不完美，也不能把这道题丢掉。
      const original = Rect.fromLTRB(0.1, 0.1, 0.9, 0.2);
      final snapped = snapToLines(
        questions: [
          const PageQuestion(box: original, text: '题', isCorrect: false),
        ],
        lines: [line(1500, 1580)],
        pageSize: page,
      );
      expect(snapped.single.box, original);
    });

    test('没有文字行时原样返回', () {
      const original = Rect.fromLTRB(0.1, 0.1, 0.9, 0.2);
      final snapped = snapToLines(
        questions: [
          const PageQuestion(box: original, text: '题', isCorrect: true),
        ],
        lines: const [],
        pageSize: page,
      );
      expect(snapped.single.box, original);
    });

    test('页面尺寸非法时原样返回，不做除零', () {
      const original = Rect.fromLTRB(0.1, 0.1, 0.9, 0.2);
      final snapped = snapToLines(
        questions: [
          const PageQuestion(box: original, text: '题', isCorrect: true),
        ],
        lines: [PageLine(text: 'x', box: Rect.fromLTRB(0, 0, 10, 10))],
        pageSize: Size.zero,
      );
      expect(snapped.single.box, original);
    });

    test('吸附不会把框推出页面', () {
      final snapped = snapToLines(
        questions: [
          const PageQuestion(
            box: Rect.fromLTRB(0.0, 0.0, 1.0, 0.05),
            text: '题',
            isCorrect: true,
          ),
        ],
        lines: [line(0, 40, left: 0, right: 1000)],
        pageSize: page,
      );
      final box = snapped.single.box;
      expect(box.left, 0.0);
      expect(box.top, 0.0);
      expect(box.right, 1.0);
      expect(box.bottom, lessThanOrEqualTo(1.0));
    });

    test('模型框短了一点，最后一行仍然被包含进来', () {
      // 这是「按中心点判断」会出错的地方：最后一行的中心刚好落到框外一丝丝，
      // 于是被丢掉，这道题的尾巴就被切了。按重叠比例就容忍了这个偏差。
      const modelBox = Rect.fromLTRB(0.0, 0.10, 1.0, 0.175);
      final snapped = snapToLines(
        questions: [
          const PageQuestion(box: modelBox, text: '题', isCorrect: true),
        ],
        lines: [
          line(200, 300), // 0.100..0.150，完全在内
          line(310, 400), // 0.155..0.200，中心 0.1775 在框外，但 44% 重叠
        ],
        pageSize: page,
      );
      expect(
        snapped.single.box.bottom,
        greaterThan(0.19),
        reason: '第二行必须被算进来，否则这道题的最后一问会被切掉',
      );
    });

    test('一行落在两个框里时，归给重叠更多的那个', () {
      // 模型被要求「相邻框不要重叠」，但它做不到。直接两边都取并集的话，
      // 这个行会出现在两道题里，打印出来是重复的。
      final snapped = snapToLines(
        questions: [
          const PageQuestion(
            box: Rect.fromLTRB(0.0, 0.10, 1.0, 0.16),
            text: '上题',
            isCorrect: true,
          ),
          const PageQuestion(
            box: Rect.fromLTRB(0.0, 0.155, 1.0, 0.30),
            text: '下题',
            isCorrect: true,
          ),
        ],
        lines: [line(320, 400)], // 0.16..0.20，绝大部分落在第二个框里
        pageSize: page,
      );
      // 第一个框不该认领这一行——它本该在框外。
      expect(snapped[0].box.bottom, lessThan(0.17));
      expect(snapped[1].box.bottom, greaterThan(0.19));
    });

    test('相邻两题的框不会重叠', () {
      // 两题的行挨得很近，加上留白之后并集就叠上了。叠上意味着同一块内容
      // 出现在两道题里。
      final snapped = snapToLines(
        questions: [
          const PageQuestion(
            box: Rect.fromLTRB(0.0, 0.10, 1.0, 0.20),
            text: '上题',
            isCorrect: true,
          ),
          const PageQuestion(
            box: Rect.fromLTRB(0.0, 0.21, 1.0, 0.30),
            text: '下题',
            isCorrect: false,
          ),
        ],
        lines: [
          line(200, 300), // 0.100..0.150
          line(310, 400), // 0.155..0.200  ← 上题最后一行
          line(410, 500), // 0.205..0.250  ← 下题第一行，离得很近
        ],
        pageSize: page,
      );

      expect(
        snapped[0].box.bottom,
        lessThanOrEqualTo(snapped[1].box.top),
        reason: '切开之后不应当再有重叠',
      );
      // 切开的同时不能把内容切掉：
      //   上题最后一行是 0.155..0.200 → 上框下缘必须盖住 0.200
      //   下题第一行是 0.205..0.250 → 下框上缘必须在 0.205 之上
      expect(
        snapped[0].box.bottom,
        greaterThanOrEqualTo(0.20),
        reason: '不能为了分开而切掉上题的最后一行',
      );
      expect(
        snapped[1].box.top,
        lessThanOrEqualTo(0.205),
        reason: '不能为了分开而切掉下题的第一行',
      );
    });

    test('批改信息在吸附后保留', () {      final snapped = snapToLines(
        questions: [
          const PageQuestion(
            box: Rect.fromLTRB(0.0, 0.1, 1.0, 0.3),
            text: '原题',
            isCorrect: false,
            correctAnswer: '42',
            reason: '漏了进位',
            subject: '数学',
            knowledgePoints: ['进位'],
          ),
        ],
        lines: [line(220, 300)],
        pageSize: page,
      );
      final q = snapped.single;
      expect(q.box, isNot(const Rect.fromLTRB(0.0, 0.1, 1.0, 0.3)));
      expect(q.text, '原题');
      expect(q.correctAnswer, '42');
      expect(q.reason, '漏了进位');
      expect(q.subject, '数学');
      expect(q.knowledgePoints, ['进位']);
    });
  });
}
