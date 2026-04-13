#!/system/bin/sh

# v3.6.3 alpha-0: PATH 健壮性,见 service.sh
[ -z "$HNC_SKIP_PATH_HARDENING" ] && [ -z "$HNC_TEST_MODE" ] && export PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
# diag.sh — HNC v3.6.3 自检脚本
#
# 用法:
#   sh /data/local/hnc/bin/diag.sh
#   sh /data/local/hnc/bin/diag.sh --json     # 输出 JSON 格式
#
# 检查 12 项核心系统状态,每项 OK / FAIL / WARN,
# 帮助快速定位问题。LTS 版本必备的故障排查工具。
#
# 退出码:
#   0 = 全部 OK
#   1 = 有 FAIL
#   2 = 有 WARN(非致命但需注意)

HNC=${HNC:-/data/local/hnc}
JSON_MODE=0
[ "$1" = "--json" ] && JSON_MODE=1

# ── 输出辅助 ────────────────────────────────────────────
PASS=0
WARN=0
FAIL=0
RESULTS=""

ok()   { PASS=$((PASS+1)); RESULTS="$RESULTS$1|OK|$2
"; [ $JSON_MODE -eq 0 ] && printf '  \033[32m✓\033[0m %-22s %s\n' "$1" "$2"; }
warn() { WARN=$((WARN+1)); RESULTS="$RESULTS$1|WARN|$2
"; [ $JSON_MODE -eq 0 ] && printf '  \033[33m!\033[0m %-22s %s\n' "$1" "$2"; }
fail() { FAIL=$((FAIL+1)); RESULTS="$RESULTS$1|FAIL|$2
"; [ $JSON_MODE -eq 0 ] && printf '  \033[31m✗\033[0m %-22s %s\n' "$1" "$2"; }

[ $JSON_MODE -eq 0 ] && {
    echo ""
    echo "  HNC v3.6.3 自检"
    echo "  ──────────────────────────────────────────────"
}

# ── [1/12] HNC 安装目录 ──────────────────────────────────
if [ -d "$HNC" ]; then
    if [ -d "$HNC/bin" ] && [ -d "$HNC/data" ] && [ -f "$HNC/module.prop" ]; then
        VER=$(grep "^version=" "$HNC/module.prop" | cut -d= -f2)
        ok "安装目录" "$HNC ($VER)"
    else
        fail "安装目录" "$HNC 存在但缺关键子目录"
    fi
else
    fail "安装目录" "$HNC 不存在"
fi

# ── [2/12] 关键脚本 ──────────────────────────────────────
MISSING=""
for f in device_detect.sh iptables_manager.sh tc_manager.sh json_set.sh watchdog.sh; do
    [ -f "$HNC/bin/$f" ] || MISSING="$MISSING $f"
done
if [ -z "$MISSING" ]; then
    ok "shell 脚本" "5 个核心脚本就位"
else
    fail "shell 脚本" "缺失:$MISSING"
fi

# ── [3/12] mdns_resolve 二进制 ──────────────────────────
if [ -x "$HNC/bin/mdns_resolve" ]; then
    SIZE=$(stat -c %s "$HNC/bin/mdns_resolve" 2>/dev/null || echo 0)
    if [ "$SIZE" -gt 100000 ]; then
        ok "mDNS 工具" "二进制存在 (${SIZE} bytes)"
    else
        warn "mDNS 工具" "文件存在但尺寸异常 (${SIZE} bytes)"
    fi
else
    warn "mDNS 工具" "未安装,自动命名功能不可用"
fi

# ── [4/12] iptables 链 ──────────────────────────────────
HAS_MARK=0; HAS_LIMIT_DOWN=0; HAS_LIMIT_UP=0; HAS_STATS=0
iptables -t mangle -L HNC_MARK -n >/dev/null 2>&1 && HAS_MARK=1
iptables -t mangle -L HNC_LIMIT_DOWN -n >/dev/null 2>&1 && HAS_LIMIT_DOWN=1
iptables -t mangle -L HNC_LIMIT_UP -n >/dev/null 2>&1 && HAS_LIMIT_UP=1
iptables -t mangle -L HNC_STATS -n >/dev/null 2>&1 && HAS_STATS=1
SUM=$((HAS_MARK + HAS_LIMIT_DOWN + HAS_LIMIT_UP + HAS_STATS))
if [ "$SUM" -eq 4 ]; then
    ok "iptables 链" "4 个 HNC 链都存在"
elif [ "$SUM" -gt 0 ]; then
    warn "iptables 链" "$SUM/4 存在,可能未完全初始化"
else
    fail "iptables 链" "0/4 — HNC 后端未运行"
fi

# ── [5/12] tc qdisc ─────────────────────────────────────
IFACE=$(sh "$HNC/bin/device_detect.sh" iface 2>/dev/null)
if [ -n "$IFACE" ]; then
    if tc qdisc show dev "$IFACE" 2>/dev/null | grep -q "htb"; then
        ok "tc qdisc" "htb 已附加到 $IFACE"
    else
        warn "tc qdisc" "$IFACE 上没有 htb (限速未启用?)"
    fi
else
    warn "tc qdisc" "无法识别热点 iface"
fi

# ── [6/12] watchdog 进程 ────────────────────────────────
WD_COUNT=$(pgrep -f "watchdog.sh" 2>/dev/null | wc -l)
if [ "$WD_COUNT" -gt 0 ]; then
    WD_PID=$(pgrep -f "watchdog.sh" 2>/dev/null | head -1)
    ok "watchdog" "运行中 (pid=$WD_PID)"
else
    warn "watchdog" "未运行(可能未启用自启)"
fi

# ── [7/12] 数据文件 ──────────────────────────────────────
RULES_COUNT=0
DEV_COUNT=0
NAMES_COUNT=0
[ -f "$HNC/data/rules.json" ] && RULES_COUNT=$(grep -c '"mark_id"' "$HNC/data/rules.json" 2>/dev/null || echo 0)
[ -f "$HNC/data/devices.json" ] && DEV_COUNT=$(grep -oE '"[0-9a-f:]{17}"' "$HNC/data/devices.json" 2>/dev/null | wc -l)
[ -f "$HNC/data/device_names.json" ] && NAMES_COUNT=$(grep -oE '"[0-9a-f:]{17}":' "$HNC/data/device_names.json" 2>/dev/null | wc -l)
ok "数据文件" "rules=$RULES_COUNT 设备 / devices=$DEV_COUNT 在线 / names=$NAMES_COUNT 命名"

# ── [8/12] hostname 缓存 ────────────────────────────────
if [ -f "$HNC/run/hostname_cache" ]; then
    CACHE_LINES=$(wc -l < "$HNC/run/hostname_cache" 2>/dev/null || echo 0)
    ok "hostname 缓存" "$CACHE_LINES 条记录"
else
    warn "hostname 缓存" "未生成(扫描尚未运行?)"
fi

# ── [9/12] 数据备份(v3.4.9 新增) ────────────────────────
BACKUP_COUNT=$(ls -d "$HNC/data/.backup-"* 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt 0 ]; then
    LATEST=$(ls -dt "$HNC/data/.backup-"* 2>/dev/null | head -1 | sed "s|.*\.backup-||")
    ok "数据备份" "$BACKUP_COUNT 个备份,最近 $LATEST"
else
    warn "数据备份" "尚无备份(等下次开机自动创建)"
fi

# ── [10/12] 日志目录 ────────────────────────────────────
if [ -d "$HNC/logs" ]; then
    LOG_SIZE=$(du -sk "$HNC/logs" 2>/dev/null | awk '{print $1}')
    LOG_FILES=$(ls "$HNC/logs" 2>/dev/null | wc -l)
    if [ "${LOG_SIZE:-0}" -gt 10240 ]; then
        warn "日志目录" "$LOG_FILES 文件 / ${LOG_SIZE}K (超过 10MB,建议清理)"
    else
        ok "日志目录" "$LOG_FILES 文件 / ${LOG_SIZE:-0}K"
    fi
else
    warn "日志目录" "$HNC/logs 不存在"
fi

# ── [11/12] KSU 环境 ────────────────────────────────────
if [ -x /data/adb/ksu/bin/ksud ]; then
    KSU_VER=$(/data/adb/ksu/bin/ksud --version 2>/dev/null | head -1)
    ok "KSU 环境" "${KSU_VER:-detected}"
elif [ -x /data/adb/ksud ]; then
    ok "KSU 环境" "ksud 检测到"
else
    warn "KSU 环境" "未检测到 ksud (可能 Magisk 环境)"
fi

# ── [12/13] SELinux 模式 ─────────────────────────────────
SE_MODE=$(getenforce 2>/dev/null)
if [ "$SE_MODE" = "Enforcing" ]; then
    ok "SELinux" "Enforcing (正常)"
elif [ "$SE_MODE" = "Permissive" ]; then
    warn "SELinux" "Permissive (调试模式)"
else
    warn "SELinux" "无法读取状态"
fi

# ── [13/13] hotspotd 防误用检查(v3.4.11) ────────────────
# hotspotd 是 v3.5+ 实验功能,LTS 期不应启用。
# 如果 bin/hotspotd 二进制存在,WARN 提醒可能撞 P0-4/P1-2/P1-7/P1-8。
if [ -e "$HNC/bin/hotspotd" ]; then
    warn "hotspotd 防误用" "检测到 bin/hotspotd 存在!LTS 期不应启用,有 4 个已知 bug,见 daemon/README.md"
else
    ok "hotspotd 防误用" "未编译(LTS 默认状态)"
fi

# ── 汇总输出 ────────────────────────────────────────────
if [ $JSON_MODE -eq 1 ]; then
    # JSON 输出
    printf '{"version":"v3.6.3","pass":%d,"warn":%d,"fail":%d,"checks":[' "$PASS" "$WARN" "$FAIL"
    FIRST=1
    echo "$RESULTS" | while IFS='|' read -r name status detail; do
        [ -z "$name" ] && continue
        [ "$FIRST" = "1" ] || printf ','
        FIRST=0
        # 转义双引号
        ed=$(printf '%s' "$detail" | sed 's/"/\\"/g')
        printf '{"name":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$ed"
    done
    printf ']}\n'
else
    echo ""
    echo "  ──────────────────────────────────────────────"
    printf "  汇总: \033[32m%d OK\033[0m  \033[33m%d WARN\033[0m  \033[31m%d FAIL\033[0m\n" "$PASS" "$WARN" "$FAIL"
    if [ "$FAIL" -gt 0 ]; then
        echo ""
        echo "  ⚠ 检测到失败项,请查看上方 ✗ 标记"
        echo "  日志路径: $HNC/logs/"
        echo "  GitHub: 报 issue 时请附上本输出"
    elif [ "$WARN" -gt 0 ]; then
        echo ""
        echo "  ✓ 系统基本正常,有少量警告(非致命)"
    else
        echo ""
        echo "  ✓ 系统完全正常"
    fi
    echo ""
fi

# ── 退出码 ──────────────────────────────────────────────
[ "$FAIL" -gt 0 ] && exit 1
[ "$WARN" -gt 0 ] && exit 2
exit 0
