import 'package:flutter_test/flutter_test.dart';
import 'package:octopus/data/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// schema v1 -> v2 的迁移。
///
/// v2 给批改加了三个字段。用户手机上已经有 v1 的库，升级时不能丢数据——这里
/// 先造一个货真价实的 v1 库（用当时的建表语句），再用当前代码打开，验证列加上
/// 了、老数据还在。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('v1 的库升级到 v2 后，批改字段可用且老数据不丢', () async {
    // 用内存库没法跨两次 open 保留数据，所以走临时文件。
    final dir = await databaseFactory.getDatabasesPath();
    final path = '$dir/octopus_migration_test.sqlite';
    await databaseFactory.deleteDatabase(path);

    // ---- 造一个 v1 库（v1 的建表语句，不含批改字段）----
    final v1 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE profiles (
              id         INTEGER PRIMARY KEY AUTOINCREMENT,
              name       TEXT    NOT NULL,
              grade      INTEGER NOT NULL,
              created_at INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE intake_batches (
              id         INTEGER PRIMARY KEY AUTOINCREMENT,
              profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
              status     TEXT    NOT NULL DEFAULT 'processing',
              created_at INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE draft_questions (
              id                   INTEGER PRIMARY KEY AUTOINCREMENT,
              batch_id             INTEGER NOT NULL REFERENCES intake_batches(id) ON DELETE CASCADE,
              original_image_path  TEXT    NOT NULL,
              content              TEXT    NOT NULL DEFAULT '',
              subject              TEXT,
              knowledge_tags       TEXT,
              review_status        TEXT    NOT NULL DEFAULT 'pending',
              accepted_question_id INTEGER,
              sort_order           INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await db.execute('''
            CREATE TABLE questions (
              id                     INTEGER PRIMARY KEY AUTOINCREMENT,
              profile_id             INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
              content                TEXT    NOT NULL DEFAULT '',
              original_image_path    TEXT,
              subject                TEXT,
              knowledge_tags         TEXT,
              source                 TEXT,
              mastery                TEXT    NOT NULL DEFAULT 'new',
              uses_ai_redrawn_figure INTEGER NOT NULL DEFAULT 0,
              review_count           INTEGER NOT NULL DEFAULT 0,
              created_at             INTEGER NOT NULL,
              last_reviewed_at       INTEGER
            )
          ''');
          await db.execute('''
            CREATE TABLE question_elements (
              id                  INTEGER PRIMARY KEY AUTOINCREMENT,
              question_id         INTEGER NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
              kind                TEXT    NOT NULL,
              sort_order          INTEGER NOT NULL DEFAULT 0,
              content             TEXT,
              original_image_path TEXT,
              generated_source    TEXT,
              chosen              TEXT    NOT NULL DEFAULT 'original'
            )
          ''');
          await db.execute('''
            CREATE TABLE worksheets (
              id          INTEGER PRIMARY KEY AUTOINCREMENT,
              profile_id  INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
              name        TEXT    NOT NULL DEFAULT '',
              layout_json TEXT,
              created_at  INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE worksheet_items (
              id           INTEGER PRIMARY KEY AUTOINCREMENT,
              worksheet_id INTEGER NOT NULL REFERENCES worksheets(id) ON DELETE CASCADE,
              question_id  INTEGER NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
              sort_order   INTEGER NOT NULL DEFAULT 0
            )
          ''');
        },
      ),
    );

    // v1 时代的真实数据
    final profileId = await v1.insert('profiles', {
      'name': '老大',
      'grade': 4,
      'created_at': 1,
    });
    final batchId = await v1.insert('intake_batches', {
      'profile_id': profileId,
      'created_at': 1,
    });
    await v1.insert('draft_questions', {
      'batch_id': batchId,
      'original_image_path': '/tmp/old.jpg',
      'content': 'v1 时代的题',
    });
    await v1.close();

    // ---- 用当前代码打开，应当触发 onUpgrade ----
    final db = await OctopusDatabase.openAt(path);
    addTearDown(() async {
      await db.close();
      await databaseFactory.deleteDatabase(path);
    });

    // 老数据还在
    final drafts = await db.draftsFor(batchId);
    expect(drafts.length, 1);
    expect(drafts.single.content, 'v1 时代的题');
    // 老题没有批改结果，应当是「未判断」而不是被判成错
    expect(drafts.single.gradeResult, isNull);
    expect(drafts.single.isGraded, isFalse);
    expect(drafts.single.correctAnswer, isNull);

    // 新字段真的可写可读
    await db.setDraftGrade(
      drafts.single.id,
      result: 'wrong',
      correctAnswer: '42',
      source: 'manual',
    );
    final graded = (await db.draftsFor(batchId)).single;
    expect(graded.isWrong, isTrue);
    expect(graded.correctAnswer, '42');
    expect(graded.gradeSource, 'manual');

    // questions 表的新字段同样可用
    final questionId = await db.insertQuestion(
      profileId: profileId,
      content: '一道错题',
      correctAnswer: '7',
      gradeResult: 'wrong',
    );
    final question = (await db.questionsFor(profileId)).firstWhere(
      (q) => q.id == questionId,
    );
    expect(question.correctAnswer, '7');
    expect(question.gradeResult, 'wrong');

    // v3 的两个字段：老题没有重绘、也不是变式题。
    expect(question.redrawnSvg, isNull);
    expect(question.variantOfQuestionId, isNull);

    // v4 的字段：老题没有批改理由。
    expect(question.gradeReason, isNull);

    // 重绘结果可以写入，而且**默认不选中**——必须先让用户和原图对照。
    const svg = '<svg viewBox="0 0 10 10"><rect/></svg>';
    await db.setRedrawn(profileId, questionId, svg: svg);
    var updated = (await db.questionsFor(profileId)).single;
    expect(updated.redrawnSvg, svg);
    expect(updated.usesAiRedrawnFigure, isFalse, reason: '存下来不等于选中');

    // 用户对照之后才切到重绘版。
    await db.setUseRedrawn(profileId, questionId, true);
    updated = (await db.questionsFor(profileId)).single;
    expect(updated.usesAiRedrawnFigure, isTrue);

    // 变式题能记住来源。
    final variantId = await db.insertQuestion(
      profileId: profileId,
      content: '变式题',
      variantOfQuestionId: questionId,
    );
    final variant = (await db.questionsFor(profileId)).firstWhere(
      (q) => q.id == variantId,
    );
    expect(variant.variantOfQuestionId, questionId);
  });

  test('同一个库文件可以反复打开，数据不丢', () async {    final dir = await databaseFactory.getDatabasesPath();
    final path = '$dir/octopus_migration_v2_test.sqlite';
    await databaseFactory.deleteDatabase(path);

    // 造一个 v2 库：直接用当前 schema 建，然后把 version 写成 2，
    // 这样 onUpgrade 会从 2 跑到 3。
    final db = await OctopusDatabase.openAt(path);
    final profileId = await db.createProfile(name: '老大', grade: 4);
    final batchId = await db.createBatch(profileId);
    await db.insertDraft(
      batchId: batchId,
      originalImagePath: '/tmp/a.jpg',
      content: 'v2 时代的题',
    );
    await db.close();

    // 重开一次。schemaVersion 已经是 3，所以这次不会触发升级——
    // 但能验证同一个文件被反复打开是稳定的。
    final reopened = await OctopusDatabase.openAt(path);
    addTearDown(() async {
      await reopened.close();
      await databaseFactory.deleteDatabase(path);
    });

    final drafts = await reopened.draftsFor(batchId);
    expect(drafts.single.content, 'v2 时代的题');
    expect(drafts.single.gradeResult, isNull);

    // 新字段可用。
    await reopened.setDraftGrade(
      drafts.single.id,
      result: 'wrong',
      source: 'manual',
    );
    expect((await reopened.draftsFor(batchId)).single.isWrong, isTrue);

    expect(await reopened.questionsFor(profileId), isEmpty);
    final qid = await reopened.insertQuestion(
      profileId: profileId,
      content: '题',
    );
    await reopened.setRedrawn(
      profileId,
      qid,
      svg: '<svg viewBox="0 0 1 1"/>',
      use: true,
    );
    expect(
      (await reopened.questionsFor(profileId)).single.usesAiRedrawnFigure,
      isTrue,
    );

    // v4：批改的理由和知识点。
    final draftId = (await reopened.draftsFor(batchId)).single.id;
    await reopened.setDraftGrade(
      draftId,
      result: 'wrong',
      source: 'ai',
      reason: '漏了进位',
      subject: '数学',
      knowledgeTags: '两位数乘法',
    );
    final graded = (await reopened.draftsFor(batchId)).single;
    expect(graded.gradeReason, '漏了进位');
    expect(graded.knowledgeTags, '两位数乘法');

    final stats = await reopened.gradingStats(profileId);
    expect(stats.single.subject, '数学');
    expect(stats.single.wrong, 1);
  });
}
