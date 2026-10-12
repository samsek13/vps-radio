#!/usr/bin/env bash
# install.sh — VPS Radio 一键安装 (Ubuntu 22.04/24.04, root 运行)
# 组件: librespot (cargo 编译) | ffmpeg (PCM→Opus) | MediaMTX (WebRTC/HLS 分发)
#
# 注意: librespot 官方 release 不提供预编译二进制, 本脚本用 rustup + cargo 现场编译
# (首次约 5-10 分钟, 之后缓存; 编译出的二进制零系统依赖, 之后升级只需重编).
set -euo pipefail

LIBRESPOT_VERSION="librespot@0.8.0"    # cargo 语法: librespot@版本
MEDIAMTX_VERSION="v1.21.0"
RADIO_USER="radiod"
RADIO_HOME="/var/lib/radiod"
STREAM_NAME="live"
INSTALL_DIR="/usr/local/bin"

log()  { printf '\033[1;32m[install]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[install] 错误:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行: sudo bash install.sh"
cd "$(dirname "$0")"

# ---------- 1. 系统依赖 ----------
log "安装系统依赖 (ffmpeg, curl, ufw, 编译工具链)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ffmpeg curl ufw build-essential pkg-config >/dev/null
command -v ffmpeg >/dev/null || die "ffmpeg 安装失败"

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  MTX_ARCH="amd64" ;;
    aarch64) MTX_ARCH="arm64" ;;
    *) die "不支持的架构: $ARCH" ;;
esac

# ---------- 2. MediaMTX (有预编译二进制) ----------
if [ ! -x "$INSTALL_DIR/mediamtx" ]; then
    log "下载 MediaMTX ${MEDIAMTX_VERSION} (${MTX_ARCH})..."
    # release 资产名带 v 前缀: mediamtx_v1.21.0_linux_amd64.tar.gz; tar 包内是平铺结构 (无子目录)
    MTX_URL="https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_linux_${MTX_ARCH}.tar.gz"
    curl -fsSL --retry 3 --retry-delay 2 "$MTX_URL" -o /tmp/mediamtx.tar.gz \
        || die "MediaMTX 下载失败 (VPS 访问不了 GitHub? 需配置代理或手动上传)"
    MTX_DIR="/tmp/mtx-extract"; rm -rf "$MTX_DIR"; mkdir -p "$MTX_DIR"
    tar -xzf /tmp/mediamtx.tar.gz -C "$MTX_DIR"
    install -m 755 "$MTX_DIR/mediamtx" "$INSTALL_DIR/mediamtx"
    # tarball 里附带带完整注释的默认配置, 留给第 5 步用
    cp "$MTX_DIR/mediamtx.yml" /tmp/mediamtx-default.yml
    rm -rf /tmp/mediamtx.tar.gz "$MTX_DIR"
else
    log "MediaMTX 已存在, 跳过"
fi
log "mediamtx: $("$INSTALL_DIR/mediamtx" --version 2>/dev/null | head -n1)"

# ---------- 3. librespot (cargo 编译, 无预编译产物) ----------
if [ ! -x "$INSTALL_DIR/librespot" ]; then
    log "安装 Rust 工具链 (rustup, MSRV 1.85)..."
    if ! command -v cargo >/dev/null 2>&1; then
        # ubuntu 22.04/24.04 的 apt rustc 是 1.75, 太旧; 用 rustup 装当前 stable
        curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
        sh /tmp/rustup-init.sh -y --default-toolchain stable --profile minimal \
            >/var/log/rustup-install.log 2>&1 || die "rustup 安装失败, 见 /var/log/rustup-install.log"
        rm /tmp/rustup-init.sh
    fi
    # rustup 默认装到 ~/.cargo; root 的 ~/.profile 已被 rustup 追加 PATH, 但本脚本的
    # 非交互 shell 不会 source 它, 手动导出
    export PATH="$HOME/.cargo/bin:$PATH"
    command -v cargo >/dev/null || die "cargo 不可用"

    log "编译 librespot 0.8.0 (首次约 5-10 分钟, 日志: /var/log/librespot-build.log)..."
    # --no-default-features + rustls-webpki: 零系统 TLS 依赖
    # pipe 后端是无条件编译的, 不需要任何 audio feature
    # with-libmdns 保留: 万一手机与 VPS 同网段 (VPS 有局域网 IP 时), zeroconf 自动可用
    if ! cargo install --locked "$LIBRESPOT_VERSION" \
            --no-default-features \
            --features "rustls-tls-webpki-roots,with-libmdns" \
            --root /usr/local \
            > /var/log/librespot-build.log 2>&1; then
        tail -20 /var/log/librespot-build.log >&2
        die "librespot 编译失败, 完整日志: /var/log/librespot-build.log"
    fi
else
    log "librespot 已存在, 跳过编译"
fi
log "librespot: $("$INSTALL_DIR/librespot" --version 2>/dev/null | head -n1)"

# ---------- 4. 系统用户与目录 ----------
if ! id -u "$RADIO_USER" >/dev/null 2>&1; then
    log "创建系统用户 ${RADIO_USER}..."
    useradd -r -m -d "$RADIO_HOME" -s /usr/sbin/nologin "$RADIO_USER"
fi
mkdir -p "$RADIO_HOME"
chown -R "$RADIO_USER":"$RADIO_USER" "$RADIO_HOME"

# ---------- 5. MediaMTX 配置 ----------
MTX_CFG="/usr/local/etc/mediamtx.yml"
mkdir -p /usr/local/etc
if [ ! -f "$MTX_CFG" ]; then
    log "写入 MediaMTX 默认配置 (来自 release 包内附的 mediamtx.yml)..."
    # mediamtx 不会自己生成配置文件; release tarball 里带一份完整带注释的默认 yml
    if [ -f /tmp/mediamtx-default.yml ]; then
        install -m 644 /tmp/mediamtx-default.yml "$MTX_CFG"
    else
        # 走到这里说明 MediaMTX 是早就装好的 (tarball 已清理), 从 GitHub 拉默认配置
        curl -fsSL "https://raw.githubusercontent.com/bluenviron/mediamtx/main/mediamtx.yml" \
            -o "$MTX_CFG" || die "无法获取 mediamtx 默认配置"
    fi
fi
chown "$RADIO_USER":"$RADIO_USER" "$MTX_CFG"

# 精简攻击面: ingest 仅监听本机回环; 关闭不用的协议
sed -i 's|^rtspAddress: .*|rtspAddress: 127.0.0.1:8554|' "$MTX_CFG"
sed -i 's|^rtmp: .*|rtmp: no|'   "$MTX_CFG"
sed -i 's|^srt: .*|srt: no|'      "$MTX_CFG"
sed -i 's|^webrtcAdditionalHosts: .*|webrtcAdditionalHosts: []|' "$MTX_CFG" 2>/dev/null || true
# 空闲期 (无发布者) 更耐心, 减少重启循环频率: 默认 readTimeout 10s → 300s
sed -i 's|^readTimeout: .*|readTimeout: 300s|' "$MTX_CFG"
grep -q '^paths:' "$MTX_CFG" || die "配置格式异常: 没有 paths 段"
# 追加命名流路径 (在 paths: 段下; all_others 空配置已存在, 不冲突)
grep -q "^  ${STREAM_NAME}:" "$MTX_CFG" || cat >> "$MTX_CFG" <<EOF

  ${STREAM_NAME}:
EOF

# ---------- 6. systemd 服务 ----------
if [ ! -f /etc/systemd/system/mediamtx.service ]; then
    log "安装 mediamtx systemd 服务..."
    cat > /etc/systemd/system/mediamtx.service <<'EOF'
[Unit]
Description=MediaMTX streaming server
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=radiod
ExecStart=/usr/local/bin/mediamtx /usr/local/etc/mediamtx.yml
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
fi

log "安装 radiod (librespot | ffmpeg 管道) 服务与辅助脚本..."
install -m 755 radiod.sh /usr/local/bin/radiod.sh
install -m 755 spotify-event /usr/local/bin/spotify-event
install -m 644 radiod.service /etc/systemd/system/radiod.service

# ---------- 7. 防火墙 ----------
log "配置 ufw..."
UFW_WAS_ACTIVE=0
ufw status 2>/dev/null | grep -q "Status: active" && UFW_WAS_ACTIVE=1
ufw allow 22/tcp   >/dev/null 2>&1 || true   # SSH (保险起见, 防锁死)
ufw allow 8889/tcp >/dev/null 2>&1 || true   # WebRTC 播放页
ufw allow 8888/tcp >/dev/null 2>&1 || true   # HLS 播放页
ufw allow 8189/udp >/dev/null 2>&1 || true   # WebRTC 媒体 (mediamtx 默认 webrtcLocalUDPAddress)
[ "$UFW_WAS_ACTIVE" -eq 1 ] && ufw reload >/dev/null 2>&1 || true
log "端口已放行: 22, 8889/tcp, 8888/tcp, 8189/udp (ufw 未激活则只是预置规则, 不会锁死)"

# ---------- 8. 启用 ----------
systemctl daemon-reload
systemctl enable mediamtx.service radiod.service >/dev/null
systemctl restart mediamtx
sleep 2
systemctl is-active --quiet mediamtx || die "mediamtx 启动失败: journalctl -u mediamtx -n 30"

# radiod 暂不启动 —— librespot 首次运行需登录 Spotify (见下方提示或 README)

IP_HINT="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo VPS_IP)"

cat <<EOF

============================================================
  安装完成!
============================================================
首次登录 Spotify (一次性, 详见 README.md):
  1. 在你本地电脑开 SSH 端口转发 (登录回调用):
       ssh -L 5588:127.0.0.1:5588 root@${IP_HINT}
  2. VPS 上前台跑一次:
       sudo -u radiod /usr/local/bin/radiod.sh
  3. 终端会打印 "Browse to: https://accounts.spotify.com/..."
     复制到本地浏览器完成授权; 回调会经隧道回到 VPS, 凭据自动落盘
  4. 之后交给 systemd:
       systemctl start radiod

日常: 手机 Spotify 设备列表选 "VPS Radio" 点歌即可

分享链接:
  主 (WebRTC, <1s 延迟):  http://${IP_HINT}:8889/${STREAM_NAME}
  备 (HLS, 数秒延迟):     http://${IP_HINT}:8888/${STREAM_NAME}
============================================================
EOF
