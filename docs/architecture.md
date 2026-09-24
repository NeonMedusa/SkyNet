# SkyNet 架构导航（面向 AI 的代码地图）

> **本文档的目的**：让 AI（和新会话/压缩后的自己）**不必通读 2 万行代码**就能定位到
> 该看的函数。它不是 API 参考，而是"改 X 该看哪里"的索引。
>
> **约定**：全文**不含行号**（行号会漂移）——所有锚点都是**函数名/类型名**，
> 用 `grep` 精确定位即可（例如 `grep -n "fn streamWorker" src/main.zig`）。
>
> **维护契约（AI 必读）**：改代码后若"入口函数/职责/调用关系"发生变化，
> **必须回来更新本文档对应条目**（见 `AGENTS.md` 的同名约定）。文档过期比没有更糟。

## 0. 一页速览

| 我想做的事 | 先看这里 |
|---|---|
| 改 AI 请求/响应/SSE 解析 | `src/ai.zig`：`streamMessage`、`buildRequestBody`、`handleLine` |
| 改工具（read/write/edit/bash/grep/find/ls） | `src/tools.zig`：`tool_defs`（schema）、`executeWithEnv`（分发）、`toolXxx` |
| 改 TUI 渲染/布局 | `src/main.zig`：`drawFrame`（总入口）、`drawMessages`、`drawInput` |
| 改对话回合/工具循环 | `src/main.zig`：`streamWorker`（worker 主循环）、`pumpStream`（主线程消费） |
| 改上下文压缩 | `src/main.zig`：`compactJobHistory`（中途）、`compactionExecute`（手动/CLI）；`src/context.zig` 纯计算 |
| 改持久化/DB | `src/db.zig`（读写 + schema 迁移 `migrateIfNeeded`）、`src/db_query.zig`（查询脚手架） |
| 改系统提示词/工具 schema 组装 | `src/main.zig`：`system_prompt`、`tool_schemas` |
| 改 Markdown 渲染 | `src/markdown.zig`：`parse` → `md_mod.Line` 列表 → `drawRow` |
| 改配置/提供商 | `src/config.zig`（config.json）、`src/main.zig` 的菜单渲染（`drawModelSelect` 等） |

## 1. 模块职责

| 文件 | 规模 | 职责 | 关键入口 |
|---|---|---|---|
| `main.zig` | ~12k 行 | TUI 主程序 + 回合编排 + 压缩/折叠 + CLI 子命令 + 全部测试聚合 | `main`（含 TUI 主循环）、`streamWorker` |
| `tools.zig` | ~2.5k | 7 个工具的 schema + 实现（无 UI 依赖，纯函数式接口） | `tool_defs`、`executeWithEnv` |
| `ai.zig` | ~1.1k | HTTP/SSE 客户端、请求体构建、工具调用累积、重试 | `streamMessage`、`buildRequestBody` |
| `markdown.zig` | ~1.1k | Markdown → 行模型的解析与渲染（表格/列表/代码块） | `parse`、`drawRow` |
| `db.zig` | ~0.8k | SQLite 读写（消息、会话、压缩记录、FTS） | `insertMessage`、`loadMessages`、`latestCompaction` |
| `textarea.zig` | ~0.7k | 多行输入框（折行、选择、粘贴、光标） | `insertBytes`、`draw` |
| `config.zig` | ~0.7k | config.json 读写、提供商/预设/思考强度/宽度策略 | `load`、`behavior` |
| `context.zig` | ~0.4k | **纯计算**：压缩区间选择、工具输出折叠扫描、checkpoint 包装 | `selectCompactionRange`、`FoldScanner` |
| `regex.zig` | ~0.5k | 自研正则（grep 工具用，零依赖） | `parse`、`exec` |
| `log.zig` | ~0.3k | 日志（分文件、分级、保留清理） | `info`、`Log.info` |
| `cli_args.zig` | ~0.2k | CLI 参数解析与标准输出辅助 | `parseCliArgs` |
| `db_query.zig` | ~0.2k | drizzle 风格的查询构造辅助 | `queryAll1` |
| `utf8.zig` / `clipboard.zig` | 小 | UTF-8 工具、Windows 剪贴板 | `nextLen`、`setText` |

## 2. main.zig 分区地图（144 个顶层函数）

`main.zig` 内部用 `// ── 分区名 ──` 注释分段（`grep "^// ──" src/main.zig` 可列出）。
按代码顺序：

### 2.1 基础工具与常量（文件开头）
`Mode`（TUI 模式枚举）、`Message`（显示消息）、`AppState`（**全局状态，最重要**）、
`StreamJob`（worker 独占的回合快照）、`system_prompt`、`tool_schemas`、
`busy_accent`（压缩/进行中强调色）、`spinnerFrame`、`inputBoxTitle`。

### 2.2 回合编排（核心）
- **发起**：`askAI`（主线程入口：落库 user 消息 → 建 job → 起 worker 线程）
- **worker 独占**：`streamWorker`（**工具循环主体**：注入排队消息 → 检查压缩 → 请求 → 执行工具 → 循环）
- **增量回调**：`onStreamDelta`（worker → 缓冲）、`waitDrained`（背压）
- **落库**：`persistTranscriptEntry`（实时落库 + 回填 db_id）、`persistMessage`
- **主线程消费**：`pumpStream`（内容/事件 → 显示）、`finalizeStream`（回合收尾：
  锚点、usage、重试提示、取消处理）、`closeCurrentTurn`
- **工具执行**：`execute` / `executeWithEnv`（在 `tools.zig`，含工作目录与超时）

### 2.3 压缩（compaction）
- **中途（worker 线程、工具轮间隙）**：`compactJobHistory`（含排队压缩 `force` 语义）
- **手动/CLI（异步 worker）**：`startCompaction` → `compactionWorker` → `compactionExecute`
- **流式显示（主线程）**：`pumpCompaction`、`appendCompactChunk`、`appendCompactReasoning`、
  `finalizeCompaction`、`finishMidCompactDisplay`、`resetCompactStreamState`
- **纯计算**：`src/context.zig` 的 `selectCompactionRange`、`buildCompactionPayload`、
  `wrapCheckpoint`/`checkpointBody`（固定包装的构造与剥离）
- **加载显示**：`applyLoadedMessagesWithCheckpoint`（摘要行就地渲染）

### 2.4 持久化与窗口化
- **加载**：`loadSessionContent`、`rebuildHistoryFromDb`、`applyLoadedMessages*`、
  `addLoadedAssistantMessage`、`addLoadedToolDisplay`（重启后重建显示）
- **窗口化（长会话渲染性能）**：`updateMessageWindow`、`unloadMessage`、`reloadMessage`、
  `messageRowCountCached`（**改 `Message` 可变字段要同步缓存键**，见 AGENTS.md 契约）

### 2.5 折叠（工具输出控制，仅面向 AI）
`maybeFoldOldToolOutputs`；纯逻辑在 `context.zig` 的 `FoldScanner`。
**DB 的 `content` 始终是全文**（导出/UI 用），`folded` 列记录已折；发给模型前换成
stub（实时折叠在 `maybeFoldOldToolOutputs`，重启重建在 `applyLoadedMessagesWithCheckpoint`）。

### 2.6 渲染
- **总入口**：`drawFrame`（每帧：消息区 → 输入框 → 状态栏 → 浮层 → toast）
- **消息区**：`drawMessages`、`messageRowCount`、`recordMdRow`/`recordPlainRow`（**行记录契约**）
- **消息块**：`drawToolBlockRow`（bash/edit 块）、`drawThoughtHeader`（思考块）、`recordThoughtRow`
- **输入框**：`drawInput`、`inputCursorScreenPos`（IME 锚点）、`drawInputStatus`
- **状态栏**：`drawStatusSegment`、`cacheHitPercent`、`contextUsagePercent`
- **浮层/菜单**：`drawOverlayMenu` + 每个菜单一个 `drawXxxSelect` 与 `drawXxxConfirmDialog`
  （实际函数名以 `grep "fn draw" src/main.zig` 为准）
- **文本选择**：`extractSelectionText`、`rowSegmentsLive`、`pointInRow`、`recordMessage`

### 2.7 启动与 CLI（无界面路径）
- **启动闸门**（schema 版本不符）：`runStartupGate`、`runVersionGate`、`drawGateFrame`
- **CLI 子命令**（复用同一套 agent 逻辑）：`cmdAsk`、`cmdCompact`、`cmdStats`、
  `cmdSessions`、`cmdMessages`、`cmdNew`；参数 `cli_args.zig`；入口 `runCli`、`main`
- **TUI 主循环**：在 `main` 内（初始化终端 → 事件循环 `handleTerminalEvent` +
  `drawFrame` → 退出清理），无单独函数

### 2.8 测试
- 文件末尾是**聚合块**：`_ = @import("ai.zig")` 等（新增模块**必须在此登记**，否则测试不被收集）
- 交互式集成测试用 `testIo()`/`gateBufferText` 等辅助；mock 端口映射见 `AGENTS.md`

## 3. 关键数据流

### 3.1 一次对话
```
用户回车 → askAI
   ├─ 落库 user 消息（persistMessage）+ 追加 history
   ├─ createStreamJob（快照 provider/model/history 深拷贝到 job.arena）
   └─ spawn streamWorker
        └─ 循环：injectPendingSends → compactJobHistory(阈值/排队) → ai.streamMessage
              ├─ onStreamDelta 写缓冲 → 主线程 pumpStream 渲染
              └─ 有 tool_call → 执行工具 → 结果落库 → 下一轮
   └─ 回合结束：finalizeStream（主线程）→ 锚点/usage/排队消息处理
```

### 3.2 上下文压缩
```
触发（三处）：
  ① 工具轮间隙（worker）: compactJobHistory(force=false 阈值 / force=true 手动排队)
  ② 空闲自动（主线程）: maybeAutoCompact → runCompaction（同步）
  ③ 手动/CLI: startCompaction → compactionWorker（异步）
执行：选区间（context.selectCompactionRange）→ 摘要请求（独立 system prompt，不写缓存）
   → role='summary' 消息落库（含 reasoning）→ compaction 记录 → 重建 job.history
   = [system, checkpoint(摘要), 保留区…]
显示：流式渲染（橙标题 + 思考块 + 正文），摘要按生成位置就地显示（重启后位置不变）
```

### 3.3 历史重建（重启/切换会话）
```
loadSessionContent
   ├─ loadMessages + latestCompaction + listCompactions
   ├─ 历史 = [system(当前提示词)] + [checkpoint 伪消息] + [保留区]
   └─ 显示 = 全部消息（含被压缩区）+ 摘要行就地渲染（不进历史）
```

## 4. 改动的连带影响（改前必看）

| 改动 | 连带必须改 |
|---|---|
| `Message` 新增"创建后可变且影响行数"字段 | 并入 `messageRowCountCached` 的匹配键（见 AGENTS.md 契约） |
| 改正文内容 | 必须走 `msg.setContent(allocator, owned)`（否则行数缓存不失效） |
| 新增工具 | `tools.zig` 的 `tool_defs` + `toolBlockKind`（是否块渲染）+ 提示词里的工具说明 |
| 改工具结果格式 | `summarizeToolResult`（统计行）、`addLoadedToolDisplay`（重启恢复）要同步 |
| 改落库字段 | `db.zig` 的列定义 + `db_query` 映射 + `applyLoadedMessages*` + 窗口化重载 |
| 改 schema（加列/表） | `schema_version` +1、在 `migrations` 表里加一步迁移函数、同步 `migration_min_version`（若放弃最旧版本支持）；旧库迁移走 `migrateIfNeeded`（自动备份 + 逐级升级） |
| 新增模块 | 在 `main.zig` 末尾聚合块 `_ = @import("xxx.zig")` 登记 |
| 改压缩显示/文案 | `formatCompactionNotice`（多处共用：手动收尾/间隙收尾/重启加载） |
| 改 fork/子进程 | `clipboard.zig`、`tools.zig` 的 bash 临时目录与清理 |
| 改强调色/视觉 | `busy_accent`（输入框压缩中边框、压缩标题、确认框共用一处常量） |

## 5. 测试地图

| 测试 | 位置 | 需要 mock |
|---|---|---|
| 单元测试（无 IO） | 各文件 `test "..."` | — |
| 工具循环集成 | `main.zig`（`streamWorker` 相关测试） | 18123 |
| gzip 错误体 / 截断重试 / 500 重试 | `main.zig` | 18124 / 18126 / 18127 |
| 压缩（手动/中途/排队） | `main.zig`（`compactJobHistory` 相关测试） | 18125 |
| 渲染/布局（Buffer 级） | `main.zig`（`drawXxx` 测试） | — |
| mock 脚本与端口约定 | `AGENTS.md` | — |

## 6. 约定与陷阱（详见 AGENTS.md）

- 提示词（`system_prompt`）与工具 schema 是**程序的一部分**（政策 A）：改版即生效，DB 不存旧值；
- 临时脚本一律写 `tmp/`（已 gitignore）；正式回归用单元测试；
- 压缩"排队"语义：生成中 `/compact` 排队到工具轮间隙（与自动压缩同函数），轮尾兜底补执行；
- 未启动 mock 时相关测试自动 skip；跑测试前删 `test/mock_*.running` 避免噪音。
