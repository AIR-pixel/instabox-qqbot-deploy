# 03 部署 runbook

> 全程在**目标机**上以 `bash` 执行。所有命令假设 `<ROOT>=/data/qqbot`、`<DSH_HOME>=<ROOT>/dsh-home`。
> 从操作端下发时，一律走「写脚本 → 上传 → 执行 → 拉结果」（P-01）。

---

## P0 前置

```bash
# 操作端
instabox whoami
instabox resume <MACHINE>            # 若 state=suspended
instabox get <MACHINE> --json        # 等到 state=running 且 runtime.ready=true

# 目标机
sudo -n true && echo SUDO_OK
docker version --format '{{.Server.Version}}'
node -v                              # 需 >= 22.13.0（SurfCore engines 要求）
df -h /data                          # 至少 10 GiB 可用
```

验收：`state=running`、`runtime.ready=true`、`SUDO_OK`、`node >= v22.13`。

---

## P1 传输 payload

把这三样打到目标机：

1. `surfcore/`（源码 + `config.json`）
2. `compose/`（`docker-compose.yml` + `.env`）
3. `config/`（`onebot.json` 模板）
4. `scripts/`（验收与维护脚本）
5. `secrets/.credentials.yaml`（600）

打包时**必须排除**：

- `surfcore/state/voice-packs/` —— 本机 TTS 语音包，动辄 10 GiB，Linux 上还用不了
- `**/*.pyc`、`node_modules/.cache`
- 本机路径写死的 `config.json` 备份 `config.json.bak*`

```bash
# 目标机解包（示例：分卷 tar + 校验）
mkdir -p /data/qqbot
cd /data/qqbot && tar -xf /tmp/bulk.tar
cd /data/qqbot && tar -xf /tmp/seed.tar      # 覆盖式：模板优先
sha256sum -c SHA256SUMS.txt
```

验收：校验全 OK，且 `surfcore/package.json` 存在、`compose/docker-compose.yml` 存在。

> **不要**把本机的 `surfcore/config.json` 打进 bulk。它里面 `dsh.baseUrl=http://127.0.0.1:3080` 之类看似通用，
> 但 `snowluma.wsUrl`、`allow.*`、`consolePort` 全是本机值。用 `config/` 里的模板生成。

---

## P2 起 SnowLuma 容器

```bash
cd /data/qqbot/compose
cp .env.example .env
# 编辑 .env：至少改 VNC_PASSWD、ONEBOT_ACCESS_TOKEN、OWNER_QQ
vi .env

docker compose --env-file .env up -d snowluma
sleep 10
docker compose --env-file .env ps
```

容器必须带：

```yaml
cap_add: [SYS_PTRACE]
security_opt: [seccomp=unconfined]
shm_size: 1gb
```

少任何一条，hook 注入失败，QQ 客户端起来了但 OneBot 没信号。

**首次启动会覆盖你预置的 `onebot.json`**（P-05）。启动后必须补灌一次：

```bash
docker compose cp /data/qqbot/config/onebot.json snowluma:/app/data/config/onebot.json
docker exec snowluma chown node:node /app/data/config/onebot.json
docker compose --env-file .env restart snowluma
```

验收：

```bash
docker exec snowluma sh -lc 'grep -c accessToken /app/data/config/onebot.json'   # >= 2
docker inspect -f '{{.State.Running}}' snowluma                                   # true
```

---

## P3 扫码登录

```bash
# 操作端：把 noVNC 与 WebUI 拉到本地
instabox port-forward <MACHINE> 6081:6081 5099:5099
#   扫码页  http://127.0.0.1:6081   （VNC 口令 = .env 的 VNC_PASSWD）
#   WebUI   http://127.0.0.1:5099   （口令见下方日志）
docker exec snowluma sh -lc \
  'grep -m1 "initial credentials" /app/data/logs/*.log 2>/dev/null || docker logs snowluma 2>&1 | grep -m1 "initial credentials"'
```

**扫码前先确认**：目标 QQ 号没有在别的设备上登录（PC 端会互踢，扫了也白扫）。
真凶常是自启项把 QQ 拉回来 —— Windows 上检查 `NapCat-AutoStart` 之类的计划任务。

扫完验收（**这一条必须有**）：

```bash
docker logs --tail 200 snowluma 2>&1 | grep -E 'login detected|OneBot.*session started'
# 期望：[Hook] login detected: PID=<n> UIN=<uin>
#       [OneBot] session started

curl -s -H "Authorization: Bearer $ONEBOT_ACCESS_TOKEN" \
     http://<snowluma-ip>:3000/get_login_info
# 期望：{"status":"ok","retcode":0,"data":{"user_id":<uin>,"nickname":"..."}}
```

---

## P4 headless DSH 推理后端

```bash
# 装 DSH 到 <ROOT>/dsh-web
mkdir -p /data/qqbot/dsh-web && cd /data/qqbot/dsh-web
npm i @deepseek-ai/dsh@0.2.1-rc.5 --no-audit --no-fund

# DSH_HOME
mkdir -p /data/qqbot/dsh-home && chmod 700 /data/qqbot/dsh-home
# 放入 .credentials.yaml（只含 client-connection/browser-session），chmod 600
```

systemd unit：

```ini
# /etc/systemd/system/dsh-web.service
[Unit]
Description=DSH Web (headless, loopback)
After=network-online.target

[Service]
Type=simple
User=user
Environment=DSH_HOME=/data/qqbot/dsh-home
Environment=TZ=Asia/Shanghai
WorkingDirectory=/data/qqbot/dsh-web
ExecStartPre=/bin/bash -lc 'test -x /usr/local/bin/node'
ExecStart=/usr/local/bin/node /data/qqbot/dsh-web/node_modules/@deepseek-ai/dsh/lib/bin.js web --no-open --host 127.0.0.1 --port 3080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

> `ExecStartPre` 里的 shell 路径必须是 **`/bin/bash`**。Debian 13 没有 `/usr/local/bin/bash`，
> 写了会 `203/EXEC` 起不来（P-06）。

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now dsh-web.service
sleep 12
systemctl is-active dsh-web.service
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3080/     # 期望 401
```

**401 是成功**。它证明鉴权栅栏生效、匿名进不去。
若回 `000`，DSH 没起来；回 `200`，栅栏没开（危险，公网可直连推理）。

装 provider 插件（按需，见 `docs/07-optional.md`）：

```bash
DSH_HOME=/data/qqbot/dsh-home \
  node /data/qqbot/dsh-web/node_modules/@deepseek-ai/dsh/lib/bin.js \
  plugin --profile web install
```

> `--dump-config` 的写法有陷阱：必须 `--profile web --dump-config`，
> 写成 `--dump-config web` 会报 `error: --profile <name> is required`（P-13）。

---

## P5 起 SurfCore 桥

```bash
cd /data/qqbot/surfcore
# config.json 由模板生成：dsh.baseUrl 必须是 http://127.0.0.1:3080
#   snowluma.httpUrl = http://snowluma:3000
#   snowluma.wsUrl   = ws://snowluma:3001
#   snowluma.accessToken = <ONEBOT_ACCESS_TOKEN>
#   allow.private = ["<OWNER_QQ>"]
#   allow.groups  = [...]
```

unit：

```ini
# /etc/systemd/system/surfcore-bridge.service
[Unit]
Description=SurfCore bridge (QQ <-> DSH)
After=network-online.target dsh-web.service
Wants=dsh-web.service

[Service]
Type=simple
User=user
Environment=DSH_HOME=/data/qqbot/dsh-home
Environment=DSH_WEB_URL=http://127.0.0.1:3080
Environment=SNOWLUMA_HOME=/data/qqbot/qq-client-data
Environment=TZ=Asia/Shanghai
WorkingDirectory=/data/qqbot/surfcore
ExecStart=/usr/local/bin/node /data/qqbot/surfcore/src/bridge.js
StandardOutput=append:/data/qqbot/surfcore-bridge.log
StandardError=append:/data/qqbot/surfcore-bridge.log
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now surfcore-bridge.service
sleep 10
tail -40 /data/qqbot/surfcore-bridge.log
```

日志必须出现：

```
SnowLuma 已连接：ws://snowluma:3001
机器人昵称: <nickname>
DSH 已就绪（模式: reserved2）
桥接模式已确定为 reserved2
```

若卡在「DSH 未就绪」→ 100% 是 baseUrl 不是回环（`docs/01-architecture.md` §1.1）。

验收连接态：

```bash
ss -tnp | grep :3001     # 必须有 ESTAB，对端是 snowluma 容器 IP
```

---

## P6 端到端（唯一能说"部署完成"的证据）

用白名单里的号，给机器人发一句话。

```bash
# 立刻看三条线索
tail -80 /data/qqbot/surfcore-bridge.log | grep -E '唤醒|已挂载 preset|已设置会话模型|工具统一发送|收尾'
docker logs --tail 80 snowluma 2>&1 | grep -E 'Event|发送'
ls -l <DSH_HOME>/sessions/*/*/session.v4.jsonl.zstd
```

通过的标志（四条都要）：

1. 桥日志有 `[Event] 私聊 <uin>` 或 `群聊 <gid>`
2. 有 `<key> 已挂载 preset` + `已设置会话模型 ... -> <provider>/<model>`
3. 有 `工具统一发送 <key>: 成功 N/N 条`
4. SnowLuma 日志有 `发送：<正文>`，且**正文是模型真的生成的内容**

如果只到 (1)(2) 没到 (3)：模型跑了但没调发送工具 → 查 prompt 里有没有给对 key（P-14）。
如果 (3) 有但 (4) 无：OneBot 发送通道问题 → 查 `code=1006` / `bot_status: offline`（P-10）。

---

## P7 保活

免费档必做，否则空闲 30 分钟就睡。完整推导见 `docs/05-keepalive.md`，最短路径：

```bash
# 目标机：验证 suspend/resume 端点可用（带 Idempotency-Key！）
KEY=$(cat /proc/sys/kernel/random/uuid)
curl -s -X POST -H "X-API-Key: $APIKEY" -H "Idempotency-Key: $KEY" \
     https://api.instabox.sh/v1/machines/<MACHINE_ID>/suspend -d ''
```

```powershell
# 操作端（Windows）：注册计划任务
powershell -ExecutionPolicy Bypass -File .\scripts\install-task.ps1 -Mode cycle -IntervalMinutes 85
```

验收：`Get-ScheduledTaskInfo -TaskName InstaBox-Keepalive` 的 `LastTaskResult=0`，
且日志里一轮 `suspend 202` → `resume 202` → `after: state=running`。

---

## 回滚

```bash
sudo systemctl disable --now surfcore-bridge.service dsh-web.service
cd /data/qqbot/compose && docker compose --env-file .env down
# 想彻底清数据卷：
docker compose --env-file .env down -v
```

`surfcore/config.json`、`.credentials.yaml`、`profiles/web/package.json` 在改动前都应留 `.bak-<tag>`。
