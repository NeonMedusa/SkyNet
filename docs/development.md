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
| `src/db.zig` | SQLite（fridge）schema/读写、折叠全文（`tool_full`） |
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
  checkpoint 重建历史。schema 版本不符时**拒绝打开**（不迁移、不重建、不写入——全部迁移
  代码 2026-09 已清空；数据库升级迁移模块将来专门设计）。TUI 另有启动闸门：旧库经用户
  确认后重命名为备份（`skynet.old.db`，含侧车、冲突编号、失败回滚）并新建空库继续；
  库比程序新则提示升级后退出——**任何路径都不自动迁移、不删除、不写入旧库**。

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
| schema 版本不符 | 拒绝打开（不迁移、不重建）；TUI 弹窗让用户选"重命名旧库并新建"/"退出" | 2026-09 清空全部迁移代码（无外部用户）；专门的迁移模块待将来设计；重命名=文件搬迁，数据零改动 |
| `skynet` fork 分支 `restore.arm` 快照时机（Windows panic 还原 raw 模式） | 低 | PR-2 已修，合并后 rebase 自动吸收（见 pr-plan"fork 遗留问题"）|
| 窗口化重载后的工具结果摘要可能显示折叠后（stub）的长度 | 低（仅影响摘要括号里的数字） | `summarizeToolResult` 目前用 `content` 长度；重载路径应优先用 `tool_full` 长度。待 review |

### 2.4 搁置的实验（存档）

- **断流"续思交接"**：重试时不重发原请求，而是把已产出的部分思考注入为提示，让模型
  从中断处继续。**搁置原因**：无先例；模型可能无视"继续"指示而重头思考（反而更贵）。
  **重启条件**：长思考断流频繁且重试成本成痛点时，先做手动版（如 `/retry continue`）
  对照实测。注：协议不支持真正的"续传"（reasoning 不能回传），整请求重发是唯一正解。
- **自动重试退避参数**：当前 2 次 / 2s、4s ±25%；如遇网关长时间抖动可调大 `stream_retry_max`。

### 2.5 设计讨论（存档）：会话跨目录、/cd 与提示词系统

> 状态：**讨论稿，未实现；当前决策：不做**。若将来（顶不住压力/需求出现）要引入
> 目录级提示词、`/cd` 或"会话记忆 cwd"，从本节重启讨论。

**决策记录（重要，先读这个）**：

- **不做提示词系统**：不加载目录/项目级提示词文件、不做 system/项目/会话提示词的
  开与关、不做"覆盖还是追加"、不做预设模板菜单。
- **理由（作者立场，供未来被质疑时回看）**：① 配置项膨胀——这些开关"又臭又长"，
  维护与文档成本远超收益；② 现代 AI 足够聪明，不需要靠堆提示词来"教"它工作；
  ③ 提示词每轮随请求发送，白占上下文、浪费 token（还可能挤掉有用的历史）；
  ④ **工具自取胜过每轮复读**：AI 会自己用工具去读 AGENTS.md / README.md，读一遍就
  在上下文里记住了——不需要系统提示词每轮把同样的内容当复读机再念一遍。
  （推论：文档类内容的正确形态是"存在且可被发现"，不是"被注入"；若担心 AI 不知道
  去读，一条一次性的轻提示足矣，也不必每轮重发全文。）
- **提示词策略（2026-09 定案）：政策A"提示词属于程序"**——曾经启动"零提示词实验"，
  当时**搁置**（非因实验本身不佳）：彼时"提示词是否/如何落库"尚未定案，而
  **"给服务端传空串 `''` 还是什么都不传"无法在库中记录与区分**（对模型两者等价——
  空串 tokenize 为 0 token；但对"每轮提示词审计"的语义不同），先退回原状待定案。
  政策A 定案"不落库"后此阻塞已消失，**实验可随时重做**（做法：`src/main.zig` 顶部
  const 置空即可；发送侧传空串与不传等价，无需在协议层区分）。最终语义：
  ① 发送永远是源码中的最新值（随版本升级，全局一套；不做每会话/每项目配置）；
  ② **DB 不含 system 行**（写入侧从不产生，读取侧无兼容分支——旧库数据 2026-09 已全部
  清除；打开会话是纯读操作，`updateMessageContent` 这类"静默改写历史"的 API 已删除）；
  ③ 加载/重建时统一前置当前值一次（`applyLoadedMessagesWithCheckpoint` 的
  `prepend_system` 参数；增量轮询传 false，勿重复前置）；
  ④ 改提示词只影响之后的请求（老会话同样用新文；代价是该会话前缀一次性重算，之后
  重新命中——低频操作，可接受）；
  ⑤ 审计（"每轮到底发了哪版"）为将来可选项：届时以 append-only 的"变更点记录"实现
  （变更时插入一条，不复制全文）。
- **服务端机制佐证（2026-09 网络调研）**：① 协议无状态——提示词确实每轮随请求完整发送
  （OpenAI 文档：缓存的是"整个渲染后的前缀"，含 developer messages / tool definitions）；
  ② 计算侧被前缀缓存缓解——KV 状态在整个前缀逐字节匹配时按约 0.1× 计费复用（GPT-5.6+
  写入 1.25×、读取 0.1×；前缀中改一个字节则断点之后全部 miss；最小缓存门槛 1024 tokens）；
  ③ 但即使命中，提示词仍**占上下文窗口**，且 decode 阶段每个生成 token 都要对全部历史
  KV 做注意力（内存带宽成本）。故"能省则省"的立场在窗口与解码维度成立；字节层"复读"在
  缓存命中时已近乎免费（跨会话共享同一 system 时甚至全局共享命中）。
- **业界实现对照（2026-09 源码调研：pi / opencode 仓库）**：两者均**不把人设提示词落库**——
  pi 运行时把"当前 systemPrompt"补为首条消息（甚至可按轮动态求值），opencode 在请求组装时
  拼入（提示词模板按模型选择）；续聊/恢复一律取当前值。唯一落库的 system 内容是**环境类
  上下文**：opencode 的 SystemContext（cwd/日期/技能清单）以 `baseline`+快照+"世代"存库、
  压缩时换代；pi 每轮重发、不落库。即"程序拥有的是人设提示词，环境属于会话数据"这条边界
  与业界主流一致；opencode 的 epoch 机制可作下方"会话记忆环境"（方案 C）的参考实现。
- 本节其余内容 = "如果哪天要做"的完整设计存档（含争议点与备选方案），避免将来
  从零头脑风暴。

**`/cd` 指令设计（若做）**：切换当前工作目录，切换后需同时完成三件事：
1. **告知 AI 新位置**（system 或注入一条简短环境说明）；
2. **加载新目录的提示词文件**（若同时也做了提示词系统）；
3. **工具的工作目录切过去**（`job.cwd` 用新目录，工具/搜索/命令全部生效）。

争议点与备选解决方案（**作者已表态否决"配置项"路线，此处仅存档**）：
- *要不要记录上次 cd 到的目录？*（会话重开时恢复到哪）——备选：`session` 表存
  `last_cwd`，或只在内存中有效（重开回到进程 cwd）；
- *恢复会话时要不要自动 cd 过去？*——备选：自动 / 提示确认 / 不自动；
- 被否决的统一解法：**加配置项让用户自选**（如 `cd_policy: remember|current|ask`）。
  否决理由见上"决策记录"：这不值得为它新增配置面。

**问题背景**：SkyNet 的会话可在**任意目录**打开（设计动机：随手开终端 → 选会话 → 开聊，
零门槛）。但若将来支持"从工作目录向上加载项目提示词"，同一会话在不同目录打开会
得到不同的 system → 环境描述与历史事实矛盾，模型可能困惑。对照：pi/opencode 均
"会话自带 cwd"（pi 存会话文件头部 `cwd`；opencode 存 `session.location.directory`），
恢复时以会话的 cwd 为工作目录——**不是目录限制，而是"会话随身携带环境"**。

**方案对比**：

| 方案 | 内容 | 优点 | 代价 |
|---|---|---|---|
| A 动态 system | 打开会话时重建 system：当前基础提示（源码 const）+ `<environment>当前工作目录：X</environment>` + X 向上找到的项目提示词 + "历史可能发生在其他目录"说明 | 简单；复用政策A 的"加载/重建前置当前值"机制（`prepend_system`），无需新增存储 | 历史中旧目录的操作无显式标注（靠说明缓解）；system 变化时前缀缓存一次性失效（低频可接受） |
| B A + 目录切换标记 | 检测到会话在新目录打开时，往历史插一条 `[工作目录切换：A → B]` | 历史自解释 | 污染历史/显示；缓存断点变两处 |
| C 会话记 cwd（学 pi/opencode） | `session` 表加 `cwd` 列，记录创建/上次使用的目录；打开会话时以它为准（`job.cwd` 用它） | 无歧义、业界一致 | 与"任意目录打开"的初衷有张力（但见下：目录被删可优雅回退） |

**目录被删的处理（方案 C 的核心顾虑，实为一行检查）**：
pi 已实现该场景（`session-cwd.ts`）——会话 cwd 不存在时：交互模式提示
"continue in current cwd?"，非交互报错。SkyNet 推荐更轻的策略：

| 策略 | 行为 | 适合 |
|---|---|---|
| **静默回退 + toast（推荐）** | 用当前目录跑，toast "会话目录 X 不存在，已改用当前目录"；**不覆盖原记录**（网络盘/移动硬盘可能只是暂时不可用） | 懒人场景（零交互） |
| 交互确认（pi 式） | 弹选择"继续用当前目录 / 取消" | 严谨场景，但多一步 |
| 报错 | 拒绝打开该会话 | CLI 脚本 |

**SkyNet 最小落地形态（若做方案 C+A）**：
1. `session` 表加 `cwd TEXT` 列（`ALTER TABLE` 增量升级，将来由专门的迁移模块处理）；
2. 新建会话记录当前目录；打开会话时生效 cwd = 记录的目录（存在时）；
3. `job.cwd` 改为用"生效 cwd"（当前是 `main.zig` 里 `currentPathAlloc` 取进程 cwd）；工具
   与 AGENTS.md 查找都以生效 cwd 为准（查找规则建议"首个胜出"：`AGENTS.md` >
   `CLAUDE.md`，向上直到用户主目录）；
4. 目录不存在 → 回退当前目录 + toast（不覆盖记录）；`/cd` 指令改为**带全套效果**的
   手动切换（见上文 `/cd` 设计："告知 AI + 加载提示词 + 切工具目录"），此时"会话记
   cwd"只是它的持久化延伸；
5. 动态 system 的措辞补充（防历史混淆）：
   > This session may be used across multiple working directories. Operations in the
   > conversation history may have happened in other directories; always verify
   > absolute paths via tool results before assuming context.

**推荐路径（若哪天决定做）**：先 A（含措辞）；B 仅在实测发现 AI 确实混淆跨目录历史时
再加；C 与 A 互补（C 决定"在哪工作"，A 决定"知道自己在哪"），两者都做则跨目录困惑
基本消除。`/cd` 可独立于提示词系统先做（第 1、3 点不依赖提示词）。

### 2.6 工具集演进（待观察与设想）

**背景**：2026-09 对工具集做了一轮"低成本高收益"改进（`edit` 匹配失败给诊断线索、
`ls` 新增 `depth` 递归参数），并对照调研了 pi / opencode 的工具设计（详见
`tmp/tool-experience-report.md`，含两家源码取证）。

**待观察：`ls depth` 的实际使用频率**

- 该参数是 SkyNet 原创——**pi 的 `ls` 只有 path/limit（非递归）、opencode 干脆没有
  `ls`**（用 `glob` 代替）；两家的"看目录树"路径是 `find`/`glob` 模式。
- 保留理由：跨平台一致性（Windows 的 `tree.com` 不支持深度限制，靠外部命令则
  Windows 用户开箱不可用——内置工具的意义正是消化平台差异）；开销极小
  （工具定义净增 ~50 token ≈ 工具定义总量的 4%、1M 上下文的 0.005%）。
- **观察点**：若长期（数月）使用中几乎不出现 `depth>=2` 调用，则考虑移除
  （同时移除描述/schema 的对应段落）。判断依据不应是直觉，而是下述统计。

**设想：工具调用的数据统计与分析**

目的：用真实数据支撑"某工具/参数该留该改"的决策，而不是拍脑袋。落点建议：

1. **日志先行（最省事）**：`tools.executeWithEnv` 入口天然拿到工具名与参数字符串
   （当前尚无任何工具调用日志）——加一行 `Log.debug` 记录"工具名 + 关键参数形状
   （如 `ls` 的 depth、`edit` 的 replace_all、`read` 的 offset/limit 是否使用）+
   结果字节数 + 是否失败"，即可零成本积累原始数据（日志已按会话分文件，见
   `src/log.zig`）。
2. **汇总视图**：将来做一个 CLI 子命令（如 `skynet stats-tools`）扫描日志/数据库，
   输出：各工具调用次数与占比、失败率、参数分布（depth 分布、grep 的 glob/literal
   使用率）、平均输出字节数——直接回答"哪些工具/参数值得保留、哪些从没人用"。
3. **与缓存统计合并**：与 `cmdStats` 的既有思路一致（数据驱动），可共用输出格式。
4. **隐私注意**：统计只记"工具名 + 参数形状"（如布尔/枚举/数值区间），**不记参数
   内容与文件路径**，避免日志变成敏感信息堆积。

**其他已知但暂缓的工具改进**（来自上述调研，按需再启）：

| 项 | 来源 | 说明 |
|---|---|---|
| `edit` 支持 `edits[]` 数组（一次多个不相交编辑） | pi 有实现 | 事务性多编辑；我们的 `edit` 目前一次一处（批量替换靠脚本） |
| `grep` 输出按文件分组 | opencode 风格 | 比 `path:line: text` 平铺易读；会改变现有输出格式，需权衡 |
| `todo` 工具（跨压缩保留的任务清单） | opencode 有实现 | 需持久化（DB 表 + UI 展示），成本较高，宜单独设计 |
| `webfetch` / `websearch` | 两家都有 | 当前靠 `bash` 调 firecrawl（环境特有），通用性差 |

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

### 3.4 内存行为说明（排查时先读这里）

长会话的内存治理见本文件 2.6 与窗口化实现（`updateMessageWindow` / `unloadMessage` /
`reloadMessage`，以及 `src/db_query.zig` 绕开 fridge session arena）。以下现象是**正常行为**，
不要误判为泄漏：

**"滚动时内存缓涨 + 突然断崖下跌"**：

- **缓涨**：滚动触发消息重载（分配 `content`/`reasoning`/`md`）。Zig 的默认分配器是
  `DebugAllocator`（`std.process.Init.gpa`），**小分配释放后留在进程内的空闲桶里复用**
  （不归还 OS）——这是性能优化（避免频繁系统调用），不是泄漏；
- **断崖跌**：窗口滑出视口的消息被 `unloadMessage` 卸载，释放的 `reasoning`/`content`
  常是几十 KB 的**大块**；GPA 对 `large_allocations`（≥ 页大小）走 `freeLarge` →
  `rawFree` → **真正 munmap 归还 OS** → RSS 骤降；
- 整体有界（实测：会话 4 启动 ~45MB，滚动往返在 16-26MB 间波动，闲置 90 秒零增长）。

**想验证"是否真零增长"**：把入口的 `init.gpa` 换成 `std.heap.smp_allocator`（生产级，
分配/释放更接近直接向 OS 要/还）再测——GPA 的空闲桶复用会掩盖小分配的泄漏。
代价：失去 GPA 的泄漏检测（debug 构建下的双释放/越界检查），**仅用于一次性验证，不要提交**。

**历史教训**（已修，勿回退）：
- `fridge` 的查询构造全部分配在 session arena（仅 `deinit` 释放），长驻进程频繁小查询
  会持续泄漏（实测 2892B/次）。所有**高频**查询必须走 `src/db_query.zig`（临时 arena）；
  新增查询时若走 `sess.raw(...).fetchAll(...)`，请评估调用频率；
- 窗口化的 `updateMessageWindow` **不能**加 `isStreaming` 早退（会退化成"只重载不卸载"，
  生成中滚动内存暴涨）；
- 实时生成的消息必须回填 `db_id`（否则永不满足卸载条件，长会话只增不减）。

---

*维护提示：本文的路线图部分应随实现推进更新（完成的移入相应章节或删除）；踩坑经验
请直接追加到 3.1，注明触发场景。*
