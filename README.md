<img width="1247" height="759" alt="57f8a45b01e6bc350b89e026b9ec3efb" src="https://github.com/user-attachments/assets/474562fd-102b-49c7-9622-812db7f099da" />

# SkyNet

用 Zig 0.16 写的 TUI AI 编码助手
仿照 pi 提供 7 个工具（read / write / edit / bash / grep / find / ls）、
流式对话、思考块、SQLite 持久化、
工具输出折叠、上下文压缩（compaction）、prompt 缓存亲和、CLI 与 TUI 共用同一套 agent 逻辑。

## 免责声明（请务必阅读）

- **没有工具权限系统，也没有沙箱，AI 想去哪就去哪。** 它以你的用户身份、你账号的完整权限运行：
  能读写任意绝对路径（不限于 cwd）、执行任意 shell 命令（默认 pwsh）、发起网络请求，
  全程没有任何确认或拦截。"换个安全目录再跑"**不能**限制它——工作目录只是提示词层面的约定，
  不构成隔离。要真正限制，只能靠系统级手段（虚拟机、独立用户/容器、备份与权限控制），
  而不是指望本程序。**用它造成的一切后果由使用者自行承担。**
- **提供商兼容性仅做了极有限实测。** 目前只实测过 **opencode-go** 网关，模型只实测过
  **deepseek-v4.1-flash**。内置的其他提供商预设（OpenAI、OpenRouter、DeepSeek 官方等
  18 家）只是模板，**不保证可用**；其他模型对工具调用、缓存字段、思考强度参数的支持
  也不一致，可能出现报错、重复计费或行为异常。
- **会产生真实费用。** 请自行确认计费与配额，建议先用小会话和 `--max-chars` 观察。
- **缓存命中优化、上下文压缩、会话持久化都只是"尽量做了"，不保证可靠。**
  摘要可能丢信息，缓存亲和可能失效，数据库 schema 版本不一致时会**删表重建**（会话丢失）。
  不要把 SkyNet 用作唯一的信息存储。
- 本项目仅供学习与自用，不提供任何形式的担保（见文末）。

## 构建

需要 Zig 0.16。仓库用 git submodule 引入 zigtui，克隆时请带 `--recurse-submodules`
（已经克隆过的执行 `git submodule update --init`）：

```bash
git clone --recursive https://github.com/NeonMedusa/SkyNet.git
zig build                    # 调试构建 → zig-out/bin/SkyNet.exe
zig build test               # 全部单测（mock 集成测试在 mock 未启动时自动跳过）
zig build -Doptimize=ReleaseSafe
```

## 运行

```bash
./zig-out/bin/SkyNet.exe                 # 启动 TUI
./zig-out/bin/SkyNet.exe help            # CLI 帮助
./zig-out/bin/SkyNet.exe ask -new -title "随便聊聊" "你好"
./zig-out/bin/SkyNet.exe ask -session latest "继续"
```

- 提供商与密钥：编辑 `config.json`（默认不随仓库提交），密钥也可以走环境变量
- 数据默认落 `skynet.db`（SQLite，WAL）
- CLI 的 stdout 是最终回答，stderr 是工具活动；`--json` 输出结构化结果；
  退出码 0 成功 / 2 参数错误 / 3 无可用提供商或模型 / 4 请求或数据库失败

常用 CLI 子命令：`ask` / `new` / `sessions` / `messages` / `stats` / `compact`。
常用参数：`-session <id|latest>`、`-db`、`-config`、`-model`、`-provider`、
`--no-tools`、`--max-chars N`、`--max-context N`、`--thinking off|low|high|max`。

TUI 里可用的指令与快捷键：`/help`、`/models`、`/sessions`、`/compact`、`/thinking`、
`Esc` 打开菜单、`Ctrl+Q` 取消流式/压缩、`Ctrl+C` 复制选中内容。

## 已知限制

- 工具没有确认环节、没有目录白名单，也**无法阻止通过绝对路径访问任意位置**（见免责声明第一条）
- 提供商预设基本未经实测，只有 opencode-go + deepseek-v4.1-flash 是验证过的组合
- prompt 缓存亲和、工具输出折叠、自动/手动压缩属于启发式实现，边界情况下可能失效或误判
- SQLite schema 升级策略：相邻版本尽量 `ALTER TABLE` 无损迁移，版本跨度大时删表重建
- 仅在 Windows + PowerShell 7 上做过日常验证

## 第三方组件

`libs/` 下是随仓库附带的第三方库，各自保留原许可证（均为 MIT）：

- `zigtui`：TUI 库，以 git submodule 引入（fork 的 `skynet` 分支，含本地修改）
- `fridge`：SQLite 绑定

## 参考与致谢

本项目的工具集设计仿照 [pi coding agent](https://github.com/earendil-works/pi)；
TUI样式、工具输出折叠等上下文管理的部分规则参考了 [opencode](https://github.com/anomalyco/opencode)。

## 许可证

以 MIT 协议发布，详见 [LICENSE](LICENSE)。
