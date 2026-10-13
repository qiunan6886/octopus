import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../app/theme/octopus_theme.dart';
import '../../data/database.dart';
import '../../providers/app_providers.dart';

/// 练习卷：挑出来的题的集合，可以预览、导出 PDF、直接打印。
///
/// 阶段一还没有 OCR，所以每道题能拿到的内容**只有切出来的原图**。因此这里
/// 直接排版图片，而不是排文字——顺带绕开了 PDF 里的中文字体问题（`pdf` 包
/// 内置字体不支持中文，嵌入 CJK 字体要额外几 MB）。
/// 等 OCR 接上之后，纯文字题会改排成文字，图片只用于图形题。
class PrintScreen extends ConsumerWidget {
  const PrintScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileObjectProvider);
    if (profile == null) {
      return const Center(child: Text('先添加一个孩子'));
    }

    final async = ref.watch(worksheetsProvider(profile.id));
    final sheets = async.value ?? const <Worksheet>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            OctopusSpacing.page,
            4,
            OctopusSpacing.page,
            16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '练习卷',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: OctopusColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                sheets.isEmpty ? '还没有练习卷' : '共 ${sheets.length} 份',
                style: TextStyle(
                  fontSize: 13,
                  color: OctopusColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: sheets.isEmpty
              ? _EmptyWorksheets(
                  onGoLibrary: () =>
                      ref.read(shellTabProvider.notifier).go(0),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                    OctopusSpacing.page,
                    0,
                    OctopusSpacing.page,
                    24,
                  ),
                  itemCount: sheets.length,
                  itemBuilder: (context, i) => _WorksheetCard(
                    sheet: sheets[i],
                    onOpen: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => WorksheetPreviewScreen(
                          worksheet: sheets[i],
                        ),
                      ),
                    ),
                    onDelete: () =>
                        _confirmDelete(context, ref, profile, sheets[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Profile profile,
    Worksheet sheet,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除练习卷'),
        content: Text('删除「${sheet.name}」？题目本身不会被删掉。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('删除', style: TextStyle(color: OctopusColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref
        .read(databaseProvider)
        .deleteWorksheet(profile.id, sheet.id);
  }
}

final worksheetsProvider =
    StreamProvider.family<List<Worksheet>, int>((ref, profileId) {
      return ref.watch(databaseProvider).watchWorksheetsFor(profileId);
    });

final worksheetQuestionsProvider =
    FutureProvider.family<List<Question>, int>((ref, worksheetId) {
      return ref.watch(databaseProvider).worksheetQuestions(worksheetId);
    });

class _WorksheetCard extends ConsumerWidget {
  const _WorksheetCard({
    required this.sheet,
    required this.onOpen,
    required this.onDelete,
  });

  final Worksheet sheet;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final questions =
        ref.watch(worksheetQuestionsProvider(sheet.id)).value ?? const [];
    final dated =
        '${sheet.createdAt.year}/${sheet.createdAt.month}/${sheet.createdAt.day}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: OctopusColors.surface,
        borderRadius: BorderRadius.circular(OctopusRadius.card),
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(OctopusRadius.card),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(OctopusRadius.card),
              border: Border.all(color: OctopusColors.border),
            ),
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: OctopusColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.description_outlined,
                    size: 20,
                    color: OctopusColors.textPrimary,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sheet.name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: OctopusColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '$dated · ${questions.length} 道题',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: OctopusColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: OctopusColors.textTertiary,
                  tooltip: '删除',
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
      ),
    );
  }
}

class _EmptyWorksheets extends StatelessWidget {
  const _EmptyWorksheets({required this.onGoLibrary});

  final VoidCallback onGoLibrary;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.print_outlined,
              size: 48,
              color: OctopusColors.textTertiary,
            ),
            const SizedBox(height: 18),
            Text(
              '还没有练习卷',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: OctopusColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '去错题库长按选中几道题，\n点「生成练习卷」。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.7,
                color: OctopusColors.textSecondary,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: onGoLibrary,
              child: const Text('去错题库'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 预览与打印
// ---------------------------------------------------------------------------

class WorksheetPreviewScreen extends ConsumerWidget {
  const WorksheetPreviewScreen({super.key, required this.worksheet});

  final Worksheet worksheet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileObjectProvider);
    final async = ref.watch(worksheetQuestionsProvider(worksheet.id));
    final questions = async.value ?? const <Question>[];

    return Scaffold(
      backgroundColor: OctopusColors.background,
      appBar: AppBar(title: Text(worksheet.name)),
      body: async.isLoading
          ? const Center(child: CircularProgressIndicator())
          : questions.isEmpty
          ? const Center(child: Text('这份练习卷里没有题目'))
          : Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(
                      OctopusSpacing.page,
                      8,
                      OctopusSpacing.page,
                      24,
                    ),
                    itemCount: questions.length,
                    itemBuilder: (context, i) =>
                        _PreviewItem(question: questions[i], index: i + 1),
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: OctopusColors.surface,
                    border: Border(
                      top: BorderSide(color: OctopusColors.border),
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _exportPdf(
                                context,
                                profile?.name ?? '',
                                questions,
                              ),
                              icon: const Icon(Icons.ios_share, size: 18),
                              label: const Text('导出 PDF'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _print(
                                context,
                                profile?.name ?? '',
                                questions,
                              ),
                              icon: const Icon(Icons.print, size: 18),
                              label: const Text('打印'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _exportPdf(
    BuildContext context,
    String childName,
    List<Question> questions,
  ) async {
    final bytes = await buildWorksheetPdf(
      title: worksheet.name,
      childName: childName,
      questions: questions,
    );
    await Printing.sharePdf(bytes: bytes, filename: '${worksheet.name}.pdf');
  }

  Future<void> _print(
    BuildContext context,
    String childName,
    List<Question> questions,
  ) async {
    await Printing.layoutPdf(
      name: worksheet.name,
      onLayout: (format) => buildWorksheetPdf(
        title: worksheet.name,
        childName: childName,
        questions: questions,
        format: format,
      ),
    );
  }
}

class _PreviewItem extends StatelessWidget {
  const _PreviewItem({required this.question, required this.index});

  final Question question;
  final int index;

  @override
  Widget build(BuildContext context) {
    final path = question.originalImagePath;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        decoration: BoxDecoration(
          color: OctopusColors.surface,
          borderRadius: BorderRadius.circular(OctopusRadius.card),
          border: Border.all(color: OctopusColors.border),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '$index.',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: OctopusColors.textPrimary,
                  ),
                ),
                const SizedBox(width: 8),
                if (question.usesAiRedrawnFigure)
                  Icon(
                    Icons.auto_fix_high,
                    size: 13,
                    color: OctopusColors.textTertiary,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (path != null && File(path).existsSync())
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(File(path), fit: BoxFit.contain),
              ),
            if (question.content.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                question.content,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.7,
                  color: OctopusColors.textPrimary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 这道题该不该打重绘版。
///
/// 两个条件都要满足：用户选过重绘版，而且重绘的 SVG 确实存在。少判后一个就会
/// 在 SVG 为空时崩掉。
bool _useRedrawn(Question question) =>
    question.usesAiRedrawnFigure && (question.redrawnSvg?.isNotEmpty ?? false);

/// 把练习卷排成 A4 PDF。
///
/// 在预览和打印之间共用同一个函数，保证「看到的」和「打出来的」是同一份东西。
Future<Uint8List> buildWorksheetPdf({
  required String title,
  required String childName,
  required List<Question> questions,
  PdfPageFormat format = PdfPageFormat.a4,
}) async {
  final doc = pw.Document();

  // 先把所有图片解码好。PDF 生成是异步的，而 pw.Image 需要同步的
  // MemoryImage，所以先读进内存。
  final images = <pw.MemoryImage>[];
  for (final q in questions) {
    final path = q.originalImagePath;
    if (path == null || !File(path).existsSync()) {
      images.add(pw.MemoryImage(Uint8List(0)));
      continue;
    }
    images.add(pw.MemoryImage(File(path).readAsBytesSync()));
  }

  doc.addPage(
    pw.MultiPage(
      pageFormat: format,
      margin: const pw.EdgeInsets.fromLTRB(36, 36, 36, 40),
      header: (context) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 12),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              title,
              style: pw.TextStyle(
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.Text(
              childName,
              style: pw.TextStyle(fontSize: 11, color: PdfColors.grey700),
            ),
          ],
        ),
      ),
      footer: (context) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          '第 ${context.pageNumber} / ${context.pagesCount} 页',
          style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
        ),
      ),
      build: (context) => [
        for (var i = 0; i < questions.length; i++)
          pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 18),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Row(
                  children: [
                    pw.Text(
                      '${i + 1}.',
                      style: pw.TextStyle(
                        fontSize: 12,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    if (questions[i].usesAiRedrawnFigure)
                      pw.Padding(
                        padding: const pw.EdgeInsets.only(left: 6),
                        child: pw.Text(
                          '（图形为 AI 重绘，请核对）',
                          style: pw.TextStyle(
                            fontSize: 8,
                            color: PdfColors.grey600,
                          ),
                        ),
                      ),
                  ],
                ),
                pw.SizedBox(height: 6),
                // 选了重绘版的题打 SVG，否则打原图。
                //
                // `pdf` 包原生支持 SVG，所以重绘的结果不需要先栅格化就能印——
                // 这也是当初让模型输出 SVG 而不是位图的原因之一。
                if (_useRedrawn(questions[i]))
                  pw.ConstrainedBox(
                    constraints: const pw.BoxConstraints(maxHeight: 320),
                    child: pw.SvgImage(
                      svg: questions[i].redrawnSvg!,
                      fit: pw.BoxFit.contain,
                    ),
                  )
                else if (images[i].bytes.isNotEmpty)
                  pw.ConstrainedBox(
                    constraints: const pw.BoxConstraints(maxHeight: 320),
                    child: pw.Image(images[i], fit: pw.BoxFit.contain),
                  ),
                if (questions[i].content.trim().isNotEmpty)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(top: 6),
                    child: pw.Text(
                      questions[i].content,
                      style: pw.TextStyle(fontSize: 11, lineSpacing: 3),
                    ),
                  ),
              ],
            ),
          ),
      ],
    ),
  );

  return doc.save();
}
