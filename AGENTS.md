# SkyNet 开发与测试指南（AGENTS.md）

SkyNet 是一个 Zig 0.16 编写的 TUI AI 编码助手：流式对话、工具调用（read/write/edit/bash/grep/find/ls）、
思考块、SQLite 持久化、上下文折叠与压缩（compaction）。数据默认在 `skynet.db`（SQLite WAL）。

## 构建与测试

```bash
zig build                      # 调试构建 → zig-out/bin/SkyNet.exe
zig build test                 # 全部单测；mock 集成测试在 mock 服务器未启动时自动跳过
zig fmt src/*.zig              # 提交前格式化
zig build -Doptimize=ReleaseSafe
```

### Mock 集成测试（三个本地 SSE mock）

| 脚本 | 端口 | 用途 |
|---|---|---|
| `test/mock_openai_sse.ps1` | 18123 | 工具循环 3 轮（ls → bash → 最终回答） |
| `test/mock_openai_400_gzip.ps1` | 18124 | gzip 压缩的服务端 400 错误体 |
| `test/mock_summary.ps1` | 18125 | compaction 摘要请求（返回 `MOCK_SUMMARY`） |

启动（在工作目录执行，脚本会写 `test/mock_*.running` 标记）：

```powershell
Start-Process pwsh -ArgumentList '-NoProfile','-File','test/mock_openai_sse.ps1'
Start-Process pwsh -ArgumentList '-NoProfile','-File','test/mock_summary.ps1'
```

清理时注意**排除当前进程**，否则会误杀自己：

```powershell
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match "mock_" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

## 用 CLI 和 SkyNet 里的 AI 对话（推荐调试手段）

不用开 TUI，headless 复用与 TUI **完全相同的** agent 逻辑（工具执行、压缩、落库都会真实发生）：

```bash
zig-out/bin/SkyNet.exe help
zig-out/bin/SkyNet.exe ask -session latest -db skynet.db "你好"
zig-out/bin/SkyNet.exe ask -new -title "agent-test 某某测试" --json --no-tools "自检一句话"
zig-out/bin/SkyNet.exe sessions -db skynet.db
zig-out/bin/SkyNet.exe messages -session 3 -n 20 -db skynet.db --json
zig-out/bin/SkyNet.exe stats -session 3 -db skynet.db          # 上下文/token 构成、折叠模拟
zig-out/bin/SkyNet.exe compact -session 3 -db skynet.db --json # 手动压缩（生成摘要 checkpoint）
```

约定与注意事项：

- `stdout` = 最终回答（`--json` 时为结构化结果）；`stderr` = 工具活动（`→ Read ...` / `↳ ...`）
- 退出码：`0` 成功 / `2` 参数错误 / `3` 无提供商或模型 / `4` 请求或数据库失败
- `--json` 字段：`session_id/content/model/input_tokens/cached_tokens/output_tokens/tool_calls/error_message`；
  **不含思考内容与工具原文**（那些只落库）
- `--max-chars N` 截断文本模式回答；`--max-context N`、`--keep-tokens N` 用于小窗口测试自动压缩
- 工具在**调用时的 cwd** 执行；沙箱目录可用 `C:\Users\32182\Develop\TEST`
- 默认使用 `config.json` 里的真实 provider（会产生真实费用）；mock 测试建议在临时目录放置自己的
  `config.json` 并用 `-config`/`-db` 指向临时文件
- Windows 控制台读 UTF-8 输出建议 `[System.IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)`；
  JSON 已做 ASCII 转义，可直接 `| ConvertFrom-Json`
- TUI 运行时也可以安全地并发使用 CLI（各写各的会话；TUI 会自动增量刷新外部写入，约 500ms）

## 数据库 / schema 约定

- `schema_version` 在 `src/db.zig`（当前 **v7**）；版本不一致会**删表重建**，破坏性升级前先提醒用户
- 相邻版本优先写 `ALTER TABLE` 无损迁移（例如 v5→v6 补 usage 列与 compaction 表）
- `message` 存全部原文；发给模型的 `content` 在大工具输出折叠后是 stub，全文在 `tool_full`
- 压缩 checkpoint 在 compaction 表：summary_message_id + tail_start_id（id >= tail_start_id 的消息才发给模型）；summary_message_id 指向一条 ole='summary' 的消息（摘要原文，FTS 可搜）
- TUI 的 /compact 是**异步**的：摘要流式渲染，Ctrl+Q 可取消；CLI compact 仍同步（脚本友好）
- `skynet.db*`、`config.json` 已在 `.gitignore`，不要提交

## 关键模块

- `src/main.zig`：TUI 绘制/事件、CLI（ask/new/sessions/messages/stats/compact）、agent worker、压缩调度
- `src/context.zig`：token 估算、工具输出折叠模拟、压缩区间选择与摘要输入构建（纯计算，可单测）
- `src/cli_args.zig`：CLI 参数解析与输出辅助（无 AppState 依赖）
- `src/ai.zig`：SSE 流式请求、工具调用分片、usage 解析、各厂会话亲和/缓存参数
- `src/db.zig`：SQLite（fridge）schema 与读写；`src/tools.zig`：7 个工具实现；`src/regex.zig`：grep 用迷你正则
- 参考代码库：`C:\Users\32182\Develop\pi-main`（工具与交互设计参考）

## 其他约定

- 测试会话标题用 `agent-test` 前缀，方便识别和清理
- 工具 bug 优先自己修，不要让 TUI 里的 AI 代劳（它的会话随时可能因 schema 变更被清空）
- 改行为前先跑 `zig build test`；涉及真实 provider 的验证用小会话 + `--max-chars`
- **新增模块的测试要在 `src/main.zig` 末尾的聚合块里 `_ = @import("xxx.zig");`**，否则 `zig build test` 不会收集它们
- zigtui 以 git submodule 引入（fork `NeonMedusa/zigtui` 的 `skynet` 分支，路径 `libs/zigtui`）：
  更新上游 = 在 `libs/zigtui` 内 `git fetch upstream && git rebase upstream/master skynet` 后推送，
  再回主库 `git add libs/zigtui` 提交指针更新；克隆主库要用 `--recurse-submodules`
