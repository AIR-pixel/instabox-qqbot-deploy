# 04 验收与排障

## 4.1 唯一权威验收

```bash
bash /data/qqbot/scripts/healthcheck-b.sh
# 期望：== RESULT: PASS (fail=0) ==
```

9 项检查及判定标准：

| # | 检查 | 通过条件 | 失败含义 |
|---|---|---|---|
| 1 | `dsh-web.service` | `systemctl is-active` = `active` | 推理后端死了 → 看 `journalctl -u dsh-web -n 80` |
| 2 | `surfcore-bridge.service` | 同上 | 桥死了 → 看 `surfcore-bridge.log` 尾部 |
| 3 | DSH 匿名访问 | `curl 127.0.0.1:3080/` = **401** | `000`=没起；`200`=鉴权栅栏没开 |
| 4 | QQ 在线 | `/get_login_info` = **200** | 掉线 → 重新扫码（P-09） |
| 5 | snowluma 容器 | `docker inspect .State.Running` = `true` | 容器崩 → `docker logs` |
| 6 | astrbot 已停 | `.State.Running` = `false` | 还在跑 → 会双回复 + 6199 刷屏 |
| 7 | 桥连上 SnowLuma | 日志含 `SnowLuma 已连接` | token 不匹配 / 3001 不通 |
| 8 | 桥 DSH 就绪 | 日志含 `DSH 已就绪` | **baseUrl 不是回环**（最常见） |
| 9 | 本次 run 无 preset 拒绝 | 最后一次 `桥接已启动` 之后无 `⛔` | 模型拿错 key / 工具连续报错 |

> **第 9 项的实现细节（很关键）**：日志是 append-only，历史里的 `⛔` 是已修复的旧事件。
> 必须 `awk '/桥接已启动/{n=NR} END{print n+0}'` 找到最后一次启动行，`tail -n +$SINCE` 只看本轮。
> 对整份日志 grep 会永远 FAIL（P-15）。

## 4.2 分层排障路由

按这个顺序查，每层只查一件事：

```
① 进程层     systemctl is-active dsh-web / surfcore-bridge
              ↓ 都 active
② 网络层     ss -tnp | grep -E ':3001|:3080'        有 ESTAB / LISTEN？
              ↓ 有
③ 鉴权层     curl 127.0.0.1:3080/                   401？
              curl snowluma:3000/get_login_info     200？
              ↓ 都过
④ 事件层     docker logs snowluma | grep '\[Event\]' 有进消息？
              ↓ 有
⑤ 决策层     surfcore-bridge.log | grep '忽略未授权会话'   被白名单挡了？
              ↓ 没被挡
⑥ 推理层     grep '已设置会话模型' / '回退到目录'          模型选对了吗？
              ↓ 对
⑦ 发送层     grep '工具统一发送' / snowluma 的 '发送：'     发出去没？
```

每层的判据与常见原因：

### ① 进程层

```bash
systemctl status dsh-web.service --no-pager -l
journalctl -u dsh-web.service -n 60 --no-pager
journalctl -u surfcore-bridge.service -n 60 --no-pager
```

`203/EXEC` → `ExecStartPre` 的 shell 路径错（P-06）。
`status=1` 立刻退出 → 端口被占，或 `DSH_HOME` 权限不对（要 700）。

### ② 网络层

```bash
ss -tnp | grep :3001     # 桥 → snowluma WS
ss -ltnp | grep :3080    # DSH 监听 127.0.0.1
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' snowluma
```

桥进程里 `3001` 连不上：容器名解析失败（桥不在同一 docker 网络？宿主进程解析容器名是靠 docker 的 embedded DNS，需要桥进程能看到 `/etc/hosts` 或走 docker 网关 —— 本方案里 SnowLuma 用 `network: qqbot`，宿主进程通过 `172.18.0.x` 直连；若解析不了，改成容器 IP 或加 `/etc/hosts`）。

### ③ 鉴权层

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3080/            # 401
curl -s -H "Authorization: Bearer $ONEBOT_ACCESS_TOKEN" \
     http://snowluma:3000/get_login_info | head -c 200                     # 200 + user_id
```

`get_login_info` 回 `{"status":"failed","retcode":1403,...}` 或 401 → token 不对。
token 必须同时匹配 SnowLuma `onebot.json` 的 `httpServers[0].accessToken` **和**桥 `config.json` 的 `snowluma.accessToken`。

### ④ 事件层

```bash
docker logs --tail 150 snowluma 2>&1 | grep -E '\[Event\]|bot_status|code='
```

没有 `[Event]` → QQ 根本没收到消息（号掉了，或别人发的是被过滤的消息类型）。
有 `bot_status: offline` / `code=1000` → 会话被踢，且**桥随后会静默死亡**（P-10）。

### ⑤ 决策层

```bash
grep '忽略未授权会话' /data/qqbot/surfcore-bridge.log | tail -5
```

出现即白名单缺失。改 `surfcore/config.json` 的 `allow.private` / `allow.groups`，
**然后 `sudo systemctl restart surfcore-bridge.service`**（P-11：没有热重载）。

### ⑥ 推理层

```bash
grep -E '已设置会话模型|回退到目录|模型不可用|未声明 image' /data/qqbot/surfcore-bridge.log | tail -10
```

`配置模型 X 不可用，回退到目录中的 Y` → profile 里没有 X 这个模型 id。
`未声明 image 输入` → 该模型不吃图片，图片/表情会退化成文字标签。

### ⑦ 发送层

```bash
grep -E '工具统一发送|发送：' /data/qqbot/surfcore-bridge.log | tail -10
docker logs --tail 60 snowluma 2>&1 | grep '发送'
```

桥说成功但 QQ 没收到 → 查 SnowLuma 侧是否有 `发送失败` / `code=`。
桥说 `agent token 无效` → prompt 里给的 key 形式错了（P-14）。

## 4.3 两个典型复合故障

### 故障 A：消息进来了但机器人不回

按顺序排除：

1. `grep '忽略未授权会话'` → 白名单（最常见）
2. `grep '唤醒\|evaluateWakeTrigger'` → 群聊里 probability 太低（默认 5%，几乎不醒）
3. `grep '模型不可用'` → 模型 id 不存在
4. `grep 'DSH 未就绪'` → baseUrl 不是回环

### 故障 B：一段时间不回，之后全都不回

这是**桥事件通道静默死亡**的典型形态，特征：

```bash
wc -l /data/qqbot/surfcore-bridge.log     # 等 15 秒再看，一行没涨
ss -tnp | grep :3001                      # 没有 ESTAB
```

日志尾部会有 `SnowLuma 报告 QQ 账号会话已离线（bot_status: offline）` → `code=1000` →
约 10 分钟后 `已连接但 10 分钟没有收到任何事件包`。

修：

```bash
sudo systemctl restart surfcore-bridge.service
# 期望日志：SnowLuma 已连接 / 桥接模式已确定 / DSH 已就绪
```

这是 SurfCore 的已知薄弱点：**WS 重连后 history 能补、事件流不恢复**。
生产环境建议加一个外部探针：每 5 分钟 `wc -l` 一次，两次相同且桥「应该」有活动时告警。

## 4.4 验收记录该长什么样

一次合格的交付，证据链应包含：

```
healthcheck-b.sh            == RESULT: PASS (fail=0) ==
ss / 端口                   172.18.0.1:xxxxx → 172.18.0.3:3001 ESTAB
get_login_info              {"user_id":<uin>,"nickname":"..."}
桥日志                      唤醒 private:<owner> → 已挂载 preset → 已设置会话模型 → 工具统一发送: 成功 2/2 条
OneBot 日志                 私聊 <owner> | 发送：<正文>
DSH session                 session.v4.jsonl.zstd 存在且大小 > 0
```

**缺最后两行的，只能报"链路就绪"，不能报"部署完成"。**
