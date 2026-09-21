# zigtui 上游 PR 计划

> 目的：把 fork（`NeonMedusa/zigtui`，集成分支 `skynet`）内对 zigtui 的本地改动中
> **通用**的部分回贡上游（`adxdits/zigtui`），减少长期维护成本。
> 本文记录分类结论、PR 路线与工作流，随进度更新。

## 分支模型

| 分支 | 基准 | 用途 |
|---|---|---|
| `upstream/master` | — | 上游，只读参照 |
| `skynet` | 上游 + 本地补丁 | SkyNet 实际消费的集成分支（保留全部本地改动，作为兜底） |
| PR 分支（如 `utf8-tolerance`） | **`upstream/master`** | 干净基底上的"上游形态"移植：英文注释/测试、单一关注点 |

原则：

- PR 分支从 `upstream/master` 起，**不夹带** `skynet` 的历史提交；
- 每个 PR 只含一个逻辑改动；注释与测试名用英文（上游为纯英文项目，
  CONTRIBUTING 要求 "Keep doc comments short and factual"）；
- PR 合并后：`skynet` rebase 到新 `upstream/master`（冲突一般接受上游版本），
  再回主仓库更新 submodule 指针并按需适配。

## 改动分类（对照 fork 的五个提交）

### 6c0105e 非法 UTF-8 容错（69 行）—— 全部适合 PR

- 依据：上游 `stringWidth` / `truncateToWidth` / `Buffer.putString` 经
  `Utf8View ... nextCodepoint()` 解码，其内部对非法输入使用 `catch unreachable`
  （Zig 0.16 `std/unicode.zig` 的 `utf8ByteSequenceLength`/`utf8Decode`），
  渲染外部脏字节（文件内容、命令输出）会在 Debug/ReleaseSafe 下直接 panic。
- 判定：直接 PR。修 bug、动机硬、改动小。

### b173771 Windows VT 输入（423 行）—— 拆三份

| 部分 | 判定 | 备注 |
|---|---|---|
| `Parser`（bracketed paste 状态机） | PR：改造后可移 | 上游 `events/mod.zig` 已声明 `.paste` 事件但全库无生产者、也无处发送 DECSET 2004（"API 已承诺、实现缺席"）。移植时先接 **POSIX/ANSI 后端**（主流平台），而非只接 Windows |
| `restore.zig` 的 Windows 支持 | PR：直接可移（推荐） | 上游 `restore.arm` 仅在 `ansi.zig`（POSIX）被调用；Windows 上 panic/异常退出会留下 raw 模式控制台（`leave_sequence` 里连关鼠标上报的序列都写好了但没人 arm）。小而独立 |
| Windows 切 VT 输入 + SGR 鼠标（windows.zig 主体） | PR：有争议，先 issue 探路 | 上游在 `windows.zig` 明确注释了*为什么*禁用 `ENABLE_VIRTUAL_TERMINAL_INPUT`（要原生 key code）；VT 输入是 Windows 上实现 bracketed paste 的唯一途径，但需要提案与沟通 |
| LF(Ctrl+J) → `'\n'`、0x08 退格 | 并入 Parser 那个 PR | 通用合理性改进 |

### c0a8f25 模糊宽度（350 行）—— 拆两份

| 部分 | 判定 | 备注 |
|---|---|---|
| `ambiguous` 宽度表（Unicode 18 EAW=A，169 区间） | PR：改造后可移 | 客观数据、通用能力（对照：Rust `unicode-width` 的 `width_cjk()`、WezTerm/iTerm2 的对应选项） |
| 宽/窄档位开关 | PR：需改造 API | 上游全库零 `pub var`（配置皆显式传参），须改为 options 形式且**默认 narrow（行为零变化）** |
| `terminalAdvance` + flush 补续格 | PR：随模糊宽度一起提（可能被砍） | "库反向补偿终端推进差异"非常规，需在 PR 描述中给出实测证据；被砍则留 fork |
| `setWidthOverrides` + 全局名单数组 | **保留 fork** | 应用层字符 curation，属 SkyNet 需求，不属通用库能力 |
| `auto_recommended_wide` 推荐名单 | **保留 SkyNet**（已在 `src/main.zig`） | 同上 |

### 0b3b877 帧尾光标定位 / e762dda 光标形状（本仓库新增）—— 全部适合 PR（需英文化）

- **动机**：中文输入法（IME）的组合串与候选窗跟随**真实终端光标**。此前光标
  定位走独立 Win32 `SetConsoleCursorPosition`，与帧字节流是两条通道、时序不可控，
  IME UI 会在"最后写入格子"与目标位置间闪烁；把定位并入帧尾（同步块内）后消除。
- **组成**：`Terminal.pending_cursor` + `flush` 帧尾输出 + mock backend 测试（`0b3b877`）；
  `CursorShape`/`setCursorShape`（DECSCUSR）+ 退出/panic 复位（`e762dda`）。
- **判定**：均通用能力（POSIX 同样受益，DECSCUSR 系 xterm 标准序列），
  改动小而独立、已有 mock 测试；移植时注释/测试名英文化、基于 `upstream/master` 重建。

## PR 路线图（按可合并性排序）

| # | 标题草案 | 分支 | 组成 | 状态 |
|---|---|---|---|---|
| 1 | `render: tolerate malformed UTF-8 instead of panicking` | `utf8-tolerance` | 6c0105e 的英文移植 | **已合并**（upstream `1002ef6`，PR #38） |
| 2 | `fix(windows): arm terminal restore hook and save console state` | `windows-restore` | b173771 的 restore 部分 | **已合并**（upstream `69b3f34`，PR #39） |
| 2.5 | `feat: wide character support (windows input + widget layout)` | `wide-char-support` | 代理对输入 + TextInput/Tabs/Paragraph 按显示宽度布局（一个 PR 四个 commit） | **已合并**（upstream `e1c7c4a`，PR #42） |
| 3 | `terminal: emit pending cursor as the last instruction of a frame` | `cursor-frame-tail`（待建） | 0b3b877 的英文移植（`pending_cursor` + mock backend 测试） | 本地已有（skynet 分支），待移植/推送 |
| 4 | `terminal: DECSCUSR cursor shape support` | `decscusr`（待建） | e762dda 的英文移植（`CursorShape` + `setCursorShape` + 退出复位） | 本地已有（skynet 分支），待移植/推送 |
| 5 | `feat: bracketed paste events (POSIX backend)` | `bracketed-paste`（待建） | Parser + POSIX 接线 + LF 语义 | 未开始 |
| 6 | `feat(windows): VT input mode with bracketed paste and SGR mouse` | 待定 | windows.zig 主体（先 issue 探路） | 未开始 |
| 7 | `feat: East Asian ambiguous width support (opt-in)` | `ambiguous-width`（待建） | 宽度表 + options 化 + 补格（先 issue 探路） | 未开始 |

顺序考量：#1–#4 均为低风险（修复或小而独立的能力；#3/#4 由 SkyNet 实装并实测——
IME 漂移/闪烁问题已在真实环境解决，说服力强；mock backend 属测试基建增量），
建立 PR 记录后再提 #5（新功能）、#6/#7（含设计讨论，建议先开 issue 探路）。
注意：#3/#4 的 `restore.zig` 改动（复位序列）与 PR-2 同文件，若 PR-2 先合并，
移植时基于合并后的 master 重建。

## PR-1 语义备忘（utf8-tolerance）

- 非法输入 → `U+FFFD`（1 列）；**每次前进 1 字节**，保证不吞掉紧随其后的合法字节；
- fork 版 `stringWidth` 曾在解码失败时前进整个序列长度（`i += len`），PR 版统一为
  1 字节；`skynet` rebase 时以 PR 版语义为准（对 SkyNet 无可见影响）；
- 覆盖用例：游离非法字节、尾部截断、坏序列后跟合法字节（不吞）、超长编码；
- 解码逻辑收敛到公共辅助 `decodeCharAt()`（此前三个函数各写一份，语义有细微出入）。

## PR-2 语义备忘（windows-restore）

- `arm` 在 Windows 上改为**显式接收原始控制台模式**（`WinMode`），与 POSIX 传入
  `original_termios` 的形态对齐；`restore()` 先写离开序列（此时 VT 处理仍开启），
  再交还 stdin/stdout 模式；
- 新增 Windows-only 测试用 `INVALID_HANDLE_VALUE` 驱动状态机（不触碰真实控制台），
  测试体用 `if (!is_posix)` comptime 分支包裹（否则 POSIX 编译会因句柄类型不匹配报错）；
- 跨平台验证：本机 Windows `zig build test`（70/70）+ `zig build examples` + 对
  `x86_64-linux-gnu` 的 `zig test -fno-emit-bin` 交叉编译检查（restore.zig 与 lib.zig）。

## PR-3 语义备忘（wide-char-support，2026-09-22）

合并为一个 PR、四个 commit（输入 + 三个组件的布局修复），上游接受（`e1c7c4a`）。
要点：

- **Windows 输入**：`codeUnitToUtf8`（上游版 `resolveSurrogate` 的 fork 增强版）——
  **两版的关键差异**：上游版只处理代理对；fork 版额外修复 **Latin-1 补充字符
  （U+0080–U+00FF，如 é/ü）**——旧逻辑把它们当"原始字节"透传，单字节不构成合法
  UTF-8 序列，会静默丢字符甚至吞掉后续字符。**回贡时未包含这部分**（当时 PR 只移植了
  代理对逻辑），rebase 后保留 fork 版并删除上游版；
- **Widgets 布局**：TextInput/Tabs/Paragraph 此前按"码点计数"推进而非显示宽度，
  宽字符（CJK/emoji）的第二列会被后继字符覆盖、整对清空 → 表现为"字符不显示"。
  统一改用 `codepointWidth` 计列；
- **测试**：`combineSurrogates` 边界 + 代理对状态机 + 三个组件的宽字符布局。

## 流程教训：rebase 会静默剥离"fork 独有的增强"

**2026-09-22 实例**：`skynet` rebase 到 PR #42 后，`codeUnitToUtf8` 的**调用点**
被退回旧逻辑（`uch <= 0xFF` 直接透传字节），函数本身也消失；**编译与测试都能过**
（上游测试只覆盖代理对，不覆盖 Latin-1），是**静默的功能回归**——只有对照 fork
版 diff 才发现。

**下次 rebase 的检查清单**：
1. rebase 后 `git diff <fork备份> skynet -- <冲突文件>` 逐文件对照，确认 fork 的
   增强**仍在**（不只是"测试通过"）；
2. 特别检查"上游也有类似函数、但 fork 版更强"的场景（如 `resolveSurrogate` vs
   `codeUnitToUtf8`）——这类冲突 git 会倾向选上游，需要人工判断保留哪版；
3. 备份分支（`skynet-backup*`）在确认稳定前不要删；
4. **跑完整测试 + TUI 冒烟**（`zig build test` + `zig build examples`；SkyNet 侧
   `zig build test` 全量 mock + 真机启动一次）——测试覆盖不到的场景（如 Latin-1
   字符）靠真机操作补。

**标准四步**：rebase → **diff 对照备份** → 完整测试/冒烟 → force-push。

## Rebase 记录（2026-09-22：PR #42 合并后）

- `upstream/master` 合入 PR #42（`e1c7c4a`）——即我们回贡的 4 个提交（宽字符支持）；
- `skynet` rebase（备份 `skynet-backup2` @ `8e4c585`）。`windows.zig` 冲突 6 处：
  - 字段：**保留双方**（VT `input` parser + `pending_high_surrogate`）；
  - `pollEvent` 主体：**取 fork 版**（VT 路径用 parser 接管事件；上游的直接
    KEY_EVENT/MOUSE switch 已被取代）；
  - `resolveSurrogate` vs `codeUnitToUtf8`：**保留 fork 版**（多 Latin-1 修复），
    删除上游版及其测试；
  - **修复被 rebase 剥离的调用点**（见上节流程教训）；
- 验证：zigtui **111/111**（比 rebase 前多 6 个：吸收上游 widgets 测试 + 保留
  Latin-1 覆盖）+ examples；SkyNet 168 pass（无 mock）+ 构建；
- `skynet` force-push（`8e4c585` → `9d0af03`）。

### fork 遗留问题（已解决）

- ~~`skynet` 分支的 `restore.arm` 在 Windows 上于进入 raw 模式之后调用、快照到 raw 模式~~
  ——PR-2 合并后 `skynet` 已 rebase（2026-09-21），上游 `WinMode` 显式传入原始模式，
  问题根除；本分支的 restore.zig 已与上游完全一致（rebase 时整文件取上游版）。
  本地对 restore.zig 的唯一残留差异是 leave_sequence 里的 `\x1b[0 q`（光标复位），
  属 PR-4 组成，待 PR-4 移植时一并处理。

## Rebase 记录（2026-09-21：PR-1/PR-2 合并后）

- `upstream/master` 合入 PR #39（`69b3f34`）与 PR #38（`1002ef6`），并发布 tag `v0.1.0`；
- `skynet` rebase 至新上游（备份分支 `skynet-backup` @ 旧 `fad915e`，保留至确认稳定后删除）；
  过程中解决两类冲突：
  - **已回贡部分 → 取上游版**：`restore.zig` 整文件、`render/mod.zig`+`width.zig` 的
    UTF-8 解码路径（6c0105e 的内联解码被 PR-1 的 `decodeCharAt` 取代，语义等价）；
  - **未回贡部分 → 保留本地并适配新 API**：`windows.zig` 的 VT 输入/bracketed paste
    （与上游 `restore.arm` 新签名融合）、模糊宽度（`c0a8f25` 整体保留，解码处改用
    `decodeCharAt`）、光标两项（`0b3b877`/`e762dda`，无冲突）；
- 验证：zigtui `zig build test` 101/101、`zig build examples` 通过；SkyNet 全量
  168/168（5 mock）、TUI 冒烟正常；`skynet` 已 force-push 回 fork（`fad915e` → `8e4c585`），
  主仓库 submodule 指针同步更新。
- **注**：本记录中的 `0b3b877`/`e762dda`/`c0a8f25` 等 hash 是那次 rebase **之前**的
  提交号；后续每次 rebase 都会重写（2026-09-22 后对应 `df7c9b3`/`1f674df`/`f60c31a`）。
  引用 fork 提交时以"标题 + 分支"为准，别依赖 hash。

## 每个 PR 的工作流

1. `cd libs/zigtui && git fetch upstream && git checkout -b <name> upstream/master`
2. 移植改动：英文注释与测试名、单一关注点、`zig fmt`
3. `zig build test` + `zig build examples`（对齐上游 CI；zlint 为 warning-only）
4. `git push -u origin <name>`，向上游 `adxdits/zigtui:master` 开 PR（网页操作）
5. 合并后：`skynet` rebase 至新上游 → 推送 fork → 主仓库更新 submodule 指针与适配

## 注意

- 主仓库 `.gitmodules` 声明 `branch = skynet`；PR 期间 SkyNet 仍消费 `skynet`，
  不追 PR 分支（等 PR 合并后再统一 rebase）；
- 上游 CI（`.github/workflows/pr.yml`）：`zig build examples`、`zig build test`、
  zlint（warning-only），Zig 0.16.0；
- PR 分支命名对齐上游习惯：描述性 kebab-case、与特性一一对应；
- `utf8-tolerance` 分支创建时跟踪了 `upstream/master`，首次推送时用
  `git push -u origin utf8-tolerance` 改绑到 fork。
