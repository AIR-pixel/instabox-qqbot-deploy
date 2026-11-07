# 02 前置条件

## 2.1 你需要准备什么

| 项 | 说明 | 强制 |
|---|---|---|
| InstaBox 账号 | Free 档可跑；需要能 `resume` 一台机 | ✅ |
| InstaBox API key | `ibk_` + 52 字符；写进 `credentials.json` 的 **`apiKey`** 字段 | ✅ |
| 一台机器 | 4 vCPU / 8 GiB 足够；20 GiB 盘要省着用（见 2.4） | ✅ |
| 目标 QQ 号 | 能扫码登录；**部署期间不要在别的设备上登录同一号** | ✅ |
| LLM 凭据 | 二选一：WorkBuddy 账号（推荐）/ DeepSeek 平台 token | ✅ |
| 管理员 QQ | 白名单里的主人号，用于免打扰过滤与 owner 权限 | 建议 |

## 2.2 本机（操作端）需要什么

- **git**（可选，用于取本仓库）
- **curl** 或 PowerShell
- **ssh**（可选，走 `instabox exec` 时未必需要）
- InstaBox CLI，或直接用 HTTP API（`docs/08-facts.md` 有端点表）

> **Windows 操作端注意**：PowerShell 5.1 把命令传给原生 exe 时会吃掉内层双引号。
> 所有远程命令请走「写 `.sh` → 上传 → 执行 → 拉结果文件」，不要拼 `bash -lc '...'`。
> 详见 `docs/06-pitfalls.md` P-01。

## 2.3 凭据怎么放

### InstaBox API key

CLI 与保活脚本都从 `credentials.json` 读：

```json
{
  "server": "https://api.instabox.sh",
  "apiKey": "ibk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
}
```

查找顺序（任选其一）：
1. `$XDG_CONFIG_HOME/instabox/credentials.json`
2. `~/.config/instabox/credentials.json`
3. `%LOCALAPPDATA%\instabox\credentials.json`

**字段名必须是 `apiKey`**。写成 `accessToken` 会被当成设备码登录的会话 token，报
`instabox: session expired; run 'instabox login'`（P-03）。

### DSH 凭据

目标机 `<DSH_HOME>/.credentials.yaml`，**最少只要一条**：

```yaml
version: 1
records:
  client-connection/browser-session:
    kind: grant
    secret: <48 字符随机串>
refs: {}
```

这条 secret 的用途：SurfCore 用它 HMAC 出 `dsh-auth-*` Cookie，证明"我是本机已授权的桥"。
它**不是** LLM key。LLM 凭据走 provider 插件自己的存储（见 `docs/07-optional.md`）。

生成：

```bash
openssl rand -base64 36 | tr -d '\n=+/' | head -c 48
```

权限必须 600，目录 700。

## 2.4 磁盘预算（20 GiB 很紧）

| 项 | 约占用 | 备注 |
|---|---|---|
| 系统 + Docker | 5–6 GiB | 不能省 |
| snowluma 镜像 | ~1.5 GiB | |
| QQ 客户端数据 | ~1 GiB | 增长缓慢 |
| DSH (`node_modules`) | ~1.5 GiB | |
| SurfCore + 依赖 | ~0.4 GiB | |
| 会话/日志/记忆 | 增长中 | 需轮转 |

**踩过的坑**：SnowLuma 容器里会生成 `/app/core`（QQ 崩溃转储），`ls` 看着 21 GiB，实际是稀疏文件只占 54 MiB。
别被 `du --apparent-size` 吓到；用 `du -sh` 看真实占用。

日志轮转：`surfcore-bridge.log` 是 append-only，验收脚本靠它，但也要限制。建议 logrotate 50 MiB × 3。

## 2.5 平台限额（决定可行性）

Free 档（详见 `docs/08-facts.md`）：

- 1 台机；`running at once` = 1
- 4 vCPU / 8 GiB；盘 20 GiB **固定**，不可扩
- 空闲 30 分钟自动暂停（**不可改**，付费档才能调 5–30 分钟）
- 单次 run 上限 `maxRunMinutes`（读数会变，120/480 都见过）
- Free 档 dynamic runtime：每次新 run 起 2 小时窗口，靠"真干活"续期
- **Starts/minute = 3**（create/start/resume/wake 都算）

这意味着：**免费档做不到 7×24 零中断**。要么接受周期性短暂离线，要么升付费档。
保活方案的完整推导见 `docs/05-keepalive.md`。

## 2.6 部署前检查清单

```bash
# 1. 凭据可用
instabox whoami                       # 期望 EXIT=0，打印 <login> (user <id>) on <server>

# 2. 机器存在且能起来
instabox get <MACHINE> --json | jq '{state,desiredState,runtime.ready,maxRunMinutes,autoSuspendAfterSeconds}'

# 3. 机器里 sudo 免密（部署脚本要用）
instabox exec <MACHINE> -- sudo -n true && echo SUDO_OK

# 4. 机器里 Docker 可用
instabox exec <MACHINE> -- docker version --format '{{.Server.Version}}'

# 5. 机器里 Node 版本（SurfCore 要求 >= 22.13.0）
instabox exec <MACHINE> -- node -v

# 6. 磁盘空余（至少 10 GiB）
instabox exec <MACHINE> -- df -h /data
```

六项全过再进 P1。任何一项不过，先修它 —— 后面每一步都建立在它上面。

## 2.7 需要用户提供的信息

部署开始前一次性问清，避免中途打断：

1. 目标 QQ 号（`<UIN>`）
2. 管理员/主人 QQ 号（`<OWNER_QQ>`）
3. 允许响应的私聊白名单（默认只有 owner）
4. 允许响应的群号列表（可空）
5. 人格设定（本仓库不内置人格；需一份 `persona.md` 或明确说"用默认"）
6. LLM 凭据来源（WorkBuddy / DeepSeek 平台 / 其它）
