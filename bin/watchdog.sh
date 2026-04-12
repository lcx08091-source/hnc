#!/system/bin/sh

# v3.5.0 alpha-0: PATH 健壮性,见 service.sh
[ -z "$HNC_SKIP_PATH_HARDENING" ] && [ -z "$HNC_TEST_MODE" ] && export PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
# watchdog.sh — 规则完整性守护
#
# 【v3.4.1 核心修复】
#  v3.4.0 用 `ip monitor link route` 监听 netlink 事件，每次有
#  网络事件就触发 full_restore（拆掉整个 tc 树重建）。但 ip monitor
#  对 ARP 状态变化（REACHABLE/STALE/DELAY）、v6 RA、移动数据路由更新、
#  VPN 状态变化都会触发，结果在真机上每 10 秒就 full_restore 一次，
#  每次重建有 100-500ms 的"无限速"窗口，TCP 在窗口里被打断。
#  真机日志显示一次会话产生 158 次 RESTORE。
#
#  v3.4.1 修复：
#   1. 完全删除 ip monitor 事件触发，只靠 60s 周期 health check
#   2. iface 检测加 5 分钟缓存，避免 wlan0/wlan2 跳变误触发 restore
#   3. INTERVAL_RECOVERY 从 10s 改为 30s，避免连续重建
#   4. full_restore 前先确认 iface 有效，避免在错误接口上跑 init_tc
#
# 功耗优化：
#  1. 周期检查：60s 一次（Doze 时 180s）
#  2. 健康检查缓存 5s，避免重复 iptables 调用
#  3. Doze 模式暂停主动检查

HNC_DIR=${HNC_DIR:-/data/local/hnc}
RULES_FILE=$HNC_DIR/data/rules.json
LOG=$HNC_DIR/logs/watchdog.log
RUN=$HNC_DIR/run

INTERVAL_NORMAL=60     # 规则正常时检查间隔
INTERVAL_RECOVERY=30   # v3.4.1：恢复后加密检查间隔（旧值 10s 太激进）
INTERVAL_DOZE=180      # Doze 模式

log() {
    [ -d "$(dirname "$LOG")" ] || mkdir -p "$(dirname "$LOG")" 2>/dev/null
    echo "[$(TZ=Asia/Shanghai date '+%H:%M:%S')] [WDG] $1" >> "$LOG" 2>/dev/null || true
}

# v3.4.1：iface 缓存。device_detect.sh iface 在 wlan0/wlan2 之间反复
# 横跳是 v3.4.0 watchdog 误触发 restore 的主要诱因。这里加 5 分钟缓存
# 完全屏蔽抖动。
IFACE_CACHE_TS=0
IFACE_CACHE_VAL=""
get_iface() {
    local now; now=$(date +%s)
    if [ -n "$IFACE_CACHE_VAL" ] && [ "$IFACE_CACHE_VAL" != "wlan0" ] \
       && [ $((now - IFACE_CACHE_TS)) -lt 300 ]; then
        echo "$IFACE_CACHE_VAL"
        return
    fi
    local v; v=$(sh "$HNC_DIR/bin/device_detect.sh" iface 2>/dev/null)
    # 只缓存有效结果（非空 + 非 wlan0）
    if [ -n "$v" ] && [ "$v" != "wlan0" ]; then
        IFACE_CACHE_VAL="$v"
        IFACE_CACHE_TS=$now
    fi
    echo "$v"
}

# ── 轻量健康检查（缓存 5s 结果）────────────────────────────
_HEALTH_TS=0
_HEALTH_RC=0
check_health() {
    local now=$(date +%s)
    [ $((now - _HEALTH_TS)) -lt 5 ] && return $_HEALTH_RC

    local rc=0
    local iface=$(get_iface)

    # 0. iface 必须有效
    [ -z "$iface" ] && rc=1

    # 1. TC 根 qdisc 是否为 HTB
    if [ $rc -eq 0 ]; then
        tc qdisc show dev "$iface" 2>/dev/null | grep -q "root.*htb" || rc=1
    fi

    # 2. iptables 链是否存在
    if [ $rc -eq 0 ]; then
        iptables -t mangle -L HNC_MARK --line-numbers 2>/dev/null | grep -q "." || rc=1
    fi

    # 3. CONNMARK 链是否就位
    if [ $rc -eq 0 ]; then
        iptables -t mangle -L HNC_RESTORE -n 2>/dev/null | grep -q "CONNMARK" || rc=1
    fi

    _HEALTH_TS=$now
    _HEALTH_RC=$rc
    return $rc
}

# ── 完整恢复 ─────────────────────────────────────────────────
full_restore() {
    local reason=$1
    log "RESTORE triggered: $reason"
    local iface=$(get_iface)
    if [ -z "$iface" ]; then
        log "RESTORE skipped: no valid iface"
        return 1
    fi

    sh "$HNC_DIR/bin/iptables_manager.sh" init >> "$LOG" 2>&1
    sh "$HNC_DIR/bin/tc_manager.sh" init "$iface" >> "$LOG" 2>&1
    sh "$HNC_DIR/bin/tc_manager.sh" restore >> "$LOG" 2>&1
    _HEALTH_TS=0
    _HEALTH_RC=1
    log "RESTORE complete"
}

# ── 子服务存活检查 ──────────────────────────────────────────
# v3.5.0 P2-4: 防重启风暴 — 60 秒内同一服务最多重启 1 次
# 之前如果 hotspotd 启动后立刻 crash,会被无限重启,日志疯涨
# v3.5.0 P1-2:hotspotd 启动参数从 --daemon 改成 -d(hotspotd 实际只识别 -d)
HOTSPOTD_LAST_RESTART=0
DETECT_LAST_RESTART=0
RESTART_COOLDOWN=60  # 秒

check_services() {
    local restarted=0
    local now; now=$(date +%s 2>/dev/null) || now=0

    # hotspotd C daemon
    local hpid; hpid=$(cat "$RUN/hotspotd.pid" 2>/dev/null)
    if [ -n "$hpid" ] && ! kill -0 "$hpid" 2>/dev/null; then
        if [ -x "$HNC_DIR/bin/hotspotd" ]; then
            local since=$((now - HOTSPOTD_LAST_RESTART))
            if [ $since -lt $RESTART_COOLDOWN ]; then
                log "hotspotd dead but in cooldown (${since}s < ${RESTART_COOLDOWN}s),skip"
            else
                log "hotspotd dead, restarting (last=${HOTSPOTD_LAST_RESTART})..."
                # v3.5.1 P1-7 修复:不再 echo $! > pid 文件,因为 hotspotd -d 会
                # double-fork 后台化,$! 是 shell 子进程 PID,不是真 hotspotd PID。
                # hotspotd 自己会 write_pid() 写真 PID 到 /data/local/hnc/run/hotspotd.pid。
                # 之前两个写法竞争同一文件,可能存的是错的 PID,导致下次 kill -0 失败,
                # 触发重启风暴(虽然有 60s cooldown 兜底,但根本上不该有这个 race)。
                "$HNC_DIR/bin/hotspotd" -d >> "$HNC_DIR/logs/hotspotd.log" 2>&1 &
                # 等 hotspotd 自己写 PID 文件(通常 < 100ms)
                sleep 1
                HOTSPOTD_LAST_RESTART=$now
                restarted=1
            fi
        fi
    fi

    # device_detect shell daemon (fallback)
    local det_pid; det_pid=$(cat "$RUN/detect.pid" 2>/dev/null)
    if [ -n "$det_pid" ] && ! kill -0 "$det_pid" 2>/dev/null; then
        local since=$((now - DETECT_LAST_RESTART))
        if [ $since -lt $RESTART_COOLDOWN ]; then
            log "Detector dead but in cooldown (${since}s),skip"
        else
            log "Detector dead, restarting..."
            sh "$HNC_DIR/bin/device_detect.sh" daemon >> "$HNC_DIR/logs/detect.log" 2>&1 &
            echo $! > "$RUN/detect.pid"
            DETECT_LAST_RESTART=$now
            restarted=1
        fi
    fi

    return $restarted
}

# ── Doze 检测 ────────────────────────────────────────────────
is_doze() {
    cmd power get-idle-mode 2>/dev/null | grep -qiE "^(deep|light)$" && return 0
    local lvl
    lvl=$(dumpsys battery 2>/dev/null | awk '/^[[:space:]]*level:/{print $2; exit}')
    [ -n "$lvl" ] && [ "$lvl" -lt 5 ] 2>/dev/null && return 0
    return 1
}

# ── 主循环 ───────────────────────────────────────────────────
log "=== Watchdog v3.4.1 started (PID=$$) ==="
echo $$ > "$RUN/watchdog.pid"

# v3.4.1：彻底删除 ip monitor 事件监听
# （旧代码 start_event_listener / check_network_event 已移除）

RESTORE_COUNT=0
INTERVAL=$INTERVAL_NORMAL
RECOVERY_ROUNDS=0
SERVICE_CHECK_ROUND=0
LAST_V6_SYNC=0

while true; do
    sleep $INTERVAL

    # Doze 模式：降频并跳过主动检查
    if is_doze; then
        INTERVAL=$INTERVAL_DOZE
        continue
    fi

    # v3.4.1：只靠 health check 触发 restore，不再监听网络事件
    if ! check_health; then
        RESTORE_COUNT=$((RESTORE_COUNT+1))
        full_restore "health_fail (total=$RESTORE_COUNT)"
        INTERVAL=$INTERVAL_RECOVERY
        RECOVERY_ROUNDS=3
    else
        if [ "$RECOVERY_ROUNDS" -gt 0 ]; then
            RECOVERY_ROUNDS=$((RECOVERY_ROUNDS-1))
            [ "$RECOVERY_ROUNDS" -eq 0 ] && INTERVAL=$INTERVAL_NORMAL
        else
            INTERVAL=$INTERVAL_NORMAL
        fi
    fi

    # v6 地址同步（每 60s 一次，比 v3.4.0 的 30s 更保守）
    NOW=$(date +%s)
    if [ $((NOW - LAST_V6_SYNC)) -ge 60 ]; then
        sh "$HNC_DIR/bin/v6_sync.sh" sync >> "$LOG" 2>&1 || true
        LAST_V6_SYNC=$NOW
    fi

    # 子服务存活检查（每 3 轮一次）
    SERVICE_CHECK_ROUND=$((SERVICE_CHECK_ROUND + 1))
    if [ "$((SERVICE_CHECK_ROUND % 3))" -eq 0 ]; then
        check_services
        SERVICE_CHECK_ROUND=0
    fi

done
