# 连接稳定性诊断报告

诊断时间：2026-11-17 18:16（本地 / 中国标准时间）
桥接版本：v0.7.2，进程 PID 16688（17:46:40 启动），cloudflared PID 19144（17:46:41 启动）
实测运行时长：约 30 分钟 → 期间已发生 1 次 edge 断连 + 2 次连接被强制重置，这就是"稳定性差"的直接体感。

---

## 一、核心元凶：所有流量被 VPN（Vortex / Clash 内核 TUN）接管并绕道东京

实测数据：

| 项目 | 实测值 |
|---|---|
| 默认路由 metric 0 | `Meta` TUN 网卡 → 198.18.0.2（VPN 接管全局） |
| DNS 解析 `region1.v2.argotunnel.com` | **198.18.0.15**（fake-ip，Clash 内核劫持 DNS） |
| cloudflared 实际连的 edge IP | **198.18.0.16**（同样的 fake-ip 段） |
| cloudflared 落地节点 | `location=nrt14` = **东京** |
| 代理进程 | `com.vortex.helper.exe` (PID 8060) 监听 127.0.0.1:7897 |
| 桥接进程继承的环境变量 | `HTTP_PROXY/HTTPS_PROXY=http://127.0.0.1:7897` |

cloudflared 自身日志（`/api/tunnel/status` 实时读取）：

```
10:10:55Z INF Lost connection with the edge connIndex=0
10:10:55Z ERR Serve tunnel error error="connection with edge closed" connIndex=0 ip=198.18.0.16
10:10:55Z INF Retrying connection in up to 2s connIndex=0
10:10:55Z ERR failed to serve incoming request error="failed to proxy HTTP: Incoming request ended abruptly: context canceled"
10:10:55Z ERR failed to serve incoming request error="Error shutting down control stream: client disconnected"
10:10:58Z INF Registered tunnel connection ... location=nrt14 protocol=http2
```

结论：你的手机 → Cloudflare 边缘 → **东京节点** → Vortex 代理 → 本机 8765。
这条链路有三段不可控跳跃，任何一段抖动，WebSocket 立刻断。
手机走蜂窝网络时还要再多绕一跳，所以"本地连接"体感极差。

---

## 二、第二个硬伤：`--protocol http2` 把隧道压成单连接

`bridge/tunnel_manager.py:83-89` 强制 `--protocol http2`。
QUIC（默认）会开 4 条到边缘的连接，掉 1~2 条不影响服务；
http2 模式只有 **1 条** TCP 连接，一断就是整条隧道全断（HTTP 502 + WS 全掉）。
日志里 `connIndex=0` 反复掉线重连就是这个模式的特征。

配合 Quick Tunnel（`*.trycloudflare.com`，Cloudflare 官方明确说明"仅供测试、无 SLA、有速率限制"），稳定性天然垫底。

---

## 三、第三个硬伤：cloudflared 死后无人拉起（无监督）

`tunnel_manager.py:138-142`：进程退出只会把 `status` 改成 `"exited"`，
**没有任何重启循环**。一旦 cloudflared 崩溃/被杀，公网 URL 依然留在 config.json 里，
手机端会一直 502 / 永远"重连中"，必须人工重启整个服务。

`start_bridge.bat` 也只是 `python bridge\server.py` + `pause`，没有守护、没有开机自启、没有崩溃自拉。

---

## 四、第四个硬伤：Windows 上 asyncio 监听套接字被"烧毁"（最致命）

`data/bridge.log` 中的确凿证据：

```
16:51:15 [ERROR] Accept failed on a socket
    socket: <asyncio.TransportSocket fd=408, laddr=('0.0.0.0', 8765)>
    OSError: [WinError 64] 指定的网络名不再可用。
```

WinError 64 出现在 ProactorEventLoop 的 accept 协程时，**监听循环直接终止**：
进程还活着、端口还在 Listen，但从此再也 accept 不到任何新连接。
时间线吻合：**16:51 断 → 17:46 人工重启（55 分钟完全不可用）**。

触发原因正是第一条：VPN TUN 网卡切换 / NDIS 适配器重置。
另有 14:00:30 的 `NDIS 10317 微型端口 Apple Mobile Device Ethernet 已重置`（iPhone USB 共享网卡被重置）记录。

随后 18:05:14 还出现两条：
```
ConnectionResetError: [WinError 10054] 远程主机强迫关闭了一个现有的连接。
```

---

## 五、第五个硬伤：客户端没有"假在线"检测 → 表现为卡死/延迟很久才发现

`web/app.js:498-551`：

1. 服务端 25s 发一次 `{"type":"ping"}`，客户端 `if (msg.type === "ping") return;` **直接丢弃**，
   不记录最后收包时间 → 半死连接（隧道断了但 TCP 未 FIN）会一直显示"已连接"。
2. `visibilitychange` 只在 `readyState !== OPEN` 时才重连；
   而半死连接 readyState 仍然是 **OPEN**，所以切回前台也不会重连 → 只能手动刷新页面。
3. 重连是固定 `setTimeout(2000)`，**没有指数退避 / 抖动**：
   隧道真断时会每 2 秒无限轰炸，既耗电也容易被边缘限速。
4. `ws.onerror` 只做 `ws.close()`，不记录原因，无法排查。

服务端 `bridge/server.py:789-796` 同样缺少写超时：
`await websocket.send_json(ev)` 在半死连接上可能**永久阻塞**（TCP 缓冲区满），
该会话的事件泵就卡死，且 `finally: sess.unsubscribe(queue)` 永远不执行（队列泄漏、内存增长）。

---

## 六、次要问题

- `bridge.log` 用 `FileHandler` 无轮转，且把 httpx 的每条请求都记 INFO，长期会无限增长。
- uvicorn 未显式配置 `timeout_keep_alive` / `ws_ping_interval`（默认值可用，但与自研 25s ping 重复，掩盖了真实链路状态）。
- 隧道重启后 trycloudflare 域名会变，PWA 缓存的旧地址会 1033/530，而客户端没有"URL 变更"提示逻辑。

---

## 七、修复优先级（按收益排序）

| 优先级 | 修复项 | 预期效果 |
|---|---|---|
| P0 | **给 cloudflared 与桥接加白名单，直连不走 VPN**（或让 Vortex 对该进程/域名走 DIRECT） | 链路从 3 跳变 1 跳，延迟与掉线率大幅下降 |
| P0 | `--protocol` 改回 **quic**（或 `auto`），4 条 edge 连接冗余 | 单连接抖动不再全断 |
| P0 | 给 cloudflared 加**自动重启监督循环**（退避重启，上限告警） | 崩溃后自愈，无需人工 |
| P0 | **修 WinError 64 监听烧毁**：桥接自检（自己 connect 一次 /api/health 失败即自重启）+ 守护进程 | 消除 55 分钟级全断 |
| P1 | 客户端加"心跳超时检测"（>45s 无任何消息即判定已死 → 强制重连）+ 指数退避重连 + 前台恢复立即重连并 `after_seq` 补拉 | 消除"假在线卡死" |
| P1 | 服务端 `send_json` 加 `asyncio.wait_for(..., 10s)` 超时，失败即关闭并退订 | 消除事件泵卡死与队列泄漏 |
| P2 | 想彻底稳：改用**命名隧道 + 固定域名**（`cloudflared_token`），或**局域网直连**（手机与 PC 同 Wi-Fi 时直接打 `http://192.168.31.x:8765`，完全绕开公网） | 从"测试级"升级到"可用级" |
| P2 | 日志轮转（RotatingFileHandler，10MB×3）+ httpx 降为 WARNING | 长期运行不爆盘 |

---

## 八、一句话总结

不是桥接代码"逻辑错了"，而是**三重外部不确定性（VPN 全局透明代理 + 东京中转 + trycloudflare 单连接快隧道）叠加 Windows asyncio 的 accept 烧毁缺陷和客户端零假在线检测**，
导致"链路一抖就断、断了不自愈、界面还以为连着"。
按 P0 四项修完，体感会从"每分钟担心掉线"变成"基本无感"。
