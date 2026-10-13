import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'models.dart';

export 'models.dart';

/// 本地数据库。
///
/// 用 `sqflite` 而不是 drift：drift 2.32 之后的版本会在**编译时**从 GitHub
/// 下载预编译的 SQLite 库（`sqlite3` 的构建钩子），网络不通就整个构建失败。
/// sqflite 直接用 Android 系统自带的 SQLite，没有原生资源、不需要联网，
/// 构建永远可复现。
///
/// 代价是失去编译期的查询检查，所以这里用一条纪律补回来：
/// **任何读写题目的方法都必须接收 profileId**，不给"忘了过滤"留机会。
class OctopusDatabase {
  OctopusDatabase._(this._db);

  final Database _db;

  /// 任何写入之后都会发一次事件，`watch*` 据此重新查询。
  ///
  /// sqflite 没有响应式查询，所以自己发通知。这个应用的数据量很小，
  /// 变更后整表重查完全够用，比维护一套细粒度的失效逻辑简单得多。
  final _changes = StreamController<void>.broadcast();

  static Future<OctopusDatabase> open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'octopus.sqlite');
    return openAt(path);
  }

  /// 指定路径打开。测试传 `inMemoryDatabasePath`。
  static Future<OctopusDatabase> openAt(String path) async {
    final db = await openDatabase(
      path,
      version: 1,
      onConfigure: (db) async {
        // SQLite **默认不开外键约束**。不打开的话，建表时写的
        // `ON DELETE CASCADE` 完全不起作用，删掉一个孩子会留下一堆无主的题。
        // 这个坑之前被测试抓到过一次。
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _createSchema,
    );
    return OctopusDatabase._(db);
  }

  Future<void> close() async {
    await _changes.close();
    await _db.close();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// 先查一次，之后每次数据变化再查一次。
  Stream<List<T>> _watch<T>(Future<List<T>> Function() query) async* {
    yield await query();
    await for (final _ in _changes.stream) {
      yield await query();
    }
  }

  static Future<void> _createSchema(Database db, int version) async {
    final batch = db.batch();

    batch.execute('''
      CREATE TABLE profiles (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        name       TEXT    NOT NULL,
        grade      INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE intake_batches (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
        status     TEXT    NOT NULL DEFAULT 'processing',
        created_at INTEGER NOT NULL
      )
    ''');

    batch.execute('''
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

    // content 而不是 text：`text` 在 SQL 里是类型名，容易在拼接语句时混淆。
    batch.execute('''
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

    batch.execute('''
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

    batch.execute('''
      CREATE TABLE worksheets (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        profile_id  INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
        name        TEXT    NOT NULL DEFAULT '',
        layout_json TEXT,
        created_at  INTEGER NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE worksheet_items (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        worksheet_id INTEGER NOT NULL REFERENCES worksheets(id) ON DELETE CASCADE,
        question_id  INTEGER NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
        sort_order   INTEGER NOT NULL DEFAULT 0
      )
    ''');

    batch.execute('CREATE INDEX idx_questions_profile ON questions(profile_id)');
    batch.execute('CREATE INDEX idx_drafts_batch ON draft_questions(batch_id)');
    batch.execute(
      'CREATE INDEX idx_worksheet_items ON worksheet_items(worksheet_id)',
    );

    await batch.commit(noResult: true);
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  // -------------------------------------------------------------------------
  // 孩子
  // -------------------------------------------------------------------------

  Future<List<Profile>> allProfiles() async {
    final rows = await _db.query('profiles', orderBy: 'created_at');
    return rows.map(Profile.fromMap).toList();
  }

  Stream<List<Profile>> watchProfiles() => _watch(allProfiles);

  Future<int> createProfile({required String name, required int grade}) async {
    final id = await _db.insert('profiles', {
      'name': name,
      'grade': grade,
      'created_at': _now(),
    });
    _notify();
    return id;
  }

  Future<void> updateProfile(int id, {String? name, int? grade}) async {
    await _db.update(
      'profiles',
      {'name': ?name, 'grade': ?grade},
      where: 'id = ?',
      whereArgs: [id],
    );
    _notify();
  }

  /// 删除孩子会连带删掉他的题、批次和练习卷（靠外键 CASCADE）。
  Future<void> deleteProfile(int id) async {
    await _db.delete('profiles', where: 'id = ?', whereArgs: [id]);
    _notify();
  }

  // -------------------------------------------------------------------------
  // 错题库 —— 一律带 profileId
  // -------------------------------------------------------------------------

  Future<List<Question>> questionsFor(int profileId) async {
    final rows = await _db.query(
      'questions',
      where: 'profile_id = ?',
      whereArgs: [profileId],
      orderBy: 'created_at DESC',
    );
    return rows.map(Question.fromMap).toList();
  }

  Stream<List<Question>> watchQuestionsFor(int profileId) =>
      _watch(() => questionsFor(profileId));

  Future<int> insertQuestion({
    required int profileId,
    String content = '',
    String? originalImagePath,
    String? subject,
    String? source,
    bool usesAiRedrawnFigure = false,
  }) async {
    final id = await _db.insert('questions', {
      'profile_id': profileId,
      'content': content,
      'original_image_path': originalImagePath,
      'subject': subject,
      'source': source,
      'uses_ai_redrawn_figure': usesAiRedrawnFigure ? 1 : 0,
      'created_at': _now(),
    });
    _notify();
    return id;
  }

  Future<void> deleteQuestions(int profileId, List<int> ids) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(', ');
    await _db.delete(
      'questions',
      // profile_id 是条件的一部分：拿错孩子的身份就删不到别人的题。
      where: 'profile_id = ? AND id IN ($placeholders)',
      whereArgs: [profileId, ...ids],
    );
    _notify();
  }

  Future<void> setMastery(
    int profileId,
    List<int> ids,
    String mastery,
  ) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(', ');
    await _db.update(
      'questions',
      {'mastery': mastery},
      where: 'profile_id = ? AND id IN ($placeholders)',
      whereArgs: [profileId, ...ids],
    );
    _notify();
  }

  Future<List<QuestionElement>> elementsFor(int questionId) async {
    final rows = await _db.query(
      'question_elements',
      where: 'question_id = ?',
      whereArgs: [questionId],
      orderBy: 'sort_order',
    );
    return rows.map(QuestionElement.fromMap).toList();
  }

  Future<int> insertElement({
    required int questionId,
    required String kind,
    int sortOrder = 0,
    String? content,
    String? originalImagePath,
    String? generatedSource,
  }) async {
    final id = await _db.insert('question_elements', {
      'question_id': questionId,
      'kind': kind,
      'sort_order': sortOrder,
      'content': content,
      'original_image_path': originalImagePath,
      'generated_source': generatedSource,
    });
    _notify();
    return id;
  }

  // -------------------------------------------------------------------------
  // 录入与待确认
  // -------------------------------------------------------------------------

  Future<int> createBatch(int profileId) async {
    final id = await _db.insert('intake_batches', {
      'profile_id': profileId,
      'created_at': _now(),
    });
    _notify();
    return id;
  }

  Future<IntakeBatch?> batchById(int batchId) async {
    final rows = await _db.query(
      'intake_batches',
      where: 'id = ?',
      whereArgs: [batchId],
      limit: 1,
    );
    return rows.isEmpty ? null : IntakeBatch.fromMap(rows.first);
  }

  Future<int> insertDraft({
    required int batchId,
    required String originalImagePath,
    String content = '',
    int sortOrder = 0,
  }) async {
    final id = await _db.insert('draft_questions', {
      'batch_id': batchId,
      'original_image_path': originalImagePath,
      'content': content,
      'sort_order': sortOrder,
    });
    _notify();
    return id;
  }

  Future<List<DraftQuestion>> draftsFor(int batchId) async {
    final rows = await _db.query(
      'draft_questions',
      where: 'batch_id = ?',
      whereArgs: [batchId],
      orderBy: 'sort_order',
    );
    return rows.map(DraftQuestion.fromMap).toList();
  }

  Stream<List<DraftQuestion>> watchDraftsFor(int batchId) =>
      _watch(() => draftsFor(batchId));

  Future<void> updateDraft(
    int draftId, {
    String? content,
    String? subject,
    String? reviewStatus,
    int? acceptedQuestionId,
  }) async {
    await _db.update(
      'draft_questions',
      {
        'content': ?content,
        'subject': ?subject,
        'review_status': ?reviewStatus,
        'accepted_question_id': ?acceptedQuestionId,
      },
      where: 'id = ?',
      whereArgs: [draftId],
    );
    _notify();
  }

  Future<void> setBatchStatus(int batchId, String status) async {
    await _db.update(
      'intake_batches',
      {'status': status},
      where: 'id = ?',
      whereArgs: [batchId],
    );
    _notify();
  }

  /// 还有多少题没审核。用来决定「全部通过」之后是否还有事要做。
  Future<int> pendingDraftCount(int batchId) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM draft_questions '
      'WHERE batch_id = ? AND review_status = ?',
      [batchId, 'pending'],
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  // -------------------------------------------------------------------------
  // 练习卷
  // -------------------------------------------------------------------------

  Future<int> createWorksheet(int profileId, String name) async {
    final id = await _db.insert('worksheets', {
      'profile_id': profileId,
      'name': name,
      'created_at': _now(),
    });
    _notify();
    return id;
  }

  Future<List<Worksheet>> worksheetsFor(int profileId) async {
    final rows = await _db.query(
      'worksheets',
      where: 'profile_id = ?',
      whereArgs: [profileId],
      orderBy: 'created_at DESC',
    );
    return rows.map(Worksheet.fromMap).toList();
  }

  Stream<List<Worksheet>> watchWorksheetsFor(int profileId) =>
      _watch(() => worksheetsFor(profileId));

  Future<void> deleteWorksheet(int profileId, int worksheetId) async {
    await _db.delete(
      'worksheets',
      where: 'profile_id = ? AND id = ?',
      whereArgs: [profileId, worksheetId],
    );
    _notify();
  }

  Future<void> addWorksheetItem(
    int worksheetId,
    int questionId,
    int order,
  ) async {
    await _db.insert('worksheet_items', {
      'worksheet_id': worksheetId,
      'question_id': questionId,
      'sort_order': order,
    });
    _notify();
  }

  Future<List<Question>> worksheetQuestions(int worksheetId) async {
    final rows = await _db.rawQuery(
      'SELECT q.* FROM worksheet_items wi '
      'JOIN questions q ON q.id = wi.question_id '
      'WHERE wi.worksheet_id = ? '
      'ORDER BY wi.sort_order',
      [worksheetId],
    );
    return rows.map(Question.fromMap).toList();
  }
}
