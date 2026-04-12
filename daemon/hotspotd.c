/*
 * hotspotd.c — HNC 事件驱动设备监控 C daemon
 *
 * 架构：
 *   - 单进程 select() 事件循环（无线程，无 malloc 泄漏）
 *   - Netlink RTGRP_NEIGH 监听 ARP/邻居表变化（RTM_NEWNEIGH / RTM_DELNEIGH）
 *   - UNIX socket 提供 IPC（GET_DEVICES / REFRESH / STATUS / QUIT）
 *   - SIGUSR1 触发立即 ARP 补充扫描（device_detect.sh scan 兼容接口）
 *   - 原子写 devices.json（tmp + rename），保持与原 shell 逻辑完全兼容
 *
 * 与原项目的关系：
 *   - 完全替换 device_detect.sh daemon 模式的轮询循环
 *   - 输出同样的 /data/local/hnc/data/devices.json 格式
 *   - 若二进制不存在，service.sh 自动退回原 shell daemon（向下兼容）
 *
 * 编译：见 daemon/build.sh 和 daemon/Android.mk
 *
 * SPDX-License-Identifier: GPL-2.0
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <ctype.h>

#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/select.h>
#include <sys/types.h>

#include <arpa/inet.h>
#include <net/if.h>

#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/neighbour.h>
#include <linux/if_arp.h>

/* 兼容性宏：部分 libc/内核头文件版本不导出 NDM_RTA/NDM_PAYLOAD */
#ifndef NDM_RTA
#  define NDM_RTA(r)    ((struct rtattr *)(((char *)(r)) +                          NLMSG_ALIGN(sizeof(struct ndmsg))))
#endif
#ifndef NDM_PAYLOAD
#  define NDM_PAYLOAD(n) NLMSG_PAYLOAD(n, sizeof(struct ndmsg))
#endif

/* ── 路径常量 ──────────────────────────────────────────────── */
#define HNC_DIR             "/data/local/hnc"
#define SOCK_PATH           HNC_DIR "/run/hotspotd.sock"
#define DEVICES_JSON        HNC_DIR "/data/devices.json"
/* v3.5.2 P0-A 修复:tmp 路径带 PID 后缀,避免跟 shell daemon 路径
 * (bin/device_detect.sh do_scan_shell 用 devices.json.tmp)的字节级冲突。
 * 虽然 P0-A 主线修复已经让 C daemon 和 shell daemon 不同时运行,这是纵深防御。 */
#define DEVICES_TMP_FMT     HNC_DIR "/data/devices.json.tmp.%d"
#define LOG_FILE            HNC_DIR "/logs/hotspotd.log"
#define PID_FILE            HNC_DIR "/run/hotspotd.pid"
#define ARP_PROC            "/proc/net/arp"
#define RULES_JSON          HNC_DIR "/data/rules.json"
#define DEVICE_NAMES_JSON   HNC_DIR "/data/device_names.json"   /* v3.5.0 P0-4 */
#define MDNS_RESOLVE_BIN    HNC_DIR "/bin/mdns_resolve"         /* v3.5.0 P0-4 */
#define IPTABLES_MGR        HNC_DIR "/bin/iptables_manager.sh"  /* v3.5.1 P1-2 */

/* ── 设备表 ──────────────────────────────────────────────── */
#define MAX_DEVICES     128
#define MAC_STR_LEN     18      /* "aa:bb:cc:dd:ee:ff\0" */
#define IP_STR_LEN      16      /* "255.255.255.255\0" */
#define HN_LEN          64
#define IF_LEN          16
#define HN_SRC_LEN      12      /* "manual\0" "mdns\0" "dhcp\0" "arp\0" "mac\0" */

/* ARP 条目有效状态：NUD_REACHABLE | NUD_STALE | NUD_DELAY |
 *                    NUD_PROBE | NUD_PERMANENT | NUD_NOARP  */
#define NUD_VALID  (NUD_REACHABLE | NUD_STALE | NUD_DELAY | \
                    NUD_PROBE | NUD_PERMANENT | NUD_NOARP)

typedef struct {
    char    mac[MAC_STR_LEN];
    char    ip[IP_STR_LEN];
    char    hostname[HN_LEN];
    char    hostname_src[HN_SRC_LEN];   /* v3.5.0 P1-8: 跟 shell 路径对齐 */
    char    iface[IF_LEN];
    long    rx_bytes;
    long    tx_bytes;
    time_t  last_seen;
    time_t  last_resolve;               /* v3.5.0-rc R-2: 上次 resolve_hostname 时间,用于改名场景的 60s 时间窗口 re-resolve */
    int     active;
    int     state;      /* NUD_* from netlink */
} Device;

static Device   g_devs[MAX_DEVICES];
static int      g_ndev = 0;          /* active device count */
static time_t   g_last_write = 0;    /* last devices.json write */
static time_t   g_last_event = 0;    /* v3.5.0-rc R-1: last netlink event time, for de-bounce */
static int      g_dirty = 0;         /* device table changed since last write */

/* ── 全局 fd ──────────────────────────────────────────────── */
static int  g_nl_fd   = -1;   /* netlink socket */
static int  g_srv_fd  = -1;   /* UNIX socket server */
static FILE *g_log    = NULL;

/* ── 信号标志（volatile sig_atomic_t 保证信号安全）────────── */
static volatile sig_atomic_t g_need_scan   = 1;  /* 1=需要立即补充扫描 */
static volatile sig_atomic_t g_running     = 1;  /* 0=退出主循环 */

/* ══════════════════════════════════════════════════════════
   日志
══════════════════════════════════════════════════════════ */
static void hlog(const char *fmt, ...) {
    if (!g_log) return;
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    char buf[32];
    strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", tm);
    fprintf(g_log, "[%s] [HOTSPOTD] ", buf);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);
}

/* ══════════════════════════════════════════════════════════
   设备表操作
══════════════════════════════════════════════════════════ */
static Device *find_device(const char *mac) {
    for (int i = 0; i < MAX_DEVICES; i++)
        if (g_devs[i].active && strcmp(g_devs[i].mac, mac) == 0)
            return &g_devs[i];
    return NULL;
}

static Device *alloc_device(void) {
    for (int i = 0; i < MAX_DEVICES; i++)
        if (!g_devs[i].active)
            return &g_devs[i];
    /* 表满：淘汰最老的条目 */
    Device *oldest = &g_devs[0];
    for (int i = 1; i < MAX_DEVICES; i++)
        if (g_devs[i].active && g_devs[i].last_seen < oldest->last_seen)
            oldest = &g_devs[i];
    hlog("WARN: device table full, evicting %s", oldest->mac);
    memset(oldest, 0, sizeof(*oldest));
    return oldest;
}

/* 忽略非热点接口（lo/rmnet/dummy/tun/p2p） */
static int is_hotspot_iface(const char *iface) {
    if (!iface || !*iface) return 0;
    const char *skip[] = {"lo","rmnet","dummy","v4-","tun","p2p","r_rmnet", NULL};
    for (int i = 0; skip[i]; i++)
        if (strncmp(iface, skip[i], strlen(skip[i])) == 0)
            return 0;
    return 1;
}

static void count_active(void) {
    g_ndev = 0;
    for (int i = 0; i < MAX_DEVICES; i++)
        if (g_devs[i].active) g_ndev++;
}

/* v3.5.2 P1-A: re-resolve 触发条件提取成真函数
 *
 * 之前 scan_arp 和 nl_process 里是内联的 if 判断,导致 test_hostname_helpers.c
 * 里的 "R-2 测试" 其实是测了测试文件自己写的一个同名 shadow 函数,
 * hotspotd.c 里根本没有对应的 symbol。第二轮 AI 审查的 P1-A 指出:
 * "测试覆盖 R-2 逻辑"是假的 coverage 标签。
 *
 * 修复:把逻辑抽成一个 static inline 函数,scan_arp 和 nl_process 都调用它,
 * 测试文件也 #include 这一小段定义或者直接 extern 引用。
 * 现在如果有人改阈值(60s → 30s),两处调用同时变,测试也真的跑到真代码上。
 *
 * 触发条件:
 *   1) hostname_src 是 "mac" 兜底 → 立即重试(user 可能刚刚命名)
 *   2) 距上次 resolve >= 60 秒 → 时间窗口过期,可能改名或 mDNS 缓存更新
 */
static int should_re_resolve(const char *hostname_src, time_t last_resolve, time_t now) {
    if (strcmp(hostname_src, "mac") == 0) return 1;
    if ((now - last_resolve) >= 60) return 1;
    return 0;
}

/* ══════════════════════════════════════════════════════════
   v3.5.0 P0-4: Hostname 解析(手动命名 + mDNS)

   之前 hotspotd 的 write_json() 直接输出 d->hostname(只含 MAC 兜底),
   完全忽略 device_names.json(手动命名)和 mDNS。shell 路径的
   get_hostname() 按优先级 mdns > dhcp > manual > mac 查询,但
   hotspotd 的 scan_arp 只做 mac 兜底。结果:同一设备在 shell 和 C 之间
   hostname 不一致,WebUI 显示不稳定。

   修复:
   1) lookup_manual_name() 读 device_names.json,按 mac 查手动命名
   2) try_mdns_resolve() 调 bin/mdns_resolve binary(跟 shell 路径共用)
   3) scan_arp 新设备时顺序调用:manual > mdns > mac,填充 hostname_src
   4) write_json 输出 hostname_src 字段

   性能:
   - lookup_manual_name 每次读文件(没缓存),但 device_names.json 通常 < 1KB,
     O(n) 解析可忽略。未来可以加 mtime-based 缓存
   - try_mdns_resolve 开 popen 子进程,每设备 ~200ms,只在新设备初次发现时调,
     不在每次 write_json 调
══════════════════════════════════════════════════════════ */

/* 从 device_names.json 查手动命名。
 * 返回: 1 = 找到(写 out),0 = 未找到 */
static int lookup_manual_name(const char *mac, char *out, size_t outlen) {
    FILE *f = fopen(DEVICE_NAMES_JSON, "r");
    if (!f) return 0;

    /* v3.5.0 P1-7 设计:device_names.json 通常整个文件 < 4KB,
     * 用大 buffer 一次读完,避免 fgets 截断风险 */
    char buf[8192];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    if (n == 0) return 0;
    buf[n] = '\0';

    /* 查找 "mac":"name" 子串(case-insensitive mac) */
    char pattern[32];
    snprintf(pattern, sizeof(pattern), "\"%s\":\"", mac);

    char *p = buf;
    while (*p) {
        /* strcasestr 不是 POSIX,手工实现 */
        char *m = pattern, *q = p;
        while (*m && *q && tolower((unsigned char)*q) == tolower((unsigned char)*m)) { q++; m++; }
        if (*m == '\0') {
            /* 匹配成功,q 指向 name 起始 */
            size_t i = 0;
            while (*q && *q != '"' && i < outlen - 1) {
                /* 处理 JSON escape: \" \\ */
                if (*q == '\\' && (q[1] == '"' || q[1] == '\\')) {
                    out[i++] = q[1];
                    q += 2;
                } else {
                    out[i++] = *q++;
                }
            }
            out[i] = '\0';
            return (i > 0) ? 1 : 0;
        }
        p++;
    }
    return 0;
}

/* 调 bin/mdns_resolve <ip>,超时 1s
 * v3.5.1 P0-1 修复:之前传 "<ip> <mac>" 两个位置参数,但 mdns_resolve 的
 * argv 解析循环把任何非 flag 参数都赋给 ip,结果 ip 被 mac 覆盖,
 * inet_pton 必然失败,从来没真正发出过 mDNS 查询。
 * 修复:只传 ip,跟 shell 路径(`mdns_resolve -t 800 "$ip"`)一致 */
static int try_mdns_resolve(const char *ip, const char *mac, char *out, size_t outlen) {
    (void)mac;  /* 参数保留以兼容调用方,但不传给 binary */
    if (access(MDNS_RESOLVE_BIN, X_OK) != 0) return 0;

    char cmd[256];
    snprintf(cmd, sizeof(cmd), "%s -t 800 %s 2>/dev/null", MDNS_RESOLVE_BIN, ip);

    FILE *pf = popen(cmd, "r");
    if (!pf) return 0;

    out[0] = '\0';
    if (fgets(out, outlen, pf) != NULL) {
        /* 去尾部换行 */
        size_t l = strlen(out);
        while (l > 0 && (out[l-1] == '\n' || out[l-1] == '\r')) {
            out[--l] = '\0';
        }
    }
    int rc = pclose(pf);
    (void)rc;
    return (out[0] != '\0') ? 1 : 0;
}

/* 综合 hostname 解析:manual > mdns > mac
 * 填充 out 和 out_src */
static void resolve_hostname(const char *mac, const char *ip,
                             char *out_hn, size_t hn_len,
                             char *out_src, size_t src_len) {
    /* 1. 手动命名(最高优先级) */
    if (lookup_manual_name(mac, out_hn, hn_len)) {
        snprintf(out_src, src_len, "manual");
        return;
    }

    /* 2. mDNS(只在有 IP 时) */
    if (ip && *ip && try_mdns_resolve(ip, mac, out_hn, hn_len)) {
        snprintf(out_src, src_len, "mdns");
        return;
    }

    /* 3. MAC 兜底(后 8 位,去冒号)— 与 shell 路径对齐 */
    /* shell 做的是 `echo "$mac" | tr -d ':' | tail -c 9`:
     * "aa:bb:cc:dd:ee:ff" → 去冒号 → "aabbccddeeff" → 后 8 字符 → "ccddeeff"
     * (tail -c 9 取最后 9 字节含 \0,实际 8 字符 + \0)
     * v3.5.0 P1-8 对齐修复 */
    char no_colon[13];  /* 12 hex chars + \0 */
    size_t ci = 0;
    for (size_t i = 0; mac[i] && ci < sizeof(no_colon) - 1; i++) {
        if (mac[i] != ':') no_colon[ci++] = mac[i];
    }
    no_colon[ci] = '\0';
    /* 取后 8 字符 */
    const char *suffix = (ci >= 8) ? (no_colon + ci - 8) : no_colon;
    snprintf(out_hn, hn_len, "%s", suffix);
    snprintf(out_src, src_len, "mac");
}

/* ══════════════════════════════════════════════════════════
   JSON 写出（原子 tmp+rename，与原 shell 格式 100% 兼容）
══════════════════════════════════════════════════════════ */

/* v3.5.1 P0-2 + v3.5.2 P2-F: JSON 字符串转义
 * 转义 " \ \n \r \t 和 0x00-0x1f 控制字符。
 *
 * P0-2 原因:之前 write_json 用 %s 直接输出 d->hostname,含 " 或 \(来自
 * lookup_manual_name 解码 device_names.json)→ JSON 破损 → WebUI 设备列表清空
 *
 * P2-F 原因:当 dst 空间不够时原 break 策略会在 UTF-8 多字节序列中间截断,
 * 留下孤立的 continuation bytes(0x80-0xBF),JSON 本身合法但 UI JSON.parse
 * 后 .hostname 里出现 replacement character 或乱码。
 * 修复:回退 UTF-8 边界后才写 NUL。
 *
 * UTF-8 规则回顾:
 *   0xxxxxxx             ASCII(1 字节)
 *   110xxxxx 10xxxxxx    2 字节
 *   1110xxxx 10xxxxxx × 2   3 字节(中文)
 *   11110xxx 10xxxxxx × 3   4 字节(emoji 等)
 *   10xxxxxx 是 continuation byte
 *   回退规则:从末尾往前扫,跳过所有 10xxxxxx 的 byte,直到找到一个 non-continuation。
 */
static void json_escape(const char *src, char *dst, size_t dst_size) {
    if (dst_size == 0) return;
    size_t j = 0;
    int truncated = 0;
    /* 循环条件 j + 1 < dst_size: 留 1 字节给末尾 NUL。
     * 每个 escape 分支自己再检查需要的额外字节,不够就 break。 */
    for (size_t i = 0; src[i] && j + 1 < dst_size; i++) {
        unsigned char c = (unsigned char)src[i];
        if (c == '"' || c == '\\') {
            if (j + 2 >= dst_size) { truncated = 1; break; }
            dst[j++] = '\\';
            dst[j++] = (char)c;
        } else if (c == '\n') {
            if (j + 2 >= dst_size) { truncated = 1; break; }
            dst[j++] = '\\'; dst[j++] = 'n';
        } else if (c == '\r') {
            if (j + 2 >= dst_size) { truncated = 1; break; }
            dst[j++] = '\\'; dst[j++] = 'r';
        } else if (c == '\t') {
            if (j + 2 >= dst_size) { truncated = 1; break; }
            dst[j++] = '\\'; dst[j++] = 't';
        } else if (c < 0x20) {
            if (j + 6 >= dst_size) { truncated = 1; break; }
            j += snprintf(dst + j, dst_size - j, "\\u%04x", c);
        } else {
            /* 普通 ASCII 或 UTF-8 字节,1 字节 */
            dst[j++] = (char)c;
        }
    }

    /* v3.5.2 P2-F: 如果因 buffer 不够退出,且原串没读完,
     * 回退到最近一个完整 UTF-8 字符边界。
     *
     * 正确做法:从当前位置往前扫,找最后一个 non-continuation byte(lead byte 或 ASCII)。
     * 检查从它开始的字符是不是已经完整写入:
     *   - ASCII (0xxxxxxx): 本身完整,保留
     *   - 2-byte lead (110xxxxx): 需要后续 1 个 continuation,检查 dst[j-1] 是不是 continuation
     *   - 3-byte lead (1110xxxx): 需要后续 2 个 continuation
     *   - 4-byte lead (11110xxx): 需要后续 3 个 continuation
     * 如果完整,保留;不完整,回退把整个残缺字符删掉。
     */
    if (truncated || (src[0] && j + 1 >= dst_size)) {
        /* 从末尾往前找 last non-continuation byte */
        size_t k = j;
        while (k > 0 && ((unsigned char)dst[k-1] & 0xC0) == 0x80) {
            k--;
        }
        /* k 现在指向 last non-continuation byte 的位置 + 1
         * 即 dst[k-1] 是 ASCII 或 lead byte */
        if (k > 0) {
            unsigned char lead = (unsigned char)dst[k-1];
            size_t needed = 0;
            if ((lead & 0x80) == 0) {
                needed = 0;  /* ASCII,完整 */
            } else if ((lead & 0xE0) == 0xC0) {
                needed = 1;  /* 2-byte,需要 1 continuation */
            } else if ((lead & 0xF0) == 0xE0) {
                needed = 2;  /* 3-byte,需要 2 continuation */
            } else if ((lead & 0xF8) == 0xF0) {
                needed = 3;  /* 4-byte,需要 3 continuation */
            }
            /* dst[k..j-1] 是 continuation bytes,有 (j - k) 个 */
            size_t have = j - k;
            if (have >= needed) {
                /* 最后一个字符完整,j 保持不变 */
            } else {
                /* 不完整,把残缺字符整个删掉 */
                j = k - 1;
            }
        }
    }

    dst[j] = '\0';
}

/* v3.5.1 P1-2: 调 iptables_manager.sh stats_all 读 per-device 流量字节
 * 之前 hotspotd 模式下 rx_bytes/tx_bytes 永远 0 → WebUI 流量统计完全失效。
 * 修复:write_json 之前 popen 一次,把输出按 IP 索引,匹配后填充 d->rx_bytes/tx_bytes。
 * stats_all 输出格式:每行 "<ip> <rx_bytes> <tx_bytes>"
 *
 * v3.5.2 P1-E: 加 5 秒 TTL 缓存。
 * 原因:iptables -L HNC_STATS -nvx 的成本是 O(chain 规则数),长时间运行后
 * HNC_STATS 可能有 500+ 条规则,每次 popen+awk+iptables 几百毫秒。
 * write_json 在 de-bounce 触发最短 1 秒一次 → 多次调用被阻塞。
 * 缓存策略:5 秒内重复调用直接 return,流量数字实时性轻微牺牲但主线程不停摆。
 */
static time_t g_last_stats_update = 0;

static void update_traffic_stats(void) {
    if (access(IPTABLES_MGR, X_OK) != 0) return;

    /* v3.5.2 P1-E: 5 秒 TTL 缓存 */
    time_t now = time(NULL);
    if (now - g_last_stats_update < 5) return;
    g_last_stats_update = now;

    char cmd[256];
    snprintf(cmd, sizeof(cmd), "sh %s stats_all 2>/dev/null", IPTABLES_MGR);
    FILE *pf = popen(cmd, "r");
    if (!pf) return;

    char line[128];
    while (fgets(line, sizeof(line), pf) != NULL) {
        char ip[IP_STR_LEN];
        long rx, tx;
        if (sscanf(line, "%15s %ld %ld", ip, &rx, &tx) == 3) {
            for (int i = 0; i < MAX_DEVICES; i++) {
                if (g_devs[i].active && strcmp(g_devs[i].ip, ip) == 0) {
                    g_devs[i].rx_bytes = rx;
                    g_devs[i].tx_bytes = tx;
                    break;
                }
            }
        }
    }
    pclose(pf);
}

static void write_json(void) {
    /* v3.5.1 P1-2: 写 JSON 前先更新流量字节,否则 rx/tx 永远是 0 */
    update_traffic_stats();

    /* 读黑名单
     * v3.5.0 P1-7 修复:之前 fgets(line, 256) 读 rules.json,如果 30+ 设备
     * 全在 blacklist 一行,256 字节装不下 → strstr 检测不到 ']' → 截断丢失。
     * 改用 fread 一次性读整个文件到大 buffer(rules.json 通常 < 8KB) */
    char blacklist[MAX_DEVICES][MAC_STR_LEN];
    int  nbl = 0;
    FILE *rf = fopen(RULES_JSON, "r");
    if (rf) {
        char buf[16384];
        size_t n = fread(buf, 1, sizeof(buf) - 1, rf);
        fclose(rf);
        buf[n] = '\0';

        /* 找 "blacklist": 然后从这个位置开始扫,到 ] 结束 */
        char *bl_start = strstr(buf, "\"blacklist\"");
        if (bl_start) {
            char *bl_end = strchr(bl_start, ']');
            if (bl_end) *bl_end = '\0';

            /* 提取所有 "xx:xx:xx:xx:xx:xx" 子串 */
            char *p = bl_start;
            while ((p = strchr(p, '"')) != NULL) {
                p++;
                if (strlen(p) >= 17 && p[2] == ':' && p[5] == ':' &&
                    p[8] == ':' && p[11] == ':' && p[14] == ':') {
                    if (nbl < MAX_DEVICES) {
                        strncpy(blacklist[nbl], p, 17);
                        blacklist[nbl][17] = '\0';
                        nbl++;
                    }
                }
            }
        }
    }

    /* v3.5.2 P0-A: tmp 路径带 PID 后缀,避免跟 shell daemon 冲突 */
    char devices_tmp[256];
    snprintf(devices_tmp, sizeof(devices_tmp), DEVICES_TMP_FMT, (int)getpid());

    FILE *f = fopen(devices_tmp, "w");
    if (!f) { hlog("ERROR: cannot write %s: %s", devices_tmp, strerror(errno)); return; }

    fprintf(f, "{");
    int first = 1;
    /* v3.5.1 P2-6: 删除原 300s 离线判断(死代码)。
     * 离线清理由主循环 R-13 周期任务负责(每 30s 检查,90s 阈值)。
     * 之前两个判断并存,300s 永远触发不到(R-13 90s 先清),逻辑不清晰 */
    (void)0;
    for (int i = 0; i < MAX_DEVICES; i++) {
        Device *d = &g_devs[i];
        if (!d->active) continue;

        /* 黑名单状态 */
        const char *status = "allowed";
        for (int b = 0; b < nbl; b++)
            if (strcmp(blacklist[b], d->mac) == 0) { status = "blocked"; break; }

        /* v3.5.0 P0-4: 输出 hostname_src 字段(默认 mac 兜底) */
        const char *hn_src = (d->hostname_src[0]) ? d->hostname_src : "mac";

        /* v3.5.1 P0-2: hostname 必须 JSON-escape,否则用户名字含 " 或 \ 会破坏 JSON */
        char hn_escaped[HN_LEN * 6 + 4];  /* worst case: 每字节变 \u00xx */
        json_escape(d->hostname, hn_escaped, sizeof(hn_escaped));

        if (!first) fprintf(f, ",");
        fprintf(f,
            "\"%s\":{"
            "\"ip\":\"%s\","
            "\"mac\":\"%s\","
            "\"hostname\":\"%s\","
            "\"hostname_src\":\"%s\","
            "\"iface\":\"%s\","
            "\"rx_bytes\":%ld,"
            "\"tx_bytes\":%ld,"
            "\"status\":\"%s\","
            "\"last_seen\":%ld"
            "}",
            d->mac, d->ip, d->mac, hn_escaped, hn_src,
            d->iface, d->rx_bytes, d->tx_bytes,
            status, (long)d->last_seen);
        first = 0;
    }
    fprintf(f, "}");
    fflush(f);
    fclose(f);

    if (rename(devices_tmp, DEVICES_JSON) != 0) {
        hlog("ERROR: rename failed: %s", strerror(errno));
        unlink(devices_tmp);  /* 清理失败的 tmp */
    } else {
        count_active();
        g_last_write = time(NULL);
        g_dirty = 0;
        hlog("JSON written: %d device(s)", g_ndev);
    }
}

/* ══════════════════════════════════════════════════════════
   ARP 补充扫描（/proc/net/arp 读取，用于 SIGUSR1 / 初始化）
══════════════════════════════════════════════════════════ */
static void scan_arp(void) {
    FILE *f = fopen(ARP_PROC, "r");
    if (!f) return;

    char line[256];
    int  updated = 0;
    /* v3.5.2 P2-D: 显式消费 fgets 返回值,不然 -Wunused-result 会报警 */
    if (fgets(line, sizeof(line), f) == NULL) {
        fclose(f);
        return;  /* /proc/net/arp 读不到表头 → 直接退出 */
    }

    while (fgets(line, sizeof(line), f)) {
        char ip[IP_STR_LEN], hw[8], flags[8], mac[MAC_STR_LEN], mask[8], iface[IF_LEN];
        if (sscanf(line, "%15s %7s %7s %17s %7s %15s",
                   ip, hw, flags, mac, mask, iface) != 6)
            continue;
        /* flags=0x0 表示无效 */
        if (strcmp(flags, "0x0") == 0) continue;
        /* 过滤全零 MAC */
        if (strcmp(mac, "00:00:00:00:00:00") == 0) continue;
        /* 过滤非热点接口 */
        if (!is_hotspot_iface(iface)) continue;

        /* MAC 转小写 */
        for (int i = 0; mac[i]; i++) mac[i] = tolower((unsigned char)mac[i]);

        Device *d = find_device(mac);
        time_t now_t = time(NULL);
        if (!d) {
            d = alloc_device();
            strncpy(d->mac, mac, sizeof(d->mac)-1);
            /* v3.5.0 P0-4 + P1-8: 用统一的 resolve_hostname,
             * 优先级 manual > mdns > mac,与 shell 路径对齐 */
            resolve_hostname(mac, ip,
                             d->hostname, sizeof(d->hostname),
                             d->hostname_src, sizeof(d->hostname_src));
            d->last_resolve = now_t;
        } else if (should_re_resolve(d->hostname_src, d->last_resolve, now_t)) {
            /* v3.5.0-rc R-2 + v3.5.2 P1-A:
             * re-resolve 条件提取成真函数(之前是内联,测试是影子函数) */
            resolve_hostname(mac, ip,
                             d->hostname, sizeof(d->hostname),
                             d->hostname_src, sizeof(d->hostname_src));
            d->last_resolve = now_t;
        }
        strncpy(d->ip,    ip,    sizeof(d->ip)-1);
        strncpy(d->iface, iface, sizeof(d->iface)-1);
        d->last_seen = now_t;
        d->active    = 1;
        d->state     = NUD_STALE; /* 保守估计 */
        updated++;
    }
    fclose(f);

    if (updated) {
        g_dirty = 1;
        hlog("ARP scan: %d entry/entries updated", updated);
        write_json();
    } else {
        hlog("ARP scan: no new entries");
    }
}

/* ══════════════════════════════════════════════════════════
   Netlink：设置 + 解析 RTM_NEWNEIGH / RTM_DELNEIGH
══════════════════════════════════════════════════════════ */
static int nl_open(void) {
    int fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
    if (fd < 0) { hlog("ERROR: netlink socket: %s", strerror(errno)); return -1; }

    /* v3.5.2 P1-C: 把 netlink 接收缓冲区调到 1 MB,减少高负载下的
     * ENOBUFS 丢包。默认约 128 KB,30+ 客户端时一次事件风暴就可能溢出。 */
    int rcvbuf = 1024 * 1024;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf)) < 0) {
        hlog("WARN: netlink SO_RCVBUF failed: %s", strerror(errno));
    }

    struct sockaddr_nl sa = {
        .nl_family = AF_NETLINK,
        .nl_groups = RTMGRP_NEIGH,   /* 只监听邻居表变化 */
    };
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        hlog("ERROR: netlink bind: %s", strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

static void nl_process(int fd) {
    char buf[8192];
    ssize_t n = recv(fd, buf, sizeof(buf), MSG_DONTWAIT);
    if (n < 0) {
        /* v3.5.2 P1-C: 处理 ENOBUFS — netlink kernel buffer 溢出,丢包了,
         * 触发一次全量 scan_arp 重同步设备表,不然有设备会永久从视角消失 */
        if (errno == ENOBUFS) {
            hlog("WARN: netlink ENOBUFS, queueing full rescan");
            g_need_scan = 1;
        } else if (errno != EAGAIN && errno != EWOULDBLOCK) {
            hlog("WARN: netlink recv: %s", strerror(errno));
        }
        return;
    }
    if (n == 0) return;

    struct nlmsghdr *nlh = (struct nlmsghdr *)buf;
    for (; NLMSG_OK(nlh, (unsigned)n); nlh = NLMSG_NEXT(nlh, n)) {
        if (nlh->nlmsg_type != RTM_NEWNEIGH && nlh->nlmsg_type != RTM_DELNEIGH)
            continue;

        struct ndmsg *ndm = (struct ndmsg *)NLMSG_DATA(nlh);
        if (ndm->ndm_family != AF_INET) continue;  /* 只处理 IPv4 */

        /* 获取接口名 */
        char iface[IF_LEN] = {0};
        if_indextoname(ndm->ndm_ifindex, iface);
        if (!is_hotspot_iface(iface)) continue;

        /* 提取 NDA_DST（IP）和 NDA_LLADDR（MAC） */
        char ip_str[IP_STR_LEN]   = {0};
        char mac_str[MAC_STR_LEN] = {0};
        struct rtattr *rta = NDM_RTA(ndm);
        int rta_len = NDM_PAYLOAD(nlh);

        for (; RTA_OK(rta, rta_len); rta = RTA_NEXT(rta, rta_len)) {
            if (rta->rta_type == NDA_DST && rta->rta_len == RTA_LENGTH(4)) {
                struct in_addr *addr = (struct in_addr *)RTA_DATA(rta);
                inet_ntop(AF_INET, addr, ip_str, sizeof(ip_str));
            } else if (rta->rta_type == NDA_LLADDR && rta->rta_len == RTA_LENGTH(6)) {
                unsigned char *m = (unsigned char *)RTA_DATA(rta);
                snprintf(mac_str, sizeof(mac_str),
                         "%02x:%02x:%02x:%02x:%02x:%02x",
                         m[0],m[1],m[2],m[3],m[4],m[5]);
            }
        }

        if (!*ip_str || !*mac_str) continue;

        if (nlh->nlmsg_type == RTM_DELNEIGH || !(ndm->ndm_state & NUD_VALID)) {
            /* 设备离线:标记非活跃,不立即删除(给 300s 宽限) */
            Device *d = find_device(mac_str);
            if (d) {
                /* 仅 NUD_FAILED / NUD_INCOMPLETE 才真正移除 */
                if (ndm->ndm_state & (NUD_FAILED | NUD_INCOMPLETE)) {
                    d->active = 0;
                    g_dirty   = 1;
                    g_last_event = time(NULL);  /* v3.5.0-rc R-1 */
                    hlog("DEL: %s (%s) state=0x%x", mac_str, ip_str, ndm->ndm_state);
                }
            }
        } else {
            /* 设备上线或更新 */
            Device *d = find_device(mac_str);
            time_t now_t = time(NULL);
            if (!d) {
                d = alloc_device();
                strncpy(d->mac, mac_str, sizeof(d->mac)-1);
                /* v3.5.0 P0-4 + P1-8: 用统一的 resolve_hostname */
                resolve_hostname(mac_str, ip_str,
                                 d->hostname, sizeof(d->hostname),
                                 d->hostname_src, sizeof(d->hostname_src));
                d->last_resolve = now_t;
            } else if (should_re_resolve(d->hostname_src, d->last_resolve, now_t)) {
                /* v3.5.0-rc R-2 + v3.5.2 P1-A: 跟 scan_arp 共用 should_re_resolve */
                resolve_hostname(mac_str, ip_str,
                                 d->hostname, sizeof(d->hostname),
                                 d->hostname_src, sizeof(d->hostname_src));
                d->last_resolve = now_t;
            }
            strncpy(d->ip,    ip_str, sizeof(d->ip)-1);
            strncpy(d->iface, iface,  sizeof(d->iface)-1);
            d->last_seen = now_t;
            d->active    = 1;
            d->state     = ndm->ndm_state;
            g_dirty      = 1;
            g_last_event = now_t;  /* v3.5.0-rc R-1: 更新事件时间戳给 de-bounce 用 */
            hlog("NEW: %s (%s) on %s state=0x%x", mac_str, ip_str, iface, ndm->ndm_state);
        }
    }

    /* v3.5.0-rc R-1: 不再"有变化立即 write_json"。
     * 仅 set g_dirty,主循环用 200ms de-bounce 合并连续事件。
     * 这避免了同一设备 5 秒内 state 变 3 次 → 3 次 write_json 的情况。
     * 实测:RMX5010 上单个客户端连接热点,5 秒内 6+ 个 state transition,
     * de-bounce 后合并为 1 次 write_json,文件 IO 减少 80%+ */
}

/* ══════════════════════════════════════════════════════════
   UNIX Socket Server（IPC）
══════════════════════════════════════════════════════════ */
static int unix_server_open(void) {
    unlink(SOCK_PATH);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) { hlog("ERROR: unix socket: %s", strerror(errno)); return -1; }

    struct sockaddr_un su = {.sun_family = AF_UNIX};
    strncpy(su.sun_path, SOCK_PATH, sizeof(su.sun_path)-1);
    if (bind(fd, (struct sockaddr *)&su, sizeof(su)) < 0) {
        hlog("ERROR: unix bind: %s", strerror(errno));
        close(fd); return -1;
    }
    chmod(SOCK_PATH, 0666);
    listen(fd, 8);
    return fd;
}

static void handle_client(int cfd) {
    /* v3.5.2 P1-B: 加读写超时防止恶意客户端挂起主线程
     * - 2 秒读超时:客户端连上但不发数据 → recv 超时后 close
     * - 5 秒写超时:客户端慢读或不读 → send 超时后 close
     * 之前没超时,一个坏客户端就能 DoS 整个 hotspotd */
    struct timeval tv_rd = {.tv_sec = 2, .tv_usec = 0};
    struct timeval tv_wr = {.tv_sec = 5, .tv_usec = 0};
    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv_rd, sizeof(tv_rd));
    setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv_wr, sizeof(tv_wr));

    char req[64] = {0};
    ssize_t n = recv(cfd, req, sizeof(req)-1, 0);
    if (n <= 0) { close(cfd); return; }
    req[n] = '\0';
    /* 去尾部空白 */
    for (int i = (int)strlen(req)-1; i >= 0 && (req[i]=='\n'||req[i]=='\r'||req[i]==' '); i--)
        req[i] = '\0';

    if (strcmp(req, "GET_DEVICES") == 0) {
        /* 直接发 JSON 文件内容 */
        FILE *f = fopen(DEVICES_JSON, "r");
        if (!f) { send(cfd, "{}", 2, 0); }
        else {
            char fbuf[65536];
            size_t rd;
            while ((rd = fread(fbuf, 1, sizeof(fbuf), f)) > 0) {
                /* v3.5.2 P1-B: 检查 send 返回值,失败就 break(客户端断连 / 超时) */
                ssize_t sent = send(cfd, fbuf, rd, 0);
                if (sent < 0) break;
            }
            fclose(f);
        }
    } else if (strcmp(req, "REFRESH") == 0) {
        /* v3.5.2 P0-B 修复:REFRESH 不再同步调 scan_arp(那会 popen
         * mdns_resolve × N 设备,主线程阻塞几秒到几十秒)。
         * 只设 g_need_scan 标志,主循环下一次 select wakeup 会处理。 */
        g_need_scan = 1;
        send(cfd, "OK:queued\n", 10, 0);
    } else if (strcmp(req, "STATUS") == 0) {
        char resp[128];
        snprintf(resp, sizeof(resp), "running:1 devices:%d pid:%d\n",
                 g_ndev, (int)getpid());
        send(cfd, resp, strlen(resp), 0);
    } else if (strcmp(req, "QUIT") == 0) {
        send(cfd, "BYE\n", 4, 0);
        g_running = 0;
    } else {
        send(cfd, "ERR:unknown command\n", 20, 0);
    }
    close(cfd);
}

/* ══════════════════════════════════════════════════════════
   信号处理
══════════════════════════════════════════════════════════ */
static void sig_usr1(int s) { (void)s; g_need_scan = 1; }
static void sig_term(int s) { (void)s; g_running   = 0; }

/* ══════════════════════════════════════════════════════════
   PID 文件
══════════════════════════════════════════════════════════ */

/* v3.5.2 P1-D + P2-A:
 * 1) write_pid 用 O_CREAT|O_EXCL 原子创建,如果文件已存在:
 *    - 读出旧 PID,kill -0 检查活不活
 *    - 活着 → 返回 -1 让 main 退出(不做 cleanup 避免误删别人的文件)
 *    - 死了 → unlink 旧文件,重试 O_EXCL 创建
 * 2) fopen/write 失败时打日志而不是静默
 *
 * 防止的场景:watchdog 重启 hotspotd 时并发拉起两个实例,
 * 第二个实例 O_EXCL 失败,检测到第一个实例活着 → 干净退出,
 * 不会 unlink 第一个实例的 PID 文件。
 */
static int write_pid(void) {
    int fd = open(PID_FILE, O_CREAT | O_EXCL | O_WRONLY, 0644);
    if (fd < 0) {
        if (errno == EEXIST) {
            /* 文件已存在,检查里面的 PID 是否还活着 */
            FILE *rf = fopen(PID_FILE, "r");
            if (rf) {
                int old_pid = 0;
                if (fscanf(rf, "%d", &old_pid) == 1 && old_pid > 0) {
                    fclose(rf);
                    if (kill(old_pid, 0) == 0) {
                        /* 旧进程还活着,不要继续 */
                        hlog("ERROR: another hotspotd already running (PID=%d), exiting",
                             old_pid);
                        return -1;
                    }
                    /* 旧进程死了,清理 stale 文件 */
                    hlog("INFO: stale PID file (dead PID=%d), cleaning up", old_pid);
                } else {
                    fclose(rf);
                    hlog("WARN: PID file exists but unreadable, cleaning up");
                }
            }
            unlink(PID_FILE);
            /* 重试 O_EXCL 创建 */
            fd = open(PID_FILE, O_CREAT | O_EXCL | O_WRONLY, 0644);
            if (fd < 0) {
                hlog("ERROR: cannot create PID file after cleanup: %s", strerror(errno));
                return -1;
            }
        } else {
            hlog("ERROR: cannot create PID file: %s", strerror(errno));
            return -1;
        }
    }
    char buf[32];
    int n = snprintf(buf, sizeof(buf), "%d\n", (int)getpid());
    if (write(fd, buf, n) != n) {
        hlog("WARN: write PID file short/failed: %s", strerror(errno));
    }
    close(fd);
    return 0;
}

/* v3.5.2 P1-D: cleanup 时验证 PID 文件里的 PID 是不是自己,
 * 是才删,不是说明别的实例已经 overwrite 了,不要删它的文件 */
static void cleanup_pid(void) {
    FILE *rf = fopen(PID_FILE, "r");
    if (!rf) return;
    int file_pid = 0;
    if (fscanf(rf, "%d", &file_pid) == 1 && file_pid == (int)getpid()) {
        fclose(rf);
        unlink(PID_FILE);
    } else {
        fclose(rf);
        /* PID 文件里不是自己 → 别的实例,保留 */
    }
}

/* ══════════════════════════════════════════════════════════
   主函数
══════════════════════════════════════════════════════════ */
int main(int argc, char *argv[]) {
    /* 简单参数：-d 后台化，-l <logfile> */
    int daemonize = 0;
    const char *logpath = LOG_FILE;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-d") == 0)      daemonize = 1;
        else if (strcmp(argv[i], "-l") == 0 && i+1 < argc) logpath = argv[++i];
    }

    /* 后台化 */
    if (daemonize) {
        if (fork() > 0) exit(0);
        setsid();
        if (fork() > 0) exit(0);
        /* 重定向标准 IO */
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) { dup2(devnull,0); dup2(devnull,1); dup2(devnull,2); close(devnull); }
    }

    /* 日志 */
    g_log = fopen(logpath, "a");
    hlog("=== hotspotd %s started (PID=%d) ===", daemonize?"daemon":"fg", (int)getpid());
    /* v3.5.2 P2-E: g_log 加 FD_CLOEXEC,避免子进程(popen mdns_resolve 等)继承日志 fd */
    if (g_log) fcntl(fileno(g_log), F_SETFD, FD_CLOEXEC);

    /* PID 文件
     * v3.5.2 P1-D: 如果 write_pid 返回 -1(别的实例还活着),直接退出,
     * 跳过 cleanup 避免误删别人的 PID 文件 */
    if (write_pid() < 0) {
        if (g_log) fclose(g_log);
        return 0;  /* 干净退出,不走 cleanup */
    }

    /* 信号 */
    signal(SIGUSR1, sig_usr1);
    signal(SIGTERM, sig_term);
    signal(SIGINT,  sig_term);
    signal(SIGPIPE, SIG_IGN);

    /* Netlink socket */
    g_nl_fd = nl_open();
    if (g_nl_fd < 0) { hlog("FATAL: cannot open netlink"); goto cleanup; }

    /* UNIX socket server */
    g_srv_fd = unix_server_open();
    if (g_srv_fd < 0) { hlog("FATAL: cannot open UNIX socket"); goto cleanup; }

    hlog("Listening on netlink RTGRP_NEIGH + %s", SOCK_PATH);

    /* 初始扫描 */
    scan_arp();

    /* v3.5.0-rc R-1: de-bounce 状态变量
     * dirty_since = 上次 g_dirty 从 0→1 的时刻
     * 主循环规则:dirty 后等 ~500ms 没有新事件才 write_json
     * 注意:用 wall-clock 秒精度,因为 select timeout 200ms 已经够细
     * 写法:dirty=1 且 (now - dirty_since >= 1) 才写,等价于"超过 1s 的 dirty"
     * (Linux time(NULL) 秒精度,所以 1s 是最小可表达 de-bounce 窗口) */
    time_t dirty_since = 0;

    /* v3.5.0-rc2 R-13: 周期性离线清理时间戳
     * hotspotd 是事件驱动的,设备静默离开(关 wifi/出门)不会触发 RTM_DELNEIGH。
     * 之前的离线判断只发生在 write_json 内,而 write_json 只在 dirty 时调用,
     * 结果设备走了之后 devices.json 永远含旧设备(直到 hotspotd 重启)。
     *
     * 修复:主循环每 OFFLINE_CHECK_INTERVAL 秒强制扫一遍 g_devs[],把
     * (now - last_seen) > OFFLINE_THRESHOLD 的设备 active=0,然后 set dirty
     * 触发 write_json 重写文件 */
    #define OFFLINE_CHECK_INTERVAL 30   /* 每 30s 检查一次 */
    #define OFFLINE_THRESHOLD       90   /* 90s 未活跃 = 离线 */
    time_t last_offline_check = time(NULL);

    /* ── 主事件循环 ────────────────────────────────────────── */
    while (g_running) {
        /* 处理 SIGUSR1 */
        if (g_need_scan) {
            g_need_scan = 0;
            hlog("SIGUSR1: manual ARP scan triggered");
            scan_arp();
        }

        time_t now = time(NULL);

        /* v3.5.0-rc2 R-13: 周期性离线清理 */
        if (now - last_offline_check >= OFFLINE_CHECK_INTERVAL) {
            int evicted = 0;
            for (int i = 0; i < MAX_DEVICES; i++) {
                Device *d = &g_devs[i];
                if (!d->active) continue;
                if (now - d->last_seen > OFFLINE_THRESHOLD) {
                    hlog("OFFLINE: %s (%s) silent for %lds, evicting",
                         d->mac, d->ip, (long)(now - d->last_seen));
                    d->active = 0;
                    evicted++;
                }
            }
            if (evicted > 0) {
                g_dirty = 1;
                g_last_event = now;  /* 也算事件,触发 de-bounce 写入 */
            }
            last_offline_check = now;
        }

        /* v3.5.0-rc R-1: de-bounce write
         * 1) g_dirty 刚从 0→1: 记 dirty_since
         * 2) g_dirty 持续 1: 等到至少 1s 没有更多 nl_process 调用时 write
         * 3) 30s 强制 flush 兜底(防止持续 dirty 永远不写) */
        if (g_dirty) {
            if (dirty_since == 0) {
                dirty_since = now;  /* 第一次 mark dirty */
            }
            int elapsed = (int)(now - dirty_since);
            int last_event = (int)(now - g_last_event);

            /* 写入条件:
             * a) 距上次事件 >= 1s(短时间无新事件,可以合并) OR
             * b) 距首次 dirty >= 30s(强制兜底) */
            if (last_event >= 1 || elapsed >= 30) {
                write_json();
                dirty_since = 0;  /* reset de-bounce 窗口 */
            }
        }

        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(g_nl_fd,  &rfds);
        FD_SET(g_srv_fd, &rfds);
        int maxfd = (g_nl_fd > g_srv_fd ? g_nl_fd : g_srv_fd) + 1;

        /* select timeout: dirty 时短(继续 de-bounce 检查),非 dirty 时长 */
        struct timeval tv;
        if (g_dirty) {
            tv.tv_sec = 1; tv.tv_usec = 0;  /* 1s 检查一次 de-bounce 窗口 */
        } else {
            tv.tv_sec = 5; tv.tv_usec = 0;  /* 闲时 5s,省 CPU */
        }
        int ret = select(maxfd, &rfds, NULL, NULL, &tv);
        if (ret < 0) {
            if (errno == EINTR) continue;  /* 信号打断,正常 */
            hlog("ERROR: select: %s", strerror(errno));
            break;
        }

        if (ret == 0) continue;  /* 超时,继续循环 */

        /* 处理 netlink 事件 */
        if (FD_ISSET(g_nl_fd, &rfds))
            nl_process(g_nl_fd);

        /* 处理 IPC 连接 */
        if (FD_ISSET(g_srv_fd, &rfds)) {
            int cfd = accept(g_srv_fd, NULL, NULL);
            if (cfd >= 0) handle_client(cfd);
        }
    }

cleanup:
    hlog("hotspotd shutting down");
    /* 最后写一次 JSON */
    if (g_dirty) write_json();
    if (g_nl_fd  >= 0) close(g_nl_fd);
    if (g_srv_fd >= 0) { close(g_srv_fd); unlink(SOCK_PATH); }
    /* v3.5.2 P1-D: 验证 PID 文件是自己的才 unlink */
    cleanup_pid();
    if (g_log) { hlog("=== hotspotd stopped ==="); fclose(g_log); }
    return 0;
}
