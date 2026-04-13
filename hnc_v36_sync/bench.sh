#!/system/bin/sh
# bench.sh — HNC v3.5.0-beta1 真机性能 benchmark
#
# 对比:
#   1. shell daemon (device_detect.sh daemon) 的扫描延迟
#   2. hotspotd C daemon 的事件响应延迟(beta2 才默认启用,beta1 可手动)
#
# 测的指标:
#   - 单次扫描的 wall-clock 时间
#   - 启动到第一次写 devices.json 的延迟
#   - CPU usage(粗略,通过 /proc/$pid/stat)
#   - 内存 RSS
#   - devices.json 写入频率
#
# 用法:
#   sh bench.sh                # 跑全部
#   sh bench.sh shell          # 只跑 shell daemon 测试
#   sh bench.sh hotspotd       # 只跑 hotspotd 测试(需要 hotspotd binary 存在)
#   sh bench.sh compare        # 同时跑两个,输出对比表
#
# 输出:
#   /data/local/hnc/logs/bench-<timestamp>.log
#   stdout 同步打印 summary

HNC_DIR="${HNC_DIR:-/data/local/hnc}"
RESULTS_DIR="$HNC_DIR/logs"
TS=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo "now")
RESULT_FILE="$RESULTS_DIR/bench-$TS.log"

mkdir -p "$RESULTS_DIR"

log() {
    echo "[$(date '+%H:%M:%S' 2>/dev/null)] $*" | tee -a "$RESULT_FILE"
}

# ─── 1. 单次扫描 wall-clock 时间 ──────────────
bench_single_scan() {
    local impl="$1"  # shell | hotspotd
    log ""
    log "── [$impl] 单次扫描 wall-clock 时间 ──"

    local total_ms=0
    local n=5
    local i=1
    while [ $i -le $n ]; do
        local t0; t0=$(date +%s%N 2>/dev/null)
        if [ "$impl" = "shell" ]; then
            sh "$HNC_DIR/bin/device_detect.sh" scan >/dev/null 2>&1
        else
            # hotspotd 通过 SIGUSR1 触发扫描
            local pid; pid=$(cat "$HNC_DIR/run/hotspotd.pid" 2>/dev/null)
            [ -z "$pid" ] && { log "  hotspotd 未运行"; return 1; }
            kill -USR1 "$pid" 2>/dev/null
            # 等 devices.json 的 mtime 变化
            local before; before=$(stat -c %Y "$HNC_DIR/data/devices.json" 2>/dev/null || echo 0)
            local waited=0
            while [ $waited -lt 30 ]; do  # 最多等 3 秒
                local now; now=$(stat -c %Y "$HNC_DIR/data/devices.json" 2>/dev/null || echo 0)
                [ "$now" != "$before" ] && break
                sleep 0.1 2>/dev/null || usleep 100000 2>/dev/null
                waited=$((waited + 1))
            done
        fi
        local t1; t1=$(date +%s%N 2>/dev/null)
        # 纳秒差 → 毫秒
        local diff_ms=$(( (t1 - t0) / 1000000 ))
        total_ms=$((total_ms + diff_ms))
        log "  run $i: ${diff_ms}ms"
        i=$((i + 1))
    done

    local avg=$((total_ms / n))
    log "  ──────────"
    log "  平均: ${avg}ms (n=$n)"
    echo "$avg"
}

# ─── 2. CPU 使用率(粗略)─────────────────────
bench_cpu_usage() {
    local impl="$1"
    log ""
    log "── [$impl] CPU 使用率(60s 窗口)──"

    local pidfile
    if [ "$impl" = "shell" ]; then
        pidfile="$HNC_DIR/run/detect.pid"
    else
        pidfile="$HNC_DIR/run/hotspotd.pid"
    fi
    local pid; pid=$(cat "$pidfile" 2>/dev/null)
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        log "  $impl 未运行(pidfile=$pidfile)"
        return 1
    fi

    log "  pid=$pid"
    # 读 /proc/$pid/stat 第 14, 15 字段(utime+stime,单位 jiffies)
    local stat0 stat1
    stat0=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null)
    [ -z "$stat0" ] && { log "  无法读 /proc/$pid/stat"; return 1; }

    log "  采样 60 秒..."
    sleep 60
    stat1=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null)
    [ -z "$stat1" ] && { log "  采样后进程消失"; return 1; }

    local jiffies=$((stat1 - stat0))
    local hz=100  # Linux 默认
    local cpu_seconds=$((jiffies / hz))
    log "  CPU 时间: ${cpu_seconds}s / 60s = $((cpu_seconds * 100 / 60))%"
}

# ─── 3. 内存 RSS ────────────────────────────
bench_memory() {
    local impl="$1"
    log ""
    log "── [$impl] 内存 RSS ──"

    local pidfile
    if [ "$impl" = "shell" ]; then
        pidfile="$HNC_DIR/run/detect.pid"
    else
        pidfile="$HNC_DIR/run/hotspotd.pid"
    fi
    local pid; pid=$(cat "$pidfile" 2>/dev/null)
    [ -z "$pid" ] && { log "  $impl 未运行"; return 1; }

    local rss_kb
    rss_kb=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null)
    if [ -z "$rss_kb" ]; then
        log "  无法读 /proc/$pid/status"
        return 1
    fi
    log "  RSS: ${rss_kb} KB"
}

# ─── 4. devices.json 写入频率 ────────────────
bench_write_frequency() {
    local impl="$1"
    log ""
    log "── [$impl] devices.json 写入频率(60s 窗口)──"

    local devices="$HNC_DIR/data/devices.json"
    [ ! -f "$devices" ] && { log "  devices.json 不存在"; return 1; }

    local before; before=$(stat -c %Y "$devices" 2>/dev/null)
    log "  采样 60 秒..."
    sleep 60
    local after; after=$(stat -c %Y "$devices" 2>/dev/null)

    if [ "$before" = "$after" ]; then
        log "  ⚠ devices.json 60 秒内没更新(可能没设备活动)"
    else
        log "  最后更新时间变化: $before → $after"
    fi
}

# ─── 主流程 ──────────────────────────────────
MODE="${1:-compare}"

log "════════════════════════════════════════"
log "  HNC v3.5.0-beta1 真机 benchmark"
log "  时间: $(date 2>/dev/null)"
log "  设备: $(getprop ro.product.brand 2>/dev/null) $(getprop ro.product.model 2>/dev/null)"
log "  Android: $(getprop ro.build.version.release 2>/dev/null)"
log "  Kernel: $(uname -r 2>/dev/null)"
log "  Mode: $MODE"
log "════════════════════════════════════════"

case "$MODE" in
    shell)
        bench_single_scan shell
        bench_cpu_usage shell
        bench_memory shell
        bench_write_frequency shell
        ;;
    hotspotd)
        if [ ! -x "$HNC_DIR/bin/hotspotd" ]; then
            log "✗ hotspotd binary 不存在,跳过"
            exit 1
        fi
        bench_single_scan hotspotd
        bench_cpu_usage hotspotd
        bench_memory hotspotd
        bench_write_frequency hotspotd
        ;;
    compare)
        log ""
        log "──────────── Shell daemon ────────────"
        SHELL_AVG=$(bench_single_scan shell)
        bench_memory shell

        if [ -x "$HNC_DIR/bin/hotspotd" ]; then
            log ""
            log "──────────── hotspotd ────────────"
            HOTSPOTD_AVG=$(bench_single_scan hotspotd)
            bench_memory hotspotd

            log ""
            log "════════════════════════════════════════"
            log "  对比结果"
            log "════════════════════════════════════════"
            log "  Shell daemon 平均扫描:    ${SHELL_AVG}ms"
            log "  hotspotd C daemon 平均:   ${HOTSPOTD_AVG}ms"
            if [ "$HOTSPOTD_AVG" -gt 0 ] 2>/dev/null; then
                log "  加速比: $((SHELL_AVG / HOTSPOTD_AVG))x"
            fi
        else
            log ""
            log "  hotspotd binary 不存在,跳过 C daemon 对比"
            log "  等 v3.5.0-beta1 通过 GitHub Actions CI build 后可启用"
        fi
        ;;
    *)
        echo "用法: sh bench.sh [shell|hotspotd|compare]"
        exit 1
        ;;
esac

log ""
log "完整日志: $RESULT_FILE"
