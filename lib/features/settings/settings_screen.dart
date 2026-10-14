import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/octopus_theme.dart';
import '../../data/database.dart';
import '../../providers/app_providers.dart';
import '../shell/app_shell.dart' show showProfileEditor;
import 'backup_actions.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider).value ?? const <Profile>[];
    final themeChoice = ref.watch(themeChoiceProvider);
    final ocr = ref.watch(ocrEngineProvider);
    final apiKey = ref.watch(deepSeekKeyProvider);
    final printName = ref.watch(printChildNameProvider);
    final gradingEnabled = ref.watch(gradingEnabledProvider);
    final keepCorrect = ref.watch(gradingKeepCorrectProvider);
    final aiGrading = ref.watch(aiGradingProvider);
    final autoOcr = ref.watch(autoOcrProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OctopusSpacing.page,
        4,
        OctopusSpacing.page,
        32,
      ),
      children: [
        Text(
          '设置',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            color: OctopusColors.textPrimary,
          ),
        ),
        const SizedBox(height: 20),

        // -- 孩子 -------------------------------------------------------------
        const _SectionLabel('孩子'),
        _Card(
          children: [
            for (final p in profiles)
              _NavRow(
                title: p.name,
                subtitle: _gradeLabel(p.grade),
                onTap: () =>
                    showProfileEditor(context, ref, existing: p),
              ),
            _NavRow(
              title: '添加孩子',
              trailingIcon: Icons.add,
              onTap: () => showProfileEditor(context, ref),
            ),
          ],
        ),
        const _SectionHint('每道错题都归属于某个孩子，两个孩子的题目不会混在一起。'),

        // -- 外观 -------------------------------------------------------------
        const _SectionLabel('外观'),
        _Card(
          children: [
            _ChoiceRow<ThemeChoice>(
              title: '主题',
              value: themeChoice,
              options: const {
                ThemeChoice.system: '跟随系统',
                ThemeChoice.paper: '纸（浅色）',
                ThemeChoice.ink: '墨（深色）',
                ThemeChoice.vivid: '彩（缤纷）',
              },
              onChanged: (v) => ref.read(themeChoiceProvider.notifier).set(v),
            ),
          ],
        ),
        _SectionHint(
          themeChoice == ThemeChoice.vivid
              ? '「彩」用淡紫纸面配紫、珊瑚、琥珀多组颜色，头部有渐变，学科标签按科目上色。'
              : '「纸」是白底黑字，「墨」是黑底白字，两套互为反色。'
                    '单色是默认——屏幕上的主角是试卷照片，彩色会和题目抢注意力。',
        ),

        // -- 识别 -------------------------------------------------------------
        const _SectionLabel('识别'),
        _Card(
          children: [
            _ChoiceRow<OcrEngineKind>(
              title: 'OCR 引擎',
              value: ocr,
              options: const {
                OcrEngineKind.local: '本地',
                OcrEngineKind.cloud: '云端',
              },
              onChanged: (v) => ref.read(ocrEngineProvider.notifier).set(v),
            ),
            _ToggleRow(
              title: '切题后自动识别',
              subtitle: '不用再手动点一次',
              value: autoOcr,
              onChanged: (v) => ref.read(autoOcrProvider.notifier).set(v),
            ),
          ],
        ),
        _SectionHint(
          switch (ocr) {
            OcrEngineKind.local =>
              '本地识别用 Google ML Kit，完全离线、免费，照片不出设备。'
                  '它擅长印刷体（题干正好是印刷体），但读不了手写字。',
            OcrEngineKind.cloud =>
              '云端识别用 DeepSeek 的视觉模型，能读手写体、能理解版面，也能把公式'
                  '转成 LaTeX。代价是题目照片会上传到 DeepSeek。',
          },
          warn: ocr == OcrEngineKind.cloud,
        ),
        if (ocr == OcrEngineKind.cloud && apiKey.trim().isEmpty)
          const _SectionHint(
            '还没配置 API Key，云端识别暂时不可用——会自动退回本地识别。',
            warn: true,
          ),

        // -- 批改 -------------------------------------------------------------
        const _SectionLabel('批改'),
        _Card(
          children: [
            _ToggleRow(
              title: '拍照后批改',
              subtitle: '拍完自动判断每道题对错，只把错题入库',
              value: gradingEnabled,
              onChanged: (v) =>
                  ref.read(gradingEnabledProvider.notifier).set(v),
            ),
            if (gradingEnabled)
              _ToggleRow(
                title: '用 AI 批改',
                subtitle: apiKey.trim().isEmpty
                    ? '需要先配置 DeepSeek API Key'
                    : '把每题的照片发给 DeepSeek 判断对错',
                value: aiGrading && apiKey.trim().isNotEmpty,
                onChanged: apiKey.trim().isEmpty
                    ? null
                    : (v) => ref.read(aiGradingProvider.notifier).set(v),
              ),
            if (gradingEnabled)
              _ToggleRow(
                title: '做对的题也入库',
                subtitle: '默认只留错题',
                value: keepCorrect,
                onChanged: (v) =>
                    ref.read(gradingKeepCorrectProvider.notifier).set(v),
              ),
          ],
        ),
        _SectionHint(
          gradingEnabled
              ? '批改和录入是同一条流程——「错题」本来就是做错的题，所以只是多了一步'
                    '判断对错。AI 关掉或没配 Key 时，可以自己点「做对了 / 做错了」。'
              : '打开后，拍照流程里会多一步判断对错，只把做错的题收进错题库。',
        ),

        // -- AI ---------------------------------------------------------------
        const _SectionLabel('AI'),
        _Card(
          children: [
            _NavRow(
              title: 'DeepSeek API Key',
              subtitle: apiKey.isEmpty
                  ? '未配置'
                  : '已配置（${apiKey.length} 字符）',
              onTap: () => _editApiKey(context, ref, apiKey),
            ),
          ],
        ),
        const _SectionHint(
          '用于两件事：批改做题对错、把图形和公式重绘成干净版本。'
          '只有你主动触发时才会把照片发给模型。',
        ),

        // -- 打印 -------------------------------------------------------------
        const _SectionLabel('打印'),
        _Card(
          children: [
            _ToggleRow(
              title: '在卷子上打印孩子姓名',
              value: printName,
              onChanged: (v) =>
                  ref.read(printChildNameProvider.notifier).set(v),
            ),
          ],
        ),

        // -- 数据备份 ---------------------------------------------------------
        const _SectionLabel('数据备份'),
        _Card(
          children: [
            _NavRow(
              title: '导出备份',
              subtitle: '打包数据库和全部图片，然后分享出去',
              trailingIcon: Icons.ios_share,
              onTap: () => exportBackup(context, ref),
            ),
            _NavRow(
              title: '从备份恢复',
              subtitle: '⚠️ 会覆盖当前全部数据',
              trailingIcon: Icons.settings_backup_restore,
              onTap: () => importBackup(context, ref),
            ),
          ],
        ),
        const BackupHint(),

        // -- 关于 -------------------------------------------------------------
        const _SectionLabel('关于'),
        _Card(
          children: [
            const _InfoRow(title: '版本', value: '0.8.0'),
            const _InfoRow(title: '数据库', value: 'v5'),
            const _InfoRow(title: '功能', value: 'OCR · 批改 · 复习计划'),
          ],
        ),
        const _SectionHint(
          'OCR 和批改都需要联网调 DeepSeek，本地识别（ML Kit）完全离线。'
          '所有题目照片都存在这台手机上，不会自动上传。',
        ),
      ],
    );
  }

  Future<void> _editApiKey(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) async {
    final controller = TextEditingController(text: current);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('DeepSeek API Key'),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(
            hintText: 'sk-...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    await ref
        .read(deepSeekKeyProvider.notifier)
        .set(controller.text.trim());
  }
}

// ---------------------------------------------------------------------------
// 通用小部件
// ---------------------------------------------------------------------------

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: OctopusColors.surface,
        borderRadius: BorderRadius.circular(OctopusRadius.card),
        border: Border.all(color: OctopusColors.border),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i != children.length - 1)
              Divider(height: 1, color: OctopusColors.border, indent: 16),
          ],
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
          color: OctopusColors.textSecondary,
        ),
      ),
    );
  }
}

class _SectionHint extends StatelessWidget {
  const _SectionHint(this.text, {this.warn = false});

  final String text;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (warn) ...[
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 6),
              child: Icon(
                Icons.warning_amber_rounded,
                size: 14,
                color: OctopusColors.textSecondary,
              ),
            ),
          ],
          Expanded(
            child: Text(
              text,
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

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.title,
    this.subtitle,
    this.trailingIcon = Icons.chevron_right,
    required this.onTap,
  });

  final String title;
  final String? subtitle;
  final IconData trailingIcon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14.5,
                      color: OctopusColors.textPrimary,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: OctopusColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              trailingIcon,
              size: 20,
              color: OctopusColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.title, required this.value});

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(fontSize: 14.5, color: OctopusColors.textPrimary),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              color: OctopusColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: InkWell(
        onTap: enabled ? () => onChanged!(!value) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14.5,
                        color: OctopusColors.textPrimary,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: OctopusColors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一行里放几个互斥选项。
///
/// 用分段按钮而不是弹窗：选项只有两三个，直接摆出来比再点一次更省事。
class _ChoiceRow<T> extends StatelessWidget {
  const _ChoiceRow({
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String title;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(fontSize: 14.5, color: OctopusColors.textPrimary),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in options.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: entry.key == value,
                  onSelected: (_) => onChanged(entry.key),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String _gradeLabel(int grade) {
  const names = ['', '一', '二', '三', '四', '五', '六'];
  if (grade <= 6) return '${names[grade]}年级';
  if (grade <= 9) return '初${names[grade - 6]}';
  return '高${names[grade - 9]}';
}
