#!/system/bin/sh
# service.sh — Magisk late_start service
# 在系统完全启动后执行,可访问所有系统服务

# v3.5.0 alpha-0:PATH 健壮性
# 强制使用系统 PATH,排除 user app(MT 管理器/termux 等)对 awk/sed/grep/tc 的劫持
# 之前的隐患:如果 user 在 root shell 中调用 service.sh,继承的 PATH 可能含 user app 路径,
# 导致 HNC 用错版本的命令(行为可能跟系统 toybox 不一致)
[ -z "$HNC_SKIP_PATH_HARDENING" ] && [ -z "$HNC_TEST_MODE" ] && export PATH=/system/bin:/system/xbin:/vendor/bin:$PATH

MODDIR=${0%/*}
HNC_DIR=/data/local/hnc
LOG=$HNC_DIR/logs/service.log
RUN=$HNC_DIR/run

mkdir -p $HNC_DIR/logs $RUN

# ── 退出时自动清理（模块卸载/系统关机）──────────────────────
cleanup_on_exit() {
    sh $HNC_DIR/bin/cleanup.sh 2>/dev/null
}
trap cleanup_on_exit TERM INT

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [HNC] $1" >> $LOG
}

log "=== HNC Service Starting ==="
log "Android $(getprop ro.build.version.release) / $(getprop ro.product.brand) $(getprop ro.product.model)"

# 等待系统网络服务就绪
wait_for_network() {
    local max=60
    local cnt=0
    while [ $cnt -lt $max ]; do
        # 检查 wlan0 或热点接口
        if ip link show 2>/dev/null | grep -qE 'wlan|ap0|swlan'; then
            log "Network interface ready"
            return 0
        fi
        sleep 2
        cnt=$((cnt+2))
    done
    log "WARN: Network wait timeout, continuing anyway"
    return 1
}

# 等待 bootcomplete
wait_boot_complete() {
    local cnt=0
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ $cnt -lt 120 ]; do
        sleep 2
        cnt=$((cnt+2))
    done
    log "Boot completed at ${cnt}s"
}

wait_boot_complete
wait_for_network

# ─── 检测热点接口（委托给 device_detect.sh，与 watchdog/detect 保持一致）────
# device_detect.sh 的 get_hotspot_iface() 要求接口已分配 IP，
# 启动初期若接口尚无 IP 则回退到候选列表扫描，行为与原逻辑相同。
detect_hotspot_iface() {
    local iface
    # 优先通过 device_detect.sh（与 watchdog/ARP 逻辑统一）
    if [ -x "$HNC_DIR/bin/device_detect.sh" ]; then
        iface=$(sh "$HNC_DIR/bin/device_detect.sh" iface 2>/dev/null)
        [ -n "$iface" ] && echo "$iface" && return
    fi
    # 回退：仅检测接口存在性（启动早期接口可能还没 IP）
    for iface in ap0 wlan1 swlan0 rndis0 usb0; do
        ip link show "$iface" >/dev/null 2>&1 && echo "$iface" && return
    done
    for iface in $(ls /sys/class/net/ 2>/dev/null); do
        local type; type=$(cat /sys/class/net/$iface/type 2>/dev/null)
        [ "$type" = "1" ] && echo "$iface" | grep -qE '^(ap|swlan|wlan[1-9])'             && echo "$iface" && return
    done
    echo "wlan0"
}

HOTSPOT_IFACE=$(detect_hotspot_iface)
log "Detected hotspot interface: $HOTSPOT_IFACE"

# 写入检测到的接口
# v3.4.11 P1-10 修复:之前的 jq + /tmp + sed fallback 链全是死代码:
#   - jq 在 Android 没装(busybox 不包含)
#   - /tmp 在 Android 不存在(应该用 /data/local/tmp)
#   - sed fallback 只匹配 "auto" 字面量,首次启动后接口名变化永不更新
#   - && ... || 在 ash 里不是 if-then-else,jq 成功 mv 失败时 sed 也跑
# 改用已有的 json_set.sh cfg_set,统一文件锁,统一错误处理
sh "$HNC_DIR/bin/json_set.sh" cfg_set hotspot_iface "$HOTSPOT_IFACE" 2>/dev/null || true

# ─── 启动 iptables 初始化 ────────────────────────────────────
log "Initializing iptables chains..."
sh $HNC_DIR/bin/iptables_manager.sh init >> $LOG 2>&1

# ─── 启动 TC 初始化 ──────────────────────────────────────────
log "Initializing TC qdisc on $HOTSPOT_IFACE..."
sh $HNC_DIR/bin/tc_manager.sh init $HOTSPOT_IFACE >> $LOG 2>&1

# ─── 恢复持久化规则 ──────────────────────────────────────────
log "Restoring persisted rules..."
sh $HNC_DIR/bin/tc_manager.sh restore >> $LOG 2>&1

# ─── v3.4.0：v6 地址首次同步 ─────────────────────────────────
# restore 已经把 iptables HNC_MARK 重建好，v6_sync 从 HNC_MARK
# 反推哪些设备有限速，给每个 v6 地址加 tc u32 filter
log "Initial v6 address sync..."
sh $HNC_DIR/bin/v6_sync.sh sync >> $LOG 2>&1

# ─── 启动 API 服务器 ─────────────────────────────────────────
API_PORT=$(grep -o '"api_port":[^,}]*' $HNC_DIR/data/config.json | grep -o '[0-9]*')
API_PORT=${API_PORT:-8080}

# ─── 启动 API 服务器 ─────────────────────────────────────────
# v3.4.11 P1-11 安全修复:停止默认启动 api/server.sh
#
# 原因:
#   1) KSU WebView 用 window.ksu.exec() 直接 fork shell,完全不走 HTTP API
#   2) api/server.sh 在 0.0.0.0:8080 监听,对热点上所有客户端开放
#   3) 0 认证 + 0 IP 限制 + POST body 字段无格式验证
#   4) handle_post_limit 把 mac/ip 直接拼到 sh ... mark "$ip" "$mac" 命令里
#      → 任何连热点的设备发 {"mac":"a\";rm -rf /;\""} 就能 RCE 你的手机
#   5) "封锁中"的设备依然能打 8080 端口(封锁规则在 mark 之后)
#
# api/server.sh 源码留在仓库里,如有需要手动启动:
#   sh /data/local/hnc/api/server.sh 8080 &
#
# log "Starting API server on port $API_PORT..."
# sh $HNC_DIR/api/server.sh $API_PORT >> $HNC_DIR/logs/api.log 2>&1 &
# echo $! > $RUN/api.pid
# log "API server PID: $(cat $RUN/api.pid)"
log "API server (api/server.sh) disabled for security (v3.4.11 P1-11)"

# ─── 启动设备检测守护进程（v3.0.0：优先 C daemon hotspotd）─
# device_detect.sh daemon 内部会优先尝试启动 hotspotd(C)；
# 若二进制不存在则自动回落到原 shell 轮询（向下兼容）
#
# v3.5.2 P0-A 修复:detect.pid 和 hotspotd.pid 不再存同一个 PID。
# - C daemon 成功接管时,只有 hotspotd.pid 有值,detect.pid 不写
# - shell fallback 时,只有 detect.pid 有值(device_detect.sh 自己写)
# - watchdog 优先检查 hotspotd.pid,存在时跳过 detect.pid 检查
# 根本原因:之前两个 pid 指同一 PID,hotspotd 崩掉后 watchdog 两个
# if 都触发重启,导致 hotspotd C daemon 和 shell fallback 同时运行,
# 并发写 devices.json.tmp → JSON 损坏(review P0-A)
log "Starting device detector (C daemon preferred)..."
sh $HNC_DIR/bin/device_detect.sh daemon >> $HNC_DIR/logs/detect.log 2>&1 &
DETECT_SHELL_PID=$!
sleep 2
# 检查 C daemon 是否接管了（hotspotd.pid 存在且进程活着）
HPID=$(cat $RUN/hotspotd.pid 2>/dev/null)
if [ -n "$HPID" ] && kill -0 "$HPID" 2>/dev/null; then
    log "C daemon hotspotd running (PID=$HPID)"
    # v3.5.2 P0-A:不再 echo $HPID > detect.pid。
    # C daemon 模式下 detect.pid 应当不存在,让 watchdog 看到"没 detect 需要照料"
    rm -f "$RUN/detect.pid" 2>/dev/null
else
    # shell fallback 在 daemon_shell_fallback 里自己写了 detect.pid
    log "Shell daemon fallback running (PID=$DETECT_SHELL_PID)"
fi

# ─── 启动 Watchdog ──────────────────────────────────────────
log "Starting watchdog..."
sh $HNC_DIR/bin/watchdog.sh >> $HNC_DIR/logs/watchdog.log 2>&1 &
echo $! > $RUN/watchdog.pid

log "=== All services started ==="
log "WebUI available at: http://$(ip addr show $HOTSPOT_IFACE 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1):$API_PORT"
log "Or access via: http://192.168.43.1:$API_PORT (default hotspot gateway)"

# ─── 热点自动启动 ────────────────────────────────────────────
# 读取 rules.json 里的 hotspot_auto 字段（WebUI 控制）
HOTSPOT_AUTO=$(grep -o '"hotspot_auto"[[:space:]]*:[[:space:]]*[a-z]*' \
    $HNC_DIR/data/rules.json 2>/dev/null | awk -F: '{print $2}' | tr -d ' ')

if [ "$HOTSPOT_AUTO" = "true" ]; then
    log "hotspot_auto=true, launching hotspot_autostart.sh in background..."
    # 延迟 5 秒再启动，确保其他网络服务就绪
    (sleep 5 && sh $HNC_DIR/bin/hotspot_autostart.sh start) \
        >> $HNC_DIR/logs/hotspot.log 2>&1 &
    echo $! > $RUN/hotspot.pid
    log "Hotspot autostart scheduled (PID: $(cat $RUN/hotspot.pid))"
else
    log "hotspot_auto=false, skipping autostart"
fi
