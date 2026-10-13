import 'package:flutter_test/flutter_test.dart';
import 'package:octopus/services/review_schedule.dart';

/// 复习计划。
///
/// 纯函数，不读时钟也不碰数据库，所以可以把「第一次复习」「走到最后」「时间
/// 边界」这些情况全跑一遍。
void main() {
  // 固定一个时间点，不用 DateTime.now()——否则跨零点跑测试会随机失败。
  final t0 = DateTime(2026, 10, 13, 10, 30);

  test('掌握所需次数和间隔数保持一致', () {
    // 这两个常量是手写的，容易改一个忘一个。第 N 次复习排出第 N 个间隔，
    // 所以掌握发生在「间隔数 + 1」次。
    expect(reviewsToMastery, reviewIntervalsDays.length + 1);
  });

  group('新题', () {
    test('入库后第一次复习安排在一天后', () {
      final plan = planForNewQuestion(t0);
      expect(plan.intervalDays, 1);
      expect(plan.reviewCount, 0);
      expect(plan.mastery, 'new');
      expect(plan.nextReviewAt, DateTime(2026, 10, 14, 10, 30));
    });
  });

  group('复习推进', () {
    test('间隔依次是 1、3、7、14、30 天', () {
      final intervals = <int?>[];
      for (var i = 0; i < 5; i++) {
        intervals.add(planAfterReview(previousCount: i, from: t0).intervalDays);
      }
      expect(intervals, [1, 3, 7, 14, 30]);
    });

    test('状态从 new 变 reviewing，最后 mastered', () {
      expect(
        planAfterReview(previousCount: 0, from: t0).mastery,
        'new',
      );
      expect(
        planAfterReview(previousCount: 1, from: t0).mastery,
        'reviewing',
      );
      expect(
        planAfterReview(previousCount: 2, from: t0).mastery,
        'reviewing',
      );
    });

    test('走完所有间隔就掌握，不再排下一次', () {
      // 第 5 次复习排出最后那个 30 天的间隔；再下一次才算掌握。
      final lastInterval = planAfterReview(previousCount: 4, from: t0);
      expect(lastInterval.intervalDays, 30);
      expect(lastInterval.mastery, 'reviewing');

      final plan = planAfterReview(previousCount: 5, from: t0);
      expect(plan.mastery, 'mastered');
      expect(plan.nextReviewAt, isNull);
      expect(plan.intervalDays, isNull);
      expect(plan.reviewCount, reviewsToMastery);
    });

    test('已经掌握之后再复习也不会越界', () {
      final plan = planAfterReview(previousCount: 99, from: t0);
      expect(plan.mastery, 'mastered');
      expect(plan.nextReviewAt, isNull);
    });

    test('次数是负数时按 0 处理，不抛异常', () {
      final plan = planAfterReview(previousCount: -3, from: t0);
      expect(plan.reviewCount, 1);
      expect(plan.intervalDays, 1);
    });
  });

  group('手动改状态', () {
    test('标成已掌握就不再排复习', () {
      final plan = planForMastery('mastered', t0);
      expect(plan.isMastered, isTrue);
      expect(plan.nextReviewAt, isNull);
    });

    test('标回未掌握就立刻可复习', () {
      final plan = planForMastery('new', t0);
      expect(plan.mastery, 'new');
      expect(plan.nextReviewAt, t0, reason: '标回未掌握应当马上进队列');
      expect(plan.reviewCount, 0);
    });

    test('标成复习中排三天后', () {
      final plan = planForMastery('reviewing', t0);
      expect(plan.intervalDays, 3);
      expect(plan.reviewCount, 1);
    });
  });

  group('到期判断', () {
    test('已掌握的不进队列', () {
      expect(isDue(t0, 'mastered', t0), isFalse);
      expect(isDue(null, 'mastered', t0), isFalse);
    });

    test('没有计划的视为立刻可复习', () {
      // 老数据升级上来没有 next_review_at。如果当成「不用复习」，
      // 这些题就永远不会出现，等于丢了。
      expect(isDue(null, 'new', t0), isTrue);
      expect(isDue(null, 'reviewing', t0), isTrue);
    });

    test('按天判断，不是按小时', () {
      // 上午复习完，计划是明天；当天下午不该又到期。
      final plan = planAfterReview(previousCount: 0, from: t0);
      final sameDayLater = DateTime(2026, 10, 13, 23, 59);
      expect(isDue(plan.nextReviewAt, plan.mastery, sameDayLater), isFalse);

      // 第二天一开始就该到期。
      final nextMorning = DateTime(2026, 10, 14, 0, 1);
      expect(isDue(plan.nextReviewAt, plan.mastery, nextMorning), isTrue);
    });

    test('已经过期很久的仍然算到期', () {
      final long = DateTime(2026, 1, 1);
      expect(isDue(long, 'new', t0), isTrue);
      expect(daysUntilDue(long, 'new', t0), 0);
    });
  });

  group('剩余天数', () {
    test('今天到期算 0，不是负数', () {
      expect(daysUntilDue(t0, 'new', t0), 0);
      expect(daysUntilDue(t0.subtract(const Duration(days: 5)), 'new', t0), 0);
    });

    test('明天到期算 1', () {
      expect(
        daysUntilDue(t0.add(const Duration(days: 1)), 'new', t0),
        1,
      );
    });

    test('已掌握返回 null', () {
      expect(daysUntilDue(t0, 'mastered', t0), isNull);
    });
  });

  group('文案', () {
    test('今天 / 明天 / N 天后', () {
      expect(describeNextReview(t0, 'new', t0), '今天该复习');
      expect(
        describeNextReview(t0.add(const Duration(days: 1)), 'new', t0),
        '明天复习',
      );
      expect(
        describeNextReview(t0.add(const Duration(days: 5)), 'new', t0),
        '5 天后复习',
      );
    });

    test('已掌握', () {
      expect(describeNextReview(null, 'mastered', t0), '已掌握');
      expect(describeNextReview(t0, 'mastered', t0), '已掌握');
    });
  });

  test('startOfDay 只保留日期', () {
    final t = startOfDay(DateTime(2026, 10, 13, 23, 59, 59));
    expect(t, DateTime(2026, 10, 13));
  });
}
