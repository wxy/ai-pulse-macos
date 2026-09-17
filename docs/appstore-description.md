# App Store description — macOS 2.0 draft

> 2026-09-17 · 未发布草案，不能作为功能已完整验收的证明。macOS 运行和用户体验验收完成后再定稿、上传。其他客户端暂停，本稿不承诺跨端可用或通用购买。

## English

AI Pulse gives your AI use a pulse: notice ongoing consumption, changes in activity, and the local work alongside it. It is not a bill, a precise meter, or a judgment of whether your output was worth the cost.

The robot-shaped dashboard brings together separate signals without turning them into a made-up dollar total:

- Today, this week, and 30 days: captured tokens, sessions, tool/model breakdowns, and repository activity.
- Opposing rhythms for token activity and code changes, using the same local time slots.
- Local Git line changes and commits as companion output—not proof of AI authorship or monetary value.
- Account balance decreases shown in their original currency when observed, with sampling intervals. They are not individual request charges.
- Fresh quota observations where available. Missing or stale observations are not treated as zero activity.
- Declared monthly subscriptions kept separate from API observations, never spread into a daily bill.

Open tool details to explore captured sessions and context observations. The menu and Dock provide a lightweight view of the current pulse. Consumption cues, startup and closing chimes have separate controls, previews, quiet hours, and one-tap mute. Refreshing data alone is not a new consumption event.

Supported signals depend on your tools, log fields, account access, folder permissions, and available provider responses. Choose development directories to limit Git monitoring to real repositories within those directories. This does not reconstruct every activity or payment in an AI account.

Local logs are parsed on your Mac. Configured provider requests connect to those services. When enabled, private iCloud sync sends derived summaries, including repository paths; API keys are not included in these payloads. Local parsing does not mean that no data ever leaves the device.

## 简体中文

AI Pulse 让 AI 使用像脉搏一样可感：知道自己持续在消费，活动强度正在变化，并看见伴随的本地成果。它不是账单、精确计量器，也不判断产出是否“值回成本”。

机器人形仪表盘将不同信号并列呈现，不拼凑虚构的美元总额：

- 今日、本周与 30 天：已捕获的词元、会话、工具模型分布及仓库活动。
- 词元活动与代码变化的相向节奏，使用相同的本地时间槽位。
- 本地 Git 增减行与提交作为伴随成果，不证明 AI 作者归属，也不折算价值。
- 有观测时按原币显示余额区间净下降及采样区间，不伪装成逐请求扣费。
- 有来源时展示新鲜额度观察；缺失或过期不等于没有活动。
- 声明月费与 API 观察分开，不摊成每日账单。

明确的工具详情入口帮助查看已捕获会话及上下文观察。菜单与程序坞轻量呈现当前脉搏。消费提示、启动钟声和收盘钟声有独立控制、试听、静音时段及一键静音；数据刷新本身不会当作新消费。

可见数据取决于工具、日志字段、账户访问、目录授权及供应商可用响应。选择开发目录后，只监控其中真实 Git 仓库；不承诺重建账户的全部活动或付款。

本地日志在 Mac 上解析。已配置的服务商请求会连接对应服务；启用私有 iCloud 同步时，会发送派生摘要，包括仓库路径，但不包含 API 密钥。本地解析不代表任何数据都不出设备。

## 发布前门槛

以 [收口计划](macos-v2-closure-plan.md)、[数据事实](data-facts-and-surfaces.md) 和 [运行证据](macos-runtime-qa-2026-09-17.md) 核对最终功能。当前草案中的设计描述必须通过真实采集、声音、权限、长时间运行及用户验收后才能成为发布承诺。旧稿见 [历史版本](archive/appstore-description-v1.md)。
