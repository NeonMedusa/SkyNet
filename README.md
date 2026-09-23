<img width="1265" height="759" alt="图片" src="https://github.com/user-attachments/assets/54c6ca37-7cbc-46d9-b38b-28eb377adbc6" />

# SkyNet

用 Zig 0.16 写的 TUI AI 编码助手，仿照 pi 提供 7 个工具（read / write / edit / bash / grep / find / ls）：
流式对话、思考块、SQLite 持久化、工具输出折叠、上下文压缩（compaction）、prompt 缓存亲和；
CLI 与 TUI 共用同一套 agent 逻辑。

## 免责声明（请务必阅读）

- **没有工具权限系统，也没有沙箱，AI 想去哪就去哪。** 它以你的用户身份、你账号的完整权限运行：
  能读写任意绝对路径（不限于 cwd）、执行任意 shell 命令（默认 pwsh）、发起网络请求，
  全程没有任何确认或拦截。"换个安全目录再跑"**不能**限制它——工作目录只是提示词层面的约定，
  不构成隔离。要真正限制，只能靠系统级手段（虚拟机、独立用户/容器、备份与权限控制），
  而不是指望本程序。**用它造成的一切后果由使用者自行承担。**
- **会产生真实费用。** 请自行确认计费与配额，建议先用小会话和 `--max-chars` 观察。
- **数据库可能发生破坏性更新。** 项目仍在起步阶段，存储对话的数据库结构随时可能变动，
  且程序暂时不做迁移——版本不符时旧库不会被打开（数据原样保留，可手动备份），你可能
  读不到旧对话。**重要会话请自行备份 `skynet.db`**；如需迁移旧数据，建议把库文件与
  本项目源码一起交给 AI，请它写一个一次性转换脚本（Python 标准库的 `sqlite3` 最适合）。
- **提供商兼容性仅做了极有限实测。** 目前只实测过 **opencode-go** 网关，模型只实测过
  **deepseek-v4.1-flash**。内置的其他提供商预设（OpenAI、OpenRouter、DeepSeek 官方等）
  只是模板，**不保证可用**；其他模型对工具调用、缓存字段、思考强度参数的支持
  也不一致，可能出现报错、重复计费或行为异常。
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
./zig-out/bin/SkyNet.exe                                     # 启动 TUI（无参数）
./zig-out/bin/SkyNet.exe ask -new -title "随便聊聊" "你好"    # 无界面发送一轮对话
./zig-out/bin/SkyNet.exe help                                # 全部子命令与参数
```

首次启动自动生成 `config.json`（空配置）与 `skynet.db`（SQLite，WAL）。
第一次使用：TUI 里按 `Esc` → `models` → 底部「+ 添加提供商…」，填入 API 地址与密钥
（密钥也可留空、改填环境变量名）。

**完整参考见 [`docs/user-guide.md`](docs/user-guide.md)：**

- `config.json` 全部字段与 18 家内置预设、密钥解析顺序；
- TUI 指令与快捷键（`/help` `/models` `/sessions` `/compact` `/thinking`、鼠标操作）；
- CLI 子命令与参数（`ask` / `new` / `sessions` / `messages` / `stats` / `compact`）；
- 状态栏读数、`ambiguous_width` / `width_overrides`（调整 `①②③`、`—→` 等字符显示宽度）。

约定：CLI 的 stdout = 最终回答，stderr = 工具活动；退出码 0 成功 / 2 参数错误 /
3 无可用提供商或模型 / 4 请求或数据库失败。

## 已知限制

- prompt 缓存亲和、工具输出折叠、自动/手动压缩：**只是"尽量做了"，是否真正有效未经验证**。
  不要依赖它们带来的收益；边界情况下它们可能失效，甚至帮倒忙（压缩可能丢信息、折叠会使缓存暂时失效、缓存亲和可能完全不生效）
- 提供商预设基本未经实测（仅 opencode-go + deepseek-v4.1-flash 验证过）；
  其他模型对工具调用、缓存字段、思考强度参数的支持不一致，可能报错或行为异常
- 流式响应中途断开会被检测并**自动重试**（默认最多 2 次、指数退避；每次重试整请求重发，
  失败尝试的部分思考会被丢弃——输入侧靠前缀缓存几乎免费，输出侧会重算）。重试预算用尽仍
  失败时会提示"连接中断"，手动重发即可
- 工具没有确认环节、没有目录白名单，无法阻止通过绝对路径访问任意位置（见免责声明）
- **项目仍在实验阶段：数据库结构随时可能变动**——schema 版本不符时 TUI 会弹窗让你选择"重命名旧库并新建"或"退出"，CLI 子命令则直接报错；程序不自动迁移、不删除、不写入旧库
- 仅在 Windows + PowerShell 7 上做过日常验证

## 第三方组件

`libs/` 下是随仓库附带的第三方库，各自保留原许可证（均为 MIT）：

- `zigtui`：TUI 库，以 git submodule 引入（fork 的 `skynet` 分支，含本地修改）
- `fridge`：SQLite 绑定

## 参考与致谢

本项目的工具集设计仿照 [pi coding agent](https://github.com/earendil-works/pi)；
TUI 样式、工具输出折叠等上下文管理的部分规则参考了 [opencode](https://github.com/anomalyco/opencode)。

## 许可证

以 MIT 协议发布，详见 [LICENSE](LICENSE)。
