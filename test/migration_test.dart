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
  });
}
