# AI 跨会话协作规程（CLI）

> 场景：多个 SkyNet 会话/实例之间交换状态与信息时，AI 应遵循的操作规程。
> 前提：进程共享同一个 `data/skynet.db`（`-db` 显式指定时以指定路径为准）。

## 1. 命令能力分级

| 命令 | 语义 | 风险 |
|---|---|---|
| `skynet sessions` | 列出全部会话（id/标题/活跃时间） | 只读，安全 |
| `skynet stats -session <id\|latest>` | 上下文占用/token/压缩点统计 | 只读，安全 |
| `skynet messages -session <id\|latest> [-n N]` | 读取最近 N 条消息（`--json` 为结构化） | 只读，但内容进上下文 |
| `skynet ask -session <id\|latest> "..."` | **向该会话追加一轮并取回回复** | 写入；见第 2 节 |
| `skynet compact -session <id\|latest>` | 生成压缩 checkpoint | 写入，破坏性低但务必避开并发 |
| `skynet ask -new -title "..."` / `skynet new` | 新建会话 | 写入，安全 |

退出码约定：0 成功 / 2 参数错误 / 3 无可用提供商或模型 / 4 请求或数据库失败。

## 2. 铁律（违反会造成数据/上下文分叉）

1. **禁止对"正在 TUI 中打开或正在生成中"的会话执行 `ask` / `compact`**
   - TUI 持有内存态历史：CLI 写入的消息它看不到，且 TUI 下一轮会用自己的旧历史继续——
     DB 与视图分叉（重启/切换会话后才一致）
   - 并发流式响应会交错追加消息
2. **`ask` 续会话用的模型是"当前配置"的模型，不是该会话原本的模型**；
   确需保持原模型时显式传 `-provider/-model`，或先在目标会话里确认
3. **先侦察再发言**：大会话先 `stats` 看规模——`ask` 会把该会话**全量历史**重发一遍；
   `messages` 先用 `-n` 小值 + `--quiet`
4. **发消息必须带角色前缀**：`代号(实例/会话)：……`，让对方模型知道是另一个 agent
   在说话（例如 `Vega(Windows主实例)：请报告当前测试状态`）
5. **要求结构化回复**：让对方按"结论 / 证据 / 待办"格式回答，降低来回轮数
6. 每次调用后**核对退出码与 stderr**；`--json` 不含思考与工具原文

## 3. 推荐模式：信箱会话（双向通信）

```bash
# 建一个专用信箱会话
skynet ask -new -title "agent-mailbox" --json "TUI 之外协作信箱，仅用于 agent 间留言"

# A 方留消息（session id 从上一条输出拿）
skynet ask -session <mailbox_id> --json "Vega(Windows主实例)：WSL 侧代理回归已通过，待办：验证 Ctrl+Q 孙进程"

# B 方读取并回复
skynet messages -session <mailbox_id> -n 3 --quiet
skynet ask -session <mailbox_id> --json "WSL实例：收到。孙进程清理验证通过，附日志摘要……"
```

## 4. 只读侦察示例

```bash
skynet sessions                                  # 有哪些会话
skynet stats -session 4                          # 目标会话上下文规模（决定是否值得 ask）
skynet messages -session 4 -n 5 --quiet          # 最近 5 条，评估对方进度
```

## 5. 已知限制

- TUI 内正在显示的会话，其视图不会实时反映 CLI 写入；需切换会话（重载）或重启 TUI
- `-session latest` 指"最近活跃会话"——若刚被 CLI 写入，`latest` 可能指向信箱会话本身
- 跨实例（不同 exe/数据目录）时各用各的 `-db`，互不可见——需要跨实例协作请共用同一个库文件
