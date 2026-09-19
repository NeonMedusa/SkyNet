# SkyNet 开发文档

面向人类开发者的：架构速览、未来计划与开发注意事项。

**文档分工**：

| 文档 | 面向 | 内容 |
|---|---|---|
| [README](../README.md) | 用户 | 入口、免责声明、已知限制 |
| [docs/user-guide.md](user-guide.md) | 用户 | 配置与指令手册 |
| [AGENTS.md](../AGENTS.md) | AI 代理 / 自动化 | 构建测试流程、mock、**契约详情** |
| [docs/zigtui-pr-plan.md](zigtui-pr-plan.md) | 维护者 | zigtui 上游 PR 专项计划 |
| 本文 | 开发者 | 架构、路线图、踩坑与设计决策 |

---

## 1. 架构速览

### 1.1 模块地图

| 模块 | 职责 |
|---|---|
| `src/main.zig` | TUI 绘制/事件、CLI 子命令、agent worker 调度、压缩调度、`AppState` |
| `src/ai.zig` | SSE 流式请求与解析、工具调用分片累积、usage 解析、错误分类、请求体构建 |
| `src/tools.zig` | 7 个工具（read/write/edit/bash/grep/find/ls）、输出截断与临时文件 |
| `src/db.zig` | SQLite（fridge）schema/迁移/读写、折叠全文（`tool_full`） |
| `src/context.zig` | token 估算、折叠扫描器、压缩区间选择与摘要输入构建（纯计算，易单测） |
| `src/textarea.zig` | 多行输入框组件（折行/视口/选区/光标渲染） |
| `src/markdown.zig` | 迷你 markdown 解析与按行渲染 |
| `src/regex.zig` | grep 用迷你正则 |
| `src/config.zig` | `config.json`（providers / options / width_overrides） |
| `src/cli_args.zig` | CLI 参数解析（无 `AppState` 依赖） |
| `src/log.zig` | 文件日志（模块标签 + 级别过滤，见 AGENTS"其他约定"） |
| `libs/zigtui` | TUI 库（fork 的 `skynet` 分支，git submodule） |
| `libs/fridge-main` | SQLite 绑定 |

### 1.2 一次对话的数据流

```
用户回车
 └─ askAI：user 消息入 history(+落库) → createStreamJob（history 深拷贝进 arena）
     └─ worker 线程 streamWorker 循环：
          注入排队消息 → 按需压缩 → streamMessage(SSE)
            ├─ 增量文本 → stream_buf/事件队列 → 主线程 pumpStream 消费并渲染
            ├─ 工具调用 → 顺序执行 → 结果入 history + 实时落库
            └─ 无工具调用 → 本轮结束
     └─ 主线程 finalizeStream：转录补落库 → 折叠旧工具输出 → 更新 usage 锚点
```

**两套数据的边界（重要）**：显示层 `AppState.messages`（含思考块/工具块等渲染态）与
模型历史 `AppState.history`（API 消息格式）是**独立两套**，只在 finalize、排队注入、
落库/恢复处汇合。改任一路径时先想清楚另一路是否需要同步。

### 1.3 线程与并发

- **主线程**：`draw → 排空终端事件` 循环，每轮顺带 `pumpStream / pumpCompaction /
  pollExternalUpdates`；渲染与输入不阻塞。
- **worker 线程**（每回合一个）：SSE 请求 + 工具执行；与主线程通过 `stream_buf`
  （互斥缓冲）和 `stream_events`（有序事件队列）通信；`waitDrained` 保证"正文渲染完
  再进工具阶段"的次序。
- **压缩线程**（`/compact` 或自动）：摘要流式产出，主线程渲染；`compact_status`
  0/1/2 状态机收尾。
- **数据库**：主线程与 worker 各持一条连接（WAL + `busy_timeout`）；其他进程的外部
  写入靠 `last_seen_msg_id` 增量轮询（约 500ms）。

### 1.4 渲染管线

```
drawFrame → Buffer（双缓冲，逐格 diff）
Terminal.flush → 仅输出变化单元格（SGR 合并）→ 同步输出块（DEC 2026）
             → 帧尾光标定位（pending_cursor，IME 定位用）
```

每帧终端只渲染一次；长会话的行数统计走 `messageRowCountCached`（见 3.2 契约）。

### 1.5 持久化

- `message` 表存**全部原文**（含 reasoning、tool_full）；工具输出折叠只改发给模型的
  history（stub），DB 原文保留，重启后 UI 完整。
- `compaction` 表存 checkpoint（`summary_message_id` + `tail_start_id`）；恢复时按
  checkpoint 重建历史。schema 变更可能**删表重建**（破坏性，已在 README 声明）。

---

## 2. 未来计划（路线图）

### 2.1 渲染性能（续）

行数缓存（`messageRowCountCached` + 绘制整条跳过）已落地：每帧成本从
O(全会话字符数) 降为 O(消息数)（3000 条实测 5.7ms → 0.44ms，Debug 构建）。
以下为可按需启用的后续方案：

- **B 底部锚定窗口**（~50-100 行，中低风险）——`drawMessages` 改为从最后一条
  **反向累计**行数，凑够"可视行数 + scroll_offset"即停；`total_lines` 的既有用途
  （offset 钳制、▲▼ 指示）改用"回走是否仍有剩余"判断。边角：视口从消息中间开始、
  offset 钳制语义。效果：每帧降为 O(视口内消息数)。**触发时机**：会话上万条仍嫌卡。
- **C 窗口化/懒加载**（几百行，高风险）——只保留最近 N 条显示消息，滚到顶再分页拉。
  触及：加载路径（全量 markdown 解析）、DB 分页查询、scroll offset 锚定语义、
  选择映射对未加载区域的行为、压缩重建、外部轮询交互。**触发时机**：打开会话明显
  变慢或内存吃紧（当前 3300 条约 0.3s 加载，尚可）。
- **单条超长消息增量计行**（理论缺口）——流式追加时对整条重扫；单条几万行时才会
  有感。思路：维护"末行已用列数"的增量状态。**触发时机**：长输出流式变卡。

### 2.2 zigtui 上游协作

计划与工作流见 [docs/zigtui-pr-plan.md](zigtui-pr-plan.md)。当前状态：

- PR-1 `utf8-tolerance`、PR-2 `windows-restore`：已推送 fork，待开上游 PR；
- 新候选（本仓库新增的两个独立 commit，属通用光标能力，适合单独提）：
  **pending cursor 帧尾定位**（修 IME 候选窗闪烁）与 **DECSCUSR 光标形状**；
- 后续：bracketed paste（POSIX 接线）、Windows VT 输入（先 issue 探路）、
  模糊宽度（先 issue 探路）。skip：`width_overrides` 名单等应用层 curation 留 fork。

### 2.3 待修与已知问题

| 问题 | 影响 | 思路/状态 |
|---|---|---|
| 表单输入框中英输入法：组合串显示在主输入框光标处 | 低（表单少用中文） | 需要把光标定位扩展为"当前焦点控件" |
| 半开连接无读超时（对端不回 FIN 也不发数据） | 低概率挂起；退出时 `join` 可能卡 | std 无 body 读超时接口；TCP keepalive 兜底，接受现状 |
| 折叠/压缩/缓存亲和仅"尽量做了"（README 已声明） | 有效性未知 | 如需实测：日志里的缓存命中与 `/context` 折叠模拟已可支撑 |
| 提供商预设（18 家）未实测 | 按需 | 用户驱动，仅 opencode-go + deepseek-v4.1-flash 验证过 |
| macOS / Linux 未验证 | 按需 | 真光标/IME/路径/进程句柄等跨平台项待排查 |
| schema 破坏性升级（删表重建） | 数据丢失 | 已在 README 强调；如需无损需逐版本写迁移 |
| `skynet` fork 分支 `restore.arm` 快照时机（Windows panic 还原 raw 模式） | 低 | PR-2 已修，合并后 rebase 自动吸收（见 pr-plan"fork 遗留问题"）|

### 2.4 搁置的实验（存档）

- **断流"续思交接"**：重试时不重发原请求，而是把已产出的部分思考注入为提示，让模型
  从中断处继续。**搁置原因**：无先例；模型可能无视"继续"指示而重头思考（反而更贵）。
  **重启条件**：长思考断流频繁且重试成本成痛点时，先做手动版（如 `/retry continue`）
  对照实测。注：协议不支持真正的"续传"（reasoning 不能回传），整请求重发是唯一正解。
- **自动重试退避参数**：当前 2 次 / 2s、4s ±25%；如遇网关长时间抖动可调大 `stream_retry_max`。

---

## 3. 开发注意事项

### 3.1 工具链陷阱（实战积累）

1. **全角/弯引号等 lookalike 字符**：中文文本里"显示相同、字节不同"的引号/标点会让
   `edit` 的精确匹配失败（已踩坑）。编辑中文文档时：先从 `read` 复制原文作为匹配串，
   或写临时脚本做替换 + 字节级校验。
2. **Zig 0.16 格式化坑**：`{d:0>3}` 对**有符号**整数会产出 `+498` 式结果——先转无符号；
   没有 `std.time.Timer`，用 `std.Io.Timestamp.now(io, .awake)`。
3. **本版 Zig 测试运行器不支持 `--test-filter`**（会 panic）：跑全量 + 输出过滤。
4. **连接被拒的 std 诊断噪音**：见 AGENTS"其他约定"——是噪音不是崩溃，勿追查；
   真正要防的是 mock 被强杀后 `test/mock_*.running` 标记残留。
5. **PowerShell 传参脆弱**：多行 Python/嵌套引号经 `-Command` 极易损坏——写
   `.py`/`.ps1` 临时文件执行，用完即删（别留在仓库）。
6. **清理进程要排除自身**：`Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match "mock_" }`，
   命令文本本身含关键字会误杀当前 shell。
7. **联网查证用 firecrawl**（本机已认证）：`firecrawl search "..." --limit 5`。
   不确定的 API/平台行为优先查官方文档或 issue，而非猜测。
8. **git 小知识**：Windows 下 `LF will be replaced by CRLF` 警告正常（仓库存 LF）；
   提交前 `zig fmt`。
9. **ConPTY 输入记录携带的是 UTF-16 码元，不是原始字节**（误判曾导致两个真实 bug，
   2026-09 修复）：conhost 的 `VtInputThread` 会先把伪控制台收到的 VT 流按 UTF-8
   解码为 UTF-16 再写入输入记录（上游源码核实）。因此 `ReadConsoleInputW` 拿到的
   `UnicodeChar` 应按码点语义处理：ASCII 码元值与字节相同可直接透传；**其余一律
   走 UTF-8 编码**（U+0080–U+00FF 也**不能**当原始字节透传，否则单字节不成序列会被
   静默丢弃）；**非 BMP 字符（emoji 等）以"前导+后继"两条记录到达**，需缓存前导
   再合并（与微软 `terminalInput.cpp` 的 `_leadingSurrogate` 同逻辑）。修复与测试见
   `libs/zigtui/src/backend/windows.zig` 的 `codeUnitToUtf8`。

### 3.2 必须遵守的契约（摘要，详情在 AGENTS.md）

| 契约 | 一句话 | 违反后果 |
|---|---|---|
| 消息行数缓存 | 改正文走 `msg.setContent`；新增可变字段并入缓存键 | 长会话卡顿/滚动错位 |
| 输入法光标（5 条） | 真光标 + 帧尾定位 + 主输入框禁用方块光标 + DECSCUSR | IME 组合串漂移/闪烁 |
| 日志 | 排查问题先看 `logs/` 最新文件 | 无从定位线上问题 |
| submodule | 先提交/推送 zigtui，再提交主库指针 | 指针指向不存在的提交 |
| 测试聚合 | 新模块测试要在 `main.zig` 末尾 `_ = @import` | 测试不被收集 |

### 3.3 设计决策速记（为什么这么做）

| 决策 | 理由 |
|---|---|
| worker 线程 + 事件队列 | UI 不阻塞于网络/工具；队列保序（正文先于工具） |
| 实时落库 + finalize 快路径 | 崩溃安全；finalize 只补未落库条目（`worker_persisted_max` 同步游标） |
| 折叠只改 history | DB 原文保留（`tool_full`）→ 重启 UI 完整；请求前缀变小 |
| usage 锚点（真实 + 增量） | bytes/4 对中文低估约 35%；压缩/清史/重建立即失效防误配 |
| 双缓冲 + 同步输出 + 帧尾光标 | 每帧一次渲染（防闪烁）；IME 定位与帧同字节流（防跳变） |
| 显示/历史两套数据 | 渲染态（思考块/工具块/展开）与 API 格式解耦 |

---

*维护提示：本文的路线图部分应随实现推进更新（完成的移入相应章节或删除）；踩坑经验
请直接追加到 3.1，注明触发场景。*
