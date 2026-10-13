import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/octopus_theme.dart';
import '../../data/database.dart';
import '../../providers/app_providers.dart';

/// 掌握状态的筛选项。
enum _MasteryFilter { all, fresh, reviewing, mastered }

const _masteryLabels = {
  _MasteryFilter.all: '全部',
  _MasteryFilter.fresh: '未掌握',
  _MasteryFilter.reviewing: '复习中',
  _MasteryFilter.mastered: '已掌握',
};

/// 错题库。
///
/// 列表永远是**当前孩子**的：profileId 来自 [currentProfileObjectProvider]，
/// 没有「全部孩子」这个选项。
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  _MasteryFilter _filter = _MasteryFilter.all;

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(currentProfileObjectProvider);
    if (profile == null) {
      return const _EmptyHint(
        icon: Icons.child_care_outlined,
        title: '先添加一个孩子',
        body: '每道错题都要有归属。',
      );
    }

    final async = ref.watch(questionsProvider(profile.id));
    final all = async.value ?? const <Question>[];
    final selectionMode = ref.watch(selectionModeProvider);
    final selected = ref.watch(selectionProvider);

    final questions = switch (_filter) {
      _MasteryFilter.all => all,
      _MasteryFilter.fresh =>
        all.where((q) => q.mastery == 'new').toList(growable: false),
      _MasteryFilter.reviewing =>
        all.where((q) => q.mastery == 'reviewing').toList(growable: false),
      _MasteryFilter.mastered =>
        all.where((q) => q.mastery == 'mastered').toList(growable: false),
    };

    return Column(
      children: [
        if (!selectionMode)
          _LibraryHeader(
            total: all.length,
            onStartSelection: () {
              if (all.isEmpty) return;
              ref.read(selectionModeProvider.notifier).enter();
            },
          ),
        if (all.isNotEmpty)
          _FilterRow(
            current: _filter,
            onChanged: (f) => setState(() => _filter = f),
          ),
        Expanded(
          child: async.isLoading && all.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : questions.isEmpty
              ? _EmptyHint(
                  icon: all.isEmpty
                      ? Icons.inbox_outlined
                      : Icons.filter_alt_off_outlined,
                  title: all.isEmpty ? '还没有错题' : '这个筛选下没有题',
                  body: all.isEmpty
                      ? '用「录入」拍一张试卷，\n切出题目、确认之后就会出现在这里。'
                      : '换一个筛选条件试试。',
                  action: all.isEmpty
                      ? FilledButton(
                          onPressed: () =>
                              ref.read(shellTabProvider.notifier).go(1),
                          child: const Text('去录入'),
                        )
                      : null,
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                    OctopusSpacing.page,
                    4,
                    OctopusSpacing.page,
                    24,
                  ),
                  itemCount: questions.length,
                  itemBuilder: (context, i) {
                    final q = questions[i];
                    return _QuestionCard(
                      question: q,
                      selectionMode: selectionMode,
                      selected: selected.contains(q.id),
                      onTap: () {
                        if (selectionMode) {
                          ref
                              .read(selectionProvider.notifier)
                              .toggle(q.id);
                        } else {
                          _openDetail(context, q);
                        }
                      },
                      onLongPress: () {
                        if (!selectionMode) {
                          ref.read(selectionModeProvider.notifier).enter();
                          ref
                              .read(selectionProvider.notifier)
                              .toggle(q.id);
                        }
                      },
                    );
                  },
                ),
        ),
        if (selectionMode)
          _SelectionBar(
            selectedCount: selected.length,
            totalCount: questions.length,
            onSelectAll: () => ref
                .read(selectionProvider.notifier)
                .setAll(questions.map((q) => q.id)),
            onCancel: () => ref.read(selectionModeProvider.notifier).exit(),
            onCreateWorksheet: selected.isEmpty
                ? null
                : () => _createWorksheet(profile, selected),
            onDelete: selected.isEmpty
                ? null
                : () => _deleteSelected(profile, selected),
          ),
      ],
    );
  }

  Future<void> _createWorksheet(Profile profile, Set<int> selected) async {
    final db = ref.read(databaseProvider);
    final name = '练习卷 ${DateTime.now().month}/${DateTime.now().day}';
    final id = await db.createWorksheet(profile.id, name);

    // 按列表顺序加入，而不是按点选顺序——用户看到什么顺序，卷子就是什么顺序。
    final ordered = (ref.read(questionsProvider(profile.id)).value ?? const [])
        .where((q) => selected.contains(q.id))
        .toList();
    for (var i = 0; i < ordered.length; i++) {
      await db.addWorksheetItem(id, ordered[i].id, i);
    }

    if (!mounted) return;
    ref.read(selectionModeProvider.notifier).exit();
    ref.read(shellTabProvider.notifier).go(2);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已生成练习卷「$name」，共 ${ordered.length} 道题')),
    );
  }

  Future<void> _deleteSelected(Profile profile, Set<int> selected) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除题目'),
        content: Text('确定删除选中的 ${selected.length} 道题？此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              '删除',
              style: TextStyle(color: OctopusColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ref
        .read(databaseProvider)
        .deleteQuestions(profile.id, selected.toList());
    if (!mounted) return;
    ref.read(selectionModeProvider.notifier).exit();
  }

  void _openDetail(BuildContext context, Question question) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: OctopusColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(OctopusRadius.sheet),
        ),
      ),
      builder: (_) => _QuestionDetail(question: question),
    );
  }
}

class _LibraryHeader extends StatelessWidget {
  const _LibraryHeader({required this.total, required this.onStartSelection});

  final int total;
  final VoidCallback onStartSelection;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        OctopusSpacing.page,
        4,
        OctopusSpacing.page,
        12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '错题库',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: OctopusColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                total == 0 ? '还没有题目' : '共 $total 道',
                style: TextStyle(
                  fontSize: 13,
                  color: OctopusColors.textSecondary,
                ),
              ),
            ],
          ),
          const Spacer(),
          if (total > 0)
            TextButton.icon(
              onPressed: onStartSelection,
              icon: const Icon(Icons.checklist, size: 18),
              label: const Text('选择'),
            ),
        ],
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({required this.current, required this.onChanged});

  final _MasteryFilter current;
  final ValueChanged<_MasteryFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: OctopusSpacing.page),
        children: [
          for (final f in _MasteryFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(_masteryLabels[f]!),
                selected: current == f,
                onSelected: (_) => onChanged(f),
              ),
            ),
        ],
      ),
    );
  }
}

/// 一道错题的卡片。
class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.question,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final Question question;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final text = question.content.trim();
    final mastery = _masteryOf(question.mastery);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: OctopusColors.surface,
        borderRadius: BorderRadius.circular(OctopusRadius.card),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(OctopusRadius.card),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(OctopusRadius.card),
              border: Border.all(
                color: selected ? OctopusColors.accent : OctopusColors.border,
                width: selected ? 2 : 1,
              ),
            ),
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (selectionMode) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 16, right: 2),
                    child: Icon(
                      selected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 22,
                      color: selected
                          ? OctopusColors.accent
                          : OctopusColors.textTertiary,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                _Thumbnail(path: question.originalImagePath),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        text.isEmpty ? '（没有识别到文字）' : text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.55,
                          color: text.isEmpty
                              ? OctopusColors.textTertiary
                              : OctopusColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: mastery.$2,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            mastery.$1,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: OctopusColors.textSecondary,
                            ),
                          ),
                          if (question.subject != null &&
                              question.subject!.isNotEmpty) ...[
                            const SizedBox(width: 10),
                            Text(
                              question.subject!,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: OctopusColors.textTertiary,
                              ),
                            ),
                          ],
                          if (question.usesAiRedrawnFigure) ...[
                            const SizedBox(width: 10),
                            Icon(
                              Icons.auto_fix_high,
                              size: 12,
                              color: OctopusColors.textTertiary,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              'AI 重绘',
                              style: TextStyle(
                                fontSize: 11,
                                color: OctopusColors.textTertiary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  (String, Color) _masteryOf(String mastery) => switch (mastery) {
    'mastered' => ('已掌握', OctopusColors.textTertiary),
    'reviewing' => ('复习中', OctopusColors.textSecondary),
    _ => ('未掌握', OctopusColors.accent),
  };
}

/// 题目缩略图。没有图片文件时给一个占位，不留空白。
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.path});

  final String? path;

  static const _size = 64.0;

  @override
  Widget build(BuildContext context) {
    final file = path == null ? null : File(path!);
    final exists = file != null && file.existsSync();

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: _size,
        height: _size,
        color: OctopusColors.surfaceHigh,
        child: exists
            ? Image.file(file, fit: BoxFit.cover)
            : Icon(
                Icons.image_not_supported_outlined,
                size: 20,
                color: OctopusColors.textTertiary,
              ),
      ),
    );
  }
}

/// 多选时的底部操作条。
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.selectedCount,
    required this.totalCount,
    required this.onSelectAll,
    required this.onCancel,
    required this.onCreateWorksheet,
    required this.onDelete,
  });

  final int selectedCount;
  final int totalCount;
  final VoidCallback onSelectAll;
  final VoidCallback onCancel;
  final VoidCallback? onCreateWorksheet;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final allSelected = selectedCount == totalCount && totalCount > 0;

    return Container(
      decoration: BoxDecoration(
        color: OctopusColors.surface,
        border: Border(top: BorderSide(color: OctopusColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
          child: Row(
            children: [
              IconButton(
                onPressed: onCancel,
                icon: const Icon(Icons.close),
                tooltip: '退出多选',
              ),
              Expanded(
                child: Text(
                  allSelected ? '已全选 $totalCount 道' : '已选 $selectedCount 道',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: OctopusColors.textPrimary,
                  ),
                ),
              ),
              TextButton(
                onPressed: allSelected ? null : onSelectAll,
                child: Text(allSelected ? '取消全选' : '全选'),
              ),
              IconButton(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline),
                tooltip: '删除',
                color: OctopusColors.danger,
              ),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: onCreateWorksheet,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 42),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                ),
                child: const Text('生成练习卷'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 题目详情。阶段一只读，编辑留给阶段二。
class _QuestionDetail extends StatelessWidget {
  const _QuestionDetail({required this.question});

  final Question question;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: OctopusColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          if (question.originalImagePath != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(OctopusRadius.card),
              child: Image.file(
                File(question.originalImagePath!),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          const SizedBox(height: 20),
          SelectableText(
            question.content,
            style: TextStyle(
              fontSize: 16,
              height: 1.8,
              color: OctopusColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: OctopusColors.textTertiary),
            const SizedBox(height: 18),
            Text(
              title,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: OctopusColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.7,
                color: OctopusColors.textSecondary,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}
