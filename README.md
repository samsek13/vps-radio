# VPS Radio — 全天候个人多音源网络电台

基于 Linux VPS 构建的高性能个人网络流媒体广播电台。任何设备只需打开网页即可实时收听，无需安装任何客户端或插件。

电台支持 **Spotify Connect、网易云音乐、B站、YouTube、SoundCloud、Bandcamp、本地音频文件及媒体库** 等 8 大音源随时热切换，采用**常驻总线架构**，在换源或切歌时听众端**不断流、不掉线**。

```
                   ┌──────────┐
                   │ 八大音源 │ (热切换, 同一时刻一个)
                   └────┬─────┘
                        │ PCM (s16le 44.1kHz)
                        ▼
┌────────────────────────────────────────────────────────┐
│ 常驻总线 (永不动)                                      │
│   音频 FIFO ──▶ ffmpeg (-re)                           │
│                   ├─ azmq 动态音量调节 (0.1~10.0x)     │
│                   └─ 编码为 Opus 128k                  │
│                        │ RTSP (:8554/live)             │
│                        ▼                               │
│                   MediaMTX                             │
│                   ├─ :8889 WebRTC/WHEP (<1s 极低延迟)  │
│                   └─ :8888 HLS (数秒延迟, 稳定兜底)    │
└───────────────────────┬────────────────────────────────┘
                        │
                        ▼
┌────────────────────────────────────────────────────────┐
│ Caddy 反代 (HTTPS & 统一入口)                          │
│   ├─ /        自托管 Web 播放页 (WHEP 主路 + HLS 备路) │
│   ├─ /np      Now Playing / 在线人数公开端点           │
│   └─ /admin   Web 管理面板 (basic_auth + Bearer 双重)  │
└────────────────────────────────────────────────────────┘
```

---

## 🌟 核心特性

- **多音源自由切换**:
  - 🟢 **Spotify Connect**: VPS 注册为远程音箱设备，手机/电脑 Spotify 客户端一键投播点歌，通过 librespot `--onevent` 实时同步曲目与艺人信息至全站 Now Playing；支持通过官方 Web API 在 Admin 后台及 CLI 实现主动切歌（下一首/上一首）。
  - 🎵 **网易云音乐 (Netease)**: 歌单/专辑循环、私人 FM、每日推荐、播客电台、关键词搜索点歌；内置 `X-Real-IP` 穿透解决海外机房限制。
  - ⚡ **Bilibili (B站)**: 纯游客 0 账号免登录（WBI 动态签名缓存）；支持单视频、分 P、公开收藏夹、UP 主合集/系列、关键词搜索；超长音频（>2h）后台自动断点接力续播。
  - ▶️ **YouTube**: 单视频、歌单、Shorts 短视频、关键词搜索；DASH Opus 160k 纯音频直接拉流；支持联动本地 Cloudflare WARP SOCKS5 代理出口，免疫机房 IP 人机拦截与 403 阻断；支持 >2h 自动换 Token 断点续播。
  - 🎸 **Bandcamp**: 单曲、专辑、艺人全库、关键词搜索；纯匿名 0 账号免登录；128kbps 原生 MP3 直推与多作品并发解析。
  - ☁️ **SoundCloud**: 匿名 `client_id` 双 Surface 抓取与自愈刷新；支持用户 Likes 循环、歌单、关键词搜索。
  - 📁 **本地媒体库 (Folder)**: 本地目录音频全库随机（shuffle）或顺序（seq）播放，每轮播完重扫新曲。
  - 💿 **单个音频 (File)**: 指定单个音频无限循环，支持带起始时点（如 `radioctl file xxx.mp3 01:30`）。
- **切歌/换源永不断流**: 
  - 总线 ffmpeg 始终持有音频 FIFO 读取端，换源或切歌时仅替换写入者，听众端仅有 ~0.5-2 秒平滑静音，播放器不断开重连。
- **动态音量平滑控制**: 
  - 依托 ffmpeg `azmq` 滤镜，无需重启动进程即可实时按倍率无级调节音量（0.1x ~ 10.0x），并支持增益持久化。
- **灵活的播放模式控制**: 
  - 支持 `repeat`（单曲循环）、`loop`（列表循环）、`seq`（列表顺序单次）、`shuffle`（乱序洗牌）热切换。
- **双端控制体验**:
  - **终端 CLI**: 完整的 `radioctl` 控制套件，普通用户权限即可执行。
  - **Web 管理面板**: 响应式管理后台 (`/admin`)，支持图形化点歌、搜索、换源、音量推子、服务状态监控与媒体库浏览。
- **现代化收听体验**:
  - 纯前端自托管播放页，优先走 WebRTC (WHEP) 达到 <1 秒极低延迟广播；网络波动时自动无缝降级到 HLS 缓冲路。
  - 支持实时“Now Playing”曲目信息展示与全站同时在线听众人数统计。

---

## 🛠️ 架构组件

| 服务 / 进程 | 运行用户 | 端口 / 路径 | 说明 |
|-------------|----------|-------------|------|
| `radiod.service` | `radiod` | `/run/radiod/` | 核心广播守护进程，负责总线、音源生命周期与命令分发 |
| `mediamtx.service` | `root` / 系统 | 8554 (RTSP), 8889 (WebRTC), 8888 (HLS) | 高性能流媒体服务器 |
| `radio-admin.service` | `radiod` | `127.0.0.1:8811` | Python 轻量管理面板 API 服务 |
| `caddy.service` | `caddy` | 80, 443 | 自动 HTTPS 反代，提供播放页与管理面板路由 |
| `warp-svc.service` (可选) | `warp` | `127.0.0.1:40000` | Cloudflare WARP 本地 SOCKS5 代理（提供纯净出口） |
| `ncm-api.service` (可选) | `docker` | `127.0.0.1:3000` | NeteaseCloudMusicApi 容器（仅扫码登录使用） |

---

## 🚀 快速开始

### 1. 部署到 VPS (Ubuntu 22.04 / 24.04)

```bash
# 本地上传安装包
scp install.sh radiod.sh spotify-event radiod.service radioctl radio-admin radio-admin.service root@<VPS_IP>:/tmp/

# 登入 VPS 并运行一键安装
ssh root@<VPS_IP>
cd /tmp && sudo bash install.sh
```

`install.sh` 脚本将自动完成：
1. 安装 ffmpeg, curl, ufw, build-essential 等依赖。
2. 下载并安装 MediaMTX。
3. 安装 Rust 工具链并现场编译 `librespot`（Spotify Connect 支持）。
4. 创建 `radiod` 系统用户及 `/var/lib/radiod` 运行目录。
5. 配置并启动 systemd 开机自启服务。

### 2. 反向代理配置 (Caddy 示例)

编辑 `/etc/caddy/Caddyfile`（参考仓库中 [`server/Caddyfile`](server/Caddyfile)）：

```caddy
your-domain.com {
    # WebRTC 信令
    handle /whep* {
        rewrite * /live/whep
        reverse_proxy 127.0.0.1:8889
    }

    # HLS 备用路
    handle_path /hls/* {
        reverse_proxy 127.0.0.1:8888 {
            header_down Location ^/live/(.*)$ /hls/live/$1
        }
    }

    # Now Playing 公开状态
    handle /np {
        reverse_proxy 127.0.0.1:8811
    }

    # 管理面板 (外层 basic_auth + 内层 Bearer)
    handle /admin/* {
        basic_auth {
            admin <YOUR_BCRYPT_PASSWORD_HASH>
        }
        uri strip_prefix /admin
        reverse_proxy 127.0.0.1:8811 {
            header_up Authorization "Bearer <YOUR_ADMIN_TOKEN>"
        }
    }

    # 根路径：自托管播放页
    handle {
        root * /var/www/jam
        try_files {path} /index.html
        file_server
    }
}
```

---

## 📻 CLI 常用操作 (`radioctl`)

所有操作在服务器普通用户下即可直接运行：

### 状态与基础控制
```bash
radioctl status          # 查看当前正在播放的音源、曲目及进度
radioctl skip            # 切到下一首 (文件模式下为重新开始)
radioctl seek 01:30      # 当前曲目快进/跳转至指定时点 (支持 mm:ss、hh:mm:ss 或纯秒数)
radioctl volume 1.2      # 动态调整音量倍率 (0.1 ~ 10.0)
radioctl mode shuffle    # 切换播放循环规则 (repeat|loop|seq|shuffle)
```

### 音源切换

#### 1. Spotify Connect
```bash
radioctl spotify               # 切到 Spotify 模式 (在手机/电脑 Spotify 设备列表选择 "VPS Radio" 即可推流)
radioctl spotify next          # 切到下一首 (或直接执行 radioctl skip)
radioctl spotify prev          # 切到上一首
radioctl spotify status        # 查看当前 Spotify 播放与 Web API 凭据状态
radioctl spotify auth          # 配置 Spotify Web API 凭据 (支持 Admin 端切歌控制)
```

#### 2. 网易云音乐
```bash
radioctl netease playlist 3778678 seq     # 歌单循环 (支持数字ID、网页链接或 App 分享文本)
radioctl netease album 18919              # 专辑循环
radioctl netease search "周杰伦 晴天"     # 搜索单曲
radioctl netease play 1                   # 播放搜索结果编号
radioctl netease fm                       # 私人 FM
radioctl netease daily                    # 每日推荐
radioctl netease podcast 794934387        # 播客电台循环
```

#### 3. Bilibili (B站)
```bash
radioctl bilibili BV1xx411c7mD            # 播放单视频或多 P (支持 BV号、av号、b23.tv 短链或完整 URL)
radioctl bilibili fav 12345678 loop       # 公开收藏夹循环
radioctl bilibili search "落日飞车"       # 搜索视频并点播
radioctl bilibili play 2
```

#### 4. YouTube
```bash
radioctl youtube "https://youtu.be/xxx"   # 播放单视频或歌单 (智能识别全链接、短链与 Shorts)
radioctl youtube search "lofi hip hop"   # 搜索视频并点播
radioctl youtube play 1
```

#### 5. Bandcamp
```bash
radioctl bandcamp "https://artist.bandcamp.com/album/xxx"  # 专辑循环
radioctl bandcamp "https://artist.bandcamp.com/track/xxx"  # 单曲循环
radioctl bandcamp search "toe"                             # 关键词搜索
radioctl bandcamp play 1
```

#### 6. SoundCloud
```bash
radioctl soundcloud user likes:username   # 播放指定用户的 Likes 收藏列表
radioctl soundcloud search "techno live"  # 搜索单曲
radioctl soundcloud play 1
```

#### 7. 本地音频与媒体库
```bash
radioctl ls                               # 列出服务器媒体库 (/var/lib/radiod/media)
radioctl folder                           # 媒体库整库随机洗牌播放
radioctl file /var/lib/radiod/media/bgm.mp3 00:30  # 单文件循环，从第 30 秒开始起播
```

---

## 📖 详细运维手册

如需了解完整的服务架构、通信管道协议、各音源的自愈机制与故障排查经验，请查阅：
👉 **[`radio-runbook.md`](radio-runbook.md)**（内含超过 600 行的架构深度解读、踩坑排障全记录与 API 说明）。

---

## 📄 License

[MIT License](LICENSE)
