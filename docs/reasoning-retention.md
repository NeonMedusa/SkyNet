# 思考保留策略调研（回传 vs 不回传：token 成本与正确率）

> 调研日期：2026-10-11 · 目的：为"思考回传"的边界处理（保留多少、跨模型、溢出）提供依据。
> 相关实现见 `docs/development.md` §2.3（interleaved reasoning 已落地 P1/P2）。
> 更新：2026-10-12（暗号对照实验 + 捕获定案 + 压缩请求调查；压缩思考策略已决议落地，见「压缩请求」节）。

## 结论速览

| 问题 | 结论 |
|---|---|
| 哪个省 token？ | **分两层**。① 回合内（工具循环）：**不回传反而更贵**——模型每轮被迫"重复推理整个问题"（DeepSeek V3.2 论文："significant token inefficiency"；Qwen 官方："保留可减少冗余推理，降低总 token 消耗"）。② 跨用户回合：不回传省输入 token 与窗口，但丢失连续性、且"丢弃动作"本身会改变缓存前缀导致重算 |
| 哪个正确率高？ | **保留普遍更高**（尤其工具/长链任务）：MiniMax M2 官方对照 Tau² **+35.9%**、BrowseComp **+40.1%**、SWE-bench Verified **+3.3%**、GAIA **+11.5%**、xBench **+9.1%**；OpenAI 官方 SWE-bench **+3%**；Novita 列出不回传的症状：错误工具使用、**重复/循环工具调用**、可靠性下降 |
| 反方代价 | **Context Rot**（Chroma 研究 + Anthropic 引用）：输入越长，召回/推理越差（即使无关 token）；Anthropic 承认 keep-all 的代价就是上下文占用；社区抱怨"思考块吃掉上下文/用量" |
| 2026 行业走向 | 向"保留"迁移：Anthropic Opus 4.5+ **keep-all**（2025-11）、OpenAI GPT-5.6 **all_turns**（2026-07）、llama.cpp `--reasoning-preserve`（2026-06）、Qwen `preserve_thinking`（agentic 推荐）；主要动机是**缓存效率 + 长程一致性** |
| 摘要（压缩）请求里回传思考吗？ | **本仓库：默认回传（已落地）**——对齐 pi / opencode（`[thinking]` 文本段）；超预算按阶梯降级（剥思考 → 加狠截断 → 丢最老，上一轮摘要始终保留）。预算 = 窗口按"1 token ≥ 3 字节"保守换算。见「压缩请求」节 |

## 各家官方立场（原文摘录）

### DeepSeek
- **API 文档**：带 `tools` 时 reasoning_content **必须完整回传**（"even for turns where the model
  did not perform a tool call"）并拼进上下文；**不带 tools 时被忽略**（示例注释："The
  reasoning_content will be ignored by the API"）。
- **V3.2 技术报告 §3.2.1「Thinking Context Management」**（arXiv 2512.02556）：
  > "Replicating DeepSeek-R1's strategy—discarding reasoning content upon the arrival of the
  > second round of messages—**results in significant token inefficiency**. This forces the
  > model to **redundantly re-reason through the entire problem for each subsequent tool call**."
  > "**Historical reasoning content is discarded only when a new user message is introduced**.
  > If only tool-related messages are appended, the reasoning content is retained throughout."
  > "When reasoning traces are removed, the history of tool calls and their results remains
  > preserved in the context."
- 即官方策略 = **回合内保留、跨用户回合丢弃**（丢弃时保留工具调用历史）。

### Anthropic
- 工具循环内**必须回传** thinking blocks（"critical for maintaining the model's reasoning flow
  and conversation integrity"），服务端自动过滤；`signature` 加密块须原样回传。
- 保留策略**按模型分层**：新模型 **keep-all**（Opus 4.5+/Sonnet 4.6+…）；**旧模型默认只留最后
  1 轮**（API 自动剥离）。可用 `clear_thinking` 配置 `keep: all / thinking_turns:N`。
- 官方权衡：保留带来 **①缓存优化**（工具循环内增量缓存命中）**②对模型性能无负面影响**；
  代价是上下文占用（"retained thinking blocks count as input like any other conversation history"）。
- 计费：思考 token 生成时按**输出**计费；回传后按**输入**计费（可缓存）。

### OpenAI
- 多轮闲聊**不需要**回传 reasoning items；**涉及函数调用时必须**（"to maximize the model's
  intelligence"）。
- 数据点：SWE-bench 上包含 reasoning items 约 **+3%**；切到 Responses API 后缓存利用率 40%→80%。

### Qwen（直接回答"省不省 token"）
- Qwen3.6-Plus 官方博客：
  > "`preserve_thinking`: …**Recommended for agentic tasks**…maintaining full reasoning context
  > can enhance decision consistency and, **in many cases, reduce overall token consumption by
  > minimizing redundant reasoning**. **Disabled by default**"（默认=丢弃最近用户消息之前的思考）。

### MiniMax M2
- 保留 vs 丢弃：Tau² **87 vs 64（+35.9%）**、BrowseComp **44.0 vs 31.4（+40.1%）**、
  SWE-bench Verified **69.4 vs 67.2（+3.3%）**、GAIA **75.7 vs 67.9（+11.5%）**、xBench **+9.1%**。
- 警告："incorrect implementations…significantly reduce the model's performance"。

### 网关/推理栈
- vLLM：interleaved thinking "**increases token usage and response latency**"。
- Novita：不回传症状——错误工具使用、丢失推理上下文、**重复/循环工具调用**、可靠性下降。
- SiliconFlow：须 "preserve and replay reasoning_content **verbatim**"。
- llama.cpp：2026-06 才加 `--reasoning-preserve`（此前历史思考会被丢）。
- hermes-agent issue #56004：客户端错误剥离字段 → 模型"忘记自己的推理"；
  vLLM ≥0.20 字段改名 `reasoning`（`reasoning_content` 会被丢弃）。
- QwenLM/Qwen3.8#131：**空思考块**导致 prompt drift / 缓存问题（→ 不要给"有思考"的消息发空串）。

## 成本机制（把账算清楚）

| 方案 | 输入 token | 输出 token | 缓存 | 窗口 | 长链质量 |
|---|---|---|---|---|---|
| 全回传（本仓库现状） | 高（可缓存，命中价 ≈ 输入的 1/10~1/4） | 低（少重复推理） | **append-only → 命中最高** | 占用大（实测思考=正文 3~8 倍）→ 压缩频繁 | 最好 |
| 回合内回传（DeepSeek 官方策略） | 中 | 低 | 回合内稳定 | 中 | 接近最好 |
| 全不回传（本仓库旧行为） | 低 | **高**（每轮重推） | 丢弃动作本身破坏前缀 | 最小 | 普通任务 OK，长链有风险 |

关键机制：**任何"丢弃/改写"动作都会改变缓存前缀**（Anthropic：丢弃思考块会让缓存从该位置
起失效）——保留 = append-only = 缓存最优；这正是 DeepSeek/Qwen 说"保留反而更省总 token"的
原因（省的是输出侧重推，赔的是输入侧缓存命中）。

## 对本仓库的启示（待办：思考保留策略旋钮）

1. **现状定位**：回传**保留区内所有**回合的思考——比 DeepSeek 官方策略更激进（官方跨回合丢弃）。
   P1 修好后压缩会正确触发，但保留区消耗放大数倍 → 压缩频率上升——keep-all 的固有成本。
2. **建议：思考保留策略旋钮**（对齐生态设计：Anthropic `keep` / llama.cpp `--reasoning-preserve`
   / Qwen `preserve_thinking`）：
   - 选项：`全部 / 最近 N 轮 / 仅当前回合（工具循环内） / 不回传`
   - 实现：窗口外的 assistant 消息发**空 reasoning_content**（字段在、内容空——协议兼容，
     pi/opencode 同款；DeepSeek 要求字段存在）
   - 注意：切换策略会改变缓存前缀 → 一次缓存重建；**估算口径要跟着策略走**（延续 P1 的
     "估算=发送"原则）
   - 建议默认保持"全部"（跟随趋势 + vendor 要求），旋钮供 A/B 实测
3. **不要做**：给"有思考"的消息发空串（Qwen issue：空思考块造成 prompt drift）；
   空串只用于"无思考"消息兜底（现状正确）。
4. **跨模型**：来源感知（异模型思考降级为文本/不回传）随 openrouter `reasoning_details`
   （带签名协议）一起做——签名必须同源才能回传。

## 行为验证：暗号实验（2026-10-12）

**目的**：验证“思考回传”端到端生效（上一轮的思考内容是否真的进入下一轮上下文）。

**设计**：

- 在一轮回复中把两枚暗号**只写入思考块**（正文不含）：`月桂-4713`、`松果-0925`；
- 排除所有其他通道：该轮**零工具调用**（不落盘）、暗号不在正文、用户消息中亦无；
- 下一轮用户追问“上一轮思考里的暗号是什么”，回答要求**不使用任何工具**、纯凭上下文。

**结果**：

- 两枚暗号**完整答对**（含格式）✅；
- TUI 核对：暗号仅出现在思考显示中，正文无泄漏；
- 数据库复核（`message` 表 session 12）：
  - 实验轮 assistant 行：`reasoning` 含两枚暗号、`content` **不含**（无泄漏）✓；
  - 回答轮 assistant 行：`content` 含暗号（即回答本身，符合预期）；
  - 用户消息行：均不含暗号 ✓。

**结论**：思考回传**端到端生效**（行为层证据）——与此前机制层证据（捕获 mock 确认请求体含
`reasoning_content`）互相印证。

**边界与后续可测**：

- 折叠不影响（只改写工具输出，不碰 assistant 的 reasoning）；
- 压缩可能丢失（若该消息被摘要出保留区）→ 可做“压缩后追问”实验；
- 保留时长（隔 N 轮再问同一暗号）也可作为后续实验。

## 对照实验与捕获定案（2026-10-12 续）

**对照（v15，无回传）**：切回旧版 v15，同法布置暗号 `白桦-6219` / `星砂-8350`（仅思考块，
零工具调用）→ 下一轮**答不出** ✅（阴性对照符合预期：不回传 = 取不到）。

**Phase 3（换回新版）**：切回新版后追问 → **声称"回忆起来"但答错**（`玄铁-8206` /
`灯芯-4471`，纯编造）；给提示（"白桦"开头）仍失败；删 zig 缓存重建后仍失败——一度怀疑
"重载路径有洞"。

**DB 取证（定案 1）**：v15 布置轮消息行（id=29024）的 `reasoning`（9,791 字符）**确含**
两枚真实暗号；`玄铁` / `灯芯` 在该行及之前**全部消息**中 **0 处** → 编造定案（幻觉，非改写）。

**捕获定案（定案 2，决定性）**：用 DB 一致性副本 + 本地捕获 mock（端口 18137）让 CLI 重发
同一会话（与 TUI 同码），捕获请求体 `req_1.json`（3.2 MB / 611 条消息 / deepseek-v4.1-flash）：

- **212 条** assistant 消息带非空 `reasoning_content`（合计 ≈ 2.3 MB）；
- **msg[575]（v15 布置轮）的 `reasoning_content` 完整含「白桦-6219」「星砂-8350」** ✅
  （「白桦-6219」共 8 条命中：1 条原始 + 7 条后续讨论轮；「星砂-8350」7 条；
  「玄铁/灯芯」在 reasoning 中 0 条，仅出现在事后自己写的 6 条 content 里）。

**结论**：**落库 → 重载 → 回传链路完好，非代码 bug**。Phase 3 失败 = **模型侧**在超长上下文
（思考占比 ~70%）中检索失败 + 编造——与 Context Rot 一致：**"在上下文里" ≠ "可被可靠取用"**。

**教训**：模型自述（"我回忆起来了"）**不可采信**，必须用外部 ground truth 验证（DB / 捕获）；
"换回新版仍失败"一度被误判为代码回归，实为模型侧检索失败。

**副作用观察**：该超长上下文期间模型自身思考出现过一次**复读循环**（模型侧退化样本；与
"长上下文 + 自我思考回声"的风险模式相符，因果未定）——keep-all 的隐性成本之一。

## 压缩（摘要）请求与思考：本仓库 vs pi / opencode（2026-10-12 调查；决议已落地）

**问题**：请求 AI 写压缩摘要时，思考内容会不会回传？（动机：状态栏 96% 时，压缩任务本身
是否可行 / 摘要请求会不会同样巨大）

**本仓库：不回传。**

- 摘要请求**只有 2 条消息**：`system`（摘要提示词）+ `user`（payload 纯文本）——**没有
  assistant 消息**，`src/ai.zig` 的 interleaved 序列化分支（仅作用于 assistant）不会触发，
  连"空串兜底"也不会（两条压缩路径同款：`src/main.zig` L6484-6487 / L6290-6293）。
- `buildCompactionPayload`（`src/context.zig` L286-334）只拼：user 正文、assistant 正文、
  tool_calls（args 截 500 字符）、工具结果（截 2000 字符）——**从不读 `m.reasoning`**。
- 实测（DB 复刻估算，compaction id=17 / session 12，脚本 `tmp/compaction_payload_estimate.py`）：

| 项 | 值 |
|---|---|
| `tokens_before`（触发时估算） | 964,896（≈状态栏 965.1k / 96%） |
| 摘要请求 payload | ≈ 0.51 MB ≈ 13~18 万 tokens |
| 同范围完整上下文（含思考） | ≈ 3.17 MB，其中 reasoning ≈ 2.39 MB（**75%**） |
| payload / full | **≈ 16%（约 1/6）** |

→ 状态栏 965k 是"正常对话请求（含思考）"的估算；**摘要请求是另一条小得多的路径**（思考
剥离 + 工具截断），96% 下压缩可行（本次已成功落库，摘要行 id=29068）。备注：摘要请求仍带
`reasoning_effort`——那是给摘要器**自身**开思考的开关，与"回传历史思考"无关，不占输入。

**pi：回传（文本形式）。**

- `serializeConversation`（`packages/coding-agent/src/core/compaction/utils.ts` L114-155）
  把 thinking 拼成 **`[Assistant thinking]: …`**（L126-138）——**全文不截断**；工具结果截
  2000 字符；主摘要 / 拆回合摘要 / 分支摘要均用它（`compaction.ts` L726 / L1095）。
- 官方文档明示该格式：`docs/compaction.md` L276-290；`durable` 包同款并有测试断言。

**opencode：回传（文本形式）。**

- `serialize`（`packages/opencode/src/session/compaction.ts` L54-85）把 reasoning 拼成
  **`[Assistant reasoning]: …`**（L69）——**全文不截断**；工具输出截 2000 字符（L30 / L51），
  被 prune 的旧输出显示 `[Old tool result content cleared]`（L76-78）。
- 摘要请求 = 单条 user 消息（提示词模板 + `<conversation>` 块；L380 / L431-446）；core 版
  实现（`packages/core/src/session/compaction.ts` L104）同款。

**解读与决议（2026-10-12，已落地）**：两家都选择把思考喂给摘要器（思考里有决策依据）——
本仓库**决定对齐**：摘要输入**默认带思考**（`[thinking]` 文本段），超预算按阶梯降级：
**剥思考 → 工具加狠截断 → 从最老端丢消息**（上一轮摘要始终保留、至少保留最后一条）；
摘要请求仍失败（重试耗尽）→ 剥思考重试一次。预算 = 窗口按"1 token ≥ 3 字节"保守换算
（如 100 万窗口 ≈ 2.95MB），给摘要输出留余量。**提示词**：查证 pi / opencode 的摘要
提示词均无"思考怎么处理"的指引（思考只作文本喂入、模型自行判断）→ 本仓库也不加；
**2026-10-13 事故复盘补正**：两家均有"禁止继续对话 / 只输出摘要"指令而本仓库缺失
（Sawdust 压缩事故根因之一）→ 已补齐，并去掉 "continue working" 字样；同批新增的压缩机制
（工具禁用指令、摘要垃圾校验 + 流式早停、输出上限与截断处理、重试定向提示 / 降思考档、
手动压缩思考档统一）见 `docs/development.md` §2.3。

**实测（卡死会话自愈，2026-10-12）**：v15 时代会话（升级后 22.97MB 请求被网关掐流、
4 连败自锁）→ 估算取大（账本 66.7 万 → 实际 590 万）→ 触发压缩 → 带思考 20.8MB 超预算
→ 剥思考 1.48MB（455k tokens）→ 摘要成功（27~101s）→ 重建 → 58 条消息小请求 → 回复
落库 ✅（首轮修复前还暴露并修复了 `ask` 在"发起前压缩"后取答案的基线失效问题）。

## 来源

- DeepSeek：`api-docs.deepseek.com/guides/thinking_mode`；arXiv 2512.02556（V3.2 报告 §3.2.1）
- Anthropic：`platform.claude.com/docs/en/build-with-claude/thinking`；AWS Bedrock
  extended-thinking 文档（计费 / `clear_thinking`）
- OpenAI：`developers.openai.com/cookbook/examples/responses_api/reasoning_items`
- MiniMax：`minimax.io/news/why-is-interleaved-thinking-important-for-m2`
- Qwen：`qwen.ai/blog?id=qwen3.6`；Qwen3.6 模型卡；`QwenLM/Qwen3.8#131`
- 基础设施：`docs.vllm.ai`（interleaved_thinking）、`novita.ai/docs`、
  `docs.siliconflow.com`、`ggml-org/llama.cpp#25105`、`NousResearch/hermes-agent#56004`
- 演进史：`note.com/bakushu/n/n0692613b4b8d`（2024 丢弃 → 2025 回合内 → 2026 keep-all）
- 反方：`trychroma.com/research/context-rot`；arXiv 2510.05381；r/Anthropic、r/claudexplorers
- 抓取原文存档：`tmp/research/`（9 份 markdown，可复查）
- 参考实现（本机仓库）：`C:\Users\32182\Develop\opencode`、`C:\Users\32182\Develop\pi`（引用文件见「压缩请求」节）
