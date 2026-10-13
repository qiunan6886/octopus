import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/theme/octopus_theme.dart';
import '../data/database.dart';

// ---------------------------------------------------------------------------
// 基础设施
// ---------------------------------------------------------------------------

/// 数据库实例。
///
/// 打开是异步的（要等 path_provider 给目录），而 provider 是同步的，所以在
/// `main()` 里打开一次再覆盖。好处是界面层完全不用处理「数据库还没准备好」
/// 这个中间态。
final databaseProvider = Provider<OctopusDatabase>((ref) {
  throw UnimplementedError('databaseProvider 必须在 main() 里用真实实例覆盖');
});

final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError(
    'sharedPreferencesProvider 必须在 main() 里用真实实例覆盖',
  );
});

// ---------------------------------------------------------------------------
// 主题
// ---------------------------------------------------------------------------

/// 用户选择的主题。`system` 跟随系统。
enum ThemeChoice { system, paper, ink }

const _themeKey = 'octopus.theme';

final themeChoiceProvider = NotifierProvider<ThemeChoiceNotifier, ThemeChoice>(
  ThemeChoiceNotifier.new,
);

class ThemeChoiceNotifier extends Notifier<ThemeChoice> {
  @override
  ThemeChoice build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final raw = prefs.getString(_themeKey);
    return ThemeChoice.values.firstWhere(
      (c) => c.name == raw,
      orElse: () => ThemeChoice.system,
    );
  }

  Future<void> set(ThemeChoice choice) async {
    state = choice;
    await ref.read(sharedPreferencesProvider).setString(_themeKey, choice.name);
  }
}

/// 真正生效的调色板。
final activePaletteProvider = Provider<OctopusPalette>((ref) {
  final choice = ref.watch(themeChoiceProvider);
  return switch (choice) {
    ThemeChoice.paper => octopusPaper,
    ThemeChoice.ink => octopusInk,
    // `system` 的判定放在 app 层，那里才有 MediaQuery。
    ThemeChoice.system => octopusPaper,
  };
});

/// 当前标签页。
///
/// 放在 provider 里而不是外壳的 State 里，是为了让别的页面能跳转过去——
/// 比如「生成练习卷」之后跳到练习卷标签。
final shellTabProvider = NotifierProvider<ShellTabNotifier, int>(
  ShellTabNotifier.new,
);

class ShellTabNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void go(int index) => state = index;
}

// ---------------------------------------------------------------------------
// 孩子（Profile）
// ---------------------------------------------------------------------------

final profilesProvider = StreamProvider<List<Profile>>((ref) {
  return ref.watch(databaseProvider).watchProfiles();
});

const _currentProfileKey = 'octopus.currentProfileId';

/// 当前选中的孩子。
///
/// 全局只有一个「当前孩子」，切换后整个应用（列表、打印、AI 提示词）都跟着变。
/// 这是设计文档里定下的规则：不提供「全部孩子」视图，避免两个孩子的题混在一起。
final currentProfileProvider = NotifierProvider<CurrentProfileNotifier, int?>(
  CurrentProfileNotifier.new,
);

class CurrentProfileNotifier extends Notifier<int?> {
  @override
  int? build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final stored = prefs.getInt(_currentProfileKey);
    if (stored != null) return stored;

    // 首次运行：还没有孩子时返回 null，由界面引导创建。
    // 有孩子但没记录过选择时，默认第一个。
    final profiles = ref.watch(profilesProvider).value;
    if (profiles != null && profiles.isNotEmpty) return profiles.first.id;
    return null;
  }

  Future<void> select(int? profileId) async {
    state = profileId;
    final prefs = ref.read(sharedPreferencesProvider);
    if (profileId == null) {
      await prefs.remove(_currentProfileKey);
    } else {
      await prefs.setInt(_currentProfileKey, profileId);
    }
  }
}

/// 当前孩子对象。界面大部分地方用这个。
final currentProfileObjectProvider = Provider<Profile?>((ref) {
  final id = ref.watch(currentProfileProvider);
  final profiles = ref.watch(profilesProvider).value;
  if (id == null || profiles == null) return null;
  for (final p in profiles) {
    if (p.id == id) return p;
  }
  return null;
});

// ---------------------------------------------------------------------------
// 设置
// ---------------------------------------------------------------------------

/// OCR 引擎。设计文档定的是两种都做、用户自己选。
enum OcrEngineKind { local, cloud }

const _ocrKey = 'octopus.ocrEngine';

final ocrEngineProvider = NotifierProvider<OcrEngineNotifier, OcrEngineKind>(
  OcrEngineNotifier.new,
);

class OcrEngineNotifier extends Notifier<OcrEngineKind> {
  @override
  OcrEngineKind build() {
    final raw = ref.watch(sharedPreferencesProvider).getString(_ocrKey);
    return OcrEngineKind.values.firstWhere(
      (e) => e.name == raw,
      // 默认本地：照片不出设备是更安全的默认值，尤其题目里常有孩子的姓名班级。
      orElse: () => OcrEngineKind.local,
    );
  }

  Future<void> set(OcrEngineKind kind) async {
    state = kind;
    await ref.read(sharedPreferencesProvider).setString(_ocrKey, kind.name);
  }
}

const _deepSeekKey = 'octopus.deepSeekApiKey';

/// DeepSeek API Key。用来重绘图形/公式、生成变式题。
final deepSeekKeyProvider = NotifierProvider<DeepSeekKeyNotifier, String>(
  DeepSeekKeyNotifier.new,
);

class DeepSeekKeyNotifier extends Notifier<String> {
  @override
  String build() =>
      ref.watch(sharedPreferencesProvider).getString(_deepSeekKey) ?? '';

  Future<void> set(String key) async {
    state = key;
    await ref.read(sharedPreferencesProvider).setString(_deepSeekKey, key);
  }
}

/// 是否在练习卷上打印孩子姓名。
const _printNameKey = 'octopus.printChildName';

final printChildNameProvider =
    NotifierProvider<PrintChildNameNotifier, bool>(PrintChildNameNotifier.new);

class PrintChildNameNotifier extends Notifier<bool> {
  @override
  bool build() =>
      ref.watch(sharedPreferencesProvider).getBool(_printNameKey) ?? true;

  Future<void> set(bool value) async {
    state = value;
    await ref.read(sharedPreferencesProvider).setBool(_printNameKey, value);
  }
}

// ---------------------------------------------------------------------------
// 拍照批改
// ---------------------------------------------------------------------------

const _gradingKey = 'octopus.gradingEnabled';

/// 是否开启批改。
///
/// 批改和录入是同一条流程——「错题」的定义就是做错的题，所以批改只是在这条
/// 流程里多了一步判断对错，不是另开一个入口。默认关：不批改时就是纯粹的错题
/// 整理，家长仍然是拍照、确认、入库。
final gradingEnabledProvider =
    NotifierProvider<GradingEnabledNotifier, bool>(GradingEnabledNotifier.new);

class GradingEnabledNotifier extends Notifier<bool> {
  @override
  bool build() =>
      ref.watch(sharedPreferencesProvider).getBool(_gradingKey) ?? false;

  Future<void> set(bool value) async {
    state = value;
    await ref.read(sharedPreferencesProvider).setBool(_gradingKey, value);
  }
}

const _keepCorrectKey = 'octopus.gradingKeepCorrect';

/// 批改后是否把**做对**的题也入库。
///
/// 默认否：错题集的用途是做错的题，做对的没有必要占位置。但如果家长想留一份
/// 完整记录（比如看看孩子哪一科全对），可以打开。
final gradingKeepCorrectProvider =
    NotifierProvider<GradingKeepCorrectNotifier, bool>(
      GradingKeepCorrectNotifier.new,
    );

class GradingKeepCorrectNotifier extends Notifier<bool> {
  @override
  bool build() =>
      ref.watch(sharedPreferencesProvider).getBool(_keepCorrectKey) ?? false;

  Future<void> set(bool value) async {
    state = value;
    await ref.read(sharedPreferencesProvider).setBool(_keepCorrectKey, value);
  }
}

/// 批改是否用 AI。
///
/// 关掉时批改完全靠家长点「对 / 错」，离线可用；打开时需要 DeepSeek API Key。
final aiGradingProvider = NotifierProvider<AiGradingNotifier, bool>(
  AiGradingNotifier.new,
);

const _aiGradingKey = 'octopus.aiGrading';

class AiGradingNotifier extends Notifier<bool> {
  @override
  bool build() =>
      ref.watch(sharedPreferencesProvider).getBool(_aiGradingKey) ?? true;

  Future<void> set(bool value) async {
    state = value;
    await ref.read(sharedPreferencesProvider).setBool(_aiGradingKey, value);
  }
}

// ---------------------------------------------------------------------------
// 错题库
// ---------------------------------------------------------------------------

/// 某个孩子的错题。
///
/// 用 `family` 而不是"当前孩子的题"这样一个全局 provider：这样调用点必须
/// 显式给出 profileId，想漏过滤都漏不掉。
final questionsProvider =
    StreamProvider.family<List<Question>, int>((ref, profileId) {
      return ref.watch(databaseProvider).watchQuestionsFor(profileId);
    });

/// 列表里的多选状态。
final selectionProvider =
    NotifierProvider<SelectionNotifier, Set<int>>(SelectionNotifier.new);

class SelectionNotifier extends Notifier<Set<int>> {
  @override
  Set<int> build() => const {};

  void toggle(int questionId) {
    state = state.contains(questionId)
        ? (state.toSet()..remove(questionId))
        : (state.toSet()..add(questionId));
  }

  void setAll(Iterable<int> ids) => state = ids.toSet();
  void clear() => state = const {};
}

/// 是否处于多选模式。进入方式是长按任意一行。
final selectionModeProvider = NotifierProvider<SelectionModeNotifier, bool>(
  SelectionModeNotifier.new,
);

class SelectionModeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void enter() => state = true;

  void exit() {
    state = false;
    ref.read(selectionProvider.notifier).clear();
  }
}

// ---------------------------------------------------------------------------
// 录入与待确认
// ---------------------------------------------------------------------------

/// 当前这次录入的批次 id。null 表示没有进行中的录入。
final activeBatchProvider = NotifierProvider<ActiveBatchNotifier, int?>(
  ActiveBatchNotifier.new,
);

class ActiveBatchNotifier extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? batchId) => state = batchId;
}

final draftsProvider =
    StreamProvider.family<List<DraftQuestion>, int>((ref, batchId) {
      return ref.watch(databaseProvider).watchDraftsFor(batchId);
    });
