#!/usr/bin/env bash
# radiod.sh — VPS Radio: 常驻音频总线 + 可热切换音源
#   音源(librespot / 单文件 / 文件夹循环) →音频FIFO→ ffmpeg(-re→Opus) → MediaMTX /live
#
# 切换音源只是换 FIFO 上的写者, 总线与听众连接不动:
#   - 本脚本对音频 FIFO 持有 O_RDWR fd (exec 3) → 换源间隙 FIFO 永远有写者,
#     总线 ffmpeg 不会读到 EOF → 不会拆 RTSP → 听众不掉流, 只有短暂静音
#   - 曲目间隙同理: FIFO 64KB 缓冲 (~0.7s) 吸收换曲耗时, 听众无感
#
# 外部控制 (radioctl 往 /run/radiod/cmd.fifo 写命令行):
#   switch-to-spotify
#   switch-to-file <绝对路径>                    # 单曲无限循环
#   switch-to-folder <目录> [shuffle|seq]        # 文件夹循环: 随机(默认)/按名顺序
#   switch-to-netease <ctx> <cid> [shuffle|seq]  # 网易云: ctx=playlist|album(id在cid) |fm|daily|search(cid=起始下标)
#   switch-to-soundcloud <ctx> <cid> [shuffle|seq] # SoundCloud: ctx=likes(permalink在cid)|playlist(id在cid)|search(下标在cid)
#   skip                                         # folder/netease/soundcloud=下一首, file=重头播
# 状态: /run/radiod/source.state  7 字段: name|dir|file|idx|total|order|ts
#   netease 时: dir=playlist:<id>|album:<id>|fm|daily|search; file="<歌曲id> <歌名>"
#   soundcloud 时: dir=likes:<permalink>|playlist:<id>|search; file="<曲目id> <标题>"
# 记忆: /var/lib/radiod/last_source (netease/soundcloud 行 5 字段 name|dir|file|order|idx, 其余 4 字段, 重启后恢复)
#
# 手动前台运行:
#   sudo -u radiod /usr/local/bin/radiod.sh               # 调试
#   sudo -u radiod FORCE_LOGIN=1 .../radiod.sh           # 强制重新 OAuth 登录
#     → 终端打印 "Browse to: <授权链接>", 配合 `ssh -L 5588:127.0.0.1:5588`
#       隧道在本地浏览器完成授权; Ctrl+C 后凭据已在 /var/lib/radiod
set -uo pipefail

LIBRESPOT_NAME="VPS Radio"
SPOTIFY_BITRATE="320"       # Spotify→VPS 段码率 (320=最高音质)
OPUS_BITRATE="128k"         # VPS→听众段 (128k Opus 音乐已很好; 上行紧张降到 96k/64k)
RTSP_IN="rtsp://127.0.0.1:8554/live"
CACHE_DIR="/var/lib/radiod"
MEDIA_DIR="/var/lib/radiod/media"
RUN_DIR="/run/radiod"                  # systemd RuntimeDirectory, radioctl 与本脚本共享
STATE_FILE="$RUN_DIR/source.state"
CMD_FIFO="$RUN_DIR/cmd.fifo"
CMD_RESULT="$RUN_DIR/cmd.result"       # 最近一条命令的处理结果 (ts|文本), 面板/radioctl 读
LAST_SOURCE="$CACHE_DIR/last_source"   # 上次音源; 链路重启/VPS 重启后按此恢复
NETEASE_HELPER="/usr/local/bin/netease-helper"
SEARCH_CACHE="$RUN_DIR/netease_search.cache"  # radioctl search 写 / list search-cache 读 (预建 666)
PODCAST_SEARCH_CACHE="$RUN_DIR/netease_podcast_search.cache"  # radioctl podcast-search 写 / list podcast-search-cache 读 (预建 666)
SOUNDCLOUD_HELPER="/usr/local/bin/soundcloud-helper"
SC_SEARCH_CACHE="$RUN_DIR/soundcloud_search.cache"  # radioctl search 写 / list search-cache 读 (预建 666)
BILIBILI_HELPER="/usr/local/bin/bilibili-helper"
BILI_SEARCH_CACHE="$RUN_DIR/bilibili_search.cache"  # radioctl search 写 / list search-cache 读 (预建 666)
YOUTUBE_HELPER="/usr/local/bin/youtube-helper"
YT_SEARCH_CACHE="$RUN_DIR/youtube_search.cache"  # radioctl search 写 / list search-cache 读 (预建 666)
BANDCAMP_HELPER="/usr/local/bin/bandcamp-helper"
BC_SEARCH_CACHE="$RUN_DIR/bandcamp_search.cache"  # radioctl search 写 / list search-cache 读 (预建 666)
# netease 音源运行态复用 folder 的 PLAYLIST/PLAY_IDX/PLAY_ORDER:
#   PLAYLIST 元素 = "<歌曲id> <歌名>" (id=首token; 歌名的 | / CR / LF 已由 helper 清洗)
#   PLAY_DIR = 上下文: playlist:<id> | album:<id> | podcast:<id> | program:<id> | fm | daily | search
NT_CTX=""                              # 当前上下文种类 (playlist/album/podcast/program/fm/daily/search)
# soundcloud 同构: PLAYLIST 元素 = "<曲目id> <标题>"; PLAY_DIR = likes:<permalink> | playlist:<id> | search
SC_CTX=""                              # 当前上下文种类 (likes/playlist/search)
# bilibili 同构: PLAYLIST 元素 = "<bvid[:cid]> <标题>"; PLAY_DIR = video:<bvid> | fav:<id> | season:<id> | search
BILI_CTX=""                            # 当前上下文种类 (video/fav/season/search)
# youtube 同构: PLAYLIST 元素 = "<video_id> <标题>"; PLAY_DIR = video:<id> | playlist:<id> | search
YT_CTX=""                              # 当前上下文种类 (video/playlist/search)
# bandcamp 同构: PLAYLIST 元素 = "<track_url> <标题>"; PLAY_DIR = track:<url> | album:<url> | artist:<url> | search:<idx>
BC_CTX=""                              # 当前上下文种类 (track/album/artist/search)

log() { LOG_LAST="$*"; echo "radiod: $*"; }

# ---------- 命令结果反馈 (2026-09-15: 面板点播失败要"响"出来, 不再静默) ----------
# 失败路径统一走 fail: 打日志 + 记原因 (CMD_NOTE) + return 1。
# 主循环据 handle_cmd 返回值把 "<ts>|OK|<文本>" / "<ts>|FAIL|<原因>" 写进 cmd.result,
# 面板/radioctl 的 status 展示最近一次操作结果。
write_cmd_result() {  # write_cmd_result <OK|FAIL> <文本>
    printf '%s|%s|%s\n' "$(date +%s)" "$1" "${2:-无详情}" > "$CMD_RESULT" 2>/dev/null || true
}
fail() { log "$*"; CMD_NOTE="$*"; return 1; }
note() { CMD_NOTE="$*"; }

# ---------- 登录模式: 不接 ffmpeg, 让 OAuth 链接直接打到终端 ----------
if [ -n "${FORCE_LOGIN:-}" ]; then
    exec librespot \
        --name "$LIBRESPOT_NAME" \
        --backend pipe --bitrate "$SPOTIFY_BITRATE" \
        --disable-audio-cache --volume-ctrl fixed \
        --cache "$CACHE_DIR" \
        --enable-oauth
fi

# ---------- 音频总线: ffmpeg -re 从 FIFO 读 s16le/44.1k/立体声 裸PCM, 编 Opus 推 RTSP ----------
# -re 至关重要: 按实时速率读 → 音源为 librespot 时播放进度 1:1 (librespot 按"已写字节"
#   算进度, 不限速则整首歌几秒内"播完"→ 疯狂切歌, librespot issue #521);
#   文件音源则靠 FIFO 背压自然限速 (写满 64KB → 写者阻塞, 无需 -re)
AUDIO_FIFO="$(mktemp -u /tmp/radiod.XXXXXX.fifo)"
mkfifo "$AUDIO_FIFO" || exit 1

VOL_FILE="$CACHE_DIR/bus_volume"
VOL_VAL="$(cat "$VOL_FILE" 2>/dev/null || echo "1.0")"
case "$VOL_VAL" in
    [0-9]|10|[0-9].[0-9]*|10.0*) ;;
    *) VOL_VAL="1.0" ;;
esac

ffmpeg \
    -hide_banner -loglevel warning \
    -re \
    -f s16le -ar 44100 -ch_layout stereo -i "$AUDIO_FIFO" \
    -af "azmq,volume@vol=volume=${VOL_VAL}:eval=frame,alimiter=limit=0.98" \
    -c:a libopus -b:a "$OPUS_BITRATE" \
    -f rtsp "$RTSP_IN" &
BUS_PID=$!

# O_RDWR 打开 FIFO 既不阻塞又常持读写两端 → 换源无缝的关键
exec 3<>"$AUDIO_FIFO"

# FIFO 容量扩到 512KB (~2.9s 音频): 默认 64KB(0.37s) 太浅, netease 源从 CDN 拉流一抖
# >0.4s 总线即断粮 → 出口流出现缺口 → 听众端 NetEQ 时域拉伸 (忽快忽慢/变调)。
# 容量是管道实例的属性: 必须在 fd3 持有实例后设置 (mkfifo 后立刻设会随临时 fd 关闭
# 而失效); 命令替换子进程继承 fd3, 对 3 号 fcntl 即可。失败不致命 → 保留 64KB 默认。
# fs.pipe-max-size=1MB 限内, 非特权可设 (F_SETPIPE_SZ=1031, 2026-09-14 实测)
FIFO_CAPA="$(python3 -c 'import fcntl; fcntl.fcntl(3, fcntl.F_SETPIPE_SZ, 512*1024); print(f"{fcntl.fcntl(3, fcntl.F_GETPIPE_SZ)//1024}KB")' 2>/dev/null)" \
    && log "音频 FIFO 缓冲 ${FIFO_CAPA} (~2.9s)" \
    || log "警告: FIFO 扩容失败, 保持默认 64KB (~0.37s)"

# 换曲静音垫 (2026-09-14): 换曲/切源空窗给 FIFO 垫静音, 总线 ffmpeg 持续出帧,
# HLS 段不断流 → 听众时间轴不停走, 不再贴边追赶。
# gap 信号: 本脚本 touch /run/radiod/gap.on → filler 补静音; 新源出声 (FIFO 水位涨)
# 或 30s 超时 (spotify 空闲) → filler 自清标志退役。filler 缺席则静默跳过, 无损音质。
GAP_FLAG="$RUN_DIR/gap.on"
FILL_PID=""
if [ -x /usr/local/bin/radio-silence-fill ]; then
    python3 /usr/local/bin/radio-silence-fill &   # 继承 fd 3 (音频 FIFO)
    FILL_PID=$!
fi

# 命令 FIFO (O_RDWR 同理); systemd 下 /run/radiod 由 RuntimeDirectory 保证存在,
# 手动前台调试时可能建不了 (radiod 无权写 /run) → 跳过, 只影响 radioctl 不影响音频
# chmod 666: radiod 建 FIFO 默认 644, radioctl (其他用户) 需要写权限才能发命令
HAVE_CMD=0
if mkdir -p "$RUN_DIR" 2>/dev/null && { rm -f "$CMD_FIFO"; mkfifo "$CMD_FIFO"; }; then
    chmod 666 "$CMD_FIFO"
    exec 4<>"$CMD_FIFO"
    HAVE_CMD=1
    touch "$SEARCH_CACHE" 2>/dev/null && chmod 666 "$SEARCH_CACHE" 2>/dev/null || true
    touch "$PODCAST_SEARCH_CACHE" 2>/dev/null && chmod 666 "$PODCAST_SEARCH_CACHE" 2>/dev/null || true
    touch "$SC_SEARCH_CACHE" 2>/dev/null && chmod 666 "$SC_SEARCH_CACHE" 2>/dev/null || true
    touch "$BILI_SEARCH_CACHE" 2>/dev/null && chmod 666 "$BILI_SEARCH_CACHE" 2>/dev/null || true
    touch "$YT_SEARCH_CACHE" 2>/dev/null && chmod 666 "$YT_SEARCH_CACHE" 2>/dev/null || true
    touch "$BC_SEARCH_CACHE" 2>/dev/null && chmod 666 "$BC_SEARCH_CACHE" 2>/dev/null || true
    touch "$CMD_RESULT" 2>/dev/null && chmod 666 "$CMD_RESULT" 2>/dev/null || true
else
    log "警告: 无法创建 $CMD_FIFO, radioctl 不可用 (音频不受影响)"
fi

# ---------- 音源状态 ----------
SRC_PID=""                  # 当前音源进程
SRC_NAME="none"             # spotify | file | folder | netease | soundcloud | bilibili | youtube | bandcamp
SRC_FILE=""                 # 当前文件 (file=单曲; folder=当前曲目; netease/soundcloud/etc="id 标题")
PLAYLIST=()                 # folder 模式的曲目绝对路径数组
PLAY_IDX=0                  # 当前下标 (0 基)
PLAY_DIR=""                 # folder 模式的目录
PLAY_ORDER="shuffle"        # shuffle | seq
SKIP_PENDING=0              # skip 命令杀的音源不计入连败

write_state() {
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
        "$SRC_NAME" "$PLAY_DIR" "$SRC_FILE" "$PLAY_IDX" "${#PLAYLIST[@]}" "$PLAY_ORDER" \
        "$(date +%s)" > "$STATE_FILE"
}

write_last() {
    if [ "$SRC_NAME" = "netease" ] || [ "$SRC_NAME" = "soundcloud" ] || [ "$SRC_NAME" = "bilibili" ] || [ "$SRC_NAME" = "youtube" ] || [ "$SRC_NAME" = "bandcamp" ]; then
        # 第 5 字段 idx 仅 netease/soundcloud/bilibili/youtube/bandcamp 行有; 旧版 radiod 读到不认识的行不命中任何 case → 默认 spotify, 回滚安全
        printf '%s|%s|%s|%s|%s\n' "$SRC_NAME" "$PLAY_DIR" "${SRC_FILE:-}" "$PLAY_ORDER" "$PLAY_IDX" > "$LAST_SOURCE"
    else
        printf '%s|%s|%s|%s\n' "$SRC_NAME" "$PLAY_DIR" "${SRC_FILE:-}" "$PLAY_ORDER" > "$LAST_SOURCE"
    fi
}

term_kill() {
    # TERM → 1s 宽限 → KILL9 → 回收. ffmpeg 的信号处理带 SA_RESTART,
    # 阻塞在 FIFO read 时 TERM 会被吞掉, 必须靠 KILL 兜底
    local pid="$1"
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null
    for _ in 1 2; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 0
}

stop_source() {
    [ -n "$SRC_PID" ] || { PLAY_DIR=""; PLAYLIST=(); PLAY_IDX=0; NT_CTX=""; SC_CTX=""; return 0; }
    touch "$GAP_FLAG" 2>/dev/null   # 静音垫: 换源空窗总线不断粮
    term_kill "$SRC_PID"
    SRC_PID=""; SRC_NAME="none"; SRC_FILE=""
    PLAY_DIR=""; PLAYLIST=(); PLAY_IDX=0; NT_CTX=""; SC_CTX=""
}

# ---------- 文件夹扫描 ----------
scan_folder() {
    # 递归收集目录下音频文件 → PLAYLIST
    # seq=按名排序; 其他=随机洗牌. null 分隔全程, 兼容空格文件名
    local d="$1" order="${2:-shuffle}"
    if [ "$order" = "seq" ]; then
        mapfile -d '' PLAYLIST < <(find "$d" -type f \
            \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.aac' -o -iname '*.flac' \
               -o -iname '*.wav' -o -iname '*.ogg' -o -iname '*.opus' -o -iname '*.wma' \) \
            -print0 | sort -z)
    else
        mapfile -d '' PLAYLIST < <(find "$d" -type f \
            \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.aac' -o -iname '*.flac' \
               -o -iname '*.wav' -o -iname '*.ogg' -o -iname '*.opus' -o -iname '*.wma' \) \
            -print0 | shuf -z)
    fi
}

# ---------- 音源启动 ----------
start_spotify() {
    # Spotify Connect 接收端. pipe 后端输出固定 S16LE/44.1k/立体声, 与总线输入格式一致
    SRC_NAME="spotify"; SRC_FILE=""
    librespot \
        --name "$LIBRESPOT_NAME" \
        --backend pipe --bitrate "$SPOTIFY_BITRATE" \
        --disable-audio-cache --volume-ctrl fixed \
        --cache "$CACHE_DIR" \
        > "$AUDIO_FIFO" &
    SRC_PID=$!
    write_state; write_last
    log "source=spotify pid=$SRC_PID"
}

start_file() {
    # 单文件音源: 无限循环同一文件. -stream_loop -1 由 ffmpeg 内部 seek 回开头
    # -y: FIFO 已存在, ffmpeg 对输出文件有"拒绝覆盖"保护, 不加会直接退出
    local f="$1" ss="${2:-}"
    SRC_NAME="file"; SRC_FILE="$f"
    local ss_args=()
    [ -n "$ss" ] && ss_args=(-ss "$ss")
    ffmpeg \
        -hide_banner -loglevel warning -nostdin -y \
        "${ss_args[@]}" \
        -stream_loop -1 -i "$f" \
        -vn -map 0:a:0 \
        -ac 2 -ar 44100 -f s16le \
        "$AUDIO_FIFO" &
    SRC_PID=$!
    write_state; write_last
    log "source=file($(basename "$f")) pid=$SRC_PID"
}

start_track() {
    # folder 模式起当前下标的曲目 (无 -stream_loop: 播完退出 → 主循环前进到下一首)
    local ss="${1:-}"
    local f="${PLAYLIST[$PLAY_IDX]}"
    SRC_NAME="folder"; SRC_FILE="$f"
    local ss_args=()
    [ -n "$ss" ] && ss_args=(-ss "$ss")
    ffmpeg \
        -hide_banner -loglevel warning -nostdin -y \
        "${ss_args[@]}" \
        -i "$f" \
        -vn -map 0:a:0 \
        -ac 2 -ar 44100 -f s16le \
        "$AUDIO_FIFO" &
    SRC_PID=$!
    write_state; write_last
    log "folder[$PLAY_ORDER] $((PLAY_IDX + 1))/${#PLAYLIST[@]}: $(basename "$f") pid=$SRC_PID"
}

start_folder() {
    # 扫描目录并从头播放; 目录无音频文件 → 返回 1 (调用方决定回落)
    local d="$1" order="${2:-shuffle}"
    [ "$order" = "seq" ] || order="shuffle"
    scan_folder "$d" "$order"
    if [ "${#PLAYLIST[@]}" -eq 0 ]; then
        log "folder '$d' 没有音频文件 (mp3/m4a/aac/flac/wav/ogg/opus/wma)"
        return 1
    fi
    PLAY_DIR="$d"; PLAY_ORDER="$order"; PLAY_IDX=0
    start_track
}

advance_folder() {
    if [ "$PLAY_ORDER" = "repeat" ]; then
        if [ "$SKIP_PENDING" = 1 ]; then
            SKIP_PENDING=0
            PLAY_IDX=$(( (PLAY_IDX + 1) % ${#PLAYLIST[@]} ))
        fi
        log "folder 单曲循环: 重播当前曲目"
        start_track
        return
    fi
    # 下一首; 一轮播完 → 重扫目录 (拾取新上传的文件) + 重洗牌; 目录已空 → 回落 spotify
    PLAY_IDX=$((PLAY_IDX + 1))
    if [ "$PLAY_IDX" -ge "${#PLAYLIST[@]}" ]; then
        if [ "$PLAY_ORDER" = "seq" ]; then
            log "folder 顺序播放完毕 ($PLAY_DIR), 回落 spotify"
            start_spotify
            return
        fi
        log "一轮播完, 重扫 '$PLAY_DIR' 并重新洗牌"
        scan_folder "$PLAY_DIR" "$PLAY_ORDER"
        if [ "${#PLAYLIST[@]}" -eq 0 ]; then
            log "目录已无音频文件, 回落 spotify"
            start_spotify
            return
        fi
        PLAY_IDX=0
    fi
    start_track
}

# ---------- netease 音源 ----------
nt_load_list() {
    # nt_load_list <ctx> [cid] → 填 PLAYLIST; 空 → return 1 (调用方决定回落)
    local ctx="$1" cid="${2:-}"
    local cmd=(list "$ctx")
    case "$ctx" in
        playlist|album|podcast|program|song) cmd+=("$cid") ;;
        search)          cmd[1]="search-cache" ;;   # helper 子命令名是 search-cache
        podcast-search)  cmd[1]="podcast-search-cache" ;;
    esac
    mapfile -t PLAYLIST < <("$NETEASE_HELPER" "${cmd[@]}" 2>/dev/null)
    [ "${#PLAYLIST[@]}" -gt 0 ] || return 1
    return 0
}

start_netease_track() {
    # 起当前下标曲目: helper 先 API 解析 URL 再 exec ffmpeg (PID 不变) → 与 file 源同构
    local ss="${1:-}"
    local entry="${PLAYLIST[$PLAY_IDX]}" id="${PLAYLIST[$PLAY_IDX]%% *}"
    SRC_NAME="netease"; SRC_FILE="$entry"
    local helper_cmd=("$NETEASE_HELPER" stream "$id" "$AUDIO_FIFO")
    [ -n "$ss" ] && helper_cmd+=("$ss")
    "${helper_cmd[@]}" &
    SRC_PID=$!
    write_state; write_last
    log "netease[$PLAY_DIR/$PLAY_ORDER] $((PLAY_IDX + 1))/${#PLAYLIST[@]}: ${entry#* } (id=$id) pid=$SRC_PID"
}

start_netease() {
    # start_netease <ctx> <cid> <order> [start_idx]; 列表取不到 → return 1 (调用方回落)
    local ctx="$1" cid="${2:-}" ord="$3" start="${4:-0}"
    case "$ctx" in
        search)
            [ -z "$ord" ] && ord="repeat"
            ;;
        song|program)
            [ -z "$ord" ] && ord="repeat"
            ;;
        fm|daily)
            ord="seq"
            ;;
    esac
    case "$ord" in
        repeat|loop|seq|shuffle) ;;
        *) ord="loop" ;;
    esac

    nt_load_list "$ctx" "$cid" || { log "netease: 取 '$ctx' 列表失败"; return 1; }

    if [ "$ord" = "shuffle" ]; then
        mapfile -t PLAYLIST < <(printf '%s\n' "${PLAYLIST[@]}" | shuf)
        start=0
    fi
    PLAY_DIR="$ctx"; case "$ctx" in playlist|album|podcast|program|song) PLAY_DIR="$ctx:$cid" ;; esac
    NT_CTX="$ctx"; PLAY_ORDER="$ord"; PLAY_IDX=0
    if [ "$start" -gt 0 ] 2>/dev/null && [ "$start" -lt "${#PLAYLIST[@]}" ]; then
        PLAY_IDX="$start"
    fi
    start_netease_track
}

advance_netease() {
    # 单曲循环: 重播当前曲目 (若收到 skip 信号则前进到下一首)
    if [ "$PLAY_ORDER" = "repeat" ]; then
        if [ "$SKIP_PENDING" = 1 ]; then
            SKIP_PENDING=0
            PLAY_IDX=$(( (PLAY_IDX + 1) % ${#PLAYLIST[@]} ))
            log "netease 跳曲: 切换至 $((PLAY_IDX + 1))/${#PLAYLIST[@]}"
        else
            if [ "${FAIL_COUNT:-0}" -ge 3 ]; then
                log "netease 单曲连续失败 3 次 (不可播/下架), 回落 spotify"
                FAIL_COUNT=0
                start_spotify
                return
            fi
            log "netease 单曲循环: 重播当前曲目"
        fi
        start_netease_track
        return
    fi

    # 非 repeat: 前进
    PLAY_IDX=$((PLAY_IDX + 1))
    if [ "$PLAY_IDX" -ge "${#PLAYLIST[@]}" ]; then
        if [ "$PLAY_ORDER" = "seq" ]; then
            log "netease 列表顺序播放完毕 ($PLAY_DIR), 回落 spotify"
            start_spotify
            return
        fi
        log "netease 一轮播完 ($PLAY_DIR), 重新取列表"
        local ctx="$NT_CTX" cid=""
        case "$ctx" in playlist|album|podcast|program|song) cid="${PLAY_DIR#*:}" ;; esac
        if ! nt_load_list "$ctx" "$cid"; then
            log "netease 重取列表失败, 回落 spotify"
            start_spotify
            return
        fi
        if [ "$PLAY_ORDER" = "shuffle" ]; then
            mapfile -t PLAYLIST < <(printf '%s\n' "${PLAYLIST[@]}" | shuf)
        fi
        PLAY_IDX=0
    fi
    start_netease_track
}

# ---------- soundcloud 音源 ----------
sc_load_list() {
    # sc_load_list <ctx> [cid] → 填 PLAYLIST; 空 → return 1 (调用方决定回落)
    # ctx: likes (cid=permalink) | playlist (cid=歌单id) | track (cid=单曲id) | search (cid 无用, 读缓存)
    local ctx="$1" cid="${2:-}"
    local cmd=(list "$ctx")
    case "$ctx" in
        likes|playlist|track) cmd+=("$cid") ;;
        search)         cmd[1]="search-cache" ;;   # helper 子命令名是 search-cache
    esac
    mapfile -t PLAYLIST < <("$SOUNDCLOUD_HELPER" "${cmd[@]}" 2>/dev/null)
    [ "${#PLAYLIST[@]}" -gt 0 ] || return 1
    return 0
}

start_soundcloud_track() {
    # 起当前下标曲目: helper 先 API 解析 URL 再 exec ffmpeg (PID 不变) → 与 file/netease 源同构
    local ss="${1:-}"
    local entry="${PLAYLIST[$PLAY_IDX]}" id="${PLAYLIST[$PLAY_IDX]%% *}"
    SRC_NAME="soundcloud"; SRC_FILE="$entry"
    local helper_cmd=("$SOUNDCLOUD_HELPER" stream "$id" "$AUDIO_FIFO")
    [ -n "$ss" ] && helper_cmd+=("$ss")
    "${helper_cmd[@]}" &
    SRC_PID=$!
    write_state; write_last
    log "soundcloud[$PLAY_DIR/$PLAY_ORDER] $((PLAY_IDX + 1))/${#PLAYLIST[@]}: ${entry#* } (id=$id) pid=$SRC_PID"
}

start_soundcloud() {
    # start_soundcloud <ctx> <cid> <order> [start_idx]; 列表取不到 → return 1 (调用方决定)
    local ctx="$1" cid="${2:-}" ord="$3" start="${4:-0}"
    case "$ctx" in
        search)
            [ -z "$ord" ] && ord="repeat"
            ;;
        track)
            [ -z "$ord" ] && ord="repeat"
            ;;
    esac
    case "$ord" in
        repeat|loop|seq|shuffle) ;;
        *) ord="loop" ;;
    esac

    sc_load_list "$ctx" "$cid" || { log "soundcloud: 取 '$ctx' 列表失败"; return 1; }

    if [ "$ord" = "shuffle" ]; then
        mapfile -t PLAYLIST < <(printf '%s\n' "${PLAYLIST[@]}" | shuf)
        start=0
    fi
    PLAY_DIR="$ctx"; case "$ctx" in likes|playlist|track) PLAY_DIR="$ctx:$cid" ;; esac
    SC_CTX="$ctx"; PLAY_ORDER="$ord"; PLAY_IDX=0
    if [ "$start" -gt 0 ] 2>/dev/null && [ "$start" -lt "${#PLAYLIST[@]}" ]; then
        PLAY_IDX="$start"
    fi
    start_soundcloud_track
}

advance_soundcloud() {
    # 单曲循环: 重播当前曲目 (若收到 skip 信号则前进到下一首)
    if [ "$PLAY_ORDER" = "repeat" ]; then
        if [ "$SKIP_PENDING" = 1 ]; then
            SKIP_PENDING=0
            PLAY_IDX=$(( (PLAY_IDX + 1) % ${#PLAYLIST[@]} ))
            log "soundcloud 跳曲: 切换至 $((PLAY_IDX + 1))/${#PLAYLIST[@]}"
        else
            if [ "${FAIL_COUNT:-0}" -ge 3 ]; then
                log "soundcloud 单曲连续失败 3 次 (不可播/下架), 延时 5 秒重试"
                sleep 5
            fi
            log "soundcloud 单曲循环: 重播当前曲目"
        fi
        start_soundcloud_track
        return
    fi

    # 非 repeat
    PLAY_IDX=$((PLAY_IDX + 1))
    if [ "$PLAY_IDX" -ge "${#PLAYLIST[@]}" ]; then
        if [ "$PLAY_ORDER" = "seq" ]; then
            log "soundcloud 列表顺序播放完毕 ($PLAY_DIR), 回落 spotify"
            start_spotify
            return
        fi
        log "soundcloud 一轮播完 ($PLAY_DIR), 重新取列表"
        local ctx="$SC_CTX" cid=""
        case "$ctx" in likes|playlist|track) cid="${PLAY_DIR#*:}" ;; esac
        if sc_load_list "$ctx" "$cid"; then
            if [ "$PLAY_ORDER" = "shuffle" ]; then
                mapfile -t PLAYLIST < <(printf '%s\n' "${PLAYLIST[@]}" | shuf)
            fi
        else
            log "soundcloud 重取列表失败, 复用旧列表续播"
        fi
        PLAY_IDX=0
    fi
    start_soundcloud_track
}

# ---------- bilibili 音源 ----------
bili_load_list() {
    # bili_load_list <ctx> [cid]
    # ctx: video (cid=BV号/链接) | fav (cid=收藏夹id/链接) | season (cid=合集id) | search (cid无用, 读缓存)
    local ctx="$1" cid="${2:-}"
    local cmd=(list "$ctx")
    case "$ctx" in
        video|fav|season) cmd+=($cid) ;;
        search)           cmd[1]="search-cache" ;;
    esac
    mapfile -t PLAYLIST < <("$BILIBILI_HELPER" "${cmd[@]}" 2>/dev/null)
    [ "${#PLAYLIST[@]}" -gt 0 ] || return 1
    return 0
}

start_bilibili_track() {
    local ss="${1:-}"
    local entry="${PLAYLIST[$PLAY_IDX]}" id="${PLAYLIST[$PLAY_IDX]%% *}"
    SRC_NAME="bilibili"; SRC_FILE="$entry"
    local helper_cmd=("$BILIBILI_HELPER" stream "$id" "$AUDIO_FIFO")
    [ -n "$ss" ] && helper_cmd+=("$ss")
    "${helper_cmd[@]}" &
    SRC_PID=$!
    write_state; write_last
    log "bilibili[$PLAY_DIR/$PLAY_ORDER] $((PLAY_IDX + 1))/${#PLAYLIST[@]}: ${entry#* } (id=$id) pid=$SRC_PID"
}

start_bilibili() {
    local ctx="$1" cid="${2:-}" ord="$3" start="${4:-0}"
    case "$ctx" in
        video|search)
            [ -z "$ord" ] && ord="repeat"
            ;;
    esac
    case "$ord" in
        repeat|loop|seq|shuffle) ;;
        *) ord="loop" ;;
    esac

    bili_load_list "$ctx" "$cid" || { log "bilibili: 取 '$ctx' 列表失败"; return 1; }

    if [ "$ord" = "shuffle" ]; then
        mapfile -t PLAYLIST < <(printf '%s\n' "${PLAYLIST[@]}" | shuf)
        start=0
    fi
    PLAY_DIR="$ctx"; case "$ctx" in video|fav|season) PLAY_DIR="$ctx:$cid" ;; esac
    BILI_CTX="$ctx"; PLAY_ORDER="$ord"; PLAY_IDX=0
    if [ "$start" -gt 0 ] 2>/dev/null && [ "$start" -lt "${#PLAYLIST[@]}" ]; then
        PLAY_IDX="$start"
    fi
    start_bilibili_track
}

advance_bilibili() {
    if [ "$PLAY_ORDER" = "repeat" ]; then
        if [ "$SKIP_PENDING" = 1 ]; then
            SKIP_PENDING=0
            PLAY_IDX=$(( (PLAY_IDX + 1) % ${#PLAYLIST[@]} ))
            log "bilibili 跳曲: 切换至 $((PLAY_IDX + 1))/${#PLAYLIST[@]}"
        else
            if [ "${FAIL_COUNT:-0}" -ge 3 ]; then
                log "bilibili 单曲连续失败 3 次, 延时 5 秒重试"
                sleep 5
            fi
            log "bilibili 单曲循环: 重播当前曲目"
        fi
        start_bilibili_track
        return
    fi

    PLAY_IDX=$((PLAY_IDX + 1))
    if [ "$PLAY_IDX" -ge "${#PLAYLIST[@]}" ]; then
        if [ "$PLAY_ORDER" = "seq" ]; then
            log "bilibili 列表顺序播放完毕 ($PLAY_DIR), 回落 spotify"
            start_spotify
            return
        fi
        log "bilibili 一轮播完 ($PLAY_DIR), 重新取列表"
        local ctx="$BILI_CTX" cid=""
        case "$ctx" in video|fav|season) cid="${PLAY_DIR#*:}" ;; esac
        if bili_load_list "$ctx" "$cid"; then
            if [ "$PLAY_ORDER" = "shuffle" ]; then
                mapfile -t PLAYLIST < <(printf '%s\n' "${PLAYLIST[@]}" | shuf)
            fi
        else
            log "bilibili 重取列表失败, 复用旧列表续播"
        fi
        PLAY_IDX=0
    fi
    start_bilibili_track
}

# ---------- youtube 音源 ----------
yt_load_list() {
    # yt_load_list <ctx> [cid]
    # ctx: video (cid=视频ID/链接) | playlist (cid=歌单ID/链接) | search (cid无用, 读缓存)
    local ctx="$1" cid="${2:-}"
    local cmd=(list "$ctx")
    case "$ctx" in
        video|playlist) cmd+=("$cid") ;;
        search) cmd=(list search-cache) ;;
        *) log "youtube: 未知上下文 '$ctx'"; return 1 ;;
    esac
    mapfile -t PLAYLIST < <("$YOUTUBE_HELPER" "${cmd[@]}" 2>/dev/null)
    [ "${#PLAYLIST[@]}" -gt 0 ] || return 1
    return 0
}

start_youtube_track() {
    local ss="${1:-}"
    local entry="${PLAYLIST[$PLAY_IDX]}" id="${PLAYLIST[$PLAY_IDX]%% *}"
    SRC_NAME="youtube"; SRC_FILE="$entry"
    local helper_cmd=("$YOUTUBE_HELPER" stream "$id" "$AUDIO_FIFO")
    [ -n "$ss" ] && helper_cmd+=("$ss")
    "${helper_cmd[@]}" &
    SRC_PID=$!
    write_state; write_last
    log "youtube[$PLAY_DIR/$PLAY_ORDER] $((PLAY_IDX + 1))/${#PLAYLIST[@]}: ${entry#* } (id=$id) pid=$SRC_PID"
}

start_youtube() {
    local ctx="$1" cid="${2:-}" ord="$3" start="${4:-0}"
    case "$ctx" in
        video|search)
            [ -z "$ord" ] && ord="repeat"
            ;;
    esac
    case "$ord" in
        repeat|loop|seq|shuffle) ;;
        *) ord="loop" ;;
    esac

    yt_load_list "$ctx" "$cid" || { log "youtube: 取 '$ctx' 列表失败"; return 1; }

    if [ "$ord" = "shuffle" ]; then
        mapfile -t PLAYLIST < <(printf '%s\n' "${PLAYLIST[@]}" | shuf)
        start=0
    fi
    PLAY_DIR="$ctx"; case "$ctx" in video|playlist) PLAY_DIR="$ctx:$cid" ;; esac
    YT_CTX="$ctx"; PLAY_ORDER="$ord"; PLAY_IDX=0
    if [ "$start" -gt 0 ] 2>/dev/null && [ "$start" -lt "${#PLAYLIST[@]}" ]; then
        PLAY_IDX="$start"
    fi
    start_youtube_track
}

advance_youtube() {
    if [ "$PLAY_ORDER" = "repeat" ]; then
        if [ "$SKIP_PENDING" = 1 ]; then
            SKIP_PENDING=0
            PLAY_IDX=$(( (PLAY_IDX + 1) % ${#PLAYLIST[@]} ))
            log "youtube 跳曲: 切换至 $((PLAY_IDX + 1))/${#PLAYLIST[@]}"
        else
            if [ "${FAIL_COUNT:-0}" -ge 3 ]; then
                log "youtube 单曲连续失败 3 次, 延时 5 秒重试"
                sleep 5
            fi
            log "youtube 单曲循环: 重播当前曲目"
        fi
        start_youtube_track
        return
    fi

    PLAY_IDX=$((PLAY_IDX + 1))
    if [ "$PLAY_IDX" -ge "${#PLAYLIST[@]}" ]; then
        if [ "$PLAY_ORDER" = "seq" ]; then
            log "youtube 列表顺序播放完毕 ($PLAY_DIR), 回落 spotify"
            start_spotify
            return
        fi
        log "youtube 一轮播完 ($PLAY_DIR), 重新取列表"
        local ctx="$YT_CTX" cid=""
        case "$ctx" in video|playlist) cid="${PLAY_DIR#*:}" ;; esac
        if yt_load_list "$ctx" "$cid"; then
            if [ "$PLAY_ORDER" = "shuffle" ]; then
                mapfile -t PLAYLIST < <(printf '%s\n' "${PLAYLIST[@]}" | shuf)
            fi
        else
            log "youtube 重取列表失败, 复用旧列表续播"
        fi
        PLAY_IDX=0
    fi
    start_youtube_track
}

# ---------- bandcamp 音源 ----------
bc_load_list() {
    # bc_load_list <ctx> [cid]
    # ctx: track (cid=URL) | album (cid=URL) | artist (cid=URL) | search (cid=下标)
    local ctx="$1" cid="${2:-}"
    local cmd=(list "$ctx")
    case "$ctx" in
        track|album|artist) cmd+=("$cid") ;;
        search)
            cmd=(list search-cache)
            [ -n "$cid" ] && cmd+=("$cid")
            ;;
        *) log "bandcamp: 未知上下文 '$ctx'"; return 1 ;;
    esac
    mapfile -t PLAYLIST < <("$BANDCAMP_HELPER" "${cmd[@]}" 2>/dev/null)
    [ "${#PLAYLIST[@]}" -gt 0 ] || return 1
    return 0
}

start_bandcamp_track() {
    local ss="${1:-}"
    local entry="${PLAYLIST[$PLAY_IDX]}" id="${PLAYLIST[$PLAY_IDX]%% *}"
    SRC_NAME="bandcamp"; SRC_FILE="$entry"
    local helper_cmd=("$BANDCAMP_HELPER" stream "$id" "$AUDIO_FIFO")
    [ -n "$ss" ] && helper_cmd+=("$ss")
    "${helper_cmd[@]}" &
    SRC_PID=$!
    write_state; write_last
    log "bandcamp[$PLAY_DIR/$PLAY_ORDER] $((PLAY_IDX + 1))/${#PLAYLIST[@]}: ${entry#* } (id=$id) pid=$SRC_PID"
}

start_bandcamp() {
    local ctx="$1" cid="${2:-}" ord="$3" start="${4:-0}"
    case "$ctx" in
        track)
            [ -z "$ord" ] && ord="repeat"
            ;;
    esac
    case "$ord" in
        repeat|loop|seq|shuffle) ;;
        *) ord="loop" ;;
    esac

    bc_load_list "$ctx" "$cid" || { log "bandcamp: 取 '$ctx' 列表失败"; return 1; }

    if [ "$ord" = "shuffle" ]; then
        mapfile -t PLAYLIST < <(printf '%s\n' "${PLAYLIST[@]}" | shuf)
        start=0
    fi
    PLAY_DIR="$ctx"; case "$ctx" in track|album|artist) PLAY_DIR="$ctx:$cid" ;; search) PLAY_DIR="search:$cid" ;; esac
    BC_CTX="$ctx"; PLAY_ORDER="$ord"; PLAY_IDX=0
    if [ "$start" -gt 0 ] 2>/dev/null && [ "$start" -lt "${#PLAYLIST[@]}" ]; then
        PLAY_IDX="$start"
    fi
    start_bandcamp_track
}

advance_bandcamp() {
    if [ "$PLAY_ORDER" = "repeat" ]; then
        if [ "$SKIP_PENDING" = 1 ]; then
            SKIP_PENDING=0
            PLAY_IDX=$(( (PLAY_IDX + 1) % ${#PLAYLIST[@]} ))
            log "bandcamp 跳曲: 切换至 $((PLAY_IDX + 1))/${#PLAYLIST[@]}"
        else
            if [ "${FAIL_COUNT:-0}" -ge 3 ]; then
                log "bandcamp 单曲连续失败 3 次, 延时 5 秒重试"
                sleep 5
            fi
            log "bandcamp 单曲循环: 重播当前曲目"
        fi
        start_bandcamp_track
        return
    fi

    PLAY_IDX=$((PLAY_IDX + 1))
    if [ "$PLAY_IDX" -ge "${#PLAYLIST[@]}" ]; then
        if [ "$PLAY_ORDER" = "seq" ]; then
            log "bandcamp 列表顺序播放完毕 ($PLAY_DIR), 回落 spotify"
            start_spotify
            return
        fi
        log "bandcamp 一轮播完 ($PLAY_DIR), 重新取列表"
        local ctx="$BC_CTX" cid=""
        case "$ctx" in track|album|artist) cid="${PLAY_DIR#*:}" ;; search) cid="${PLAY_DIR#*:}" ;; esac
        if bc_load_list "$ctx" "$cid"; then
            if [ "$PLAY_ORDER" = "shuffle" ]; then
                mapfile -t PLAYLIST < <(printf '%s\n' "${PLAYLIST[@]}" | shuf)
            fi
        else
            log "bandcamp 重取列表失败, 复用旧列表续播"
        fi
        PLAY_IDX=0
    fi
    start_bandcamp_track
}

# ---------- 命令处理 ----------
handle_cmd() {
    # 协议: <命令>[ <参数(可含空格)>]
    # 目录参数与可选 order 从行尾剥离, 兼容带空格的路径
    local line="$1" cmd rest d f ord
    cmd=${line%% *}
    rest=""
    [ "$cmd" != "$line" ] && rest=${line#* }
    case "$cmd" in
        switch-to-spotify)
            stop_source
            start_spotify
            ;;
        switch-to-file)
            local f="$rest" ss=""
            if [ -n "$rest" ] && [ ! -r "$rest" ]; then
                local cand_f="${rest% *}" cand_ss="${rest##* }"
                if [ -r "$cand_f" ]; then
                    f="$cand_f"
                    ss="$cand_ss"
                fi
            fi
            if [ -z "$f" ] || [ ! -r "$f" ]; then
                fail "switch-to-file: 文件不可读 '$rest', 保持当前音源"
                return 1
            fi
            stop_source
            start_file "$f" "$ss"
            ;;
        switch-to-folder)
            case "$rest" in
                *" repeat")  d="${rest% repeat}";  ord="repeat" ;;
                *" loop")    d="${rest% loop}";    ord="loop" ;;
                *" seq")     d="${rest% seq}";     ord="seq" ;;
                *" shuffle") d="${rest% shuffle}"; ord="shuffle" ;;
                *)          d="$rest";            ord="loop" ;;
            esac
            if [ -z "$d" ] || [ ! -d "$d" ]; then
                fail "switch-to-folder: 目录不存在 '$d', 保持当前音源"
                return 1
            fi
            stop_source
            start_folder "$d" "$ord" || { fail "目录无音频文件/启动失败, 回落 spotify"; start_spotify; }
            ;;
        switch-to-netease)
            # 协议: switch-to-netease <ctx> <cid> [repeat|loop|seq|shuffle]
            #   playlist|album|song: cid=数字id;  search: cid=起始下标(0基);  fm|daily: 无 cid
            local ord="loop" body="$rest" ctx cid="" start=0
            case "$rest" in
                *" repeat")  body="${rest% repeat}";  ord="repeat" ;;
                *" loop")    body="${rest% loop}";    ord="loop" ;;
                *" seq")     body="${rest% seq}";     ord="seq" ;;
                *" shuffle") body="${rest% shuffle}"; ord="shuffle" ;;
            esac
            ctx=${body%% *}
            [ "$ctx" != "$body" ] && cid=${body#* }
            case "$ctx" in
                playlist|album|podcast|program|song)
                    [ -n "$cid" ] || { fail "switch-to-netease: $ctx 缺 id, 忽略"; return 1; }
                    ;;
                search|podcast-search) start="$cid" ;;
                fm|daily) ;;
                *) fail "switch-to-netease: 未知上下文 '$ctx', 忽略"; return 1 ;;
            esac
            stop_source
            start_netease "$ctx" "$([ "$ctx" = search ] && echo "" || echo "$cid")" "$ord" "$start" \
                || { fail "取 '$ctx' 列表失败, 回落 spotify"; start_spotify; }
            ;;
        switch-to-soundcloud)
            # 协议: switch-to-soundcloud <ctx> <cid> [repeat|loop|seq|shuffle]
            #   likes: cid=用户permalink;  playlist|track: cid=数字id;  search: cid=起始下标(0基)
            local ord="loop" body="$rest" ctx cid="" start=0
            case "$rest" in
                *" repeat")  body="${rest% repeat}";  ord="repeat" ;;
                *" loop")    body="${rest% loop}";    ord="loop" ;;
                *" seq")     body="${rest% seq}";     ord="seq" ;;
                *" shuffle") body="${rest% shuffle}"; ord="shuffle" ;;
            esac
            ctx=${body%% *}
            [ "$ctx" != "$body" ] && cid=${body#* }
            case "$ctx" in
                likes)
                    case "$cid" in
                        ''|*[!A-Za-z0-9_-]*) fail "switch-to-soundcloud: likes permalink 非法 '$cid', 忽略"; return 1 ;;
                    esac ;;
                playlist|track)
                    case "$cid" in
                        ''|*[!0-9]*) fail "switch-to-soundcloud: $ctx id 需数字 '$cid', 忽略"; return 1 ;;
                    esac ;;
                search) start="$cid" ;;
                *) fail "switch-to-soundcloud: 未知上下文 '$ctx', 忽略"; return 1 ;;
            esac
            stop_source
            start_soundcloud "$ctx" "$cid" "$ord" "$start" \
                || { fail "soundcloud 切换失败 (取列表失败), 保持之前的音源"; return 1; }
            ;;
        switch-to-bilibili)
            # 协议: switch-to-bilibili <ctx> <cid> [repeat|loop|seq|shuffle]
            #   video: cid=BV/URL; fav|season: cid=数字id/URL; search: cid=起始下标(0基)
            local ord="loop" body="$rest" ctx cid="" start=0
            case "$rest" in
                *" repeat")  body="${rest% repeat}";  ord="repeat" ;;
                *" loop")    body="${rest% loop}";    ord="loop" ;;
                *" seq")     body="${rest% seq}";     ord="seq" ;;
                *" shuffle") body="${rest% shuffle}"; ord="shuffle" ;;
            esac
            ctx=${body%% *}
            [ "$ctx" != "$body" ] && cid=${body#* }
            case "$ctx" in
                video) [ -z "$ord" ] && ord="repeat" ;;
                fav|season) [ -n "$cid" ] || { fail "switch-to-bilibili: $ctx 缺 id, 忽略"; return 1; } ;;
                search) start="$cid" ;;
                *) fail "switch-to-bilibili: 未知上下文 '$ctx', 忽略"; return 1 ;;
            esac
            stop_source
            start_bilibili "$ctx" "$cid" "$ord" "$start" \
                || { fail "bilibili 切换失败 (取列表失败), 保持之前的音源"; return 1; }
            ;;
        switch-to-youtube)
            # 协议: switch-to-youtube <ctx> <cid> [repeat|loop|seq|shuffle]
            #   video: cid=ID/URL; playlist: cid=ID/URL; search: cid=起始下标(0基)
            local ord="loop" body="$rest" ctx cid="" start=0
            case "$rest" in
                *" repeat")  body="${rest% repeat}";  ord="repeat" ;;
                *" loop")    body="${rest% loop}";    ord="loop" ;;
                *" seq")     body="${rest% seq}";     ord="seq" ;;
                *" shuffle") body="${rest% shuffle}"; ord="shuffle" ;;
            esac
            ctx=${body%% *}
            [ "$ctx" != "$body" ] && cid=${body#* }
            case "$ctx" in
                video) [ -z "$ord" ] && ord="repeat" ;;
                playlist) [ -n "$cid" ] || { fail "switch-to-youtube: playlist 缺 id, 忽略"; return 1; } ;;
                search) start="$cid" ;;
                *) fail "switch-to-youtube: 未知上下文 '$ctx', 忽略"; return 1 ;;
            esac
            stop_source
            start_youtube "$ctx" "$cid" "$ord" "$start" \
                || { fail "youtube 切换失败 (取列表失败), 保持之前的音源"; return 1; }
            ;;
        switch-to-bandcamp)
            # 协议: switch-to-bandcamp <ctx> <cid> [repeat|loop|seq|shuffle]
            #   track: cid=URL; album: cid=URL; artist: cid=URL; search: cid=起始下标(0基)
            local ord="loop" body="$rest" ctx cid="" start=0
            case "$rest" in
                *" repeat")  body="${rest% repeat}";  ord="repeat" ;;
                *" loop")    body="${rest% loop}";    ord="loop" ;;
                *" seq")     body="${rest% seq}";     ord="seq" ;;
                *" shuffle") body="${rest% shuffle}"; ord="shuffle" ;;
            esac
            ctx=${body%% *}
            [ "$ctx" != "$body" ] && cid=${body#* }
            case "$ctx" in
                track) [ -z "$ord" ] && ord="repeat" ;;
                album|artist) [ -n "$cid" ] || { fail "switch-to-bandcamp: $ctx 缺 URL, 忽略"; return 1; } ;;
                search) start=0 ;;
                *) fail "switch-to-bandcamp: 未知上下文 '$ctx', 忽略"; return 1 ;;
            esac
            stop_source
            start_bandcamp "$ctx" "$cid" "$ord" "$start" \
                || { fail "bandcamp 切换失败 (取列表失败), 保持之前的音源"; return 1; }
            ;;
        mode)
            # 协议: mode <repeat|loop|seq|shuffle>
            if [ "$SRC_NAME" = "spotify" ]; then
                fail "mode: Spotify 模式不支持播放模式切换 (请在手机 Spotify 客户端中设置)"
                return 1
            fi
            local new_ord="$rest"
            case "$new_ord" in
                repeat|loop|seq|shuffle)
                    PLAY_ORDER="$new_ord"
                    write_state
                    write_last
                    note "播放模式已设为: $new_ord"
                    ;;
                *)
                    fail "mode: 参数需为 repeat | loop | seq | shuffle"
                    return 1
                    ;;
            esac
            ;;
        skip)
            case "$SRC_NAME" in
                folder|netease|soundcloud|bilibili|youtube|bandcamp)
                    # 杀当前曲目, 主循环检测到退出后前进下一首; SKIP_PENDING 使其不计连败
                    SKIP_PENDING=1
                    kill "$SRC_PID" 2>/dev/null
                    note "skip: 已发送跳曲信号 (下一首由主循环衔接)"
                    ;;
                file)
                    f="$SRC_FILE"
                    stop_source
                    start_file "$f"
                    ;;
                spotify)
                    fail "skip: spotify 模式请用手机 Spotify Connect 控制"
                    ;;
                *)
                    fail "skip: 当前无可跳的音源 ($SRC_NAME)"
                    ;;
            esac
            ;;
        seek)
            # 协议: seek <时点> (支持 01:30, 00:01:30, 90 等)
            local ss="$rest"
            if [ -z "$ss" ]; then
                fail "seek: 缺少时点参数 (如 01:30 或 90)"
                return 1
            fi
            if [ "$SRC_NAME" = "spotify" ]; then
                fail "seek: Spotify 模式不支持指定时点 (请在手机 Spotify 中拖动进度条)"
                return 1
            fi
            if [ -z "$SRC_NAME" ] || [ "$SRC_NAME" = "none" ]; then
                fail "seek: 当前无正在播放的音源"
                return 1
            fi

            case "$SRC_NAME" in
                file)
                    f="$SRC_FILE"
                    [ -n "$f" ] && [ -r "$f" ] || { fail "seek: 当前文件不可读"; return 1; }
                    touch "$GAP_FLAG" 2>/dev/null
                    term_kill "$SRC_PID"
                    start_file "$f" "$ss"
                    note "已从 $ss 开始播放当前文件: $(basename "$f")"
                    ;;
                folder)
                    [ "${#PLAYLIST[@]}" -gt 0 ] || { fail "seek: 当前播放列表为空"; return 1; }
                    touch "$GAP_FLAG" 2>/dev/null
                    term_kill "$SRC_PID"
                    start_track "$ss"
                    note "已从 $ss 开始播放第 $((PLAY_IDX + 1))/${#PLAYLIST[@]} 首: $(basename "${PLAYLIST[$PLAY_IDX]}")"
                    ;;
                netease)
                    [ "${#PLAYLIST[@]}" -gt 0 ] || { fail "seek: 当前网易云列表为空"; return 1; }
                    local entry="${PLAYLIST[$PLAY_IDX]}"
                    touch "$GAP_FLAG" 2>/dev/null
                    term_kill "$SRC_PID"
                    start_netease_track "$ss"
                    note "已从 $ss 开始播放第 $((PLAY_IDX + 1))/${#PLAYLIST[@]} 首: ${entry#* }"
                    ;;
                soundcloud)
                    [ "${#PLAYLIST[@]}" -gt 0 ] || { fail "seek: 当前 SoundCloud 列表为空"; return 1; }
                    local entry="${PLAYLIST[$PLAY_IDX]}"
                    touch "$GAP_FLAG" 2>/dev/null
                    term_kill "$SRC_PID"
                    start_soundcloud_track "$ss"
                    note "已从 $ss 开始播放第 $((PLAY_IDX + 1))/${#PLAYLIST[@]} 首: ${entry#* }"
                    ;;
                bilibili)
                    [ "${#PLAYLIST[@]}" -gt 0 ] || { fail "seek: 当前哔哩哔哩列表为空"; return 1; }
                    local entry="${PLAYLIST[$PLAY_IDX]}"
                    touch "$GAP_FLAG" 2>/dev/null
                    term_kill "$SRC_PID"
                    start_bilibili_track "$ss"
                    note "已从 $ss 开始播放第 $((PLAY_IDX + 1))/${#PLAYLIST[@]} 首: ${entry#* }"
                    ;;
                youtube)
                    [ "${#PLAYLIST[@]}" -gt 0 ] || { fail "seek: 当前 YouTube 列表为空"; return 1; }
                    local entry="${PLAYLIST[$PLAY_IDX]}"
                    touch "$GAP_FLAG" 2>/dev/null
                    term_kill "$SRC_PID"
                    start_youtube_track "$ss"
                    note "已从 $ss 开始播放第 $((PLAY_IDX + 1))/${#PLAYLIST[@]} 首: ${entry#* }"
                    ;;
                bandcamp)
                    [ "${#PLAYLIST[@]}" -gt 0 ] || { fail "seek: 当前 Bandcamp 列表为空"; return 1; }
                    local entry="${PLAYLIST[$PLAY_IDX]}"
                    touch "$GAP_FLAG" 2>/dev/null
                    term_kill "$SRC_PID"
                    start_bandcamp_track "$ss"
                    note "已从 $ss 开始播放第 $((PLAY_IDX + 1))/${#PLAYLIST[@]} 首: ${entry#* }"
                    ;;
                *)
                    fail "seek: 当前音源 ($SRC_NAME) 不支持从指定时点播放"
                    return 1
                    ;;
            esac
            FAIL_COUNT=0
            LAST_START=$(date +%s)
            ;;
        volume)
            # volume <float>
            local v="$rest"
            if [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                if python3 -c "import zmq, sys; ctx=zmq.Context(); s=ctx.socket(zmq.REQ); s.setsockopt(zmq.RCVTIMEO, 2000); s.connect('tcp://127.0.0.1:5555'); s.send_string('volume@vol volume ' + sys.argv[1]); r=s.recv_string(); sys.exit(0 if ('Success' in r or r.startswith('0')) else 1)" "$v" 2>/dev/null; then
                    echo "$v" > "$CACHE_DIR/bus_volume"
                    note "音量倍数已设为 ${v}x"
                else
                    echo "$v" > "$CACHE_DIR/bus_volume"
                    note "音量倍数已存为 ${v}x (总线未响应, 重启生效)"
                fi
            else
                fail "volume: 参数需为浮点数字 (如 1.5)"
                return 1
            fi
            ;;
        *)
            fail "unknown command: $line"
            ;;
    esac
}

# ---------- 主循环 ----------
cleanup() {
    # 先杀静音垫 (它也持 fd 3 副本, 不杀会挡住下面"关 fd 3 → 总线读 EOF"的退出路径)
    [ -n "$FILL_PID" ] && term_kill "$FILL_PID"
    rm -f "$GAP_FLAG"
    # 先关自己持有的 FIFO fd: 这是唯一写者时, 总线 ffmpeg 立即读到 EOF 退出
    # (TERM 常被 ffmpeg 的 SA_RESTART 吞掉, EOF 才是可靠的退出路径)
    exec 3>&- 4>&- 2>/dev/null || true
    stop_source
    term_kill "$BUS_PID"
    rm -f "$AUDIO_FIFO"
}
trap cleanup EXIT
trap 'exit 143' TERM INT

# 启动默认音源: 上次关机前的音源 (文件已不可读 / 首次运行 → spotify)
START_MODE="spotify"; START_ARG=""; START_ORDER="shuffle"; START_IDX=0
if [ -s "$LAST_SOURCE" ]; then
    IFS='|' read -r lname ldir lfile lorder lidx < "$LAST_SOURCE"
    case "$lname" in
        file)    [ -r "${lfile:-}" ] && { START_MODE="file"; START_ARG="$lfile"; } ;;
        folder)  [ -d "${ldir:-}" ]  && { START_MODE="folder"; START_ARG="$ldir"; START_ORDER="${lorder:-shuffle}"; } ;;
        netease) [ -n "${ldir:-}" ]  && { START_MODE="netease"; START_ARG="$ldir";
                                          START_ORDER="${lorder:-seq}"; START_IDX="${lidx:-0}"; } ;;
        soundcloud) [ -n "${ldir:-}" ] && { START_MODE="soundcloud"; START_ARG="$ldir";
                                            START_ORDER="${lorder:-seq}"; START_IDX="${lidx:-0}"; } ;;
        bilibili) [ -n "${ldir:-}" ] && { START_MODE="bilibili"; START_ARG="$ldir";
                                          START_ORDER="${lorder:-seq}"; START_IDX="${lidx:-0}"; } ;;
        youtube)  [ -n "${ldir:-}" ] && { START_MODE="youtube"; START_ARG="$ldir";
                                          START_ORDER="${lorder:-seq}"; START_IDX="${lidx:-0}"; } ;;
        bandcamp) [ -n "${ldir:-}" ] && { START_MODE="bandcamp"; START_ARG="$ldir";
                                          START_ORDER="${lorder:-loop}"; START_IDX="${lidx:-0}"; } ;;
    esac
fi
case "$START_MODE" in
    spotify) start_spotify ;;
    file)    start_file "$START_ARG" ;;
    folder)  start_folder "$START_ARG" "$START_ORDER" || start_spotify ;;
    netease)
        ctx="${START_ARG%%:*}"; cid=""
        case "$ctx" in playlist|album|podcast|program|song) cid="${START_ARG#*:}" ;; esac
        idx="$START_IDX"
        [ "$START_ORDER" = "shuffle" ] && idx=0    # shuffle 重启重洗, 位置无意义 (与 folder 一致)
        [ "$ctx" = "fm" ] && idx=0                 # fm 列表一次性, 重取从头
        [ "$ctx" = "program" ] || [ "$ctx" = "song" ] && idx=0            # 单集/单曲重启从头
        start_netease "$ctx" "$cid" "$START_ORDER" "$idx" || start_spotify
        ;;   # search/podcast-search: 服务重启(/run 未丢)缓存仍在→正常恢复; VPS 重启缓存丢→取列表失败→spotify, 优雅降级
    soundcloud)
        ctx="${START_ARG%%:*}"; cid=""
        case "$ctx" in likes|playlist|track) cid="${START_ARG#*:}" ;; esac
        idx="$START_IDX"
        [ "$START_ORDER" = "shuffle" ] && idx=0    # shuffle 重启重洗, 位置无意义
        [ "$ctx" = "track" ] && idx=0              # 单曲重启从头
        # 启动时取不到列表 → 回落 spotify (此时无旧列表无从"连跳", 优雅降级同 netease 语义)
        start_soundcloud "$ctx" "$cid" "$START_ORDER" "$idx" || start_spotify
        ;;   # search: 同 netease — /run 缓存丢 → 取列表失败 → spotify
    bilibili)
        ctx="${START_ARG%%:*}"; cid=""
        case "$ctx" in video|fav|season) cid="${START_ARG#*:}" ;; esac
        idx="$START_IDX"
        [ "$START_ORDER" = "shuffle" ] && idx=0
        [ "$ctx" = "video" ] && idx=0
        start_bilibili "$ctx" "$cid" "$START_ORDER" "$idx" || start_spotify
        ;;
    youtube)
        ctx="${START_ARG%%:*}"; cid=""
        case "$ctx" in video|playlist) cid="${START_ARG#*:}" ;; esac
        idx="$START_IDX"
        [ "$START_ORDER" = "shuffle" ] && idx=0
        [ "$ctx" = "video" ] && idx=0
        start_youtube "$ctx" "$cid" "$START_ORDER" "$idx" || start_spotify
        ;;
    bandcamp)
        ctx="${START_ARG%%:*}"; cid=""
        case "$ctx" in track|album|artist|search) cid="${START_ARG#*:}" ;; esac
        idx="$START_IDX"
        [ "$START_ORDER" = "shuffle" ] && idx=0
        [ "$ctx" = "track" ] && idx=0
        start_bandcamp "$ctx" "$cid" "$START_ORDER" "$idx" || start_spotify
        ;;
esac

# 音源死亡判定: 自然播完 (rc=0) 与被杀/崩溃 (rc!=0) 分开处理
FAIL_COUNT=0
LAST_START=$(date +%s)

while true; do
    # 总线死 → 整链退出 (空闲 300s 被 MediaMTX 断开也走此路, 同旧设计)
    kill -0 "$BUS_PID" 2>/dev/null || exit 0

    # 音源退出 → folder 前进下一首; 其他回落 spotify
    if [ -n "$SRC_PID" ] && ! kill -0 "$SRC_PID" 2>/dev/null; then
        wait "$SRC_PID"; rc=$?
        SRC_PID=""
        touch "$GAP_FLAG" 2>/dev/null   # 静音垫: 自然播完/skip/崩溃的空窗也覆盖
        now=$(date +%s)
        if [ "$rc" -eq 0 ]; then
            # 自然播完: 无论时长都不算失败 (短曲目/jingle 合法)
            FAIL_COUNT=0
        elif [ "$SKIP_PENDING" = 1 ]; then
            # skip 杀的: 不计连败 (SKIP_PENDING 传递给 advance_* 以在 repeat 模式前进下一首)
            FAIL_COUNT=0
        elif [ $((now - LAST_START)) -lt 10 ]; then
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            FAIL_COUNT=0
        fi

        if [ "$SRC_NAME" = "folder" ]; then
            if [ "$FAIL_COUNT" -ge 3 ]; then
                # 连续 3 首 <10s 崩溃: 目录内容疑似损坏, 回落 spotify (不动总线, 听众无感)
                log "folder 连续 3 首曲目 <10s 崩溃, 目录内容疑似损坏, 回落 spotify"
                FAIL_COUNT=0
                LAST_START=$(date +%s)
                start_spotify
            else
                LAST_START=$(date +%s)
                advance_folder
            fi
        elif [ "$SRC_NAME" = "netease" ]; then
            # 快速失败 (典型: VIP 曲无权 exit 22; 也含下架/试听/CDN 拒) 不回落 spotify (2026-09-13 需求):
            # 一律前进下一首保持 netease; cookie 失效的表现从"连跳后回落"改为"无限连跳",
            # 每 10 连败打一条诊断日志 (journalctl 可见), 平时不刷屏
            if [ "$FAIL_COUNT" -gt 0 ] && [ $((FAIL_COUNT % 10)) -eq 0 ]; then
                log "netease 已连续 $FAIL_COUNT 首曲目 <10s 失败 (疑似 cookie 失效/接口异常/歌全 VIP), 继续跳歌保持 netease 音源"
            fi
            LAST_START=$(date +%s)
            advance_netease
        elif [ "$SRC_NAME" = "soundcloud" ]; then
            # 与 netease 2026-09-13 设计对称 (2026-09-15 用户决策): 曲目级快速失败
            # (典型: SNIP 试听/BLOCK exit 22) 与系统级 API 失败 (exit 23) 都不回落 spotify,
            # 一律前进保持 soundcloud。区别: helper 的 API 失败路径自带 sleep 15 (自限速),
            # 运行时长 ≥10s → FAIL_COUNT 归零, 每 10 连败日志不会触发 — 系统级失败由 helper
            # 每次一条 journal 自报 (radioctl soundcloud status / 面板徽章可查), 这里不再刷屏
            if [ "$FAIL_COUNT" -gt 0 ] && [ $((FAIL_COUNT % 10)) -eq 0 ]; then
                log "soundcloud 已连续 $FAIL_COUNT 首曲目 <10s 失败 (SNIP/BLOCK 密集), 继续跳歌保持 soundcloud 音源"
            fi
            LAST_START=$(date +%s)
            advance_soundcloud
        elif [ "$SRC_NAME" = "bilibili" ]; then
            if [ "$FAIL_COUNT" -gt 0 ] && [ $((FAIL_COUNT % 10)) -eq 0 ]; then
                log "bilibili 已连续 $FAIL_COUNT 首曲目 <10s 失败, 继续跳歌保持 bilibili 音源"
            fi
            LAST_START=$(date +%s)
            advance_bilibili
        elif [ "$SRC_NAME" = "youtube" ]; then
            if [ "$FAIL_COUNT" -gt 0 ] && [ $((FAIL_COUNT % 10)) -eq 0 ]; then
                log "youtube 已连续 $FAIL_COUNT 首曲目 <10s 失败, 继续跳歌保持 youtube 音源"
            fi
            LAST_START=$(date +%s)
            advance_youtube
        elif [ "$SRC_NAME" = "bandcamp" ]; then
            if [ "$FAIL_COUNT" -gt 0 ] && [ $((FAIL_COUNT % 10)) -eq 0 ]; then
                log "bandcamp 已连续 $FAIL_COUNT 首曲目 <10s 失败, 继续跳歌保持 bandcamp 音源"
            fi
            LAST_START=$(date +%s)
            advance_bandcamp
        else
            if [ "$FAIL_COUNT" -ge 3 ]; then
                log "音源连续快速失败 3 次, 整链退出交 systemd 重启"
                exit 0
            fi
            log "音源 '$SRC_NAME' 意外退出, 回落到 spotify"
            sleep 1
            LAST_START=$(date +%s)
            start_spotify
        fi
        SKIP_PENDING=0
    fi

    # 命令轮询, 0.3s 节拍 (缩短曲目切换检测延迟, 保证 FIFO 缓冲能盖住间隙)
    if [ "$HAVE_CMD" = 1 ]; then
        if IFS= read -r -t 0.3 -u 4 line; then
            CMD_NOTE=""; LOG_LAST=""
            if handle_cmd "$line"; then
                # 成功: 结果文本 = 本次命令触发的最后一条日志 (start_* 的 source=.. / [..] n/m: ..),
                # 无新日志 (skip 等) → 用内存变量附当前状态
                if [ -n "$LOG_LAST" ]; then
                    write_cmd_result OK "$LOG_LAST"
                else
                    write_cmd_result OK "已受理 ($SRC_NAME $((PLAY_IDX + 1))/${#PLAYLIST[@]}: ${SRC_FILE:-无})"
                fi
            else
                write_cmd_result FAIL "${CMD_NOTE:-$line}"
            fi
            LAST_START=$(date +%s)
        fi
    else
        sleep 0.3
    fi
done

# 说明:
# - 切换/切歌瞬间总线 ffmpeg 与听众的 RTSP/HLS/WebRTC 连接保持:
#   脚本自持 FIFO 写端 + 64KB FIFO 缓冲 (~0.7s) 吸收换曲间隙 → 听众无感
# - spotify 空闲 (没人放歌) 无 PCM → 300s 后 MediaMTX readTimeout 断开发布者 →
#   总线 ffmpeg 退出 → 整链退出 → systemd 重拉, 与原设计一致; 文件/文件夹音源持续出帧, 无此循环
# - folder 每轮结束重扫目录: 运行中 scp 新文件进来, 下一轮自动进 rotation
# - 音频 FIFO 在 PrivateTmp, 仅本服务命名空间内可见; 命令 FIFO 在共享 /run/radiod 供 radioctl 写
