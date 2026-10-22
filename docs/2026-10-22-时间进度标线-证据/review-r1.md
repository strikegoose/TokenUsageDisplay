"glm-5.3" isn't described by this version's model catalog; update Claude Code, or map it with behavesAs on a modelPicker row (or modelOverrides, if it is a provider id of a model this version knows). Until then auto-compact keeps this session within 200k tokens (the context window it assumes); if the model accepts more, append [1m] to the model name for 1M, or set CLAUDE_CODE_MAX_CONTEXT_TOKENS to its real window; CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1 restores the previous wait-for-the-API behavior.
[claude-code:unrecognized_model] {"model":"glm-5.3","query_source":"sdk"}
We're changing auto mode to no longer charge for classifier requests in Claude Code. However, this session isn't eligible because your requests go through open.bigmodel.cn, which isn't compatible with this update. Nothing breaks: auto mode keeps working, and its classifier requests are billed as before. To fix it and access the new version of auto mode, ask your gateway to implement: https://code.claude.com/docs/en/auto-mode-classifier-billing
复审完成。以下按五项审查点逐条给出证据与判定。

# 复审报告：a35bdb7 时间进度标线（基线 c9d176d）

## 1. QuotaTimeProgress.fraction 边界 — 通过

`Sources/TokenUsageCore/QuotaTimeProgress.swift:8-12`：

```swift
guard duration.isFinite, duration > 0 else { return nil }
guard elapsed.isFinite else { return nil }
return min(1, max(0, elapsed / duration))
```

- duration 为 NaN/±Inf/0/负数：`isFinite` 与 `>0` 全拦下，返回 nil。elapsed 为 NaN/±Inf 同理（第二道 guard）。
- 钳位方向：上溢（now 已过 reset，elapsed > duration）由 `min(1,·)` 钳到 1；下溢（时钟回拨，elapsed < 0）由 `max(0,·)` 钳到 0。方向正确。
- 隐蔽溢出路径也安全：入参有限但 `elapsed/duration` 中间值溢出为 +Inf（duration 为极小正数）时，`min(1, Inf) = 1`，不外溢。0/极小 = 0，正常。
- 消费侧 `UsageData.timeProgress`（`Sources/Models/UsageData.swift:39-46`）要求 resetTime 与 windowDuration 双非 nil，余额类卡片（无 windowDuration）永远返回 nil。未见漏洞。

## 2. 各 provider windowDuration 口径 — 通过

**Kimi**（`Sources/Services/Providers/KimiProvider.swift`）：
- 周配额：`duration: 7 * 86400`（147 行）= 7 天 ✓。
- 滚动窗：`windowDuration()`（278-285 行）MINUTE×60 / HOUR×3600 / DAY×86400，未知 timeUnit → nil（不画线）。关键交叉验证：与**既有** `windowLabel`（297-307 行）对同一字段的解释一致——文件头注释（11 行）的实测样本 `duration:300, timeUnit:"TIME_UNIT_MINUTE"` 在老代码里解释为「300分钟 = 5小时窗口」（301 行 `duration / 60` 换算小时），新代码 300×60 = 18000s = 5h。**无分钟当秒错误**。
- 月配额（161-169 行）：`Calendar.current.date(byAdding: .month, value: -1, to: resetTime)` 即 reset−1 个日历月，符合口径。resetTime 为 nil → duration 为 nil；`parsed.resetTime!`（165 行）只会在 flatMap 闭包已确认非 nil 后的 map 里执行，安全。用本地时区日历月而非 UTC 属口径选择，非缺陷。
- 余额类：加油包余额（184-192 行）与月度加油包（201-209 行）均不传 resetTime/windowDuration → 无标线 ✓。

**智谱**（`Sources/Services/Providers/ZhipuProvider.swift:141-152`）：unit=3 → `number × 3600`（number 缺失或 ≤0 → nil）；unit=6 → `7 × 86400`；default → nil。与既有 `limitLabel`（124-132 行「unit=3 → N小时滚动窗；unit=6 → 周额度~7天」）口径一致。智谱仅有积分配额卡（95-108 行），无余额卡误传。反向安全也成立：windowDuration 有值而 resetTime 为 nil 时 `timeProgress` 仍为 nil。

**Cursor**（`Sources/Services/Providers/CursorProvider.swift:110-116`）：start、end 双可解析且 `end > start` 才有 cycleDuration，缺 billingCycleStart 或区间非正 → nil 不画线（注释明确）。四张卡（team/auto/api/ondemand，123-193 行）均为计费周期配额卡且带 resetTime，传入合理；Cursor 无余额类卡。

## 3. UsageProgressBar 渲染 — 通过

- `Sources/Views/Common/UsageProgressBar.swift:11`：`timeProgress: Double? = nil` 默认参数。全仓仅两个调用点（`ServiceCardView.swift:154`、`GroupedServiceCardView.swift:166`），均显式传 `snapshot.timeProgress`（snapshot 即 `UsageData` 本体，视图直接吃 `[UsageData]`）；不传者 → nil → 无标线、`TimeMarkerHelp` nil 分支裸返回 content（58-64 行）——**与旧行为逐像素一致**，help 也只在有标线时挂载（空串 help 会弹空气泡，注释已说明动机）。
- 位置公式（45 行）：`.position(x: geometry.size.width * timeProgress, y: height/2)`——position 定的是线**中心**，线中心落在 elapsed/duration 比例处，公式正确。init 里的二次钳位（15 行）与 fraction 的钳位重复但无害。
- 非阻塞观察：timeProgress 恰为 0 或 1 时，2pt 宽的线中心贴条边缘，会有 1pt 悬出进度条（ZStack 默认不裁剪）。纯视觉边角，不改变位置语义，不构成缺陷。

## 4. 禁区 — 无违规

- 用量口径：`usedAmount/totalAmount/usagePercentage` 的计算零改动（`quotaCard` 的 `max(window.limit, 1)`、Cursor 的 percent 派生逻辑原样）。
- 配色：`barColor`（`UsageProgressBar.swift:18-24`）未动。标线用 `Color.primary.opacity(0.9)` 并有注释说明不引入新色相——是需求本身的新增元素，不是改配色逻辑。
- UsageData：仅新增可选字段 `windowDuration`、计算属性 `timeProgress`、init 尾部默认参数（59-82 行）；既有字段语义未变。Codable 向后兼容：合成解码对 Optional 用 `decodeIfPresent`，旧缓存 JSON（`ConfigurationStore.swift:50,59` 读取）缺该键时解出 nil，不炸、无标线，降级方向正确。
- 无顺手重构：两个卡片视图各改一行传参；`TimeMarkerHelp` 是功能内聚的新增。

## 5. 自测假绿 — 无假绿

- `check`（`Tests/TokenUsageSelfTest/main.swift:7-13`）失败记入 `failures`，结尾非空则 `exit(1)`（212-218 行）——真失败语义。
- `timeProgressFractionClampsAndRejects`（137-152 行）在第 208 行被实际调用，断言打的是真实现（`import TokenUsageCore`，非复制体）。
- `== 0.2` 非恒真也非碰运气：3600/18000 的 IEEE754 正确舍入结果即 0.2 字面量的最近 Double，严格相等成立。
- 上/下溢、零/负/NaN duration 共 8 断言齐全，含负向控制（非法时长必须 nil）。
- 观察项（非假绿）：provider 侧的 `windowDuration(item.window)` 单位换算没有直接测试，覆盖缺口。

## 构建与运行验证

- 项目正式路径 `./build.sh`（release，回退 26.5 SDK）**构建通过**，.app 生成成功。
- `swift run TokenUsageSelfTest`：**33 checks passed**（含新增 9 条）。
- 裸 `swift build` 失败系 CLT 27 SDK 缺 SwiftUIMacros 插件的已知环境问题（`build.sh` 注释明说，且报错点多为本次 diff 未触碰文件的 `@State`），与本提交无关。

## 结论：CONVERGED

五项审查点全部通过，无阻塞性缺陷。两条非阻塞观察供后续参考：(1) 标线在 timeProgress 恰为 0/1 时有 1pt 悬边，属视觉边角；(2) Kimi `windowDuration` 的 timeUnit 换算逻辑缺直接单测覆盖（现有覆盖靠与 `windowLabel` 的口径一致性保障）。
