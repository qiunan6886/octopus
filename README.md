# Octopus · 错题集

把孩子的错题**拍照 → 切题 → 还原成干净的新题 → 挑题排版打印**，省掉手抄。

> **当前状态：阶段二进行中。**
> 已实现：多孩子隔离、黑白双主题、拍照/相册录入、手动框选切题、
> **本地 OCR 文字识别（切题后自动跑）**、**拍照批改（AI 视觉 + 手动标记）**、
> 待确认环节、错题库多选、生成练习卷、导出 PDF / 打印。
> **还没实现**：自动切题、AI 重绘图形公式、变式题、中英双语。

## OCR：本地 / 云端可选

在**设置 → 识别**里切换，另有一个「切题后自动识别」开关（默认开）。

| 引擎 | 用什么 | 优点 | 缺点 |
|---|---|---|---|
| **本地**（默认） | Google ML Kit | 离线、免费、**照片不出设备** | APK 约 32MB；读不了手写体 |
| **云端** | DeepSeek 视觉模型 | 能读手写体、理解版面、公式转 LaTeX | 照片要上传、按次收费 |

本地是默认，因为题目照片里常有孩子的姓名、学校、班级。**没配 API Key 时选云端
会自动回退到本地**——拍照录入是主流程，不该因为一个可选配置卡住。

> 中文模型**打包进了 APK**（`com.google.mlkit:text-recognition-chinese`），
> 不是首次使用时下载。代价是 APK 大 13MB，换来的是开箱即用、真离线。

## 拍照批改

**批改和录入是同一条流程，不是两个功能。** 「错题」的定义就是做错的题——只要能
判断对错，错题库就能自动筛出来。

在**设置 → 批改**里开关，默认关：

| 设置 | 默认 | 说明 |
|---|---|---|
| 拍照后批改 | 关 | 打开后流程里多一步判断对错 |
| 用 AI 批改 | 开 | 关掉或没配 Key 时，自己点「做对了 / 做错了」 |
| 做对的题也入库 | 关 | 默认只留错题 |

**AI 批改**把切出来的那道题（含孩子的手写答案）发给 `deepseek-flash`，它判断对错
并给出正确答案。**手动批改**完全离线，点一下就行，再点一次撤销。

两种方式的结果都**只是建议**：确认页每题都能改对错、改正确答案，AI 的判断带 `AI`
标记，一眼能看出哪些需要复核。

> 为什么不比对答案：题目和答案都是手写的，题型又五花八门，要比对得先有标准答案，
> 而这里没有。视觉模型能同时看见题干和孩子的答案，直接判断。

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
| 改 schema 不写迁移 | 老用户升级后新字段不存在，读写直接崩 | `onUpgrade` 加列，`test/migration_test.dart` 用真实的 v1 库验证 |
| ML Kit 只打包中文模型 | R8 找不到其他语种的识别器，release 构建直接失败 | `proguard-rules.pro` 里 `-dontwarn` 那些包 |
| PowerShell 往返读写中文文件 | 文件变乱码且被提交 | 不用 PowerShell 读写中文文本；`tools/check_encoding.py` 做**往返检测** |
| Bash 控制台把 UTF-8 当 GBK 显示 | 中文看起来像乱码，误判成文件损坏 | 用 Python `repr` 看真实字符，不信控制台渲染 |

## 测试

```
flutter test
```

| 文件 | 覆盖 |
|---|---|
| `test/data_isolation_test.dart` | 题目按孩子隔离；用错的身份删不到别人的题 |
| `test/grading_parse_test.dart` | 批改响应解析：代码围栏、下划线字段名、字符串布尔值、答案里带引号 |
| `test/ocr_parse_test.dart` | OCR 响应解析：多行题目、图形占位符、空结果处理 |
| `test/migration_test.dart` | v1 库升级到 v2，批改字段可用且老数据不丢 |

共 29 个测试。

## 许可

私有项目。
