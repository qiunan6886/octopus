import 'package:flutter_test/flutter_test.dart';
import 'package:octopus/data/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 数据层的关键保证：**题目按孩子隔离**。
///
/// 这是这个产品最容易出、后果最严重的一类错误——把老二的题打进老大的卷子。
/// 所以隔离做在存储层，这里直接对着真实的 SQLite 验证它真的成立。
void main() {
  late OctopusDatabase db;

  setUpAll(() {
    // 桌面环境下没有 Android 的 SQLite，用 FFI 那一套。
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await OctopusDatabase.openAt(inMemoryDatabasePath);
  });

  tearDown(() async {
    await db.close();
  });

  test('题目只能查到所属孩子的', () async {
    final alice = await db.createProfile(name: '老大', grade: 4);
    final bob = await db.createProfile(name: '老二', grade: 2);

    await db.insertQuestion(profileId: alice, content: '老大的题');
    await db.insertQuestion(profileId: bob, content: '老二的题');
    await db.insertQuestion(profileId: alice, content: '老大的第二题');

    final aliceQuestions = await db.questionsFor(alice);
    final bobQuestions = await db.questionsFor(bob);

    expect(aliceQuestions.length, 2);
    expect(bobQuestions.length, 1);
    expect(aliceQuestions.map((q) => q.content), isNot(contains('老二的题')));
    expect(bobQuestions.single.content, '老二的题');
    expect(aliceQuestions.every((q) => q.profileId == alice), isTrue);
    expect(bobQuestions.every((q) => q.profileId == bob), isTrue);
  });

  test('删除孩子会连带删掉他的题，但不动别人的', () async {
    final alice = await db.createProfile(name: '老大', grade: 4);
    final bob = await db.createProfile(name: '老二', grade: 2);

    await db.insertQuestion(profileId: alice, content: 'a');
    await db.insertQuestion(profileId: bob, content: 'b');

    await db.deleteProfile(alice);

    expect(await db.questionsFor(alice), isEmpty);
    expect((await db.questionsFor(bob)).length, 1);
  });

  test('删除题目必须带上 profileId，删不到别人的题', () async {
    final alice = await db.createProfile(name: '老大', grade: 4);
    final bob = await db.createProfile(name: '老二', grade: 2);

    final aliceQuestionId = await db.insertQuestion(
      profileId: alice,
      content: 'a',
    );

    // 用 bob 的身份去删 alice 的题：应当一条都删不掉。
    await db.deleteQuestions(bob, [aliceQuestionId]);
    expect((await db.questionsFor(alice)).length, 1);

    // 用自己的身份才删得掉。
    await db.deleteQuestions(alice, [aliceQuestionId]);
    expect(await db.questionsFor(alice), isEmpty);
  });

  test('批次继承孩子的归属，草稿通过后才变成题', () async {
    final alice = await db.createProfile(name: '老大', grade: 4);
    final batchId = await db.createBatch(alice);

    await db.insertDraft(batchId: batchId, originalImagePath: '/tmp/a.jpg');

    // 草稿阶段不进错题库——这是整个设计的核心安全阀。
    expect(await db.questionsFor(alice), isEmpty);

    final batch = await db.batchById(batchId);
    expect(batch?.profileId, alice);
    expect((await db.draftsFor(batchId)).length, 1);
    expect(await db.pendingDraftCount(batchId), 1);

    // 通过之后才出现在错题库里。
    await db.updateDraft(
      (await db.draftsFor(batchId)).single.id,
      reviewStatus: 'accepted',
    );
    expect(await db.pendingDraftCount(batchId), 0);
  });

  test('掌握状态按孩子隔离地更新', () async {
    final alice = await db.createProfile(name: '老大', grade: 4);
    final bob = await db.createProfile(name: '老二', grade: 2);

    final aliceId = await db.insertQuestion(profileId: alice, content: 'a');
    final bobId = await db.insertQuestion(profileId: bob, content: 'b');

    // 用 alice 的身份去改 bob 的题：不应生效。
    await db.setMastery(alice, [bobId], 'mastered');
    expect((await db.questionsFor(bob)).single.mastery, 'new');

    await db.setMastery(alice, [aliceId], 'mastered');
    expect((await db.questionsFor(alice)).single.mastery, 'mastered');
  });

  test('练习卷按顺序取回题目', () async {
    final alice = await db.createProfile(name: '老大', grade: 4);
    final first = await db.insertQuestion(profileId: alice, content: '第一题');
    final second = await db.insertQuestion(profileId: alice, content: '第二题');

    final sheet = await db.createWorksheet(alice, '练习卷');
    // 故意倒着加，验证取回时按 sort_order 而不是插入顺序。
    await db.addWorksheetItem(sheet, second, 1);
    await db.addWorksheetItem(sheet, first, 0);

    final ordered = await db.worksheetQuestions(sheet);
    expect(ordered.map((q) => q.content).toList(), ['第一题', '第二题']);
  });

  test('删除练习卷不会删掉题目本身', () async {
    final alice = await db.createProfile(name: '老大', grade: 4);
    final q = await db.insertQuestion(profileId: alice, content: '题');
    final sheet = await db.createWorksheet(alice, '卷');
    await db.addWorksheetItem(sheet, q, 0);

    await db.deleteWorksheet(alice, sheet);

    expect(await db.worksheetsFor(alice), isEmpty);
    expect((await db.questionsFor(alice)).length, 1);
  });

  test('watch 在数据变化后重新发出', () async {
    final alice = await db.createProfile(name: '老大', grade: 4);
    final other = await db.createProfile(name: '老二', grade: 2);

    // 用 take(2) 而不是长期订阅：流会自己结束，测试不会因为挂着一个活跃订阅
    // 而等到超时。
    final emissions = db.watchQuestionsFor(alice).take(2).toList();

    // 等首次查询发出来。
    await Future<void>.delayed(const Duration(milliseconds: 80));

    // 给另一个孩子加题也要触发重查——通知是全局的，但查出来的结果仍然只有
    // alice 的题。宁可多查一次，也不要漏掉。
    await db.insertQuestion(profileId: other, content: '别人的题');
    await db.insertQuestion(profileId: alice, content: '我的题');

    final pages = await emissions;
    expect(pages.first, isEmpty);
    expect(pages.last.length, 1);
    expect(pages.last.single.content, '我的题');
  });
}
