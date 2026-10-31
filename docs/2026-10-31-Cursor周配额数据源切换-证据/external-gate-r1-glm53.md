# 异构外门复审 r1（Claude Code + GLM-5.3，2026-10-31）

审查对象：工作区未提交改动（git diff HEAD -- Sources Tests），基线 b717fc9。
说明：输出经 tail -25 截断，以下为收到的结论部分（含全部五项判定与 VERDICT）。

- 401 场景不被掩盖：weekly 401 → nil → legacy 401 → `reauthRequired` 正常抛出。

## 3) percent/100 口径与渲染一致 — 通过

- `usagePercentage = percent/100 ∈ [0,1]`，与旧 API 池卡片（同样是 percent/100，CursorProvider.swift:179-189）同构；进度条、状态色阈值（80%/95%）、`formattedPercentage` 全部基于该比例，实测 10.46% 显示 "10%"，与官方一致。
- `usedAmount=10.46` 的小数原值不会以 "10.46 %" 裸露：Cursor 卡片详情行走 `formattedPercentage`（ServiceCardView.swift:167），`formattedUsed` 仅在 `isUnlimited` 分支使用，周配额卡片不会进入。

## 4) 时间标线 windowDuration — 通过

- `reset - start` 实测恰好 7 天（两端同为 23:33:34.774Z，自测断言 <1s 误差）；`timeProgress` 以 `reset - duration` 还原 `windowStart = periodStart`（UsageData.swift:40-47），`QuotaTimeProgress.fraction` 钳制无越界。
- 重置时刻 11-06T23:33Z 按本地时区（UTC+8）显示 11-07 07:33，与官方 "Resets Nov 7" 吻合。

## 5) 生产风险 — 两处知情项，不阻塞

- **回落方向的数据新鲜度**：新计费账户若 weekly 端点瞬时失败而 usage-summary 可用，会短暂显示过时月度数据（标注"Auto 池"）而非报错。这是本次明示的设计取舍，可接受，但属已知误导窗口。
- **旧账户多一次串行请求**：legacy/team 账户每次刷新先打 weekly 端点（timeout 30s），端点悬挂时刷新最多多等 30s。正常情况无感。
- 次要确认项均无问题：`#auto`→`#weekly` 切换由 ServiceManager.swift:150-156 剪枝并同步清磁盘缓存，无残留卡片；`poolLabel` 为 optional，旧缓存经 decodeIfPresent 向后兼容。

**备注**：任务描述称新增 17 项自测，实际 `check()` 断言为 15 处（4+4+5+2，含 2 处失败分支守护断言）——计数出入，非代码缺陷。

---

## VERDICT: PASS

五项检查全部通过；两处知情项（回落窗口的过时数据、旧账户串行请求延迟）建议在提交信息或文档中注明，不构成阻塞。
