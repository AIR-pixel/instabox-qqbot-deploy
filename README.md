# instabox-qqbot-deploy

在 **InstaBox** 云主机上从零部署一套可常驻的 QQ 聊天机器人栈：真实 QQ 账号登录 + 大模型推理 + 人格与长期记忆 + 主动发言。

本仓库是**部署规程（runbook）+ 踩坑库 + 可直接执行的脚本**，不是一份通用框架文档。目标读者是 agent：读完就能在另一台机器上重放，不需要原始工程的上下文。

```
snowluma 容器 (真实 QQ + OneBot v11)  ←→  surfcore 桥 (宿主 systemd)  ←→  headless DSH Web (宿主 systemd, 127.0.0.1:3080)
```

## 快速判断要不要用这个仓库

| 你的情况 | 结论 |
|---|---|
| 把本机 Windows/NapCat 的 QQ 机器人整体搬到 Linux VPS | ✅ 正是本仓库 |
| 从零在 InstaBox 起一个「能登自己 QQ 的 AI」 | ✅ 直接走 `docs/03-runbook.md` |
| 只要把 LLM 接到 QQ，不需要人格/记忆/主动说话 | ⚠️ 上 SnowLuma + 简单 bot 就够了，别搬这套 |
| 要求严格 7×24 不间断 | ⚠️ 免费档做不到，先读 `docs/05-keepalive.md` |

## 阅读顺序

1. **`SKILL.md`** — agent 契约：阶段划分、每阶段的验收证据、7 条硬规矩。**先读这个。**
2. `docs/01-architecture.md` — 为什么这样切分（含源码级依据，解释"为什么不能改成容器名调 3080"这类问题）。
3. `docs/02-prerequisites.md` → `docs/03-runbook.md` — 照着做。
4. `docs/04-verification.md` — 怎么判定成功、失败往哪查。
5. `docs/06-pitfalls.md` — **本仓库最贵的部分**。20 条踩坑，每条带症状/根因/修法。
6. `docs/07-optional.md` — 哪些是锦上添花（B站分享、WorkBuddy 多账号、AstrBot 遗留），非必需。
7. `docs/08-facts.md` — 平台 API / 限额 / 状态机事实表，写实现时查。
8. `docs/09-full-walkthrough.md` — **全链路实录**：从本机到 VPS 到常驻，含传输、逐层配置、实测返回值与保活决策理由。想理解「为什么这么设计」读这个。

## 实测基线（这套流程验证过的形态）

- 平台：InstaBox Free（4 vCPU / 8 GiB / 20 GiB 固定盘）
- 系统：Debian 13 trixie，Docker 29.8.2 + Compose v5.6.0，Node v22.23.3
- 组件：`motricseven7/snowluma:latest`（2.4.0-node）+ `@deepseek-ai/dsh@0.2.1-rc.5` + `surfcore 0.8.8`（reserved2 模式）
- 验收：`healthcheck-b.sh` → `RESULT: PASS (fail=0)`，并观测到真实的「QQ 消息 → 推理 → QQ 回复」往返

## 目录

```
SKILL.md                  agent 契约（阶段/验收/硬规矩）
README.md                 本文件
docs/01-architecture.md   架构与取舍
docs/02-prerequisites.md  凭据、机器、限额
docs/03-runbook.md        分阶段可执行命令
docs/04-verification.md   验收与排障路由
docs/05-keepalive.md      免费档保活
docs/06-pitfalls.md       ★ 踩坑库
docs/07-optional.md       ★ 非必需组件
docs/08-facts.md          平台事实表
docs/09-full-walkthrough.md  全链路实录（含保活与上传流程）
scripts/                  healthcheck / postscan / 保活
config/                   配置模板（含占位符）
```

## 安全提示

本仓库所有配置文件里出现的 token / 口令 **都是占位样例**，部署时必须自己重新生成。
`config/.env.example` 明确标注了哪几项必须改。
