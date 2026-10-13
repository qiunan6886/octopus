# Octopus · 错题集

把孩子的错题**拍照 → 切题 → 还原成干净的新题 → 挑题排版打印**，省掉手抄。

> **当前状态：阶段一 MVP 已可运行。**
> 已实现：多孩子隔离、黑白双主题、拍照/相册录入、手动框选切题、待确认环节、
> 错题库多选、生成练习卷、导出 PDF / 打印。
> **还没实现**：OCR 识别、AI 重绘图形公式、变式题、云端 OCR、中英双语。

## 文档

| 文件 | 说明 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | 设计文档（做什么、为什么） |
| [docs/UX.md](docs/UX.md) | **UX 设计**（长什么样、为什么） |
| [docs/design-v0.2.html](docs/design-v0.2.html) | 网页版设计文档 |

手机上看网页版：**https://qiunan6886.github.io/octopus/**

## 跑起来

```bash
flutter pub get
flutter run                    # 连真机跑
flutter build apk --release    # 出 APK
flutter test                   # 数据层测试
flutter analyze                # 应为 0 错误 0 警告
```

APK 在 `build/app/outputs/flutter-apk/app-release.apk`。

## 代码结构

```
lib/
├── main.dart                      # 入口：异步初始化后覆盖 provider
├── app/
│   ├── app.dart                   # MaterialApp + 主题切换
│   └── theme/octopus_theme.dart   # 黑白双主题、尺寸 token
├── data/
│   ├── models.dart                # 数据模型（手写 fromMap）
│   └── database.dart              # sqflite + 变更通知流
├── providers/app_providers.dart   # Riverpod 状态
└── features/
    ├── shell/                     # 外壳：孩子切换 + 底部导航
    ├── library/                   # 错题库（多选、全选、生成练习卷）
    ├── intake/                    # 拍照 / 相册 / 框选切题
    ├── review/                    # ★ 待确认环节
    ├── print/                     # 练习卷预览 / PDF / 打印
    └── settings/                  # 孩子、主题、OCR、AI、打印
```

## 三个关键设计判断

1. **不做图像修复去笔迹**，改用**文本重建** —— 把印刷体 OCR 出来重新排版，
   结果必然干净；含图形/公式的区域保留原图，可选让 `deepseek-flash` 重绘成 SVG
2. **不做全自动** —— 自动切题和去笔迹都不可能 100% 准，所以有「待确认」环节，
   用户确认后才入库，避免家长反复返工
3. **照片默认不出设备** —— 默认用本地 OCR；切到云端 OCR 时界面会明确提示
   照片会上传到第三方

## 两个孩子的数据隔离

这是整个项目最容易出、后果最严重的一类错误——把老二的题打进老大的卷子。

所以隔离做在**存储层**，不是界面层：

- `profileId` 是必填外键，不存在「无主」的题
- **所有**读写题目的方法都要求传 `profileId`（`deleteQuestions`、`setMastery` 也一样）
- **不提供**「全部孩子」视图
- 拍照流程第一步就确认归属

`test/data_isolation_test.dart` 对着真实 SQLite 验证这些保证，8 个测试覆盖到
「用错的身份删不到别人的题」这种反向场景。

## 技术选型

| 项 | 选择 | 说明 |
|---|---|---|
| 框架 | Flutter 3.47 | Android，minSdk 26 |
| 状态管理 | Riverpod 3 | |
| 本地存储 | **sqflite** | 见下方说明 |
| PDF / 打印 | `pdf` + `printing` | |
| 拍照 | `image_picker` | |
| 裁切 | `image` | 纯 Dart 像素操作，不走平台通道 |

### 为什么是 sqflite 而不是 drift

设计阶段选的是 drift。实际搭建时遇到死结：

- drift 2.32+ 依赖的 `sqlite3` 3.x 会在**编译时从 GitHub 下载**预编译的
  SQLite 库，网络不通就整个构建失败
- 想降级到用 `sqlite3` 2.x 的旧版 drift，又与新版 `build_runner` 的
  analyzer 版本要求冲突，解不开

sqflite 直接用 Android 系统自带的 SQLite，**没有原生资源、不需要联网**，
构建永远可复现。代价是失去编译期的查询检查，用「所有方法必须传 profileId」
这条纪律补回来。

## 已踩过的坑（都有测试兜住）

| 坑 | 后果 | 兜法 |
|---|---|---|
| SQLite 默认不开外键约束 | `ON DELETE CASCADE` 形同虚设，删掉孩子留下一堆孤儿题 | `onConfigure` 里 `PRAGMA foreign_keys = ON`，测试验证 |
| 框选按控件归一化 | 图片 `BoxFit.contain` 留边时，裁出来的位置整体偏移 | 按**相对图片**的归一化坐标存 |
| PowerShell 往返读写中文文件 | 文件变乱码且被提交 | 不用 PowerShell 读写中文文本；`tools/check_encoding.py` 检测 |

## 许可

私有项目。
