import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// 备份文件的清单。
///
/// 放在 zip 里的 `manifest.json`。导入前先读它，用来拒绝三种东西：不是本应用
/// 的 zip、版本对不上的 zip、以及内容残缺的 zip。没有这道校验的话，用户随手
/// 选错一个 zip 就可能把数据库覆盖成垃圾。
class BackupManifest {
  const BackupManifest({
    required this.app,
    required this.schemaVersion,
    required this.createdAt,
    required this.profiles,
    required this.questions,
    required this.images,
  });

  /// 固定是 [backupAppId]，用来确认这是 Octopus 的备份。
  final String app;

  /// 数据库 schema 版本。比当前高说明备份来自更新的版本，不能直接恢复。
  final int schemaVersion;

  final DateTime createdAt;
  final int profiles;
  final int questions;
  final int images;

  Map<String, Object?> toJson() => {
    'app': app,
    'schemaVersion': schemaVersion,
    'createdAt': createdAt.toIso8601String(),
    'profiles': profiles,
    'questions': questions,
    'images': images,
  };

  factory BackupManifest.fromJson(Map<String, Object?> json) {
    final app = json['app']?.toString();
    if (app != backupAppId) {
      throw BackupException('这不是 Octopus 的备份文件');
    }
    final rawDate = json['createdAt']?.toString();
    return BackupManifest(
      app: app!,
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.tryParse(rawDate ?? '') ?? DateTime(1970),
      profiles: (json['profiles'] as num?)?.toInt() ?? 0,
      questions: (json['questions'] as num?)?.toInt() ?? 0,
      images: (json['images'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 备份/恢复失败。[message] 是要直接展示给用户的人话。
class BackupException implements Exception {
  BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

const backupAppId = 'octopus';
const backupManifestName = 'manifest.json';
const backupDatabaseName = 'octopus.sqlite';
const backupImagesDir = 'images';

/// 数据库里哪些列存着图片的绝对路径。
///
/// 恢复时必须逐列重写，漏掉任何一列都会留下死链——图片在，但打不开。
const imagePathColumns = <String, List<String>>{
  'draft_questions': ['original_image_path'],
  'questions': ['original_image_path'],
  'question_elements': ['original_image_path'],
};

/// 把数据库里记录的旧路径换成本机的新路径。
///
/// **备份文件里保存的是原设备的绝对路径**（形如
/// `/data/user/0/com.mossapps.octopus/app_flutter/intake/q_1.jpg`）。换台设备、
/// 甚至同一台设备重装之后，这个路径就不存在了。所以恢复时只保留**文件名**，
/// 目录用当前设备的图片目录。
///
/// 纯函数，单独测。
String remapImagePath(String storedPath, String newImagesDir) {
  final name = p.basename(storedPath);
  if (name.isEmpty) return storedPath;
  return p.join(newImagesDir, name);
}

/// 生成备份文件名。
String backupFileName(DateTime at) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'octopus-backup-${at.year}${two(at.month)}${two(at.day)}'
      '-${two(at.hour)}${two(at.minute)}.zip';
}

/// 校验并解析清单。
///
/// [currentSchemaVersion] 是本机数据库版本：备份比它新就拒绝，因为老代码读不懂
/// 新表结构，硬恢复只会把数据库搞坏。
BackupManifest parseManifest(
  String jsonText, {
  required int currentSchemaVersion,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonText);
  } catch (_) {
    throw BackupException('备份文件的清单读不出来，可能已损坏');
  }
  if (decoded is! Map<String, Object?>) {
    throw BackupException('备份文件的清单格式不对');
  }

  final manifest = BackupManifest.fromJson(decoded);
  if (manifest.schemaVersion > currentSchemaVersion) {
    throw BackupException(
      '这个备份来自更新版本的 Octopus（数据库 v${manifest.schemaVersion}，'
      '当前 v$currentSchemaVersion），请先升级应用',
    );
  }
  return manifest;
}

/// 备份的内容概览，用来在导出前告诉用户「要备份多少东西」。
class BackupSummary {
  const BackupSummary({
    required this.profiles,
    required this.questions,
    required this.images,
    required this.bytes,
  });

  final int profiles;
  final int questions;
  final int images;
  final int bytes;

  String get sizeLabel {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// 备份与恢复。
///
/// 打包成一个 zip：数据库 + 所有图片 + 一份清单。用 zip 而不是分别导出，是因为
/// 分享出去的时候用户只会拿到一个文件，不容易漏。
class BackupService {
  BackupService({
    required this.documentsDir,
    required this.currentSchemaVersion,
  });

  /// 应用的文档目录。图片和数据库都在它下面。
  final String documentsDir;
  final int currentSchemaVersion;

  String get databasePath => p.join(documentsDir, backupDatabaseName);

  /// 图片分散在 intake 等子目录里，统一放在文档目录下扫描。
  List<File> _imageFiles() {
    final dir = Directory(documentsDir);
    if (!dir.existsSync()) return const [];
    const imageExtensions = {'.jpg', '.jpeg', '.png', '.webp'};
    return dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => imageExtensions.contains(p.extension(f.path).toLowerCase()))
        .toList();
  }

  /// 统计要备份的内容。导出前展示给用户。
  BackupSummary summarize({required int profiles, required int questions}) {
    final images = _imageFiles();
    var bytes = images.fold<int>(0, (sum, f) => sum + f.lengthSync());
    final db = File(databasePath);
    if (db.existsSync()) bytes += db.lengthSync();
    return BackupSummary(
      profiles: profiles,
      questions: questions,
      images: images.length,
      bytes: bytes,
    );
  }

  /// 打包成 zip 写到 [outputDir]，返回文件路径。
  ///
  /// 打包前先 `VACUUM INTO` 拷一份数据库，而不是直接读原文件：SQLite 在写入
  /// 过程中文件处于中间状态，直接复制可能拿到半个事务。VACUUM INTO 由 SQLite
  /// 自己保证一致性。
  Future<File> export({
    required String outputDir,
    required int profiles,
    required int questions,
    required Future<void> Function(String target) snapshotDatabase,
    DateTime? now,
  }) async {
    final db = File(databasePath);
    if (!db.existsSync()) {
      throw BackupException('还没有数据库文件，没什么可备份的');
    }

    final at = now ?? DateTime.now();
    final tmpDb = File(p.join(outputDir, '_snapshot.sqlite'));
    if (tmpDb.existsSync()) tmpDb.deleteSync();
    await snapshotDatabase(tmpDb.path);

    final images = _imageFiles();
    final archive = Archive();

    archive.addFile(
      ArchiveFile(
        backupDatabaseName,
        tmpDb.lengthSync(),
        tmpDb.readAsBytesSync(),
      ),
    );

    // 图片统一放进 images/，只保留文件名——恢复时按文件名重建路径。
    final seen = <String>{};
    var added = 0;
    for (final file in images) {
      final name = p.basename(file.path);
      // 不同子目录可能有重名文件，加个后缀避免互相覆盖。
      final unique = seen.contains(name)
          ? '${seen.length}_$name'
          : name;
      seen.add(unique);
      final bytes = file.readAsBytesSync();
      archive.addFile(
        ArchiveFile('$backupImagesDir/$unique', bytes.length, bytes),
      );
      added++;
    }

    final manifest = BackupManifest(
      app: backupAppId,
      schemaVersion: currentSchemaVersion,
      createdAt: at,
      profiles: profiles,
      questions: questions,
      images: added,
    );
    final manifestBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
    );
    archive.addFile(
      ArchiveFile(
        backupManifestName,
        manifestBytes.length,
        manifestBytes,
      ),
    );

    final output = File(p.join(outputDir, backupFileName(at)));
    final zipped = ZipEncoder().encode(archive);
    await output.writeAsBytes(zipped);

    if (tmpDb.existsSync()) tmpDb.deleteSync();
    return output;
  }

  /// 读取备份里的清单，不落地任何东西。用户选完文件先给他看这是什么。
  BackupManifest inspect(String zipPath) {
    final file = File(zipPath);
    if (!file.existsSync()) {
      throw BackupException('找不到这个文件');
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
    } catch (_) {
      throw BackupException('这个文件不是有效的压缩包');
    }

    final entry = archive.findFile(backupManifestName);
    if (entry == null) {
      throw BackupException('这个压缩包里没有 Octopus 的备份清单');
    }
    return parseManifest(
      utf8.decode(entry.content as List<int>),
      currentSchemaVersion: currentSchemaVersion,
    );
  }

  /// 从备份恢复。
  ///
  /// 调用方必须提供两个回调，因为服务自己拿不到数据库连接，而这两件事都不能
  /// 省：
  ///
  /// * [closeDatabase] —— 替换数据库文件之前必须关掉连接。sqflite 持有打开的
  ///   文件句柄，在下面直接覆盖文件会让连接读到半新半旧的页。
  /// * [reopenAndFixPaths] —— 换完文件重新打开，并执行 `rewriteImagePaths`。
  ///   备份里存的是**原设备的绝对路径**，不改写的话图片文件明明就在旁边，
  ///   点开每道题却是空白。
  ///
  /// 两者都是**必填**而不是「记得自己调一下」：写成文档一定会有人漏掉，而漏掉
  /// 的后果是用户以为恢复成功了、实际全是死链。做成必填，漏掉是编译不过。
  ///
  /// 顺序由服务保证：关库 → 落图片 → 换数据库 → 重开并改路径。
  Future<BackupManifest> restore(
    String zipPath, {
    required Future<void> Function() closeDatabase,
    required Future<void> Function(String imagesDir) reopenAndFixPaths,
  }) async {
    final manifest = inspect(zipPath);
    final archive = ZipDecoder().decodeBytes(
      File(zipPath).readAsBytesSync(),
    );

    final dbEntry = archive.findFile(backupDatabaseName);
    if (dbEntry == null) {
      throw BackupException('备份里没有数据库文件');
    }

    // 1. 先关连接，否则下面覆盖文件会打架。
    await closeDatabase();

    // 2. 落图片。放在换数据库之前——反过来的话中途失败会留下一个指向不存在
    //    图片的数据库，比不做还糟。
    final images = Directory(imagesDir);
    if (!images.existsSync()) images.createSync(recursive: true);

    var restoredImages = 0;
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      if (!entry.name.startsWith('$backupImagesDir/')) continue;
      final name = p.basename(entry.name);
      if (name.isEmpty) continue;
      File(p.join(images.path, name)).writeAsBytesSync(
        entry.content as List<int>,
      );
      restoredImages++;
    }

    if (restoredImages == 0 && manifest.images > 0) {
      throw BackupException('备份里的图片一个都没解出来，文件可能已损坏');
    }

    // 3. 换数据库。
    await File(databasePath).writeAsBytes(dbEntry.content as List<int>);

    // 4. 重开并修正路径。
    await reopenAndFixPaths(images.path);

    return manifest;
  }

  /// 图片目录。恢复后所有图片都在这里。
  String get imagesDir => p.join(documentsDir, backupImagesDir);
}
