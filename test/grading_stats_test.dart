import 'package:flutter_test/flutter_test.dart';
import 'package:octopus/data/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 批改统计。
///
/// 关键的坑是**统计口径**：做对的题默认不进错题库，如果只统计 questions 表，
/// 正确率永远是 0。所以统计必须走 draft_questions。
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

  /// 建一道批改过的草稿。
  Future<void> graded({
    required int profileId,
    required String result,
    String? subject,
    String source = 'ai',
  }) async {
    final batchId = await db.createBatch(profileId);
    final draftId = await db.insertDraft(
      batchId: batchId,
      originalImagePath: '/tmp/q.jpg',
    );
    await db.setDraftGrade(
      draftId,
      result: result,
      source: source,
      subject: subject,
      reason: '测试理由',
    );
  }

  test('做对的题不入库，但仍然算进正确率', () async {
    // 这是这条测试存在的唯一理由：如果统计走 questions 表，
    // 下面三道的正确率会算成 0%。
    await graded(profileId: alice, result: 'correct', subject: '数学');
    await graded(profileId: alice, result: 'correct', subject: '数学');
    await graded(profileId: alice, result: 'wrong', subject: '数学');

    // 确认做对的确实没进错题库。
    expect(await db.questionsFor(alice), isEmpty);

    final stats = await db.gradingStats(alice);
    expect(stats.length, 1);
    expect(stats.single.subject, '数学');
    expect(stats.single.correct, 2);
    expect(stats.single.wrong, 1);
    expect(stats.single.total, 3);
    expect(stats.single.accuracyPercent, 67);
  });

  test('按学科分组', () async {
    await graded(profileId: alice, result: 'correct', subject: '数学');
    await graded(profileId: alice, result: 'wrong', subject: '语文');
    await graded(profileId: alice, result: 'wrong', subject: '语文');

    final stats = await db.gradingStats(alice);
    final bySubject = {for (final s in stats) s.subject: s};

    expect(bySubject['数学']!.accuracyPercent, 100);
    expect(bySubject['语文']!.accuracyPercent, 0);
    // 题多的排前面。
    expect(stats.first.subject, '语文');
  });

  test('没识别出学科的归到「未分类」，不丢', () async {
    await graded(profileId: alice, result: 'wrong');
    final stats = await db.gradingStats(alice);
    expect(stats.single.subject, '未分类');
  });

  test('没批改的题不算进统计', () async {
    final batchId = await db.createBatch(alice);
    await db.insertDraft(batchId: batchId, originalImagePath: '/tmp/q.jpg');
    // 只建草稿，不批改。
    expect(await db.gradingStats(alice), isEmpty);
  });

  test('统计按孩子隔离', () async {
    await graded(profileId: alice, result: 'correct', subject: '数学');
    await graded(profileId: bob, result: 'wrong', subject: '数学');

    expect((await db.gradingStats(alice)).single.correct, 1);
    expect((await db.gradingStats(alice)).single.wrong, 0);
    expect((await db.gradingStats(bob)).single.correct, 0);
    expect((await db.gradingStats(bob)).single.wrong, 1);
  });

  test('手动改过的数量单独统计', () async {
    await graded(profileId: alice, result: 'wrong', source: 'ai');
    await graded(profileId: alice, result: 'correct', source: 'manual');
    await graded(profileId: bob, result: 'correct', source: 'manual');

    expect(await db.manuallyOverriddenCount(alice), 1);
    expect(await db.manuallyOverriddenCount(bob), 1);
  });

  test('空统计时正确率是 0 而不是除零', () {
    const stat = SubjectStat(subject: '数学', correct: 0, wrong: 0);
    expect(stat.accuracy, 0);
    expect(stat.accuracyPercent, 0);
    expect(stat.total, 0);
  });

  test('批改理由会存下来', () async {
    final batchId = await db.createBatch(alice);
    final draftId = await db.insertDraft(
      batchId: batchId,
      originalImagePath: '/tmp/q.jpg',
    );
    await db.setDraftGrade(
      draftId,
      result: 'wrong',
      source: 'ai',
      reason: '竖式第二行忘了进位',
      subject: '数学',
      knowledgeTags: '两位数乘一位数、进位',
    );

    final draft = (await db.draftsFor(batchId)).single;
    expect(draft.gradeReason, '竖式第二行忘了进位');
    expect(draft.subject, '数学');
    expect(draft.knowledgeTags, '两位数乘一位数、进位');
  });

  test('理由跟着题一起入库', () async {
    final batchId = await db.createBatch(alice);
    final draftId = await db.insertDraft(
      batchId: batchId,
      originalImagePath: '/tmp/q.jpg',
    );
    await db.setDraftGrade(
      draftId,
      result: 'wrong',
      source: 'ai',
      reason: '单位换错了',
      correctAnswer: '5 米',
    );

    final draft = (await db.draftsFor(batchId)).single;
    await db.insertQuestion(
      profileId: alice,
      content: '题',
      gradeResult: draft.gradeResult,
      gradeReason: draft.gradeReason,
      correctAnswer: draft.correctAnswer,
    );

    final question = (await db.questionsFor(alice)).single;
    expect(question.gradeReason, '单位换错了');
    expect(question.correctAnswer, '5 米');
  });
}
