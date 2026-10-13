# VPS Radio 使用说明书

> 面向: 从零接手本机的 agent / 运维人员。读完后应能完整操作这套广播服务。
> 写作时间: 2026-09-12, 最后更新 2026-09-21 (新增 Cloudflare WARP 本地 SOCKS5 代理出口，彻底解决 YouTube 机房 IP 人机拦截；优化 Cookie 隔离保护与无轮换导出指南)。服务已部署完毕且运行中。
> 服务器: VPS `<YOUR_VPS_IP>` (Ubuntu 24.04, 2核/4G/50G)

---

## 1. 这是什么

一台 VPS 上跑的**个人网络电台**, 对外地址:

```
https://radio.example.com
```

任何设备打开这个链接就能收听 (浏览器原生支持, 无需 App)。流是 WebRTC 主路 + HLS 备路, 经 Caddy 反代 (根路径即播放页)。管理在 `/admin` (见 §3)。

电台同一时刻只有**一路音频**对外播出, 这路音频来自八种**音源**之一, 可随时热切换:

| 音源 | 说明 | 切换命令 |
|------|------|----------|
| **spotify** | 服务器作为 Spotify Connect 设备 ("VPS Radio")。手机/电脑 Spotify 里选中它, 一按播放, 全世界打开链接的人都在听你放的 | `radioctl spotify` |
| **file** | 服务器上单个音频文件无限循环 | `radioctl file <绝对路径>` |
| **folder** | 一个目录当播放列表: 逐曲播, 播完自动下一首, 一轮播完重扫目录+重新洗牌; 目录空了回落 spotify | `radioctl folder` |
| **netease** | 网易云音乐: 歌单/专辑循环、私人FM、每日推荐、播客电台、搜索点歌。免费/低费歌 320k mp3; VIP 曲需黑胶 cookie (2026-09-13 现为免费账号, VIP 曲自动跳过) | `radioctl netease ...` (§3) |
| **soundcloud** | SoundCloud: 用户 likes/歌单循环、搜索点歌。无登录 (匿名 client_id, 双 surface 自愈刷新); SNIP=30s 试听自动跳过。运行期失败**一律不回落 spotify** (连跳保持音源; 2026-09-15) | `radioctl soundcloud ...` (§3) |
| **bilibili** | Bilibili (B站): 单视频、分P、公开收藏夹、UP主合集/系列、关键词搜索点歌。纯游客 0 账号免登录 (WBI 签名自愈缓存); DASH 纯音频流 (m4s/aac) 直推; >2h 超长音频断点接力守护。运行期失败**一律不回落 spotify** (连跳保持音源; 2026-09-19~20) | `radioctl bilibili ...` (§3) |
| **youtube** | YouTube: 单视频、歌单、Shorts、移动端短链 youtu.be、关键词搜索。原生低延迟直连 Google/YouTube CDN; 本地 Cloudflare WARP SOCKS5 代理出口彻底免疫机房 IP 人机拦截与 403 阻断; 零手动参数 (粘贴任意格式链接自动识别单曲与歌单); DASH Opus 160k 纯音频直推; >2h 超长音频断点接力续播。运行期失败**一律不回落 spotify** (连跳保持音源; 2026-09-20~21) | `radioctl youtube ...` (§3) |
| **bandcamp** | Bandcamp: 单曲、专辑、艺人全库、关键词搜索点歌。纯匿名 0 账号免登录; 原生直接提取 128kbps MP3 纯音频直推; 自动过滤仅付费试听受限曲目; 支持艺人多作品极速并发解析。运行期失败**一律不回落 spotify** (连跳保持音源; 2026-10-10) | `radioctl bandcamp ...` (§3) |

**核心特性: 切换音源/切歌时听众不掉流** (总线常驻, 只换写者), 只有约 0.5~3 秒静音。支持实时 ZMQ 动态音量缩放 (0.1~10.0x) 与播放模式热切换 (repeat/loop/seq/shuffle)。

---

## 2. 架构与进程模型 (理解排障的前提)

```
音源 (同一时刻一个, 可热切换)          常驻总线 (永不动)
┌───────────────────────────┐     ┌───────────────────────────────┐
│ librespot (Spotify 接收)   │────▶│ 音频FIFO → ffmpeg (-re)        │
│ ffmpeg (file 单曲循环)     │────▶│   azmq 音量调节 (0.1~10.0x)   │
│ ffmpeg (folder 逐曲)      │────▶│   s16le/44.1k → Opus 128k     │──▶ MediaMTX ──▶ Caddy ──▶ 听众
│ netease-helper stream     │────▶│   (rtsp://127.0.0.1:8554/live) │    :8554        :443      (WebRTC/HLS)
│   (歌单/播客拉流)          │────▶│                               │
│ soundcloud-helper stream  │────▶│                               │
│   (likes/歌单拉流)        │────▶│                               │
│ bilibili-helper stream    │────▶│                               │
│   (DASH 提取直推/断点守护)│────▶│                               │
│ youtube-helper stream     │────▶│                               │
│   (DASH Opus 直推/接力)   │────▶│                               │
│ bandcamp-helper stream    │────▶│                               │
│   (128k MP3 直推/专辑展开)│────▶│                               │
└───────────────────────────┘     └───────────────────────────────┘
     ▲                                 ▲ radioctl 经 /run/radiod/cmd.fifo 发切换/音量命令
     │                                 │ (音量命令经 /run/radiod/ffmpeg-azmq.sock 即刻生效)
     │ netease-helper 直连明文 API + X-Real-IP
     │ QR 登录走 ncm-api 容器 (127.0.0.1:3000, docker)
     │ soundcloud-helper 匿名 client_id 双 surface 自愈
     │ bilibili-helper 纯匿名 WBI 动态签名与 DASH 流直链提取
     │ youtube-helper 首尔原生直连 Google/YouTube CDN + yt-dlp + deno 运行时
     │ bandcamp-helper 纯匿名免登录数据抓取与并发专辑全库展开
     └─────────────────────────────────────────────────────────────┘
```

### systemd 服务 (6 个相关)

```bash
radiod.service    # 核心: /usr/local/bin/radiod.sh, User=radiod。总线+音源+命令循环+音量控制都在这一个脚本里
mediamtx.service  # 流媒体服务器: 接 RTSP 发布, 分发 WebRTC(:8889)/HLS(:8888)
caddy.service     # HTTPS 反代: radio.example.com 根路径播放页 + /whep 信令 + /hls 备路 + /admin 面板
warp-svc.service  # Cloudflare WARP 客户端后台守护进程: 运行于 proxy 模式, 本地监听 127.0.0.1:40000 SOCKS5 代理, 提供干净出口供 YouTube 等音源解析 (2026-09-21)
ncm-api.service   # 网易云 API 容器 (docker, 127.0.0.1:3000): 仅承担 QR 登录换取 MUSIC_U;
                  #   放歌/取链接不依赖它 (明文 API 直连), 它挂了只是不能重新扫码登录
radio-admin.service # 管理面板后端 (python3, 127.0.0.1:8811): /admin 的 API 层, Caddy 加 basic_auth
                  # 与 radiod 共同持有 RuntimeDirectory=radiod + StateDirectory=radiod (见 §10 坑13):
                  #   面板搜索缓存写 / 网易 cookie 落盘 / CID 自愈刷新 / 音量调节全靠这个 rw 权限
```

`radiod.sh` 内部结构: 起总线 ffmpeg (挂载 azmq 与 volume 滤镜) → 以 O_RDWR 持有音频 FIFO (无缝切换的关键) → 起音源 → 主循环每 0.3s 检查 [总线死? 整链退出] [音源死? folder/netease/soundcloud/bilibili/youtube/bandcamp→下一首 / 其他→回落 spotify] [命令 FIFO 有命令? 处理并把结果写 cmd.result]。

### 关键文件

| 路径 | 说明 |
|------|------|
| `/usr/local/bin/radiod.sh`   | 主脚本 (本说明 §8 有完整源码解读索引) |
| `/usr/local/bin/radioctl`   | 控制命令 (ubuntu 用户执行) |
| `/usr/local/bin/netease-helper` | 网易云辅助: QR 登录/列表/播客/URL 解析/拉流 (radiod 与 ubuntu 共用) |
| `/usr/local/bin/soundcloud-helper` | SoundCloud 辅助: CID 自愈/likes/歌单/搜索/URL 解析/拉流 (2026-09-15) |
| `/usr/local/bin/bilibili-helper`   | B站辅助: 纯游客WBI鉴权/单视频分P/收藏夹/合集与系列/搜索/DASH音频拉流与超长守护 (2026-09-19~20) |
| `/usr/local/bin/youtube-helper`    | YouTube 辅助: 智能URL解析/单视频/歌单批量/关键词搜索/DASH Opus拉流与超长接力 (2026-09-20) |
| `/usr/local/bin/bandcamp-helper`   | Bandcamp 辅助: 智能URL解析/单曲/专辑/艺人全库并发展开/搜索点歌/MP3拉流 (2026-10-10) |
| `/usr/local/bin/spotify-event`     | Spotify Connect 辅助: librespot --onevent 实时曲目/艺人上报与状态感知 (2026-10-12) |
| `/usr/local/bin/yt-dlp`            | YouTube 核心解析引擎 (Linux x86_64 standalone, 2026.08.19) |
| `/usr/local/bin/deno`              | Deno JS 运行时 (用于 yt-dlp 原生解密计算，消除签名告警) |
| `/usr/local/bin/radio-admin`| 管理面板后端 (python3, 8811; 面板页 admin-panel.html 同目录) |
| `/var/www/jam/`             | 公开播放页 (index.html + hls.js): radio.example.com 根路径 |
| `/etc/caddy/Caddyfile`      | 路由: / = 播放页, /whep = WebRTC 信令, /hls/* = 备路, /admin/* = 面板(basic_auth) |
| `/etc/systemd/system/radiod.service` | 服务定义 |
| `/etc/systemd/system/ncm-api.service` | 网易 API 容器单元 (docker start/run 幂等) |
| `/etc/systemd/system/radio-admin.service` | 面板后端单元 (User=radiod) |
| `/var/lib/radiod/admin_token`| 面板内层 Bearer token (600; Caddy 注入, 改后同步改 Caddyfile) |
| `/var/lib/radiod/volume`     | 音量缩放倍数持久化文件 (0.1~10.0, 默认 1.0, 666) |
| `/var/lib/radiod/media/`    | **媒体库**, 音频文件放这里 (755, radiod:radiod) |
| `/var/lib/radiod/`          | librespot Spotify 凭据缓存 + `last_source` (重启恢复用) |
| `/var/lib/radiod/netease_cookie` | 网易云登录 cookie (单行 `MUSIC_U=...; __csrf=...`, 666, ~15 天过期) |
| `/var/lib/radiod/soundcloud_cid` | SC 匿名 client_id 双 surface (`<surface> <cid>` ×2 行, 首行=生效, 666) |
| `/var/lib/radiod/youtube_proxy`  | YouTube 代理配置 (单行如 `socks5://127.0.0.1:40000`, 666) |
| `/var/lib/radiod/youtube_cookies.txt` | YouTube 登录/会话 Cookie 文件 (母盘快照保护, 666) |
| `/tmp/bilibili_wbi_keys.json`| B站 WBI 鉴权密钥本地文件缓存 (6小时有效) |
| `/run/radiod/cmd.fifo`      | 命令管道 (radioctl 与 radio-admin 都写这里) |
| `/run/radiod/cmd.result`    | 最近一条命令处理结果 (`ts\|OK/FAIL\|文本`, radiod 写, 面板/radioctl status 显示) |
| `/run/radiod/source.state`  | 当前状态: `name\|dir\|file\|idx\|total\|order\|ts` 竖线分隔 |
| `/run/radiod/ffmpeg-azmq.sock`| 总线 ffmpeg azmq Unix 套接字 (实时音量调节通道) |
| `/run/radiod/*_search.cache`| 搜索结果缓存 (netease/netease_podcast/soundcloud/bilibili/youtube, 666) |
| `/usr/local/etc/mediamtx.yml`| MediaMTX 配置 |

---

## 3. 日常操作速查 (最常用)

**所有控制命令都在 ubuntu 用户下执行, 无需 sudo** (文件操作除外)。

```bash
radioctl status          # 看当前在播什么 (音源/曲目/进度)

radioctl spotify         # 切到 Spotify (然后手机 Spotify 里选设备 "VPS Radio" 放歌)

radioctl file /var/lib/radiod/media/xxx.mp3 [01:30]     # 播单个文件 (循环，支持指定起始时点)
radioctl folder                                # 媒体库整库随机循环
radioctl folder /var/lib/radiod/media seq      # 按文件名顺序播
radioctl skip            # folder/netease=跳下一首; file=重头播
radioctl seek 01:30      # 从指定时点播放当前曲目 (支持 mm:ss、hh:mm:ss 或纯秒数)

radioctl ls              # 列媒体库文件
radioctl upload-hint     # 上传提示
```

### 网易云音源 (netease)

```bash
radioctl netease login                    # 扫码登录 (二维码打终端; 需要 ncm-api 容器在跑)
radioctl netease status                   # 登录态检查 (昵称/VIP; cookie ~15 天过期)

radioctl netease playlist 3778678 seq     # 歌单循环 (支持直接传数字ID、完整链接或 App 分享文字如 "分享歌单: ... https://163cn.tv/...")
radioctl netease album 18919 seq          # 专辑循环 (如 范特西，亦支持分享链接/文字)
radioctl netease fm                       # 私人FM (登录后个性化)
radioctl netease daily                    # 每日推荐 (登录后可用)
radioctl netease podcast 794934387 seq    # 播客/电台节目循环 (支持直接传播客数字ID或网页链接)
radioctl netease podcasts                 # 列出账号已订阅播客
radioctl netease podcast-sub 1 seq        # 播已订阅播客第 1 个
radioctl netease program 2064123456       # 播客单集点播
radioctl netease search "周杰伦 晴天"     # 搜索单曲 → 编号列表
radioctl netease play 3                   # 播放上次单曲搜索结果第 3 首
radioctl netease podcast-search "Tiny Desk" # 搜索播客电台 → 编号列表
radioctl netease podcast-play 1           # 播放上次播客搜索结果第 1 个电台
radioctl skip                             # 跳当前网易曲目 (复用总 skip)
```

- 曲目来源: 服务器直连 music.163.com 明文 API + **X-Real-IP 伪装大陆 IP** (海外 VPS 必需, 2026-09 实测有效)
- 曲目搜索缓存 `/run/radiod/netease_search.cache` 与播客缓存 `/run/radiod/netease_podcast_search.cache` (VPS 重启清空, 重新 search 即可)
- VIP 曲 (fee=1): 需黑胶会员 cookie; 免费账号自动**跳过** (30s 试听片段也不播)。单曲失败**不回落 spotify** (2026-09-13 需求变更: 无限跳歌保持 netease), 仅"取不到列表"才回落
- cookie 失效表现: 电台无限连跳歌 (不回落), journalctl 每 10 连败打一条 "已连续 N 首曲目 <10s 失败" 诊断 → `radioctl netease status` 确认 → 重新 `login` 扫码
- 重新登录前确认容器: `systemctl is-active ncm-api` (QR 登录唯一依赖; 平时放歌不需要它)

### SoundCloud 音源 (soundcloud, 2026-09-15)

```bash
radioctl soundcloud status                  # CID 健康 (金丝雀探针)
radioctl soundcloud track <单曲id或完整链接> [模式]       # SC 单曲点播
radioctl soundcloud likes [用户名/链接] [shuffle|seq]   # 用户 likes 循环 (默认 plusdrei, 支持主页 URL)
radioctl soundcloud playlist <歌单id或完整链接> [shuffle|seq] # SC 歌单循环 (支持直接传数字ID或网页完整URL)
radioctl soundcloud search <关键词>          # 搜索 (编号列表, ✂=30s试听不可播)
radioctl soundcloud play <序号>              # 播上次搜索结果第 n 首 (从 1 起)
radioctl skip                               # 跳当前曲 (复用总 skip)
```

- **无登录无 OAuth**: 匿名 client_id (双 surface mobile/desktop 缓存 `/var/lib/radiod/soundcloud_cid`), 401/403 → 刮 m.soundcloud.com (主) / 桌面 asset (备) 自愈; (CID,IP) 软限 → 自动切备用; 429/网络错 sleep 15 自限速
- 曲目 policy: ALLOW=全长 / SNIP=30s 试听 (自动跳过, 同 netease fee=1) / BLOCK=不可播
- **失败不回落 spotify** (2026-09-15 决策): 运行期单曲失败、API 失败、重取列表失败全部保持 soundcloud 音源连跳; 仅"收到切换命令时列表取不到"才保持原音源不动
- 转码 progressive mp3 优先 (超长 DJ set 必须走它——HLS 签名 URL ~2h 过期会截断), HLS aac_160k 回退 (~11% 曲仅 HLS)

### Bilibili 音源 (bilibili, 2026-09-19~20)

```bash
radioctl bilibili video <BV号/链接/短链/文案> [p] [模式]     # 单视频或分P (默认 repeat 单曲循环)
radioctl bilibili fav <收藏夹ID或公开链接> [模式]           # 公开收藏夹全量循环 (支持分页自动抓取)
radioctl bilibili season <合集ID或完整链接> [mid] [模式]   # UP主合集或系列循环 (支持合集与系列双接口自适应分页)
radioctl bilibili search <关键词>                         # 视频搜索 → 编号列表 (保存到缓存)
radioctl bilibili play <序号> [模式]                      # 播放上次搜索结果第 n 个视频
radioctl skip                                            # 跳当前 B 站视频音频 (复用总 skip)
```

- **纯匿名 0 账号免登录**: 无需扫码配置 Cookie，通过 WBI 动态混合签名获取全长 1080P/全规格 DASH 音频流 (m4s/aac)。密钥缓存于 `/tmp/bilibili_wbi_keys.json` (6小时自愈轮换)。
- **智能文案清洗与短链重定向**: 支持手机端 `b23.tv` 短链重定向、App 复制长文案提取、纯 BV 号、`?p=分P`、带额外参数的 Web 链接。
- **UP主合集与系列双接口兼容**: 支持直接输入如 `https://space.bilibili.com/151440561/lists?sid=4174394`，内部自动从 URL 提取 mid 与 sid，自动探测合集 (`seasons_archives_list`) 与系列 (`series/archives`) 接口，并自动分页取满全部曲目 (已破除 40 首分页限制)。
- **超长音频 (>2h) 断点接力守护**: DASH 签名 Token 约 2 小时过期。针对超长音频 (>7000s)，`bilibili-helper` 自动启动后台 Supervisor，上游断开时自动带着 `-ss <已播秒数>` 重新请求新签名 Token 秒级接力续播，听众端完全无感知。
- **单曲失败绝不回落 spotify**: 遭遇下架或无音频轨道等错误时自动跳下一首，保持 bilibili 音源连播。

### YouTube 音源 (youtube / yt, 2026-09-20~21)

```bash
radioctl youtube <链接/短链/歌单/ID/文案> [模式]           # 智能点播: 自动识别单视频还是歌单并开播
radioctl youtube video <视频链接或ID> [模式]               # 单视频点播 (默认 repeat 单曲循环)
radioctl youtube playlist <歌单链接或ID> [模式]            # 歌单全量循环 (默认 loop 列表循环)
radioctl youtube search <关键词>                          # YouTube 视频搜索 → 编号列表 (保存到缓存)
radioctl youtube play <序号> [模式]                       # 播放上次搜索结果第 n 个视频
radioctl youtube status                                   # 查看当前 yt-dlp 与解析环境版本
radioctl youtube cookie [file]                            # 查看当前 Cookie 状态或导入 Netscape cookie 文件
radioctl youtube proxy [url|off]                          # 查看/配置代理 (如 socks5://127.0.0.1:40000 或 off)
radioctl skip                                             # 跳当前 YouTube 视频/单曲 (复用总 skip)
```

- **Cloudflare WARP 本地 SOCKS5 代理 (彻底免去 Cookie 与人机风控)**: 系统在本地部署了 Cloudflare WARP (`warp-svc.service`)，运行于 `proxy` 模式，本地监听 `127.0.0.1:40000`。该模式下**不修改系统默认路由与公网 IP，绝不影响 SSH 远程运维**。通过配置 `radioctl youtube proxy socks5://127.0.0.1:40000`，`yt-dlp` 与音频流均通过干净的 Cloudflare Anycast 出口请求，从根源上规避了腾讯云首尔机房 IP 遭遇的 YouTube BotGuard（`Sign in to confirm you're not a bot`）人机拦截与 403 阻断，实现 **0 账号、0 Cookie、0 Token** 稳定点播。
- **首尔机房原生极速直连与直推**: 直链解析仅需 1~2 秒，直接提取最高规格 WebM DASH Opus (160kbps) 纯音频流，零磁盘缓存即点即播。
- **极致的零参数体验**: 支持直接粘贴完整链接、`youtu.be` 短链、`playlist?list=` 歌单、`shorts` 短视频、移动端 App 复制的分享文本。无需人工拆分或输入参数。
- **Deno 运行时安全防护**: 系统集成 Deno 2.9.7 运行时，由 `yt-dlp` 原生调用进行签名解密计算，彻底消除 EJS 告警。
- **超长音频 (>2h) 与直播断点守护**: 视频时长超过 2 小时时，`youtube-helper` 自动启动 Supervisor 断点接力监听，在连接中断时自动附带 `-ss` 续播。
- **失败永不回落 Spotify**: 单曲版权/受限快速失败自动连跳，保持 YouTube 音源不掉队。

### Bandcamp 音源 (bandcamp / bc, 2026-10-10)

```bash
radioctl bandcamp <链接/文案> [模式]               # 智能点播: 自动识别单曲、专辑还是艺人全库并开播
radioctl bandcamp track <单曲链接> [模式]          # 单曲点播 (默认 repeat 单曲循环)
radioctl bandcamp album <专辑链接> [模式]          # 专辑全量循环 (默认 loop 列表循环，自动过滤仅购买不可播曲目)
radioctl bandcamp artist <艺人主页链接> [模式]     # 艺人全库作品循环 (多线程并发抓取全部公开发行作品并提取可播音频)
radioctl bandcamp search <关键词>                 # Bandcamp 搜索 → 编号列表 (保存到缓存)
radioctl bandcamp play <序号> [模式]              # 播放上次 Bandcamp 搜索结果的第 n 项 (自动展开专辑或播放单曲)
radioctl skip                                    # 跳当前 Bandcamp 曲目 (复用总 skip)
```

- **纯匿名 0 账号免登录**: 无需账号 Cookie，通过 Bandcamp 页面原生 `data-tralbum` 与移动端 API 解析 128kbps MP3 纯音频流。
- **专辑与艺人全作品并发解析**: 针对艺人主页（如 `https://aphextwin.bandcamp.com`），后台自动通过 8 线程线程池并发拉取全部发行专辑并提取全部可播曲目，仅耗时 1~4 秒即可展开全库。
- **自动过滤仅购买限制曲目**: 与网易云 VIP (`fee=1`) 和 SoundCloud (`SNIP=30s`) 同构，自动识别未提供免费完整试听的曲目并直接跳过，只将可听曲目编入播放列表。
- **搜索自动展开专辑**: 搜索结果包含专辑、单曲与艺人。点播某条专辑搜索结果时，系统自动展开该专辑的全部曲目并循环播放。
- **失败永不回落 Spotify**: 运行期遇到仅购买曲目或网络单次超时快速失败连跳下一首，保持 Bandcamp 音源连播。

### 播放模式与音量调节 (全局生效)

```bash
radioctl mode repeat|loop|seq|shuffle       # 切换播放模式 (单曲循环|列表循环|列表顺序|随机播放)
radioctl volume                             # 查看当前音量倍数 (默认 1.0)
radioctl volume 1.5                         # 调节音量为 1.5 倍 (支持 0.1 ~ 10.0，实时 ZMQ 生效并存盘)
```

- **模式定义**:
  - `repeat` (单曲循环): 循环播当前这一首 (视频/单曲默认)
  - `loop` (列表循环): 列表顺序播放，到底后重新回到第 1 首 (合集/收藏夹/播客默认)
  - `seq` (列表顺序): 列表顺播，整轮播完后回落 spotify
  - `shuffle` (随机播放): 列表洗牌乱序播放，一轮播完重新洗牌继续
- **实时音量调节**: 总线 ffmpeg 内置 `azmq` 滤镜，音量调整直接经 Unix Domain Socket `/run/radiod/ffmpeg-azmq.sock` 毫秒级调节，无需重启进程，且即刻写入 `/var/lib/radiod/volume` 持久化保存。

### 网页管理 (不用 SSH 的方式)

**`https://radio.example.com/admin/`** — radioctl 的全部常用操作都在网页上 (账号 `admin`, 密码见下):

- **状态卡**: 当前音源/曲目/进度 + 5 个服务健康徽章 (radiod/mediamtx/caddy/ncm-api/volume) + **最近操作** (radiod cmd.result, OK/FAIL+原因, 10min 内可见) + **从指定时点开始播放** (支持输入 mm:ss、hh:mm:ss 或纯秒数跳转播放) + **下一首 / 播放模式切换**，3 秒自动刷新
- **实时音量滑块与模式切换**: 支持在网页端直接拖动滑块调节电台总音量 (0.1~3.0x 预设滑块)，一键切换 单曲/列表循环/顺序/随机 模式
- **切换音源**: Spotify / 媒体库随机·顺序 / 网易歌单·专辑·FM·每日推荐·播客 / SC Likes·歌单 / B站视频·收藏夹·合集 (合集/系列支持直接粘贴完整链接或 sid) / 跳过
- **媒体库列表**: 点 ▶ 直接播 (上传仍走 scp, 见 §4)
- **多平台搜索点歌**:
  - 网易单曲搜索 / 网易播客电台搜索
  - SoundCloud 搜索
  - Bilibili 视频搜索
  - 搜关键词 → 填序号播放 (越界/无缓存会明确报错)
- **网易扫码登录**: cookie 过期 (~15 天) 时在此生成二维码手机扫, 全程网页完成

**认证双层**: Caddy basic_auth (外层) + radio-admin Bearer token (内层, Caddy 自动注入, 用户无感)。
**改密码**: `caddy hash-password --plaintext '新密码'` 生成哈希 → 替换 /etc/caddy/Caddyfile 里 basic_auth 的哈希行 → `sudo systemctl reload caddy`。
**面板后端**: `/usr/local/bin/radio-admin` (python3 stdlib, 127.0.0.1:8811, systemd 单元 radio-admin.service, User=radiod); 改面板 HTML 在 `/usr/local/bin/admin-panel.html`, 改完 `sudo systemctl restart radio-admin`。

看实时日志 / 服务状态:

```bash
journalctl -u radiod -f                    # 跟日志 (含切歌记录, 前缀 "radiod:")
systemctl status radiod                    # 服务健康
journalctl -u mediamtx -f                  # 听众连接日志 (WebRTC session created/closed)
```

---

## 4. 上传新音频文件

**⚠️ 最重要的坑: radiod 服务开了 `PrivateTmp=true`, `/tmp` 下放文件它看不见。必须进 `/var/lib/radiod/media/`。**

两步 (ubuntu 用户):

```bash
# 1. 从你本地机器传到 VPS (在本地跑; [ ] 等特殊字符加单引号):
scp '本地文件' ubuntu@<YOUR_VPS_IP>:/tmp/随便命名.mp3

# 2. VPS 上移入媒体库 (需要 sudo):
sudo mv /tmp/随便命名.mp3 /var/lib/radiod/media/
sudo chown radiod: /var/lib/radiod/media/随便命名.mp3
```

一条龙 (本机已配免密密钥 ~/.ssh/id_ed25519, 无需 -i/密码):

```bash
F='新歌.mp3'
scp "~/Downloads/$F" "ubuntu@<YOUR_VPS_IP>:/tmp/$F"
ssh ubuntu@<YOUR_VPS_IP> "sudo mv '/tmp/$F' /var/lib/radiod/media/ && sudo chown radiod: '/var/lib/radiod/media/$F'"
```

传完验证没传坏 (应输出正常时长; 大文件建议验, 2026-09-14 实测 50MB mp3 一次通过):

```bash
ssh ubuntu@<YOUR_VPS_IP> "ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1 '/var/lib/radiod/media/新歌.mp3'"
```

上传后:

- 正在播别的东西 → `radioctl file /var/lib/radiod/media/随便命名.mp3` 立即播
- 正在 folder 模式 → **不用任何操作**, 下一轮重扫自动进 rotation
- 想立刻进 rotation → `radioctl folder` 重开一轮

支持格式: mp3 / m4a / aac / flac / wav / ogg / opus / wma (folder 递归扫子目录, 文件名带空格 OK)。

删除文件: `sudo rm /var/lib/radiod/media/xxx` (folder 模式下一轮自动出队)。

---

## 5. Spotify 音源怎么用

切到 spotify 后, 电台设备名是 **"VPS Radio"**。

1. 手机/电脑打开 Spotify, 点底部设备图标
2. 列表选 **VPS Radio**
3. 放任何歌/歌单 → 服务器收到 PCM → 全台播出

注意:

- **空置 300 秒服务会整链重启** (systemd `Restart=always`)。这是**设计内行为不是故障**: MediaMTX `readTimeout: 300s` 无数据断开发布者 → systemd 3 秒后拉起 → 你按播放后几秒恢复。journalctl 里看到周期性 restart 属正常。
- 手机选了 VPS Radio 但放歌没声音 → 查 `radioctl status` 是否 spotify, journalctl 有无 librespot 报错。
- Spotify Premium 账号才能用 Connect (现凭据缓存于 /var/lib/radiod/, 有效)。
- **重新登录 Spotify** (凭据失效时): 
  ```bash
  sudo systemctl stop radiod
  sudo -u radiod FORCE_LOGIN=1 /usr/local/bin/radiod.sh   # 前台跑, 打印 OAuth URL
  # 本地浏览器打开 URL 授权; 如需隧道: ssh -L 5588:127.0.0.1:5588 vps
  # 授权成功后 Ctrl+C, 凭据已存, 再 systemctl start radiod
  ```

### 5.1 Admin 端 / CLI 切歌控制 (Spotify Web API)

系统支持在 Admin 面板点击“下一首 / 上一首”或通过 `radioctl skip` / `radioctl spotify next` 远程控制 Spotify 换歌：
1. **首次配置 Web API 授权 (一次性)**:
   - 运行: `radioctl spotify auth`
   - 按终端提示输入 Spotify Developer App 的 Client ID 与 Client Secret，复制链接至浏览器完成授权，并粘贴回调 URL/code。
   - 凭据将安全持久化保存在 `/var/lib/radiod/spotify_auth.json` (chmod 0600)。
2. **日常切歌**:
   - **Web 后台**: 直接点击“下一首”或 Spotify 卡片内的“下一首 ▶▶|” / “|◀◀ 上一首”。
   - **CLI 命令行**:
     ```bash
     radioctl skip               # 切下一首
     radioctl spotify next       # 切下一首
     radioctl spotify prev       # 切上一首
     radioctl spotify status     # 查看当前设备与播放曲目 JSON
     ```
   - 若未配置凭据，Web 面板会标识“Web API 未配置”，点击切歌时会在最近操作中给出明确配置提示。

---

## 6. 排障 (症状 → 根因 → 处置)

### 6.1 网页打不开 / 没声

```bash
systemctl is-active radiod mediamtx caddy    # 三个都得 active
curl -sI https://radio.example.com | head -1  # 应 200/302
```

- caddy 挂 → `sudo systemctl restart caddy`
- mediamtx 挂 → `sudo systemctl restart mediamtx` (radiod 会自动重连)
- 全挂 → 逐个 `sudo systemctl restart radiod mediamtx caddy`

### 6.2 radioctl 报 "radiod 未在运行"

`/run/radiod/cmd.fifo` 不存在 = radiod 没在 systemd 下跑。`sudo systemctl start radiod`。
若服务反复崩溃: `journalctl -u radiod -n 50` 看末尾错误。

### 6.3 文件模式报 "文件不可读"

三种可能: ① 文件还在 `/tmp` (PrivateTmp 坑, 见 §4); ② 属主/权限不对 (`ls -la /var/lib/radiod/media/`, 要求 radiod 可读, 一般 `chown radiod:` 即可); ③ 文件真坏了 (`ffprobe -i 文件` 验证)。

### 6.4 folder 模式反复跳歌不前进

journalctl 里连续 `曲目 <10s 崩溃` → 音频文件损坏率太高, 连续 3 首崩会回落 spotify。找出坏文件: 逐个 `ffprobe` 或看日志里哪首总在崩溃, 删掉。

### 6.5 切歌/切源后卡住不动

等 3 秒再 `radioctl status` (librespot 启动要 2-3 秒)。仍卡 → `journalctl -u radiod -n 30`, 有 `radiod:` 前缀的行就是脚本自己的日志。

### 6.6 服务停了想手动前台调试

```bash
sudo systemctl stop radiod
sudo -u radiod /usr/local/bin/radiod.sh    # 前台跑, 日志直打终端; 注意此时 radioctl 不可用 (cmd.fifo 建不成)
# Ctrl+C 退出, 完事记得 systemctl start radiod
```

### 6.7 高危操作前记住

- `Restart=always` + `RestartSec=3`: 改完 unit 文件要 `daemon-reload`; 重启服务会断流几秒 (听感重启即可)
- 别直接 `kill` 总线 ffmpeg 或 librespot —— 脚本主循环检测到会自杀整链交给 systemd 拉起, 看似"杀了没死过几秒又回来"是正常的
- `last_source` (`/var/lib/radiod/last_source`) 记录重启前音源; 删了它=下次重启默认 spotify

### 6.8 netease 常见问题

- **无限连跳歌不回落 spotify**: 单曲快速失败 (典型 <10s) 时不回落、一律前进下一首 (2026-09-13 需求变更), 三种可能 ① cookie 失效 (~15 天) → `radioctl netease status` 确认, 重新 `login`; ② 歌单 VIP 曲密度高 + 免费账号 → 换免费歌为主的歌单或登录黑胶号; ③ 接口/伪装被风控 → `netease-helper resolve <id>` 单曲诊断, 全部不可播则改 helper 里 `XIP` 常量换个大陆 IP。区分: 日志里出现 "取 'xx' 列表失败/重取列表失败, 回落 spotify" 才是列表级失败回落 (网络/接口挂了), 单曲连跳属正常跳过
- **切到 netease / 一轮播完取列表失败 → 回落 spotify**: 列表级失败, 两种来源 ① API/网络层面挂了 (playlist/album 也取不到); ② fm/daily 列表需要登录 cookie, cookie 过期也会取列表失败 (playlist/album 取列表不依赖登录)。看 `radioctl status` 是否已变 spotify + journalctl "取/重取列表失败" 的上下文
- **login 报 "ncm-api 容器未运行"**: `sudo systemctl start ncm-api` (或看 §5 容器说明)
- **二维码 800 过期**: unikey 生命周期约 5 分钟, 重跑 `radioctl netease login` 即可
- **单曲诊断**: `netease-helper resolve <歌曲id>` 打印 CDN URL = 可播; exit 22 = 无权/试听/下架
- **大歌单只取到部分**: helper 已内置 trackIds+song/detail 批量补全 (游客截断 10 首时自动触发)
- **搜到想播的但拿不到链接** (VIP 曲): 登录黑胶账号即可整首播; 或选同曲免费版本 (search 列表里常见多个版本)

### 6.9 面板搜索点歌"没反应" (2026-09-15 修复过的坑, 复发时先查这里)

症状 = 搜索能出结果, 输序号点播放后什么都没播、也不报错:

```bash
wc -c /run/radiod/netease_search.cache    # 0 = 缓存写不进 (沙箱 rw bind 丢了)
journalctl -u radiod --since '-10 min' | grep "列表失败"   # 取 search 列表失败 = 缓存空的下游表现
pid=$(pgrep -f 'python3 /usr/local/bin/radio-admin'); sudo nsenter -t $pid -m mount | grep radiod  # 应见 rw
```

根因与修法见 §10 坑 13。现在复发时会**当场报出来**: helper 缓存写失败 → exit 26 → 面板搜索直接 502 带原因; 命令送达到 radiod 但失败 → 面板"最近操作"徽章 FAIL + 原因 (仅 10min 内显示; CLI `radioctl status` 末行不受时限)。临时绕过 = 用 CLI 搜索 (ubuntu 用户无沙箱, 缓存写得进), 之后面板点播同一查询可用。

### 6.10 bilibili 常见问题 (2026-09-19~20)

- **合集 / 系列取不到曲目 / 报 -404 啥都木有**:
  - 检查链接是否被误提取 mid: B 站空间链接格式为 `space.bilibili.com/<mid>/lists?sid=<sid>`，必须确保 helper 正确匹配 `sid=` 而非开头的 `mid` (已在 2026-09-20 修复，见 §10 坑 14)。
  - 自动回退: helper 已内置双接口回退，合集 (`seasons_archives_list`) 失败会自动探测系列 (`series/archives`)。
- **单曲播放报错 / 签名无效 (code=-403 / code=-412)**:
  - WBI 签名密钥失效: 删除本地密钥缓存 `rm -f /tmp/bilibili_wbi_keys.json`，helper 会在下一次请求时重新向 B 站 nav 接口获取最新的 img_key / sub_key。
- **超长音频中途断开续播**:
  - B 站 DASH 音频链接自带约 2 小时有效期的签名 Token。针对 >2h 音频，helper 已自带断点接力守护 (带着 `-ss` 续播)。若听众端断开，刷新网页即可恢复。
- **Windows CLI 输出特殊歌名乱码/崩溃**:
  - B 站部分视频标题含特殊变音符号（如 `Ē`/`\u0112`），在非 UTF-8 命令行下输出会触发编码报错。helper 头部已强制配置 `sys.stdout.reconfigure(encoding="utf-8", errors="replace")`。

### 6.11 youtube 常见问题 (2026-09-20~21)

- **机房 IP 人机风控与 Cloudflare WARP SOCKS5 代理诊断**:
  - 腾讯云等机房 ASN 会被 YouTube 判定为机器人流量（返回 `Sign in to confirm you're not a bot`）。系统通过部署本地 Cloudflare WARP 代理出口彻底免疫该拦截。
  - 检查 WARP 服务健康:
    ```bash
    warp-cli --accept-tos status                                                # 应显示 Status update: Connected
    curl -fsS --socks5-hostname 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace  # 应返回 warp=on
    radioctl youtube proxy                                                      # 查看电台当前代理配置 (应为 socks5://127.0.0.1:40000)
    ```
  - 若 WARP 未连接: `sudo warp-cli --accept-tos connect`。重设代理命令: `radioctl youtube proxy socks5://127.0.0.1:40000`。
- **Cookie 隔离快照保护 (杜绝 yt-dlp 覆写破坏母盘)**:
  - `yt-dlp --cookies` 默认机制会在进程退出时将内存中的 CookieJar 回写到原文件。一旦遇到风控或校验不通过，`yt-dlp` 会从 CookieJar 中注销 `LOGIN_INFO` 并写回磁盘，导致持久化存储的 Cookie 文件被不可逆污染清空；若设为只读，`yt-dlp` 退出时又会抛出 `PermissionError` 崩溃。
  - `youtube-helper` 已实现隔离防护：每次调用 `yt-dlp` 前，均自动将 `/var/lib/radiod/youtube_cookies.txt` 快照复制至 `/tmp/radiod_yt_cookie_<pid>.txt` 供进程独立读写，并在结束时清理。母盘文件永不被篡改损坏。
- **零轮换 Cookie 导出标准操作 (若需播放年龄限制/私有视频时使用)**:
  - 正常在 WARP 代理下无需任何 Cookie 即可播全量公开播单/单曲。若遇特殊受限视频需 Cookie，务必按以下 5 步导出，防止 Google 活跃会话轮换导致几分钟内失效：
    1. 打开 Chrome/Edge/Firefox 的**无痕/隐私窗口 (Incognito)**；
    2. 登录目标 Google / YouTube 账号；
    3. 登录完成后，在地址栏直接输入并访问 `https://www.youtube.com/robots.txt`（**核心原则**：robots.txt 是纯文本页面，不加载 YouTube 复杂前端脚本与跟踪器，绝不触发后台网络轮询与凭证轮换）；
    4. 点击浏览器 Cookie-Editor 插件，点击 "Export" -> 格式选择 "Export as Netscape"；
    5. 导出后**立即彻底关闭该无痕窗口**（立刻切断与 Google 的所有网络连接，避免主浏览器活动冲刷已导出的 `__Secure-1PSIDTS` / `LOGIN_INFO` 凭据）；
    6. 将内容保存并执行 `radioctl youtube cookie <文件路径>` 导入。
- **单曲播放报错 / 地区受限 (exit 22)**:
  - 某些官方 MV 可能会对特定国家/地区做播放限制。`youtube-helper` 自动跳过并前进下一首，保持 youtube 音源连播。
- **命令行或日志中出现 JavaScript runtime 告警**:
  - 本机已全局配置 Deno 2.9.7 (`/usr/local/bin/deno`)。若重新安装或升级 `yt-dlp`，无需手动指定 `--js-runtimes`，`yt-dlp` 会自动优先调用 Deno 消除告警。
- **单条链接含视频与歌单参数时的识别逻辑**:
  - 用户粘贴诸如 `youtube.com/watch?v=VID&list=PLID` 时，智能解析器优先判定为**歌单**以全量循环播出；如仅想播放单视频，直接粘贴单视频链接 `youtu.be/VID` 或在面板选择“单曲循环”即可。
- **超长音频中途断开接力**:
  - YouTube 的 CDN 签名 URL 有效期通常为 6 小时。超过 2 小时的视频（如超长白噪音或全天现场录音），`youtube-helper` 自动运行断点守护，上游意外中断时以 `-ss <已播秒数>` 申请新 Token 接力续播。

---

## 7. 自动行为汇总 (别当故障修)

| 现象 | 原因 | 要修吗 |
|------|------|--------|
| spotify 空闲 ~300s 后服务自动重启 | MediaMTX readTimeout 断开无数据发布者, systemd 拉起 | ❌ 设计内, 按播放即恢复 |
| folder 一轮播完日志出现 "重扫并重新洗牌" | 拾取新上传文件的机制 | ❌ 正是功能 |
| 手动 kill 某子进程几秒后"复活" | systemd 重启了整链 | ❌ 想停用 `systemctl stop` |
| 切歌瞬间 0.5~3s 静音 | librespot 启动耗时 / FIFO 换写者 / netease 换曲解析 URL / bilibili 签名解析 / youtube 直链解析 | ❌ 正常, 听众连接不断 |
| journalctl 见 librespot WARN "context is not available" | Spotify 上下文元数据小 warn | ❌ 不影响播放 |
| file/folder 模式**永不空闲重启** | 文件源持续出帧 | — |
| netease 单曲 <10s 失败 → 无限连跳**不回落** (每 10 连败打一条诊断日志) | VIP 曲连跳/cookie 失效 (2026-09-13 起: 保持 netease 音源, 见 §6.8); 仅取列表失败才回落 spotify | ❌ 设计内; 想播 VIP 登录黑胶号 |
| netease 一轮播完日志 "重新取列表" | 拾取歌单更新 / FM 换新推荐的机制 | ❌ 正是功能 |
| netease search 重启 VPS 后 play 失效 | 搜索缓存在 /run, VPS 重启清空 | ❌ 重新 search 即可 |
| soundcloud 单曲 <10s 失败 / API 失败 → 无限连跳**绝不回落** | SNIP/BLOCK 曲或 CID 软限自愈中; 重取列表失败复用旧列表 (2026-09-15 决策, 比 netease 更激进) | ❌ 设计内; `radioctl soundcloud status` 看 CID 健康 |
| soundcloud 超长 DJ set 播到 ~2h 截断换下一首 | 该曲只有 HLS 转码时签名 URL 过期; progressive 曲不受影响 | ❌ 已知边界 |
| bilibili / youtube 单曲 <10s 失败 → 无限连跳**不回落** | 版权受限/下架曲目; 保持音源连播 | ❌ 设计内 |
| bilibili / youtube 超长录音断点守护换 Token | 签名链接过期或网络抖动; 自动 -ss 接力续播 | ❌ 正是功能 |
| bilibili 单曲失败 / 下架 → 无限连跳**绝不回落** | 保持 bilibili 音源继续前进下一首; 一轮播完重取列表或复用旧列表 | ❌ 设计内; 查看 `journalctl -u radiod -f` |
| bilibili 超长音频 (>2h) 偶见短链接力日志 | 上游 DASH Token 过期，Supervisor 自动带 `-ss` 续播 | ❌ 正是守护功能 |
| volume 调节时广播完全不中断 | ffmpeg 总线 azmq filter 毫秒级热调 | ❌ 正是设计 |
| radiod 重启后 /run/radiod 目录 inode **不变** | radio-admin 共同持有 RuntimeDirectory + 双 unit Preserve=yes (2026-09-15) | ❌ 正是修复设计 |

## 8. 流量账 (VPS 有流量包, 关心的话)

- **没人听 = 0 出口流量** (file/folder 空转全程 loopback); spotify 模式无人放歌也 0
- 1 个听众 ≈ 57MB/小时 (128k Opus)
- spotify 有人放歌 ≈ 144MB/小时**入站** (腾讯云一般入站免费, 但占带宽)
- 结论: 最省状态 = file/folder 循环空转, 或 spotify 空闲自休眠

---

## 9. 二次开发索引 (想改逻辑时读哪里)

核心逻辑在 `/usr/local/bin/radiod.sh` 一个文件里 (音源取列表/解析 URL 各在 netease-helper / soundcloud-helper / bilibili-helper), 本地留档 + 逐段注释:

| 想做的事 | 改哪里 |
|---------|--------|
| 加新命令 (如 pause) | `handle_cmd()` 加 case + radioctl 加子命令 (记得让新分支写 CMD_NOTE 或产出 log 行, cmd.result 才有意义) |
| 加音源类型 (如 URL 直播流拉流) | 仿 `start_file()`: 起 ffmpeg 写 `$AUDIO_FIFO` 的后台进程, 主循环会自动管理生死 |
| 换音质 | 脚本头部 `OPUS_BITRATE` (注意媒体上行带宽) |
| 换电台名 | `LIBRESPOT_NAME` (Spotify 里显示的设备名) |
| 调整音量 | `radioctl volume <倍数>` 或直接经 `/run/radiod/ffmpeg-azmq.sock` 发送 zmq 命令 |
| 切换播放模式 | `radioctl mode <repeat\|loop\|seq\|shuffle>` (主循环 `advance_*` 会根据模式决定到底后行为) |
| 媒体库挪位置 | `MEDIA_DIR` + radioctl 里同名字段同步改 |
| netease 换伪装 IP | `netease-helper` 头部 `XIP` 常量 (一处改全局生效) |
| netease 加上下文 (如 排行榜/歌手热门) | helper 加 `list_xxx` + radiod.sh `start_netease` 的 ctx 映射 + radioctl 子命令 |
| soundcloud 换/刷新 client_id | helper 头部 `CID_FILE` (双 surface 缓存); 自愈在 `refresh_cid`/`scrape_mobile`/`scrape_desktop`; 内置兜底 CID 在 `load_cids`/`cid_init_default` |
| bilibili 优化解析/分P/合集 | `bilibili-helper` 头部 WBI 表、`cmd_list_season`、`cmd_list_fav`、`cmd_stream` |

命令协议 (往 `/run/radiod/cmd.fifo` 写一行):
- `switch-to-spotify`
- `switch-to-file <绝对路径>`
- `switch-to-folder <目录> [repeat|loop|seq|shuffle]`
- `switch-to-netease <ctx> <cid> [repeat|loop|seq|shuffle]` (ctx=playlist|album|podcast 时 cid=数字id; ctx=fm|daily 无 cid; ctx=search 时 cid=起始下标0基)
- `switch-to-soundcloud <ctx> <cid> [repeat|loop|seq|shuffle]` (ctx=likes 时 cid=用户permalink; playlist 数字id; track 单曲; search 起始下标)
- `switch-to-bilibili <ctx> <cid> [repeat|loop|seq|shuffle]` (ctx=video 时 cid=BV或链接; fav|season 时 cid=数字id或URL; search 时 cid=起始下标)
- `switch-to-youtube <ctx> <cid> [repeat|loop|seq|shuffle]` (ctx=video 时 cid=视频ID或URL; playlist 时 cid=歌单ID或URL; search 时 cid=起始下标)
- `mode <repeat|loop|seq|shuffle>`
- `volume <倍数>` (0.1 ~ 10.0)
- `skip`

路径含空格 OK, 参数从行尾解析; **不支持换行**。每条命令处理后 radiod 把 `<ts>|OK|文本` 或 `<ts>|FAIL|原因` 写 `/run/radiod/cmd.result` (面板/radioctl status 显示)。

状态文件 (`/run/radiod/source.state`): 7 字段竖线分隔 `name|dir|file|idx|total|order|unix_ts`。folder 进度 `idx` 0 基。
- netease 时: `dir` = `playlist:<id>` / `album:<id>` / `podcast:<id>` / `fm` / `daily` / `search`; `file` = `"<歌曲id> <歌名>"`。
- soundcloud 时: `dir` = `likes:<user>` / `playlist:<id>` / `track:<id>` / `search`; `file` = `"<曲目id> <歌名>"`.
- bilibili 时: `dir` = `video:<bvid>` / `fav:<id>` / `season:<id>` / `search`; `file` = `"<bvid[:cid]> <标题>"`.
- youtube 时: `dir` = `video:<id>` / `playlist:<id>` / `search`; `file` = `"<id> <标题>"`.

`last_source` (`/var/lib/radiod/last_source`): spotify/file/folder 行 4 字段; **netease/soundcloud/bilibili/youtube 行 5 字段** (末尾多 `idx` 进度, seq/loop 恢复续播用)。旧版 radiod 读到不识别的行 → 默认 spotify, 回滚安全。

**netease 兜底路线** (若明文 API 被收紧): ncm-api 容器 (ncm-api.service, 127.0.0.1:3000) 是完整 API 实现, 可扩展 helper 把取链接也走容器 (现仅 QR 登录走它)。

**部署留档**: 脚本/配置的源副本 + 完整踩坑记录在本地项目工作区。改 VPS 上的文件前建议先拉回一份备份: `scp vps:/usr/local/bin/radiod.sh ./radiod.sh.bak`。

---

## 10. 历史踩坑备忘 (改动前必读, 防止回退)

这些坑都已修好, 但**改动时容易无意中踩回去**:

1. ffmpeg 写已存在的 FIFO 要加 `-y` (拒绝覆盖保护), 否则文件源秒退
2. 清理时必须先 `exec 3>&-` 关自持的 FIFO fd 让总线 ffmpeg 读 EOF 退出; 直接 kill 会被 SA_RESTART 吞掉卡 90 秒
3. 命令 FIFO 建立后要 chmod 666, 否则 ubuntu 用户写不进 (radiod 建的默认 644)
4. 状态文件分隔符用 `|` 不用 tab (bash IFS 对 tab 会折叠丢字段)
5. 服务 `PrivateTmp=true`: /tmp 隔离, 媒体文件必须进 /var/lib/radiod/media
6. `mapfile -d ''` + `find -print0` 处理空格文件名, 别改回 glob
7. radioctl 预检目录用 find, 别用 ls+多格式 glob (不匹配的 glob 字面量会让 ls 报错误报"无音频文件")
8. netease 歌名清洗 (`|`→`／`, 去 CR/LF) 在 helper `JQ_LINE`/`san()` —— 防 7 字段状态文件被竖线污染, 别删
9. netease cookie 文件 666 跨用户模型: ubuntu 写 (login) / radiod 读 (放歌); 误删后 `sudo install -o radiod -g radiod -m 666 /dev/null /var/lib/radiod/netease_cookie` 重建
10. curl 取链接的 URL 含 `ids=[...]` 方括号 → 必须带 `-g` (禁 glob), 否则 curl 报 bad range 拒绝请求
11. netease QR 登录必须走 ncm-api 容器: 明文 `/api/login/qrcode/*` (type=1) 的 803 只回 web 游客 cookie (MUSIC_R_T/A_T, 无 MUSIC_U), 看似"登录成功"实则无效 —— save_login_cookie 的 `grep MUSIC_U` 校验别删
12. 容器 803 的 cookie 串带 `; Path=...; Max-Age=...;;` 属性行, 清洗用内置 python (bash 管道在 `;;` 分隔上易碎, 实测丢过 MUSIC_U)
13. **跨 unit 写 `ProtectSystem=strict` 服务的目录, 必须两边都声明同名 RuntimeDirectory/StateDirectory, 别用 ReadWritePaths 指向别人的目录**: radio-admin 曾写 `ReadWritePaths=/run/radiod` 依赖 radiod 的 RuntimeDirectory —— systemd 255 实测静默跳过该绑定 (ns 内无 rw, helper 写搜索缓存 EROFS)。症状演进: 09-13~09-15 helper 搜索 tmp 写 $HOME 也失败 → 面板搜索步就 502; 09-15 凌晨把 tmp 挪到 /tmp 后搜索恢复显示, 但缓存 `cat > /run/radiod/*_search.cache` 仍 EROFS → "能搜不能点"且无报错 (helper 只 warn stderr, radio-admin 只回 stdout)。网易面板扫码登录写 cookie 同坑, 从未成功过。现两 unit 均声明 `RuntimeDirectory=radiod`(共享引用计数, 都停才删) + `RuntimeDirectoryPreserve=yes`(单 restart 不换 inode, bind 不 stale)。新增写 /run/radiod 或 /var/lib/radiod 的 unit 照 radio-admin 抄这两行。诊断: `sudo nsenter -t $(pgrep -f 'python3 /usr/local/bin/radio-admin') -m mount | grep radiod` 应见 rw
14. **B站合集/系列/收藏夹 URL 正则提取必须严格避开 mid**: B站个人主页链接形如 `https://space.bilibili.com/<mid>/lists?sid=<sid>`。若正则写成 `(?:sid=)?(\d+)` (含可选的 `?`)，正则引擎会从前往后匹配，把开头的 `<mid>` 误当作 `sid`，向接口发送 `season_id=<mid>` 导致返回 `-404 啥都木有`。提取时必须显式提取 `mid` 与 `sid`，且优先匹配显式关键词 `(?:season_id=|sid=|series_id=|series/)(\d+)`。
15. **B站合集 (season) 与系列 (series) 双接口自动降级与分页**: UP主个人空间的 `lists?sid=...` 既可能是合集 (season) 也可能是系列 (series)。合集走 `seasons_archives_list`，系列走 `series/archives`。单页默认 40 条，必须带分页循环 (`page_num/pn`) 直至取满 `total` 或返回空，否则大歌单（如 117 首的 Tiny Desk Concert）会被截断在前 40 首。
16. **Python CLI 输出 UTF-8 编码防御**: Windows 命令行默认代码页（如 cp936/GBK）在输出含特殊变音符号（如 `Ē`/`\u0112`）的歌曲名时会报 `UnicodeEncodeError`。Python helper 头部必须强制配置 `sys.stdout.reconfigure(encoding="utf-8", errors="replace")`。
17. **ZMQ 实时音量调节与持久化**: 总线 ffmpeg 挂载 `azmq,volume@vol=volume=1.0:eval=frame,alimiter=limit=0.98`，通过 Unix domain socket `/run/radiod/ffmpeg-azmq.sock` 接收 JSON 调节指令，毫秒级无缝生效，并写入 `/var/lib/radiod/volume` 持久化，避免重启还原。
18. **Web 后台合集链接一键解析统一**: 面板此前将 B站合集拆为 UID 与 sid 两个输入框，不仅输入繁琐且易让用户产生困惑；现已改造为直接接收合集/系列链接（或单个 sid/短链/文案），由后端与 helper 自动提取有效参数，免去人工拆解。
19. **YouTube 智能免参数解析 (单个输入框自动分流)**: 用户输入的 YouTube 链接形式繁杂（包含 `watch?v=...`, `youtu.be/...`, `playlist?list=...`, `shorts/...`, 甚至包含分享文案或同时包含 `v=` 与 `list=`）。在 Web 面板与 CLI 中统一由 `resolve_youtube_input` 正则状态机解析，若含 `list=` 优先判定为歌单以全量循环播出，短链/纯单曲判定为单视频，彻底消除人工判断与多输入框负担。
20. **yt-dlp 与 Deno JS 运行时集成消除 EJS 签名告警**: 2026 年 YouTube 强化了客户端签名挑战计算，`yt-dlp` 依赖 JS 引擎计算挑战解密。系统中配置 Deno 运行时 (`/usr/local/bin/deno`)，配合独立 `yt-dlp`，避免了回退到 nodejs 时的各种沙箱限制与 EJS 告警，秒级提取 WebM DASH Opus (160kbps) 纯音频直推流。
21. **跨沙箱搜索缓存权限与原子写入**: `youtube-helper search` 生成的 `/run/radiod/youtube_search.cache` 必须以 `0666` 权限创建。若使用 Python 的临时文件并在 `/tmp` 与 `/run/radiod` 跨文件系统原子替换，会因 systemd `PrivateTmp` 隔离导致跨卷移动或权限异常。helper 改造为直接打开目标缓存文件清空写入并赋予 `0666`，确保 `radio-admin` 与 `radiod` 在独立沙箱下均能正常读写搜索缓存。
22. **B站音源播一半自动切歌 (MCDN/PCDN 慢速断流与 FFmpeg 重连机制)**:
    - **现象**: B站音频经常播放到 30 秒~1 分钟左右突然掐断，单曲循环模式下从头重播，歌单/合集模式下直接跳到下一首。
    - **根因**:
      1) **PCDN 节点调度**: B站 API 默认下发的 `baseUrl` 是边缘 `*.mcdn.bilivideo.cn:8082` (PCDN 节点)。`radiod` 架构通过 64KB 的 FIFO 以 1x 速率消费 PCM (约 20~30KB/s 读网络流)，PCDN 节点对这种慢速长连接极不友好，会在数十秒后主动发送 RST 或超时关闭连接；
      2) **FFmpeg 缺少重连参数**: `bilibili-helper` 的 `ffmpeg` 命令行此前缺少 `-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5`，导致网络抖动或上游连接断开时 FFmpeg 直接将其视作 EOF 退出；
      3) **总时长计算为 0**: 在 `bvid:cid` 点播模式下 `total_duration` 被硬编码赋予 0，导致超长音频守护绕过了 Supervisor，且 Supervisor 正常结束条件判定失效；
      4) **radiod 误判播完跳歌**: FFmpeg 播了一半退出后，由于播放已超过 10 秒，`radiod.sh` 误判为自然播完，调用 `advance_bilibili` 切至下一首。
    - **修复**:
      1) `is_bad_cdn` 识别并过滤 `mcdn`/`pcdn`/`:8082`，从 `[baseUrl] + backupUrl` 中优先提取稳定官方骨干 UPOS 镜像 (`upos-sz-mirror*.bilivideo.com`)；
      2) FFmpeg 输入前补全 `-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5`，结合 UPOS CDN 完美的 HTTP 206 Range 支持实现毫秒级静默自动续传；
      3) 从 `playurl` 接口中的 `data.timelength` 直接获取精准视频总时长，修正 `total_duration`；
      4) 完善 Supervisor 断点接力与已播满判定逻辑，杜绝半途退出。
23. **YouTube 音乐播单全量失败无限连跳 (机房 IP 风控与 Sign in to confirm you're not a bot)**:
    - **现象**: 某些 YouTube 播单（如 NPR Music Tiny Desk Concert `PLy2PCKGkKRVaB9xWjcZ2VqUcBV_2x88PB`）在电台点播时 47 首无一能播，在数十秒内连续快速跳过全部曲目。
    - **根因**:
      1) **机房 IP 拦截**: VPS IP 属于腾讯云数据中心 ASN，谷歌对此类 IP 实施了自动化的访问限制；
      2) **版权音乐高严风控**: 普通个人视频允许匿名拉流，但 NPR Music / Vevo 等官方音乐内容被 YouTube 强制启用了 BotGuard 人机对抗校验。所有 InnerTube 客户端均返回 `LOGIN_REQUIRED`（`Sign in to confirm you're not a bot`）；
      3) **未配置 Cookie**: 服务器 `/var/lib/radiod/youtube_cookies.txt` 为空；
      4) **GoogleVideo 403 Forbidden 独立访问限制**: 部分高防护音乐视频，虽然 `yt-dlp` 解密算出了 `videoplayback` 直链，但当 `ffmpeg` 独立通过标准 HTTP GET 访问直链时，由于缺乏 `yt-dlp` 内置的下载器会话状态、会话 Cookie 及 Range 分块协调，被 GoogleVideo CDN 直接返回 403 Forbidden；
      5) **radiod 快败连跳**: 曲目在 2 秒内失败，`radiod.sh` 判定快速失败并切歌，形成走马灯连跳。
    - **解决与修复**:
      1) **导入 Cookie 认证**: 浏览器导出已登录 YouTube 的 Netscape 格式 `cookies.txt`，安装至 `/var/lib/radiod/youtube_cookies.txt` (所有者 `radiod:radiod`，权限 `0644`)，配合 Deno 运行时解答 JS 签名；
      2) **yt-dlp 管道流直推 FFmpeg (终极规避 403)**: `youtube-helper stream` 改造为 `yt-dlp -o - | ffmpeg -i pipe:0` 管道模式。由 `yt-dlp` 原生下载器全程负责会话认证、分块拉取与连接维系，`ffmpeg` 从标准输入接收并转码至 FIFO，彻底消除 Google CDN 403 访问拒绝；
      3) **管理指令支持**: `radioctl youtube cookie [file]` 支持查看/一键导入 Cookie，`radioctl youtube proxy [url|off]` 支持配置代理；
      4) **增强诊断反馈**: `youtube-helper` 捕获该错误并向日志和面板返回明朗指引，避免盲目排查。
24. **YouTube Cookie 活跃会话轮换失效与 yt-dlp 回写覆写破坏 (Cloudflare WARP 本地 SOCKS5 出口方案)**:
    - **现象**:
      1) 用户在浏览器中导出的 Cookie 安装到服务器后，播放几首歌曲或几分钟后即失效，重新报 `Sign in to confirm you're not a bot`；
      2) 经过 `yt-dlp` 运行后，检查服务器上的 `/var/lib/radiod/youtube_cookies.txt`，发现文件被清空或关键的 `LOGIN_INFO` / `__Secure-1PSIDTS` 字段被剔除；
      3) 若将 Cookie 文件设置为只读 (`chmod 444`)，`yt-dlp` 退出时会抛出 `PermissionError: [Errno 13] Permission denied` 导致进程直接异常崩溃。
    - **根因**:
      1) **Google Cookie 活跃轮换机制**: Google 在 2024~2026 年加强了会话安全，在活跃浏览器中浏览时会高频刷新 `__Secure-1PSIDTS` 并更新 `LOGIN_INFO`。若从普通活跃页面导出 Cookie，浏览器稍后发出的后台网络请求就会使已导出的凭据立即作废；
      2) **yt-dlp 退出回写覆写破坏**: `yt-dlp --cookies <file>` 机制在退出时默认会将内存中的 CookieJar 回写同步到磁盘文件。当请求遭遇人机验证或服务端拒绝时，`yt-dlp` 的会话注销逻辑会把失效的 `LOGIN_INFO` 从 CookieJar 中抹除并覆写回文件，导致存盘的 Cookie 母盘被不可逆破坏；若禁止写权限，`yt-dlp` 退出阶段又会抛异常崩溃；
      3) **机房 IP 对 OAuth / PO Token 彻底封死**: YouTube 早已关停 TV/设备端 OAuth 2.0 登录通道；第三方 PO Token (如 bgutil) 在腾讯云机房 ASN 下由于缺乏前置受信上下文，同样无法通过 BotGuard 挑战。
    - **修复与终极方案**:
      1) **Cloudflare WARP 本地 SOCKS5 代理出口 (核心破局点)**:
         - 在 VPS 上部署官方 `cloudflare-warp` (`warp-svc.service`)，关键配置为**代理模式** (`warp-cli mode proxy`) 并绑定端口 `127.0.0.1:40000` (`warp-cli proxy port 40000`)；
         - **安全性与网络零影响**: 代理模式**绝不修改 VPS 路由表与公网 IP，绝不影响 SSH 连接与已有服务**，仅在本地监听一个轻量级 SOCKS5 端口；
         - **绕过效果**: 通过 `radioctl youtube proxy socks5://127.0.0.1:40000` 将代理注入 `youtube-helper`。由于 Cloudflare WARP 拥有干净全球 Anycast 出口，YouTube 将其识别为正常家庭/移动用户流量，**完全不触发任何 BotGuard 人机拦截**，实现 **0 账号、0 Cookie、0 人机拦截** 的全量畅播；
      2) **Cookie 母盘快照与运行时隔离保护**:
         - 在 `youtube-helper` 中彻底重构 Cookie 文件传递逻辑：每次调用 `yt-dlp` 前，将 `/var/lib/radiod/youtube_cookies.txt` 快照复制至 `/tmp/radiod_yt_cookie_<pid>.txt`，由 `yt-dlp` 独立使用临时副本，退出后自动清理；
         - 无论 `yt-dlp` 如何回写或擦除 CookieJar，原始母盘文件始终受到绝对保护，永不被篡改污染；
      3) **无痕 + robots.txt 零轮换导出标准**:
         - 针对日后若需播放私密或特定年龄限制视频的场景，制定标准无轮换导出法：打开无痕窗口 → 登录账号 → 访问 `youtube.com/robots.txt` (纯文本不触发脚本轮换) → Export Netscape → **立即关闭无痕窗口** (切断连接锁定凭据) → 导入 VPS。

