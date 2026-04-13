/* hnc_helpers.c — HNC shared C helpers 实现
 *
 * v3.6 Commit 2:从 hotspotd.c 提取的纯 helper 函数。
 * 见 hnc_helpers.h 的设计说明。
 */

#include "hnc_helpers.h"

#include <stdio.h>
#include <string.h>
#include <ctype.h>

/* ══════════════════════════════════════════════════════════
 * should_re_resolve
 * ══════════════════════════════════════════════════════════ */
int hnc_should_re_resolve(const char *hostname_src, time_t last_resolve, time_t now) {
    if (strcmp(hostname_src, "mac") == 0) return 1;
    if ((now - last_resolve) >= 60) return 1;
    return 0;
}

/* ══════════════════════════════════════════════════════════
 * json_escape — 含 UTF-8 边界回退 (v3.5.2 P2-F)
 * ══════════════════════════════════════════════════════════ */
void hnc_json_escape(const char *src, char *dst, size_t dst_size) {
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
            /* 普通 ASCII 或 UTF-8 字节 */
            dst[j++] = (char)c;
        }
    }

    /* UTF-8 边界回退:如果因 buffer 不够退出,确保不留残缺多字节序列 */
    if (truncated || (src[0] && j + 1 >= dst_size)) {
        /* 从末尾往前找 last non-continuation byte */
        size_t k = j;
        while (k > 0 && ((unsigned char)dst[k-1] & 0xC0) == 0x80) {
            k--;
        }
        /* dst[k-1] 是 ASCII 或 lead byte */
        if (k > 0) {
            unsigned char lead = (unsigned char)dst[k-1];
            size_t needed = 0;
            if ((lead & 0x80) == 0) {
                needed = 0;                /* ASCII,完整 */
            } else if ((lead & 0xE0) == 0xC0) {
                needed = 1;                /* 2-byte lead */
            } else if ((lead & 0xF0) == 0xE0) {
                needed = 2;                /* 3-byte lead (中文) */
            } else if ((lead & 0xF8) == 0xF0) {
                needed = 3;                /* 4-byte lead (emoji) */
            }
            size_t have = j - k;
            if (have < needed) {
                /* 不完整,删掉整个残缺字符 */
                j = k - 1;
            }
        }
    }

    dst[j] = '\0';
}

/* ══════════════════════════════════════════════════════════
 * mac_fallback — 跟 shell 路径对齐 (v3.5.0 P1-8)
 *
 * "aa:bb:cc:dd:ee:ff" → 去冒号 → "aabbccddeeff" → 后 8 字符 → "ccddeeff"
 * ══════════════════════════════════════════════════════════ */
void hnc_mac_fallback(const char *mac, char *out, size_t outlen) {
    if (outlen == 0) return;
    char no_colon[13];  /* 12 hex chars + \0 */
    size_t ci = 0;
    for (size_t i = 0; mac[i] && ci < sizeof(no_colon) - 1; i++) {
        if (mac[i] != ':') no_colon[ci++] = mac[i];
    }
    no_colon[ci] = '\0';
    /* 取后 8 字符 */
    const char *suffix = (ci >= 8) ? (no_colon + ci - 8) : no_colon;
    snprintf(out, outlen, "%s", suffix);
}

/* ══════════════════════════════════════════════════════════
 * lookup_manual_name — 从 device_names.json 查手动命名
 *
 * 参数化:不再依赖 DEVICE_NAMES_JSON macro,路径由调用方传入。
 * 这让测试可以用临时文件路径跑,不需要污染真实 /data/local/hnc/。
 * ══════════════════════════════════════════════════════════ */
int hnc_lookup_manual_name(const char *mac, const char *names_path,
                           char *out, size_t outlen) {
    if (!names_path || !*names_path) return 0;
    FILE *f = fopen(names_path, "r");
    if (!f) return 0;

    /* v3.5.0 P1-7: device_names.json 通常整个文件 < 4KB,
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
        while (*m && *q && tolower((unsigned char)*q) == tolower((unsigned char)*m)) {
            q++; m++;
        }
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

/* ══════════════════════════════════════════════════════════
 * resolve_hostname_fast — 快速解析,不含 mdns
 *
 * v3.6:scan_arp / nl_process 调用这个版本,保证不阻塞主循环。
 * mdns 解析延后到主循环的 process_pending_mdns() 异步处理(Commit 3)。
 *
 * 优先级:manual > mac 兜底
 * ══════════════════════════════════════════════════════════ */
void hnc_resolve_hostname_fast(const char *mac, const char *ip,
                               const char *names_path,
                               char *out_hn, size_t hn_len,
                               char *out_src, size_t src_len) {
    (void)ip;  /* fast 模式不需要 ip(只 manual + mac 兜底) */

    /* 1) 手动命名 */
    if (hnc_lookup_manual_name(mac, names_path, out_hn, hn_len)) {
        snprintf(out_src, src_len, "manual");
        return;
    }

    /* 2) MAC 兜底 */
    hnc_mac_fallback(mac, out_hn, hn_len);
    snprintf(out_src, src_len, "mac");
}

/* ══════════════════════════════════════════════════════════
 * pending_ready — 判断 pending 设备是否应该被异步 mDNS 解析
 *
 * 见 hnc_helpers.h 详细说明。纯函数,好测。
 * ══════════════════════════════════════════════════════════ */
int hnc_pending_ready(const char *hostname_src, time_t pending_since, time_t now) {
    if (!hostname_src) return 0;
    if (strcmp(hostname_src, "pending") != 0) return 0;
    if (now - pending_since < HNC_PENDING_BREATHING_ROOM_SEC) return 0;
    return 1;
}
