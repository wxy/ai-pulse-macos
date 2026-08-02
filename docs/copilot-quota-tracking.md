# GitHub Copilot 用量追踪研究

> 状态：**暂缓实现**。用户担心提供 OAuth token 过于繁琐，是否实现待定。
> 日期：2026-08-02

## 结论

Copilot 的套餐/超量用量**只存在 GitHub 云端**，本地无缓存，必须通过 GitHub API + OAuth token 查询。token 在新版 VS Code 加密存储在 `Code Safe Storage`（Keychain），第三方 app 无法读取——因此 AI Pulse 需要用户**手动提供 GitHub OAuth token**。

## 数据源与机制

- **API**: `GET https://api.github.com/copilot_internal/user`（Bearer token 认证）
- **token 来源**: 用户从 GitHub Settings → Developer settings 生成 OAuth token，配置到 AI Pulse（存 Keychain）
- **新版 VS Code token 存储**: `Code Safe Storage`（Keychain 加密 blob），**不再使用**旧的 `copilot-auth.json`。AI Pulse 现有代码读 `copilot-auth.json` 已过时。

## API 返回字段（quota_snapshots.premium_interactions）

```json
"premium_interactions": {
  "entitlement": 300,          // 套餐内总配额（premium requests 数）
  "percent_remaining": 31.16,  // 套餐内剩余百分比
  "quota_remaining": 93.5,     // 套餐内剩余请求数
  "overage_count": 0,          // 套餐外用量（超量请求数）
  "overage_permitted": true,   // 是否允许超量（按量付费开关）
  "unlimited": false
}
```

顶层还有 `quota_reset_date`（下次重置的 ISO 时间戳）。

### 三个可查维度

| 数据 | 字段 | 含义 |
|------|------|------|
| 套餐内剩余 | `quota_remaining` / `percent_remaining` | 还剩多少 premium requests |
| 套餐外用量 | `overage_count` | 超出套餐的请求数 |
| 是否按量付费 | `overage_permitted` | true = 超量后自动按量计费 |

**限制**：API 返回 overage 请求**数量**，不含金额——需按 GitHub 单价（premium requests 超量约 $0.04/request，不同模型有倍数）自行估算费用。

## 对 AI Pulse 的意义

- **不提供 token**：按订阅套餐均摊（月费 ÷ 天），覆盖大多数场景（现状）
- **提供 token**：升级为精确——套餐内剩余 + 套餐外支出 + 重置日期

## 待办（若决定实现）

1. Settings 加"GitHub token"输入框，存 Keychain
2. `parseCopilotResponse` 已解析 `usedPercent`/`overageCount`，需补解析 `quota_remaining` + `quota_reset_date` + overage 费用估算
3. Dashboard 显示套餐内剩余 + 套餐外支出

## 相关代码

- `Sources/Engine/UsageMonitor.swift` — `refreshCopilotStatus()` / `copilotToken()`（读旧版 `copilot-auth.json`，需改为读用户配置的 token）
- `Sources/Store/Database.swift` — `quota_status` 表（tool_id="copilot"）
