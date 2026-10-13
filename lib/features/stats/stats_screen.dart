import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/octopus_theme.dart';
import '../../data/database.dart';
import '../../providers/app_providers.dart';

/// 批改统计。
///
/// 口径是**批改过的题**，不是入库的题。做对的题默认不进错题库，但它们同样是
/// 批改结果；只统计错题库的话正确率永远是 0，那这个页面就没有意义了。
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileObjectProvider);
    if (profile == null) {
      return const Scaffold(body: Center(child: Text('先添加一个孩子')));
    }

    final async = ref.watch(gradingStatsProvider(profile.id));
    final stats = async.value ?? const <SubjectStat>[];
    final overrides =
        ref.watch(manualOverrideCountProvider(profile.id)).value ?? 0;

    final totalCorrect = stats.fold<int>(0, (sum, s) => sum + s.correct);
    final totalWrong = stats.fold<int>(0, (sum, s) => sum + s.wrong);
    final total = totalCorrect + totalWrong;
    final accuracy = total == 0 ? 0.0 : totalCorrect / total;

    return Scaffold(
      backgroundColor: OctopusColors.background,
      appBar: AppBar(title: const Text('批改统计')),
      body: async.isLoading && stats.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : total == 0
          ? const _Empty()
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                OctopusSpacing.page,
                8,
                OctopusSpacing.page,
                32,
              ),
              children: [
                _OverallCard(
                  total: total,
                  correct: totalCorrect,
                  wrong: totalWrong,
                  accuracy: accuracy,
                ),
                const SizedBox(height: 24),
                _SectionLabel('按学科'),
                const SizedBox(height: 10),
                for (final stat in stats) _SubjectRow(stat: stat),
                if (overrides > 0) ...[
                  const SizedBox(height: 24),
                  _SectionLabel('AI 可靠度'),
                  const SizedBox(height: 10),
                  _OverrideCard(overrides: overrides, total: total),
                ],
                const SizedBox(height: 24),
                Text(
                  '统计的是**批改过**的题，包括做对之后没入库的那些——'
                  '只看错题库的话正确率永远是 0。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.7,
                    color: OctopusColors.textTertiary,
                  ),
                ),
              ],
            ),
    );
  }
}

final gradingStatsProvider =
    FutureProvider.family<List<SubjectStat>, int>((ref, profileId) {
      // 数据变了要重算：批改完回来看统计，数字得是新的。
      ref.watch(questionsProvider(profileId));
      return ref.watch(databaseProvider).gradingStats(profileId);
    });

final manualOverrideCountProvider = FutureProvider.family<int, int>((
  ref,
  profileId,
) {
  ref.watch(questionsProvider(profileId));
  return ref.watch(databaseProvider).manuallyOverriddenCount(profileId);
});

class _OverallCard extends StatelessWidget {
  const _OverallCard({
    required this.total,
    required this.correct,
    required this.wrong,
    required this.accuracy,
  });

  final int total;
  final int correct;
  final int wrong;
  final double accuracy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: OctopusColors.surface,
        borderRadius: BorderRadius.circular(OctopusRadius.card),
        border: Border.all(color: OctopusColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '总体正确率',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: OctopusColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '${(accuracy * 100).round()}',
                style: TextStyle(
                  fontSize: 44,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1.5,
                  height: 1,
                  color: OctopusColors.textPrimary,
                ),
              ),
              Text(
                '%',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: OctopusColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(OctopusRadius.pill),
            child: LinearProgressIndicator(
              value: accuracy,
              minHeight: 8,
              backgroundColor: OctopusColors.surfaceHigh,
              valueColor: AlwaysStoppedAnimation(
                OctopusColors.success,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _Pill(
                label: '做对 $correct',
                color: OctopusColors.success,
              ),
              const SizedBox(width: 8),
              _Pill(
                label: '做错 $wrong',
                color: OctopusColors.danger,
              ),
              const Spacer(),
              Text(
                '共 $total 道',
                style: TextStyle(
                  fontSize: 12.5,
                  color: OctopusColors.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SubjectRow extends StatelessWidget {
  const _SubjectRow({required this.stat});

  final SubjectStat stat;

  @override
  Widget build(BuildContext context) {
    final color = OctopusColors.subjectColor(stat.subject);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: OctopusColors.surface,
          borderRadius: BorderRadius.circular(OctopusRadius.card),
          border: Border.all(color: OctopusColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  stat.subject,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: OctopusColors.textPrimary,
                  ),
                ),
                const Spacer(),
                Text(
                  '${stat.accuracyPercent}%',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: OctopusColors.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(OctopusRadius.pill),
              child: LinearProgressIndicator(
                value: stat.accuracy,
                minHeight: 6,
                backgroundColor: OctopusColors.surfaceHigh,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '对 ${stat.correct} · 错 ${stat.wrong} · 共 ${stat.total}',
              style: TextStyle(
                fontSize: 11.5,
                color: OctopusColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// AI 判过、家长又手动改过的比例。
///
/// 这个数字高说明 AI 的批改不太可信，家长应该多复核；低则说明可以放心让它先判。
class _OverrideCard extends StatelessWidget {
  const _OverrideCard({required this.overrides, required this.total});

  final int overrides;
  final int total;

  @override
  Widget build(BuildContext context) {
    final ratio = total == 0 ? 0.0 : overrides / total;
    final hint = switch (ratio) {
      >= 0.3 => 'AI 的判断改动比较多，建议每次批改后都过一遍。',
      >= 0.1 => '偶尔需要改，AI 的判断大体可用。',
      _ => 'AI 判断基本没被改过，可以放心让它先批。',
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: OctopusColors.surface,
        borderRadius: BorderRadius.circular(OctopusRadius.card),
        border: Border.all(color: OctopusColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'AI 判过 $total 道，其中 $overrides 道被你改过（${(ratio * 100).round()}%）',
            style: TextStyle(
              fontSize: 13.5,
              height: 1.6,
              color: OctopusColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            hint,
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: OctopusColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(OctopusRadius.pill),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.4,
      color: OctopusColors.textSecondary,
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.insights_outlined,
              size: 48,
              color: OctopusColors.textTertiary,
            ),
            const SizedBox(height: 18),
            Text(
              '还没有批改记录',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: OctopusColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '在「设置 → 批改」里打开「拍照后批改」，\n'
              '拍一次作业并确认之后就会有了。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.7,
                color: OctopusColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
