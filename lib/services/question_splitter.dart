import 'dart:math' as math;
import 'dart:ui';

/// 识别出来的**印刷体**文字行。
///
/// 自动切题只看题干文字，不看手写答案——手写字会让「这一行属于哪道题」的判断
/// 变得很乱，而题干已经足够定了。
class PageLine {
  const PageLine({required this.text, required this.box});

  final String text;

  /// 像素坐标，原点在图片左上角。
  final Rect box;

  double get top => box.top;
  double get bottom => box.bottom;
}

/// 切出来的一道题。
class QuestionRegion {
  const QuestionRegion({required this.box, this.marker});

  /// 归一化坐标（0..1），和手动框选存的是同一套坐标。
  final Rect box;

  /// 识别到的题号，如「3.」「（2）」。没识别到时为 null。
  final String? marker;

  @override
  String toString() =>
      'QuestionRegion(${box.left.toStringAsFixed(2)},'
      '${box.top.toStringAsFixed(2)},'
      '${box.width.toStringAsFixed(2)},'
      '${box.height.toStringAsFixed(2)}'
      '${marker == null ? '' : ', $marker'})';
}

/// 取出落在 [region] 里的文字行。
///
/// [lines] 和 [pageSize] 都是像素坐标；[region] 是归一化坐标。AI 录入模式下用它
/// 把每道题的文字拼出来——切题是按块切的，文字是按行给的，这里把两者对上，
/// 省掉一次逐题识别。
///
/// 判断用**行的中心点**而不是整行的矩形：一行横跨两个框时，归给中心所在的那个框
/// 才符合直觉。
List<String> linesInRegion({
  required List<PageLine> lines,
  required Rect region,
  required Size pageSize,
}) {
  if (pageSize.width <= 0 || pageSize.height <= 0) return const [];
  final result = <String>[];
  for (final line in lines) {
    final center = Offset(
      line.box.center.dx / pageSize.width,
      line.box.center.dy / pageSize.height,
    );
    if (region.contains(center)) {
      final text = line.text.trim();
      if (text.isNotEmpty) result.add(text);
    }
  }
  return result;
}

/// 题号出现在行首的各种写法。
///
/// 覆盖小学作业里最常见的几种：`1.` `1、` `1)` `（1）` `一、`。刻意不匹配
/// 行中间的数字——应用题里「3 个苹果」不该被当成题号。
final _markerPatterns = <RegExp>[
  // 1.  1、  1． 1)
  RegExp(r'^\s*(\d{1,2})\s*[.、．)）]\s*'),
  // （1）  (1)  【1】
  RegExp(r'^\s*[（(【\[]\s*(\d{1,2})\s*[)）】\]]\s*'),
  // 一、 二.  三）
  RegExp(r'^\s*([一二三四五六七八九十]{1,3})\s*[、.．)）]\s*'),
  // 第 3 题
  RegExp(r'^\s*第\s*(\d{1,2})\s*题\s*[：:.]?\s*'),
];

/// 从一页的文字行里切出题目。
///
/// 两条路径：
///
/// 1. **按题号切**——找到 ≥2 个题号行，就按它们分段。这是最准的，因为题号是
///    作者自己划的边界。
/// 2. **按空白切**——没有题号（比如一整段连续的题目、或者只有一道题）时，用
///    行间垂直间距找断点。
///
/// 题号优先：空白可能出现在一道题内部（比如题目和它的选项之间），而题号不会。
///
/// 返回**归一化坐标**。切不出来时返回空列表，调用方回退到手动框选。
List<QuestionRegion> splitIntoQuestions({
  required List<PageLine> lines,
  required Size pageSize,
  double padding = 0.02,
}) {
  if (lines.isEmpty || pageSize.width <= 0 || pageSize.height <= 0) {
    return const [];
  }

  final sorted = [...lines]..sort((a, b) => a.top.compareTo(b.top));
  final groups = _groupByMarker(sorted) ?? _groupByGap(sorted);
  if (groups.isEmpty) return const [];

  final regions = <QuestionRegion>[];
  for (final group in groups) {
    // 一组的所有行的并集就是这道题的区域。
    var box = group.lines.first.box;
    for (final line in group.lines.skip(1)) {
      box = box.expandToInclude(line.box);
    }

    final normalized = Rect.fromLTRB(
      (box.left / pageSize.width - padding).clamp(0.0, 1.0),
      (box.top / pageSize.height - padding).clamp(0.0, 1.0),
      (box.right / pageSize.width + padding).clamp(0.0, 1.0),
      (box.bottom / pageSize.height + padding).clamp(0.0, 1.0),
    );

    // 太扁或太窄的多半是页眉、页码之类，不是题目。
    if (normalized.height < 0.02 || normalized.width < 0.05) continue;
    regions.add(QuestionRegion(box: normalized, marker: group.marker));
  }
  return regions;
}

class _Group {
  _Group(this.marker);

  final String? marker;
  final List<PageLine> lines = [];
}

/// 按题号分段。找到的题号少于 2 个就认为不可靠，返回 null 让调用方走空白切分。
List<_Group>? _groupByMarker(List<PageLine> sorted) {
  final starts = <int>[];
  final markers = <String?>[];

  for (var i = 0; i < sorted.length; i++) {
    final marker = _matchMarker(sorted[i].text);
    if (marker != null) {
      starts.add(i);
      markers.add(marker);
    }
  }
  if (starts.length < 2) return null;

  // 第一个题号之前的内容（页眉、卷头）归到第一组，避免丢掉。
  final groups = <_Group>[];
  for (var g = 0; g < starts.length; g++) {
    final from = g == 0 ? 0 : starts[g];
    final to = g + 1 < starts.length ? starts[g + 1] : sorted.length;
    final group = _Group(markers[g]);
    for (var i = from; i < to; i++) {
      group.lines.add(sorted[i]);
    }
    if (group.lines.isNotEmpty) groups.add(group);
  }
  return groups;
}

/// 按垂直空白分段：间距明显大于「正常行距」的地方就是断点。
List<_Group> _groupByGap(List<PageLine> sorted) {
  if (sorted.length == 1) {
    return [_Group(_matchMarker(sorted.first.text))..lines.add(sorted.first)];
  }

  // 关键是用**行距**推导阈值，不是用行高。
  //
  // 一开始我用行高中位数 × 1.6，但行高和行距没有固定关系：如果字体小、行距大
  // （比如 20px 的字配 60px 行距），每两行之间的空白都会超过阈值，一段连续的
  // 文字会被切成一堆单行碎片。
  //
  // 改成看实际的行距：取行距的**下四分位**当「正常行距」。下四分位天然忽略掉
  // 那些真正的大空白——4 个行距里即使有 2 个大空白，下四分位仍然是小的那个。
  final gaps = <double>[];
  for (var i = 1; i < sorted.length; i++) {
    gaps.add(sorted[i].top - sorted[i - 1].bottom);
  }
  gaps.sort();
  final normalGap = gaps[gaps.length ~/ 4];

  final heights = <double>[];
  for (final line in sorted) {
    if (line.box.height > 0) heights.add(line.box.height);
  }
  if (heights.isEmpty) return const [];
  heights.sort();
  final medianHeight = heights[heights.length ~/ 2];

  // 2.5 倍正常行距，同时不低于 1.2 倍行高——后者防止「行距本来就很小」时
  // 把排版上的细微空隙当成题目边界。
  final threshold = math.max(normalGap * 2.5, medianHeight * 1.2);

  final groups = <_Group>[];
  var current = _Group(_matchMarker(sorted.first.text))..lines.add(sorted.first);

  for (var i = 1; i < sorted.length; i++) {
    final gap = sorted[i].top - sorted[i - 1].bottom;
    if (gap > threshold) {
      groups.add(current);
      current = _Group(_matchMarker(sorted[i].text))..lines.add(sorted[i]);
    } else {
      current.lines.add(sorted[i]);
    }
  }
  groups.add(current);
  return groups;
}

/// 行首的题号，返回匹配到的原文（便于显示），没匹配到返回 null。
String? _matchMarker(String text) {
  for (final pattern in _markerPatterns) {
    final match = pattern.firstMatch(text);
    if (match != null) {
      final value = match.group(1);
      final whole = match.group(0)!.trim();
      // 中文数字形式的题号可能超过 10（十一），这里不额外校验。
      if (value != null && whole.isNotEmpty) return whole;
    }
  }
  return null;
}
