import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../app/theme/octopus_theme.dart';
import '../../data/database.dart';
import '../../providers/app_providers.dart';
import '../../services/deepseek_client.dart';
import '../../services/deepseek_redraw.dart';
import '../../services/deepseek_variants.dart';

// ---------------------------------------------------------------------------
// AI 重绘
// ---------------------------------------------------------------------------

/// 让 AI 把题目重画成干净的 SVG，并**强制和原图对照**。
///
/// 为什么一定要对照：模型会画错——角度、标注、数字都可能和原题不一致。所以
/// 存下来之后默认**不选中**，必须由用户看着两张图点一次「用这张」。
Future<void> showRedrawSheet(
  BuildContext context,
  WidgetRef ref, {
  required Question question,
  required int grade,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: OctopusColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(OctopusRadius.sheet),
      ),
    ),
    builder: (_) => _RedrawSheet(question: question, grade: grade),
  );
}

class _RedrawSheet extends ConsumerStatefulWidget {
  const _RedrawSheet({required this.question, required this.grade});

  final Question question;
  final int grade;

  @override
  ConsumerState<_RedrawSheet> createState() => _RedrawSheetState();
}

class _RedrawSheetState extends ConsumerState<_RedrawSheet> {
  bool _busy = false;
  String? _error;
  String? _svg;
  String? _note;
  late bool _useRedrawn = widget.question.usesAiRedrawnFigure;

  @override
  void initState() {
    super.initState();
    _svg = widget.question.redrawnSvg;
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          const _Handle(),
          const SizedBox(height: 16),
          Text(
            'AI 重绘',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: OctopusColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '让模型去掉笔迹、重画一张干净的图。'
            '模型会画错，请对着原图核对之后再决定用哪张。',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.6,
              color: OctopusColors.textSecondary,
            ),
          ),
          const SizedBox(height: 18),

          if (_error != null) ...[
            _ErrorBox(message: _error!),
            const SizedBox(height: 16),
          ],

          _Label('原图'),
          const SizedBox(height: 8),
          _ImageBox(path: widget.question.originalImagePath),

          if (_svg != null) ...[
            const SizedBox(height: 20),
            Row(
              children: [
                _Label('AI 重绘'),
                const Spacer(),
                if (_note != null && _note!.isNotEmpty)
                  Flexible(
                    child: Text(
                      _note!,
                      textAlign: TextAlign.right,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: OctopusColors.textTertiary,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            _SvgBox(svg: _svg!),
            const SizedBox(height: 16),
            _Choice(
              selected: _useRedrawn,
              title: '用这张重绘版',
              subtitle: '打印时用重绘的图，卷子上会标注「AI 重绘」',
              onTap: () => _choose(true),
            ),
            const SizedBox(height: 8),
            _Choice(
              selected: !_useRedrawn,
              title: '还是用原图',
              subtitle: '原图有笔迹，但一定是原题',
              onTap: () => _choose(false),
            ),
          ],

          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _redraw,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_fix_high, size: 18),
            label: Text(_svg == null ? '开始重绘' : '重新生成'),
          ),
        ],
      ),
    );
  }

  Future<void> _choose(bool use) async {
    final profile = ref.read(currentProfileObjectProvider);
    if (profile == null) return;
    setState(() => _useRedrawn = use);
    await ref
        .read(databaseProvider)
        .setUseRedrawn(profile.id, widget.question.id, use);
  }

  Future<void> _redraw() async {
    final key = ref.read(deepSeekKeyProvider);
    if (key.trim().isEmpty) {
      setState(() => _error = '先在「设置 → AI」里填 DeepSeek API Key');
      return;
    }
    final path = widget.question.originalImagePath;
    if (path == null || !File(path).existsSync()) {
      setState(() => _error = '找不到题目图片');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final outcome = await DeepSeekRedrawer(apiKey: key).redraw(
        imagePath: path,
        grade: widget.grade,
      );
      final profile = ref.read(currentProfileObjectProvider);
      if (profile != null) {
        // use: false —— 存下来但先不选中，等用户对照完再决定。
        await ref
            .read(databaseProvider)
            .setRedrawn(profile.id, widget.question.id, svg: outcome.svg);
      }
      if (!mounted) return;
      setState(() {
        _svg = outcome.svg;
        _note = outcome.note;
      });
    } on DeepSeekException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ---------------------------------------------------------------------------
// 变式题
// ---------------------------------------------------------------------------

/// 生成变式题：同一个知识点、同一个难度，但换个数字或情境。
Future<void> showVariantsSheet(
  BuildContext context,
  WidgetRef ref, {
  required Question question,
  required int grade,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: OctopusColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(OctopusRadius.sheet),
      ),
    ),
    builder: (_) => _VariantsSheet(question: question, grade: grade),
  );
}

class _VariantsSheet extends ConsumerStatefulWidget {
  const _VariantsSheet({required this.question, required this.grade});

  final Question question;
  final int grade;

  @override
  ConsumerState<_VariantsSheet> createState() => _VariantsSheetState();
}

class _VariantsSheetState extends ConsumerState<_VariantsSheet> {
  bool _busy = false;
  String? _error;
  List<Variant> _variants = const [];

  /// 用户勾选保留的变式题下标。
  final Set<int> _keep = {};

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          const _Handle(),
          const SizedBox(height: 16),
          Text(
            '变式题',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: OctopusColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '同一个知识点、同一个难度，换掉数字或情境。'
            '生成之后可以改，确认的才会入库。',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.6,
              color: OctopusColors.textSecondary,
            ),
          ),
          const SizedBox(height: 18),

          if (_error != null) ...[
            _ErrorBox(message: _error!),
            const SizedBox(height: 16),
          ],

          if (_variants.isNotEmpty) ...[
            for (var i = 0; i < _variants.length; i++)
              _VariantCard(
                variant: _variants[i],
                index: i + 1,
                kept: _keep.contains(i),
                onToggle: () => setState(() {
                  if (!_keep.remove(i)) _keep.add(i);
                }),
                onEdit: () => _edit(i),
              ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _keep.isEmpty ? null : _save,
              child: Text('${_keep.length} 道入库'),
            ),
            const SizedBox(height: 8),
          ],

          OutlinedButton.icon(
            onPressed: _busy ? null : _generate,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome, size: 18),
            label: Text(_variants.isEmpty ? '生成变式题' : '重新生成'),
          ),
          if (_variants.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'AI 生成的题可能有错，入库前请自己过一遍。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11.5,
                  color: OctopusColors.textTertiary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _generate() async {
    final key = ref.read(deepSeekKeyProvider);
    if (key.trim().isEmpty) {
      setState(() => _error = '先在「设置 → AI」里填 DeepSeek API Key');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = DeepSeekVariants(apiKey: key);
      final text = widget.question.content.trim();
      final List<Variant> variants;

      if (text.isNotEmpty) {
        // 有题干文字就走文字：便宜、快，而且文字是已经校对过的。
        variants = await service.fromText(
          question: text,
          grade: widget.grade,
          subject: widget.question.subject,
        );
      } else {
        final path = widget.question.originalImagePath;
        if (path == null || !File(path).existsSync()) {
          setState(() => _error = '这道题既没有题干文字，也没有图片');
          return;
        }
        variants = await service.fromImage(
          imageBytes: await File(path).readAsBytes(),
          grade: widget.grade,
          subject: widget.question.subject,
        );
      }

      if (!mounted) return;
      setState(() {
        _variants = variants;
        // 默认全选：用户点「生成」就是想用，逐个取消比逐个勾选省事。
        _keep
          ..clear()
          ..addAll(List.generate(variants.length, (i) => i));
      });
    } on DeepSeekException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(int index) async {
    final controller = TextEditingController(text: _variants[index].text);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('修改第 ${index + 1} 道'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 6,
          minLines: 3,
          decoration: const InputDecoration(border: OutlineInputBorder()),
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
    setState(() {
      _variants = [
        for (var i = 0; i < _variants.length; i++)
          if (i == index)
            Variant(
              text: controller.text.trim(),
              answer: _variants[i].answer,
            )
          else
            _variants[i],
      ];
    });
  }

  Future<void> _save() async {
    final profile = ref.read(currentProfileObjectProvider);
    if (profile == null) return;
    final db = ref.read(databaseProvider);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    var saved = 0;
    for (final index in _keep.toList()..sort()) {
      final variant = _variants[index];
      if (variant.text.trim().isEmpty) continue;
      await db.insertQuestion(
        profileId: profile.id,
        content: variant.text,
        subject: widget.question.subject,
        correctAnswer: variant.answer,
        // 记住来源，这样以后能看出哪些题是同一道题变出来的。
        variantOfQuestionId: widget.question.id,
      );
      saved++;
    }

    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text('已入库 $saved 道变式题')));
  }
}

class _VariantCard extends StatelessWidget {
  const _VariantCard({
    required this.variant,
    required this.index,
    required this.kept,
    required this.onToggle,
    required this.onEdit,
  });

  final Variant variant;
  final int index;
  final bool kept;
  final VoidCallback onToggle;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(OctopusRadius.card),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: OctopusColors.surface,
            borderRadius: BorderRadius.circular(OctopusRadius.card),
            border: Border.all(
              color: kept ? OctopusColors.accent : OctopusColors.border,
              width: kept ? 2 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 10),
                child: Icon(
                  kept ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 20,
                  color: kept
                      ? OctopusColors.accent
                      : OctopusColors.textTertiary,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '第 $index 道',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: OctopusColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      variant.text,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.7,
                        color: OctopusColors.textPrimary,
                      ),
                    ),
                    if (variant.answer != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        '答案：${variant.answer}',
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.6,
                          color: OctopusColors.success,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: onEdit,
                        icon: const Icon(Icons.edit_outlined, size: 15),
                        label: const Text('修改'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 32),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 小部件
// ---------------------------------------------------------------------------

class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        color: OctopusColors.border,
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.4,
      color: OctopusColors.textSecondary,
    ),
  );
}

class _ImageBox extends StatelessWidget {
  const _ImageBox({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final file = path == null ? null : File(path!);
    final exists = file != null && file.existsSync();
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxHeight: 220),
        color: OctopusColors.surfaceHigh,
        child: exists
            ? Image.file(file, fit: BoxFit.contain)
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Icon(
                  Icons.image_not_supported_outlined,
                  color: OctopusColors.textTertiary,
                ),
              ),
      ),
    );
  }
}

/// SVG 预览。
///
/// 外面套一层白底：SVG 是假设白纸画的，放在深色主题的灰底上会看不清黑色线条。
class _SvgBox extends StatelessWidget {
  const _SvgBox({required this.svg});

  final String svg;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxHeight: 240),
        padding: const EdgeInsets.all(12),
        color: Colors.white,
        child: SvgPicture.string(svg, fit: BoxFit.contain),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? OctopusColors.accent : OctopusColors.border,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 20,
              color: selected
                  ? OctopusColors.accent
                  : OctopusColors.textTertiary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: OctopusColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: OctopusColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: OctopusColors.danger.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: OctopusColors.danger.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: OctopusColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: OctopusColors.danger,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
