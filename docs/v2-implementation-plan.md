# AI Pulse 2.0 实施入口

> 2026-09-19 · macOS、iPhone、iPhone 小组件、Watch 应用、Watch 小组件和 macOS 小组件均已完成实现，当前处于 2.0 发布收尾。尚未正式发布。

现行规则与状态：

- [产品设计](PRODUCT_DESIGN.md)：目标、展示、声音与跨端边界。
- [数据事实与展示出口](data-facts-and-surfaces.md)：来源语义与历史审计。
- [macOS 收口计划](macos-v2-closure-plan.md)：五阶段执行、门槛和逐轮证据。

旧“P0／P1／P2 已完成”只是历史工作项结论，不是当前达标依据。完整记录见 [历史计划](archive/v2-money-first-implementation-plan.md)，不用于当前验收，也不要求旧展示或传输兼容。

当前收尾以 `Sources/Localizable.xcstrings` 为唯一国际化事实源，完成 10 种语言、隐私清单、资源成员关系、CI、构建矩阵和发布文档审计。macOS、macOS 小组件、iPhone、iPhone 小组件、Watch 应用和 Watch 小组件均已完成真机验收。正式发布仍需完成最终构建、App Store 提交与审核，并在单独授权后公开 GitHub Release。
