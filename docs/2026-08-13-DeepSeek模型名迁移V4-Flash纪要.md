# DeepSeek 模型名迁移 V4-Flash 纪要

- 讨论时间:2026-08-13 11:54–11:57(CST)
- 讨论所用模型/工具:Kimi Code CLI,用户本机 macOS,工作目录 `/Users/newgoose/aihq/apps/TokenUsageDisplay`
- 原文回溯路径:`/Users/newgoose/.kimi-code/sessions/wd_tokenusagedisplay_89d05b6d4516/session_946c6a5f-88e4-4bc0-9e9e-fade6785999a/agents/main/wire.jsonl`(用 Grep 按关键词搜此文件可找回原话)

## 背景

用户反馈:App 的 Claude Code 供应商切换(类 CC Switch)功能里,DeepSeek profile 显示的模型还是 `deepseek-chat`,听说 DeepSeek 已公告弃用该名称,要求确认应显示 V4 Pro 还是 V4 Flash 并改正。

## 调研结论

- DeepSeek 官方公告:`deepseek-chat` 与 `deepseek-reasoner` 两个旧模型名已于 **2026-07-24 23:59(北京时间)弃用**,二者分别映射到 `deepseek-v4-flash` 的非思考 / 思考模式(见 [DeepSeek API 更新日志](https://api-docs.deepseek.com/zh-cn/updates/))。
- V4 系列 2026-04-24 发布:V4-Pro(1.6T 总参数,旗舰)/ V4-Flash(284B,高性价比);2026-07-31 V4-Flash 正式版 API 上线公测,V4-Pro 正式版仍未发布。
- **决策:旧 `deepseek-chat` 的迁移目标是 `deepseek-v4-flash`,不是 V4 Pro**。想要 Pro 的用户可在设置里手动加 profile。

## 改动

- `Sources/Services/CCConfigSwitcher.swift`:
  - 新增 `deepseekDefaultModel = "deepseek-v4-flash"`,默认 profile 播种改用该值。
  - 新增 `migrateDeprecatedDeepSeekModels()`:启动时把已存 profiles(含 Sonnet/Opus/Haiku 分档)和 live `~/.claude/settings.json` 里的 `deepseek-chat`/`deepseek-reasoner` 原地改写为 `deepseek-v4-flash`,幂等。旧名在 API 侧已完全不可用,故直接改写不询问。
- 构建验证:`./build.sh` 通过(曾遇 `.build` 模块缓存残留旧路径报错,删 `.build` 后重新构建成功)。

## 待办

- 无。若日后 V4-Pro 正式版发布,可考虑在默认 profiles 中增加 Pro 选项。

## 追加(2026-08-13 12:04):默认模型改为 V4 Pro

- 用户反馈:官方 V4 是 Pro/Flash 双模型设计,只给 Flash 与官方设计不一致;Claude Code `/model` 里 Default 及各档都是 Flash,要求默认设为 V4 Pro。
- 复查官方文档:`deepseek-v4-pro` 正式版(DeepSeek-V4-Pro-0813)恰于 2026-08-13 当天上线,输入 3 元/输出 6 元每百万 tokens,约为 Flash 的 3 倍(见 [DeepSeek 定价页](https://api-docs.deepseek.com/zh-cn/quick_start/pricing))。
- **决策修正:DeepSeek profile 默认模型由 `deepseek-v4-flash` 改为 `deepseek-v4-pro`**(覆盖上文"迁移目标是 Flash"的结论;弃用名迁移也直接落到 Pro)。Flash 仍可在设置里手动加 profile 使用。
- 改动:`deepseekDefaultModel` 改为 `deepseek-v4-pro`;用户现有 profile(含三个分档)与 live settings.json 已一次性改为 Pro。构建通过,App 已重启验证(profile 与 settings.json 均显示 `deepseek-v4-pro`)。

## 追加(2026-08-13 12:08):Haiku 档指向 V4 Flash

- 用户指令:默认保持 V4 Pro 没问题,但选择模型时也要有 Flash 可选——把 Claude Code 的 **Haiku 档** 映射为 `deepseek-v4-flash`。
- 改动:新增 `deepseekFastModel = "deepseek-v4-flash"`;默认 DeepSeek profile 播种时 `haikuModel` 用 Flash(其余档随默认 Pro);用户现有 profile 与 live settings.json 的 `ANTHROPIC_DEFAULT_HAIKU_MODEL` 已改为 `deepseek-v4-flash`。构建通过,App 已重启验证。
- 效果:Claude Code `/model` 中 Default/Sonnet/Opus = V4 Pro,Haiku = V4 Flash(省钱选项)。
