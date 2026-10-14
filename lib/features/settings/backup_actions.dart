import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/theme/octopus_theme.dart';
import '../../data/database.dart';
import '../../providers/app_providers.dart';
import '../../services/backup_service.dart';

/// 导出备份。
///
/// 流程：统计 → 打包 → 交给系统分享。用分享而不是「保存到某个目录」，是因为
/// Android 的分区存储让「保存到用户能找到的地方」很麻烦，而分享面板里用户随手
/// 就能发到微信、网盘或邮件——这才是备份真正要到达的地方。
Future<void> exportBackup(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  final docs = await getApplicationDocumentsDirectory();
  final db = ref.read(databaseProvider);

  final profiles = await db.allProfiles();
  final questions = await db.questionsFor(
    ref.read(currentProfileProvider) ?? (profiles.isEmpty ? -1 : profiles.first.id),
  );

  final service = BackupService(
    documentsDir: docs.path,
    currentSchemaVersion: 5,
  );

  final summary = service.summarize(
    profiles: profiles.length,
    questions: questions.length,
  );

  if (!context.mounted) return;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('导出备份'),
      content: Text(
        '将打包：\n'
        '· ${profiles.length} 个孩子\n'
        '· ${summary.images} 张题目图片\n'
        '· 全部错题、批改记录和复习计划\n\n'
        '预计大小 ${summary.sizeLabel}。\n\n'
        '打包后会打开分享面板，你可以发到微信、网盘或邮箱。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('开始导出'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  try {
    final file = await service.export(
      outputDir: docs.path,
      profiles: profiles.length,
      questions: summary.questions,
      // 通过 VACUUM INTO 取一致性快照，而不是直接读活库文件。
      snapshotDatabase: db.snapshotTo,
    );

    final size = (file.lengthSync() / 1024 / 1024).toStringAsFixed(1);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        subject: 'Octopus 错题集备份',
        text: 'Octopus 备份（$size MB）。在应用的「设置 → 数据备份」里可以恢复。',
      ),
    );

    // 分享完把临时文件删掉，免得在文档目录里越堆越多。
    if (file.existsSync()) file.deleteSync();
  } on BackupException catch (error) {
    messenger.showSnackBar(SnackBar(content: Text('导出失败：${error.message}')));
  } catch (error) {
    messenger.showSnackBar(SnackBar(content: Text('导出失败：$error')));
  }
}

/// 从备份恢复。
///
/// **会覆盖当前全部数据**，所以先让用户看清楚这个 zip 里是什么，再二次确认。
Future<void> importBackup(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  final docs = await getApplicationDocumentsDirectory();
  final service = BackupService(
    documentsDir: docs.path,
    currentSchemaVersion: 5,
  );

  // file_picker 13 把 pickFiles 改成了静态方法，返回 List 而不是可空结果对象。
  final files = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['zip'],
  );
  if (files.isEmpty) return;
  final path = files.first.path;
  if (path == null) return;

  // 先只读清单，不落地任何东西——用户可能选错文件。
  final BackupManifest manifest;
  try {
    manifest = service.inspect(path);
  } on BackupException catch (error) {
    messenger.showSnackBar(SnackBar(content: Text('打不开这个备份：${error.message}')));
    return;
  }

  if (!context.mounted) return;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('恢复备份'),
      content: Text(
        '这个备份包含：\n'
        '· ${manifest.profiles} 个孩子\n'
        '· ${manifest.images} 张图片\n'
        '· 数据库 v${manifest.schemaVersion}\n'
        '· 导出于 ${_formatDate(manifest.createdAt)}\n\n'
        '⚠️ 恢复会**覆盖当前的全部数据**，且无法撤销。\n'
        '如果现在的数据还要，请先导出一份备份。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: OctopusColors.danger,
          ),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('覆盖并恢复'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  final db = ref.read(databaseProvider);
  try {
    await service.restore(
      path,
      // sqflite 持有打开的文件句柄，替换数据库文件之前必须先关掉，
      // 否则连接会读到半新半旧的页。
      closeDatabase: db.close,
      reopenAndFixPaths: (imagesDir) async {
        // 换完文件重新打开，然后立刻把图片路径改成本机的。
        // 不做这一步的话，图片文件就在旁边，界面上却全是打不开。
        final reopened = await OctopusDatabase.openAt(service.databasePath);
        await reopened.rewriteImagePaths(imagesDir);
        await reopened.close();
      },
    );

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('恢复完成'),
        content: const Text(
          '数据已经恢复。\n\n'
          '请**完全退出并重新打开**应用，让新的数据生效。',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  } on BackupException catch (error) {
    messenger.showSnackBar(SnackBar(content: Text('恢复失败：${error.message}')));
  } catch (error) {
    messenger.showSnackBar(SnackBar(content: Text('恢复失败：$error')));
  }
}

String _formatDate(DateTime at) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}';
}

/// 备份提示卡。放在设置里，说明为什么值得做。
class BackupHint extends StatelessWidget {
  const BackupHint({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 6),
            child: Icon(
              Icons.warning_amber_rounded,
              size: 14,
              color: OctopusColors.textSecondary,
            ),
          ),
          Expanded(
            child: Text(
              '照片和数据都只存在这台手机上。手机丢了、重置了、或者卸载了应用，'
              '积攒的错题就没了。建议过一段时间导出一次，存到网盘或发给自己。',
              style: TextStyle(
                fontSize: 12,
                height: 1.65,
                color: OctopusColors.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 备份文件在文档目录里可能残留，启动时清一下。
Future<void> cleanStaleBackups() async {
  try {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(docs.path);
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync()) {
      if (entity is File &&
          p.basename(entity.path).startsWith('octopus-backup-')) {
        entity.deleteSync();
      }
    }
  } catch (_) {
    // 清理失败无所谓，不影响主流程。
  }
}
