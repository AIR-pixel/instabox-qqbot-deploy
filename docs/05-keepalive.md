# 05 免费档保活

## 5.1 先接受一个事实

**InstaBox Free 档做不到 7×24 零中断。** 这不是配置问题，是平台语义。

可选的三条路：

| 路线 | 效果 | 代价 |
|---|---|---|
| A. 接受周期性离线 | 每轮在线 ~85 分钟，之后短暂离线 | 空闲时段消息会漏 |
| B. 升付费档 | 可调 `autoSuspendAfterSeconds`（5–30 分钟或 0 关闭） | $20/月起 |
| C. 本机常驻 | 完全可控 | 违背"全搬上云"的初衷 |

本仓库给的是 **A** 的可行实现，并把它做干净。

## 5.2 平台到底怎么算

三层限制同时生效（细节见 `docs/08-facts.md`）：

### ① 空闲暂停

running 且 30 分钟没有任何 "work" → 自动 pause（保留内存 + 进程，不计费）。

"work" 的判定：有 agent 在干活 / 有 terminal·SSH 流量 / 有 CPU 负载 / exec / 读文件 / 请求 public port / 有 task lease。
**列机器、读机器详情、读日志都不算**（所以探活不能靠 GET）。

唤醒方式：exec / 读文件 / SSH / dashboard 的 terminal·files·desktop / **请求它的 public port** / `POST /wake`。

### ② max-run

`maxRunMinutes` 到点**立刻 pause，哪怕机器正忙**。activity lease **不能**延长它。

### ③ Free 档 dynamic runtime

每次新 run 起一个 2 小时窗口。到期前 5 分钟检查**前 30 个完整分钟里有几分钟真在干活**：

- ≥ 5 分钟有活 → 续 2 小时
- 1–4 分钟 → 续 30 分钟
- 0 分钟 → 到点 pause

原文明确：**"Renewing a keepalive lease or requesting a wake does not earn an extension."**

## 5.3 冷却机制（为什么"高频唤醒"是最差解）

| 暂停类型 | 冷却 |
|---|---|
| 空闲暂停（30 分钟没活） | **零冷却** |
| max-run 暂停，第 1 次 | 5–20 分钟 |
| max-run 暂停，第 2 次 | 60–75 分钟 |
| max-run 暂停，第 3 次及以后 | 120–135 分钟 |

连击计数归零条件：

- run **以无冷却欠账的方式结束**（= 空闲暂停，或你主动 pause/stop）
- 新 run 在上次冷却结束 **≥ 2 小时**后开始

冷却期内任何唤醒/启动都回 `409 machine_cooldown`，带 `Retry-After`。

### 由此推出的正确策略

**高频 wake（比如每 15 分钟）= 主动作死**：

1. wake 不算 work，续不了 2 小时窗口；
2. 持续唤醒又让机器**永远走不到空闲暂停**，于是必然撞 max-run；
3. 撞 max-run → 冷却 5–20 → 60–75 → 120–135 递增，越来越差。

**正确做法：主动 `suspend` 再 `resume`。**

原理：`suspend` 是你主动结束 run，**零冷却、计数归零**；`resume` 起来是一个全新 run，`maxRunMinutes` 重新计时。

每轮循环让 run 只活 **85 分钟**：

```
85 min 在线  <  120 min（2 小时窗口）    ← 走不到 dynamic runtime 的判定点
85 min 在线  <  maxRunMinutes（120/480）  ← 也走不到 max-run
```

两条硬线都够不着，于是永远不会进冷却。

## 5.4 实现

`scripts/keepalive-cycle.ps1`（Windows 操作端）：

```
GET  /v1/machines/<ID>            读 state
  ├─ state != running  → POST /resume（带 Idempotency-Key）
  └─ state == running  → POST /suspend  → sleep 20s → POST /resume
                           └ 409 machine_cooldown → 本轮跳过，不重试
结束后 6×10s 轮询确认 state 收敛回 running
```

`suspend` 期间的那 20 秒，内存与进程都保留（Paused 状态），QQ 不掉线、DSH 不重载。
客户端看到的是"20 秒没回话"，不是"掉线"。

注册（每 85 分钟）：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-task.ps1 -Mode cycle -IntervalMinutes 85
```

## 5.5 为什么是 85 而不是 30 或 120

- **< 30**：太密，白白损失在线比例，且 `Starts/minute = 3` 虽然够用但没必要消耗。
- **85**：在线比例最高（85/105 ≈ 81%），且安全落在 120 分钟窗口内，留 35 分钟余量给"平台把 maxRunMinutes 读成 120"的情况。
- **> 110**：一旦平台读数是 120，你有较大概率在下一轮之前就撞上 dynamic runtime 的 5 分钟检查点（如果那半小时里没活的话会被 pause）。

## 5.6 代价与局限

| 问题 | 说明 |
|---|---|
| 消息漏失 | 20 秒暂停窗口内进来的消息，靠 SnowLuma 的历史补发；补不回来的（如群聊他人发言）就丢了 |
| 保活进程必须在外部 | 计划任务跑在操作端 PC 上。PC 关机 = 不保活 |
| 依赖 API key | key 失效则保活停摆，机器会在 30 分钟后自然睡 |
| 不解决 24h 安全锁 | 平台触发安全审查时最长锁 24 小时，此方案无能为力 |

## 5.7 外部平台托管版

若不想依赖本机 PC，可以把同一条 `curl` 序列交给支持定时 HTTP 的平台。
任务描述只需一段话：

> 每 85 分钟执行：① `POST https://api.instabox.sh/v1/machines/<ID>/suspend`，
> 头 `X-API-Key: <KEY>` + `Idempotency-Key: <每次新 UUID>`；② 等 20 秒；
> ③ 同路径 `/resume`，另一个新 UUID；④ `GET /v1/machines/<ID>` 确认 `state=="running"`。
> 409 `machine_cooldown` 直接跳过本轮，不重试。禁止高频调用 `GET`（会被当探活滥用）。

**注意**：部分平台会以"规避用量限制"为由拒绝这类任务。
如果被拒，走 A 路线的替代实现（本机计划任务）或直接建议用户升付费档。

## 5.8 只想要"尽力在线"的最简版

如果连 suspend/resume 都不想配，最低限度做一件事：**每 25 分钟产生一次真 work**。

```bash
# 在目标机上，靠 cron 每 25 分钟跑一次真实计算
*/25 * * * * /usr/bin/timeout 20 /bin/sh -c 'find /data/qqbot -type f -name "*.log" | head -2000 | wc -l' >/dev/null
```

这能躲过"30 分钟空闲"，但躲不过 max-run 与 dynamic runtime —— 最终仍会周期性 pause。
**不推荐**，仅在用户明确说"随便，能响就行"时用。

## 5.9 验证保活真的在工作

```bash
# 连续观测 runStartedAt 是否在变
watch -n 60 'curl -s -H "X-API-Key: $KEY" \
  https://api.instabox.sh/v1/machines/<ID> | jq -r ".state, .runStartedAt, .cooldownUntil"'
```

合格的形态：`runStartedAt` 每 ~85 分钟跳一次，`cooldownUntil` 始终是过去时间。
若看到 `cooldownUntil` 在未来 → 已经在冷却里，说明有别的路径撞了 max-run，查是否有别的东西在 wake。
