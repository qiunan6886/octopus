import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/octopus_theme.dart';
import '../../data/database.dart';
import '../../providers/app_providers.dart';
import '../intake/intake_screen.dart';
import '../library/library_screen.dart';
import '../print/print_screen.dart';
import '../settings/settings_screen.dart';

/// 应用外壳：顶部孩子切换器 + 四个标签页。
///
/// 顺序上把「错题库」放在第一个而不是设计文档里的「录入」：错题库是回来
/// 看的地方，录入是一次性动作。打开应用直接进相机太有攻击性。
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileObjectProvider);
    final profiles = ref.watch(profilesProvider).value ?? const <Profile>[];
    final tab = ref.watch(shellTabProvider);

    // 没有任何孩子时，先引导创建——没有归属的题是不能存的。
    if (profiles.isEmpty) {
      return const _FirstRunScreen();
    }

    return Scaffold(
      backgroundColor: OctopusColors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _ProfileBar(profile: profile),
            Expanded(
              child: IndexedStack(
                index: tab,
                children: const [
                  LibraryScreen(),
                  IntakeScreen(),
                  PrintScreen(),
                  SettingsScreen(),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _BottomNav(
        index: tab,
        onChanged: (i) => ref.read(shellTabProvider.notifier).go(i),
      ),
    );
  }
}

/// 顶部当前孩子。
///
/// 始终可见：设计文档里要求「切换后整个应用都跟着变」，那么当前在谁的上下文里
/// 就必须一直看得见，否则家长会往错误的孩子的库里存题。
class _ProfileBar extends ConsumerWidget {
  const _ProfileBar({required this.profile});

  final Profile? profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        OctopusSpacing.page,
        8,
        OctopusSpacing.page,
        4,
      ),
      child: Row(
        children: [
          Text(
            'Octopus',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
              color: OctopusColors.textPrimary,
            ),
          ),
          const Spacer(),
          if (profile != null)
            _ProfileChip(
              profile: profile!,
              onTap: () => _pickProfile(context, ref),
            ),
        ],
      ),
    );
  }

  Future<void> _pickProfile(BuildContext context, WidgetRef ref) async {
    final profiles = ref.read(profilesProvider).value ?? const <Profile>[];
    final current = ref.read(currentProfileProvider);

    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: OctopusColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(OctopusRadius.sheet),
        ),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            const _SheetHandle(),
            const SizedBox(height: 12),
            Text(
              '选择孩子',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: OctopusColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            for (final p in profiles)
              ListTile(
                leading: _ProfileAvatar(profile: p, size: 36),
                title: Text(
                  p.name,
                  style: TextStyle(
                    color: OctopusColors.textPrimary,
                    fontWeight: p.id == current
                        ? FontWeight.w700
                        : FontWeight.w400,
                  ),
                ),
                subtitle: Text(
                  '${_gradeLabel(p.grade)} · ${_questionCountLabel(ref, p.id)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: OctopusColors.textSecondary,
                  ),
                ),
                trailing: p.id == current
                    ? Icon(Icons.check, size: 18, color: OctopusColors.accent)
                    : null,
                onTap: () => Navigator.pop(sheetContext, p.id),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );

    if (picked != null) {
      await ref.read(currentProfileProvider.notifier).select(picked);
    }
  }
}

String _questionCountLabel(WidgetRef ref, int profileId) {
  final questions = ref.watch(questionsProvider(profileId)).value;
  return '${questions?.length ?? 0} 道错题';
}

class _ProfileChip extends StatelessWidget {
  const _ProfileChip({required this.profile, required this.onTap});

  final Profile profile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: OctopusColors.surface,
      borderRadius: BorderRadius.circular(OctopusRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(OctopusRadius.pill),
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 5, 10, 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(OctopusRadius.pill),
            border: Border.all(color: OctopusColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ProfileAvatar(profile: profile, size: 24),
              const SizedBox(width: 8),
              Text(
                profile.name,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: OctopusColors.textPrimary,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                _gradeLabel(profile.grade),
                style: TextStyle(
                  fontSize: 12,
                  color: OctopusColors.textSecondary,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.expand_more,
                size: 16,
                color: OctopusColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 用姓名的第一个字作头像，不引入图片资源。
///
/// 彩主题下用渐变底，单色主题下渐变两端同色、等价于纯色——这样不用写分支。
class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.profile, required this.size});

  final Profile profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = profile.name.characters.isEmpty
        ? '?'
        : profile.name.characters.first;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: OctopusColors.heroGradient,
        shape: BoxShape.circle,
      ),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.46,
          fontWeight: FontWeight.w700,
          color: OctopusColors.onAccent,
        ),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: OctopusColors.surface,
        border: Border(top: BorderSide(color: OctopusColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: onChanged,
          backgroundColor: OctopusColors.surface,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.menu_book_outlined),
              selectedIcon: Icon(Icons.menu_book),
              label: '错题库',
            ),
            NavigationDestination(
              icon: Icon(Icons.add_a_photo_outlined),
              selectedIcon: Icon(Icons.add_a_photo),
              label: '录入',
            ),
            NavigationDestination(
              icon: Icon(Icons.print_outlined),
              selectedIcon: Icon(Icons.print),
              label: '练习卷',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '设置',
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        color: OctopusColors.border,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// 首次运行：还没有孩子。
///
/// 因为题目必须归属某个孩子，所以这一步无法跳过。
class _FirstRunScreen extends ConsumerWidget {
  const _FirstRunScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: OctopusColors.background,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.child_care_outlined,
                size: 56,
                color: OctopusColors.textTertiary,
              ),
              const SizedBox(height: 20),
              Text(
                '先添加一个孩子',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: OctopusColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '每道错题都归属于某个孩子，\n这样两个孩子的题目永远不会混在一起。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.7,
                  color: OctopusColors.textSecondary,
                ),
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: () => showProfileEditor(context, ref),
                child: const Text('添加孩子'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _gradeLabel(int grade) {
  if (grade <= 6) return '${_chineseNumber(grade)}年级';
  if (grade <= 9) return '初${_chineseNumber(grade - 6)}';
  return '高${_chineseNumber(grade - 9)}';
}

String _chineseNumber(int n) => const [
  '',
  '一',
  '二',
  '三',
  '四',
  '五',
  '六',
].elementAt(n.clamp(0, 6));

// ---------------------------------------------------------------------------
// 孩子编辑
// ---------------------------------------------------------------------------

/// 新建或编辑一个孩子。传 null 表示新建。
Future<void> showProfileEditor(
  BuildContext context,
  WidgetRef ref, {
  Profile? existing,
}) async {
  final nameController = TextEditingController(text: existing?.name ?? '');
  var grade = existing?.grade ?? 2;

  final saved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: Text(existing == null ? '添加孩子' : '编辑孩子'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '名字',
                hintText: '如：小明',
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '年级',
              style: TextStyle(
                fontSize: 13,
                color: OctopusColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var g = 1; g <= 9; g++)
                  ChoiceChip(
                    label: Text(_gradeLabel(g)),
                    selected: grade == g,
                    onSelected: (_) => setDialogState(() => grade = g),
                  ),
              ],
            ),
          ],
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () async {
                await ref
                    .read(databaseProvider)
                    .deleteProfile(existing.id);
                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext, false);
                }
              },
              child: Text(
                '删除',
                style: TextStyle(color: OctopusColors.danger),
              ),
            ),
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
    ),
  );

  if (saved != true) return;

  final name = nameController.text.trim();
  if (name.isEmpty) return;

  final db = ref.read(databaseProvider);
  if (existing == null) {
    final id = await db.createProfile(name: name, grade: grade);
    await ref.read(currentProfileProvider.notifier).select(id);
  } else {
    await db.updateProfile(existing.id, name: name, grade: grade);
  }
}
