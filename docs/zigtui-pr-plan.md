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

## 改动分类（对照 fork 的三个提交）

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

## PR 路线图（按可合并性排序）

| # | 标题草案 | 分支 | 组成 | 状态 |
|---|---|---|---|---|
| 1 | `render: tolerate malformed UTF-8 instead of panicking` | `utf8-tolerance` | 6c0105e 的英文移植 | **已推送**（`653b2f2` @ origin/utf8-tolerance） |
| 2 | `fix(windows): arm terminal restore hook and save console state` | `windows-restore` | b173771 的 restore 部分 | **已推送**（`fa4aadc` @ origin/windows-restore） |
| 3 | `feat: bracketed paste events (POSIX backend)` | `bracketed-paste`（待建） | Parser + POSIX 接线 + LF 语义 | 未开始 |
| 4 | `feat(windows): VT input mode with bracketed paste and SGR mouse` | 待定 | windows.zig 主体（先 issue 探路） | 未开始 |
| 5 | `feat: East Asian ambiguous width support (opt-in)` | `ambiguous-width`（待建） | 宽度表 + options 化 + 补格（先 issue 探路） | 未开始 |

顺序考量：#1、#2 为低风险"热身"（纯修复、小改动），建立 PR 记录后再提 #3（新功能）、
#4/#5（含设计讨论，建议先开 issue 探路）。

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

### fork 遗留问题（待处理）

- `skynet` 分支的 `restore.arm` 在 Windows 上于**进入 raw 模式之后**调用、且在
  `arm` 内部用 `GetConsoleMode` 快照——快照到的是 raw 模式，panic 路径会把 raw
  模式写回控制台（正常退出不受影响）。PR-2 已改为显式传入原始模式；
  **该修复在 PR-2 合并、`skynet` rebase 后自动吸收**。若想提前修复（PR 未合并期间
  也生效），可把 `skynet` 分支的快照点提前到 SetConsoleMode 之前（一行改动）。

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
