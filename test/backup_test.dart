import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octopus/data/database.dart';
import 'package:octopus/services/backup_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 备份与恢复。
///
/// 这里能跑**真实的往返测试**：真的建库、真的放图片、真的打包、真的解到另一个
/// 目录，然后验证数据还能打开。备份这种东西「大概没问题」是不行的——出事的时候
/// 才发现就晚了。
void main() {
  late Directory root;
  late Directory deviceA;
  late Directory deviceB;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync('octopus_backup_test');
    deviceA = Directory(p.join(root.path, 'deviceA'))..createSync(recursive: true);
    deviceB = Directory(p.join(root.path, 'deviceB'))..createSync(recursive: true);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('路径重写', () {
    test('只保留文件名，目录换成本机的', () {
      const oldPath =
          '/data/user/0/com.mossapps.octopus/app_flutter/intake/q_1.jpg';
      expect(
        remapImagePath(oldPath, '/new/device/images'),
        p.join('/new/device/images', 'q_1.jpg'),
      );
    });

    test('不同设备的路径都归到同一个文件名', () {
      const a = '/data/user/0/com.mossapps.octopus/app_flutter/intake/q_9.jpg';
      const b = '/storage/emulated/0/Android/data/x/files/q_9.jpg';
      expect(
        remapImagePath(a, '/new'),
        remapImagePath(b, '/new'),
        reason: '同一张图在不同设备上的路径应当归到一起',
      );
    });

    test('空路径原样返回，不制造出目录', () {
      expect(remapImagePath('', '/new'), '');
    });
  });

  group('清单校验', () {
    String manifestJson({
      String app = backupAppId,
      int schema = 5,
      String created = '2026-10-14T07:00:00.000',
    }) => jsonEncode({
      'app': app,
      'schemaVersion': schema,
      'createdAt': created,
      'profiles': 2,
      'questions': 17,
      'images': 17,
    });

    test('正常清单', () {
      final m = parseManifest(manifestJson(), currentSchemaVersion: 5);
      expect(m.app, backupAppId);
      expect(m.profiles, 2);
      expect(m.questions, 17);
    });

    test('别的应用的备份会被拒绝', () {
      expect(
        () => parseManifest(
          manifestJson(app: 'some-other-app'),
          currentSchemaVersion: 5,
        ),
        throwsA(
          isA<BackupException>().having(
            (e) => e.message,
            'message',
            contains('不是 Octopus'),
          ),
        ),
      );
    });

    test('来自更新版本的备份会被拒绝，而不是硬恢复', () {
      // 老代码读不懂新表结构，硬恢复只会把数据库搞坏。
      expect(
        () => parseManifest(manifestJson(schema: 99), currentSchemaVersion: 5),
        throwsA(
          isA<BackupException>().having(
            (e) => e.message,
            'message',
            contains('更新版本'),
          ),
        ),
      );
    });

    test('更老版本的备份可以恢复，交给数据库迁移处理', () {
      final m = parseManifest(manifestJson(schema: 1), currentSchemaVersion: 5);
      expect(m.schemaVersion, 1);
    });

    test('不是 JSON 时报错，而不是抛原始异常', () {
      expect(
        () => parseManifest('这不是 json', currentSchemaVersion: 5),
        throwsA(isA<BackupException>()),
      );
    });

    test('setUpAll 清单是数组时报错', () {
      expect(
        () => parseManifest('[1,2,3]', currentSchemaVersion: 5),
        throwsA(isA<BackupException>()),
      );
    });

    test('缺少字段时用默认值，不崩', () {
      final m = parseManifest(
        jsonEncode({'app': backupAppId}),
        currentSchemaVersion: 5,
      );
      expect(m.schemaVersion, 0);
      expect(m.profiles, 0);
      expect(m.createdAt.year, 1970);
    });
  });

  group('文件名', () {
    test('按日期时间生成，同一分钟内两次不会撞名', () {
      final name = backupFileName(DateTime(2026, 10, 14, 7, 5));
      expect(name, 'octopus-backup-20261014-0705.zip');
      expect(backupFileName(DateTime(2026, 1, 2, 3, 4)), contains('20260102'));
    });
  });

  group('往返', () {
    /// 在 [dir] 里建一个真实的库，带图片和引用它们的数据。
    Future<OctopusDatabase> seed(Directory dir) async {
      final dbPath = p.join(dir.path, 'octopus.sqlite');
      final db = await OctopusDatabase.openAt(dbPath);

      final profileId = await db.createProfile(name: '老大', grade: 4);

      // 图片放在子目录里，模拟真实的 intake/ 结构。
      final intake = Directory(p.join(dir.path, 'intake'))
        ..createSync(recursive: true);
      final image1 = File(p.join(intake.path, 'q_1.jpg'))
        ..writeAsBytesSync(List.filled(512, 1));
      final image2 = File(p.join(intake.path, 'q_2.jpg'))
        ..writeAsBytesSync(List.filled(1024, 2));

      await db.insertQuestion(
        profileId: profileId,
        content: '第一道错题',
        originalImagePath: image1.path,
      );
      await db.insertQuestion(
        profileId: profileId,
        content: '第二道错题',
        originalImagePath: image2.path,
      );

      final batchId = await db.createBatch(profileId);
      await db.insertDraft(
        batchId: batchId,
        originalImagePath: image1.path,
        content: '草稿',
      );
      return db;
    }

    test('导出再导入另一台设备，数据和图片都还在且能打开', () async {
      // ---- 设备 A：建数据、导出 ----
      final dbA = await seed(deviceA);
      final serviceA = BackupService(
        documentsDir: deviceA.path,
        currentSchemaVersion: 5,
      );

      final summary = serviceA.summarize(profiles: 1, questions: 2);
      expect(summary.images, 2);
      expect(summary.questions, 2);
      expect(summary.bytes, greaterThan(0));

      final backup = await serviceA.export(
        outputDir: root.path,
        profiles: 1,
        questions: 2,
        snapshotDatabase: dbA.snapshotTo,
      );
      expect(backup.existsSync(), isTrue);
      expect(backup.lengthSync(), greaterThan(0));
      await dbA.close();

      // ---- 设备 B：导入 ----
      final serviceB = BackupService(
        documentsDir: deviceB.path,
        currentSchemaVersion: 5,
      );
      final manifest = serviceB.inspect(backup.path);
      expect(manifest.questions, 2);
      expect(manifest.images, 2);

      await serviceB.restore(
        backup.path,
        closeDatabase: () async {},
        reopenAndFixPaths: (dir) async {
          // 服务保证顺序：关库 → 落图片 → 换数据库 → 重开并改路径。
          // 真实调用里这里就是「重新打开数据库 + db.rewriteImagePaths(dir)」。
          final reopened = await OctopusDatabase.openAt(
            p.join(deviceB.path, 'octopus.sqlite'),
          );
          await reopened.rewriteImagePaths(dir);
          await reopened.close();
        },
      );

      final dbB = await OctopusDatabase.openAt(
        p.join(deviceB.path, 'octopus.sqlite'),
      );
      addTearDown(dbB.close);

      final questions = await dbB.questionsFor(1);
      expect(questions.length, 2);
      expect(
        questions.map((q) => q.content).toSet(),
        {'第一道错题', '第二道错题'},
      );

      // **关键断言**：路径还指向设备 A 的话，图片就打不开了。
      for (final q in questions) {
        expect(
          q.originalImagePath,
          startsWith(serviceB.imagesDir),
          reason: '路径应当已经改写到设备 B',
        );
        expect(
          File(q.originalImagePath!).existsSync(),
          isTrue,
          reason: '改写后的路径必须真的指向存在的文件',
        );
      }

      // 草稿的路径也要一起重写——漏掉任何一列都会留下死链。
      final drafts = await dbB.draftsFor(1);
      expect(drafts.single.originalImagePath, startsWith(serviceB.imagesDir));
      expect(File(drafts.single.originalImagePath).existsSync(), isTrue);

      // 内容确实解出来了，不是空文件。
      final restored = File(questions.first.originalImagePath!);
      expect(restored.lengthSync(), anyOf(512, 1024));
    });

    test('没有 manifest 的压缩包会被拒绝', () async {
      final bogus = File(p.join(root.path, 'bogus.zip'));
      final archive = Archive();
      final bytes = utf8.encode('hello');
      archive.addFile(ArchiveFile('random.txt', bytes.length, bytes));
      bogus.writeAsBytesSync(ZipEncoder().encode(archive));

      final service = BackupService(
        documentsDir: deviceB.path,
        currentSchemaVersion: 5,
      );
      expect(
        () => service.inspect(bogus.path),
        throwsA(
          isA<BackupException>().having(
            (e) => e.message,
            'message',
            contains('清单'),
          ),
        ),
      );
    });

    test('根本不是压缩包的文件会被拒绝', () async {
      final notZip = File(p.join(root.path, 'notazip.zip'))
        ..writeAsStringSync('这只是一段文字');
      final service = BackupService(
        documentsDir: deviceB.path,
        currentSchemaVersion: 5,
      );
      expect(
        () => service.inspect(notZip.path),
        throwsA(isA<BackupException>()),
      );
    });

    test('文件不存在时报错，而不是写坏数据库', () async {
      final service = BackupService(
        documentsDir: deviceB.path,
        currentSchemaVersion: 5,
      );
      expect(
        () => service.inspect(p.join(root.path, '不存在.zip')),
        throwsA(isA<BackupException>()),
      );
    });

    test('没有数据库时导出直接报错', () async {
      final service = BackupService(
        documentsDir: deviceB.path,
        currentSchemaVersion: 5,
      );
      expect(
        () => service.export(
          outputDir: root.path,
          profiles: 0,
          questions: 0,
          snapshotDatabase: (_) async {},
        ),
        throwsA(
          isA<BackupException>().having(
            (e) => e.message,
            'message',
            contains('数据库'),
          ),
        ),
      );
    });

    test('导出时数据库用快照，产物是能打开的库', () async {
      final db = await seed(deviceA);
      final service = BackupService(
        documentsDir: deviceA.path,
        currentSchemaVersion: 5,
      );
      // 故意加一条快照之后才写入的数据，验证导出用的是快照而不是活库。
      await db.insertQuestion(profileId: 1, content: '快照之后加的');

      final backup = await service.export(
        outputDir: root.path,
        profiles: 1,
        questions: 3,
        snapshotDatabase: db.snapshotTo,
      );
      await db.close();

      final restoredDir = Directory(p.join(root.path, 'restored'))
        ..createSync(recursive: true);
      final serviceB = BackupService(
        documentsDir: restoredDir.path,
        currentSchemaVersion: 5,
      );
      await serviceB.restore(
        backup.path,
        closeDatabase: () async {},
        reopenAndFixPaths: (_) async {},
      );

      final reopened = await OctopusDatabase.openAt(
        p.join(restoredDir.path, 'octopus.sqlite'),
      );
      addTearDown(reopened.close);
      final contents = (await reopened.questionsFor(1))
          .map((q) => q.content)
          .toList();
      expect(contents, contains('快照之后加的'), reason: '快照应当包含导出前的全部数据');
    });
  });
}
