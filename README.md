# TokenUsageDisplay

macOS 状态栏小工具：把 Kimi / DeepSeek / 火山方舟的额度钉在状态栏上，快用完时一眼可见。

<!-- 截图：将图片放到 docs/images/ 后取消下面这行的注释 -->
<!-- ![状态栏与面板截图](docs/images/screenshot.png) -->

## 功能

- **状态栏一眼可见**：圆点 + 已用百分比；用量超 80% 变橙、超 95% 变红，健康时保持低调的黑白
- **Kimi Coding Plan**：自动复用 kimi CLI 的本地登录态（OAuth），零配置开箱即用；周配额 / 滚动窗口 / 月配额 / 加油包多窗口分组展示，按重置时间排序；状态栏百分比优先显示"最先咬人"的短窗口
- **DeepSeek**：账户余额监控；可手动填 API Key，也能自动从 Claude Code 的配置里识别
- **火山方舟 ARK**：账户余额；支持手动 AK/SK，也能自动复用 arkcli SSO 登录的 STS 临时凭证（临期自动续签）
- **Cmd+Shift+T** 全局热键呼出浮动面板（Carbon 热键，无需辅助功能权限）
- 自动刷新（1 分钟 ~ 1 小时可调）、开机自启动、全中文界面

## 系统要求

- macOS 14.0+
- Swift 5.9+ 工具链（安装 Xcode Command Line Tools 即可，不需要完整 Xcode）

## 构建与运行

```bash
./build.sh
open TokenUsageDisplay.app
```

构建产物是项目根目录下的 `TokenUsageDisplay.app`（ad-hoc 签名，首次打开如遇 Gatekeeper 提示，在 系统设置 → 隐私与安全性 中允许即可）。纯 SwiftPM，零第三方依赖，没有 Xcode 工程文件。

## 使用

首次启动会自动检测本机已有的登录态（kimi CLI / Claude Code / arkcli），检测到的服务开箱即用。点击状态栏图标 → 设置 → 服务，可手动添加/编辑服务、测试连接。

## 数据安全

- 所有配置与凭证只保存在本机 `~/.config/tokenusage/`，密钥文件权限 0600
- Kimi 复用 `~/.kimi-code/` 的 OAuth token；火山方舟复用 `~/.arkcli/` 的 STS 临时凭证——均为本地只读复用
- 网络请求只发往各服务官方 API，无任何第三方上报

## License

[MIT](LICENSE)
