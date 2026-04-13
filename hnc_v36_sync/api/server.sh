#!/system/bin/sh
# server.sh — 纯Shell HTTP API服务器
# 使用 busybox nc (netcat) 或 socat 实现
# 端口: 8080 (可配置)
#
# API接口:
#   GET  /devices           — 获取所有热点设备
#   GET  /stats             — 获取流量统计
#   POST /limit             — 设置限速
#   POST /delay             — 设置延迟
#   POST /blacklist         — 黑名单管理
#   POST /whitelist         — 白名单管理
#   POST /whitelist_mode    — 白名单模式开关
#   GET  /status            — 服务状态
#   GET  /config            — 读取配置
#   POST /config            — 更新配置

HNC_DIR=/data/local/hnc
RULES_FILE=$HNC_DIR/data/rules.json
DEVICES_FILE=$HNC_DIR/data/devices.json
LOG=$HNC_DIR/logs/api.log
PORT=${1:-8080}
MODULE_PROP=$(dirname "$(dirname "$0")")/module.prop
VERSION=$(grep '^version=' "$MODULE_PROP" 2>/dev/null | cut -d= -f2 | tr -d 'v')
VERSION=${VERSION:-3.0.0}

log() { echo "[$(date '+%H:%M:%S')] [API] $1" >> $LOG; }

# ─── CORS + 公共响应头 ───────────────────────────────────────
cors_headers() {
    echo "Access-Control-Allow-Origin: *"
    echo "Access-Control-Allow-Methods: GET, POST, OPTIONS"
    echo "Access-Control-Allow-Headers: Content-Type"
}

# ─── HTTP 响应构建器 ─────────────────────────────────────────
# v3.3.0 修复：Content-Length 必须按字节计算，${#body} 在 UTF-8 locale
# 下返回字符数，中文/emoji 设备名会导致响应被浏览器截断
_byte_len() {
    printf '%s' "$1" | wc -c | tr -d ' '
}

http_ok() {
    local body=$1
    local len; len=$(_byte_len "$body")
    printf "HTTP/1.1 200 OK\r\n"
    printf "Content-Type: application/json; charset=utf-8\r\n"
    printf "Content-Length: %d\r\n" $len
    cors_headers | while read h; do printf "%s\r\n" "$h"; done
    printf "\r\n"
    printf "%s" "$body"
}

http_error() {
    local code=${1:-400}
    local msg=${2:-"Bad Request"}
    local body="{\"error\":\"$msg\"}"
    local len; len=$(_byte_len "$body")
    printf "HTTP/1.1 %d %s\r\n" $code "$msg"
    printf "Content-Type: application/json\r\n"
    printf "Content-Length: %d\r\n" $len
    printf "\r\n"
    printf "%s" "$body"
}

http_options() {
    printf "HTTP/1.1 204 No Content\r\n"
    cors_headers | while read h; do printf "%s\r\n" "$h"; done
    printf "\r\n"
}

http_html() {
    local file=$1
    local len=$(wc -c < $file)
    printf "HTTP/1.1 200 OK\r\n"
    printf "Content-Type: text/html; charset=utf-8\r\n"
    printf "Content-Length: %d\r\n" $len
    printf "\r\n"
    cat "$file"
}

http_static() {
    local file=$1
    local ext="${file##*.}"
    local ctype="text/plain"
    case $ext in
        css) ctype="text/css" ;;
        js)  ctype="application/javascript" ;;
        json) ctype="application/json" ;;
        png) ctype="image/png" ;;
        ico) ctype="image/x-icon" ;;
        svg) ctype="image/svg+xml" ;;
    esac
    local len=$(wc -c < $file 2>/dev/null || echo 0)
    printf "HTTP/1.1 200 OK\r\n"
    printf "Content-Type: %s\r\n" "$ctype"
    printf "Content-Length: %d\r\n" $len
    printf "Cache-Control: max-age=3600\r\n"
    printf "\r\n"
    cat "$file"
}

# ─── JSON工具函数 ────────────────────────────────────────────
json_field() {
    local json=$1
    local key=$2
    echo "$json" | grep -o "\"$key\":[^,}]*" | head -1 | \
        sed 's/.*: *//;s/"//g;s/[,}].*//'
}

json_str_field() {
    local json=$1
    local key=$2
    echo "$json" | grep -o "\"$key\":\"[^\"]*\"" | head -1 | \
        sed "s/\"$key\"://;s/\"//g"
}

# ─── 获取或分配设备 mark_id ──────────────────────────────────
get_or_assign_mark() {
    local mac=$1
    local existing=""

    # 优先用 jq 精确查找 .devices[mac].mark_id
    if command -v jq >/dev/null 2>&1; then
        existing=$(jq -r --arg m "$mac"             '.devices[$m].mark_id // empty' "$RULES_FILE" 2>/dev/null)
    fi

    # 回退：python3
    if [ -z "$existing" ] && command -v python3 >/dev/null 2>&1; then
        existing=$(python3 -c "
import json
try:
    d = json.load(open('$RULES_FILE'))
    v = d.get('devices', {}).get('$mac', {}).get('mark_id')
    if v is not None:
        print(int(v))
except: pass
" 2>/dev/null)
    fi

    if [ -n "$existing" ] && [ "$existing" -gt 0 ] 2>/dev/null; then
        echo "$existing"
        return
    fi

    # 分配新的 mark_id (1-99)，避免与已用值冲突
    local used="" new_id=1
    if command -v jq >/dev/null 2>&1; then
        used=$(jq -r '.devices[].mark_id // empty' "$RULES_FILE" 2>/dev/null | sort -n)
    elif command -v python3 >/dev/null 2>&1; then
        used=$(python3 -c "
import json
try:
    d = json.load(open('$RULES_FILE'))
    ids = [v.get('mark_id') for v in d.get('devices',{}).values() if v.get('mark_id')]
    print(' '.join(str(i) for i in sorted(ids)))
except: pass
" 2>/dev/null)
    fi
    for id in $used; do
        [ "$id" -eq "$new_id" ] 2>/dev/null && new_id=$((new_id+1))
    done
    [ "$new_id" -gt 99 ] && new_id=1
    echo "$new_id"
}

# ─── 更新 rules.json（v3.3.0：统一委托给 json_set.sh）────────
# 旧实现依赖 jq 或 python3 且 value 语义混乱（既接受 JSON 字面量
# 又接受裸字符串）。现在全部转交 json_set.sh device，由它的
# json_encode 函数统一处理引号。
#
# 调用方只传原始值：
#   update_rules aa:bb:cc:dd:ee:ff down_mbps 10       (num)
#   update_rules aa:bb:cc:dd:ee:ff ip 192.168.1.5     (string → 自动加引号)
#   update_rules aa:bb:cc:dd:ee:ff limit_enabled true (bool)
update_rules() {
    local mac=$1 field=$2 value=$3
    sh "$HNC_DIR/bin/json_set.sh" device "$mac" "$field" "$value" 2>/dev/null \
        || log "WARN: json_set device failed: $mac.$field=$value"
}

# v3.3.0：更新 rules.json 顶层字段（用于 whitelist_mode 等）
update_top() {
    local field=$1 value=$2
    sh "$HNC_DIR/bin/json_set.sh" top "$field" "$value" 2>/dev/null \
        || log "WARN: json_set top failed: $field=$value"
}

# ─── API处理函数 ─────────────────────────────────────────────

handle_get_devices() {
    local devices=$(cat $DEVICES_FILE 2>/dev/null || echo '{}')
    local rules=$(cat $RULES_FILE 2>/dev/null || echo '{}')
    
    # 合并设备信息和规则
    local result
    if command -v python3 &>/dev/null; then
        result=$(python3 -c "
import json
devs = json.loads('''$devices''')
rules = json.loads('''$rules''')
dev_rules = rules.get('devices', {})
result = []
for mac, dev in devs.items():
    r = dev_rules.get(mac, {})
    dev.update({
        'mark_id': r.get('mark_id', 0),
        'down_mbps': r.get('down_mbps', 0),
        'up_mbps': r.get('up_mbps', 0),
        'delay_ms': r.get('delay_ms', 0),
        'jitter_ms': r.get('jitter_ms', 0),
        'loss_pct': r.get('loss_pct', 0),
        'limit_enabled': r.get('limit_enabled', False),
        'delay_enabled': r.get('delay_enabled', False),
    })
    result.append(dev)
print(json.dumps({'devices': result, 'count': len(result)}))
" 2>/dev/null)
    fi
    
    result=${result:-"{\"devices\":[],\"raw\":$devices}"}
    http_ok "$result"
}

handle_get_stats() {
    local iface
    iface=$(sh "$HNC_DIR/bin/device_detect.sh" iface 2>/dev/null)
    local ts; ts=$(date +%s)

    # 从 tc class 获取各 mark_id 的精准流量（对应各设备）
    local tc_json="{}"
    if command -v jq >/dev/null 2>&1; then
        tc_json=$(tc -s class show dev "$iface" 2>/dev/null | python3 -c "
import sys, json, re
classes = {}
cur = None
for line in sys.stdin:
    m = re.match(r' *class htb \S+:(\d+)', line)
    if m:
        cur = int(m.group(1))
        classes[cur] = {'bytes_sent': 0, 'bytes_recv': 0}
    if cur:
        m2 = re.search(r'Sent (\d+) bytes', line)
        if m2: classes[cur]['bytes_sent'] = int(m2.group(1))
        m3 = re.search(r'backlog.*?(\d+)b', line)
        if m3: classes[cur]['bytes_recv'] = int(m3.group(1))
print(json.dumps(classes))
" 2>/dev/null || echo "{}")
    else
        # 降级：读取接口总计字节数
        local rx tx
        rx=$(cat /sys/class/net/"$iface"/statistics/rx_bytes 2>/dev/null || echo 0)
        tx=$(cat /sys/class/net/"$iface"/statistics/tx_bytes 2>/dev/null || echo 0)
        tc_json="{\"total\":{\"rx_bytes\":$rx,\"tx_bytes\":$tx}}"
    fi

    local json="{\"iface\":\"$iface\",\"per_class\":$tc_json,\"timestamp\":$ts}"
    http_ok "$json"
}

handle_post_limit() {
    local body=$1
    # 解析body: {"mac":"xx:xx","ip":"x.x.x.x","down":10,"up":5,"enabled":true}
    local mac=$(json_str_field "$body" "mac")
    local ip=$(json_str_field "$body" "ip")
    local down=$(json_field "$body" "down")
    local up=$(json_field "$body" "up")
    local enabled=$(json_field "$body" "enabled")
    
    [ -z "$mac" ] && http_error 400 "mac required" && return
    
    local mark_id=$(get_or_assign_mark "$mac")
    local iface=$(sh $HNC_DIR/bin/device_detect.sh iface)
    
    log "set_limit mac=$mac ip=$ip down=$down up=$up enabled=$enabled mark_id=$mark_id"
    
    # 应用iptables MARK (绑定IP+MAC)
    sh $HNC_DIR/bin/iptables_manager.sh mark "$ip" "$mac" "$mark_id"
    
    # v3.3.0 关键修复：将 IP 作为第 5 参数传给 set_limit，
    # 否则 ifb0 的 u32 src IP 过滤器无法建立，上传方向永远不限速
    if [ "$enabled" = "true" ]; then
        sh $HNC_DIR/bin/tc_manager.sh set_limit "$iface" "$mark_id" "${down:-0}" "${up:-0}" "$ip"
        update_rules "$mac" limit_enabled true
        update_rules "$mac" down_mbps "${down:-0}"
        update_rules "$mac" up_mbps "${up:-0}"
    else
        sh $HNC_DIR/bin/tc_manager.sh set_limit "$iface" "$mark_id" 0 0 "$ip"
        update_rules "$mac" limit_enabled false
    fi
    
    update_rules "$mac" mark_id "$mark_id"
    update_rules "$mac" ip "$ip"
    
    http_ok "{\"ok\":true,\"mark_id\":$mark_id,\"iface\":\"$iface\"}"
}

handle_post_delay() {
    local body=$1
    local mac=$(json_str_field "$body" "mac")
    local ip=$(json_str_field "$body" "ip")
    local delay=$(json_field "$body" "delay")
    local jitter=$(json_field "$body" "jitter")
    local loss=$(json_field "$body" "loss")
    local enabled=$(json_field "$body" "enabled")
    
    [ -z "$mac" ] && http_error 400 "mac required" && return
    
    local mark_id=$(get_or_assign_mark "$mac")
    local iface=$(sh $HNC_DIR/bin/device_detect.sh iface)
    
    log "set_delay mac=$mac ip=$ip delay=$delay jitter=$jitter loss=$loss"
    
    sh $HNC_DIR/bin/iptables_manager.sh mark "$ip" "$mac" "$mark_id"
    
    # v3.3.0 关键修复：set_delay 第 6 参数是 IP，用于 u32 filter 精确分类
    if [ "$enabled" = "true" ]; then
        sh $HNC_DIR/bin/tc_manager.sh set_delay "$iface" "$mark_id" \
            "${delay:-0}" "${jitter:-0}" "${loss:-0}" "$ip"
        update_rules "$mac" delay_enabled true
        update_rules "$mac" delay_ms "${delay:-0}"
        update_rules "$mac" jitter_ms "${jitter:-0}"
    else
        sh $HNC_DIR/bin/tc_manager.sh set_delay "$iface" "$mark_id" 0 0 0 "$ip"
        update_rules "$mac" delay_enabled false
    fi
    
    update_rules "$mac" mark_id "$mark_id"
    update_rules "$mac" ip "$ip"
    
    http_ok "{\"ok\":true,\"mark_id\":$mark_id}"
}

handle_post_blacklist() {
    local body=$1
    local mac=$(json_str_field "$body" "mac")
    local ip=$(json_str_field "$body" "ip")
    local action=$(json_str_field "$body" "action")  # add / remove
    
    [ -z "$mac" ] && http_error 400 "mac required" && return

    # MAC 格式校验，防止命令注入
    echo "$mac" | grep -qE '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' || {
        http_error 400 "invalid mac format"
        return
    }
    
    log "blacklist $action: $ip ($mac)"
    
    if [ "$action" = "add" ]; then
        sh $HNC_DIR/bin/iptables_manager.sh blacklist_add "$ip" "$mac"
        sh $HNC_DIR/bin/json_set.sh bl_add "$mac" 2>/dev/null
    else
        sh $HNC_DIR/bin/iptables_manager.sh blacklist_remove "$ip" "$mac"
        sh $HNC_DIR/bin/json_set.sh bl_del "$mac" 2>/dev/null
    fi
    
    http_ok "{\"ok\":true,\"action\":\"$action\",\"mac\":\"$mac\"}"
}

# v3.3.0 新增：白名单成员管理（补齐缺失的 /whitelist 路由）
handle_post_whitelist() {
    local body=$1
    local mac=$(json_str_field "$body" "mac")
    local ip=$(json_str_field "$body" "ip")
    local action=$(json_str_field "$body" "action")

    [ -z "$mac" ] && http_error 400 "mac required" && return
    echo "$mac" | grep -qE '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' || {
        http_error 400 "invalid mac format"
        return
    }

    log "whitelist $action: $ip ($mac)"

    if [ "$action" = "add" ]; then
        sh $HNC_DIR/bin/iptables_manager.sh whitelist_add "$ip" "$mac"
    else
        sh $HNC_DIR/bin/iptables_manager.sh whitelist_remove "$ip" "$mac"
    fi

    http_ok "{\"ok\":true,\"action\":\"$action\",\"mac\":\"$mac\"}"
}

handle_post_whitelist_mode() {
    local body=$1
    local enabled=$(json_field "$body" "enabled")
    
    if [ "$enabled" = "true" ]; then
        sh $HNC_DIR/bin/iptables_manager.sh whitelist_on
        update_top whitelist_mode true
    else
        sh $HNC_DIR/bin/iptables_manager.sh whitelist_off
        update_top whitelist_mode false
    fi
    
    http_ok "{\"ok\":true,\"whitelist_mode\":$enabled}"
}

handle_get_status() {
    local api_pid=$(cat $HNC_DIR/run/api.pid 2>/dev/null)
    local detect_pid=$(cat $HNC_DIR/run/detect.pid 2>/dev/null)
    local watchdog_pid=$(cat $HNC_DIR/run/watchdog.pid 2>/dev/null)
    local iface=$(sh $HNC_DIR/bin/device_detect.sh iface 2>/dev/null)
    local uptime=$(cat /proc/uptime | awk '{print int($1)}')
    
    local json="{
  \"ok\":true,
  \"version\":\"$VERSION\",
  \"iface\":\"$iface\",
  \"uptime\":$uptime,
  \"services\":{
    \"api\":{\"pid\":${api_pid:-0},\"alive\":$(kill -0 ${api_pid:-0} 2>/dev/null && echo true || echo false)},
    \"detect\":{\"pid\":${detect_pid:-0},\"alive\":$(kill -0 ${detect_pid:-0} 2>/dev/null && echo true || echo false)},
    \"watchdog\":{\"pid\":${watchdog_pid:-0},\"alive\":$(kill -0 ${watchdog_pid:-0} 2>/dev/null && echo true || echo false)}
  }
}"
    http_ok "$json"
}

# ─── 请求处理器 ──────────────────────────────────────────────
handle_request() {
    local request_line=""
    local method=""
    local path=""
    local content_length=0
    local body=""
    
    # 读取请求行
    read -r request_line
    request_line=$(echo "$request_line" | tr -d '\r')
    method=$(echo "$request_line" | awk '{print $1}')
    path=$(echo "$request_line" | awk '{print $2}')
    
    log "$method $path"
    
    # 读取headers
    while true; do
        local header=""
        read -r header
        header=$(echo "$header" | tr -d '\r')
        [ -z "$header" ] && break
        
        # 获取Content-Length
        echo "$header" | grep -qi "content-length" && \
            content_length=$(echo "$header" | grep -oi '[0-9]*$')
    done
    
    # 读取body (POST)
    if [ "$method" = "POST" ] && [ "$content_length" -gt 0 ]; then
        body=$(dd bs=1 count=$content_length 2>/dev/null)
    fi
    
    # OPTIONS预检
    [ "$method" = "OPTIONS" ] && http_options && return
    
    # 路由
    case "$path" in
        /|/index.html)
            local web_file="$HNC_DIR/web/index.html"
            [ -f "$web_file" ] && http_html "$web_file" || \
                http_ok '{"message":"HNC API Server v'$VERSION'","webui":"/index.html"}'
            ;;
        /css/*|/js/*|/img/*)
            local static_file="$HNC_DIR/web$path"
            [ -f "$static_file" ] && http_static "$static_file" || \
                http_error 404 "Not Found"
            ;;
        /devices)   handle_get_devices ;;
        /stats)     handle_get_stats ;;
        /status)    handle_get_status ;;
        /config)
            [ "$method" = "GET" ] && \
                http_ok "$(cat $HNC_DIR/data/config.json 2>/dev/null || echo '{}')" || \
                http_ok "{\"ok\":true}"
            ;;
        /limit)     handle_post_limit "$body" ;;
        /delay)     handle_post_delay "$body" ;;
        /blacklist) handle_post_blacklist "$body" ;;
        /whitelist) handle_post_whitelist "$body" ;;
        /whitelist_mode) handle_post_whitelist_mode "$body" ;;
        *)          http_error 404 "Not Found" ;;
    esac
}

# ─── 主循环: busybox nc 单线程 ───────────────────────────────
log "Starting API server on port $PORT (PID=$$)"
echo $$ > $HNC_DIR/run/api.pid

# v3.3.0 安全修复：移除原 `busybox nc -l -p $PORT -e /bin/sh` 探测。
# 该命令不是探测——nc -l 是阻塞监听，-e /bin/sh 会把连入的任何人
# 直接放到一个未授权的 root shell 里。若 busybox 编译时带了 -e 支持，
# 8080 端口就变成无密码后门；若不支持，调用也会让启动流程卡死或
# 依赖 stderr 静默失败。无论哪种情况都不能保留。

# 主循环: 每次处理一个连接
while true; do
    # 使用mkfifo创建双向通信管道
    PIPE=$(mktemp -u /tmp/hnc_pipe_XXXXXX)
    mkfifo $PIPE
    
    # 启动nc监听，将响应通过管道写入
    handle_request < $PIPE | busybox nc -l -p $PORT > $PIPE 2>/dev/null
    
    rm -f $PIPE
done &

# 如果busybox nc不支持，尝试用ncat/socat
if ! wait; then
    log "Trying socat fallback..."
    if command -v socat &>/dev/null; then
        socat TCP-LISTEN:$PORT,fork,reuseaddr EXEC:"sh $HNC_DIR/api/server.sh handle" >> $LOG 2>&1 &
    else
        log "ERROR: No suitable nc/socat found. Please install busybox with netcat support."
        # 最后备选: Python3
        python3 - << 'PYEOF' &
import http.server, json, subprocess, os, threading

HNC_DIR = "/data/local/hnc"

class HNCHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # 静默日志
    
    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()
    
    def send_json(self, data, code=200):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(body))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)
    
    def get_body(self):
        length = int(self.headers.get('Content-Length', 0))
        return json.loads(self.rfile.read(length)) if length else {}
    
    def do_GET(self):
        path = self.path.split('?')[0]
        if path in ('/', '/index.html'):
            try:
                with open(f'{HNC_DIR}/web/index.html', 'rb') as f:
                    data = f.read()
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', len(data))
                self.end_headers()
                self.wfile.write(data)
            except:
                self.send_json({'message': 'HNC API Server', 'version': '1.4.0'})
        elif path.startswith('/css/') or path.startswith('/js/'):
            try:
                with open(f'{HNC_DIR}/web{path}', 'rb') as f:
                    data = f.read()
                ctype = 'text/css' if path.endswith('.css') else 'application/javascript'
                self.send_response(200)
                self.send_header('Content-Type', ctype)
                self.send_header('Content-Length', len(data))
                self.end_headers()
                self.wfile.write(data)
            except:
                self.send_json({'error': 'not found'}, 404)
        elif path == '/devices':
            try:
                with open(f'{HNC_DIR}/data/devices.json') as f:
                    devs = json.load(f)
                with open(f'{HNC_DIR}/data/rules.json') as f:
                    rules = json.load(f)
                dev_rules = rules.get('devices', {})
                result = []
                for mac, dev in devs.items():
                    r = dev_rules.get(mac, {})
                    dev.update({'mark_id': r.get('mark_id', 0),
                               'down_mbps': r.get('down_mbps', 0),
                               'up_mbps': r.get('up_mbps', 0),
                               'delay_ms': r.get('delay_ms', 0),
                               'jitter_ms': r.get('jitter_ms', 0),
                               'loss_pct': r.get('loss_pct', 0),
                               'limit_enabled': r.get('limit_enabled', False),
                               'delay_enabled': r.get('delay_enabled', False)})
                    result.append(dev)
                self.send_json({'devices': result, 'count': len(result)})
            except Exception as e:
                self.send_json({'devices': [], 'error': str(e)})
        elif path == '/stats':
            self.send_json({'timestamp': __import__('time').time()})
        elif path == '/status':
            self.send_json({'ok': True, 'version': '1.4.0'})
        elif path == '/config':
            try:
                with open(f'{HNC_DIR}/data/config.json') as f:
                    self.send_json(json.load(f))
            except:
                self.send_json({})
        else:
            self.send_json({'error': 'not found'}, 404)
    
    def do_POST(self):
        path = self.path
        body = self.get_body()
        
        def run_sh(cmd):
            return subprocess.run(['sh', '-c', cmd], capture_output=True, text=True)
        
        if path == '/limit':
            mac = body.get('mac', '')
            ip = body.get('ip', '')
            down = body.get('down', 0)
            up = body.get('up', 0)
            enabled = body.get('enabled', True)
            mark_id = body.get('mark_id', 1)
            
            run_sh(f'sh {HNC_DIR}/bin/iptables_manager.sh mark "{ip}" "{mac}" {mark_id}')
            if enabled:
                iface_r = run_sh(f'sh {HNC_DIR}/bin/device_detect.sh iface')
                iface = iface_r.stdout.strip()
                run_sh(f'sh {HNC_DIR}/bin/tc_manager.sh set_limit "{iface}" {mark_id} {down} {up}')
            
            # 更新rules.json
            try:
                with open(f'{HNC_DIR}/data/rules.json') as f:
                    rules = json.load(f)
                rules.setdefault('devices', {}).setdefault(mac, {}).update({
                    'mark_id': mark_id, 'down_mbps': down, 'up_mbps': up,
                    'limit_enabled': enabled, 'ip': ip
                })
                with open(f'{HNC_DIR}/data/rules.json', 'w') as f:
                    json.dump(rules, f, indent=2)
            except: pass
            
            self.send_json({'ok': True, 'mark_id': mark_id})
        
        elif path == '/delay':
            mac = body.get('mac', '')
            ip = body.get('ip', '')
            delay = body.get('delay', 0)
            jitter = body.get('jitter', 0)
            loss = body.get('loss', 0)
            enabled = body.get('enabled', True)
            mark_id = body.get('mark_id', 1)
            
            run_sh(f'sh {HNC_DIR}/bin/iptables_manager.sh mark "{ip}" "{mac}" {mark_id}')
            if enabled:
                iface_r = run_sh(f'sh {HNC_DIR}/bin/device_detect.sh iface')
                iface = iface_r.stdout.strip()
                run_sh(f'sh {HNC_DIR}/bin/tc_manager.sh set_delay "{iface}" {mark_id} {delay} {jitter} {loss}')
            
            try:
                with open(f'{HNC_DIR}/data/rules.json') as f:
                    rules = json.load(f)
                rules.setdefault('devices', {}).setdefault(mac, {}).update({
                    'mark_id': mark_id, 'delay_ms': delay, 'jitter_ms': jitter,
                    'delay_enabled': enabled, 'ip': ip
                })
                with open(f'{HNC_DIR}/data/rules.json', 'w') as f:
                    json.dump(rules, f, indent=2)
            except: pass
            
            self.send_json({'ok': True})
        
        elif path == '/blacklist':
            mac = body.get('mac', '')
            ip = body.get('ip', '')
            action = body.get('action', 'add')
            run_sh(f'sh {HNC_DIR}/bin/iptables_manager.sh blacklist_{action} "{ip}" "{mac}"')
            self.send_json({'ok': True, 'action': action})
        
        elif path == '/whitelist_mode':
            enabled = body.get('enabled', False)
            action = 'whitelist_on' if enabled else 'whitelist_off'
            run_sh(f'sh {HNC_DIR}/bin/iptables_manager.sh {action}')
            self.send_json({'ok': True, 'whitelist_mode': enabled})
        
        else:
            self.send_json({'error': 'not found'}, 404)

import os
port = int(os.environ.get('HNC_PORT', 8080))
server = http.server.ThreadingHTTPServer(('0.0.0.0', port), HNCHandler)
server.serve_forever()
PYEOF
    fi
fi

wait
