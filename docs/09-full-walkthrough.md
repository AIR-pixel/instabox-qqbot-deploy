# 09 全链路实录（从本机到 VPS 到常驻）

> 本文是**一次真实迁移的完整复盘**，按发生顺序记录：目标形态、传输、逐层配置、端到端验收、保活。
> 与 `03-runbook.md` 的区别：runbook 是「照着做」的通用步骤，本文是「当时实际发生了什么」，含实测返回值、
> 具体报错原文与决策理由。agent 读完本文应能解释每一个设计选择，而不只是会敲命令。
>
> 所有路径、版本、token 均为该次实测值；在新环境部署时按 `<占位符>` 替换。

---

## 0. 起点与目标形态

本机栈：NapCat（Windows QQNT 挂钩）+ SurfCore 0.8.8（reserved2 二代仿真）+ AstrBot 4.29.4 +
dsh-llm-gateway 1.2.1。深度绑定 Windows 绝对路径、`E:\` / `C:\`、PowerShell 计划任务。

曾评估 A 方案（三容器 surfcore + astrbot + llm-gateway），用户判定「后来的方案用不上 astrbot」后改 **B**：
把 DSH 也搬上 VPS，本机彻底不参与。

最终形态（B）：

```
┌─ 宿主网络命名空间（127.0.0.1）────────────────────────┐
│  dsh-web.service          surfcore-bridge.service      │
│  @deepseek-ai/dsh         surfcore 0.8.8 reserved2     │
│  127.0.0.1:3080           node src/bridge.js           │
│       ▲  回环 HMAC Cookie（共享 .credentials.yaml）      │
│       └──────── DSH_WEB_URL=http://127.0.0.1:3080 ─────┘
└──────────────────────▲─────────────────────────────────┘
                       │ ws://snowluma:3001
        ┌──────────────┴───────────────┐
        │  snowluma 容器（真实 QQ）     │
        │  OneBot v11  3000 / 3001     │   ← 仅容器内网，未 publish
        └──────────────────────────────┘
```

**唯一不可改的架构约束**：DSH Web 与桥必须同 netns，且 `dsh.baseUrl` 走回环。
SurfCore 的 `dsh-client.js` 只在 `isLoopbackBase()` 成立时用共享凭据离线铸造 `dsh-auth-*` Cookie；
写成 `http://dsh-web:3080` 一类容器服务名会一路 401，卡在「DSH 未就绪」。

实测基线：InstaBox Free（4 vCPU / 8 GiB / 20 GiB 固定盘）、Debian 13 trixie、
Docker 29.8.2 + Compose v5.6.0、Node v22.23.3、`motricseven7/snowluma:latest`（2.4.0-node）、
`@deepseek-ai/dsh@0.2.1-rc.5`、`surfcore 0.8.8`（reserved2）。

**AstrBot 与 dsh-llm-gateway 后续停用**：前者是多余转发层，两边同时订阅事件会双回复；
后者是唯一会走账号主本人 DeepSeek 平台额度的路径。

---

## 1. 授权与操作端

凭据落盘 `instabox-home\config\instabox\credentials.json`：

```json
{"server":"https://api.instabox.sh","apiKey":"ibk_..."}
```

字段名必须是 `apiKey`。写成 `accessToken` 会被当成会话 token，报：

```
instabox: session expired; run `instabox login`
```

CLI 为 `instabox-cli\instabox-windows-amd64.exe`（不在 PATH），且必须设置：

```powershell
$env:XDG_CONFIG_HOME='<WORKSPACE>\instabox-home\config'
```

否则 Go 在 Windows 上会试图 `mkdir C:\Users\<u>\.config\instabox` 并 `chmod`，报 `Access is denied.`

验证：

```powershell
& $cli whoami
# 2708104313 (user 347330580) ... (personal, free plan)
# Sandbox sizes: 4 vCPU / 8 GB
& $cli resume test          # test = m_agq2w7s6x7s75gkwpndobeebke，原 state=suspended
& $cli get test --json      # 等 state=running / runtime.ready=true / processesPreserved=true
```

> 曾走 `login --agent --no-wait` 的 claim-code 流程，长轮询在 Windows 无终端环境下 interval=60 卡死且不落地凭据；
> 且 `/v1/auth/agent/token` 未批准前恒返回 400 `authorization_pending` / `slow_down`。最终由用户直接提供 API key 绕过。

---

## 2. 传输：打包、推送、解包

### 2.1 两个 tar，为什么拆

| 包 | 内容 | 大小 | SHA256 |
|---|---|---|---|
| `bulk.tar` | surfcore 源码 / node_modules / 人格卡 / 角色包 / AstrBot data | 612.75 MiB | `cd5474a3…` |
| `seed.tar` | Linux 模板、`config/onebot.json`、脚本、文档 | 25.59 MiB（476 members） | `fd3ec6bf…` |

首次初打 **9.3 GB**，根因 `surfcore\state\voice-packs` 是 10.4 GB 的 Windows Python venv 本地 TTS 包，
Linux 不可用且超 `instabox push` 单文件 5 GiB 上限。修法：`SKIP_DIR_NAMES` 加 `voice-packs`、
`SKIP_NAMES` 加 `*.pyc`。

**关键取舍**：bulk 刻意排除根级 `surfcore/config.json`（本机值 `127.0.0.1:3001`、白名单、consolePort
全是 Windows 的），由 seed.tar 放 Linux 模板覆盖式解开。活 VPS 上**严禁整包重解 seed.tar**——
内含原始 `cmd_config.json` 的 `127.0.0.1` 会盖掉已 patch 的网关地址，一律只做增量 push。

### 2.2 引号链（本工程最反复的一坑）

PowerShell 5.1 把参数交给原生 exe 时会再解析一次引号，套两层系统性掉引号：

```powershell
# 你写的
instabox exec test -- bash -lc 'echo "=== test ===" && curl -H "Authorization: Bearer x" ...'
# Linux 实际收到
echo === test === && curl -H Authorization: Bearer x ...
```

报错原文：`curl: (2) no URL specified`、`unexpected EOF while looking for matching \`'\``、
`QQ_HTTP=+r.status`。另：PS 5.1 读 UTF-8 无 BOM 的 `.ps1` 会 `ParserError: 意外的标记")"`，
凡要被 PS 5.1 执行的 `.ps1` 一律纯 ASCII（校验 `($bytes | ? { $_ -gt 127 }).Count -eq 0`）。

**定案（五步文件化）**，此后所有远程操作都走这个模板：

```powershell
# 1 本地写 ASCII 脚本，内部 exec > /data/qqbot/x.txt 2>&1
Set-Content -Path .\x.sh -Value $script -Encoding ASCII
# 2 上传
& $cli push test .\x.sh /data/qqbot/scripts/x.sh
# 3 执行（这一行不含任何引号）
& $cli exec test -- bash /data/qqbot/scripts/x.sh
# 4/5 拉结果
& $cli pull test /data/qqbot/x.txt .\x.txt
```

`deploy-remote.ps1` 的 step4 因此改成无双引号形式：

```
python3 patch-astrbot-config.py --config ... --env-file /data/qqbot/compose/.env
```

（`patch-astrbot-config.py` 新增 `--env-file` 自己逐行解析 `GATEWAY_TOKEN=`。）

附带两个环境坑：
- 后台 job 的 PATH 里没有 `pwsh` → `CommandNotFoundException`；
- 需要 `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force`，否则 `PSSecurityException`；
- `$ErrorActionPreference='Stop'` 会把 docker 拉镜像的 stderr 进度行当 `NativeCommandError` 误报 exit 1，改 `'Continue'`。

### 2.3 部署序列

```powershell
& instabox-migration\scripts\deploy-remote.ps1 -Machine test
```

push 约 10 分钟，bulk 分成 4 个 `.instabox-upload-*` 块。解包顺序 **先 bulk 后 seed**：

```bash
mkdir -p /data/qqbot
cd /data/qqbot && tar -xf /tmp/bulk.tar
cd /data/qqbot && tar -xf /tmp/seed.tar
sha256sum -c SHA256SUMS.txt
cp compose/.env.example compose/.env     # 改 VNC_PASSWD / ONEBOT_ACCESS_TOKEN / OWNER_QQ / TZ
docker compose --env-file .env up -d
```

**step 5b（必做）**：SnowLuma 首启会自生成随机 token
（httpServers `NUJRK9fUKPA0muwWF83c1soXNyfidLJGoXQEj-xQ2lg`、
wsServers `Ork4WrI3NZFS2ZJEInB35yXBnHMk6pcmhhWrahd9ekQ`）并把 `wsClients` 清成 `[]`，
直接盖掉预置模板。补灌：

```bash
docker compose cp /data/qqbot/config/onebot.json snowluma:/app/data/config/onebot.json
docker exec snowluma chown node:node /app/data/config/onebot.json
docker compose --env-file .env restart snowluma
```

扫码后账号级 `onebot_<uin>.json` 会再覆盖一次，故 `postscan.sh` 写成**幂等版**：
该文件是 `mode:overlay`，字段全嵌在 `networks` 下（曾误按顶层读导致假阴性），
按 `networks.*` 结构化读；配置已正确则只打印 `status=OK`、**不重写不重启**，保住刚登录的活会话。

> 早期还有一次 `systemd 203/EXEC`：`ExecStartPre=/usr/local/bin/bash` 在 Debian 13 不存在，改 `/bin/bash`。

---

## 3. 机器人逐层配置

### 3.1 容器层

`snowluma` 三条缺一不可，hook 注入真实 QQ 全靠它们：

```yaml
cap_add: [SYS_PTRACE]
security_opt: [seccomp=unconfined]
shm_size: 1gb
```

`SNOWLUMA_QQ_FLAGS`:

```
--disable-gpu --disable-gpu-compositing --enable-unsafe-swiftshader --disable-dev-shm-usage
```

**必须去掉镜像默认的 `--disable-software-rasterizer`**：headless Xvfb 下它连最后一条绘制路径也关掉，
登录窗变浅灰白屏、无二维码、进程表无 `--type=renderer`。抓屏实证主色 `(240,240,240)` 34156 像素、
`dense B/W alternation blocks: 0`；另有 `xmessage` 弹窗
（`fbsetbg: I can't find an app to set the wallpaper with...`）正好盖住登录窗，`pkill` 掉即可。

端口：`127.0.0.1:6081`（noVNC 扫码）、`127.0.0.1:5099`（WebUI）；3000/3001 **从不 publish**。
VNC 口令在 `.env`；WebUI 口令每次重启重生成：

```bash
docker compose --env-file .env logs --no-color snowluma | grep 'initial credentials' | tail -1
```

`ONEBOT_ACCESS_TOKEN` 三处必须一致：`onebot.json` 的 `networks.httpServers[].accessToken`、
`networks.wsServers[].accessToken`、surfcore 的 `snowluma.accessToken`。

### 3.2 扫码层

```bash
instabox port-forward test 6081:6081 5099:5099 6186:6185
```

本机三端口 HTTP 200 后打开 `http://127.0.0.1:6081` 扫码。
**扫前确认别处没登同号**：PC 端会互踢，真凶是计划任务 `NapCat-AutoStart`（已 Disabled + 杀净进程树）。
`port-forward` 断线不会自动重连，曾用一个无限循环（断线等 5s 再拉）兜住。

扫完日志：`[Hook] login detected: PID=192868 UIN=<uin>`、`[OneBot] session started`。

### 3.3 推理后端 `dsh-web.service`

```ini
[Service]
User=user
Environment=DSH_HOME=/data/qqbot/dsh-home
Environment=TZ=Asia/Shanghai
WorkingDirectory=/data/qqbot/dsh-web
ExecStartPre=/bin/bash -lc 'test -f /data/qqbot/dsh-web/node_modules/@deepseek-ai/dsh/lib/bin.js'
ExecStart=/usr/local/bin/node /data/qqbot/dsh-web/node_modules/@deepseek-ai/dsh/lib/bin.js web --no-open --host 127.0.0.1 --port 3080
StandardOutput=append:/data/qqbot/logs/dsh-web.log
Restart=always
```

验收 `curl 127.0.0.1:3080/` 回 **401 才是成功**（鉴权栅栏立住）；200 是栅栏没开，000 是没起来。
`ExecStartPre` 必须 `/bin/bash`（Debian 13 无 `/usr/local/bin/bash` → `203/EXEC`）。
`TZ=Asia/Shanghai` 影响所有定时任务；宿主默认 UTC 会把「07:00」偏移到北京时间 15:00。

**额度物理隔离**：`$DSH_HOME/.credentials.yaml` 只保留 `client-connection/browser-session`
（HMAC 铸造 Cookie 必需），删除 `deepseek-account-platform/default`、`deepseek-account-platform/device`
两条 record 与 `refs.BAOMIAO_API_KEY`。实测：

```
USER_TOKEN_HITS=0  DEVICE_ID_HITS=0  BAOMIAO_HITS=0  BROWSER_SESSION_HITS=1  CREDS_MODE=600
```

备份 `.credentials.yaml.bak-wb`。同时 `docker compose stop llm-gateway`。

**WorkBuddy provider**：`dsh-connect-workbuddy@5.17.0` 加进 web profile 的 `dependencies` 与
`dsh.profile.bundles`，然后 `dsh plugin --profile web install`。凭据走 vault：
`workbuddy-vault/cn/<24位hex>.json`（`version:1`、domain `www.workbuddy.cn` 判 `cn`）。
源码依据 `scanAll()` → `syncVault()` 的 `if (existing === void 0) scan.set(id, entry.credential)`，
即 vault 文件本身就是合法凭据源，桌面端不装也行。

查配置必须写 `--profile web --dump-config`（写成 `--dump-config web` 报
`error: --profile <name> is required`），实测 `WORKBUDDY_BUNDLE_HITS=3` /
`WORKBUDDY_PROVIDER_HITS=3` / `DEEPSEEK_V41_HITS=3`。

`deepseek-v4.1-flash` 在插件里声明 `multimodal`（`NATIVE_MODALITY_BY_MODEL_ID`），
装上后图片/表情不再退化成文字标签。端到端日志实证
`已设置会话模型 ... -> workbuddy/deepseek-v4.1-flash (low)`，无「回退到目录」、无「未声明 image 输入」。

> 装插件前那次回环走的是 `deepseek-account/deepseek-flash`（用户账号额度）且无 image 输入，
> 这正是必须做物理隔离的原因。

### 3.4 编排层 `surfcore-bridge.service` + `config.json`

```ini
Environment=DSH_HOME=/data/qqbot/dsh-home
Environment=DSH_WEB_URL=http://127.0.0.1:3080
Environment=SNOWLUMA_HOME=/data/qqbot/qq-client-data
Environment=TZ=Asia/Shanghai
WorkingDirectory=/data/qqbot/surfcore
ExecStart=/usr/local/bin/node /data/qqbot/surfcore/src/bridge.js
StandardOutput=append:/data/qqbot/surfcore-bridge.log
```

| 键 | 值 / 说明 |
|---|---|
| `dsh.baseUrl` | `http://127.0.0.1:3080`（必须回环） |
| `dsh.provider` / `model` | `workbuddy` / `deepseek-v4.1-flash`，`reasoningEffort: low`，`followDefaultModel: false` |
| `snowluma.wsUrl` / `httpUrl` | `ws://snowluma:3001` / `http://snowluma:3000`，`followDiscoveredEndpoint: false` |
| `ownerQQ` | `<OWNER_QQ>` |
| `allow.private` / `allow.groups` | 白名单；`allowAllWhenEmpty: false` |
| `consolePort` / `consoleToken` | `3100` / `""`（每次启动生成到 `state/console-token`） |
| `socialV2.enabled` | `true`（二代全套工具） |

白名单外的消息在 `bridge.js:15569` 直接丢弃——这是「机器人不理我」的第一因。
新增好友后必须把 QQ 号加进 `allow.private` **并重启桥**（`config.json` 无 `fs.watch`）。

两条运维铁律：
- `systemctl restart` 必须带 `sudo`，否则 `Failed to restart ...: Access denied`（rc=4），看着像服务坏；
- 控制台鉴权只认 `?token=` 或 `X-Console-Token` 头，`Authorization: Bearer` 会 401；
  且二代 key 必须是 `private:<QQ号>` / `group:<群号>`，**不能写昵称**（三次 `agent token 无效`
  会触发 `⛔ 回合止血 ... 同一工具错误连续出现 3 次`）。

**群聊接话频率**（后续调优）：`probability 0.05 → 0.45 → 1.0`；
`maxWakePerMinute 1→6`、`maxWakePerHour 12→120`、`noActionLimit 3→1000`
（默认 3 最阴：几次「醒了没说话」就静默把 wakeConfig 重置回 5%）、`batchWindowMs 8000→3000`。
`/api/socialV2/wake` 只是一次性手动唤醒，改配置要用 `/api/socialV2/wake-config`；
后者有 5 分钟沉睡前观察守卫，绕过办法是停桥改 `state/social-v2.json` 再起。

### 3.5 验收

唯一权威命令：

```bash
bash /data/qqbot/scripts/healthcheck-b.sh
# == RESULT: PASS (fail=0) ==
```

九项：两 systemd active、3080 匿名 401、`/get_login_info` 200、snowluma running、astrbot 已停、
桥 `SnowLuma 已连接`、桥 `DSH 已就绪`、本次 run 无 `⛔`。第 9 项用
`awk '/桥接已启动/{n=NR} END{print n+0}'` + `tail -n +$SINCE` 只看本轮日志——
对 append-only 日志全量 grep 会永远 FAIL（历史第 253 行的 `⛔ 回合止血` 是旧事件）。

**端到端真人闭环实证**（北京时间 15:38）：

```
15:38:05  [Event] 私聊 (ﾟёﾟ)(<OWNER_QQ>): ID:-1934587237 咳咳
07:38:14  [reserved2] 唤醒 private:<OWNER_QQ>（bootstrap）
07:38:14  会话 private:<OWNER_QQ> 已挂载 preset qq-chat-v2
07:38:23  [reserved2] 工具统一发送 private:<OWNER_QQ>: 成功 2/2 条
15:38:22  [OneBot] 私聊 <OWNER_QQ> | 发送：咳什么咳，我耳朵又没聋
15:38:23  ... 发送：倒是说说，上次那首打字版的，算不算有点感情了？
```

DSH session 落盘 `session-e0fed7d1-…/session.v4.jsonl.zstd`，`token-usage.jsonl` /
`tool-calls.jsonl` / `social-v2.json` 全有。**只在观测到真实往返之后才算部署完成。**

---

## 4. 保活策略

### 4.1 平台到底怎么掐你（官方事实表）

| 机制 | 实测 / 官方值 |
|---|---|
| 空闲暂停 | 30 分钟（`autoSuspendAfterSeconds: 1800` 写死；Free 档 `PATCH` 被拦且**错误体为空**） |
| idle 判定 | 无 agent working / 无 SSH / 无 CPU load；exec、file read、public port 请求、task lease 都算 busy |
| **列机器 / 读详情 / 读日志** | **永不唤醒**（外部平台轮询状态零成本） |
| `maxRunMinutes` | 到点即 pause，再忙也一样；activity lease **延长不了它**；读数 running=120 / suspended=480，以实时 JSON 为准 |
| Free dynamic runtime | 新 run 起始 2 小时窗口；到期前 5 分钟看前 30 个完整分钟里几个不同分钟有 work：≥5 → 延 2h，1–4 → 延 30min，0 → 到点 pause。原文：**"Renewing a keepalive lease or requesting a wake does not earn an extension."** 采集不到活动时该 run 改用 8 小时上限 |
| 冷却 | 空闲暂停 **零冷却**；max-run 暂停 Free 递增：第 1 次 5–20min、第 2 次 60–75min、第 3 次及以后 120–135min。冷却期内唤醒回 `409 machine_cooldown`（带 `Retry-After` / `retryAfterSeconds` / `cooldownUntil`） |
| 计数归零 | run 以无冷却欠账结束（空闲暂停 / 主动 pause·stop），或新 run 在上次冷却结束 ≥2h 后开始 |
| 安全审查锁 | 不算 max-run 一步，但最长 24 小时；算冷却、保留计数 |
| `Starts/minute` | **3**（create / start / resume / wake 都算，超了 `429 rate_limited`） |
| 状态语义 | Running（留内存+进程+文件，计费）/ Paused（留内存+进程，不计费）/ Stopped（丢内存与进程，留文件）/ Deleted。**暂停的机器不能 stop** |
| 生命周期 API | `POST /suspend`、`/resume` 必须带唯一 `Idempotency-Key`（UUID），返回 **202 + operation**；`GET /operations` 是 **404**；`PUT /activity-leases/{taskID}` 200 / DELETE 204；`POST /wake` 200、`GET /wake` 404；`PATCH` 改 `autoSuspendAfterSeconds` 在 Free 失败且错误体为空 |

API 基址 `https://api.instabox.sh`，头 `X-API-Key: ibk_...`（`ibk_` + 52 字符），
Idempotency-Key 保留 7 天。Free 档：1 台机、running at once 1、20 GiB 盘、5 快照、
100 GiB 出口/月。Pro $20/月（含 $20 credits、8vCPU/16GiB、200GiB 盘、1TiB 出口）。

### 4.2 策略演进：为什么否掉每 15 分钟 wake

最初给的是「每 15 分钟 wake 一次」。查完官方 `auto-pause.md` 后确认这是**反向优化**：

1. wake 不算 work、不延长 max-run；
2. 持续唤醒又阻止了「空闲暂停」——而空闲暂停恰恰是零冷却、能把连击计数清零的唯一出口；
3. 结果必然反复撞 max-run，冷却按 5–20 → 60–75 → **120–135 分钟**递增，越保越离线。

「会不会触发风控」的准确答案：`Starts/minute=3` 离 15 分钟一次差得远，**速率上碰不到**；
真正的惩罚是 max-run 冷却递增，不是限流。

中间走过 muse 外部定时任务，后改 Hark Pro——Hark Pro 以「定时 suspend/resume 等于规避 Free 档
用量限制」为由拒绝配置，并暂停了 15 分钟那个任务。用户随后拍板**自建**。

### 4.3 定案：`suspend → 20s → resume`，每 85 分钟

核心：**让每个 run 都短于 2 小时窗口，且每轮主动制造一次「无冷却欠账」的结束**，
两条硬线都够不着。

| 数字 | 理由 |
|---|---|
| 85 min | < 120 min 动态窗口，也 < `maxRunMinutes`；比 30 长（少折腾）、比 120 短（留足余量） |
| 8 小时上限 | 是**单个 run** 的上限；每次 cycle 都换 run，走不到 |
| 20 秒 | suspend→resume 间隔，实测足够 operation 落定；Paused 保留内存+进程且不计费 |

实测收敛：

```
18:17:40 state=running
18:17:41 suspend 202
18:18:01 resume 202
18:18:12 state=running ready=True preserved=True
```

`runStartedAt` 连续刷新 `10:08:21Z → 10:18:02Z → 10:21:03Z`，证明每次都换了新 run；
`cooldownUntil=2026-11-06T09:57:25Z` 早已过期。VPS 旁证：`snowluma::Up 8 hours`、
`dsh-web: active`、`surfcore-bridge: active`、`get_login_info` 正常、桥日志无断档。

### 4.4 落地实现

`keepalive\keepalive-cycle.ps1`（纯 ASCII）：

```
Get-State
  ├─ 非 running → 直接走 resume
  └─ running    → POST /suspend  (唯一 Idempotency-Key，期望 202)
                  Start-Sleep 20
                  POST /resume   (另一个唯一 key，期望 202)
                  6 × 10s 收敛确认，打印 ready / preserved
                  409 machine_cooldown → 跳过本轮，不重试
```

日志 `%LOCALAPPDATA%\instabox-keepalive\keepalive.log`。
`install-task.ps1` 注册计划任务 `InstaBox-Keepalive`：
`-Once -RepetitionInterval 85 min -RepetitionDuration 3650 days`、
`MultipleInstances IgnoreNew`、`ExecutionTimeLimit 10 min`、`RunLevel Limited`。
实测 18:20:26 自动触发，`NextRunTime 19:45:26`、`LastTaskResult=0`。

**代价必须说清**：每 85 分钟约 20 秒离线。真 7×24 只有三条路——升 Pro、
机器人放回本机常驻、或接受周期性空窗。Free 档物理限制绕不过去，只是选哪种代价。

---

## 5. 与仓库内其它文档的关系

| 需求 | 去哪读 |
|---|---|
| 立刻照着做 | `03-runbook.md` |
| 判断成功 / 失败往哪查 | `04-verification.md` |
| 保活机制细节与取舍 | `05-keepalive.md` |
| 某条报错怎么修 | `06-pitfalls.md`（P-01..P-20） |
| B站分享 / 群唤醒 / WorkBuddy 等可选件 | `07-optional.md` |
| 平台 API、限额、状态机 | `08-facts.md` |
| 本文（为什么这么设计、当时实测值） | `09-full-walkthrough.md` |
