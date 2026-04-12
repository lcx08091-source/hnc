#!/system/bin/sh

# v3.5.0 alpha-0: PATH 健壮性,见 service.sh
[ -z "$HNC_SKIP_PATH_HARDENING" ] && [ -z "$HNC_TEST_MODE" ] && export PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
# device_detect.sh — HNC 设备检测（C daemon 代理 + shell 兜底）
#
# 【增量重构 v2.5.4 → v3.0.0】
# ✅ 保留全部对外接口：scan | daemon | list | iface | status
# 🔄 scan:   SIGUSR1 → C daemon → shell ARP fallback
# 🔄 daemon: 启动 hotspotd(C) → 失败则 shell 轮询 fallback
# 🔄 list:   socket GET_DEVICES → cat 文件 fallback
# ✅ iface:  完全不变
# 输出格式与原 shell 版本 100% 兼容
#
# ════════════════════════════════════════════════════════════════════
# ⚠️ v3.4.11 LTS 重要警告:hotspotd C daemon 不要启用
# ════════════════════════════════════════════════════════════════════
# 本脚本设计上支持 hotspotd C daemon 接管扫描(netlink 事件驱动,
# 实时性比 shell 轮询好),但 hotspotd 在 LTS 阶段是【实验性未完成】功能:
#
#   1. hotspotd 二进制【不在 zip 包里】(只有 daemon/hotspotd.c 源码)
#   2. hotspotd write_json 不调 mDNS / 不读 device_names.json /
#      不写 hostname_src 字段 → 启用后所有"手动命名"和"mDNS 自动识别"
#      功能立刻失效(P0-4)
#   3. watchdog 用 --daemon 参数重启它会失败(hotspotd 只识别 -d) → P1-2
#   4. 多设备时 fgets(256) 截断会导致黑名单识别失效 → P1-7
#   5. 没有任何真机长时间测试记录
#
# 如果你出于好奇或想推动 v3.5+ 开发去手动编译了 hotspotd 并放到
# /data/local/hnc/bin/hotspotd,你会立刻撞 4 个 P0/P1 bug。
#
# 当前默认状态:hotspotd 二进制不存在 → hotspotd_alive 永远 false
# → 自动 fall back 到 shell daemon → 100% 功能正常 → 已实测稳定
#
# 如需 v3.5+ 真正启用 hotspotd,需要先修 P0-4 / P1-2 / P1-7 / P1-8
# 并完成真机长时间测试。LTS 期不动 hotspotd 路径。
# ════════════════════════════════════════════════════════════════════

HNC_DIR=${HNC_DIR:-/data/local/hnc}
DEVICES_FILE=$HNC_DIR/data/devices.json
RULES_FILE=$HNC_DIR/data/rules.json
LOG=$HNC_DIR/logs/detect.log
HOTSPOTD_BIN=$HNC_DIR/bin/hotspotd
HOTSPOTD_PID=$HNC_DIR/run/hotspotd.pid
HOTSPOTD_SOCK=$HNC_DIR/run/hotspotd.sock
CACHE_FILE=$HNC_DIR/run/hostname_cache

log() {
    [ -d "$(dirname "$LOG")" ] || mkdir -p "$(dirname "$LOG")" 2>/dev/null
    echo "[$(TZ=Asia/Shanghai date '+%H:%M:%S')] [DETECT] $1" >> "$LOG" 2>/dev/null || true
}

# C daemon 是否在线
hotspotd_alive() {
    local pid
    pid=$(cat "$HOTSPOTD_PID" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# UNIX socket 查询
socket_query() {
    local cmd=$1
    if command -v socat >/dev/null 2>&1; then
        echo "$cmd" | socat -t 2 - UNIX-CONNECT:"$HOTSPOTD_SOCK" 2>/dev/null
    elif command -v nc >/dev/null 2>&1; then
        echo "$cmd" | nc -U "$HOTSPOTD_SOCK" 2>/dev/null
    else
        cat "$DEVICES_FILE" 2>/dev/null
    fi
}

# ── 热点接口检测 ─────────────────────────────────────────────
# v3.4.1 修复：之前优先用 /proc/net/arp，但当热点没开 / 没设备连接时
# ARP 表为空，会降级遍历 /sys/class/net/ 匹配到手机本机 WiFi 接口
# wlan0（不是热点！），导致 HNC 在错误的接口上跑 init_tc 污染本机网络。
#
# 新方案：优先读 Android tetherctrl_FORWARD iptables 链。Android tethering
# 服务会自动维护这个链，包含 `-i <hotspot_iface> -o <upstream_iface> -j ACCEPT`
# 这样的规则。第一个 in 接口就是当前热点接口，这是绝对准确的。
# tetherctrl 链不存在或为空时再降级到旧的 ARP / 接口扫描方法。
get_hotspot_iface() {
    # 方法 1：tetherctrl iptables 链（最准确，只要热点开着就有）
    # 必须用 -v 才有接口列。awk 字段：$3=target $6=in_iface $7=out_iface
    local tc_iface
    tc_iface=$(iptables -t filter -L tetherctrl_FORWARD -n -v 2>/dev/null \
        | awk '$3 == "ACCEPT" && $6 != "*" && $6 !~ /^(lo|rmnet|dummy|v4-|tun|p2p)/ { print $6; exit }')
    [ -n "$tc_iface" ] && echo "$tc_iface" && return

    # 方法 2：ARP 表（热点开但 tetherctrl 链不存在的旧设备）
    local arp_iface
    arp_iface=$(awk '
        NR>1 && $3!="0x0" && $6!~/^(lo|rmnet|dummy|v4-|tun|p2p|wlan0$)/ {cnt[$6]++}
        END {for(k in cnt) print cnt[k], k}
    ' /proc/net/arp 2>/dev/null | sort -rn | awk '{print $2}' | head -1)
    [ -n "$arp_iface" ] && echo "$arp_iface" && return

    # 方法 3：常见接口名扫描（不含 wlan0，避免命中本机 WiFi）
    for iface in ap0 wlan1 wlan2 wlan3 wlan4 swlan0 swlan1 rndis0 usb0; do
        ip addr show "$iface" 2>/dev/null | grep -q 'inet ' && echo "$iface" && return
    done

    # 方法 4：兜底扫 /sys/class/net/，但严格排除 wlan0
    for iface in $(ls /sys/class/net/ 2>/dev/null | grep -E '^(wlan[1-9]|ap[0-9]|swlan)'); do
        ip addr show "$iface" 2>/dev/null | grep -q 'inet ' && echo "$iface" && return
    done

    # 真的什么都找不到时返回空，让上层处理
    # （v3.4.1：不再返回 wlan0 兜底，因为 wlan0 是本机 WiFi 不是热点）
    return 1
}

# ── scan via C daemon (SIGUSR1) ─────────────────────────────
do_scan_via_daemon() {
    local pid
    pid=$(cat "$HOTSPOTD_PID" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
    kill -USR1 "$pid" 2>/dev/null
    sleep 1
    local cnt
    cnt=$(awk 'BEGIN{n=0} /"mac"/{n++} END{print n}' "$DEVICES_FILE" 2>/dev/null || echo 0)
    log "scan via SIGUSR1: ${cnt} device(s)"
    echo "$cnt"
    return 0
}

# ── hostname 缓存 (TTL=600s) ────────────────────────────────
hostname_cached() {
    local mac=$1 now
    now=$(date +%s)
    [ -f "$CACHE_FILE" ] || return 1
    # Fix #6: cache uses '|' delimiter, must specify -F'|'
    awk -F'|' -v mac="$mac" -v now="$now" '
        $1==mac && (now-$3)<600 { print $2; found=1; exit }
        END { if(!found) exit 1 }
    ' "$CACHE_FILE" 2>/dev/null
}

hostname_cache_set() {
    local mac=$1 name=$2 now
    now=$(date +%s)
    [ -z "$name" ] && return
    mkdir -p "$(dirname "$CACHE_FILE")"
    if [ -f "$CACHE_FILE" ]; then
        grep -v "^$mac|" "$CACHE_FILE" > ${CACHE_FILE}.tmp 2>/dev/null || true
        echo "$mac|$name|$now" >> ${CACHE_FILE}.tmp
        mv ${CACHE_FILE}.tmp "$CACHE_FILE"
    else
        echo "$mac|$name|$now" > "$CACHE_FILE"
    fi
}

# v3.4.11 兼容 #2: 探测 mdns_resolve 是否能在当前 CPU 架构上跑
# bin/mdns_resolve 只编译了 aarch64,armv7/x86_64 设备执行会 "exec format error"
# 用 -h 跑一次(立刻 exit,不发任何 UDP 包),exit code 0 = 能跑,非 0 = 架构不兼容
# 结果缓存到 $HNC_DIR/run/.mdns_ok 文件,后续不再探测
_mdns_usable() {
    local probe="$HNC_DIR/run/.mdns_probe"
    if [ -f "$probe" ]; then
        # 缓存命中
        [ "$(cat "$probe" 2>/dev/null)" = "ok" ]
        return
    fi
    # 首次探测
    mkdir -p "$HNC_DIR/run" 2>/dev/null
    if [ ! -x "$HNC_DIR/bin/mdns_resolve" ]; then
        echo "no" > "$probe"
        return 1
    fi
    # 跑一次 -h(只输出 usage,不发包,不阻塞),只看是否能 exec 成功
    "$HNC_DIR/bin/mdns_resolve" -h >/dev/null 2>&1
    local rc=$?
    # exec format error 通常 exit 126,正常 -h 通常 exit 0 或 1
    # 任何能成功 fork+exec 的(rc < 126)都算可用
    if [ $rc -lt 126 ]; then
        echo "ok" > "$probe"
        log "mdns_resolve compatible (rc=$rc)"
        return 0
    else
        echo "no" > "$probe"
        log "mdns_resolve incompatible (rc=$rc), arch mismatch likely"
        return 1
    fi
}

get_hostname() {
    local ip=$1 mac=$2 name=""

    # v3.4.6: 优先级链 (高 → 低):
    #   1. 手动命名 (data/device_names.json,用户说了算)
    #   2. 已缓存的发现结果 (10 分钟 TTL,避免每次扫描都跑 mDNS)
    #   3. mDNS 主动发现 (bin/mdns_resolve unicast + multicast)
    #   4. dnsmasq leases (在 ColorOS 上为空,但 LineageOS/原生 Android 有用)
    #   5. (调用方 fallback) MAC 后 8 位
    #   1. 手动命名 (data/device_names.json,用户说了算)
    #   2. 已缓存的发现结果 (10 分钟 TTL,避免每次扫描都跑 mDNS)
    #   3. mDNS 主动发现 (bin/mdns_resolve unicast + multicast)
    #   4. dnsmasq leases (在 ColorOS 上为空,但 LineageOS/原生 Android 有用)
    #   5. (调用方 fallback) MAC 后 8 位

    # 1. 手动命名
    local manual
    manual=$(sh "$HNC_DIR/bin/json_set.sh" name_get "$mac" 2>/dev/null)
    if [ -n "$manual" ]; then
        echo "$manual|manual"
        return
    fi

    # 2. 缓存
    local cached
    cached=$(hostname_cached "$mac") && {
        # 缓存里也存了来源标记 (cache 文件 v3.4.6 升级:第二个字段可能是
        # "name|src",兼容旧格式 "name")
        case "$cached" in
            *\|*) echo "$cached" ;;
            *)    echo "$cached|cache" ;;
        esac
        return
    }

    # 3. mDNS 主动发现
    # v3.4.11 兼容 #2:不仅检查文件可执行,还检查 CPU 架构兼容性
    # mdns_resolve 只编译了 aarch64,armv7/x86_64 设备执行会 "exec format error"
    # _mdns_usable() 首次调用时探测并缓存结果,后续直接读
    if _mdns_usable && [ -n "$ip" ]; then
        local mdns_name
        mdns_name=$("$HNC_DIR/bin/mdns_resolve" -t 800 "$ip" 2>/dev/null)
        if [ -n "$mdns_name" ]; then
            hostname_cache_set "$mac" "$mdns_name|mdns"
            echo "$mdns_name|mdns"
            return
        fi
    fi

    # 4. dnsmasq leases
    for f in /data/misc/dhcp/dnsmasq.leases \
              /data/vendor/dhcp/dnsmasq.leases \
              /data/misc/wifi/hostapd/dnsmasq.leases \
              /data/misc/wifi/dnsmasq.leases; do
        [ -f "$f" ] || continue
        name=$(awk -v m="$mac" '
            { ref=tolower(m); gsub(/:/,"",ref)
              cur=tolower($2); gsub(/:/,"",cur)
              if(cur==ref && $4!="*" && $4!="") {print $4; exit} }
        ' "$f" 2>/dev/null)
        [ -n "$name" ] && break
    done
    if [ -n "$name" ]; then
        hostname_cache_set "$mac" "$name|dhcp"
        echo "$name|dhcp"
        return
    fi

    # 5. 没有结果,调用方处理 fallback
    echo ""
}

# ── shell ARP 直读扫描（C daemon 不可用时的兜底）────────────
# v3.4.4：扫描完成后从 iptables HNC_STATS 链拿真实 rx/tx 字节,
# 替代 v3.4.3 之前硬编码的 0。
# v3.4.6：get_hostname 改成返回 "name|src" 格式,临时文件多一列
# 存 hostname_src,最终写入 devices.json 的 hostname_src 字段供
# WebUI 显示来源图标(✏️ manual / 🔍 mdns / 📡 dhcp / 无 mac)。
#
# 流程:
#   (1) 第一遍扫 ARP,把每个设备的基础 info(含 hostname + 来源)暂存
#   (2) 收集到的 IP 列表全部 ensure_stats(已有则幂等跳过)
#   (3) 一次性 stats_all 拿所有 IP 的字节计数(O(1) iptables 调用)
#   (4) 第三遍读临时文件 + stats 数据组装最终 JSON
#
# 注意:第三遍循环里复用第一遍设的 $ts(扫描开始时间戳),所有
# 设备共享同一个 last_seen — 这是有意的,反映"本次扫描时刻"。
do_scan_shell() {
    local ts iface gw pfx rules blacklist
    ts=$(date +%s)
    rules=$(cat "$RULES_FILE" 2>/dev/null || echo '{}')
    blacklist=$(echo "$rules" | grep -o '"blacklist":\[[^]]*\]' | \
        grep -oE '"[0-9a-f:]{17}"' | tr -d '"')

    iface=$(get_hotspot_iface)
    gw=$(ip addr show "$iface" 2>/dev/null | \
        awk '/inet /{split($2,a,"/"); print a[1]; exit}')
    [ -n "$gw" ] && {
        local pfx
        pfx=$(echo "$gw" | cut -d. -f1-3)
        ping -b -c 1 -W 1 "${pfx}.255" >/dev/null 2>&1 &
    }

    # 临时文件:每行存 ip|mac|hn|hn_src|dev|status
    local TMP="$HNC_DIR/run/scan_tmp.$$"
    # v3.4.11 P1-6 修复:第二个临时文件存 ARP 扫描结果
    # 之前用 `done <<EOF $(awk ...) EOF`,某些 busybox ash 实现会把整个 while 跑在 subshell,
    # 导致循环外 count=0 / online_ips="" → 第二遍 ensure_stats 跳过 → 流量数据全 0
    # 改用临时文件 + `done < "$ARP_TMP"`,POSIX 保证文件重定向不创建 subshell
    local ARP_TMP="$HNC_DIR/run/scan_arp.$$"
    mkdir -p "$HNC_DIR/run" 2>/dev/null
    : > "$TMP"
    # v3.5.0 P2-3: 进程异常退出时清理临时文件,避免 /run 累积垃圾
    trap 'rm -f "$TMP" "$ARP_TMP" 2>/dev/null' EXIT INT TERM

    # 写 ARP 扫描结果到临时文件(这一步即使在 subshell 也无所谓,因为它本来就在命令替换里)
    awk 'NR>1 && $3!="0x0" && $4!="00:00:00:00:00:00" && $1~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $6!~/^(lo|rmnet|dummy|v4-|tun|p2p)/ {print $1"|"$4"|"$6}' /proc/net/arp 2>/dev/null > "$ARP_TMP"

    local count=0
    local online_ips=""

    # ── 第一遍:扫 ARP,生成基础 device info ──
    # 用 < "$ARP_TMP" 而不是 <<EOF $(...) EOF,确保 while 在当前 shell 跑(变量不丢)
    while IFS='|' read -r ip mac dev; do
        [ -z "$ip" ] && continue
        mac=$(echo "$mac" | tr 'A-Z' 'a-z')
        count=$((count+1))
        online_ips="$online_ips $ip"

        # v3.4.6: get_hostname 返回 "name|src",空字符串表示 fallback
        local hn_raw hn hn_src
        hn_raw=$(get_hostname "$ip" "$mac")
        if [ -n "$hn_raw" ]; then
            # 拆分 name|src
            hn=${hn_raw%|*}
            hn_src=${hn_raw##*|}
        else
            hn=""
            hn_src=""
        fi
        # 兜底:MAC 后 8 位
        if [ -z "$hn" ]; then
            hn=$(echo "$mac" | tr -d ':' | tail -c 9)
            hn_src="mac"
        fi

        local status="allowed"
        echo "$blacklist" | grep -q "^$mac$" && status="blocked"

        printf '%s|%s|%s|%s|%s|%s\n' "$ip" "$mac" "$hn" "$hn_src" "$dev" "$status" >> "$TMP"
    done < "$ARP_TMP"
    rm -f "$ARP_TMP"

    # ── 第二遍:同步 stats 链 + 一次性读所有字节计数 ──
    local stats_data=""
    if [ "$count" -gt 0 ]; then
        for ip in $online_ips; do
            sh "$HNC_DIR/bin/iptables_manager.sh" ensure_stats "$ip" >/dev/null 2>&1
        done
        stats_data=$(sh "$HNC_DIR/bin/iptables_manager.sh" stats_all 2>/dev/null)
    fi

    # ── 第三遍:用 stats 数据填充 rx_bytes/tx_bytes,组装最终 JSON ──
    # ts 沿用第一遍的扫描开始时间戳(所有设备共享同一 last_seen)
    local json="{" first=1
    while IFS='|' read -r ip mac hn hn_src dev status; do
        [ -z "$ip" ] && continue
        local rx=0 tx=0
        if [ -n "$stats_data" ]; then
            local line
            line=$(echo "$stats_data" | awk -v i="$ip" '$1==i {print $2" "$3; exit}')
            if [ -n "$line" ]; then
                rx=$(echo "$line" | cut -d' ' -f1)
                tx=$(echo "$line" | cut -d' ' -f2)
                [ -z "$rx" ] && rx=0
                [ -z "$tx" ] && tx=0
            fi
        fi
        # JSON 转义 hostname(中文/特殊字符)
        # v3.4.11 P0-5 修复:加 tr -d '\000-\037' 去掉所有 0x00-0x1f 控制字符。
        # mDNS PTR label 协议层允许任意字节,含 \n 会破坏 JSON,
        # 让 JSON.parse 失败 → 整个设备列表清空。
        local hn_json
        hn_json=$(printf '%s' "$hn" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
        [ $first -eq 0 ] && json="$json,"
        json="${json}\"${mac}\":{\"ip\":\"$ip\",\"mac\":\"$mac\",\"hostname\":\"$hn_json\",\"hostname_src\":\"$hn_src\",\"iface\":\"$dev\",\"rx_bytes\":$rx,\"tx_bytes\":$tx,\"status\":\"$status\",\"last_seen\":$ts}"
        first=0
    done < "$TMP"
    json="${json}}"

    rm -f "$TMP"
    printf '%s' "$json" > "${DEVICES_FILE}.tmp" && \
        mv "${DEVICES_FILE}.tmp" "$DEVICES_FILE"
    log "shell scan: $count device(s)"
    echo "$count"
}

# ── 热点状态 / Doze 检测 ─────────────────────────────────────
is_hotspot_up() {
    local iface
    iface=$(get_hotspot_iface)
    ip addr show "$iface" 2>/dev/null | grep -q 'inet '
}

is_doze_mode() {
    cmd power get-idle-mode 2>/dev/null | grep -qiE "^deep$|^light$" && return 0
    local lvl
    lvl=$(dumpsys battery 2>/dev/null | awk '/level:/{print $2}')
    [ -n "$lvl" ] && [ "$lvl" -lt 5 ] 2>/dev/null && return 0
    return 1
}

arp_hash() {
    awk 'NR>1 && $3!="0x0" {print $1,$4,$6}' /proc/net/arp 2>/dev/null | \
        md5sum | awk '{print $1}'
}

# ── Shell 轮询兜底 (只在 hotspotd 不可用时运行) ─────────────
daemon_shell_fallback() {
    log "=== Shell daemon fallback started (PID=$$) ==="
    echo $$ > "$HNC_DIR/run/detect.pid"
    [ -f "$DEVICES_FILE" ] || echo '{}' > "$DEVICES_FILE"

    local last_count=-1 last_hash="" interval=60 no_ap_rounds=0

    while true; do
        if is_doze_mode; then
            interval=120; sleep $interval; continue
        fi

        if ! is_hotspot_up; then
            no_ap_rounds=$((no_ap_rounds+1))
            if [ "$last_count" -gt 0 ] || [ "$last_count" = "-1" ]; then
                echo '{}' > "$DEVICES_FILE"; last_count=0; log "Hotspot down"
            fi
            [ "$no_ap_rounds" -gt 5 ] && interval=60 || interval=15
            sleep $interval; continue
        fi
        no_ap_rounds=0

        local cur_hash need_scan=0
        cur_hash=$(arp_hash)
        # v3.3.0：原逻辑 `[ last_count > 0 ] && need_scan=1` 让 arp_hash
        # 缓存在有设备时完全失效，每 8 秒强制重扫但 shell 扫描并不抓
        # 流量字节数（rx/tx 都写 0），纯粹浪费 CPU。移除。
        [ "$cur_hash" != "$last_hash" ] && need_scan=1
        [ "$last_count" = "-1" ]        && need_scan=1

        if [ "$need_scan" = "1" ]; then
            local count
            count=$(do_scan_shell)
            last_hash=$(arp_hash)
            if [ "$count" -gt 0 ]; then
                interval=8
                [ "$count" != "$last_count" ] && log "Devices: $last_count -> $count"
            else
                interval=30
                [ "$last_count" -gt 0 ] && log "All devices gone"
            fi
            last_count=$count
        fi
        sleep $interval
    done
}

# ── daemon 模式：优先 C daemon ──────────────────────────────
daemon_mode() {
    log "=== Daemon mode starting ==="

    if [ -x "$HOTSPOTD_BIN" ]; then
        log "Starting C daemon: $HOTSPOTD_BIN"
        # -d: 后台化（自己 fork），写 PID 到 HOTSPOTD_PID
        "$HOTSPOTD_BIN" -d -l "$HNC_DIR/logs/hotspotd.log"
        sleep 2
        if hotspotd_alive; then
            log "C daemon running (PID=$(cat $HOTSPOTD_PID 2>/dev/null))"
            # C daemon 已接管，本进程可退出
            # service.sh 不再需要 detect.pid（由 hotspotd.pid 管理）
            return 0
        fi
        log "WARN: C daemon failed, falling back to shell poll"
    else
        log "hotspotd binary not found, using shell daemon"
    fi

    daemon_shell_fallback
}

# ── 命令分发 ────────────────────────────────────────────────
case "${1:-scan}" in
    scan)
        if hotspotd_alive; then
            do_scan_via_daemon || do_scan_shell
        else
            do_scan_shell
        fi
        ;;
    daemon)
        daemon_mode
        ;;
    list)
        if hotspotd_alive && \
           (command -v socat >/dev/null 2>&1 || command -v nc >/dev/null 2>&1); then
            socket_query "GET_DEVICES"
        else
            cat "$DEVICES_FILE" 2>/dev/null || echo '{}'
        fi
        ;;
    iface)
        # v3.4.1：iface 检测加文件缓存（5 分钟）
        # 旧版每次调用都跑 awk 解析 /proc/net/arp，结果在 wlan0 / wlan2 之间反复
        # 横跳（取决于 ARP 表临时状态），导致 watchdog 误判"接口变化"触发 full_restore，
        # 一晚上 158 次。加文件缓存彻底屏蔽抖动。
        #
        # 但缓存有副作用：如果检测时热点没开，get_hotspot_iface 可能返回错误结果，
        # 然后被缓存 5 分钟。所以：
        #   1. 只缓存有效结果（非空 + 非 wlan0）
        #   2. 缓存 miss 时如果 get_hotspot_iface 失败，输出 wlan0 但不写缓存
        #      （让下次调用重新检测，热点开了就能拿到正确值）
        IFACE_CACHE="$HNC_DIR/run/iface.cache"
        if [ -f "$IFACE_CACHE" ]; then
            cache_ts=$(stat -c %Y "$IFACE_CACHE" 2>/dev/null || echo 0)
            now_ts=$(date +%s)
            if [ -n "$cache_ts" ] && [ $((now_ts - cache_ts)) -lt 300 ]; then
                cached=$(cat "$IFACE_CACHE" 2>/dev/null)
                if [ -n "$cached" ] && [ "$cached" != "wlan0" ]; then
                    echo "$cached"
                    exit 0
                fi
            fi
        fi
        # 缓存失效或缓存值无效，重新检测
        mkdir -p "$HNC_DIR/run" 2>/dev/null
        detected=$(get_hotspot_iface)
        if [ -n "$detected" ] && [ "$detected" != "wlan0" ]; then
            # 有效值才写缓存
            echo "$detected" > "$IFACE_CACHE" 2>/dev/null
            echo "$detected"
        else
            # 检测失败：输出 wlan0 兜底但不写缓存
            # 让下次调用有机会重新检测（热点开了之后就能拿到正确值）
            echo "wlan0"
        fi
        ;;
    status)
        if hotspotd_alive; then
            socket_query "STATUS"
        else
            # v3.3.0 修复：case 分支运行在顶层而非函数内部，ash 严格模式
            # 下不允许 `local`。直接用普通变量。
            dpid=$(cat "$HNC_DIR/run/detect.pid" 2>/dev/null)
            echo "shell_daemon pid=${dpid:-none}"
        fi
        ;;
    *)
        echo "Usage: $0 [scan|daemon|list|iface|status]"
        exit 1
        ;;
esac
