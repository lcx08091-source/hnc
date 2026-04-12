#!/system/bin/sh

# v3.5.0 alpha-0: PATH 健壮性,见 service.sh
[ -z "$HNC_SKIP_PATH_HARDENING" ] && [ -z "$HNC_TEST_MODE" ] && export PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
# json_set.sh — 纯 Shell JSON 字段更新工具，不依赖 python3
#
# 用法:
#   json_set.sh device  <mac> <field> <value>   # 更新 .devices[mac][field]
#   json_set.sh bl_add  <mac>                   # 加入 blacklist
#   json_set.sh bl_del  <mac>                   # 从 blacklist 删除
#   json_set.sh reset                           # 清空 devices 和 blacklist
#
# 原理：用 awk 直接做文本替换，适用于我们固定格式的 rules.json
# rules.json 格式固定可预测，不需要通用 JSON 解析器

HNC=${HNC:-/data/local/hnc}
RULES=$HNC/data/rules.json
TMP=$HNC/data/rules.tmp

# ═══════════════════════════════════════════════════════════════
# v3.4.11 P0-2 修复:加 mkdir 文件锁,防并发写竞态
#
# 之前的问题:
#   - 所有写命令(top/device/bl_add/bl_del/reset/cfg_set/name_*)都用
#     `awk ... > "$TMP" && mv "$TMP" "$RULES"`,共用同一个 $TMP
#   - 两个并发 shell 同时写 → 第二个 mv 用半写完的临时文件覆盖 → JSON 破损
#   - shUpdate 串行 5 次 kexec 写 5 个字段,user 快速点击两次"应用"或
#     setTimeout(doRefresh, 100) 跟 user 点击交错 → 触发竞态
#
# 修复:用 mkdir 原子操作做锁(POSIX 标准,所有 ash/busybox 都支持),
# 5 秒超时(50 × 100ms)。trap 退出时自动释放。
# ═══════════════════════════════════════════════════════════════
LOCKDIR=$HNC/run/json.lock
mkdir -p $HNC/run 2>/dev/null

# v3.4.11 内部加固:sleep 0.1 在 busybox ash 不一定支持小数,
# 改用 usleep(支持微秒,busybox 大部分版本有)。usleep 也失败则 fall back
# 到 sleep 1(慢 10 倍但能用)。同时加陈旧锁检测:
# 如果锁目录存在超过 10 秒(可能是上次崩溃没释放),强制清掉再重试。
_short_sleep() {
    usleep 100000 2>/dev/null && return 0
    sleep 1
}

# 检测并清除陈旧锁:见 acquire_lock 内部的 force_break 机制
# (之前用 stat -c %Y 但 Android busybox 不一定有 stat 命令,
#  改用循环计数法 — 第 20 次重试时如果还卡着就强制清,等价于"卡 2 秒就当陈旧锁")

acquire_lock() {
    local i=0
    local force_break=20  # 第 20 次重试时(=2 秒)如果还卡着,认为是陈旧锁
    while [ $i -lt 50 ]; do
        if mkdir "$LOCKDIR" 2>/dev/null; then
            trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM
            return 0
        fi
        # 第 20 次重试时如果还在卡(=已经等 2 秒),强制清掉陈旧锁
        if [ $i -eq $force_break ]; then
            rmdir "$LOCKDIR" 2>/dev/null
            echo "json_set: force-break stale lock at retry $i" >&2
        fi
        _short_sleep
        i=$((i+1))
    done
    return 1
}
release_lock() { rmdir "$LOCKDIR" 2>/dev/null; }

# ═══════════════════════════════════════════════════════════════
# v3.3.0 新增：统一的 JSON 值编码函数
# 规则：
#   - true / false / null → 原样（JSON 字面量）
#   - 严格数字（整数或浮点，可带负号）→ 原样
#   - 其他一律当字符串 → 加 JSON 双引号
#
# 关键修复：原实现 `*[!0-9.-]*` 允许 "192.168.1.5" 当数字，
# 导致 IP 写入 JSON 时不带引号，破坏 JSON 格式。
# ═══════════════════════════════════════════════════════════════
json_encode() {
    local v=$1
    case "$v" in
        true|false|null)
            echo "$v" ;;
        '')
            echo '""' ;;
        *)
            # 严格数字匹配：可选负号 + 整数 + 可选小数部分
            if echo "$v" | grep -qE '^-?[0-9]+(\.[0-9]+)?$'; then
                echo "$v"
            else
                # 转义内嵌的双引号和反斜杠，避免破坏 JSON
                local esc
                esc=$(printf '%s' "$v" | sed 's/\\/\\\\/g; s/"/\\"/g')
                echo "\"$esc\""
            fi
            ;;
    esac
}

# 确保目录和文件存在
mkdir -p $HNC/data
[ -f $RULES ] || cat > $RULES << 'EOF'
{"version":1,"whitelist_mode":false,"devices":{},"blacklist":[],"whitelist":[]}
EOF

# v3.4.6: device_names.json 路径与初始化
NAMES_FILE=$HNC/data/device_names.json
ensure_names_file() {
    [ -f "$NAMES_FILE" ] || echo '{}' > "$NAMES_FILE"
}

CMD=$1

# v3.4.11 P0-2: 写命令统一加锁,读命令不加锁(避免阻塞 cfg_get / name_get)
# 注意:device_patch 不在此列表 — 它内部递归调 `sh "$0" device`,
# device 命令本身会 acquire_lock,加在外层会自己跟自己抢锁导致 5 秒超时回归
case "$CMD" in
    top|device|bl_add|bl_del|reset|cfg_set|name_set|name_del)
        acquire_lock || { echo "json_set: lock timeout (5s)" >&2; exit 2; }
        ;;
esac

# ── 原子写入：先写临时文件，再 mv ──────────────────────────
atomic_write() {
    mv "$TMP" "$RULES"
}

case "$CMD" in

# ── 更新顶层字段（hotspot_auto / whitelist_mode 等）────────
# v3.3.0 修复：
#   1) 原 awk 正则 `($0 ~ """ field """)` 被 shell+awk 解析为字面量 " field "，
#      根本不引用 field 变量，匹配永远失败
#   2) 原字符串分支 JVAL=""$VALUE"" 经 shell 合并后等于 $VALUE，JSON 里写出裸串
#   3) 原实现只替换已存在字段；若字段不存在则无效。现补上“插入”分支
top)
    FIELD=$2; VALUE=$3
    JVAL=$(json_encode "$VALUE")

    if grep -q "\"$FIELD\"[[:space:]]*:" "$RULES" 2>/dev/null; then
        # 字段已存在：精确替换该字段的值
        # 关键：单行 JSON 不能用 line-sub，否则会替换到文件里第一个字段
        awk -v field="$FIELD" -v val="$JVAL" '
        {
            pat="\"" field "\"[[:space:]]*:[[:space:]]*[^,}]*"
            rep="\"" field "\": " val
            gsub(pat, rep)
            print
        }' "$RULES" > "$TMP" && atomic_write
    else
        # 字段不存在：在首层对象的 "{" 之后插入
        awk -v field="$FIELD" -v val="$JVAL" '
        BEGIN { depth=0; inserted=0 }
        {
            if (!inserted) {
                n=split($0,chars,"")
                for(i=1;i<=n;i++){
                    if(chars[i]=="{") {
                        depth++
                        if(depth==1) {
                            # 在这一行的 "{" 后插入新字段
                            pre=substr($0,1,i)
                            post=substr($0,i+1)
                            # 若 "{" 后紧接 "}"（空对象），新字段不需要逗号
                            if (post ~ /^[[:space:]]*\}/) {
                                $0 = pre "\"" field "\": " val post
                            } else {
                                $0 = pre "\"" field "\": " val "," post
                            }
                            inserted=1
                            break
                        }
                    }
                }
            }
            print
        }' "$RULES" > "$TMP" && atomic_write
    fi
    ;;

# ── 更新设备字段 ──────────────────────────────────────────
device)
    MAC=$2; FIELD=$3; VALUE=$4
    JVAL=$(json_encode "$VALUE")

    # 检查 devices 里有没有这个 MAC 的条目
    if grep -q "\"$MAC\"[[:space:]]*:[[:space:]]*{" "$RULES" 2>/dev/null; then
        # MAC 存在：尝试更新或插入字段
        # v3.3.0：改用 match/substr 按 MAC 块精确定位，支持单行/多行 JSON
        if grep -oE "\"$MAC\"[[:space:]]*:[[:space:]]*\{[^}]*\"$FIELD\"[[:space:]]*:" "$RULES" >/dev/null 2>&1; then
            # 字段存在：在 MAC 块内替换
            awk -v mac="$MAC" -v field="$FIELD" -v val="$JVAL" '
            {
                line=$0
                mac_pat="\"" mac "\"[[:space:]]*:[[:space:]]*\\{[^}]*\\}"
                if (match(line, mac_pat)) {
                    block=substr(line, RSTART, RLENGTH)
                    rest =substr(line, RSTART+RLENGTH)
                    pre  =substr(line, 1, RSTART-1)
                    fpat ="\"" field "\"[[:space:]]*:[[:space:]]*[^,}]*"
                    frep ="\"" field "\": " val
                    gsub(fpat, frep, block)
                    print pre block rest
                } else {
                    print line
                }
            }' "$RULES" > "$TMP" && atomic_write
        else
            # 字段不存在：在 MAC 块的 "{" 后插入新字段
            awk -v mac="$MAC" -v field="$FIELD" -v val="$JVAL" '
            {
                line=$0
                mac_pat="\"" mac "\"[[:space:]]*:[[:space:]]*\\{"
                if (match(line, mac_pat)) {
                    brace_end=RSTART+RLENGTH
                    pre =substr(line, 1, brace_end-1)
                    post=substr(line, brace_end)
                    if (post ~ /^[[:space:]]*\}/) {
                        line = pre "\"" field "\": " val post
                    } else {
                        line = pre "\"" field "\": " val "," post
                    }
                }
                print line
            }' "$RULES" > "$TMP" && atomic_write
        fi
    else
        # MAC 不存在：在 "devices": { 后插入新条目
        awk -v mac="$MAC" -v field="$FIELD" -v val="$JVAL" '
        {
            line=$0
            if (match(line, /"devices"[[:space:]]*:[[:space:]]*\{/)) {
                brace_end=RSTART+RLENGTH
                pre =substr(line, 1, brace_end-1)
                post=substr(line, brace_end)
                new_entry="\"" mac "\": {\"" field "\": " val "}"
                if (post ~ /^[[:space:]]*\}/) {
                    # 空 devices 对象
                    line = pre new_entry post
                } else {
                    line = pre new_entry "," post
                }
            }
            print line
        }' "$RULES" > "$TMP" && atomic_write
    fi
    ;;

# ── 批量更新设备多个字段（从 stdin 读 JSON patch）─────────
device_patch)
    MAC=$2
    # 从第3个参数起读取 key=value 对
    shift 2
    TMPJSON="{}"
    while [ $# -ge 2 ]; do
        K=$1; V=$2; shift 2
        JVAL=$(json_encode "$V")
        TMPJSON=$(echo "$TMPJSON" | sed "s/}$/,\"$K\":$JVAL}/")
        # 修复开头的 {, → {
        TMPJSON=$(echo "$TMPJSON" | sed 's/^{,/{/')
    done
    # 逐字段调用 device 更新
    echo "$TMPJSON" | tr ',' '\n' | grep ':' | while IFS=: read -r k v; do
        k=$(echo $k | tr -d '" {}')
        v=$(echo $v | tr -d ' {}')
        sh "$0" device "$MAC" "$k" "$v"
    done
    ;;

# ── 加入黑名单 ────────────────────────────────────────────
# v3.3.0 修复：
#   原实现 gsub(/\]/, ...) 会替换文件中所有的 ]，单行 JSON 下
#   把 whitelist 和 blacklist 一起污染了。改用 match+substr 精确
#   定位 "blacklist":[...] 范围。
bl_add)
    MAC=$2
    # 已在黑名单则不重复添加
    grep -oE "\"blacklist\"[[:space:]]*:[[:space:]]*\[[^]]*\"$MAC\"" "$RULES" >/dev/null 2>&1 && exit 0

    awk -v mac="$MAC" '
    {
        line=$0
        pat="\"blacklist\"[[:space:]]*:[[:space:]]*\\[[^]]*\\]"
        if (match(line, pat)) {
            block=substr(line, RSTART, RLENGTH)
            pre  =substr(line, 1, RSTART-1)
            rest =substr(line, RSTART+RLENGTH)
            # 空数组：[]  → ["mac"]
            if (block ~ /\[[[:space:]]*\]$/) {
                sub(/\[[[:space:]]*\]$/, "[\"" mac "\"]", block)
            } else {
                # 非空：在末尾 ] 前追加 ,"mac"
                sub(/\]$/, ",\"" mac "\"]", block)
            }
            line = pre block rest
        }
        print line
    }' "$RULES" > "$TMP" && atomic_write
    ;;

# ── 从黑名单删除 ──────────────────────────────────────────
# v3.3.0 修复：原 gsub 不加范围限制，会把 devices 块里同 MAC 的键也删掉
bl_del)
    MAC=$2
    awk -v mac="$MAC" '
    {
        line=$0
        pat="\"blacklist\"[[:space:]]*:[[:space:]]*\\[[^]]*\\]"
        if (match(line, pat)) {
            block=substr(line, RSTART, RLENGTH)
            pre  =substr(line, 1, RSTART-1)
            rest =substr(line, RSTART+RLENGTH)
            # 删除 "mac", 或 ,"mac" 或独立 "mac"
            gsub("\"" mac "\",", "", block)
            gsub(",\"" mac "\"", "", block)
            gsub("\"" mac "\"", "", block)
            line = pre block rest
        }
        print line
    }' "$RULES" > "$TMP" && atomic_write
    ;;

# ── 清空所有规则 ──────────────────────────────────────────
reset)
    cat > "$RULES" << 'EOF'
{"version":1,"whitelist_mode":false,"devices":{},"blacklist":[],"whitelist":[]}
EOF
    ;;

# ── 初始化目录结构 ────────────────────────────────────────
init_dirs)
    mkdir -p $HNC/{bin,api,webroot,data,logs,run}
    chmod 755 $HNC $HNC/bin $HNC/api $HNC/webroot $HNC/data $HNC/logs $HNC/run
    [ -f $RULES ] || cat > $RULES << 'EOF'
{"version":1,"whitelist_mode":false,"devices":{},"blacklist":[],"whitelist":[]}
EOF
    chmod 644 $RULES
    echo "HNC dirs initialized"
    ;;

# ── 写入 config.json 字段 ────────────────────────────────────
cfg_set)
    KEY=$2; VAL=$3
    CFG=$HNC/data/config.json
    [ -f "$CFG" ] || echo '{}' > "$CFG"
    JVAL=$(json_encode "$VAL")
    if grep -q "\"$KEY\"" "$CFG" 2>/dev/null; then
        sed -i "s|\"$KEY\"[[:space:]]*:[[:space:]]*[^,}]*|\"$KEY\": $JVAL|g" "$CFG"
    else
        sed -i "s|}$|,\"$KEY\": $JVAL}|" "$CFG"
    fi
    echo "ok"
    ;;

# ── 读取 config.json 字段 ────────────────────────────────────
# v3.3.0 修复：原 sed 's/.*: *//' 是贪婪匹配，对 "22:00" 这种
# 含冒号的值会把 "22:" 也当分隔符吃掉，返回 "00"。
# 改用只匹配到第一个冒号的版本。
cfg_get)
    KEY=$2
    CFG=$HNC/data/config.json
    grep -o "\"$KEY\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$CFG" 2>/dev/null \
        | head -1 | sed 's/^[^:]*:[[:space:]]*//; s/^"//; s/"$//' && exit 0
    grep -o "\"$KEY\"[[:space:]]*:[[:space:]]*[^,}[:space:]]*" "$CFG" 2>/dev/null \
        | head -1 | sed 's/^[^:]*:[[:space:]]*//'
    ;;

# ── 读取 rules.json 顶层字段（v3.3.0 新增）──────────────────
top_get)
    KEY=$2
    # 先尝试字符串字段（带引号），取引号内的完整内容
    result=$(grep -o "\"$KEY\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$RULES" 2>/dev/null \
        | head -1 | sed 's/^[^:]*:[[:space:]]*"//; s/"$//')
    if [ -n "$result" ]; then
        echo "$result"
    else
        # 数字/布尔字段
        grep -o "\"$KEY\"[[:space:]]*:[[:space:]]*[^,}[:space:]]*" "$RULES" 2>/dev/null \
            | head -1 | sed 's/^[^:]*:[[:space:]]*//'
    fi
    ;;

# ═══════════════════════════════════════════════════════════════
# v3.4.6: 设备手动命名 (data/device_names.json)
# ═══════════════════════════════════════════════════════════════
# 文件格式（单行 JSON,扁平 MAC -> name 映射）:
#   {"e2:0d:4a:48:5d:40":"Mi-10","aa:bb:cc:dd:ee:ff":"客厅打印机"}
#
# 子命令:
#   name_set  <mac> <name>   设置或更新设备名
#   name_get  <mac>          获取设备名(找不到则空)
#   name_del  <mac>          删除条目
#   name_list                打印整个文件(供调试)
#
# 这是 v3.4.6 设备命名功能的"路线 A":手动命名,优先级最高,
# 永远凌驾于 mDNS 自动发现 / DHCP lease / MAC 兜底之上。
# ═══════════════════════════════════════════════════════════════

name_set)
    MAC=$2; NAME=$3
    [ -z "$MAC" ] && { echo "name_set: mac required" >&2; exit 1; }
    [ -z "$NAME" ] && { echo "name_set: name required" >&2; exit 1; }
    ensure_names_file

    # 转小写 mac
    MAC=$(echo "$MAC" | tr 'A-Z' 'a-z')

    # JSON 编码 name(转义反斜杠和双引号 + 去控制字符)
    # v3.4.11 P0-5/P0-6 修复:
    #   1) tr -d 去掉控制字符,跟 device_detect.sh 一致
    #   2) 不用 awk -v(避免 awk 二次解析反斜杠把 JSON escape 撤销)
    # v3.5.0 alpha-2 修复:
    #   原 v3.4.11 用 `getline pair < "/dev/stdin"; close("/dev/stdin")`,
    #   在某些 awk 实现(mawk / 老 gawk / busybox awk)上 close("/dev/stdin")
    #   会段错误。改用临时文件传 NEW_PAIR,awk 用 getline 从文件读,
    #   兼容所有 awk 实现。
    NAME_ESC=$(printf '%s' "$NAME" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
    NEW_PAIR="\"$MAC\":\"$NAME_ESC\""
    PAIR_TMP="${NAMES_FILE}.pair.$$"
    printf '%s' "$NEW_PAIR" > "$PAIR_TMP"

    # 用 awk 替换或插入,通过文件传 NEW_PAIR(awk 不会二次解析文件内容)
    awk -v mac="$MAC" -v pairfile="$PAIR_TMP" '
    BEGIN { getline pair < pairfile }
    {
        # 检查 "mac": 是否已存在
        pat = "\"" mac "\":\"[^\"]*\""
        if (match($0, pat)) {
            # 替换已有 entry
            $0 = substr($0, 1, RSTART-1) pair substr($0, RSTART+RLENGTH)
        } else {
            # 插入新 entry
            if ($0 ~ /^\{\}[[:space:]]*$/) {
                # 空对象 -> {"mac":"name"}
                $0 = "{" pair "}"
            } else {
                # 非空对象 -> 在末尾 } 前插入 ,"mac":"name"
                sub(/\}[[:space:]]*$/, "," pair "}", $0)
            }
        }
        print
    }
    ' "$NAMES_FILE" > "${NAMES_FILE}.tmp" && mv "${NAMES_FILE}.tmp" "$NAMES_FILE"
    rm -f "$PAIR_TMP"
    ;;

name_get)
    MAC=$2
    [ -z "$MAC" ] && exit 0
    [ -f "$NAMES_FILE" ] || exit 0
    MAC=$(echo "$MAC" | tr 'A-Z' 'a-z')
    # 提取 "mac":"name" 中的 name
    grep -o "\"$MAC\":\"[^\"]*\"" "$NAMES_FILE" 2>/dev/null \
        | head -1 \
        | sed "s/^\"$MAC\":\"//; s/\"$//"
    ;;

name_del)
    MAC=$2
    [ -z "$MAC" ] && exit 0
    [ -f "$NAMES_FILE" ] || exit 0
    MAC=$(echo "$MAC" | tr 'A-Z' 'a-z')

    awk -v mac="$MAC" '
    {
        pat = "\"" mac "\":\"[^\"]*\""
        # 删除条目以及前后的逗号(如果有)
        # 三种位置:中间 (前后都有逗号)、开头 (后跟逗号)、末尾 (前面有逗号)
        gsub(",?" pat ",?", ",", $0)
        # 清理可能产生的 ,, -> ,
        gsub(/,,/, ",", $0)
        # 清理可能产生的 {, -> {
        gsub(/\{,/, "{", $0)
        # 清理可能产生的 ,} -> }
        gsub(/,\}/, "}", $0)
        print
    }
    ' "$NAMES_FILE" > "${NAMES_FILE}.tmp" && mv "${NAMES_FILE}.tmp" "$NAMES_FILE"
    ;;

name_list)
    ensure_names_file
    cat "$NAMES_FILE"
    ;;

*)
    echo "Usage: json_set.sh {device|bl_add|bl_del|reset|init_dirs|cfg_set|cfg_get|top|top_get|name_set|name_get|name_del|name_list} [args...]"
    exit 1
    ;;
esac
