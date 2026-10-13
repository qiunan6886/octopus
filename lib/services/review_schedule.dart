/// 复习间隔（天）。
///
/// 经典的间隔重复节奏：第一次隔一天，之后逐步拉长。对小学的错题来说，太长的
/// 间隔等于没复习——孩子早忘了——所以最长只到 30 天。
const reviewIntervalsDays = <int>[1, 3, 7, 14, 30];

/// 走完全部间隔需要复习几次。
///
/// 是 `间隔数 + 1`：第 5 次复习要**排出** 30 天这个间隔，排完之后的下一次
/// 才算掌握。写成 `间隔数` 的话 30 天那一档永远用不到。
///
/// 写成字面量而不是 `reviewIntervalsDays.length + 1`，是因为常量表达式里不能取
/// `.length`。`review_schedule_test.dart` 里有一条测试盯着两者不要漂移。
const reviewsToMastery = 6;

/// 一道题的下一次复习安排。
class ReviewPlan {
  const ReviewPlan({
    required this.nextReviewAt,
    required this.mastery,
    required this.reviewCount,
    required this.intervalDays,
  });

  /// 下次该复习的时间。已经掌握时为 null。
  final DateTime? nextReviewAt;

  /// new / reviewing / mastered
  final String mastery;

  /// 这是第几次复习（含本次）。
  final int reviewCount;

  /// 本次安排的天数。已掌握时为 null。
  final int? intervalDays;

  bool get isMastered => mastery == 'mastered';
}

/// 算出「刚复习完一次」之后的安排。
///
/// [previousCount] 是这次复习**之前**已经复习过的次数。第一次复习传 0。
///
/// 传 [from] 而不是取 `DateTime.now()` 是为了可测——纯函数里读时钟就没法验证了。
ReviewPlan planAfterReview({
  required int previousCount,
  required DateTime from,
}) {
  final count = previousCount < 0 ? 0 : previousCount;
  final nextCount = count + 1;

  if (nextCount >= reviewsToMastery) {
    return ReviewPlan(
      nextReviewAt: null,
      mastery: 'mastered',
      reviewCount: nextCount,
      intervalDays: null,
    );
  }

  // 索引夹一下：万一 reviewCount 被外部改大了，也不要越界。
  final index = (nextCount - 1).clamp(0, reviewIntervalsDays.length - 1);
  final days = reviewIntervalsDays[index];
  return ReviewPlan(
    nextReviewAt: from.add(Duration(days: days)),
    mastery: nextCount == 1 ? 'new' : 'reviewing',
    reviewCount: nextCount,
    intervalDays: days,
  );
}

/// 一道新入库的错题什么时候该第一次复习。
ReviewPlan planForNewQuestion(DateTime createdAt) =>
    ReviewPlan(
      nextReviewAt: createdAt.add(
        Duration(days: reviewIntervalsDays.first),
      ),
      mastery: 'new',
      reviewCount: 0,
      intervalDays: reviewIntervalsDays.first,
    );

/// 手动改掌握状态时的安排。
///
/// 标成「已掌握」就不再有复习计划；标回「未掌握」就从头再来一次。
ReviewPlan planForMastery(String mastery, DateTime from) => switch (mastery) {
  'mastered' => ReviewPlan(
    nextReviewAt: null,
    mastery: 'mastered',
    reviewCount: reviewsToMastery,
    intervalDays: null,
  ),  'reviewing' => ReviewPlan(
    nextReviewAt: from.add(const Duration(days: 3)),
    mastery: 'reviewing',
    reviewCount: 1,
    intervalDays: 3,
  ),
  _ => ReviewPlan(
    nextReviewAt: from,
    mastery: 'new',
    reviewCount: 0,
    intervalDays: reviewIntervalsDays.first,
  ),
};

/// 这道题今天该不该复习。
///
/// 已掌握的不再进入队列；没有计划的（老数据）视为「立刻可复习」，否则升级上来的
/// 题会永远不出现。
///
/// **按天比较，不按时间戳**：计划是「明天复习」，那么明天一整天都该出现，
/// 而不是要等到明天同一时刻。上午复习完、下午又冒出来是很糟的体验。
bool isDue(DateTime? nextReviewAt, String mastery, DateTime now) {
  if (mastery == 'mastered') return false;
  if (nextReviewAt == null) return true;
  return !startOfDay(nextReviewAt).isAfter(startOfDay(now));
}

/// 把时间归到当天零点。
///
/// 「今天该复习」是**按天**算的，不是按小时。否则上午复习完，下午同一道题的
/// 到期时间又到了。
DateTime startOfDay(DateTime time) =>
    DateTime(time.year, time.month, time.day);

/// 还剩几天到期。已过期返回 0。已掌握返回 null。
int? daysUntilDue(DateTime? nextReviewAt, String mastery, DateTime now) {
  if (mastery == 'mastered') return null;
  if (nextReviewAt == null) return 0;
  final today = startOfDay(now);
  final due = startOfDay(nextReviewAt);
  final diff = due.difference(today).inDays;
  return diff < 0 ? 0 : diff;
}

/// 给人看的下次复习说明。
String describeNextReview(DateTime? nextReviewAt, String mastery, DateTime now) {
  if (mastery == 'mastered') return '已掌握';
  final days = daysUntilDue(nextReviewAt, mastery, now);
  if (days == null) return '已掌握';
  return switch (days) {
    0 => '今天该复习',
    1 => '明天复习',
    _ => '$days 天后复习',
  };
}
