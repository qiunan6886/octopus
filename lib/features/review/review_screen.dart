import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/octopus_theme.dart';
import '../../data/database.dart';
import '../../providers/app_providers.dart';
import '../../services/deepseek_client.dart';
import '../../services/deepseek_grader.dart';

/// 待确认列表 —— 整个设计的**安全阀**，也是批改结果落地的地方。
///
/// 批改和录入是同一条流程：「错题」的定义就是做错的题，所以批改只是在这条流程
/// 里多了一步判断对错。设置里关掉批改时，这里就是纯粹的确认页。
class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key, required this.batchId});

  final int batchId;

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  bool _grading = false;
  bool _ocrRunning = false;
  final _errors = <String>[];

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(draftsProvider(widget.batchId));
    final drafts = async.value ?? const <DraftQuestion>[];

    final gradingOn = ref.watch(gradingEnabledProvider);
    final pending = drafts.where((d) => d.reviewStatus == 'pending').length;
    final accepted = drafts.where((d) => d.reviewStatus == 'accepted').length;
    final graded = drafts.where((d) => d.isGraded).length;
    final wrong = drafts.where((d) => d.isWrong).length;

    final apiKey = ref.watch(deepSeekKeyProvider);
    final canGrade =
        gradingOn &&
        apiKey.trim().isNotEmpty &&
        ref.watch(aiGradingProvider) &&
        drafts.any((d) => !d.isGraded);

    return Scaffold(
      backgroundColor: OctopusColors.background,
      appBar: AppBar(
        title: Text(gradingOn ? '批改并确认' : '确认题目'),
        actions: [
          if (drafts.any((d) => d.content.trim().isEmpty) && !_grading && !_ocrRunning)
            TextButton(
              onPressed: _recognizeAll,
              child: const Text('识别文字'),
            ),
          if (_ocrRunning)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
        bottom: drafts.isEmpty
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(28),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _subtitle(
                        gradingOn: gradingOn,
                        total: drafts.length,
                        pending: pending,
                        graded: graded,
                        wrong: wrong,
                        accepted: accepted,
                      ),
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
          : Column(
              children: [
                if (_grading) const LinearProgressIndicator(minHeight: 2),
                if (_errors.isNotEmpty) _ErrorBanner(messages: _errors),
                Expanded(
                  child: ListView.builder(
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
                      gradingOn: gradingOn,
                      onAccept: () => _accept(drafts[i]),
                      onDiscard: () => _discard(drafts[i]),
                      onEdit: () => _edit(drafts[i]),
                      onReopen: () => _reopen(drafts[i]),
                      onGrade: (result) => _manualGrade(drafts[i], result),
                      onEditAnswer: () => _editAnswer(drafts[i]),
                    ),
                  ),
                ),
              ],
            ),
      bottomNavigationBar: drafts.isEmpty
          ? null
          : _ReviewFooter(
              pending: pending,
              willAccept: _willAccept(drafts).length,
              busy: _grading,
              onGradeAll: canGrade && !_grading ? _gradeAll : null,
              onAcceptAll: pending == 0 || _grading ? null : _finish,
              onDone: () => Navigator.of(context).pop(),
            ),
    );
  }

  String _subtitle({
    required bool gradingOn,
    required int total,
    required int pending,
    required int graded,
    required int wrong,
    required int accepted,
  }) {
    if (!gradingOn) {
      return pending == 0
          ? '全部确认完了 · 已入库 $accepted'
          : '还有 $pending 道没确认 · 已入库 $accepted';
    }
    if (graded == 0) return '共 $total 道，还没批改';
    return '已批改 $graded 道，其中做错 $wrong 道 · 已入库 $accepted';
  }

  /// 批改开启时，「完成」只让**做错**的题入库（除非设置里允许保留做对的）。
  /// 未批改的题也算入库——家长没标对错，多半是想留着。
  List<DraftQuestion> _willAccept(List<DraftQuestion> drafts) {
    final gradingOn = ref.read(gradingEnabledProvider);
    final keepCorrect = ref.read(gradingKeepCorrectProvider);
    return drafts.where((d) {
      if (d.reviewStatus == 'accepted') return true;
      if (d.reviewStatus != 'pending') return false;
      if (gradingOn && d.isCorrect && !keepCorrect) return false;
      return true;
    }).toList();
  }

  // -- 动作 -----------------------------------------------------------------

  Future<void> _accept(DraftQuestion draft) async {
    final db = ref.read(databaseProvider);
    final batch = await db.batchById(widget.batchId);
    if (batch == null) return;

    final questionId = await db.insertQuestion(
      // profileId 从批次继承——草稿本身不存归属，避免两处不一致。
      profileId: batch.profileId,
      content: draft.content,
      originalImagePath: draft.originalImagePath,
      subject: draft.subject,
      correctAnswer: draft.correctAnswer,
      gradeResult: draft.gradeResult,
      // 做对的题（设置允许保留时）直接标成已掌握，不占用复习列表。
      usesAiRedrawnFigure: false,
    );
    await db.updateDraft(
      draft.id,
      reviewStatus: 'accepted',
      acceptedQuestionId: questionId,
    );
    if (draft.isCorrect) {
      await db.setMastery(batch.profileId, [
        questionId,
      ], 'mastered');
    }
  }

  Future<void> _discard(DraftQuestion draft) =>
      ref.read(databaseProvider).updateDraft(draft.id, reviewStatus: 'discarded');

  Future<void> _reopen(DraftQuestion draft) async {
    final db = ref.read(databaseProvider);
    // 重新打开一道已入库的题时，把它刚才写进错题库的那条删掉——否则会留下
    // 一条用户已经改主意的题。
    if (draft.acceptedQuestionId != null) {
      final batch = await db.batchById(widget.batchId);
      if (batch != null) {
        await db.deleteQuestions(batch.profileId, [draft.acceptedQuestionId!]);
      }
    }
    await db.updateDraft(
      draft.id,
      reviewStatus: 'pending',
      gradeResult: draft.gradeResult,
    );
  }

  /// 家长手动标对错。AI 判断不放心时用这个覆盖。
  Future<void> _manualGrade(DraftQuestion draft, String? result) => ref
      .read(databaseProvider)
      .setDraftGrade(
        draft.id,
        // 再点一次同一个按钮就是撤销判断。
        result: draft.gradeResult == result ? null : result,
        correctAnswer: draft.correctAnswer,
        source: 'manual',
      );

  Future<void> _editAnswer(DraftQuestion draft) async {
    final controller = TextEditingController(text: draft.correctAnswer ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('正确答案'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 5,
          minLines: 2,
          decoration: const InputDecoration(
            hintText: '孩子重做时用来对照',
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
        .updateDraft(
          draft.id,
          correctAnswer: controller.text.trim(),
          gradeSource: 'manual',
        );
  }

  /// 给还没有文字的草稿跑一遍识别。
  ///
  /// 自动识别关掉、或者自动识别那一步失败了，就在这里补。逐题记录失败原因，
  /// 一道题失败不影响其他题。
  Future<void> _recognizeAll() async {
    final drafts = ref.read(draftsProvider(widget.batchId)).value ?? const [];
    final targets = drafts.where((d) => d.content.trim().isEmpty).toList();
    if (targets.isEmpty) return;

    final ocr = ref.read(ocrEngineInstanceProvider);
    final db = ref.read(databaseProvider);

    setState(() {
      _ocrRunning = true;
      _errors.clear();
    });

    var done = 0;
    try {
      for (final draft in targets) {
        if (!mounted) return;
        try {
          final outcome = await ocr.recognize(draft.originalImagePath);
          if (outcome.text.isNotEmpty) {
            await db.updateDraft(draft.id, content: outcome.text);
            done++;
          } else {
            setState(
              () => _errors.add('第 ${drafts.indexOf(draft) + 1} 题：没读出文字'),
            );
          }
        } catch (error) {
          setState(
            () => _errors.add(
              '第 ${drafts.indexOf(draft) + 1} 题：'
              '${error is DeepSeekException ? error.message : error}',
            ),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() => _ocrRunning = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('识别完成 $done/${targets.length} 道')),
        );
      }
    }
  }

  /// 用 AI 批改所有还没判断的题。
  ///
  /// 逐题调用、逐题记录失败原因：一道题失败不该让整批停摆，家长需要知道具体
  /// 是哪几道没批上。
  Future<void> _gradeAll() async {
    final drafts = ref.read(draftsProvider(widget.batchId)).value ?? const [];
    final targets = drafts.where((d) => !d.isGraded).toList();
    if (targets.isEmpty) return;

    final batch = await ref.read(databaseProvider).batchById(widget.batchId);
    if (batch == null) return;
    final profile = ref
        .read(profilesProvider)
        .value
        ?.where((p) => p.id == batch.profileId)
        .firstOrNull;
    final grade = profile?.grade ?? 4;

    final grader = DeepSeekGrader(apiKey: ref.read(deepSeekKeyProvider));
    final db = ref.read(databaseProvider);

    setState(() {
      _grading = true;
      _errors.clear();
    });

    try {
      for (final draft in targets) {
        if (!mounted) return;
        try {
          final bytes = await readQuestionImage(draft.originalImagePath);
          final outcome = await grader.grade(
            imageBytes: bytes,
            grade: grade,
            subject: draft.subject,
          );
          await db.setDraftGrade(
            draft.id,
            result: outcome.gradeResult,
            correctAnswer: outcome.correctAnswer,
            source: 'ai',
          );
        } on GradeException catch (error) {
          setState(() => _errors.add('第 ${drafts.indexOf(draft) + 1} 题：${error.message}'));
        }
      }
    } finally {
      if (mounted) setState(() => _grading = false);
    }
  }

  /// 批量处理：要入库的入库，做对的（设置不允许保留时）直接丢弃。
  Future<void> _finish() async {
    final drafts = ref.read(draftsProvider(widget.batchId)).value ?? const [];
    final willAccept = _willAccept(drafts).map((d) => d.id).toSet();

    for (final draft in drafts) {
      if (draft.reviewStatus != 'pending') continue;
      if (willAccept.contains(draft.id)) {
        await _accept(draft);
      } else {
        await _discard(draft);
      }
    }

    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text('已入库 ${willAccept.length} 道题')),
    );
    Navigator.of(context).pop();
  }

  Future<void> _edit(DraftQuestion draft) async {
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

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.messages});

  final List<String> messages;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: OctopusColors.danger.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: OctopusColors.danger.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline,
                size: 16,
                color: OctopusColors.danger,
              ),
              const SizedBox(width: 6),
              Text(
                '有 ${messages.length} 道没批上',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: OctopusColors.danger,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final m in messages.take(3))
            Text(
              m,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: OctopusColors.textSecondary,
              ),
            ),
          if (messages.length > 3)
            Text(
              '……还有 ${messages.length - 3} 条',
              style: TextStyle(
                fontSize: 12,
                color: OctopusColors.textTertiary,
              ),
            ),
        ],
      ),
    );
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

/// 一张待确认的题：原图 + 批改结果 + 识别文字 + 动作。
class _DraftCard extends StatelessWidget {
  const _DraftCard({
    required this.draft,
    required this.index,
    required this.gradingOn,
    required this.onAccept,
    required this.onDiscard,
    required this.onEdit,
    required this.onReopen,
    required this.onGrade,
    required this.onEditAnswer,
  });

  final DraftQuestion draft;
  final int index;
  final bool gradingOn;
  final VoidCallback onAccept;
  final VoidCallback onDiscard;
  final VoidCallback onEdit;
  final VoidCallback onReopen;
  final ValueChanged<String> onGrade;
  final VoidCallback onEditAnswer;

  @override
  Widget build(BuildContext context) {
    final accepted = draft.reviewStatus == 'accepted';
    final discarded = draft.reviewStatus == 'discarded';
    final settled = accepted || discarded;

    final accent = draft.isCorrect
        ? OctopusColors.success
        : draft.isWrong
        ? OctopusColors.danger
        : OctopusColors.border;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: BoxDecoration(
          color: OctopusColors.surface,
          borderRadius: BorderRadius.circular(OctopusRadius.card),
          border: Border.all(
            color: accepted
                ? OctopusColors.accent
                : draft.isWrong
                ? OctopusColors.danger.withValues(alpha: 0.55)
                : OctopusColors.border,
            width: accepted || draft.isWrong ? 2 : 1,
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
                const SizedBox(width: 8),
                if (gradingOn && draft.isGraded)
                  _GradeBadge(draft: draft, accent: accent),
                const Spacer(),
                if (settled)
                  _StatusTag(
                    label: accepted ? '已入库' : '已丢弃',
                    color: accepted
                        ? OctopusColors.accent
                        : OctopusColors.danger,
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
            // 识别结果为空时明确说明，而不是留一片空白——阶段二还没接 OCR，
            // 这里为空是正常的。
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
            if (gradingOn && draft.correctAnswer != null) ...[
              const SizedBox(height: 10),
              _AnswerBox(
                answer: draft.correctAnswer!,
                wrong: draft.isWrong,
                onEdit: onEditAnswer,
              ),
            ],
            const SizedBox(height: 12),
            if (!settled) ...[
              if (gradingOn) ...[
                Row(
                  children: [
                    Expanded(
                      child: _GradeButton(
                        label: '做对了',
                        icon: Icons.check,
                        active: draft.isCorrect,
                        activeColor: OctopusColors.success,
                        onTap: () => onGrade('correct'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _GradeButton(
                        label: '做错了',
                        icon: Icons.close,
                        active: draft.isWrong,
                        activeColor: OctopusColors.danger,
                        onTap: () => onGrade('wrong'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
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
                      child: const Text('入库'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GradeBadge extends StatelessWidget {
  const _GradeBadge({required this.draft, required this.accent});

  final DraftQuestion draft;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final correct = draft.isCorrect;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(OctopusRadius.pill),
        border: Border.all(color: accent.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            correct ? Icons.check_circle : Icons.cancel,
            size: 12,
            color: accent,
          ),
          const SizedBox(width: 4),
          Text(
            correct ? '正确' : '错误',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
          if (draft.gradeSource == 'ai') ...[
            const SizedBox(width: 4),
            Text(
              'AI',
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: accent.withValues(alpha: 0.75),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AnswerBox extends StatelessWidget {
  const _AnswerBox({
    required this.answer,
    required this.wrong,
    required this.onEdit,
  });

  final String answer;
  final bool wrong;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final color = wrong ? OctopusColors.danger : OctopusColors.textSecondary;
    return InkWell(
      onTap: onEdit,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '正确答案',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                answer,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.6,
                  color: OctopusColors.textPrimary,
                ),
              ),
            ),
            Icon(Icons.edit_outlined, size: 14, color: color),
          ],
        ),
      ),
    );
  }
}

class _GradeButton extends StatelessWidget {
  const _GradeButton({
    required this.label,
    required this.icon,
    required this.active,
    required this.activeColor,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active
          ? activeColor.withValues(alpha: 0.12)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active ? activeColor : OctopusColors.border,
              width: active ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: active ? activeColor : OctopusColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active
                      ? activeColor
                      : OctopusColors.textSecondary,
                ),
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
    required this.willAccept,
    required this.busy,
    required this.onGradeAll,
    required this.onAcceptAll,
    required this.onDone,
  });

  final int pending;
  final int willAccept;
  final bool busy;
  final VoidCallback? onGradeAll;
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
              if (onGradeAll != null) ...[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : onGradeAll,
                    icon: const Icon(Icons.auto_awesome, size: 16),
                    label: const Text('AI 批改'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: FilledButton(
                  onPressed: onAcceptAll ?? onDone,
                  child: Text(
                    onAcceptAll == null
                        ? '完成'
                        : pending == willAccept
                        ? '全部入库（$pending）'
                        : '入库 $willAccept · 丢弃 ${pending - willAccept}',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
