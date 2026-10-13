import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octopus/app/theme/octopus_theme.dart';

/// 主题。
///
/// 重点不是「颜色好不好看」，而是几条会被静默破坏的规则：
/// 纸和墨互为反色、彩色不该渗透到单色主题、学科配色要稳定。
void main() {
  tearDown(() => OctopusColors.apply(octopusPaper));

  test('纸和墨互为反色', () {
    expect(octopusPaper.brightness, Brightness.light);
    expect(octopusInk.brightness, Brightness.dark);

    // 强调色互换：纸是黑，墨是白。
    expect(octopusPaper.accent, const Color(0xFF111111));
    expect(octopusInk.accent, const Color(0xFFFFFFFF));

    // 底色也互换：纸亮、墨暗。
    expect(
      octopusPaper.background.computeLuminance(),
      greaterThan(octopusInk.background.computeLuminance()),
    );
    expect(octopusInk.background, const Color(0xFF000000));
  });

  test('纸和墨都不带彩色', () {
    expect(octopusPaper.isColorful, isFalse);
    expect(octopusInk.isColorful, isFalse);
    // 没有第二强调色和语义色，界面取到的会是中性值。
    expect(octopusPaper.accentAlt, isNull);
    expect(octopusInk.success, isNull);
    expect(octopusPaper.heroGradient, isNull);
  });

  test('彩主题是彩色，且带了参与界面的颜色', () {
    expect(octopusVivid.isColorful, isTrue);
    expect(octopusVivid.accentAlt, isNotNull);
    expect(octopusVivid.success, isNotNull);
    expect(octopusVivid.warning, isNotNull);
    expect(octopusVivid.heroGradient, isNotNull);
    // 第二强调色和主强调色必须真的不同，否则「彩色」是假的。
    expect(octopusVivid.accentAlt, isNot(octopusVivid.accent));
  });

  test('彩主题仍然满足可读的对比度', () {
    // 正文压在背景上、标签压在卡片上，都要看得清。
    double contrast(Color a, Color b) {
      final l1 = a.computeLuminance();
      final l2 = b.computeLuminance();
      final hi = l1 > l2 ? l1 : l2;
      final lo = l1 > l2 ? l2 : l1;
      return (hi + 0.05) / (lo + 0.05);
    }

    expect(
      contrast(octopusVivid.textPrimary, octopusVivid.background),
      greaterThan(4.5),
      reason: '正文对比度要过 4.5:1',
    );
    expect(
      contrast(octopusVivid.onAccent, octopusVivid.accent),
      greaterThan(3.0),
      reason: '压在强调色上的文字至少 3:1',
    );
    expect(
      contrast(octopusVivid.textSecondary, octopusVivid.surface),
      greaterThan(4.5),
      reason: '次要文字也要能读',
    );
  });

  test('单色主题下学科配色是中性色——彩色不该渗透进来', () {
    OctopusColors.apply(octopusPaper);
    final inPaper = [
      OctopusColors.subjectColor('数学'),
      OctopusColors.subjectColor('语文'),
      OctopusColors.subjectColor('英语'),
    ];
    expect(inPaper.toSet().length, 1, reason: '单色主题下所有学科同一个颜色');
    expect(inPaper.first, OctopusColors.textSecondary);

    expect(OctopusColors.accentAlt, octopusPaper.accent);
    expect(OctopusColors.success, octopusPaper.textSecondary);

    OctopusColors.apply(octopusInk);
    expect(OctopusColors.subjectColor('数学'), OctopusColors.textSecondary);
    expect(OctopusColors.accentAlt, octopusInk.accent);
  });

  test('彩主题下不同学科拿到不同颜色，同一学科永远同一个颜色', () {
    OctopusColors.apply(octopusVivid);

    final colors = {
      for (final s in ['数学', '语文', '英语', '科学', '道德与法治'])
        s: OctopusColors.subjectColor(s),
    };
    // 五个学科至少要有三种颜色，否则「按科目上色」没意义。
    expect(colors.values.toSet().length, greaterThanOrEqualTo(3));

    // 稳定性：同名字必然同色，否则每次重建颜色都在跳。
    for (final entry in colors.entries) {
      expect(OctopusColors.subjectColor(entry.key), entry.value);
    }

    // 空学科回退到中性色，不参与配色。
    expect(OctopusColors.subjectColor(null), OctopusColors.textSecondary);
    expect(OctopusColors.subjectColor(''), OctopusColors.textSecondary);
  });

  test('单色主题的渐变两端同色，界面不用写分支', () {
    OctopusColors.apply(octopusPaper);
    final gradient = OctopusColors.heroGradient as LinearGradient;
    expect(gradient.colors.first, gradient.colors.last);
    expect(gradient.colors.first, octopusPaper.accent);

    OctopusColors.apply(octopusVivid);
    final vivid = OctopusColors.heroGradient as LinearGradient;
    expect(vivid.colors.first, isNot(vivid.colors.last));
  });

  test('每个调色板的 id 唯一——它同时是强制重建用的 widget key', () {
    final ids = [
      octopusPaper.id,
      octopusInk.id,
      octopusVivid.id,
    ];
    expect(ids.toSet().length, ids.length);
  });

  test('apply 会切换全局颜色', () {
    OctopusColors.apply(octopusInk);
    expect(OctopusColors.isDark, isTrue);
    expect(OctopusColors.background, octopusInk.background);

    OctopusColors.apply(octopusVivid);
    expect(OctopusColors.isDark, isFalse);
    expect(OctopusColors.isColorful, isTrue);
    expect(OctopusColors.background, octopusVivid.background);
  });
}
