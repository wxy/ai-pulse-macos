# 内联双语串收敛计划（zh/en 双轨 → String Catalog）

2026-09-27 立项。**现状**：xcstrings 是唯一事实源（742 键 × 10 语言），但仪表盘/设置/多端 UI 存在大量内联中英双语串——`pulseText(zh, en)`、`SetupCopy.text(zh, en)`、`WidgetCopy.text(zh, en)`、`I18n.prototype(zh, en)` 及 Suites 侧 `t(zh, en)`。这些串只服务中文与英文用户；**日、韩、德、法、西、葡用户在这些位置看到英文回退**。这是"十语言完成度"的最大缺口。

## 第一步已落地：校验脚本覆盖内联串（本提交）

`scripts/check-localizations.py` 现在扫描 `Sources/`、`Suites/`、`AIPulse/AIPulseMacWidget` 中的内联双语对（一行内"中文字面量" + ", " + "字面量"的调用形态），并强制两条不变量：

- en 回退不得为空；
- en 不得与 zh 字面量相同（防止复制粘贴成对失真）。

当前清点：**415 对 / 19 个文件**。前三名：`Sources/UI/Dashboard/DashboardView.swift`（65）、`Suites/iOS/UI/DashboardView.swift`（60）、`Suites/iOS/UI/PhoneSettingsView.swift`（46）。

重新生成迁移工作清单：

```sh
python3 scripts/check-localizations.py --dump-inline /tmp/inline-inventory.json
```

已知边界：逐行扫描**不覆盖跨行调用**（需要真正的 Swift 语法解析才能避免误配对）；跨行串会在逐文件迁移时一并捕获。

## 后续批次（未排期，逐文件推进）

1. **按文件迁移**：每次迁移一个 UI 文件——内联对改为 xcstrings 键 + 十语言翻译；迁移完成的文件加入脚本的禁用清单（该文件再出现内联对即校验失败），防止回潮。
2. **翻译质量门槛**：新增键的 ja/ko/de/fr/es/pt-BR 五语翻译须人工复核后才能标 `translated`；机器草稿可作起点，不直接落 `translated` 状态。
3. **顺序建议**：从 `DataAndSyncTab`（39 对，本轮已新增多个 SetupCopy 串）与 `OnboardingView`（19 对，新用户第一印象）起步；`DashboardView` 的 65 对涉及大量图表语义文案，放最后单独一批并走视觉验收。
4. **不做**：不为内联串生成运行时翻译（Hans→Hant 变换、en 回退维持现状）；不改变"中文界面中国区可见性"策略。

## 与 ten-language 宣传口径的关系

在收敛完成前，对外文案与 README 的"十种界面语言"表述应理解为"xcstrings 覆盖十语言；辅助性内联文案当前为中英双语"。迁移完成后此注记删除。
