---
name: instabox-qqbot-deploy
description: 在 InstaBox 云主机（Free 档可跑）上从零部署一套 QQ 聊天机器人栈：SnowLuma 容器承载真实 QQ 账号 + 宿主 systemd 跑 headless DSH Web 作推理后端 + SurfCore 桥做 OneBot↔DSH 编排。适用于「把本机 Windows QQ 机器人整体搬到 Linux VPS」「在云端起一个能收发 QQ 消息、带人格与记忆的 AI 账号」这类任务。内含可直接执行的部署 runbook、验收判定、免费档保活方案，以及 20+ 条已踩过的坑（每条都带症状/根因/修法）。
---

# InstaBox QQ 机器人云端部署

本 skill 是把一套**已在生产跑通**的 QQ 机器人栈部署流程固化成 agent 可执行的形态。
读它的人（或 agent）应当能在**没有原始工程上下文**的情况下，把整套东西在另一台 InstaBox 机器上重放出来。

## 0. 这套东西是什么

```
                    ┌──────────── 宿主网络命名空间 (127.0.0.1) ────────────┐
snowluma 容器        │  dsh-web.service (systemd)    surfcore-bridge.service  │
真实 QQ + OneBot v11 │  @deepseek-ai/dsh  headless    surfcore reserved2 桥   │
 3000(HTTP)          │  web --host 127.0.0.1:3080    node src/bridge.js        │
 3001(WS)   ◄────────┤        ▲ 回环 HMAC Cookie 鉴权（共享 .credentials.yaml）│
 容器内网，不 publish │        └──────── DSH_WEB_URL=http://127.0.0.1:3080 ────┘
                     └────────────────────────────────────────────────────────┘
```

三个角色：

| 角色 | 形态 | 职责 | 必需 |
|---|---|---|---|
| **SnowLuma** | Docker 容器 | 注入真实 QQ 客户端，扫码登录，暴露 OneBot v11 HTTP/WS | 是 |
| **DSH Web** | 宿主 systemd | 推理与 agent 运行时；提供 OpenAI/ACP 风格接口 | 是 |
| **SurfCore 桥** | 宿主 systemd | 消费 OneBot 事件 → 唤醒 DSH 会话 → 把回复发回 QQ | 是 |
| AstrBot | Docker 容器 | 另一套 bot 框架（本方案弃用，仅历史遗留） | 否 |
| dsh-llm-gateway | Docker 容器 | DSH 凭据转 DeepSeek API 的中转（本方案弃用） | 否 |

**关键约束（第一优先级，别试图改）**：DSH Web 与 SurfCore 桥**必须同网络命名空间、且 baseUrl 走回环 `127.0.0.1`**。
理由：SurfCore 的 `dsh-client.js` 只在 `isLoopbackBase()` 成立时才会用共享凭据离线铸造 `dsh-auth-*` Cookie；
换成 `http://dsh-web:3080` 这种容器服务名会直接失败。详见 `docs/01-architecture.md`。

## 1. 什么时候用 / 不用

用：
- 用户要把本机 Windows（NapCat + QQNT 挂钩）的 QQ 机器人迁到 Linux 云端常驻。
- 用户要一个「能登自己的 QQ、带人格与长期记忆、会主动说话」的 AI 账号，且愿意在云主机上跑。
- 需要在 InstaBox 上从零复刻一套已验证的栈。

不用 / 先问清楚：
- 目标平台不是 InstaBox（但 `docs/08-facts.md` 的平台语义可作为同类平台对照）。
- 用户只是想接一个 LLM 到 QQ，不需要人格/记忆/主动行为 → 直接上 NapCat + 简单 bot，别搬这套。
- 用户要求严格 7×24 —— Free 档做不到，先看 `docs/05-keepalive.md` 的取舍，再让用户选「接受周期性 20 秒离线」还是「升付费档」。

## 2. 执行顺序（agent 契约）

严格按阶段推进，**每阶段结束必须拿到对应验收证据**，不许跳步、不许"大概应该好了"。

| 阶段 | 目标 | 产出证据 | 详见 |
|---|---|---|---|
| **P0 前置** | 凭据可用、机器 running、盘点平台限额 | `instabox whoami` EXIT=0；`instabox get <MACHINE> --json` 里 `state=running` | `docs/02-prerequisites.md` |
| **P1 传输** | 把 payload 打到 `/data/qqbot/` | `sha256sum -c SHA256SUMS.txt` 全 OK | `docs/03-runbook.md` §P1 |
| **P2 起容器** | SnowLuma 起来、OneBot 端口通 | 容器 Up；`/get_login_info` 有响应（未登录时也应有 HTTP 层响应） | §P2 |
| **P3 扫码** | QQ 真登录 | SnowLuma 日志 `[Hook] login detected ... UIN=<uin>`；`get_login_info` 200 且 `data.user_id` 正确 | §P3 |
| **P4 推理后端** | headless DSH 装好并绑回环 | `dsh-web.service` active；匿名 `curl 127.0.0.1:3080/` 回 **401** | §P4 |
| **P5 桥接入** | SurfCore 连上 SnowLuma 与 DSH | 桥日志出现 `SnowLuma 已连接` + `DSH 已就绪`；`ss -tnp \| grep :3001` 有 ESTAB | §P5 |
| **P6 端到端** | 真人发一句话，机器人回 | OneBot 发送日志有 `发送：<正文>`；DSH session 目录出现 `session.v4.jsonl.zstd` | §P6 |
| **P7 保活** | 免费档不被 30 分钟空闲睡死 | 计划任务注册成功 + 手动跑一轮 `suspend→resume` 状态收敛回 running | `docs/05-keepalive.md` |

**只在 P6 通过后才说"部署完成"。** P1–P5 全绿但没观测到一次真实往返，只能报"链路就绪，未验证回环"。

## 3. 验收命令（唯一权威）

```bash
# 全栈体检，RESULT: PASS (fail=0) 才算过
bash /data/qqbot/scripts/healthcheck-b.sh
```

它检查 9 项：两个 systemd active、3080 匿名 401、QQ 在线、snowluma 容器 running、astrbot 已停、
桥连上 SnowLuma、桥 DSH 就绪、**本次运行**内无 preset 拒绝。
逐项判定标准与失败时的排查路径见 `docs/04-verification.md`。

## 4. 硬规矩（违反必炸，每条都踩过）

1. **本机不许同时登同一个 QQ 号**。PC 端会互踢，扫码白扫。真凶常是自启计划任务把 QQ 拉回来 —— 先 Disable + 杀进程树。
2. **远程命令一律走「写脚本文件 → 上传 → `bash /path/x.sh` → 拉结果文件」**。理由见 `docs/06-pitfalls.md` P-01（PowerShell 5.1 → 原生 exe 吃内层双引号）。
3. **手改 SurfCore `config.json` 必须重启桥**。桥没有 fs.watch，改文件不生效（P-11）。
4. **`systemctl restart` 必须带 `sudo`**。非 root 会报 `Access denied` 且 rc=4，看起来像服务有问题（P-12）。
5. **不要写死 `maxRunMinutes`**。同一台机不同时刻读出来是 120 / 480 不等，以实时 JSON 为准（P-16）。
6. **不要用高频 wake 做保活**。wake 不算 work、不延长运行时间，还会阻止空闲暂停清零连击（P-17）。
7. **管理端口全绑 `127.0.0.1`**，用 `instabox port-forward` 访问。InstaBox 一旦 publish 就全网可达。

## 5. 文件地图

```
SKILL.md                      ← 你在这里；契约与顺序
README.md                     ← 给人看的概览
docs/01-architecture.md       ← 为什么这么切分（含源码级论证）
docs/02-prerequisites.md      ← 凭据、机器、平台限额
docs/03-runbook.md            ← 可复制粘贴的分阶段命令
docs/04-verification.md       ← 验收判定与排障路由
docs/05-keepalive.md          ← 免费档保活：机制、参数、代价
docs/06-pitfalls.md           ← ★ 踩坑库（20 条，症状/根因/修法）
docs/07-optional.md           ← ★ 非必需组件（B站分享、WorkBuddy、AstrBot 遗留）
docs/08-facts.md              ← 平台 API/限额/状态机事实表
scripts/                      ← 可直接跑的脚本（含 patch、验收、保活）
config/                       ← 配置模板（需按目标机改写占位符）
```

`docs/06-pitfalls.md` 和 `docs/07-optional.md` 是这套东西最贵的部分 —— 前者省掉重踩一遍的时间，后者划清「必须」与「锦上添花」的边界。

## 6. 占位符约定

文档与脚本里统一用这些占位符，执行前按目标环境替换：

| 占位符 | 含义 | 取法 |
|---|---|---|
| `<MACHINE>` | InstaBox 机器名或 id | `instabox ls --json` |
| `<MACHINE_ID>` | `m_xxx` 形式的机器 id | 同上 |
| `<UIN>` | 目标 QQ 号 | 用户提供 |
| `<OWNER_QQ>` | 管理员/主人 QQ 号 | 用户提供 |
| `<ROOT>` | 部署根目录，默认 `/data/qqbot` | 本文档约定 |
| `<DSH_HOME>` | DSH 数据目录，默认 `<ROOT>/dsh-home` | 本文档约定 |
| `<ONEBOT_TOKEN>` | OneBot accessToken | 自定，须与桥侧一致 |
