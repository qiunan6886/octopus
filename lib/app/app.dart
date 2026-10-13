import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import '../features/shell/app_shell.dart';
import 'theme/octopus_theme.dart';

/// 应用根。
///
/// 负责把 [OctopusColors] 的静态值切到当前调色板，然后重建整棵树。
///
/// 为什么需要重建：颜色走 `OctopusColors.accent` 这样的静态读取（和 Spark
/// 一样的取舍），Flutter 观察不到静态值的变化。所以每次 build 先调用
/// [OctopusColors.apply]，再用 palette id 当 key —— key 变了，子树就会重建，
/// 读到新颜色。
class OctopusApp extends ConsumerWidget {
  const OctopusApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choice = ref.watch(themeChoiceProvider);
    final media = MediaQuery.maybeOf(context);
    final systemIsDark = media?.platformBrightness == Brightness.dark;

    final palette = switch (choice) {
      ThemeChoice.paper => octopusPaper,
      ThemeChoice.ink => octopusInk,
      ThemeChoice.system => systemIsDark ? octopusInk : octopusPaper,
    };

    OctopusColors.apply(palette);

    final theme = buildOctopusTheme(palette);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: OctopusColors.systemOverlay,
      child: MaterialApp(
        title: 'Octopus 错题集',
        debugShowCheckedModeBanner: false,
        theme: theme,
        // 单色设计只有两套，两处都传同一个 theme；亮暗由 palette 决定。
        darkTheme: theme,
        themeMode: ThemeMode.light,
        home: KeyedSubtree(
          // palette id 作 key：换主题时强制重建，静态颜色才会刷新。
          key: ValueKey(palette.id),
          child: const AppShell(),
        ),
      ),
    );
  }
}
