# Cursor 周配额数据源切换（Pstack-lite）

日期：2026-10-31 · 基线 `b717fc9` · 触发：创始人升级 Cursor 套餐后 App 显示与官方后台不一致

## §1 下单五件套

【Goal】Cursor 卡片显示的用量百分比与重置时间，与官方 cursor.com/dashboard/usage 页面一致（升级新套餐后显示"周配额 已用 10%、11-07 07:33 后重置"）。

【Done check】
1. 新接口 `GET /api/dashboard/v2/usage-status?scope=user` 实测返回 200 且 `weeklyIncludedUsage.usedCents/budgetCents = 483/4615`、`resetsAt = 2026-11-06T23:33:34Z`（curl 复现）；
2. `CursorWeeklyUsageParser` 对真实响应解析出 percent≈10.46、窗口恰 7 天（自测）；
3. 非 metered/畸形 JSON/零预算/负数/reset≤start/缺 usage 块 → 一律 nil 回落 legacy（negative-control 自测）；
4. 超耗 clamp 到 100（自测）；
5. 全量自测 56 项通过（新增 15 项断言，外门备注已核对）；
6. release 构建成功、程序重启运行（PID 证据）。

【禁区】不改 legacy usage-summary 的既有解析；不动其他服务；禁止把"编译通过"当完成。

【回单】§四 七字段。

## §3 Feature map

| 编号 | 内容 | done check |
|---|---|---|
| F1 | TokenUsageCore 新增 CursorWeeklyUsageParser（含 negative-control） | Done check 2/3/4 |
| F2 | CursorProvider 新端点优先、legacy 回落 | Done check 1 + 全量回归 |
| F3 | UsageData.poolLabel + ServiceCardView 标签 | 视觉核对（用户侧） |

## 红绿闸

- **红**：`docs/2026-10-31-Cursor周配额数据源切换-证据/red-gate-at-b717fc9.txt` — 旧 HEAD 编译失败 `cannot find 'CursorWeeklyUsageParser' in scope`
- **绿**：`docs/2026-10-31-Cursor周配额数据源切换-证据/green-gate.txt` — `TokenUsageSelfTest: 56 checks passed`
- 部署：`deployed-binary-sha256.txt` = `eb4d1746…`，重启后 PID 16212（14:07:46）

## 数据源事实（2026-10-31 实测）

- 旧接口 `/api/usage-summary`（pro 账户时代沿用）：对新 premium 账户返回过时口径 —— 月度周期 10-01→11-01、used 0/limit 4615、0%。**已不再对应官方页面显示**。
- 新接口 `/api/dashboard/v2/usage-status?scope=user`：`availability=available`、`weeklyIncludedStatus.status=metered`、`weeklyIncludedUsage{usedCents:483, budgetCents:4615, periodStart:2026-10-30T23:33:34Z, resetsAt:2026-11-06T23:33:34Z}`、`monthlyUsage{usedCents:0, limitCents:null}`（limitCents 为 null，不渲染月度卡）。
- 官方页面显示 "10% used / Resets Nov 7"（= resetsAt 北京 11-07 07:33，页面按日期舍入）。Web 会话需三跳 bootstrap 种 cookie，但 **API 侧仅凭 WorkosCursorSessionToken 即可直连**（0.85s 实测，首调可能冷启动 ~15s，App 超时设 30s）。

## §四 七字段回单

【Goal】复述：Cursor 卡片数字与官方仪表盘一致（周配额 10%、11-07 07:33 重置）。

【Done check】
1. pass — curl 新接口 200，483/4615/周期字段与官方页面一致（会话记录）
2. pass — 自测 `weekly percent 10.46` / `weekly window is 7 days`（green-gate.txt）
3. pass — 9 项 negative-control 全拦（not_applicable/unavailable/identity_unlinked/garbage/零预算/负数/reset≤start/bad-date/缺 usage 块）
4. pass — `weekly caps at 100%`
5. pass — `56 checks passed`（green-gate.txt）
6. pass — release 构建 ✅、PID 16212

【Commands】
$ ./test.sh（红/绿两轮）
$ ./build.sh && pkill -x TokenUsageDisplay; open TokenUsageDisplay.app
$ curl "https://cursor.com/api/dashboard/v2/usage-status?scope=user" -H "Cookie: WorkosCursorSessionToken=…"

【Observed】红闸编译失败留证；绿闸 56/56；curl http=200 bytes=403 time=0.85s，JSON 与官方页面 10%/Nov 7 一致。

【Artifacts】
- docs/2026-10-31-Cursor周配额数据源切换-证据/red-gate-at-b717fc9.txt
- docs/2026-10-31-Cursor周配额数据源切换-证据/green-gate.txt
- docs/2026-10-31-Cursor周配额数据源切换-证据/deployed-binary-sha256.txt
- knowledge/纪要/2026-10-31-TokenUsageDisplay-Cursor订阅更新后展示核查.md（含修正）

【Cleanup】/tmp 下 cookie/jar/JS/截图临时文件已清；无残留进程。

【Residual risk】
- 新接口偶发冷启动慢（实测一次 ~15s），App 超时 30s，失败回落 legacy（显示旧口径）——若回落发生会看到"Auto 池"标签+11-01，属已知降级形态
- monthlyUsage（limitCents=null）暂不渲染；若 Cursor 后续给月度限额可加第二张卡
- 周窗口按 resetsAt-periodStart 精确推导，无近似

## 外门

**r1（Claude Code + GLM-5.3）：VERDICT PASS**，报告见 `证据/external-gate-r1-glm53.md`。两项非阻塞知情项已记入 Residual risk（回落窗口短暂显示旧口径；legacy 账户刷新多一次串行请求）。
