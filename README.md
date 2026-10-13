# Octopus · 错题集

把孩子的错题**拍照 → 自动切题 → 还原成干净的新题 → 挑题排版打印**，省掉手抄。

> **当前状态：设计已定稿（v0.2），尚未开发。**

## 文档

| 文件 | 说明 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | **设计文档源文件**（Markdown） |
| [docs/design-v0.2.html](docs/design-v0.2.html) | 网页版（带目录跳转，手机可直接看） |
| [docs/Octopus-设计文档-v0.2.docx](docs/Octopus-设计文档-v0.2.docx) | Word 版 |

手机上看网页版：**https://qiunan6886.github.io/octopus/**

> GitHub 会把 `.html` 当源码显示，所以仓库启用了 Pages 来发布网页版。

## 修改文档后怎么同步

`docs/DESIGN.md` 是唯一源文件，改完重跑脚本生成另外两种格式：

```bash
python tools/build_design_html.py docs/DESIGN.md docs/design-v0.2.html
python tools/build_design_docx.py docs/DESIGN.md docs/Octopus-设计文档-v0.2.docx
```

## 工具

| 脚本 | 用途 |
|---|---|
| `tools/build_design_html.py` | Markdown → 自包含 HTML（无外部依赖，含目录） |
| `tools/build_design_docx.py` | Markdown → Word |
| `tools/diagnose_html_width.py` | 注入脚本让浏览器报告有没有元素超出视口宽度 |
| `tools/check_encoding.py` | 扫描文件是否被 PowerShell 重编码损坏 |

> **写中文文本文件时不要用 PowerShell 的 `Get-Content` / `Set-Content` 往返读写。**
> Windows PowerShell 5.1 的 `Get-Content` 按系统 ANSI 代码页读取，
> 再以 UTF-8 写回会产生乱码。本项目已踩过一次，`check_encoding.py` 就是为此加的。

## 功能概览

- **多孩子 Profile** —— 两个孩子的题目严格隔离（存储层过滤，不是界面层）
- **录入** —— 拍照 / 相册导入，自动切题 + 手动调整
- **待确认环节** —— 自动处理结果先进待确认列表，用户确认后才真正入库
- **题目清理** —— OCR 出文字重新排版；图形/公式裁剪保留，可选 AI 重绘
- **错题库** —— 列表、手动选择 / 多选 / 全选、按学科时间筛选
- **变式题** —— AI 生成同知识点、同年级难度的新题
- **一键打印** —— 排版后直接打印或导出 PDF

## 已确定的技术选型

| 项 | 选择 |
|---|---|
| 框架 | **Flutter**（Android，minSdk 26） |
| 状态管理 | Riverpod |
| 本地存储 | SQLite（drift）+ 图片文件 |
| 打印 | `pdf` + `printing` |
| OCR | **双引擎，设置里可选**：本地 PaddleOCR（离线、照片不出设备）/ 云端 API |
| AI | **DeepSeek** —— `deepseek-flash`（多模态，重绘图形/公式）+ 变式题生成 |
| SVG 渲染 | `flutter_svg` |

## 三个关键设计判断

1. **不做图像修复去笔迹**，改用**文本重建** —— 把印刷体 OCR 出来重新排版，
   结果必然干净；含图形/公式的区域保留原图，可选让 `deepseek-flash` 重绘成 SVG
2. **不做全自动** —— 自动切题和去笔迹都不可能 100% 准，所以加了「待确认」环节，
   用户确认后才入库，避免家长反复返工
3. **照片默认不出设备** —— 默认用本地 OCR；切到云端 OCR 时界面会明确提示
   照片会上传到第三方

## 开发计划

- **阶段一（MVP）**：Profile + 拍照 + 手动切题 + 本地 OCR + 待确认列表 + 打印
- **阶段二**：自动切题、AI 重绘、变式题、云端 OCR
- **阶段三**：复习计划、统计、模板、备份同步
