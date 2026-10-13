import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/octopus_theme.dart';
import '../../data/database.dart';
import '../../providers/app_providers.dart';

/// 待确认列表 —— 整个设计的**安全阀**。
///
/// 自动处理（切题、识别）一定会有错，所以结果先进这里。只有用户点过「通过」
/// 的题才会变成真正的错题。这样错题库里永远是可信的。
class ReviewScreen extends ConsumerWidget {
  const ReviewScreen({super.key, required this.batchId});

  final int batchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(draftsProvider(batchId));
    final drafts = async.value ?? const <DraftQuestion>[];

    final pending = drafts.where((d) => d.reviewStatus == 'pending').length;
    final accepted = drafts.where((d) => d.reviewStatus == 'accepted').length;
    final discarded = drafts.where((d) => d.reviewStatus == 'discarded').length;

    return Scaffold(
      backgroundColor: OctopusColors.background,
      appBar: AppBar(
        title: const Text('确认题目'),
        bottom: drafts.isEmpty
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(28),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      pending == 0
                          ? '全部确认完了 · 通过 $accepted · 丢弃 $discarded'
                          : '还有 $pending 道没确认 · 已通过 $accepted',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: OctopusColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
      ),
      body: drafts.isEmpty
          ? const _NothingToReview()
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(
                OctopusSpacing.page,
                8,
                OctopusSpacing.page,
                24,
              ),
              itemCount: drafts.length,
              itemBuilder: (context, i) => _DraftCard(
                draft: drafts[i],
                index: i + 1,
                onAccept: () => _accept(ref, drafts[i]),
                onDiscard: () => _discard(ref, drafts[i]),
                onEdit: () => _edit(context, ref, drafts[i]),
                onReopen: () => _reopen(ref, drafts[i]),
              ),
            ),
      bottomNavigationBar: drafts.isEmpty
          ? null
          : _ReviewFooter(
              pending: pending,
              accepted: accepted,
              onAcceptAll: pending == 0
                  ? null
                  : () => _acceptAll(ref, drafts),
              onDone: () => Navigator.of(context).pop(),
            ),
    );
  }

  /// 通过一道题：写进错题库，并把草稿标记为已通过。
  ///
  /// 这一步是**唯一**把草稿变成正式错题的地方。
  Future<void> _accept(WidgetRef ref, DraftQuestion draft) async {
    final db = ref.read(databaseProvider);
    final batch = await db.batchById(batchId);
    if (batch == null) return;

    final questionId = await db.insertQuestion(
      // profileId 从批次继承——草稿本身不存归属，避免两处不一致。
      profileId: batch.profileId,
      content: draft.content,
      originalImagePath: draft.originalImagePath,
      subject: draft.subject,
    );
    await db.updateDraft(
      draft.id,
      reviewStatus: 'accepted',
      acceptedQuestionId: questionId,
    );
  }

  Future<void> _discard(WidgetRef ref, DraftQuestion draft) =>
      ref.read(databaseProvider).updateDraft(draft.id, reviewStatus: 'discarded');

  Future<void> _reopen(WidgetRef ref, DraftQuestion draft) async {
    final db = ref.read(databaseProvider);
    // 重新打开一道已通过的题时，把它刚才写进错题库的那条删掉——否则会留下
    // 一条用户已经改主意的题。
    if (draft.acceptedQuestionId != null) {
      final batch = await db.batchById(batchId);
      if (batch != null) {
        await db.deleteQuestions(batch.profileId, [draft.acceptedQuestionId!]);
      }
    }
    await db.updateDraft(draft.id, reviewStatus: 'pending');
  }

  Future<void> _acceptAll(WidgetRef ref, List<DraftQuestion> drafts) async {
    for (final d in drafts) {
      if (d.reviewStatus == 'pending') {
        await _accept(ref, d);
      }
    }
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    DraftQuestion draft,
  ) async {
    final controller = TextEditingController(text: draft.content);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('修改题干'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 6,
          minLines: 3,
          decoration: const InputDecoration(
            hintText: '把识别错的字改过来',
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
        .read(databaseProvider)
        .updateDraft(draft.id, content: controller.text);
  }
}

class _NothingToReview extends StatelessWidget {
  const _NothingToReview();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 48,
              color: OctopusColors.textTertiary,
            ),
            const SizedBox(height: 16),
            Text(
              '这次录入没有题目',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: OctopusColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '可能没有框选到任何内容。',
              style: TextStyle(
                fontSize: 13,
                color: OctopusColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一张待确认的题：左边原图，右边识别结果，下面三个动作。
class _DraftCard extends StatelessWidget {
  const _DraftCard({
    required this.draft,
    required this.index,
    required this.onAccept,
    required this.onDiscard,
    required this.onEdit,
    required this.onReopen,
  });

  final DraftQuestion draft;
  final int index;
  final VoidCallback onAccept;
  final VoidCallback onDiscard;
  final VoidCallback onEdit;
  final VoidCallback onReopen;

  @override
  Widget build(BuildContext context) {
    final accepted = draft.reviewStatus == 'accepted';
    final discarded = draft.reviewStatus == 'discarded';
    final settled = accepted || discarded;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Opacity(
        opacity: settled ? 0.55 : 1,
        child: Container(
          decoration: BoxDecoration(
            color: OctopusColors.surface,
            borderRadius: BorderRadius.circular(OctopusRadius.card),
            border: Border.all(
              color: accepted
                  ? OctopusColors.accent
                  : OctopusColors.border,
              width: accepted ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '第 $index 题',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: OctopusColors.textSecondary,
                    ),
                  ),
                  const Spacer(),
                  if (accepted)
                    _StatusTag(
                      label: '已通过',
                      color: OctopusColors.accent,
                      onTap: onReopen,
                    ),
                  if (discarded)
                    _StatusTag(
                      label: '已丢弃',
                      color: OctopusColors.danger,
                      onTap: onReopen,
                    ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 180),
                  width: double.infinity,
                  color: OctopusColors.surfaceHigh,
                  child: Image.file(
                    File(draft.originalImagePath),
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => Padding(
                      padding: const EdgeInsets.all(24),
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: OctopusColors.textTertiary,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // 识别结果为空时给一句明确的提示，而不是一片空白——阶段一还没有
              // 接 OCR，这里为空是正常的。
              Text(
                draft.content.trim().isEmpty
                    ? '（还没有识别文字，点「修改」手动录入）'
                    : draft.content,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.7,
                  color: draft.content.trim().isEmpty
                      ? OctopusColors.textTertiary
                      : OctopusColors.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              if (!settled)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: onEdit,
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        label: const Text('修改'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 40),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onDiscard,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          foregroundColor: OctopusColors.danger,
                        ),
                        child: const Text('丢弃'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: onAccept,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 40),
                        ),
                        child: const Text('通过'),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusTag extends StatelessWidget {
  const _StatusTag({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 28),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        foregroundColor: color,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
      child: Text('$label · 撤销'),
    );
  }
}

class _ReviewFooter extends StatelessWidget {
  const _ReviewFooter({
    required this.pending,
    required this.accepted,
    required this.onAcceptAll,
    required this.onDone,
  });

  final int pending;
  final int accepted;
  final VoidCallback? onAcceptAll;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: OctopusColors.surface,
        border: Border(top: BorderSide(color: OctopusColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onAcceptAll,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                  ),
                  child: const Text('全部通过'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: onDone,
                  child: Text(accepted > 0 ? '完成（入库 $accepted）' : '完成'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
