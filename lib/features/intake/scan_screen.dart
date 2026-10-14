import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../../app/theme/octopus_theme.dart';
import '../../providers/app_providers.dart';
import '../../services/deepseek_client.dart';
import '../../services/deepseek_grader.dart';
import '../../services/ocr_service.dart';
import '../../services/question_splitter.dart';
import 'intake_screen.dart' show persistIntakeFileBytes;

/// 处理阶段。
enum ScanPhase { scanning, grading, done, failed }

/// 页面上的一道题：位置、识别出的文字、批改结果。
class ScanItem {
  ScanItem({required this.box});

  /// 归一化坐标（0..1），和手动框选存的是同一套。
  final Rect box;

  String text = '';

  /// 切出来的图片路径。批改和入库都要用。
  String? cropPath;

  GradeOutcome? grade;
  String? error;

  /// 是否加入题库。默认做错的才选上。
  bool selected = false;

  bool get isCorrect => grade?.isCorrect ?? false;
  bool get isWrong => grade != null && !grade!.isCorrect;
}

/// AI 录入：拍完整页，自动切题 + 批改，把结果画在照片上。
///
/// 和手动框选的区别不只是省事。手动模式下自动切题切歪了，用户要到下一个页面
/// 才发现；这里结果直接画在原图上，切歪了一眼就看见。
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({
    super.key,
    required this.batchId,
    required this.imagePath,
  });

  final int batchId;
  final String imagePath;

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep;
  final _items = <ScanItem>[];
  ScanPhase _phase = ScanPhase.scanning;
  Size? _imageSize;
  String _status = '正在识别题目…';
  int _graded = 0;
  int _toGrade = 0;
  String? _fatal;

  @override
  void initState() {
    super.initState();
    // 扫描线：处理期间一直扫，处理完停下。
    _sweep = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    final decoded = img.decodeImage(File(widget.imagePath).readAsBytesSync());
    if (decoded != null) {
      _imageSize = Size(decoded.width.toDouble(), decoded.height.toDouble());
    }
    _run();
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  bool get _busy =>
      _phase == ScanPhase.scanning || _phase == ScanPhase.grading;

  @override
  Widget build(BuildContext context) {
    final selected = _items.where((i) => i.selected).length;

    return Scaffold(
      backgroundColor: OctopusColors.background,
      appBar: AppBar(
        title: Text(_busy ? '正在批改' : '批改结果'),
        bottom: _busy
            ? PreferredSize(
                preferredSize: const Size.fromHeight(24),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _status,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: OctopusColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              )
            : null,
      ),
      body: Column(
        children: [
          if (_fatal != null) _FatalBanner(message: _fatal!),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(OctopusSpacing.page),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(OctopusRadius.card),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: OctopusColors.surfaceHigh,
                    border: Border.all(color: OctopusColors.border),
                    borderRadius: BorderRadius.circular(OctopusRadius.card),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final imageRect = _imageRect(constraints.biggest);
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.file(
                            File(widget.imagePath),
                            fit: BoxFit.contain,
                          ),
                          // 处理中：扫描线 + 整页压暗，让等待有内容。
                          if (_busy)
                            AnimatedBuilder(
                              animation: _sweep,
                              builder: (context, _) => CustomPaint(
                                painter: _ScanPainter(
                                  progress: _sweep.value,
                                  imageRect: imageRect,
                                  color: OctopusColors.accent,
                                  dim: OctopusColors.background.withValues(
                                    alpha: 0.35,
                                  ),
                                ),
                              ),
                            ),
                          // 结果框。每个框是一个可点的区域。
                          for (var i = 0; i < _items.length; i++)
                            _BoxOverlay(
                              item: _items[i],
                              index: i,
                              imageRect: imageRect,
                              onTap: () => _toggle(i),
                              onLongPress: () => _openDetail(i),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          if (!_busy && _items.isNotEmpty)
            _ResultBar(
              total: _items.length,
              wrong: _items.where((i) => i.isWrong).length,
              selected: selected,
              onSelectWrongOnly: () => setState(() {
                for (final item in _items) {
                  item.selected = item.isWrong;
                }
              }),
              onSelectAll: () => setState(() {
                for (final item in _items) {
                  item.selected = true;
                }
              }),
              onClear: () => setState(() {
                for (final item in _items) {
                  item.selected = false;
                }
              }),
              onSubmit: selected == 0 ? null : _submit,
            ),
          if (!_busy && _items.isEmpty)
            _EmptyBar(onRetry: _run, onManual: () => Navigator.pop(context)),
        ],
      ),
    );
  }

  /// 图片在控件里实际占的矩形（`BoxFit.contain` 会留边）。
  ///
  /// 框存的是归一化坐标，换算成像素必须基于**图片**而不是控件，否则整体偏移。
  Rect _imageRect(Size box) {
    final size = _imageSize;
    if (size == null) return Offset.zero & box;
    final fitted = applyBoxFit(BoxFit.contain, size, box);
    return Alignment.center.inscribe(fitted.destination, Offset.zero & box);
  }

  // -- 处理 ------------------------------------------------------------------

  Future<void> _run() async {
    setState(() {
      _items.clear();
      _phase = ScanPhase.scanning;
      _status = '正在识别题目…';
      _graded = 0;
      _toGrade = 0;
      _fatal = null;
    });

    final size = _imageSize;
    if (size == null) {
      _fail('读不到图片尺寸');
      return;
    }

    try {
      // 1. 端上识别拿文字块坐标。自动切题要的是**位置**，所以固定用本地引擎，
      //    即使设置里选了云端——云端只返回纯文本，拿不到坐标。
      final ocr = await MlKitOcrEngine().recognize(widget.imagePath);
      if (!mounted) return;

      if (!ocr.hasGeometry) {
        _fail('没识别到文字。可以换张清楚点的照片，或用「手动框选」。');
        return;
      }

      final regions = splitIntoQuestions(lines: ocr.lines, pageSize: size);
      if (regions.isEmpty) {
        _fail('没切出题目。可以换张照片，或用「手动框选」。');
        return;
      }

      // 2. 按框裁图。裁完才有东西可以逐题批改。
      final decoded = img.decodeImage(
        File(widget.imagePath).readAsBytesSync(),
      );
      if (decoded == null) {
        _fail('图片解码失败');
        return;
      }

      for (var i = 0; i < regions.length; i++) {
        final region = regions[i];
        final rect = region.box;
        final x = (rect.left * decoded.width).round().clamp(
          0,
          decoded.width - 1,
        );
        final y = (rect.top * decoded.height).round().clamp(
          0,
          decoded.height - 1,
        );
        final w = (rect.width * decoded.width).round().clamp(
          1,
          decoded.width - x,
        );
        final h = (rect.height * decoded.height).round().clamp(
          1,
          decoded.height - y,
        );

        final crop = img.copyCrop(decoded, x: x, y: y, width: w, height: h);
        final path = await persistIntakeFileBytes(
          img.encodeJpg(crop, quality: 92),
          'scan_${DateTime.now().microsecondsSinceEpoch}_$i.jpg',
        );

        final item = ScanItem(box: rect)..cropPath = path;
        // 框里的文字：OCR 是按行给的，切题是按块给的，这里把两者对上，
        // 省掉一次逐题识别。
        item.text = linesInRegion(
          lines: ocr.lines,
          region: rect,
          pageSize: size,
        ).join('\n');

        setState(() => _items.add(item));
      }

      // 3. 逐题批改。
      final key = ref.read(deepSeekKeyProvider);
      final gradingOn =
          ref.read(gradingEnabledProvider) &&
          ref.read(aiGradingProvider) &&
          key.trim().isNotEmpty;

      if (!gradingOn) {
        // 没开批改或没配 Key：仍然把题切好了，直接进可点选状态。
        // 默认全选——用户既然用了这个模式，就是想把这些题收进来。
        setState(() {
          for (final item in _items) {
            item.selected = true;
          }
          _phase = ScanPhase.done;
          _status = '';
        });
        return;
      }

      setState(() {
        _phase = ScanPhase.grading;
        _toGrade = _items.length;
      });

      final profile = ref.read(currentProfileObjectProvider);
      final grade = profile?.grade ?? 4;
      final grader = DeepSeekGrader(apiKey: key);

      for (final item in _items) {
        if (!mounted) return;
        try {
          final bytes = await readQuestionImage(item.cropPath!);
          final outcome = await grader.grade(
            imageBytes: bytes,
            grade: grade,
          );
          if (!mounted) return;
          setState(() {
            item.grade = outcome;
            // 默认只选做错的——错题集的用途就是错题。做对的仍然显示出来，
            // 用户想留也可以自己点。
            item.selected = !outcome.isCorrect;
            _graded++;
            _status = '正在批改 $_graded/$_toGrade…';
          });
        } on DeepSeekException catch (error) {
          if (!mounted) return;
          setState(() {
            item.error = error.message;
            // 批改失败的题默认选上：宁可多收一道让用户自己判断，
            // 也不要因为 API 出错就把题漏掉。
            item.selected = true;
            _graded++;
            _status = '正在批改 $_graded/$_toGrade…';
          });
        }
      }

      if (!mounted) return;
      final failed = _items.where((i) => i.error != null).length;
      setState(() {
        _phase = ScanPhase.done;
        _status = failed == 0 ? '' : '有 $failed 道没批上，已默认选中';
      });
    } catch (error) {
      if (mounted) _fail('处理失败：$error');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _fatal = message;
      _phase = ScanPhase.failed;
    });
  }

  void _toggle(int index) {
    if (_busy) return;
    setState(() => _items[index].selected = !_items[index].selected);
  }

  Future<void> _openDetail(int index) async {
    if (_busy) return;
    final item = _items[index];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: OctopusColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(OctopusRadius.sheet),
        ),
      ),
      builder: (_) => _ItemSheet(
        item: item,
        index: index + 1,
        onChanged: () => setState(() {}),
      ),
    );
  }

  Future<void> _submit() async {
    final profile = ref.read(currentProfileObjectProvider);
    if (profile == null) return;
    final db = ref.read(databaseProvider);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    var accepted = 0;
    for (final item in _items.where((i) => i.selected)) {
      final outcome = item.grade;
      await db.insertQuestion(
        profileId: profile.id,
        content: item.text,
        originalImagePath: item.cropPath,
        subject: null,
        correctAnswer: outcome?.correctAnswer,
        gradeResult: outcome?.gradeResult,
        gradeReason: outcome?.reason,
      );
      accepted++;
    }

    navigator.pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text('已入库 $accepted 道题'),
        action: SnackBarAction(
          label: '去错题库',
          onPressed: () => ref.read(shellTabProvider.notifier).go(0),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 画在照片上的框
// ---------------------------------------------------------------------------

/// 一道题的框 + 角上的对错标记。整个框都可以点。
class _BoxOverlay extends StatelessWidget {
  const _BoxOverlay({
    required this.item,
    required this.index,
    required this.imageRect,
    required this.onTap,
    required this.onLongPress,
  });

  final ScanItem item;
  final int index;
  final Rect imageRect;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final rect = Rect.fromLTWH(
      imageRect.left + item.box.left * imageRect.width,
      imageRect.top + item.box.top * imageRect.height,
      item.box.width * imageRect.width,
      item.box.height * imageRect.height,
    );

    // 颜色按结果分：对绿、错红、没批上灰。选中再加一层描边。
    final color = item.grade == null
        ? OctopusColors.textTertiary
        : item.isCorrect
        ? OctopusColors.success
        : OctopusColors.danger;

    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: item.selected ? color : color.withValues(alpha: 0.45),
              width: item.selected ? 3 : 2,
            ),
            // 未选中的压一层暗色，选中的保持清晰——一眼看出哪些会被收进去。
            color: item.selected
                ? color.withValues(alpha: 0.10)
                : OctopusColors.background.withValues(alpha: 0.45),
          ),
          child: Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: _Badge(item: item, index: index),
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.item, required this.index});

  final ScanItem item;
  final int index;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (item) {
      _ when item.error != null => (Icons.priority_high, OctopusColors.warning),
      _ when item.grade == null => (Icons.more_horiz, OctopusColors.textSecondary),
      _ when item.isCorrect => (Icons.check, OctopusColors.success),
      _ => (Icons.close, OctopusColors.danger),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(OctopusRadius.pill),
        border: Border.all(color: Colors.white.withValues(alpha: 0.8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.white),
          const SizedBox(width: 3),
          Text(
            '$index',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// 扫描动画：一条横线从上往下扫，线上方提亮。
class _ScanPainter extends CustomPainter {
  _ScanPainter({
    required this.progress,
    required this.imageRect,
    required this.color,
    required this.dim,
  });

  final double progress;
  final Rect imageRect;
  final Color color;
  final Color dim;

  @override
  void paint(Canvas canvas, Size size) {
    // 整页压暗，让扫描线更醒目。
    canvas.drawRect(imageRect, Paint()..color = dim);

    final y = imageRect.top + imageRect.height * progress;

    // 已扫过的部分提亮一点。
    canvas.drawRect(
      Rect.fromLTRB(imageRect.left, imageRect.top, imageRect.right, y),
      Paint()..color = color.withValues(alpha: 0.08),
    );

    // 扫描线本身，上下各加一层渐变做出光晕。
    canvas.drawRect(
      Rect.fromLTRB(imageRect.left, y - 14, imageRect.right, y + 14),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0),
            color.withValues(alpha: 0.55),
            color.withValues(alpha: 0),
          ],
        ).createShader(
          Rect.fromLTRB(imageRect.left, y - 14, imageRect.right, y + 14),
        ),
    );
    canvas.drawRect(
      Rect.fromLTRB(imageRect.left, y - 1, imageRect.right, y + 1),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_ScanPainter old) =>
      old.progress != progress || old.imageRect != imageRect;
}

// ---------------------------------------------------------------------------
// 底部条与单题详情
// ---------------------------------------------------------------------------

class _ResultBar extends StatelessWidget {
  const _ResultBar({
    required this.total,
    required this.wrong,
    required this.selected,
    required this.onSelectWrongOnly,
    required this.onSelectAll,
    required this.onClear,
    required this.onSubmit,
  });

  final int total;
  final int wrong;
  final int selected;
  final VoidCallback onSelectWrongOnly;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;
  final VoidCallback? onSubmit;

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
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    '共 $total 道 · 错 $wrong 道',
                    style: TextStyle(
                      fontSize: 13,
                      color: OctopusColors.textSecondary,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '已选 $selected',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: OctopusColors.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ActionChip(
                    label: const Text('只选错题'),
                    onPressed: onSelectWrongOnly,
                  ),
                  ActionChip(label: const Text('全选'), onPressed: onSelectAll),
                  ActionChip(label: const Text('全不选'), onPressed: onClear),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onSubmit,
                  child: Text(
                    onSubmit == null ? '点框选择要入库的题' : '入库 $selected 道',
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

class _ItemSheet extends StatelessWidget {
  const _ItemSheet({
    required this.item,
    required this.index,
    required this.onChanged,
  });

  final ScanItem item;
  final int index;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final grade = item.grade;
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
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                '第 $index 题',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: OctopusColors.textPrimary,
                ),
              ),
              const Spacer(),
              if (grade != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color:
                        (item.isCorrect
                                ? OctopusColors.success
                                : OctopusColors.danger)
                            .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(OctopusRadius.pill),
                  ),
                  child: Text(
                    item.isCorrect ? '做对了' : '做错了',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: item.isCorrect
                          ? OctopusColors.success
                          : OctopusColors.danger,
                    ),
                  ),
                ),
            ],
          ),
          if (item.error != null) ...[
            const SizedBox(height: 12),
            Text(
              '没批上：${item.error}',
              style: TextStyle(fontSize: 12.5, color: OctopusColors.warning),
            ),
          ],
          const SizedBox(height: 16),
          if (item.cropPath != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                constraints: const BoxConstraints(maxHeight: 220),
                color: OctopusColors.surfaceHigh,
                child: Image.file(
                  File(item.cropPath!),
                  fit: BoxFit.contain,
                ),
              ),
            ),
          if (item.text.isNotEmpty) ...[
            const SizedBox(height: 16),
            SelectableText(
              item.text,
              style: TextStyle(
                fontSize: 15,
                height: 1.8,
                color: OctopusColors.textPrimary,
              ),
            ),
          ],
          if (grade?.correctAnswer != null) ...[
            const SizedBox(height: 16),
            _AnswerBox(answer: grade!.correctAnswer!),
          ],
          if (grade?.reason != null) ...[
            const SizedBox(height: 10),
            Text(
              grade!.reason!,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: OctopusColors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () {
              item.selected = !item.selected;
              onChanged();
              Navigator.pop(context);
            },
            icon: Icon(
              item.selected ? Icons.remove_circle_outline : Icons.add_circle_outline,
              size: 18,
            ),
            label: Text(item.selected ? '从入库列表移除' : '加入入库列表'),
          ),
        ],
      ),
    );
  }
}

class _AnswerBox extends StatelessWidget {
  const _AnswerBox({required this.answer});

  final String answer;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: OctopusColors.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '正确答案',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: OctopusColors.textSecondary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              answer,
              style: TextStyle(
                fontSize: 14,
                height: 1.7,
                color: OctopusColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FatalBanner extends StatelessWidget {
  const _FatalBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: OctopusColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: OctopusColors.warning.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline,
            size: 16,
            color: OctopusColors.warning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: OctopusColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyBar extends StatelessWidget {
  const _EmptyBar({required this.onRetry, required this.onManual});

  final VoidCallback onRetry;
  final VoidCallback onManual;

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
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onManual,
                  child: const Text('改用手动框选'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(onPressed: onRetry, child: const Text('重试')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 扫描线用的缓动，让来回更自然。
double easeInOutSine(double t) => (1 - math.cos(math.pi * t)) / 2;
