import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'data/database.dart';
import 'providers/app_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 数据库和 SharedPreferences 的初始化都是异步的，而 provider 是同步的。
  // 在启动时各读一次并覆盖 provider，比让界面层到处 await 简单得多。
  final db = await OctopusDatabase.open();
  final prefs = await SharedPreferences.getInstance();

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const OctopusApp(),
    ),
  );
}
