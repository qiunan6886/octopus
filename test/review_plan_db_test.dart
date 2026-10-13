import 'package:flutter_test/flutter_test.dart';
import 'package:octopus/data/database.dart';
import 'package:octopus/services/review_schedule.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 复习计划的数据层。
///
/// 间隔计算是纯函数（另有一组测试），这里测的是**接上数据库之后**的行为：
/// 到期查询、推进计划、跨孩子隔离、以及老数据没有计划时的处理。
void main() {
  late OctopusDatabase db;
  late int alice;
  late int bob;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await OctopusDatabase.openAt(inMemoryDatabasePath);
    alice = await db.createProfile(name: '老大', grade: 4);
    bob = await db.createProfile(name: '老二', grade: 2);
  });

  tearDown(() async {
    await db.close();
  });

  test('新入库的题排好了第一次复习，当天不到期', () async {
    await db.insertQuestion(profileId: alice, content: '题');

    final question = (await db.questionsFor(alice)).single;
    expect(question.nextReviewAt, isNotNull);
    expect(question.mastery, 'new');
    expect(question.reviewCount, 0);

    // 刚入库，今天不该复习——计划是一天后。
    expect(await db.dueCount(alice), 0);
    expect(await db.dueQuestions(alice), isEmpty);
  });

  test('到了第二天就进复习队列', () async {
    await db.insertQuestion(profileId: alice, content: '题');
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    expect(await db.dueCount(alice, now: tomorrow), 1);
    expect((await db.dueQuestions(alice, now: tomorrow)).single.content, '题');
  });

  test('标记复习过之后计划往后推，并且不再到期', () async {
    await db.insertQuestion(profileId: alice, content: '题');
    final id = (await db.questionsFor(alice)).single.id;

    // 假装到了第二天，复习一次。
    final day2 = DateTime.now().add(const Duration(days: 1));
    await db.markReviewed(alice, [id], now: day2);

    final updated = (await db.questionsFor(alice)).single;
    expect(updated.reviewCount, 1);
    expect(updated.mastery, 'new', reason: '第一次复习后仍是未掌握');
    // 下一次间隔 3 天，所以 day2 当天不该再到期。
    expect(await db.dueCount(alice, now: day2), 0);
    expect(await db.dueCount(alice, now: day2.add(const Duration(days: 3))), 1);
  });

  test('连续复习的间隔依次拉长，最后变成已掌握', () async {
    await db.insertQuestion(profileId: alice, content: '题');
    final id = (await db.questionsFor(alice)).single.id;

    var clock = DateTime.now();
    final intervals = <int?>[];
    for (var i = 0; i < reviewsToMastery; i++) {
      final before = (await db.questionsFor(alice)).single;
      await db.markReviewed(alice, [id], now: clock);
      final after = (await db.questionsFor(alice)).single;

      if (after.nextReviewAt != null && before.nextReviewAt != null) {
        intervals.add(
          startOfDay(after.nextReviewAt!)
              .difference(startOfDay(clock))
              .inDays,
        );
      } else {
        intervals.add(null);
      }
      clock = after.nextReviewAt ?? clock;
    }

    expect(intervals, [1, 3, 7, 14, 30, null]);
    final finalState = (await db.questionsFor(alice)).single;
    expect(finalState.mastery, 'mastered');
    expect(finalState.nextReviewAt, isNull);
    // 已掌握的不该再出现在队列里。
    expect(await db.dueCount(alice, now: clock.add(const Duration(days: 365))), 0);
  });

  test('手动标成已掌握会退出复习队列', () async {
    await db.insertQuestion(profileId: alice, content: '题');
    await db.setMastery(alice, [(await db.questionsFor(alice)).single.id], 'mastered');

    final question = (await db.questionsFor(alice)).single;
    expect(question.mastery, 'mastered');
    expect(question.nextReviewAt, isNull);
    expect(await db.dueCount(alice), 0);
  });

  test('手动标回未掌握会立刻回到队列', () async {
    await db.insertQuestion(profileId: alice, content: '题');
    final id = (await db.questionsFor(alice)).single.id;
    await db.setMastery(alice, [id], 'mastered');

    await db.setMastery(alice, [id], 'new');

    final question = (await db.questionsFor(alice)).single;
    expect(question.mastery, 'new');
    expect(question.reviewCount, 0, reason: '标回未掌握等于从头再来');
    expect(await db.dueCount(alice), 1, reason: '应当马上可复习');
  });

  test('复习计划按孩子隔离', () async {
    await db.insertQuestion(profileId: alice, content: '老大的题');
    await db.insertQuestion(profileId: bob, content: '老二的题');

    final aliceId = (await db.questionsFor(alice)).single.id;
    await db.setMastery(alice, [aliceId], 'mastered');

    expect(await db.dueCount(alice), 0);
    // 老二的题不受影响。
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    expect(await db.dueCount(bob, now: tomorrow), 1);

    // 拿错的身份推进计划：一条都不该动。
    final bobId = (await db.questionsFor(bob)).single.id;
    expect(await db.markReviewed(alice, [bobId]), 0);
    expect((await db.questionsFor(bob)).single.reviewCount, 0);
  });

  test('没有计划的题视为立刻可复习，而不是永远不出现', () async {
    // 老数据升级上来 next_review_at 是空的。如果当成「不用复习」，
    // 这些题就永远不会进队列，等于丢了。
    await db.insertQuestion(profileId: alice, content: '题');
    final id = (await db.questionsFor(alice)).single.id;
    // 手工清掉计划，模拟老数据。
    await db.setMastery(alice, [id], 'new');
    expect(await db.dueCount(alice), 1, reason: '标回未掌握后应当立刻到期');
  });

  test('空列表推进不会出错', () async {
    expect(await db.markReviewed(alice, []), 0);
    await db.setMastery(alice, [], 'mastered');
    expect(await db.questionsFor(alice), isEmpty);
  });
}
