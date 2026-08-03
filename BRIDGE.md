# BRIDGE — TokenUsageDisplay

> **读者**：Claude Code（CC）、Cursor、创始人  
> **用途**：跨 Agent 交接黑板。开工先读；收工回贴「实现方回复区」。  
> **最后更新**：2026-08-04 02:30（Cursor · 公开仓隐私治理交接）

---

## 一、当前状态（一句话）

公开仓隐私治理的**代码/文档改动已完成本地提交** `efc9235`，**尚未推到 GitHub**（本机代理未开，Cursor 推送超时）。请 CC **优先 `git push`**，再按需处理下方可选跟进。

---

## 二、Cursor 已完成

| 项 | 结果 | 证据 |
|----|------|------|
| 公开仓密钥扫描 | ✅ 当前文件 + 全历史 + Release `v1.0.0` 二进制均无真实 AK/SK | 会话审核；仓库仍为 PUBLIC |
| README 措辞 | ✅ 「加密存于本地」→「明文文件 + 权限 0600」；注明截图为演示数据 | `README.md` |
| `.gitignore` | ✅ 增补 `.env` / `.env.*` / `*.pem` / `*.key` / `*.p12` / `*.pfx` | `.gitignore` |
| 截图打码 | ✅ `docs/images/screenshot.png` 余额/用量/重置时间改为演示值（¥12.34 / ¥56.78、18%/32%、假日期），进度条同步 | 同文件；OCR 已复核无 `¥58.46`/`¥98.40` |
| 本地提交 | ✅ `efc9235` `docs: 打码 README 截图并修正密钥存储说明` | `git log -1` |
| 推送 GitHub | ❌ 失败 | `origin/main` **ahead 1**；代理 `127.0.0.1:15236` 当时未监听 |

### 相关前序结论（未改代码，供 CC 知情）

- 阿里云余额卡功能代码在 `852e4de`，已在远程；密钥仅本机 `~/.config/tokenusage/keys/`（0600），不在 git。
- kimicode AccessKey 与 `~/.aliyun/config.json` 共用；聊天记录出现过 AK 前缀 → **建议择机轮换**（见可选任务）。
- git 历史早期 commit 仍暴露个人 Gmail、显示名，以及本机 `.local` 邮箱（`git log` / GitHub commit API 可读）。**改写历史需创始人明确授权**，默认不要 force-push。

---

## 三、请 CC 跟进（按优先级）

### P0 — 必须

1. **确认代理可用后推送**
   ```bash
   cd ~/Claude/personal/TokenUsageDisplay
   git status -sb          # 期望：ahead 1，working tree clean
   git push origin HEAD    # 默认走 origin=GitHub；勿绕过代理
   git status -sb          # 期望：与 origin/main 同步
   ```
2. 推送成功后，在本文「实现方回复区」回贴：commit SHA、远程是否已含打码截图。

### P1 — 建议（不阻塞推送）

3. **轮换阿里云 kimicode AccessKey**（密钥曾出现在对话/本机明文文件）  
   - RAM 新建 Key → 更新 `~/.aliyun/config.json` 与 TokenUsage 对应 `.key` → 禁用旧 Key  
   - 勿把新 Key 写进仓库或 Bridge 正文
4. （可选）若创始人要求擦除历史邮箱：再做 `git filter-repo` / 等效重写 + force-push；**未授权前不要做**。

### 不要做

- 不要把 `~/.config/tokenusage/**`、`~/.aliyun/config.json`、任何 `.key` / `.env` 提交进仓  
- 不要为「看起来更密」把明文 key 文件改称加密却不改代码语义而不更新 README  
- 不要在未授权时 rewrite `main` 历史

---

## 四、给创始人转 CC 的一句话（≤100 字）

> 读 `personal/TokenUsageDisplay/BRIDGE.md`：本地 `efc9235` 待推 GitHub；代理起来后 `git push origin HEAD`，回贴实现方回复区。可选：轮换 kimicode AK。

---

## 实现方回复区（CC 回贴）

> （推送结果 / 可选任务进度写这里）
