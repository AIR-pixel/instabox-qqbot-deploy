# 06 踩坑库

每条格式：**症状 → 根因 → 修法**。按"会卡住你的顺序"排列，P-01..P-20。
带 ★ 的是必须知道，不知道一定会卡。

---

## P-01 ★ PowerShell 5.1 → 原生 exe 会吃掉内层双引号

**症状**：从 Windows 操作端下发远程命令，在 Linux 上执行结果被截断。

```powershell
# 你写的
instabox exec m1 -- bash -lc 'echo "=== test ===" && curl -H "Authorization: Bearer x" http://a/b'
# Linux 实际收到的（引号全没了）
echo === test === && curl -H Authorization: Bearer x http://a/b
```
典型报错：`curl: (2) no URL specified`、`unexpected EOF while looking for matching \`'\``、`QQ_HTTP=+r.status`。

**根因**：PowerShell 在把参数交给非 `.ps1` 的原生程序时，会重新做一次引号解析。
单层命令还好，套两层（`bash -lc '...'`）就会系统性掉引号。`\$` 和 `\"` 在 PS 双引号里**不是转义**。

**修法**：**永远走文件**。

```powershell
# 1. 本地写 ASCII 脚本
Set-Content -Path .\x.sh -Value $script -Encoding ASCII
# 2. 上传
instabox push m1 .\x.sh /data/qqbot/scripts/x.sh
# 3. 执行（这一行没有任何引号）
instabox exec m1 -- bash /data/qqbot/scripts/x.sh
# 4. 脚本内部把结果写到固定文件
#    exec > /data/qqbot/out/x.txt 2>&1
# 5. 拉回来
instabox pull m1 /data/qqbot/out/x.txt .\x.txt
```

配套规则：
- 脚本内容**纯 ASCII**（PS 5.1 读 UTF-8 无 BOM 会乱码甚至 ParserError → P-02）
- 脚本路径不含空格
- 需要参数就用环境变量或位置参数，不要拼进字符串

---

## P-02 ★ PowerShell 5.1 读 UTF-8 无 BOM 的 .ps1 会 ParserError

**症状**：

```
在 ...\clean-workspace.ps1:12 字符: 5
+     }
+     ~
意外的标记")"
    + CategoryInfo          : ParserError
```

文件肉眼看着完全正常。

**根因**：PS 5.1 默认按 ANSI（中文系统是 GBK）解码 `.ps1`。UTF-8 无 BOM 的中文注释会变成乱码字节，
其中某些字节序列恰好等于引号/括号，解析器就崩了。

**修法**：**所有要被 PS 5.1 执行的 .ps1 一律纯 ASCII**（注释也写英文，或用 `# ASCII only` 一行带过）。

```powershell
# 检查
$bytes = [IO.File]::ReadAllBytes('.\x.ps1')
($bytes | Where-Object { $_ -gt 127 }).Count   # 必须是 0
```

或者存成 UTF-8 **with BOM**（`Out-File -Encoding utf8BOM`，PS 7 有），但跨版本不如纯 ASCII 稳。

---

## P-03 ★ InstaBox credentials.json 的字段名是 `apiKey`

**症状**：

```
instabox: session expired; run `instabox login`
```

明明刚写了凭据。

**根因**：`credentials.json` 有两种用途，字段不同：

| 登录方式 | 字段 |
|---|---|
| 设备码登录（`instabox login`） | `accessToken` + `accessExpiresAt` + `refreshToken` … |
| **agent key / API key** | **`apiKey`** |

把 `ibk_...` 写进 `accessToken` → CLI 当成过期的会话 token。

**修法**：

```json
{
  "server": "https://api.instabox.sh",
  "apiKey": "ibk_<52 chars>"
}
```

另外：Windows 上 Go 的 `chmod` 会被拒（`mkdir C:\Users\x\.config\instabox: Access is denied.`），
用 `XDG_CONFIG_HOME` 把配置目录改到可写位置：

```powershell
$env:XDG_CONFIG_HOME = 'C:\work\instabox-home\config'
$env:INSTABOX_API_KEY = 'ibk_...'    # 或只靠这一个环境变量
```

---

## P-04 ★ SnowLuma 白屏：没有二维码

**症状**：noVNC 里 QQ 登录窗是浅灰白块，无 QR 码。截图分析：主色 `(240,240,240)` 数万像素，
`dense B/W alternation blocks: 0`（没有二维码的黑白棋盘），进程表里没有 `--type=renderer`。

**根因**：SnowLuma 镜像默认的 QQ 启动 flags 同时禁用了 GPU **和软件光栅化**：

```
--disable-gpu --disable-software-rasterizer --disable-gpu-compositing
```

在 headless Xvfb 上没有 GPU，软件光栅化又被禁 → **没有任何绘制路径**，渲染进程起不来，窗口只有底色。

**修法**：去掉 `--disable-software-rasterizer`，补 `--enable-unsafe-swiftshader`（Electron 40 的 WebGL）：

```yaml
environment:
  SNOWLUMA_QQ_FLAGS: "--disable-gpu --disable-gpu-compositing --enable-unsafe-swiftshader --disable-dev-shm-usage"
```

**附带坑**：容器里 `fbsetbg` 会弹一个 `xmessage` 窗口（"I can't find an app to set the wallpaper with..."），
尺寸 578×118 正好盖住登录窗。杀掉它：`docker exec snowluma pkill xmessage`。

---

## P-05 ★ SnowLuma 首次启动覆盖预置的 onebot.json

**症状**：你把 `onebot.json` 放进容器 `config/` 目录，启动后 token 变成随机串、`wsClients` 变空。

**根因**：SnowLuma 首启时若发现没有 `onebot.json`（或结构版本不匹配），会**自己生成一份**，
内容带随机 accessToken，覆盖你预置的文件。

**修法**：启动后、扫码前，补灌一次：

```bash
docker compose cp /data/qqbot/config/onebot.json snowluma:/app/data/config/onebot.json
docker exec snowluma chown node:node /app/data/config/onebot.json
docker compose --env-file .env restart snowluma
```

**并且**：扫码后 SnowLuma 会再生成**账号级** `onebot_<uin>.json`（P-08），需要 postscan 处理。

---

## P-06 ★ Debian 13 没有 `/usr/local/bin/bash`

**症状**：

```
dsh-web.service: Failed at step EXEC spawning /usr/local/bin/bash: No such file or directory
Main process exited, code=exited, status=203/EXEC
```

**根因**：`ExecStartPre=/usr/local/bin/bash ...` 是某些镜像里的路径习惯，Debian 的 bash 在 `/bin/bash`。

**修法**：`ExecStartPre=/bin/bash -lc '...'`，或干脆去掉 `ExecStartPre`。
改完 `sudo systemctl daemon-reload`。

---

## P-07 ★ 本机同时登同一个 QQ 号 → 互踢

**症状**：扫码成功，几秒后 QQ 掉线，反复扫反复掉。`docker logs snowluma` 有
`bot_status: offline` / `code=1000`。

**根因**：QQ 同一账号多端登录会互相踢。常见真凶是**自启项把 QQ 拉回来**：
Windows 上是计划任务（例：`NapCat-AutoStart`）或 Startup 目录快捷方式。

**修法**：

```powershell
Get-ScheduledTask | Where-Object { $_.TaskName -match 'NapCat|QQ' } | Select TaskName,State
Disable-ScheduledTask -TaskName 'NapCat-AutoStart'
Get-Process QQ -EA SilentlyContinue | Stop-Process -Force
Get-Process NapCat* -EA SilentlyContinue | Stop-Process -Force
```

**注意**：让用户退出 QQ 客户端 ≠ 退出计划任务。必须两边都确认。
另外：本机上"没有登录 QQ"不代表"没有 QQ 进程在跑" —— Electron 的 8 个 renderer 子进程会残留。

---

## P-08 ★ 账号级 onebot 配置是 overlay，字段嵌在 `networks` 下

**症状**：脚本按顶层 `d['httpServers']` 读配置，报 `httpTokens=[] wsTokens=[] wsClients=[] hasAstrbotWS=false`，
但 `grep` 明明能搜到 token。

**根因**：`onebot_<uin>.json` 的形状是：

```json
{
  "mode": "overlay",
  "networks": {
    "httpServers": [ { "accessToken": "..." } ],
    "wsClients": [ { "url": "ws://..." } ]
  },
  ...
}
```

**所有字段都在 `networks` 下面**。按顶层读 → 全是空的假阴性。

**修法**：读/写一律 `d.setdefault('networks', {})` 之后再取 `httpServers` / `wsServers` / `wsClients`。
文本级 `grep -c accessToken` 可作为交叉验证，但**判定必须结构化读**。

---

## P-09 扫码后 QQ 掉线需要重扫

**症状**：容器重启、镜像更新、`down -v` 之后，`get_login_info` 不再返回 `user_id`。

**根因**：QQ 登录态存在数据卷 `qq-client-data`（`/app/.local/share`）里。
清卷 = 清登录态。

**修法**：`docker compose down` 可以，**`down -v` 之后必须重扫**。
生产上把 `qq-client-data` 单独做快照。

---

## P-10 ★ 桥的事件通道会静默死亡（SurfCore 已知薄弱点）

**症状**：一段时间不回话，之后**所有**新消息都不回。看起来"桥还活着"。

**判据**（三条同时成立）：

```bash
wc -l /data/qqbot/surfcore-bridge.log     # 15 秒后不涨
ss -tnp | grep :3001                      # 无 ESTAB
tail -30 /data/qqbot/surfcore-bridge.log
#   ⚠️ SnowLuma 报告 QQ 账号会话已离线（bot_status: offline）
#   SnowLuma 连接断开（code=1000），重连中…
#   ❌ SnowLuma 发送通道不可用；自动唤醒已暂停
#   ⚠️ SnowLuma 上游不健康：已连接但 10 分钟没有收到任何事件包
```

**根因**：SnowLuma 掉线重登后，桥会重连 WS、`get_status` 探活也能过、history 能补回，
但**事件订阅没有真正恢复**。桥自己会误以为健康（因为它能发 HTTP 请求）。

**修法**：

```bash
sudo systemctl restart surfcore-bridge.service
```

重启后必须看到三行才算恢复：

```
SnowLuma 已连接：ws://snowluma:3001
桥接模式已确定为 reserved2
DSH 已就绪（模式: reserved2）
```

**预防**：外部探针每 5 分钟记录日志行数，连续两次相同且期间应有活动 → 自动重启。
单纯 `systemctl status` 是 active 不代表事件通道活着。

---

## P-11 ★ 手改 surfcore config.json 必须重启桥

**症状**：把 QQ 号加进 `allow.private`，等半天没用。

**根因**：桥读 `config.json` 只在启动时。代码里 `grep reloadConfig|fs.watch` 无命中。
控制台改白名单走的是内存热更（`cfg.allow = {...}`），但**改文件不触发**。

**修法**：

```bash
cp -a config.json config.json.bak-$(date +%Y%m%d-%H%M%S)
# 编辑 allow.private / allow.groups
sudo systemctl restart surfcore-bridge.service
```

**不带 sudo 会怎样**：

```
Failed to restart surfcore-bridge.service: Access denied
# rc=4
```
看起来像服务坏了，其实是权限（P-12）。

---

## P-12 ★ `systemctl restart` 不带 sudo 报 Access denied（rc=4）

**症状**：`systemctl restart xxx` 返回 rc=4 + `Access denied`。

**根因**：非 root 用户对 system 单元没有管理权限。systemd 用 rc=4 表达"权限不足"，
文案却像"服务拒绝"。

**修法**：一律 `sudo -n systemctl restart xxx`。`sudo -n` 让它在需要密码时**立刻失败**而不是挂住等输入。
部署前先 `sudo -n true && echo SUDO_OK` 确认免密。

---

## P-13 ★ `--dump-config` 必须跟 `--profile`

**症状**：

```
error: --profile <name> is required
```
即使你写了 `dsh --dump-config web`。

**根因**：CLI 的 alias 展开只在**第一个 token 不是 `-`** 时生效。
`--dump-config web` 的第一个 token 是 `--dump-config`，`web` 被当成位置参数丢掉。

**修法**：

```bash
node .../bin.js --profile web --dump-config
```

验证插件真的进了运行配置：

```bash
node .../bin.js --profile web --dump-config | grep -c dsh-connect-workbuddy
node .../bin.js --profile web --dump-config | grep -ci workbuddy
```

只看 `package.json` 里有依赖**不够** —— 还得在 `dsh.profile.bundles` 里，且插件通过 `cordis.patch.yml` 注册。

---

## P-14 ★ 模型/工具拿到的是 key，不是昵称

**症状**：桥日志

```
⛔ 回合止血 private:<qq>：同一工具错误连续出现 3 次
```
工具调用报 `agent token 无效`，之后该会话静默。

**根因**：AI 把会话 key 写成 `private:御坂`（昵称），而桥要求 **`private:<QQ号>`** 或 **`group:<群号>`**。
连续 3 次同类错误触发止血，会话锁死。

**修法**：

1. 立刻提醒 AI 正确形式：`private:<QQ号>`。
2. 若通过控制台注入消息（`POST /api/console/notify-ai`），**在 message 文本里写死 key 与 token**：

```
【会话令牌】<token>
【本群 key】<key>
（发消息请调用 qq_send_message，参数 key="<key>"、token="<token>"；不要用群名或昵称当 key。）
```

3. 控制台鉴权头是 **`X-Console-Token`**（值在 `state/console-token`），
   用 `Authorization: Bearer` 会 401。另外必须有 `Content-Type: application/json`，且 Host 头在白名单里（`127.0.0.1:<port>` / `localhost` / `[::1]`）。

**扩展**：任何"prompt 里让 AI 自己发消息"的场景（定时分享、主动搭话）都要把 key + token 直接写进 prompt，
不要指望 AI 自己查。桥的常规唤醒（`buildWakePromptV2`）会自动注入这两行，但**自定义 deliver 路径不会**。

---

## P-15 ★ 验收脚本 grep 全量 append-only 日志 → 永远 FAIL

**症状**：`healthcheck` 报 `FAIL bridge has preset rejection`，但服务明明在正常回话。

**根因**：`surfcore-bridge.log` 是 append-only 的。`grep -q '⛔'` 命中的是几小时前**已修复**的旧事件。

**修法**：只看**本轮**日志。

```bash
SINCE=$(awk '/桥接已启动/{n=NR} END{print n+0}' /data/qqbot/surfcore-bridge.log)
RUNLOG=$(tail -n +"$SINCE" /data/qqbot/surfcore-bridge.log)
printf '%s\n' "$RUNLOG" | grep -q '⛔' && bad "..." || ok "no preset rejection (this run)"
```

任何"日志里出现过 X 就判失败"的检查，都要先切成"本 run 之后"。

---

## P-16 ★ `maxRunMinutes` 读数会变，不要写死

**症状**：文档写"单次 120 分钟"，实测读出 480，过一会儿又变 120。

**根因**：平台侧的 `maxRunMinutes` 会随 run 状态与策略变化（suspended 与 running 读到的都不是同一个值）。

**修法**：

- 文档里写"以 `GET /v1/machines/<ID>` 的实时值为准"
- 代码里**不要**用它做算术（比如"我每 60 分钟跑一次所以安全"这种推理会被它打脸）
- 保活间隔用**远小于最小值**的数（本仓库用 85 分钟对着最小值 120）

---

## P-17 ★ 高频 wake 保活 = 反向优化

**症状**：机器越"保活"越频繁进入长时间不可用。

**根因**：三层机制叠加（详见 `docs/05-keepalive.md`）：

1. wake **不算 work**，不能续 dynamic runtime 的 2 小时窗口；
2. 持续 wake 让机器永远走不到"空闲暂停"（空闲暂停是零冷却的）；
3. 于是必然撞 max-run，Free 档冷却递增：5–20 → 60–75 → **120–135 分钟**。

**修法**：改主动 `suspend` → 20 秒 → `resume`，让 run 以零冷却方式结束、连击计数归零。
频率取 85 分钟（< 120 分钟窗口）。

---

## P-18 生命周期 API 必须带 `Idempotency-Key`

**症状**：`POST /v1/machines/<ID>/suspend` 直接失败，错误体还是空的。

**根因**：suspend / resume / start / stop 这类操作端点要求唯一幂等键（保留 7 天）。
同 key 不同请求 → `409 idempotency_conflict`。

**修法**：

```bash
curl -X POST \
  -H "X-API-Key: $KEY" \
  -H "Idempotency-Key: $(cat /proc/sys/kernel/random/uuid)" \
  "https://api.instabox.sh/v1/machines/<ID>/suspend" -d ''
```

返回 **202 + operation 对象**，不是最终状态。要轮询确认：

```bash
for i in $(seq 6); do sleep 10; curl -s -H "X-API-Key: $KEY" \
  "https://api.instabox.sh/v1/machines/<ID>" | jq -r .state; done
```

顺带：`GET /v1/machines/<ID>/operations` 是 **404**（没有这个端点），别指望按 operation 轮询。

---

## P-19 端口转发断了不会自动重连

**症状**：`instabox port-forward` 返回过 "Forwarding ..." 之后，本地端口突然全部连不上。

**根因**：`Forwarding` 只是绑定成功的提示。底层 SSH 通道断开（`client_loop: send disconnect: Connection reset`）后，
命令退出，没有重连逻辑。

**修法**：包一层循环。

```bash
while true; do
  instabox port-forward <MACHINE> 6081:6081 5099:5099
  echo "[$(date +%T)] tunnel down, retry in 5s"; sleep 5
done
```

或者扫码/调试完成后就关掉，别长期挂着。

---

## P-20 CLI 的 stderr 噪音会误导你判失败

**症状**：

```
TLS handshake timeout
instabox 0.8.173 is outdated (latest 0.8.186)
```
命令却实际成功了。

**根因**：CLI 把这些打到 stderr，配合 `$ErrorActionPreference='Stop'` 会让 PowerShell 把它当终止性错误；
`docker` 的拉镜像进度行同理（`NativeCommandError`）。

**修法**：

```powershell
$ErrorActionPreference = 'Continue'     # 不要 Stop
# 传输类命令加重试，并把 stderr 吞掉
for ($i=0; $i -lt 3; $i++) {
  instabox push $m $src $dst 2>$null
  if ($LASTEXITCODE -eq 0) { break }
  Start-Sleep -Seconds 5
}
```

**判成功的依据是退出码与目标端校验**（`sha256sum`），不是 stderr 有没有字。

---

## 附：一次性诊断脚本的命名

工程里积累了大量 `_` 前缀的一次性脚本（`_check.sh` / `_diag.sh` / `_probe.sh`）。
规则：**`_` 前缀 = 一次性，不进交付物**；不带前缀 = 可复用，要写进 `scripts/`。
这条规则救过一次交付：bulk 包里 130+ 脚本里有 100+ 是一次性的，打包时直接排除，体积从 9.3 GB 降到 612 MiB
（另一个大头是 10.4 GB 的 Windows TTS 语音包，Linux 上用不了，必须排除）。
