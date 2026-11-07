# 01 架构与取舍

## 1.1 三个角色为什么必须这样切

### SnowLuma 必须跑在容器里

SnowLuma 的工作原理是**把 OneBot 协议实现注入到真实的 QQ 客户端进程里**（QQ 是 Electron/Chromium）。
它需要：

- `--cap-add=SYS_PTRACE`：ptrace 注入
- `--security-opt seccomp=unconfined`：默认 seccomp 会拦掉注入所需的系统调用
- `--shm-size=1gb`：Chromium 的共享内存

这三条意味着它天然属于容器。宿主直装也能跑，但污染面大、回滚难。

**它只能扫码登录**，没有密码/协议登录路径。所以部署必然包含一次人工介入（noVNC 里扫码）。

### DSH Web 与 SurfCore 桥必须同网络命名空间、走回环

这是整套架构里最容易改错、改错后最难查的一条。

SurfCore 的 `src/dsh-client.js` 在连接 DSH 时做两件事：

1. 拼 baseUrl；
2. 若 `isLoopbackBase(baseUrl)` 成立，就用 `$DSH_HOME/.credentials.yaml` 里的 `client-connection/browser-session` secret **在本地离线铸造 `dsh-auth-*` Cookie**，直接带给 DSH。

一旦 baseUrl 写成 `http://dsh-web:3080`（容器服务名），`isLoopbackBase()` 返回 false，铸造路径被跳过，DSH 侧收到匿名请求 → 401 → 桥永远停在「DSH 未就绪」。

所以只有两条合法路径：

- **成立**：DSH 跑在宿主，桥也跑在宿主，baseUrl = `http://127.0.0.1:3080`。
- **成立**：桥跑在容器，但容器 `network_mode: host` 或与 DSH 同 `--network container:<dsh>`。
- **不成立**：桥在 `qqbot` bridge 网络里，靠服务名访问 DSH。会 401。

本仓库选第一种：两个 systemd unit 都跑在宿主，只有 SnowLuma 在容器里。
桥访问 SnowLuma 走容器名 `ws://snowluma:3001` 没问题 —— 那一侧用的是 OneBot accessToken，不是 DSH Cookie。

### 为什么弃用 AstrBot

原始工程是 AstrBot + SnowLuma 双容器。迁移时发现：

- AstrBot 的反向 WS 端口 6199 只是**又多一层转发**，SurfCore 可以直接吃 OneBot 3000/3001；
- AstrBot 自带数据卷、插件体系、provider 配置，全都需要跟着迁，收益与成本不成比例；
- 两者同时在线会**双回复**（都订阅同一个 QQ 账号的事件流）。

结论：B 方案里 AstrBot 停掉（不删，便于回滚），`onebot.json` 的 `wsClients` 里指向 6199 的反连也要清掉，否则 SnowLuma 每 5 秒报一次 `ENOTFOUND astrbot` 刷屏。

### 为什么弃用 dsh-llm-gateway

`dsh-llm-gateway` 的作用是把 DSH 的凭据转成 DeepSeek 官方 API 的中转，喂给 AstrBot 的 provider。
AstrBot 不在了，它就没有消费者。更关键的是：**只要它还在跑，就可能走用户自己的 DeepSeek 账号额度**（见 `docs/07-optional.md` 的额度隔离一节）。

## 1.2 数据流

```
QQ 服务器
   │ (真实 QQ 客户端协议)
   ▼
snowluma 容器
   │ OneBot v11  ws://snowluma:3001  /  http://snowluma:3000
   ▼
surfcore-bridge.service  (宿主)
   │ ① 事件进入 → 白名单过滤 → 按会话 key 唤醒策略判定
   │ ② 命中 → 组装人格 + 记忆 + 会话上下文 → 调 DSH
   ▼
dsh-web.service (宿主 127.0.0.1:3080)   ← HMAC 铸造的 dsh-auth-* Cookie
   │ ③ 推理（模型由 profile 决定）
   ▼
surfcore-bridge.service
   │ ④ 工具调用 qq_send_message / qq_send_burst / qq_reply
   ▼
snowluma 容器 → QQ 服务器
```

**单向依赖，无环**。桥是唯一的状态持有者；DSH 与 SnowLuma 都是无状态/弱状态服务，可以独立重启。

## 1.3 目录布局（目标机）

```
/data/qqbot/
├── compose/                 docker-compose.yml + .env
├── config/                  onebot.json（模板，用于覆盖容器内生成物）
├── surfcore/                SurfCore 源码 + config.json + state/
├── surfcore-bridge.log      桥日志（append-only，验收要看）
├── dsh-home/                DSH_HOME：凭据、profile、会话、插件
│   ├── .credentials.yaml
│   └── profiles/web/
├── dsh-web/                 DSH 安装（node_modules/@deepseek-ai/dsh/lib/bin.js）
├── qq-client-data/          SnowLuma 数据卷挂载点（QQ 登录态在这里）
├── secrets/                 共享凭据（600）
└── scripts/                 healthcheck / postscan 等
```

`.credentials.yaml` 里只需要一条记录：`client-connection/browser-session`。
它是桥铸造 Cookie 的 HMAC 密钥，**不是任何 LLM 供应商的 key**。这一点很关键，见 `docs/07-optional.md`。

## 1.4 与「纯容器化」方案的取舍

| 维度 | 全容器 | 本方案（容器 + 宿主 systemd） |
|---|---|---|
| DSH Cookie 铸造 | ✗ 需 `network_mode: host`，与 SnowLuma 端口冲突 | ✅ 天然回环 |
| 进程保活 | `restart: unless-stopped` | systemd `Restart=always` |
| 升级 DSH | 重建镜像 | `pnpm/npm i` + `systemctl restart` |
| 快照/恢复 | 具名卷 | 目录（DSH_HOME 直接可拷） |
| 调试 | `docker exec` | 直接读日志文件 |

宿主 systemd 在调试和快照上更省事，代价是需要管两个 unit 文件。

## 1.5 端口矩阵

| 端口 | 归属 | 绑定 | 用途 | 是否对外 |
|---|---|---|---|---|
| 3000 | snowluma | 容器内 0.0.0.0 | OneBot HTTP | ✗ 只在 `qqbot` 网络 |
| 3001 | snowluma | 容器内 0.0.0.0 | OneBot WS | ✗ 同上 |
| 3080 | dsh-web | 宿主 127.0.0.1 | 推理 API | ✗ 回环 |
| 3100 | surfcore | 宿主 127.0.0.1 | 控制台 | ✗ 回环，靠 port-forward |
| 5099 | snowluma | `127.0.0.1:5099` | WebUI | ✗ port-forward |
| 6081 | snowluma | `127.0.0.1:6081` | noVNC 扫码 | ✗ port-forward |
| 6185 | astrbot | `127.0.0.1:6185` | AstrBot WebUI（遗留） | ✗ |

**不要 publish 3000/3001**。OneBot 端口一旦公开且 token 泄漏，等于把 QQ 账号交出去。
