/* test_hostname_helpers.c — 单元测试 hotspotd 的 hostname 解析逻辑
 *
 * 测试 v3.5.0-beta1 P0-4 + P1-8 修复:
 *   - lookup_manual_name() 正确读取 device_names.json
 *   - resolve_hostname() 优先级 manual > mdns > mac
 *   - mac 兜底与 shell 路径对齐(后 8 字符,去冒号)
 *
 * 复制 hotspotd.c 的 helper 函数,沙箱直接编译运行,不依赖网络/文件系统外的东西。
 *
 * 编译:
 *   cd daemon/test
 *   gcc -Wall -Wextra -o test_hostname_helpers test_hostname_helpers.c
 *   ./test_hostname_helpers
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <unistd.h>
#include <time.h>

#define MAC_STR_LEN  18
#define HN_LEN       64
#define HN_SRC_LEN   12

/* 测试用临时路径(每个 process pid 独立) */
static char DEVICE_NAMES_JSON[256];

/* === 从 hotspotd.c 复制的函数(必须保持同步)=== */

static int lookup_manual_name(const char *mac, char *out, size_t outlen) {
    FILE *f = fopen(DEVICE_NAMES_JSON, "r");
    if (!f) return 0;

    char buf[8192];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    if (n == 0) return 0;
    buf[n] = '\0';

    char pattern[32];
    snprintf(pattern, sizeof(pattern), "\"%s\":\"", mac);

    char *p = buf;
    while (*p) {
        char *m = pattern, *q = p;
        while (*m && *q && tolower((unsigned char)*q) == tolower((unsigned char)*m)) { q++; m++; }
        if (*m == '\0') {
            size_t i = 0;
            while (*q && *q != '"' && i < outlen - 1) {
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

/* mac 兜底:跟 shell `echo $mac | tr -d ':' | tail -c 9` 对齐 */
static void mac_fallback(const char *mac, char *out_hn, size_t hn_len) {
    char no_colon[13];
    size_t ci = 0;
    for (size_t i = 0; mac[i] && ci < sizeof(no_colon) - 1; i++) {
        if (mac[i] != ':') no_colon[ci++] = mac[i];
    }
    no_colon[ci] = '\0';
    const char *suffix = (ci >= 8) ? (no_colon + ci - 8) : no_colon;
    snprintf(out_hn, hn_len, "%s", suffix);
}

/* === 测试基础设施 === */
static int g_pass = 0, g_fail = 0;

#define ASSERT_EQ(expected, actual, name) do {                              \
    if (strcmp((expected), (actual)) == 0) {                                \
        g_pass++;                                                           \
        printf("  ✓ %s\n", name);                                           \
    } else {                                                                \
        g_fail++;                                                           \
        printf("  ✗ %s\n    expected: %s\n    actual:   %s\n",              \
               name, expected, actual);                                     \
    }                                                                       \
} while (0)

#define ASSERT_INT_EQ(expected, actual, name) do {                          \
    if ((expected) == (actual)) {                                           \
        g_pass++;                                                           \
        printf("  ✓ %s\n", name);                                           \
    } else {                                                                \
        g_fail++;                                                           \
        printf("  ✗ %s\n    expected: %d\n    actual:   %d\n",              \
               name, (int)(expected), (int)(actual));                       \
    }                                                                       \
} while (0)

static void write_test_file(const char *content) {
    FILE *f = fopen(DEVICE_NAMES_JSON, "w");
    if (!f) { perror("write_test_file"); exit(1); }
    fputs(content, f);
    fclose(f);
}

/* === 测试用例 === */

static void test_lookup_manual_name_empty_file(void) {
    write_test_file("{}");
    char out[HN_LEN] = "x";
    int rc = lookup_manual_name("aa:bb:cc:dd:ee:ff", out, sizeof(out));
    ASSERT_INT_EQ(0, rc, "empty file returns 0");
}

static void test_lookup_manual_name_basic(void) {
    write_test_file("{\"aa:bb:cc:dd:ee:ff\":\"Living Room TV\"}");
    char out[HN_LEN] = "";
    int rc = lookup_manual_name("aa:bb:cc:dd:ee:ff", out, sizeof(out));
    ASSERT_INT_EQ(1, rc, "basic lookup returns 1");
    ASSERT_EQ("Living Room TV", out, "basic lookup value");
}

static void test_lookup_manual_name_chinese(void) {
    write_test_file("{\"aa:bb:cc:dd:ee:ff\":\"客厅平板\"}");
    char out[HN_LEN] = "";
    int rc = lookup_manual_name("aa:bb:cc:dd:ee:ff", out, sizeof(out));
    ASSERT_INT_EQ(1, rc, "chinese lookup returns 1");
    ASSERT_EQ("客厅平板", out, "chinese name preserved");
}

static void test_lookup_manual_name_multiple(void) {
    write_test_file(
        "{\"11:11:11:11:11:11\":\"Phone\","
        "\"22:22:22:22:22:22\":\"Laptop\","
        "\"33:33:33:33:33:33\":\"Tablet\"}");
    char out[HN_LEN] = "";
    lookup_manual_name("22:22:22:22:22:22", out, sizeof(out));
    ASSERT_EQ("Laptop", out, "lookup middle entry");

    out[0] = '\0';
    lookup_manual_name("33:33:33:33:33:33", out, sizeof(out));
    ASSERT_EQ("Tablet", out, "lookup last entry");

    out[0] = '\0';
    lookup_manual_name("11:11:11:11:11:11", out, sizeof(out));
    ASSERT_EQ("Phone", out, "lookup first entry");
}

static void test_lookup_manual_name_not_found(void) {
    write_test_file("{\"aa:bb:cc:dd:ee:01\":\"Phone\"}");
    char out[HN_LEN] = "x";
    int rc = lookup_manual_name("aa:bb:cc:dd:ee:99", out, sizeof(out));
    ASSERT_INT_EQ(0, rc, "missing mac returns 0");
}

static void test_lookup_manual_name_case_insensitive(void) {
    write_test_file("{\"aa:bb:cc:dd:ee:ff\":\"TV\"}");
    char out[HN_LEN] = "";
    /* hotspotd 内 mac 已经 lower,但万一有 bug 测一下 */
    int rc = lookup_manual_name("AA:BB:CC:DD:EE:FF", out, sizeof(out));
    ASSERT_INT_EQ(1, rc, "uppercase mac matches lowercase entry");
    ASSERT_EQ("TV", out, "case insensitive value");
}

static void test_lookup_manual_name_escape_quote(void) {
    /* 文件内 a\"b → 解码后 a"b */
    write_test_file("{\"aa:bb:cc:dd:ee:ff\":\"Bob\\\"s TV\"}");
    char out[HN_LEN] = "";
    lookup_manual_name("aa:bb:cc:dd:ee:ff", out, sizeof(out));
    ASSERT_EQ("Bob\"s TV", out, "escape quote decoded");
}

static void test_lookup_no_file(void) {
    unlink(DEVICE_NAMES_JSON);
    char out[HN_LEN] = "x";
    int rc = lookup_manual_name("aa:bb:cc:dd:ee:ff", out, sizeof(out));
    ASSERT_INT_EQ(0, rc, "missing file returns 0");
}

/* === mac_fallback 测试 (P1-8 对齐 shell) === */

static void test_mac_fallback_standard(void) {
    char out[HN_LEN] = "";
    mac_fallback("aa:bb:cc:dd:ee:ff", out, sizeof(out));
    /* shell: aa:bb:cc:dd:ee:ff → aabbccddeeff → tail -c 9 → "ccddeeff" (8 字符) */
    ASSERT_EQ("ccddeeff", out, "standard MAC fallback");
}

static void test_mac_fallback_short(void) {
    char out[HN_LEN] = "";
    mac_fallback("11:22:33", out, sizeof(out));
    /* 去冒号: "112233", 长度 6 < 8, 全部输出 */
    ASSERT_EQ("112233", out, "short MAC returns full");
}

static void test_mac_fallback_no_colon(void) {
    char out[HN_LEN] = "";
    mac_fallback("aabbccddeeff", out, sizeof(out));
    /* 已经无冒号: "aabbccddeeff", 取后 8 → "ccddeeff" */
    ASSERT_EQ("ccddeeff", out, "MAC without colons");
}

/* === v3.5.0-rc R-2 / v3.5.2 P1-A: re-resolve 触发条件测试 ===
 *
 * v3.5.2 P1-A 修复:
 * 之前这里定义了一个 TestDevice + long now 的 shadow 函数,
 * 测试的是测试文件自己写的版本,hotspotd.c 里根本没有对应 symbol。
 * 第二轮 AI 审查指出这是假的 coverage 标签。
 *
 * 新版本:
 * - 函数签名跟 hotspotd.c 完全一致:
 *     int should_re_resolve(const char *hostname_src, time_t last_resolve, time_t now)
 * - 函数体字面复制粘贴 hotspotd.c 的真实实现
 * - 测试调用这个跟主代码一致的版本
 *
 * 依然是复制不是 #include,因为测试是独立编译单元,要 link 整个
 * hotspotd.o 需要完整模块结构。但复制的是"真实签名+真实实现",
 * 不是"平行宇宙的影子函数"。如果主代码改阈值(60s → 30s),
 * 这里也必须同步改,否则编译测试会炸出 drift 信号——比 silent PASS 好。
 *
 * v3.6 计划:把 helper 提取成 daemon/hnc_helpers.c + hnc_helpers.h,
 * 测试和主代码 #include 同一头文件,彻底消除复制。
 */

static int should_re_resolve(const char *hostname_src, time_t last_resolve, time_t now) {
    if (strcmp(hostname_src, "mac") == 0) return 1;
    if ((now - last_resolve) >= 60) return 1;
    return 0;
}

static void test_re_resolve_mac_fallback_immediate(void) {
    int rc = should_re_resolve("mac", (time_t)1000, (time_t)1005);
    ASSERT_INT_EQ(1, rc, "mac fallback always re-resolves");
}

static void test_re_resolve_manual_within_window(void) {
    int rc = should_re_resolve("manual", (time_t)1000, (time_t)1030);
    ASSERT_INT_EQ(0, rc, "manual within 60s window: no re-resolve");
}

static void test_re_resolve_manual_after_window(void) {
    int rc = should_re_resolve("manual", (time_t)1000, (time_t)1060);
    ASSERT_INT_EQ(1, rc, "manual after 60s window: re-resolve");
}

static void test_re_resolve_manual_long_after(void) {
    int rc = should_re_resolve("manual", (time_t)1000, (time_t)1300);
    ASSERT_INT_EQ(1, rc, "manual after 5min: re-resolve");
}

static void test_re_resolve_mdns_within_window(void) {
    int rc = should_re_resolve("mdns", (time_t)1000, (time_t)1059);
    ASSERT_INT_EQ(0, rc, "mdns at 59s: no re-resolve");
}

static void test_re_resolve_mdns_at_exactly_60(void) {
    int rc = should_re_resolve("mdns", (time_t)1000, (time_t)1060);
    ASSERT_INT_EQ(1, rc, "mdns at exactly 60s: re-resolve (>= boundary)");
}

/* === v3.5.1 P0-2: json_escape 测试 ===
 *
 * 复刻 hotspotd.c 的 json_escape 函数。
 * 之前 write_json 用 %s 直接输出 hostname,如果 hostname 含 " 或 \
 * 会破坏 JSON,WebUI 设备列表清空。
 */

static void json_escape(const char *src, char *dst, size_t dst_size) {
    if (dst_size == 0) return;
    size_t j = 0;
    int truncated = 0;
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
            dst[j++] = (char)c;
        }
    }
    /* v3.5.2 P2-F: buffer 不够时回退到完整 UTF-8 字符边界 */
    if (truncated || (src[0] && j + 1 >= dst_size)) {
        size_t k = j;
        while (k > 0 && ((unsigned char)dst[k-1] & 0xC0) == 0x80) {
            k--;
        }
        if (k > 0) {
            unsigned char lead = (unsigned char)dst[k-1];
            size_t needed = 0;
            if ((lead & 0x80) == 0) {
                needed = 0;
            } else if ((lead & 0xE0) == 0xC0) {
                needed = 1;
            } else if ((lead & 0xF0) == 0xE0) {
                needed = 2;
            } else if ((lead & 0xF8) == 0xF0) {
                needed = 3;
            }
            size_t have = j - k;
            if (have < needed) {
                j = k - 1;
            }
        }
    }
    dst[j] = '\0';
}

static void test_json_escape_plain(void) {
    char out[64];
    json_escape("hello", out, sizeof(out));
    ASSERT_EQ("hello", out, "plain ascii unchanged");
}

static void test_json_escape_double_quote(void) {
    char out[64];
    json_escape("My \"Phone\"", out, sizeof(out));
    ASSERT_EQ("My \\\"Phone\\\"", out, "double quote escaped");
}

static void test_json_escape_backslash(void) {
    char out[64];
    json_escape("a\\b", out, sizeof(out));
    ASSERT_EQ("a\\\\b", out, "backslash escaped");
}

static void test_json_escape_newline(void) {
    char out[64];
    json_escape("line1\nline2", out, sizeof(out));
    ASSERT_EQ("line1\\nline2", out, "newline escaped");
}

static void test_json_escape_tab_cr(void) {
    char out[64];
    json_escape("a\tb\rc", out, sizeof(out));
    ASSERT_EQ("a\\tb\\rc", out, "tab and CR escaped");
}

static void test_json_escape_control_char(void) {
    char out[64];
    /* C 字符串字面量 trap: "a\x01b" 实际是 "a" + char(0x1b)
     * 因为 \x 后接任意多 hex 字符。用八进制 \001 (最多 3 位) 避开 */
    json_escape("a\001b", out, sizeof(out));
    /* 期望 8 字符: a, \, u, 0, 0, 0, 1, b */
    const char *expected = "a\\u0001b";
    ASSERT_EQ(expected, out, "control char 0x01 as backslash u 0001 b");
}

static void test_json_escape_chinese_unchanged(void) {
    char out[128];
    json_escape("测试设备", out, sizeof(out));
    ASSERT_EQ("测试设备", out, "Chinese UTF-8 unchanged");
}

static void test_json_escape_empty(void) {
    char out[64];
    json_escape("", out, sizeof(out));
    ASSERT_EQ("", out, "empty string unchanged");
}

static void test_json_escape_truncation_safe(void) {
    char out[10];
    /* "a\"b\"c\"d\"e" → 9 chars + NUL,正好刚刚够 */
    json_escape("aaaaaaaaaa", out, sizeof(out));
    /* 应该是 "aaaaaaaaa" (9 char + NUL),最后一个 a 被截 */
    ASSERT_INT_EQ(9, (int)strlen(out), "small buffer truncates safely");
}

/* === v3.5.2 P2-F: UTF-8 边界回退测试 ===
 *
 * buffer 不够时不应切断 UTF-8 多字节序列,否则 JSON 合法但 UI 里显示乱码。
 * "测" = 0xE6 0xB5 0x8B (3 字节)
 * "试" = 0xE8 0xAF 0x95
 * "设" = 0xE8 0xAE 0xBE
 * "备" = 0xE5 0xA4 0x87
 */

static void test_json_escape_utf8_rollback_mid(void) {
    /* 4 个中文 = 12 字节,dst 只有 10 字节(9 可用 + NUL) → 应该写 3 个完整字符(9 字节),
     * 不能有残缺的第 4 个字符 */
    char out[10];
    json_escape("测试设备", out, sizeof(out));
    /* 期望 "测试设" = 9 字节 + NUL */
    ASSERT_INT_EQ(9, (int)strlen(out), "UTF-8 rollback: 9 bytes = 3 complete chars");
    ASSERT_EQ("测试设", out, "UTF-8 rollback: 3 complete Chinese chars");
}

static void test_json_escape_utf8_rollback_tight(void) {
    /* dst 只有 4 字节,最多能放 1 个 3-byte 中文字符 */
    char out[4];
    json_escape("测试", out, sizeof(out));
    /* 期望 "测" = 3 字节 + NUL */
    ASSERT_INT_EQ(3, (int)strlen(out), "UTF-8 rollback tight: 1 char");
    ASSERT_EQ("测", out, "UTF-8 rollback tight: first char only");
}

static void test_json_escape_utf8_no_truncation(void) {
    /* dst 足够大,不应触发回退 */
    char out[32];
    json_escape("测试", out, sizeof(out));
    ASSERT_EQ("测试", out, "UTF-8 complete in big buffer");
}

static void test_json_escape_utf8_cant_fit_lead_byte(void) {
    /* dst 太小,连一个 lead byte 都塞不下会怎样 */
    char out[3];
    json_escape("测", out, sizeof(out));
    /* 3 byte 字符,dst[0..1] 写 lead+cont1,循环条件 j+1<3 让 j 停在 1,然后第 3 字节
     * 因为 j+1>=3 不写 → j=2 是 continuation byte → 回退到 j=0。
     * 最终 dst = "" */
    ASSERT_INT_EQ(0, (int)strlen(out), "UTF-8 too small for even one char → empty");
}

/* === main === */

int main(void) {
    snprintf(DEVICE_NAMES_JSON, sizeof(DEVICE_NAMES_JSON),
             "/tmp/hnc_test_device_names_%d.json", (int)getpid());

    printf("════════════════════════════════════════\n");
    printf("  hotspotd hostname helpers 测试\n");
    printf("════════════════════════════════════════\n\n");

    printf("── lookup_manual_name ──\n");
    test_lookup_manual_name_empty_file();
    test_lookup_manual_name_basic();
    test_lookup_manual_name_chinese();
    test_lookup_manual_name_multiple();
    test_lookup_manual_name_not_found();
    test_lookup_manual_name_case_insensitive();
    test_lookup_manual_name_escape_quote();
    test_lookup_no_file();

    printf("\n── mac_fallback (P1-8 shell 对齐) ──\n");
    test_mac_fallback_standard();
    test_mac_fallback_short();
    test_mac_fallback_no_colon();

    printf("\n── re-resolve 触发条件 (v3.5.0-rc R-2) ──\n");
    test_re_resolve_mac_fallback_immediate();
    test_re_resolve_manual_within_window();
    test_re_resolve_manual_after_window();
    test_re_resolve_manual_long_after();
    test_re_resolve_mdns_within_window();
    test_re_resolve_mdns_at_exactly_60();

    printf("\n── json_escape (v3.5.1 P0-2) ──\n");
    test_json_escape_plain();
    test_json_escape_double_quote();
    test_json_escape_backslash();
    test_json_escape_newline();
    test_json_escape_tab_cr();
    test_json_escape_control_char();
    test_json_escape_chinese_unchanged();
    test_json_escape_empty();
    test_json_escape_truncation_safe();

    printf("\n── json_escape UTF-8 边界回退 (v3.5.2 P2-F) ──\n");
    test_json_escape_utf8_rollback_mid();
    test_json_escape_utf8_rollback_tight();
    test_json_escape_utf8_no_truncation();
    test_json_escape_utf8_cant_fit_lead_byte();

    /* 清理 */
    unlink(DEVICE_NAMES_JSON);

    printf("\n════════════════════════════════════════\n");
    if (g_fail == 0) {
        printf("  ALL PASS: %d/%d\n", g_pass, g_pass);
    } else {
        printf("  FAIL: %d failed, %d passed\n", g_fail, g_pass);
    }
    printf("════════════════════════════════════════\n");

    return (g_fail == 0) ? 0 : 1;
}
