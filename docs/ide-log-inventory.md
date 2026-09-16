# C 级 IDE 本地数据盘点（P0 遗留闭环）

> 2026-09-12 · 在本机实测（macOS 26 / Cursor + VS Code + Copilot Chat 已安装，Windsurf 未安装）
> 结论：**C 级 IDE 的本地数据"存在但不可稳定解析"——维持 §4.5 兜底链现状（WI-5 归因兜底 + 盲区标注），不做 state.vscdb 解析。**

## 结论矩阵（可采清单 + 盲区清单）

| 工具 | 本地数据 | 可采性 | 结论 |
|---|---|---|---|
| Claude Code / Codex / aider / OpenCode / Qwen Code | 明文 JSONL 日志 | ✅ 已采集（A 级） | 维持 |
| DeepSeek Harness | `~/.dsh/sessions/**/session*.jsonl.zstd`（zstd JSONL） | ✅ 已采集；v3 格式 2026-09-12 起支持（同名前缀匹配 + 双载体 usage 解析） | 维持 |
| **Cursor** | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`（SQLite：`ItemTable` / `composerHeaders` / `cursorDiskKV`） | ⚠️ **盲区**：用量在 `cursorDiskKV` 的 `agentKv:blob:*` 不透明二进制键下（压缩/私有格式，跨版本易碎） | **不解析**；燃烧感知走 WI-5 归因（`code_change` + EditorDetector） |
| **GitHub Copilot / Copilot Chat** | `~/Library/Application Support/Code/User/workspaceStorage/<hash>/GitHub.copilot-chat/`（按工作区分散，无统一账本；本机 4+ 处） | ⚠️ **盲区**：无稳定 token/计费记录，目录结构随扩展版本漂移 | **不解析**；同上走归因兜底 |
| **Windsurf** | 未安装（本机无从验证；公开资料与 Cursor 同构） | ⚠️ 假定盲区 | 同上 |
| 余额可查的 API（DeepSeek/Kimi/智谱等） | 服务端余额 | ✅ B 级快照差值（exact） | 机会性增强（§4.1） |

## 决策依据（r6 边界决策的延伸）

1. 花费**提醒**以客户端已存在的可观测数据为基础：日志 token（A 级）、余额差值（B 级）、AI 归因代码变化（WI-5）。三者已覆盖"火焰有反应"的全部需求。
2. 精确金额是锦上添花：Cursor/Copilot 本身不暴露稳定计费数据，解析不透明 blob = 高维护成本 + 高碎裂风险 + 诚实性存疑（读不出就编不出），违背 §4.6"归因不到 = 不计量"。
3. 套餐月费（如 GLM Coding Plan）按 r6 决策不扩张登记面；用户需要金额时可手动登记（设置 → 集成）。

## 后续触发条件（何时重启此调查）

- Cursor 官方暴露稳定的本地用量表（非 blob），或
- 用户实测发现 `composerHeaders` 里有稳定可用的 token/请求数（当前样本未证实），或
- 归因兜底的准确率不满足感知层需求（归因行数失真反馈）。
