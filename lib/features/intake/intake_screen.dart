import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app/theme/octopus_theme.dart';
import '../../providers/app_providers.dart';
import '../review/review_screen.dart';

/// 录入：拍一张（或选一张）试卷，然后框选出错题。
///
/// 阶段一还没有自动切题和 OCR，所以流程是**手动框选**：拖出一个框、确认、
/// 再拖下一道。切出来的每一块都会成为待确认列表里的一条草稿。
class IntakeScreen extends ConsumerStatefulWidget {
  const IntakeScreen({super.key});

  @override
  ConsumerState<IntakeScreen> createState() => _IntakeScreenState();
}

class _IntakeScreenState extends ConsumerState<IntakeScreen> {
  final _picker = ImagePicker();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(currentProfileObjectProvider);
    final batchId = ref.watch(activeBatchProvider);
    final enabled = profile != null && !_busy;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OctopusSpacing.page,
        4,
        OctopusSpacing.page,
        32,
      ),
      children: [
        Text(
          '录入',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            color: OctopusColors.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          profile == null ? '先添加孩子' : '计入「${profile.name}」的错题库',
          style: TextStyle(
            fontSize: 13,
            color: OctopusColors.textSecondary,
          ),
        ),
        const SizedBox(height: 20),

        // 有未完成的录入时置顶——这是最该点的东西。
        if (batchId != null) ...[
          _ResumeCard(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ReviewScreen(batchId: batchId),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],

        _BigAction(
          icon: Icons.photo_camera_outlined,
          title: '拍试卷',
          subtitle: '对着整页拍，再框出错题',
          primary: true,
          busy: _busy,
          onTap: enabled ? () => _pick(ImageSource.camera) : null,
        ),
        const SizedBox(height: 12),
        _BigAction(
          icon: Icons.photo_library_outlined,
          title: '从相册选',
          subtitle: '用已经在相册里的照片',
          busy: _busy,
          onTap: enabled ? () => _pick(ImageSource.gallery) : null,
        ),

        const SizedBox(height: 28),
        const _HowItWorks(),
      ],
    );
  }

  Future<void> _pick(ImageSource source) async {
    final profile = ref.read(currentProfileObjectProvider);
    if (profile == null) return;

    setState(() => _busy = true);
    try {
      final picked = await _picker.pickImage(
        source: source,
        // 试卷是文字，留着分辨率给后面的 OCR；同时设上限避免大图把内存撑爆。
        maxWidth: 2400,
        imageQuality: 92,
      );
      if (picked == null) return;

      // image_picker 返回的是缓存路径，重启后可能被清掉，所以复制进应用目录。
      final saved = await persistIntakeFile(
        picked.path,
        'source_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );

      final db = ref.read(databaseProvider);
      final batchId = await db.createBatch(profile.id);
      ref.read(activeBatchProvider.notifier).set(batchId);

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CropScreen(batchId: batchId, imagePath: saved),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// 把文件复制进 `<文档目录>/intake/`，返回新路径。
Future<String> persistIntakeFile(String sourcePath, String fileName) async {
  final dir = await getApplicationDocumentsDirectory();
  final target = Directory(p.join(dir.path, 'intake'));
  if (!target.existsSync()) target.createSync(recursive: true);
  final file = File(p.join(target.path, fileName));
  return (await File(sourcePath).copy(file.path)).path;
}

// ---------------------------------------------------------------------------
// 框选切题
// ---------------------------------------------------------------------------

/// 在一张试卷照片上拖出矩形，切出错题。
///
/// 框用**相对图片的归一化坐标**（0..1）保存，不是相对控件。这一点很关键：
/// 图片按 `BoxFit.contain` 显示时四周可能留边，如果按控件归一化，切出来的
/// 位置会整体偏移。
class CropScreen extends ConsumerStatefulWidget {
  const CropScreen({super.key, required this.batchId, required this.imagePath});

  final int batchId;
  final String imagePath;

  @override
  ConsumerState<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends ConsumerState<CropScreen> {
  final List<Rect> _rects = [];
  Rect? _drag;
  Size? _imageSize;
  bool _saving = false;

  /// 已经识别完的题数，只用来显示进度。
  int _ocrDone = 0;

  @override
  void initState() {
    super.initState();
    // 提前拿到图片真实像素尺寸，才能把它和显示区域对应起来。
    final decoded = img.decodeImage(File(widget.imagePath).readAsBytesSync());
    if (decoded != null) {
      _imageSize = Size(decoded.width.toDouble(), decoded.height.toDouble());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OctopusColors.background,
      appBar: AppBar(
        title: const Text('框出错题'),
        actions: [
          if (_rects.isNotEmpty && !_saving)
            TextButton(
              onPressed: _finish,
              child: Text('完成（${_rects.length}）'),
            ),
          if (_saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),        ],
      ),
      body: Column(
        children: [
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
                      final box = constraints.biggest;
                      final imageRect = _imageRect(box);
                      return GestureDetector(
                        onPanStart: (d) => _onStart(d.localPosition, imageRect),
                        onPanUpdate: (d) =>
                            _onUpdate(d.localPosition, imageRect),
                        onPanEnd: (_) => _onEnd(),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.file(
                              File(widget.imagePath),
                              fit: BoxFit.contain,
                            ),
                            CustomPaint(
                              painter: _CropPainter(
                                confirmed: _rects,
                                dragging: _drag,
                                imageRect: imageRect,
                                stroke: OctopusColors.accent,
                                dim: OctopusColors.background.withValues(
                                  alpha: 0.6,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          _CropFooter(
            count: _rects.length,
            busyLabel: _saving
                ? '正在裁切并识别 ${_ocrDone + 1}/${_rects.length}…'
                : null,
            onUndo: _rects.isEmpty || _saving
                ? null
                : () => setState(() => _rects.removeLast()),
            onFinish: _rects.isEmpty || _saving ? null : _finish,
          ),
        ],
      ),
    );
  }

  /// 图片在控件里实际占据的矩形（`BoxFit.contain` 会留边）。
  Rect _imageRect(Size box) {
    final size = _imageSize;
    if (size == null) return Offset.zero & box;
    final fitted = applyBoxFit(BoxFit.contain, size, box);
    return Alignment.center.inscribe(fitted.destination, Offset.zero & box);
  }

  Offset? _normalize(Offset local, Rect imageRect) {
    if (!imageRect.contains(local)) return null;
    return Offset(
      ((local.dx - imageRect.left) / imageRect.width).clamp(0.0, 1.0),
      ((local.dy - imageRect.top) / imageRect.height).clamp(0.0, 1.0),
    );
  }

  void _onStart(Offset local, Rect imageRect) {
    final n = _normalize(local, imageRect);
    if (n == null) return;
    setState(() => _drag = Rect.fromPoints(n, n));
  }

  void _onUpdate(Offset local, Rect imageRect) {
    final start = _drag;
    if (start == null) return;
    // 拖出图片边界时夹回边界，而不是丢弃这次拖动。
    final clamped = Offset(
      local.dx.clamp(imageRect.left, imageRect.right),
      local.dy.clamp(imageRect.top, imageRect.bottom),
    );
    final n = _normalize(clamped, imageRect);
    if (n == null) return;
    setState(() => _drag = Rect.fromPoints(start.topLeft, n));
  }

  void _onEnd() {
    final r = _drag;
    setState(() => _drag = null);
    // 太小的框基本是误触。
    if (r == null || r.width < 0.03 || r.height < 0.015) return;
    setState(() => _rects.add(r));
  }

  /// 把每个框裁出来存成独立文件，登记为待确认题，并**顺手识别文字**。
  ///
  /// 裁切直接用 `package:image` 在 Dart 里做，不走平台通道：纯像素操作，
  /// 省一次跨平台往返，也更好测。
  ///
  /// 识别放在这里而不是确认页，是因为这是「拍完自动处理」那一步——用户在框选时
  /// 就能看到进度，进确认页时文字已经在了。识别失败不影响切题结果，草稿照样入库，
  /// 用户可以手动补。
  Future<void> _finish() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final runOcr = ref.read(autoOcrProvider);
    final ocr = ref.read(ocrEngineInstanceProvider);

    try {
      final decoded = img.decodeImage(File(widget.imagePath).readAsBytesSync());
      if (decoded == null) {
        messenger.showSnackBar(const SnackBar(content: Text('图片解码失败')));
        return;
      }

      final db = ref.read(databaseProvider);
      var recognized = 0;
      var failed = 0;

      for (var order = 0; order < _rects.length; order++) {
        final rect = _rects[order];
        final x = (rect.left * decoded.width)
            .round()
            .clamp(0, decoded.width - 1);
        final y = (rect.top * decoded.height)
            .round()
            .clamp(0, decoded.height - 1);
        final w = (rect.width * decoded.width)
            .round()
            .clamp(1, decoded.width - x);
        final h = (rect.height * decoded.height)
            .round()
            .clamp(1, decoded.height - y);

        final crop = img.copyCrop(decoded, x: x, y: y, width: w, height: h);
        final path = await persistIntakeFileBytes(
          img.encodeJpg(crop, quality: 92),
          'q_${DateTime.now().microsecondsSinceEpoch}_$order.jpg',
        );

        String content = '';
        if (runOcr) {
          if (mounted) setState(() => _ocrDone = order);
          try {
            content = (await ocr.recognize(path)).text;
            if (content.isNotEmpty) recognized++;
          } catch (_) {
            // 单题识别失败不该让整批停下，草稿仍然入库，用户可手动补文字。
            failed++;
          }
        }

        await db.insertDraft(
          batchId: widget.batchId,
          originalImagePath: path,
          content: content,
          sortOrder: order,
        );
      }

      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            _summary(
              total: _rects.length,
              recognized: recognized,
              failed: failed,
              ranOcr: runOcr,
            ),
          ),
        ),
      );
      navigator.pop();
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => ReviewScreen(batchId: widget.batchId),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _summary({
    required int total,
    required int recognized,
    required int failed,
    required bool ranOcr,
  }) {
    if (!ranOcr) return '切出 $total 道题，确认后入库';
    if (failed == 0) return '切出 $total 道题，已识别 $recognized 道';
    return '切出 $total 道题，识别成功 $recognized 道、失败 $failed 道';
  }
}

/// 写字节到 `<文档目录>/intake/`，返回路径。
Future<String> persistIntakeFileBytes(List<int> bytes, String fileName) async {
  final dir = await getApplicationDocumentsDirectory();
  final target = Directory(p.join(dir.path, 'intake'));
  if (!target.existsSync()) target.createSync(recursive: true);
  final file = File(p.join(target.path, fileName));
  await file.writeAsBytes(bytes);
  return file.path;
}

/// 画框：已确认的 + 正在拖的，框外压暗。
class _CropPainter extends CustomPainter {
  _CropPainter({
    required this.confirmed,
    required this.dragging,
    required this.imageRect,
    required this.stroke,
    required this.dim,
  });

  final List<Rect> confirmed;
  final Rect? dragging;
  final Rect imageRect;
  final Color stroke;
  final Color dim;

  @override
  void paint(Canvas canvas, Size size) {
    Rect toPixels(Rect r) => Rect.fromLTWH(
      imageRect.left + r.left * imageRect.width,
      imageRect.top + r.top * imageRect.height,
      r.width * imageRect.width,
      r.height * imageRect.height,
    );

    final all = [...confirmed, ?dragging];
    if (all.isEmpty) return;

    // 只压暗图片区域，留边本来就该是背景色。
    final outside = Path()..addRect(imageRect);
    for (final r in all) {
      outside.addRect(toPixels(r));
    }
    outside.fillType = PathFillType.evenOdd;
    canvas.drawPath(outside, Paint()..color = dim);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    for (final r in confirmed) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(toPixels(r), const Radius.circular(6)),
        paint..color = stroke,
      );
    }
    if (dragging != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(toPixels(dragging!), const Radius.circular(6)),
        paint..color = stroke.withValues(alpha: 0.65),
      );
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.confirmed.length != confirmed.length ||
      old.dragging != dragging ||
      old.imageRect != imageRect;
}

class _CropFooter extends StatelessWidget {
  const _CropFooter({
    required this.count,
    required this.onUndo,
    required this.onFinish,
    this.busyLabel,
  });

  final int count;
  final String? busyLabel;
  final VoidCallback? onUndo;
  final VoidCallback? onFinish;

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
                child: Text(
                  busyLabel ??
                      (count == 0 ? '在照片上拖动，框出一道题' : '已框出 $count 道'),
                  maxLines: 2,
                  style: TextStyle(
                    fontSize: 13,
                    color: OctopusColors.textSecondary,
                  ),
                ),
              ),
              if (onUndo != null)
                TextButton(onPressed: onUndo, child: const Text('撤销')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: onFinish,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                child: const Text('完成'),
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

class _BigAction extends StatelessWidget {
  const _BigAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
    this.busy = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool primary;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !busy;
    return Opacity(
      opacity: enabled || busy ? 1 : 0.45,
      child: Material(
        color: primary ? OctopusColors.accent : OctopusColors.surface,
        borderRadius: BorderRadius.circular(OctopusRadius.card),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(OctopusRadius.card),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(OctopusRadius.card),
              border: Border.all(
                color: primary ? OctopusColors.accent : OctopusColors.border,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 26,
                  color: primary
                      ? OctopusColors.onAccent
                      : OctopusColors.textPrimary,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: primary
                              ? OctopusColors.onAccent
                              : OctopusColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: primary
                              ? OctopusColors.onAccent.withValues(alpha: 0.72)
                              : OctopusColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (busy)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: primary
                          ? OctopusColors.onAccent
                          : OctopusColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ResumeCard extends StatelessWidget {
  const _ResumeCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: OctopusColors.surfaceHigh,
      borderRadius: BorderRadius.circular(OctopusRadius.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(OctopusRadius.card),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                Icons.pending_actions_outlined,
                size: 22,
                color: OctopusColors.textPrimary,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  '有一次录入还没确认',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: OctopusColors.textPrimary,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: OctopusColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  static const _steps = [
    ('拍照', '把整页拍进来，光线均匀一些'),
    ('框选', '用手指拖出每道错题的范围'),
    ('确认', '检查识别结果，改一改再入库'),
    ('打印', '挑题、排版、一键打印'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: OctopusColors.surface,
        borderRadius: BorderRadius.circular(OctopusRadius.card),
        border: Border.all(color: OctopusColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '流程',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: OctopusColors.textPrimary,
            ),
          ),
          const SizedBox(height: 14),
          for (var i = 0; i < _steps.length; i++) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 20,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: OctopusColors.surfaceHigh,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: OctopusColors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.6,
                        color: OctopusColors.textSecondary,
                      ),
                      children: [
                        TextSpan(
                          text: '${_steps[i].$1}  ',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: OctopusColors.textPrimary,
                          ),
                        ),
                        TextSpan(text: _steps[i].$2),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (i != _steps.length - 1) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}
