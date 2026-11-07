# 07 非必需组件

本文件把「锦上添花」和「必须」划清界线。**P0–P7 走完不需要这里的任何东西。**
它们是在主链路跑通之后，按用户需求逐个加的。

---

## 7.1 AstrBot（**已弃用**）

原方案里 AstrBot 是 bot 框架，SnowLuma 通过 `ws://astrbot:6199/ws` 反连它。

**为什么弃用**：

- SurfCore 能直接吃 OneBot 3000/3001，多一层转发无收益
- AstrBot 的数据卷、插件、provider 配置全都要跟着迁，成本与收益不成比例
- 两者同时在线 = **双回复**（都订阅同一 QQ 账号事件流）

**弃用后必做**（否则刷屏）：

```bash
docker compose --env-file .env stop astrbot      # 停，但别 down（保留回滚）
```

同时清掉 `onebot.json` 里的反连，否则 SnowLuma 每 5 秒报一次：

```
[OneBot.WS-Client] [astrbot] error ws://astrbot:6199/ws: getaddrinfo ENOTFOUND astrbot
```
近 200 行日志里 186 行是这个。

若只是想保留 AstrBot 但不要双回复：删掉 `wsClients` 里的 astrbot 项，或 `enabled: false`。

---

## 7.2 dsh-llm-gateway（**已弃用，且涉及额度**）

作用：把 DSH 凭据转成 DeepSeek 官方 API 的中转，供 AstrBot 的 provider 使用。

**为什么必须停**：它是**唯一会走用户自己 DeepSeek 账号额度**的路径。
AstrBot 不在之后它没有消费者，留着纯属风险。

```bash
docker compose --env-file .env stop llm-gateway
```

---

## 7.3 WorkBuddy provider 插件（**推荐，解决额度 + 图片**）

### 它解决什么

默认的 `deepseek-account` provider 用的是**用户自己的 DeepSeek 平台账号 token**，两个问题：

1. 消耗用户额度
2. 该模型没声明 image 输入 → **图片/表情会退化成文字标签**

`dsh-connect-workbuddy` 换成 WorkBuddy 账号，且其 `deepseek-v4.1-flash` 声明为 `multimodal`。

### 安装（三步）

```bash
# 1. 凭据：把 WorkBuddy 的 vault 放到位
#    来源：本机 <DSH_HOME>/workbuddy-vault/cn/<24-hex>.json
mkdir -p /data/qqbot/dsh-home/workbuddy-vault/cn
chmod 700 /data/qqbot/dsh-home/workbuddy-vault /data/qqbot/dsh-home/workbuddy-vault/cn
cp <vault.json> /data/qqbot/dsh-home/workbuddy-vault/cn/
chmod 600 /data/qqbot/dsh-home/workbuddy-vault/cn/*.json

# 2. 加依赖 + bundle
#    profiles/web/package.json:
#      dependencies["dsh-connect-workbuddy"] = "5.17.0"
#      dsh.profile.bundles 里加 "dsh-connect-workbuddy"
DSH_HOME=/data/qqbot/dsh-home node .../bin.js plugin --profile web install

# 3. 重启
sudo systemctl restart dsh-web.service surfcore-bridge.service
```

### 为什么 vault 文件就够，不需要桌面端

源码 `dsh-connect-workbuddy/lib/host-heartbeat-*.js` 的 `scanAll()`：
先扫 desktop auth 候选文件 → 再读插件自有 `.workbuddy-auth.json` → **最后 `syncVault()` 把 vault 条目合并进扫描结果**。

```js
if (existing === void 0) scan.set(id, entry.credential);   // :7585-7592
```

vault 目录 = `join(resolveDshHome(), "workbuddy-vault", region)`，`region` 由域名决定：
`www.workbuddy.cn` → `cn`。文件须命名 `<24位hex>.json`，`version: 1`。

### 额度物理隔离（**硬要求**）

装完插件后，从 `<DSH_HOME>/.credentials.yaml` 里**物理删除**用户自己账号的凭据：

```yaml
# 删掉这些
records:
  deepseek-account-platform/default      # ← 用户 token
  deepseek-account-platform/device       # ← 设备 id
refs:
  BAOMIAO_API_KEY: ...                   # ← 也删

# 只保留
records:
  client-connection/browser-session      # HMAC 必需，不是 LLM key
```

验证（应全是 0）：

```bash
grep -c '<用户token前12位>' /data/qqbot/dsh-home/.credentials.yaml    # 0
grep -c 'BAOMIAO' /data/qqbot/dsh-home/.credentials.yaml              # 0
grep -c 'browser-session' /data/qqbot/dsh-home/.credentials.yaml      # 1
stat -c '%a' /data/qqbot/dsh-home/.credentials.yaml                   # 600
```

> 这一步的意义：**即使插件以后被卸载/配置回退，也不存在能消耗用户额度的凭据**。
> 从"配置正确"升级为"物理上不可能"。

### 验证确实走了 WorkBuddy

```bash
grep -E '已设置会话模型|回退到目录|未声明 image' /data/qqbot/surfcore-bridge.log | tail -5
```

期望：`已设置会话模型 ... -> workbuddy/deepseek-v4.1-flash (low)`
不该出现：`回退到目录中的 deepseek-account/deepseek-flash`、`未声明 image 输入`

### 回滚

```bash
cp .credentials.yaml.bak-wb .credentials.yaml
cp profiles/web/package.json.bak-wb profiles/web/package.json
sudo systemctl restart dsh-web.service surfcore-bridge.service
```

---

## 7.4 B站定时分享（**可选，依赖外部 API**）

功能：从 B站收藏/日记里挑素材，定时往指定群发「视频卡片 + 2~3 句短评」。

### 它需要什么

| 项 | 位置 | 说明 |
|---|---|---|
| B站 cookie | `<HOME>/.dsh/surfcore/bili/credentials.json` | `sessdata` + `bili_jct` + `buvid3` **三者都非空** |
| 账号信息 | `<HOME>/.dsh/surfcore/bili.config.json` | `self.mid/name`、`owner.mid/name` |
| 账本 | 同目录 `whale-diary.md` / `favorites.json` / `quota.json` | 缺则 `entries: 0` |
| 开关 | `surfcore/config.json` 的 `biliBridge.share.enabled` | 默认 false |

注意 `HOME` 是**桥进程的 HOME**，不是 `DSH_HOME`。查法：

```bash
systemctl show surfcore-bridge.service -p Environment
# 桥进程若是 User=user，则 HOME=/home/user 或 /data/home
```

### 必须凑齐的三个前置

1. **`buvid3` 非空**。`hasCredentials = Boolean(sessdata && bili_jct && buvid3)`，少一个就报"缺少 B 站凭据"。
   自取：
   ```bash
   curl -s https://api.bilibili.com/x/frontend/finger/spi
   # data.b_3 -> buvid3, data.b_4 -> buvid4
   ```
2. **`self.mid` / `self.name` 非空**。为空时记忆简报会写成占位名 `「B站账号」`。
3. **账本文件存在**，否则 `entries: 0 / shareable: 0`。

### 时区（很隐蔽）

分享时间点 `times: ["07:00", ...]` 按**进程 TZ** 解释。宿主是 UTC 时，"07:00" 实际是北京时间 15:00。

```bash
timedatectl    # Time zone: Etc/UTC  ← 有问题
```

修：给两个 systemd unit 都加 `Environment=TZ=Asia/Shanghai`（写完 `daemon-reload` + 重启）。

### 已知限制：412

机房 IP 调 `api.bilibili.com/x/web-interface/view` 常被风控回 **412**（HTML 反爬页）。
判据：**带 cookie 与不带 cookie 都是 412** → 是 IP 级风控，不是凭据问题。

影响：动态同步（dynamics）不可用；**分享本身仍可用**（素材来自本地账本，不依赖实时 API）。

### 分享 prompt 必须自带 key 与 token

分享走的是 `deliverPrompt(key, prompt)`，**不经过** `buildWakePromptV2`，所以默认**不注入** `【会话令牌】`。
AI 会卡在"工具返回 token 无效"，然后吐出「❓ agent 需要你回答：」。

修：给 deliver 包一层，把令牌 + 本群 key 直接拼进 prompt（见 `docs/06-pitfalls.md` P-14）。

---

## 7.5 群聊唤醒概率（**建议一定要调**）

默认 `probability = 0.05`。若非大群（`member_count` 小）、没人 @、也没打关键词，**基本永远不醒**。

症状：私聊正常，群里像死了一样。

```bash
# 看当前值
jq '.conversations["group:<gid>"].wakeConfig' /data/qqbot/surfcore/state/social-v2.json
```

改法（两种）：

**A. 走 API**（有沉睡前观察守卫，可能被拒）：

```bash
POST /api/socialV2/wake-config
{"key":"group:<gid>","config":{"mode":"diving","infinite":true,
  "triggers":{"atMention":true,"nameMention":true,"question":true,"poke":true,
              "anyMessage":false,"probability":1.0}}}
```
被拒时返回 `preSleepWaitMs: 300000` + 剩余时间。

**B. 停桥改文件**（绕过守卫，本仓库实证可用）：

```bash
sudo systemctl stop surfcore-bridge.service
python3 -c "import json;p='/data/qqbot/surfcore/state/social-v2.json';d=json.load(open(p));d['conversations']['group:<gid>']['wakeConfig']['triggers']['probability']=1.0;json.dump(d,open(p,'w'),ensure_ascii=False,indent=2)"
sudo systemctl start surfcore-bridge.service
```

> `POST /api/socialV2/wake` 是**手动唤醒一次**，不是改配置。改配置是 `/wake-config`。
> 两者名字太像，踩过。

**相关限流**（`config.json` 的 `socialV2.wake`）：

| 键 | 默认 | 调高到 | 作用 |
|---|---|---|---|
| `maxWakePerMinute` | 1 | 6 | 每分钟最多醒几次 |
| `maxWakePerHour` | 12 | 120 | 每小时上限 |
| `noActionLimit` | **3** | 1000 | **连续 N 次醒了没说话 → wakeConfig 被重置回默认（probability 变 0.05）** |
| `batchWindowMs` | 8000 | 3000 | 多条消息合并窗口 |

`noActionLimit` 是最阴的：不调高就会在几次"醒了但没插话"之后**静默退回 5%**，表现为"调过又变回去"。

---

## 7.6 B站人格记忆 / 生物钟

`[surfcore] 生物钟未启动：B站 还没登录` 是无害日志 —— 生物钟是「按 B站活动时间推断作息」的可选模块，
不登录只是不启用，不影响聊天。

---

## 7.7 人格与记忆

本仓库**不内置人格**。SurfCore 侧需要：

```
<DSH_HOME>/surfcore/characters/<char-id>/
├── character.json        {"version":1,"id":"...","name":"...","persona":"persona.md",...}
├── persona.md            人格正文
├── memory/               长期记忆
└── purpose-outreach.json 主动搭话的目标假设
```

没有角色包时桥仍能跑，只是没有"人味"。若要迁移现有人格，整目录拷过去 + `character.json` 的 `id` 保持一致。

---

## 7.8 一张表：加这些要不要

| 组件 | 加它的收益 | 不加的后果 | 建议 |
|---|---|---|---|
| WorkBuddy provider | 不烧用户额度 + 支持图片 | 烧额度、图片退化成文字 | **加** |
| 群聊 probability | 群里会说话 | 群里像死的 | **加** |
| 人格角色包 | 有人味 | 机器人腔 | 看需求 |
| B站分享 | 定时内容投喂 | 无 | 看需求 |
| AstrBot | 无 | 无（且更干净） | **不加** |
| llm-gateway | 无（且有额度风险） | 无 | **不加** |
