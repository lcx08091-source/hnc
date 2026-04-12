#!/system/bin/sh

# v3.5.0 alpha-0: PATH 健壮性,见 service.sh
[ -z "$HNC_SKIP_PATH_HARDENING" ] && [ -z "$HNC_TEST_MODE" ] && export PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
# cleanup.sh — HNC 资源完全释放
# 在模块禁用/卸载/手动调用时执行，确保无残留进程和规则

HNC_DIR=${HNC_DIR:-/data/local/hnc}
RUN=$HNC_DIR/run
LOG=$HNC_DIR/logs/service.log

log() { echo "[$(TZ=Asia/Shanghai date '+%H:%M:%S')] [CLEANUP] $1" >> $LOG; }

log "=== Cleanup started ==="

# ── 1. 停止所有 HNC 进程 ─────────────────────────────────────
# 也清理 C daemon hotspotd
for pidfile in hotspotd watchdog detect api hotspot netmon; do
    PID=$(cat "$RUN/${pidfile}.pid" 2>/dev/null)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null
        log "Killed $pidfile (PID=$PID)"
    fi
    rm -f "$RUN/${pidfile}.pid"
done

# 确保相关进程名也被清理
for proc in device_detect watchdog server.sh hotspot_autostart; do
    pkill -f "$proc" 2>/dev/null && log "pkill $proc"
done

sleep 1

# ── 2. 清除 TC 规则 ──────────────────────────────────────────
IFACE=$(sh "$HNC_DIR/bin/device_detect.sh" iface 2>/dev/null || echo wlan2)
log "Cleaning TC on $IFACE and ifb0..."
tc qdisc del dev "$IFACE" root 2>/dev/null
tc qdisc del dev "$IFACE" ingress 2>/dev/null
tc qdisc del dev ifb0 root 2>/dev/null
ip link set ifb0 down 2>/dev/null
ip link del ifb0 2>/dev/null
log "TC cleanup done"

# ── 3. 清除 iptables 规则 ────────────────────────────────────
# v3.3.4：双栈清理 v4 + v6 所有 HNC 链
log "Cleaning iptables chains (v4+v6)..."
for table_chain in "mangle PREROUTING  HNC_RESTORE" \
                   "mangle FORWARD     HNC_MARK"    \
                   "mangle FORWARD     HNC_STATS"   \
                   "mangle POSTROUTING HNC_SAVE"    \
                   "filter FORWARD     HNC_CTRL"    \
                   "filter FORWARD     HNC_WHITELIST"; do
    t=$(echo $table_chain | awk '{print $1}')
    c=$(echo $table_chain | awk '{print $2}')
    h=$(echo $table_chain | awk '{print $3}')
    iptables -t $t -D $c -j $h 2>/dev/null
    iptables -t $t -F $h 2>/dev/null
    iptables -t $t -X $h 2>/dev/null
done

# v6 清理（v3.3.4 新增：完整清理 v6 所有链，不再只清 HNC_MARK）
if command -v ip6tables >/dev/null 2>&1; then
    for table_chain in "mangle PREROUTING  HNC_RESTORE" \
                       "mangle FORWARD     HNC_MARK"    \
                       "mangle POSTROUTING HNC_SAVE"    \
                       "filter FORWARD     HNC_CTRL"    \
                       "filter FORWARD     HNC_WHITELIST"; do
        t=$(echo $table_chain | awk '{print $1}')
        c=$(echo $table_chain | awk '{print $2}')
        h=$(echo $table_chain | awk '{print $3}')
        ip6tables -t $t -D $c -j $h 2>/dev/null
        ip6tables -t $t -F $h 2>/dev/null
        ip6tables -t $t -X $h 2>/dev/null
    done
fi
log "iptables cleanup done"

# ── 4. 清理临时文件（保留 data/ 目录，用户配置不删）────────
rm -f "$RUN"/*.pid "$RUN"/netevt_* "$RUN"/arp_hash "$RUN"/hotspotd.sock 2>/dev/null
rm -f "$HNC_DIR/run/hostname_cache" 2>/dev/null  # 缓存可以删
rm -rf "$HNC_DIR/run/v6" 2>/dev/null              # v3.4.0：v6_sync 快照目录
# v3.5.0 P2-5: 清理 device_detect.sh 留下的临时文件(进程异常退出后残留)
rm -f "$RUN"/scan_tmp.* "$RUN"/scan_arp.* "$RUN"/.gc_* "$RUN"/.lock_check_* 2>/dev/null
rm -rf "$RUN/json.lock" 2>/dev/null               # P0-2 锁残留

log "=== Cleanup complete ==="
echo "HNC: all resources released"
