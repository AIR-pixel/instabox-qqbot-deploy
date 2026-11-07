# 08 平台事实表

> 全部来自实测（2026-11-05 至 11-07）与官方文档交叉验证。
> 写实现时查这里，不要凭印象。

## 8.1 API 基础

- Base：`https://api.instabox.sh`
- 鉴权：`X-API-Key: ibk_...` 或 `Authorization: Bearer ibk_...`
- key 形态：`ibk_` + 52 字符 `[a-z2-7]`
- 生命周期类端点**必须**带 `Idempotency-Key`（唯一串，保留 7 天）
- 错误按 `code` 分支：`rate_limited`（带 `retryAfterSeconds`）、`machine_cooldown`（带 `Retry-After` / `cooldownUntil`）、`idempotency_conflict`、`operation_conflict`

## 8.2 端点表

| 方法 | 路径 | 说明 | 实测 |
|---|---|---|---|
| GET | `/v1/machines` | 列表（**不会唤醒机器**） | 200 |
| GET | `/v1/machines/{id}` | 详情（**不会唤醒**） | 200 |
| GET | `/v1/machines/{id}/logs` | 日志（**不会唤醒**） | 200 |
| POST | `/v1/machines/{id}/wake` | 唤醒；最多等 45 秒 | 200 / 运行中 409 |
| GET | `/v1/machines/{id}/wake` | — | **404** |
| POST | `/v1/machines/{id}/suspend` | 需 `Idempotency-Key` | **202** + operation |
| POST | `/v1/machines/{id}/resume` | 需 `Idempotency-Key` | **202** + operation |
| POST | `/v1/machines/{id}/start` | 需 `Idempotency-Key` | 从 stopped 起 |
| GET | `/v1/machines/{id}/operations` | — | **404 无此端点** |
| PUT | `/v1/machines/{id}/activity-leases/{taskId}` | body `{"ttlSeconds":300}`（30–3600） | 200 |
| DELETE | `/v1/machines/{id}/activity-leases/{taskId}` | 释放 | **204** |
| PATCH | `/v1/machines/{id}` | 改配置 | Free 改 `autoSuspendAfterSeconds` **失败且错误体为空** |
| GET | `/v1/auth/agent/token` | — | 404（只支持 POST） |

## 8.3 机器对象字段

```
id, name, desiredState, state, revision, operationId, template, spec,
storage, runtime, autoSuspendAfterSeconds, maxRunMinutes, runStartedAt,
readyAt, cooldownUntil, metadata, vault, guestUser, orgId, free,
oomKills, createdAt, updatedAt
```

`runtime` 子对象：`ready`（bool）、`processesPreserved`（bool）。

## 8.4 状态机

| 状态 | 内存 | 进程 | 磁盘 | 计费 |
|---|---|---|---|---|
| Running | 保留 | 保留 | 保留 | 是 |
| Paused | **保留** | **保留** | 保留 | 否 |
| Stopped | 丢 | 丢 | 保留 | 否（只收磁盘） |
| Deleted | 丢 | 丢 | 丢 | — |

- **暂停的机器不能 stop**
- 生命周期调用返回 **202 + operation**，需轮询到 `succeeded` / `failed`
- `restart`（recover）= 断电重启；`restore`（快照回滚）= 丢快照后磁盘改动 + **SSH host key 变化**
- guest 内 `sudo poweroff` → Stopped；`sudo reboot` → 同盘重启
- 10 分钟内重启超 5 次 → 会被留作 stopped

## 8.5 空闲暂停（auto-pause）

| 项 | 值 |
|---|---|
| Free 档空闲阈值 | **30 分钟，不可改** |
| 付费档可调 | 5–30 分钟，或 0 关闭 |
| "work" 判定 | agent 在干活 / terminal·SSH 流量 / CPU 负载 / exec / 读文件 / 请求 public port / task lease |
| **不算 work** | 列机器、读机器详情、读日志 |
| 唤醒方式 | exec / 读文件 / SSH / dashboard terminal·files·desktop / 请求 public port / `POST /wake` |
| wake 最长等待 | 45 秒；仍运行则 `409 operation_conflict` |
| 手动 pause/stop 的机器 | 用不会唤醒，必须 `resume` / `start` |

## 8.6 max-run 与 dynamic runtime

- `maxRunMinutes` 到点**立刻 pause，即使正忙**；activity lease **不能**延长
- **读数会变**：同一台机不同时刻读到 120 / 480 都出现过 → 以实时 JSON 为准
- Free 档 dynamic runtime：每次新 run 起 **2 小时**窗口，到期前 5 分钟检查**前 30 个完整分钟**：
  - ≥ 5 个不同分钟有 work → 续 **2 小时**
  - 1–4 个 → 续 **30 分钟**
  - 0 个 → 到点 pause
- 原文：*"Renewing a keepalive lease or requesting a wake does not earn an extension."*
- 采集不到活动时该 run 改用 **8 小时**上限（从 run 开始算）
- 任何 run 连续工作最长 **8 小时**

## 8.7 冷却

| 触发 | 冷却 |
|---|---|
| 空闲暂停 | **0** |
| max-run 第 1 次 | 5–20 分钟 |
| max-run 第 2 次 | 60–75 分钟 |
| max-run 第 3 次+ | 120–135 分钟 |
| 安全审查锁 | 不算 max-run 一步，但**最长 24 小时**；算冷却、保留计数 |

- 基础冷却 5 分钟 + 随机 0–15
- 连击计数归零：run 以无冷却欠账方式结束（空闲暂停 / 主动 pause·stop）；或新 run 在上次冷却结束 ≥ 2 小时后开始
- 冷却期内任何唤醒/启动 → `409 machine_cooldown`

## 8.8 Free 档限额

| 项 | 值 |
|---|---|
| 机器数 | 1 |
| 同时 running | 1 |
| 规格 | 4 vCPU / 8 GiB |
| 磁盘 | 20 GiB **固定**（不可扩） |
| 快照 | 5 |
| 出口流量 | 100 GiB / 月 |
| 成员 | 3 |
| **Starts/minute** | **3**（create / start / resume / wake 都算，超了 `429 rate_limited`） |

## 8.9 定价（对照，用于建议用户升档）

| 档 | 月费 | 关键差异 |
|---|---|---|
| Free | $0 | 见 8.8 |
| Pro | $20 + 用量（含 $20 credits） | 100 台并发、8 vCPU/16 GiB、盘至 200 GiB、无限快照、1 TiB 出口 |
| Builder | $100 | — |
| Team | $500 | — |

单价：vCPU `$0.004/vCPU-hour`、Memory `$0.00225/GiB-hour`、Storage `$0.00011/GiB-hour`、Egress `$0.02/GiB`。
暂停/停止只收磁盘费；超额磁盘 `$0.08/GiB-month`。

## 8.10 模板与限制

- 可用模板：`agent-browser` / `android` / `ci`
- **不能自选 Debian 版本**，实测拿到 Debian 13 trixie
- 单文件上传上限 5 GiB（`instabox push`）
- 上传会分块（`.instabox-upload-*`），大包耗时长（612 MiB 约 10 分钟）

## 8.11 官方文档索引

- 空闲暂停：`https://instabox.sh/docs/machines/auto-pause.md`
- 生命周期：`https://instabox.sh/docs/machines/lifecycle.md`
- 定价：`https://instabox.sh/docs/account/pricing.md`
- 限额：`https://instabox.sh/docs/account/limits.md`
- API 通则：`https://instabox.sh/docs/api.md`
- Agent 授权：`https://instabox.sh/docs/agent-auth.md`
