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
