# systemd units

Copy to `/etc/systemd/system/`, edit the paths/user, then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now dsh-web.service surfcore-bridge.service
```

Both units share one requirement: **the bridge must reach DSH on a loopback
address**. That only works when they run in the same network namespace, i.e.
both on the host (this is why they are not containers).

---

## dsh-web.service

```ini
[Unit]
Description=DSH Web (headless, loopback)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=user
Group=user
Environment=DSH_HOME=/data/qqbot/dsh-home
Environment=TZ=Asia/Shanghai
WorkingDirectory=/data/qqbot/dsh-web
# MUST be /bin/bash on Debian; /usr/local/bin/bash does not exist there
# and gives status=203/EXEC.
ExecStartPre=/bin/bash -lc 'test -f /data/qqbot/dsh-web/node_modules/@deepseek-ai/dsh/lib/bin.js'
ExecStart=/usr/local/bin/node /data/qqbot/dsh-web/node_modules/@deepseek-ai/dsh/lib/bin.js web --no-open --host 127.0.0.1 --port 3080
Restart=always
RestartSec=5
StandardOutput=append:/data/qqbot/logs/dsh-web.log
StandardError=append:/data/qqbot/logs/dsh-web.log

[Install]
WantedBy=multi-user.target
```

Startup takes ~10-15s (plugin scan). Verify with:

```bash
systemctl is-active dsh-web.service
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3080/   # 401 = good
```

---

## surfcore-bridge.service

```ini
[Unit]
Description=SurfCore bridge (QQ <-> DSH)
After=network-online.target dsh-web.service
Wants=dsh-web.service

[Service]
Type=simple
User=user
Group=user
Environment=DSH_HOME=/data/qqbot/dsh-home
Environment=DSH_WEB_URL=http://127.0.0.1:3080
Environment=SNOWLUMA_HOME=/data/qqbot/qq-client-data
Environment=TZ=Asia/Shanghai
Environment=NODE_ENV=production
WorkingDirectory=/data/qqbot/surfcore
ExecStart=/usr/local/bin/node /data/qqbot/surfcore/src/bridge.js
Restart=always
RestartSec=5
StandardOutput=append:/data/qqbot/surfcore-bridge.log
StandardError=append:/data/qqbot/surfcore-bridge.log

[Install]
WantedBy=multi-user.target
```

`surfcore-bridge.log` is append-only and the acceptance script reads it, so keep
the path stable. Add a logrotate rule (50 MiB × 3) so it cannot fill the 20 GiB disk.

---

## Notes

- **`sudo` is required** for `systemctl restart`. Without it you get
  `Access denied` and rc=4, which looks like a broken unit (P-12).
- **`TZ=Asia/Shanghai` matters** for anything time-scheduled. The host is
  usually UTC, so without it every "07:00" fires at 15:00 Beijing time.
- **`Restart=always`** covers crashes but not a hung event channel. If the
  bridge stops receiving QQ events while staying `active`, only a manual
  restart helps (P-10) — add an external line-count probe.
