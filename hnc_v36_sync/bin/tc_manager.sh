#!/system/bin/sh

# v3.5.0 alpha-0: PATH 健壮性,见 service.sh
[ -z "$HNC_SKIP_PATH_HARDENING" ] && [ -z "$HNC_TEST_MODE" ] && export PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
# tc_manager.sh — v3.2.0  Android 16 / KSU 强化版
#
# 核心修复（解释"限速时好时坏"根因）：
#
#  问题1 — 上传方向 TC 永不生效：
#    mirred redirect → ifb0 发生在 PREROUTING 之前
#    此时 iptables MARK=0，ifb0 fw filter 匹配不到，上传走 class 9999
#    修复：ifb0 改用 u32 src IP 匹配，完全不依赖 iptables mark
#
#  问题2 — 下载偶发绕过：
#    旧 burst = 128×Mbps KB → 2Mbps 时 256KB（约1秒数据量）太宽松
#    多线程同时命中 burst 窗口可轻松冲破限速线
#    修复：burst = 2.5×Mbps KB（约 20ms 数据量），严格限速
#
#  问题3 — 硬件 offload 绕过：
#    GRO/GSO/TSO 将小包合并成超大包，tc 按包整形时等效带宽翻倍
#    修复：init_tc 时通过 ethtool + sysfs 禁用全部 offload
#
#  问题4 — QUIC/多线程绕过：
#    fw mark 依赖 iptables 时序，新连接第一包 mark=0 走默认 class
#    修复：主分类改用 u32 IP 匹配（dst=下载, src=上传），fw mark 降为备用
#
# set_limit 签名（v3.2.0 新增第5参数）：
#   set_limit <iface> <mark_id> <down_mbps> <up_mbps> [ip]

HNC_DIR=${HNC_DIR:-/data/local/hnc}
RULES_FILE=$HNC_DIR/data/rules.json
LOG=$HNC_DIR/logs/tc.log

log() {
    # v3.5.0 P2-1: 路径不存在时不让 redirect 失败导致整个脚本退出
    [ -d "$(dirname "$LOG")" ] || mkdir -p "$(dirname "$LOG")" 2>/dev/null
    echo "[$(date '+%H:%M:%S')] [TC] $*" >> "$LOG" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# v3.3.1 浮点数比较助手
# 问题：shell 内置 `[ x -gt 0 ]` 对 "0.2" 这种小数直接报错，
# 导致 set_limit/set_delay 里所有 `if [ "${val:-0}" -gt 0 ]` 判断
# 在小数输入下统统走 false 分支，限速规则永远不会被创建。
# 症状：整数 Mbps 生效、小数 Mbps（0.1 / 0.2 / 0.5）完全不生效。
#
# 用法：gt0 "$var"            # $var > 0 ?
#       ge_val "$a" "$b"      # $a >= $b ?
# ═══════════════════════════════════════════════════════════════
gt0() {
    awk -v v="${1:-0}" 'BEGIN{exit !(v+0 > 0)}'
}
ge_val() {
    awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{exit !(a+0 >= b+0)}'
}
lt_val() {
    awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{exit !(a+0 < b+0)}'
}

# ─── 常量 ────────────────────────────────────────────────────
DEFAULT_RATE="1000mbit"
IFB_IFACE="ifb0"
FILTER_PRIO_FW=1       # fw mark filter（备用）
FILTER_PRIO_BASE=100   # u32 IP filter 基准优先级（每设备 100+class_id）

# ═══════════════════════════════════════════════════════════════
# 顶层辅助函数（Android ash 不支持嵌套函数定义）
# ═══════════════════════════════════════════════════════════════

mbps_to_rate() {
    local val=$1
    # 带 k/K 后缀：直接解释为 kbit
    if echo "$val" | grep -qi 'k$'; then
        local n; n=$(echo "$val" | tr -d 'kKmM')
        gt0 "$n" && echo "${n}kbit" && return
    fi
    # 剥离可能的 m/M 后缀
    local mbps; mbps=$(echo "$val" | tr -d 'mMkK')

    # v3.3.1：统一换算为 kbit 输出，兼顾小数精度
    # 原因：
    #   1) shell `[ x -gt 0 ]` 对小数报错 → 改用 awk 浮点比较
    #   2) tc 不接受 "1.5mbit"/"0.2mbit" 这种写法 → 统一改成 1500kbit/200kbit
    #   3) 0.01 → 10kbit（最低限速粒度约 10 kbps，足够细）
    if gt0 "$mbps"; then
        local kbps; kbps=$(awk -v v="$mbps" 'BEGIN{printf "%d", v*1000 + 0.5}')
        [ "${kbps:-0}" -lt 1 ] && kbps=1
        echo "${kbps}kbit"
    else
        echo "64kbit"
    fi
}

# burst = 约20ms数据量，防多线程集体冲破限速（旧方案128×Mbps太宽松）
burst_for_rate() {
    awk "BEGIN{b=int($1 * 2.5); print (b<16?16:b) \"k\"}"
}

# HTB class add-or-change（幂等）
tc_class_set() {
    local dev=$1 parent=$2 classid=$3; shift 3
    tc class change dev "$dev" parent "$parent" classid "$classid" htb "$@" 2>/dev/null && return 0
    tc class add   dev "$dev" parent "$parent" classid "$classid" htb "$@" 2>/dev/null && return 0
    return 1
}

# 确保 HTB class 有叶子 qdisc（无叶子时 pfifo 兜底偶发丢包）
tc_leaf_ensure() {
    local dev=$1 parent=$2 handle=$3
    tc qdisc change dev "$dev" parent "$parent" handle "$handle" fq_codel 2>/dev/null && return 0
    tc qdisc add   dev "$dev" parent "$parent" handle "$handle" fq_codel 2>/dev/null \
        || tc qdisc add dev "$dev" parent "$parent" handle "$handle" pfifo 2>/dev/null || true
}

# fw mark filter（备用，prio=1）
tc_filter_fw_set() {
    local dev=$1 mark=$2 flowid=$3
    tc filter del dev "$dev" parent 1: pref "$FILTER_PRIO_FW" handle "$mark" fw 2>/dev/null || true
    tc filter add dev "$dev" parent 1: pref "$FILTER_PRIO_FW" handle "$mark" fw \
        flowid "$flowid" 2>/dev/null || true
}

# u32 dst IP filter（下载方向：热点→设备，按 dst IP 分类）
# 关键：不依赖 iptables mark，捕获所有协议（TCP/UDP/QUIC）
# v3.3.4：删除了原 IPv6 u32 分支——原代码用 $ip（IPv4 地址）做 "ip6 dst $ip/128"
#         永远不可能匹配，是静默失败的死代码。IPv6 流量现在完全靠 fw mark filter
#         （由 tc_filter_fw_set 注册）配合 iptables_manager.sh 的 CONNMARK 路径分类。
tc_filter_u32_dst() {
    local dev=$1 prio=$2 ip=$3 flowid=$4
    [ -z "$ip" ] && return 0
    tc filter del dev "$dev" parent 1: prio "$prio" 2>/dev/null || true
    tc filter add dev "$dev" parent 1: protocol ip prio "$prio" u32 \
        match ip dst "$ip/32" flowid "$flowid" 2>/dev/null \
        && log "u32 dst $ip → $flowid on $dev"
}

# u32 src IP filter（上传方向：设备→ifb0，按 src IP 分类）
# 核心修复：替代 fw mark，解决 mirred redirect 时序问题
# v3.3.4：同样删除了假的 IPv6 分支
tc_filter_u32_src() {
    local dev=$1 prio=$2 ip=$3 flowid=$4
    [ -z "$ip" ] && return 0
    tc filter del dev "$dev" parent 1: prio "$prio" 2>/dev/null || true
    tc filter add dev "$dev" parent 1: protocol ip prio "$prio" u32 \
        match ip src "$ip/32" flowid "$flowid" 2>/dev/null \
        && log "u32 src $ip → $flowid on $dev"
}

# netem qdisc add-or-change
netem_qdisc_set() {
    local dev=$1 parent=$2 handle=$3; shift 3
    tc qdisc change dev "$dev" parent "$parent" handle "$handle" netem "$@" 2>/dev/null && return 0
    tc qdisc del dev "$dev" parent "$parent" 2>/dev/null || true
    tc qdisc add dev "$dev" parent "$parent" handle "$handle" netem "$@" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# v3.3.2 设备 class 生命周期管理
#
# 【新架构】
# 限速（HTB rate）与延迟（netem）使用同一个 HTB class，但互不干扰：
#
#   class 1:$class_id  (HTB, rate = 限速值 或 DEFAULT_RATE 表示不限速)
#     └─ qdisc leaf: netem [delay Xms] limit 100
#                    （无延迟时仅 limit，不带 delay 参数）
#
# 【分工】
#   - ensure_device_class : 幂等创建 class + leaf netem + filter
#   - set_rate_only       : 仅改 class 的 rate/ceil/burst
#   - set_netem_only      : 仅改 leaf netem 参数
#   - class_exists        : 查询 class 是否存在（用于关闭分支保护 leaf）
#   - leaf_has_netem      : 查询 leaf 是否为 netem（兼容 v3.3.1 fq_codel 残留）
#
# 【解决 v3.3.1 的核心 bug】
#   原 set_limit 的 "关闭限速" 分支会 `tc class del`，连带删除挂在该
#   class 下的 netem qdisc → 关掉限速就误杀了延迟。反向也有类似问题
#   （换叶子 qdisc 会影响限速）。新架构下两者完全解耦：
#     - set_limit(0)  → 只 set_rate_only 为 DEFAULT_RATE，leaf netem 不动
#     - set_delay(0)  → 只 set_netem_only 为无延迟，class rate 不动
# ═══════════════════════════════════════════════════════════════

# 查询 class 是否存在
class_exists() {
    local dev=$1 class_id=$2
    tc class show dev "$dev" 2>/dev/null | grep -qF "class htb 1:$class_id "
}

# 查询 leaf qdisc 是否已是 netem（用于兼容 v3.3.1 fq_codel 残留的升级场景）
leaf_has_netem() {
    local dev=$1 class_id=$2
    tc qdisc show dev "$dev" 2>/dev/null \
        | grep -F "parent 1:$class_id " \
        | grep -q netem
}

# 幂等创建设备 class + leaf netem + filters
# 参数：dev class_id ip
# 方向由 dev 推断：$IFB_IFACE → src IP（上传），其他 → dst IP（下载）
#
# v3.3.6：从"已存在则跳过"改为"已存在则备份延迟参数后强制重建"
# 原因：升级 v3.3.5 后旧 v3.3.4 创建的 class 还带 cburst=1600，
# 单纯靠 set_rate_only 的 tc class change 在某些 Android tc 实现下
# 不会刷新 cburst。强制 del+add 是唯一保险的办法。
ensure_device_class() {
    local dev=$1 class_id=$2 ip=$3
    local mark; mark=$(printf "0x%x" $((0x800000 + class_id)))
    local prio=$((FILTER_PRIO_BASE + class_id))
    local leaf_handle direction
    if [ "$dev" = "$IFB_IFACE" ]; then
        leaf_handle=$((class_id + 2000))
        direction=src
    else
        leaf_handle=$((class_id + 1000))
        direction=dst
    fi

    # 1. 备份现有 class 的 rate 和 leaf netem 的 delay 参数（如果有），
    # 然后整个 class 删掉。这样无论旧 class 是什么状态
    # （v3.3.4 残留 cburst=1600 等），新建出来的 class 一定带正确的 v3.3.6 参数。
    #
    # v3.3.6 关键修复：必须保留 rate，否则 set_delay 调用本函数时
    # 会清掉 set_limit 之前设好的限速 rate（场景：先 set_limit 再 set_delay）。
    local saved_rate=""
    local saved_delay=""
    local saved_jitter=""
    if class_exists "$dev" "$class_id"; then
        # 解析 class 的 rate 字段（格式如 "class htb 1:59 ... rate 8Mbit ceil 8Mbit ..."）
        local class_line; class_line=$(tc class show dev "$dev" classid "1:$class_id" 2>/dev/null)
        if [ -n "$class_line" ]; then
            saved_rate=$(echo "$class_line" | awk '{for(i=1;i<=NF;i++) if($i=="rate") {print $(i+1); exit}}')
        fi
        # 解析 leaf netem 的 delay 字段（格式如 "delay 100ms 10ms"）
        # v3.5.0 P2-2: jitter 解析防御 — 如果 delay 后面没有 jitter,
        # $(i+2) 可能是 "limit" 等非时间字段,case 检查会过滤掉
        local netem_line; netem_line=$(tc qdisc show dev "$dev" parent "1:$class_id" 2>/dev/null | grep netem)
        if [ -n "$netem_line" ]; then
            saved_delay=$(echo "$netem_line" | awk '{for(i=1;i<=NF;i++) if($i=="delay") {print $(i+1); exit}}')
            saved_jitter=$(echo "$netem_line" | awk '{for(i=1;i<=NF;i++) if($i=="delay") {print $(i+2); exit}}')
            case "$saved_delay" in
                0ms|0us|0s|"") saved_delay="" ;;
                *ms|*us|*s) ;;  # 保留
                *) saved_delay="" ;;  # 不识别的格式,不保留
            esac
            case "$saved_jitter" in
                *ms|*us|*s) ;;
                *) saved_jitter="" ;;
            esac
        fi
        tc class del dev "$dev" parent 1:1 classid "1:$class_id" 2>/dev/null || true
        log "  Rebuilding class 1:$class_id on $dev (saved rate='$saved_rate' delay='$saved_delay')"
    fi

    # 2. 用正确参数重新建 class
    # rate 用备份值（如果之前 set_limit 设过）或 DEFAULT_RATE（首次建）
    # cburst 必须显式设，否则内核默认 1600 字节
    local use_rate="${saved_rate:-$DEFAULT_RATE}"
    tc class add dev "$dev" parent 1:1 classid "1:$class_id" \
        htb rate "$use_rate" ceil "$use_rate" burst 200k cburst 200k 2>/dev/null \
        && log "  Created class 1:$class_id on $dev (rate=$use_rate)"

    # 3. 重建 leaf netem，恢复延迟参数（如果有的话）
    # limit 100 包 ≈ 150 KB，避免 buffer bloat 卡死 TCP
    local netem_args="delay 0ms"
    if [ -n "$saved_delay" ]; then
        netem_args="delay $saved_delay"
        [ -n "$saved_jitter" ] && netem_args="$netem_args $saved_jitter"
    fi
    # shellcheck disable=SC2086
    tc qdisc add dev "$dev" parent "1:$class_id" handle "${leaf_handle}:" \
        netem $netem_args limit 100 2>/dev/null \
        && log "  Created leaf netem ${leaf_handle}: ($netem_args)"

    # 4. 创建 u32 filter（若有 IP）
    if [ -n "$ip" ]; then
        if [ "$direction" = "src" ]; then
            tc_filter_u32_src "$dev" "$prio" "$ip" "1:$class_id"
        else
            tc_filter_u32_dst "$dev" "$prio" "$ip" "1:$class_id"
        fi
    fi

    # 5. 创建 fw 备用 filter
    tc_filter_fw_set "$dev" "$mark" "1:$class_id"
}

# 仅修改 class 的 rate/ceil/burst（不动 leaf qdisc）
# v3.3.5：cburst 必须和 burst 一起改，不然 cburst 永远是初始建 class 时的值
set_rate_only() {
    local dev=$1 class_id=$2 rate=$3 burst=$4
    tc_class_set "$dev" 1:1 "1:$class_id" rate "$rate" ceil "$rate" burst "$burst" cburst "$burst"
}

# 仅修改 leaf netem 参数（不动 class rate）
# 参数：dev class_id delay_ms jitter_ms loss
set_netem_only() {
    local dev=$1 class_id=$2 delay_ms=${3:-0} jitter_ms=${4:-0} loss=${5:-0}
    local leaf_handle
    if [ "$dev" = "$IFB_IFACE" ]; then
        leaf_handle=$((class_id + 2000))
    else
        leaf_handle=$((class_id + 1000))
    fi

    # 拼接 netem 参数。v3.3.2：无论 delay 是否为 0 都显式带上 `delay Xms`，
    # 避免部分 kernel 在 `tc qdisc change` 省略 delay 时保留旧值。
    # v3.4.11 P0-3 修复:之前 if gt0 delay 的 else 分支只输出 "delay 0ms",
    # 把 jitter 和 loss 都丢了,导致"只设丢包不设延迟"完全无效
    # (但前端 delay_enabled = (dl>0 || jt>0 || ls>0) 让 UI 显示已启用 → 严重视觉欺骗)。
    local args
    if gt0 "$delay_ms" || gt0 "$jitter_ms" || gt0 "$loss"; then
        if gt0 "$delay_ms"; then
            args="delay ${delay_ms}ms"
            gt0 "$jitter_ms" && args="$args ${jitter_ms}ms 25% distribution normal"
        else
            args="delay 0ms"
        fi
        gt0 "$loss" && args="$args loss ${loss}%"
    else
        args="delay 0ms"
    fi
    args="$args limit 100"  # v3.3.5: 同 ensure_device_class，避免 buffer bloat

    # 幂等：优先 change；失败则 del+add
    # shellcheck disable=SC2086
    tc qdisc change dev "$dev" parent "1:$class_id" handle "${leaf_handle}:" netem $args 2>/dev/null && return 0
    tc qdisc del    dev "$dev" parent "1:$class_id" 2>/dev/null || true
    # shellcheck disable=SC2086
    tc qdisc add    dev "$dev" parent "1:$class_id" handle "${leaf_handle}:" netem $args 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# 禁用硬件加速 / offload
# 必须在 tc qdisc 建立之前调用，否则大包绕过整形层
# ═══════════════════════════════════════════════════════════════
disable_offload() {
    local iface=$1
    log "Disabling offload on $iface..."

    # 关闭 ethtool offload（GRO/GSO/TSO/LRO）
    # GRO 把多个小包合并为大包再交给网络栈，tc 按包整形时等效带宽倍增
    ethtool -K "$iface" gro off gso off tso off lro off 2>/dev/null || true
    ethtool -K "$iface" sg off rx-vlan-offload off tx-vlan-offload off 2>/dev/null || true

    # Android 特有 fastpath / 硬件转发加速（高通/联发科 SoC）
    for p in \
        /proc/sys/net/netfilter/nf_fastroute \
        /proc/sys/net/rmnet/nf_hook_enable   \
        /sys/kernel/hnk/nf_conntrack_skip    ; do
        [ -w "$p" ] && echo 0 > "$p" 2>/dev/null || true
    done

    # bridge-nf 确保桥接帧走 iptables（v3.4.1：很多 ColorOS 内核没编 bridge 模块，
    # /proc/sys/net/bridge 目录直接不存在。无害，静默忽略。）
    [ -w /proc/sys/net/bridge/bridge-nf-call-iptables ]  && echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables  2>/dev/null || true
    [ -w /proc/sys/net/bridge/bridge-nf-call-ip6tables ] && echo 1 > /proc/sys/net/bridge/bridge-nf-call-ip6tables 2>/dev/null || true

    # 关闭 RPS（部分配置下绕过 tc ingress）
    for q in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
        [ -w "$q" ] && echo 0 > "$q" 2>/dev/null || true
    done

    # 确保 conntrack 记账开启
    modprobe nf_conntrack 2>/dev/null || true
    echo 1 > /proc/sys/net/netfilter/nf_conntrack_acct 2>/dev/null || true

    # MTU 限制为 1500（防超大帧绕过整形）
    local mtu; mtu=$(cat /sys/class/net/"$iface"/mtu 2>/dev/null || echo 1500)
    [ "${mtu:-1500}" -gt 1500 ] && ip link set dev "$iface" mtu 1500 2>/dev/null || true

    log "Offload disabled OK"
}

# ─── 加载 IFB 模块 ───────────────────────────────────────────
load_ifb() {
    modprobe ifb numifbs=2 2>/dev/null \
        || insmod /system/lib/modules/ifb.ko numifbs=2 2>/dev/null || true
    local i=0
    while [ $i -lt 10 ] && ! ip link show "$IFB_IFACE" >/dev/null 2>&1; do
        ip link add "$IFB_IFACE" type ifb 2>/dev/null || true
        # v3.4.11 内部加固:sleep 0.3 改成 usleep 兼容 busybox,失败 fall back sleep 1
        i=$((i+1))
        usleep 300000 2>/dev/null || sleep 1
    done
    ip link set "$IFB_IFACE" up 2>/dev/null || true
    log "IFB $IFB_IFACE ready"
}

# ═══════════════════════════════════════════════════════════════
# 初始化 TC 基础结构
# ═══════════════════════════════════════════════════════════════
init_tc() {
    local iface=${1:-$(sh "$HNC_DIR/bin/device_detect.sh" iface)}

    # v3.4.1: 参数验证。空 iface 或不存在的接口直接 return，
    # 避免 watchdog 误调时把 tc 命令带空参数运行（v3.4.0 真机日志里
    # 出现过 "tc: invalid argument '1:1'" 这类错误就是这里来的）
    if [ -z "$iface" ] || ! ip link show "$iface" >/dev/null 2>&1; then
        log "init_tc: skipped, invalid iface='$iface'"
        return 1
    fi

    log "=== TC init: $iface ==="

    disable_offload "$iface"
    load_ifb

    # ── Egress HTB（下载：热点→设备）────────────────────────
    tc qdisc del dev "$iface" root 2>/dev/null || true
    tc qdisc add dev "$iface" root handle 1: htb default 9999 r2q 10 2>/dev/null \
        || { log "init_tc: failed to add root htb on $iface"; return 1; }
    tc class add dev "$iface" parent 1:  classid 1:1    htb rate "$DEFAULT_RATE" ceil "$DEFAULT_RATE" burst 200k cburst 200k 2>/dev/null
    tc class add dev "$iface" parent 1:1 classid 1:9999 htb rate "$DEFAULT_RATE" ceil "$DEFAULT_RATE" burst 200k cburst 200k 2>/dev/null
    tc qdisc add dev "$iface" parent 1:9999 handle 9999: fq_codel 2>/dev/null \
        || tc qdisc add dev "$iface" parent 1:9999 handle 9999: sfq perturb 10 2>/dev/null

    # ── Ingress → IFB 重定向（上传：设备→热点）──────────────
    # v3.4.1：先检测 clsact 是否已存在。Android 内核常常在 wlan2 上预装
    # `clsact ffff: parent ffff:fff1`,与我们要 add 的 `ingress` qdisc
    # 共用 handle ffff: 但类型不同。直接 add 会报 RTNETLINK File exists
    # 然后后续 tc filter add 全部失败。检测到 clsact 时跳过 ingress add,
    # 直接复用 clsact 的 ingress hook 挂 filter。
    #
    # v3.4.11 P0 修复:之前的代码用 `tc filter add dev <iface> parent ffff: ...`
    # 这是老 ingress qdisc 的语法,在 clsact 上不工作!
    # clsact 提供两个独立的 hook:
    #   ffff:fff2 = ingress(包从外面进入,我们要的)
    #   ffff:fff3 = egress(包从主机发出)
    # 在 clsact 上必须用 `parent ffff:fff2`,在老 ingress 上才能用 `parent ffff:`。
    # 之前的代码在 clsact 路径下 silent 失败(2>/dev/null),所有上传限速都没生效!
    local has_clsact=0
    tc qdisc show dev "$iface" 2>/dev/null | grep -q "qdisc clsact ffff:" && has_clsact=1

    local ingress_parent
    if [ "$has_clsact" = "1" ]; then
        log "init_tc: clsact ffff: already present, reusing ingress hook (parent ffff:fff2)"
        ingress_parent="ffff:fff2"
    else
        tc qdisc del dev "$iface" ingress 2>/dev/null || true
        tc qdisc add dev "$iface" handle ffff: ingress 2>/dev/null \
            || log "init_tc: ingress qdisc add failed (may already exist)"
        ingress_parent="ffff:"
    fi

    # 删旧 filter(防止重复 init 累积)
    tc filter del dev "$iface" parent "$ingress_parent" prio 1 2>/dev/null || true
    tc filter del dev "$iface" parent "$ingress_parent" prio 2 2>/dev/null || true

    tc filter add dev "$iface" parent "$ingress_parent" protocol ip   prio 1 u32 \
        match u32 0 0 action mirred egress redirect dev "$IFB_IFACE" \
        && log "init_tc: ingress v4 mirred filter added on $ingress_parent" \
        || log "init_tc: ingress v4 mirred filter add FAILED on $ingress_parent (上传限速会失效!)"
    tc filter add dev "$iface" parent "$ingress_parent" protocol ipv6 prio 2 u32 \
        match u32 0 0 action mirred egress redirect dev "$IFB_IFACE" 2>/dev/null \
        && log "init_tc: ingress v6 mirred filter added on $ingress_parent" || true

    # ── IFB0 Egress HTB（上传整形）──────────────────────────
    tc qdisc del dev "$IFB_IFACE" root 2>/dev/null || true
    tc qdisc add dev "$IFB_IFACE" root handle 1: htb default 9999 r2q 10 2>/dev/null
    tc class add dev "$IFB_IFACE" parent 1:  classid 1:1    htb rate "$DEFAULT_RATE" ceil "$DEFAULT_RATE" burst 200k cburst 200k 2>/dev/null
    tc class add dev "$IFB_IFACE" parent 1:1 classid 1:9999 htb rate "$DEFAULT_RATE" ceil "$DEFAULT_RATE" burst 200k cburst 200k 2>/dev/null
    tc qdisc add dev "$IFB_IFACE" parent 1:9999 handle 9999: fq_codel 2>/dev/null \
        || tc qdisc add dev "$IFB_IFACE" parent 1:9999 handle 9999: sfq perturb 10 2>/dev/null

    log "=== TC init OK ==="
}

# ═══════════════════════════════════════════════════════════════
# 设置设备限速
# 用法: set_limit <iface> <mark_id> <down_mbps> <up_mbps> [ip]
#
# v3.3.2 重构：限速与延迟完全解耦
#   - 启用限速：ensure_device_class（首次建 class+leaf+filter）+ set_rate_only
#   - 关闭限速：只把 rate 重置为 DEFAULT_RATE，不删 class，不碰 leaf netem
#   - 结果：关限速时若该设备还有延迟，延迟保持不变
# ═══════════════════════════════════════════════════════════════
set_limit() {
    local iface=$1 mark_id=$2 down_mbps=${3:-0} up_mbps=${4:-0} ip=${5:-}
    local class_id; class_id=$(printf "%d" "$mark_id")

    log "set_limit: mark=$mark_id ip=${ip:-(none)} dn=${down_mbps}M up=${up_mbps}M"

    # ── Egress（下载：热点→设备）──────────────────────────────
    if gt0 "$down_mbps"; then
        ensure_device_class "$iface" "$class_id" "$ip"
        local dn_rate;  dn_rate=$(mbps_to_rate "$down_mbps")
        local dn_burst; dn_burst=$(burst_for_rate "$down_mbps")
        set_rate_only "$iface" "$class_id" "$dn_rate" "$dn_burst"
        log "  Egress 1:$class_id @ $dn_rate burst $dn_burst"
    else
        # 关限速：只重置 rate，保留 leaf netem（可能承载延迟）
        if class_exists "$iface" "$class_id"; then
            set_rate_only "$iface" "$class_id" "$DEFAULT_RATE" 200k
            log "  Egress 1:$class_id rate cleared (leaf preserved)"
        fi
    fi

    # ── Ingress（上传：设备→热点，通过 ifb0）────────────────
    if gt0 "$up_mbps"; then
        ensure_device_class "$IFB_IFACE" "$class_id" "$ip"
        local up_rate;  up_rate=$(mbps_to_rate "$up_mbps")
        local up_burst; up_burst=$(burst_for_rate "$up_mbps")
        set_rate_only "$IFB_IFACE" "$class_id" "$up_rate" "$up_burst"
        log "  Ingress(ifb0) 1:$class_id @ $up_rate burst $up_burst"
    else
        if class_exists "$IFB_IFACE" "$class_id"; then
            set_rate_only "$IFB_IFACE" "$class_id" "$DEFAULT_RATE" 200k
            log "  Ingress(ifb0) 1:$class_id rate cleared (leaf preserved)"
        fi
    fi

    # v3.4.0：触发 v6 sync，让 IPv6 流量也能被这条限速规则覆盖
    # sync_all 是幂等的，对没有变化的设备零开销
    sh "$HNC_DIR/bin/v6_sync.sh" sync >> "$LOG" 2>&1 || true
    return 0
}

# ═══════════════════════════════════════════════════════════════
# 设置延迟（netem）
# 用法: set_delay <iface> <mark_id> <delay_ms> [jitter_ms] [loss%] [ip]
#
# v3.3.2 重构：
#   - 启用延迟：ensure_device_class + set_netem_only（只改 leaf netem）
#   - 关闭延迟：只重置 leaf netem 为无延迟，不动 class rate
#   - 结果：关延迟时若该设备还有限速，限速保持不变
# ═══════════════════════════════════════════════════════════════
set_delay() {
    local iface=$1 mark_id=$2 delay_ms=${3:-0} jitter_ms=${4:-0} loss=${5:-0} ip=${6:-}
    local class_id; class_id=$(printf "%d" "$mark_id")

    log "set_delay: mark=$mark_id ip=${ip:-(none)} ${delay_ms}ms jitter=${jitter_ms}ms loss=${loss}%"

    # v3.5.0 alpha-2:P0-3 完整修复
    # v3.4.11 只修了 set_netem_only 内部逻辑,但 set_delay 的入口判断仍然是
    # `if gt0 delay_ms`,导致 loss-only(delay=0 jitter=0 loss=5)进入 else
    # 分支被当成"关闭延迟",把 netem 重置为 0 → loss 完全丢失。
    # 修复:入口判断改为 delay/jitter/loss 任一 > 0 都进入"启用"分支
    if gt0 "$delay_ms" || gt0 "$jitter_ms" || gt0 "$loss"; then
        # 双向都建 class（若尚未建立）
        ensure_device_class "$iface"     "$class_id" "$ip"
        ensure_device_class "$IFB_IFACE" "$class_id" "$ip"
        # 只修改 leaf netem,不动 class rate
        set_netem_only "$iface"     "$class_id" "$delay_ms" "$jitter_ms" "$loss"
        set_netem_only "$IFB_IFACE" "$class_id" "$delay_ms" "$jitter_ms" "$loss"
        log "  Netem applied: ${delay_ms}ms jitter=${jitter_ms}ms loss=${loss}% (both dirs)"
    else
        # 关延迟：把 leaf netem 重置为无延迟，class 及 rate 不动
        if class_exists "$iface" "$class_id"; then
            set_netem_only "$iface" "$class_id" 0 0 0
            log "  Delay cleared on $iface 1:$class_id (class+rate preserved)"
        fi
        if class_exists "$IFB_IFACE" "$class_id"; then
            set_netem_only "$IFB_IFACE" "$class_id" 0 0 0
            log "  Delay cleared on $IFB_IFACE 1:$class_id (class+rate preserved)"
        fi
    fi
}

set_all() { set_limit "$1" "$2" "$3" "$4" "${8:-}"; set_delay "$1" "$2" "$5" "${6:-0}" "${7:-0}" "${8:-}"; }

# ─── 移除设备所有规则 ────────────────────────────────────────
remove_device() {
    local iface=$1 mark_id=$2
    local class_id; class_id=$(printf "%d" "$mark_id")
    local mark; mark=$(printf "0x%x" $((0x800000 + mark_id)))
    local prio=$((FILTER_PRIO_BASE + class_id))
    for dev in "$iface" "$IFB_IFACE"; do
        tc filter del dev "$dev" parent 1: prio "$prio"         2>/dev/null || true
        tc filter del dev "$dev" parent 1: prio "$((prio+1))"   2>/dev/null || true
        tc filter del dev "$dev" parent 1: pref "$FILTER_PRIO_FW" handle "$mark" fw 2>/dev/null || true
        tc qdisc del dev "$dev" parent "1:$class_id" 2>/dev/null || true
        tc class del dev "$dev" classid "1:$class_id" 2>/dev/null || true
    done
    log "Removed TC rules: mark_id=$mark_id"
}

# ─── 恢复持久化规则 ──────────────────────────────────────────
# v3.4.1：彻底移除 python3 依赖。改用纯 awk 解析 rules.json，
# 正确处理浮点数（v3.3.6 用 grep `[0-9]*` 会把 0.8 截断为 0 这种祖传 bug
# 已经修复，但仍依赖 python3。某些精简 ROM 没有 python3，restore 直接静默
# 失败，看起来"重启后规则丢了"。现在用 awk 一遍解析整个 MAC block，
# 输出 mark_id|ip|down|up|delay|jitter 格式。）
restore_rules() {
    log "Restoring rules from $RULES_FILE"
    [ -f "$RULES_FILE" ] || return 0
    local iface; iface=$(sh "$HNC_DIR/bin/device_detect.sh" iface)

    # 提取所有设备 MAC（只匹配 devices 对象里有 mark_id 的条目）
    local macs; macs=$(grep -oE '"([0-9a-f]{2}:){5}[0-9a-f]{2}"' "$RULES_FILE" | tr -d '"' | sort -u)
    for mac in $macs; do
        # v3.4.1：纯 awk 解析。先在 rules.json 里定位 "mac": { ... } 块，
        # 然后从块里逐字段抽 mark_id/ip/down_mbps/up_mbps/delay_ms/jitter_ms。
        # 不依赖 python3，浮点数原样保留。
        local fields; fields=$(awk -v mac="$mac" '
        {
            pat = "\"" mac "\"[[:space:]]*:[[:space:]]*\\{"
            if (match($0, pat)) {
                start = RSTART + RLENGTH
                depth = 1
                i = start
                while (i <= length($0) && depth > 0) {
                    c = substr($0, i, 1)
                    if (c == "{") depth++
                    else if (c == "}") depth--
                    i++
                }
                block = substr($0, start, i - start - 1)
                mark_id = ""; ip = ""; down = "0"; up = "0"; delay = "0"; jitter = "0"
                n = split(block, parts, ",")
                for (j = 1; j <= n; j++) {
                    if (match(parts[j], /"mark_id"[[:space:]]*:[[:space:]]*[0-9]+/)) {
                        s = substr(parts[j], RSTART, RLENGTH)
                        sub(/.*:[[:space:]]*/, "", s); mark_id = s
                    } else if (match(parts[j], /"ip"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
                        s = substr(parts[j], RSTART, RLENGTH)
                        sub(/.*:[[:space:]]*"/, "", s); sub(/"$/, "", s); ip = s
                    } else if (match(parts[j], /"down_mbps"[[:space:]]*:[[:space:]]*[0-9.]+/)) {
                        s = substr(parts[j], RSTART, RLENGTH)
                        sub(/.*:[[:space:]]*/, "", s); down = s
                    } else if (match(parts[j], /"up_mbps"[[:space:]]*:[[:space:]]*[0-9.]+/)) {
                        s = substr(parts[j], RSTART, RLENGTH)
                        sub(/.*:[[:space:]]*/, "", s); up = s
                    } else if (match(parts[j], /"delay_ms"[[:space:]]*:[[:space:]]*[0-9.]+/)) {
                        s = substr(parts[j], RSTART, RLENGTH)
                        sub(/.*:[[:space:]]*/, "", s); delay = s
                    } else if (match(parts[j], /"jitter_ms"[[:space:]]*:[[:space:]]*[0-9.]+/)) {
                        s = substr(parts[j], RSTART, RLENGTH)
                        sub(/.*:[[:space:]]*/, "", s); jitter = s
                    }
                }
                if (mark_id != "") {
                    print mark_id "|" ip "|" down "|" up "|" delay "|" jitter
                    exit
                }
            }
        }' "$RULES_FILE")
        [ -z "$fields" ] && continue

        local mark_id; mark_id=$(echo "$fields" | cut -d'|' -f1)
        local ip;      ip=$(echo      "$fields" | cut -d'|' -f2)
        local down;    down=$(echo    "$fields" | cut -d'|' -f3)
        local up;      up=$(echo      "$fields" | cut -d'|' -f4)
        local delay;   delay=$(echo   "$fields" | cut -d'|' -f5)
        local jitter;  jitter=$(echo  "$fields" | cut -d'|' -f6)
        [ -z "$mark_id" ] && continue

        log "Restoring: $mac mark=$mark_id ip=$ip dn=${down}M up=${up}M delay=${delay}ms"
        sh "$HNC_DIR/bin/iptables_manager.sh" mark "$ip" "$mac" "$mark_id"
        set_all "$iface" "$mark_id" "${down:-0}" "${up:-0}" "${delay:-0}" "${jitter:-0}" "0" "$ip"
    done

    # 恢复黑名单
    local in_bl=0
    while IFS= read -r line; do
        echo "$line" | grep -q '"blacklist"' && in_bl=1
        [ $in_bl -eq 1 ] && echo "$line" | grep -q '\]' && in_bl=0
        if [ $in_bl -eq 1 ]; then
            local bl_mac; bl_mac=$(echo "$line" | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}')
            [ -n "$bl_mac" ] && sh "$HNC_DIR/bin/iptables_manager.sh" blacklist_add "" "$bl_mac"
        fi
    done < "$RULES_FILE"
    log "Restore complete"
}

# ─── 状态 / 清理 ─────────────────────────────────────────────
show_status() {
    local iface=${1:-$(sh "$HNC_DIR/bin/device_detect.sh" iface)}
    echo "=== Egress TC: $iface ===" && tc qdisc show dev "$iface"
    tc class show dev "$iface" && echo "--- Filters ---" && tc filter show dev "$iface"
    echo "" && echo "=== Ingress TC (ifb0) ===" && tc qdisc show dev "$IFB_IFACE"
    tc class show dev "$IFB_IFACE" && echo "--- Filters ---" && tc filter show dev "$IFB_IFACE"
    echo "" && echo "--- Redirect filter on $iface ---" && tc filter show dev "$iface" parent ffff:
}

cleanup_tc() {
    local iface=${1:-$(sh "$HNC_DIR/bin/device_detect.sh" iface)}
    tc qdisc del dev "$iface" root    2>/dev/null || true
    tc qdisc del dev "$iface" ingress 2>/dev/null || true
    tc qdisc del dev "$IFB_IFACE" root 2>/dev/null || true
    ip link set dev "$IFB_IFACE" down 2>/dev/null || true
    ip link del "$IFB_IFACE" 2>/dev/null || true
    log "TC cleanup done"
}

# ─── 命令分发 ────────────────────────────────────────────────
case "$1" in
    init)       init_tc "$2" ;;
    set_limit)  set_limit "$2" "$3" "$4" "$5" "$6" ;;
    set_delay)  set_delay "$2" "$3" "$4" "$5" "$6" "$7" ;;
    set_all)    set_all   "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" ;;
    remove)     remove_device "$2" "$3" ;;
    restore)    restore_rules ;;
    status)     show_status "$2" ;;
    cleanup)    cleanup_tc "$2" ;;
    *)
        echo "Usage: tc_manager.sh {init|set_limit|set_delay|set_all|remove|restore|status|cleanup}"
        echo ""
        echo "验证限速命令："
        echo "  tc qdisc show dev \$IFACE"
        echo "  tc class show dev \$IFACE"
        echo "  tc filter show dev \$IFACE"
        echo "  tc filter show dev ifb0"
        echo "  tc -s class show dev ifb0      # 查看上传流量字节数"
        echo "  iptables -t mangle -L HNC_MARK -nv"
        exit 1 ;;
esac
