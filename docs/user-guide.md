# SkyNet 用户手册

面向使用者的配置与指令参考。安装/构建见 [README](../README.md)。

- [1. 快速开始](#1-快速开始)
- [2. 配置参考（config.json）](#2-配置参考configjson)
- [3. TUI 指令与快捷键](#3-tui-指令与快捷键)
- [4. CLI 子命令与参数](#4-cli-子命令与参数)

---

## 1. 快速开始

```bash
git clone --recursive https://github.com/NeonMedusa/SkyNet.git
cd SkyNet
zig build
./zig-out/bin/SkyNet.exe
```

首次启动会自动生成 `config.json`（空配置）和 `skynet.db`（SQLite 数据库，存会话历史）。
在 TUI 里按 `Esc` 打开菜单 → `models` → 底部「+ 添加提供商…」，按提示填入名称、API 地址、
密钥即可开始对话；密钥也可以留空并填环境变量名（见 [2.4 密钥解析](#24-密钥解析顺序)）。

常用入口：

```bash
./zig-out/bin/SkyNet.exe                 # 启动 TUI
./zig-out/bin/SkyNet.exe help            # CLI 帮助
./zig-out/bin/SkyNet.exe ask -new -title "随便聊聊" "你好"
./zig-out/bin/SkyNet.exe ask -session latest "继续"
```

---

## 2. 配置参考（config.json）

### 2.1 顶层结构

```jsonc
{
  "providers": [ /* 提供商列表，见 2.2 */ ],
  "current": { "provider": "opencode-go", "model": "deepseek-v4.1-flash" },
  "thinking": "max",
  "ambiguous_width": "auto",
  "width_overrides": { "wide": "U+2460-U+249B", "narrow": "— → ←" }
}
```

| 字段 | 说明 |
|---|---|
| `providers` | 提供商列表（数组）。TUI 里增删改会自动写回本文件 |
| `current.provider` / `current.model` | 当前使用的提供商与模型 |
| `thinking` | 思考强度：`""`（不发送）/ `off` / `low` / `high` / `max`。TUI 的 `/thinking` 会写回这里 |
| `ambiguous_width` | 模糊宽度字符（`①②③`、`→≤…` 等）排版档位：省略或 `"auto"`（默认）= 窄基底 + 内置推荐名单（带圈/带括号字母数字按两列）；`"wide"` = 全部两列；`"narrow"` = 全部一列 |
| `width_overrides` | 在档位之外的按字符覆盖，**永远最高优先**。`wide` 名单强制两列、`narrow` 名单强制一列；格式：空白/逗号分隔，支持码点范围 `U+2460-U+249B`（`U+` 前缀可省）或字面字符 `— → ←`。上限各 1024 个码点 |

模糊宽度示例（只让带圈数字为宽、破折号/箭头为窄）：

```json
{
  "ambiguous_width": "auto",
  "width_overrides": { "wide": "U+2460-U+249B", "narrow": "— → ←" }
}
```

注意：真宽字符（如 `中`）终端固定渲染两列，`narrow` 名单对它们无效；`wide` 名单对任何字符
有效（渲染层会补续格对齐）。想抵消 `auto` 名单里某个字符的加宽，把该字符写进 `narrow` 名单即可。

### 2.2 providers 条目字段

```jsonc
{
  "name": "opencode-go",            // 显示名（必填，唯一，≤64 字符）
  "preset": "opencode-go",          // 预设 id（可空 = 自定义）
  "endpoint": "https://.../v1",     // API 地址（必填）
  "api_key": "",                    // 密钥（可空，走环境变量）
  "api_key_env": "OPENCODE_API_KEY",// 环境变量名（可空，走预设默认）
  "options": { /* 见 2.3 */ }
}
```

### 2.3 options 字段

| 字段 | 取值 | 说明 |
|---|---|---|
| `session_affinity` | `""`/`"auto"`、`none`、`opencode`、`openai`、`openrouter`、`fireworks` | 会话亲和的请求头方言，网关按此复用缓存 |
| `prompt_cache_key` | `""`/`"auto"`、`"on"`、`"off"` | 是否在请求体发送 `prompt_cache_key`（服务端前缀缓存亲和） |
| `cache_retention` | `""`/`"auto"`、`none`、`short`、`long` | 缓存保留策略；`long` 发送 24h 保留参数（支持的服务端才有效） |
| `include_usage` | `""`/`"auto"`、`"on"`、`"off"` | 是否请求流式 token 用量（默认开）。个别严格网关不认 `stream_options` 时可设 `"off"` |
| `context_window` | 数字 | 上下文窗口大小（token）。`0` = 按模型名启发式推断 |
| `headers` | `[{ "name": "X-Org", "value": "acme" }]` | 附加请求头 |

以上字段留空/`"auto"` 时按 `preset` 的默认行为；`preset` 也为空时按主机名兜底（如识别 `opencode.ai`、`deepseek.com`）。

### 2.4 密钥解析顺序

1. `api_key` 非空 → 直接使用；
2. 否则读 `api_key_env` 指定的环境变量；
3. 它也为空时 → 读预设的默认环境变量（见 2.5 表）。

本地服务（LM Studio / Ollama）不需要密钥。

### 2.5 内置预设（18 家）

| preset id | 名称 | 默认环境变量 |
|---|---|---|
| `openai` | OpenAI | `OPENAI_API_KEY` |
| `opencode` / `opencode-go` | OpenCode Zen / Zen Go | `OPENCODE_API_KEY` |
| `openrouter` | OpenRouter | `OPENROUTER_API_KEY` |
| `deepseek` | DeepSeek | `DEEPSEEK_API_KEY` |
| `moonshot` | Moonshot / Kimi | `MOONSHOT_API_KEY` |
| `zai` | Z.ai (GLM) | `ZHIPU_API_KEY` |
| `groq` | Groq | `GROQ_API_KEY` |
| `mistral` | Mistral | `MISTRAL_API_KEY` |
| `xai` | xAI (Grok) | `XAI_API_KEY` |
| `google` | Google (OpenAI 兼容) | `GEMINI_API_KEY` |
| `cerebras` | Cerebras | `CEREBRAS_API_KEY` |
| `fireworks` | Fireworks | `FIREWORKS_API_KEY` |
| `together` | Together | `TOGETHER_API_KEY` |
| `nvidia` | NVIDIA NIM | `NVIDIA_API_KEY` |
| `siliconflow` | SiliconFlow | `SILICONFLOW_API_KEY` |
| `lmstudio` | LM Studio（本地） | 不需要 |
| `ollama` | Ollama（本地） | 不需要 |

> 预设只是模板地址与默认值，**不保证各家全部可用**；实测过的组合见 README 免责声明。

### 2.6 完整示例

```jsonc
{
  "providers": [
    {
      "name": "opencode-go",
      "preset": "opencode-go",
      "endpoint": "https://opencode.ai/zen/go/v1",
      "api_key": "",
      "api_key_env": "OPENCODE_API_KEY",
      "options": { "include_usage": "on" }
    },
    {
      "name": "公司网关",
      "preset": "",
      "endpoint": "https://gw.example.com/v1",
      "api_key": "",
      "api_key_env": "COMPANY_KEY",
      "options": {
        "session_affinity": "openai",
        "cache_retention": "long",
        "context_window": 131072,
        "headers": [{ "name": "X-Org", "value": "acme" }]
      }
    }
  ],
  "current": { "provider": "opencode-go", "model": "deepseek-v4.1-flash" },
  "thinking": "max"
}
```

---

## 3. TUI 指令与快捷键

### 3.1 斜杠指令

在输入框键入 `/` 开头的指令并回车。只有首词是已知指令才会被当作指令执行，
其余内容一律发给 AI（想发以 `/` 开头的普通消息时，避开这些指令名即可）。

| 指令 | 说明 |
|---|---|
| `/help`（`/h`、`/?`） | 打开主菜单（同 `Esc`） |
| `/models` | 打开模型/提供商选择菜单 |
| `/sessions` | 打开会话选择菜单 |
| `/compact [保留token]` | 压缩当前会话；省略参数用默认保留窗口（20000 token）。直接输入即执行 |
| `/thinking [级别]` | 不带参数打开选择器；带 `off` / `low` / `high` / `max` 直接设置并写回配置 |
| `/exit` | 退出程序 |

### 3.2 键盘快捷键

| 按键 | 作用 |
|---|---|
| `Enter` | 发送消息；生成/压缩中则排队，见 [3.10](#310-生成中插入消息排队) |
| `Ctrl+Enter` / `Shift+Enter` / `Ctrl+J` | 输入框内换行 |
| `Esc` | 有选中内容时清除选区；否则打开主菜单 |
| `Ctrl+C` | 复制选中内容（拖选后） |
| `Ctrl+X` | 剪切输入框内的选中内容 |
| `Ctrl+A` | 全选输入框内容 |
| `Ctrl+Q` | 中断正在进行的生成/压缩 |
| `PageUp` / `PageDown` | 聊天区上/下滚动半页 |
| `↑` / `↓` | 在输入框内上下移动光标（多行输入） |
| `Home` / `End` | 移到当前行首/行尾 |
| `Backspace` / `Delete` | 删除字符（有选中内容时删除选区） |

### 3.3 鼠标操作

| 操作 | 作用 |
|---|---|
| 左键拖选 | 在聊天区或输入框选择文本（支持跨消息；拖到聊天区顶部/底部之外自动滚动） |
| 单击思考块标题 | 展开/折叠 `> Thought:` 思考内容 |
| 滚轮 | 按鼠标位置分流：输入框上滚输入框，聊天区滚消息 |

### 3.4 主菜单（`Esc` 或 `/help`）

菜单项：`sessions` / `models` / `compact` / `thinking` / `exit`。
`↑` / `↓` 循环选择，`Enter` 执行，`Esc` 关闭。其中 `compact` 会弹**两关确认框**
（每一关默认停在「否」，`←`/`→` 切换选项、`Enter` 确认）——直接输入 `/compact` 则不弹确认。

### 3.5 模型与提供商管理（`/models`）

菜单自上而下：最近使用过的模型（最多 5 个）→ 各提供商 → 底部「+ 添加提供商…」。

| 按键 | 作用 |
|---|---|
| `Enter` | 最近模型：直接切换；提供商：拉取其模型列表（`GET /models`）供选择；底部项：进入添加流程 |
| `Ctrl+A` | 添加提供商（先选预设，末项为「自定义」） |
| `Ctrl+E` | 编辑光标所在的提供商 |
| `Del` | 删除光标所在的提供商（两关确认，默认「否」） |
| `Esc` | 关闭菜单 |

添加/编辑表单字段：**名称 / 地址 / 密钥 / 环境变量**。
`Tab`/`↓` 下一栏、`Shift+Tab`/`↑` 上一栏、`Enter` 下一栏（末栏提交）、`Esc` 取消、
`Ctrl+U` 清空当前栏。**新增时**选择预设，名称/地址为只读（来自预设）；编辑已有条目不受限。
保存后立即写回 `config.json`。

### 3.6 会话管理（`/sessions`）

列表首项为「+ 新建会话」，其后为历史会话（按最近活跃排序）。
`Enter` 新建/加载，`Esc` 关闭。切换会话在生成中会被忽略；从菜单打开某个会话
会刷新它的"最近访问"时间，下次启动自动恢复该会话。

### 3.7 状态栏

输入框下方一行从左到右：

```
114.6k/1.0M 10% · deepseek-v4.1-flash · opencode-go · think:max · 缓存 114.5k/114.7k 99%
```

- `114.6k/1.0M 10%`：本轮请求占用的上下文（服务端真实用量；启动首轮/无用量数据时为
  `~` 前缀的估算值）/ 窗口大小 / 占比。占比按压力着色：<50% 绿、≥50% 黄、≥80% 红；
- `deepseek-v4.1-flash · opencode-go`：当前模型与提供商；
- `think:max`：当前思考强度（未设置时不显示）；
- `缓存 114.5k/114.7k 99%`：prompt 缓存命中 / 输入 token 数 / 命中率（绿 ≥80%，黄 ≥50%，红 <50%）；
  没有命中数据时整段不显示。

**生成中的视觉指示**：AI 生成/压缩期间，输入框标题变为 `⠹ 生成中 12s`（旋转动画 + 已用秒数），
边框由品红变为青色；底部帮助栏同时切换为 `[Enter] 排队发送  [Ctrl+Q] 中断生成`。空闲后自动恢复。

### 3.8 上下文压缩（compaction）

会话变长后，旧消息会被替换为一段摘要（checkpoint），以控制上下文规模：

- **自动**：请求达到窗口的 75%（默认）时触发；保留最近约 20000 token 不动。
  多数情况下无需干预；摘要内容与"哪条之前的消息被压缩"会以黄色提示展示在聊天区。
- **手动**：`/compact`（或菜单里的 compact）随时压缩；`/compact 30000` 指定保留窗口；
  CLI 可加 `--keep-tokens N`。
- 工具输出另有独立的**折叠**机制（较早的大输出替换为一行提示），不需要手动管理。

### 3.9 输入框与消息

- 输入框支持多行（`Ctrl+J`/`Shift+Enter` 换行）、粘贴（终端的 bracketed paste，
  大粘贴自动保留排版；超上限会截断并提示）；
- 消息列表：用户消息带左侧竖条；AI 回复流式渲染；思考块（`> Thought: 3.2s`）
  在思考时自动展开、思考完成后自动折叠，点击标题可手动展开/折叠；
- 工具调用以 `→ 工具名（摘要）` 和输出块展示（`$` 开头为 shell 输出，`←` 开头为 diff）。

### 3.10 生成中插入消息（排队）

AI 生成/压缩期间按 `Enter`，消息不会丢失，而是**排队等待**：

- 消息立即上屏（带竖条的用户消息）+ 右上角提示"已排队"；
- 送达时机：**在下一个工具轮次边界注入**——AI 正在跑工具循环时，排队消息会在
  下一次请求前插入对话（AI 能立即看到并响应）；若本轮以纯文本回复结束（没有更多
  工具轮次），则在**本回合结束后作为新回合自动发出**；
- 连续排队多条：工具轮次边界会按顺序整批注入；轮尾只先发出最早一条，其余留给下一回合；
- 排队上限 32 条；切换会话/新建会话时清空队列；`Ctrl+Q` 取消生成后队列照常送出；
- 斜杠指令在生成中仍被忽略（不会排队）。

```text
你: 帮我看看这个 bug…
AI: （正在跑工具循环…）
你: [Enter] 顺便把日志级别改成 debug     ← 排队，立即上屏
AI: （下一个工具轮次前看到该消息，直接照做）
```

### 3.11 断连自动重试

流式响应中途断开（网络错误或连接被网关/服务端掐断）时自动重试，无需手动重发：

- **默认最多重试 2 次**，指数退避（约 2 秒、4 秒，含 ±25% 抖动）；
- 聊天区显示 `↻ 连接中断，N 秒后重试（第 x/2 次）`，失败尝试的部分思考会被丢弃
  （重试是**整请求重发**而非续传——这是协议限制：思考内容不能回传服务端续写）；
- 重试期间按 `Ctrl+Q` 可取消（退避睡眠也会被立即打断）；
- **成本提示**：输入侧因前缀缓存几乎免费，但输出侧（思考+回答）会重算；
- 服务端返回的确定性错误（如 400/鉴权失败）不会重试，直接报错。
- 重试预算用尽仍失败时提示"连接中断：响应流未正常结束"，此时手动重发即可。

### 3.12 日志（排查问题）

每次启动会把诊断日志写到 `logs/<时间戳>.txt`（自动保留最近 20 份）：

- 记录内容：启动/会话加载、LLM 请求与响应（耗时/token/缓存命中）、工具调用（参数摘要/耗时/输出大小）、
  断连重试、压缩与折叠、数据库异常（**含"删表重建"警告**）等——不含消息正文与密钥；
- 默认级别 `info`；排查更细的问题（如工具参数）可用 `debug`：

```powershell
$env:SKYNET_LOG='debug'   # off / error / warn / info（默认） / debug
zig build run
```

- 日志只写文件、不干扰 TUI 界面；遇到异常行为（断连、卡顿、消息异常）时，把最新的
  `logs/*.txt` 内容一并提供给协助排查的人或 AI 即可。

---

## 4. CLI 子命令与参数

无界面模式，与 TUI 共用同一套 agent 逻辑（同样的工具、压缩、缓存策略）。

```bash
skynet                         # 启动 TUI
skynet ask [选项] "消息"        # 发送一轮对话（含工具调用）
skynet new [-title 标题]        # 新建会话
skynet sessions                # 列出会话
skynet messages -session <id|latest> [-n N]   # 查看会话消息
skynet stats [-session <id|latest>]           # 上下文/token 统计
skynet compact [-session <id|latest>]         # 压缩上下文（生成摘要 checkpoint）
skynet help
```

### 4.1 参数

| 参数 | 说明 |
|---|---|
| `-session <id\|latest>` | 指定会话（默认 `latest`；不存在则新建） |
| `-new` | 先新建会话再发送 |
| `-title <文本>` | 新会话标题 |
| `-provider <名称>` | 临时覆盖提供商（不写回 config.json） |
| `-model <模型id>` | 临时覆盖模型（不写回 config.json） |
| `-thinking <级别>` | 思考强度 `off`/`low`/`high`/`max`（仅本次请求） |
| `-db <路径>` | 数据库文件（默认 `skynet.db`） |
| `-config <路径>` | 配置文件（默认 `config.json`） |
| `-n <数量>` | `messages` 只显示最后 N 条 |
| `--json` | 以 JSON 输出结果（结构化字段，不含思考/工具原文） |
| `--quiet` | 不输出过程信息（stderr） |
| `--stream` | 实时把正文增量写到 stderr |
| `--no-tools` | 不打印工具活动行（stderr） |
| `--max-chars <N>` | 文本模式下最终回答截断为前 N 个字符 |
| `--max-context <N>` | 临时覆盖上下文窗口大小（便于测试自动压缩） |
| `--keep-tokens <N>` | 压缩时保留的最近 token 数（默认 20000） |

### 4.2 输出约定与退出码

- `stdout` = 最终回答；`stderr` = 过程信息与工具活动行；
- 退出码：`0` 成功 / `2` 参数错误 / `3` 无可用提供商或模型 / `4` 请求或数据库失败。

### 4.3 示例

```bash
# 新建会话并问一句，只看最终回答的前 500 字符
skynet ask -new -title "调试" --max-chars 500 "解释一下这个报错"

# 结构化输出（脚本消费）
skynet ask -session latest --json "列出 TODO"

# 查看最近 10 条消息 / 会话列表
skynet messages -session latest -n 10
skynet sessions

# 用小窗口触发一次自动压缩（验证行为）
skynet ask --max-context 2000 "继续"
```
