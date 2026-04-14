# HNC HACKING 指南

> **谁应该读这个**
>
> - 想给 HNC 贡献代码的人
> - 6 个月后忘了当初为什么这么写的作者本人 ← **主要读者**
> - 想 fork HNC 做魔改的开发者

这不是教学文档(那是 [README.md](README.md) 的事)。**这是避雷文档**:记录了从 v3.4 到 v3.6 开发过程中真实踩过的坑,以及当前代码为什么这么写。每一条都带**具体的文件+行号+版本锚点**,将来搜关键词就能定位决策。

HNC 经历过**三轮独立 AI 代码审查** + 多次真机事故,下面 12 个坑都是**真实发生过的事**,不是"理论上可能"。

---

## 📐 快速心智模型

HNC = **Hotspot Network Control**。让 Android 手机的个人热点对每台连接客户端做**限速 / 延迟注入 / 黑名单 / mDNS 命名**。

### 运行时组件

```
┌────────────────────────────────────────────────────┐
│  KernelSU/SukiSU Ultra (或 Magisk + MMRL)          │
│  ├─ module loader                                  │
│  │   └─ service.sh (post-boot)                    │
│  │        ├─ 拉起 watchdog.sh                      │
│  │        ├─ 拉起 device_detect.sh daemon (wrapper)│
│  │        │    └─ 启动 bin/hotspotd (C daemon)     │
│  │        └─ (api/server.sh 已废弃,P1-11)           │
│  └─ WebUI (browser in KSU manager)                 │
│       └─ webroot/index.html                        │
│            └─ window.ksu.exec() ← kexec() → root shell │
└────────────────────────────────────────────────────┘
```

### 核心进程树

```
watchdog.sh          ← 1 分钟一次 health check + 子服务重启
hotspotd (C daemon)  ← netlink RTMGRP_NEIGH 事件驱动 + UNIX socket IPC
device_detect.sh     ← fallback shell daemon(只在 C 失败时)
```

**只有一个活跃路径**:**要么** hotspotd(C),**要么** device_detect shell daemon fallback,**绝不并存**。互斥靠 `hotspotd.pid` 和 `detect.pid` 两个文件语义 + `daemon.spawn` 锁(见 [坑 6](#坑-6-detectpid-和-hotspotdpid-必须互斥)).

### 数据文件

```
/data/local/hnc/
├── data/
│   ├── devices.json       ← hotspotd 周期性写,WebUI 读
│   ├── rules.json         ← 限速/延迟/黑名单规则,cfg_set 写
│   ├── device_names.json  ← 手动命名(MAC → 用户给的名字)
│   └── config.json        ← HNC 全局配置
├── run/
│   ├── hotspotd.pid       ← C daemon 模式
│   ├── detect.pid         ← shell fallback 模式
│   ├── watchdog.pid
│   ├── hotspotd.sock      ← IPC socket
│   └── daemon.spawn/      ← 目录作为 mkdir-based 互斥锁
└── logs/
    ├── hotspotd.log
    ├── watchdog.log
    └── detect.log
```

### 核心数据流:一个 action 从 WebUI 到 iptables

用户点 "应用限速 10 Mbps":

```
WebUI applyLimit(mac, ip)
  │
  ├─ lockMac(mac)                                        // 防快速点击 (v3.4.11 P1-3)
  ├─ ensureInit()                                         // 确认 TC/iptables 结构存在
  ├─ kexec('iptables_manager.sh mark ...')               // 加 MARK 规则
  ├─ kexec('tc_manager.sh set_limit ...')                // 加 HTB + filter
  ├─ shUpdate({mark_id, ip, down_mbps, limit_enabled})   // 持久化到 rules.json
  │     └─ json_set.sh device(内部 acquire_lock PID 互斥)
  ├─ doRefresh()                                          // 2.5 秒后刷新 UI
  └─ verifyUploadLimit()                                  // 后台异步验证 ifb0 流量
```

**任何一步失败都会 toast 报错,设备 lock 永远释放**(then/catch 出口都 unlockMac)。

---

## 🚫 12 个已知的坑(绝对不要踩)

### 坑 1: MARK_BASE 必须避开 netd 的 fwmark 范围

**事故版本**: v3.4.0 之前
**文件**: `bin/iptables_manager.sh:8-25`, `webroot/index.html` (显示用 `0x800000 + mid`)

**症状**: 设置限速后,被限速的设备**完全失联**(访问不了任何网站)。未限速的设备正常。

**根因**: Android `netd` 使用 fwmark 范围 `0x10000-0xdffff` 做 policy routing(uid routing / VPN / tethering)。HNC v3.4 之前用 `MARK_BASE=0x10000` 作为基址,分配的 mark 落在 `0x10001-0x10063` 范围内,**直接冲突**。netd 的 routing rule 把这些 mark 当 uid marker 解释,送到错误的 routing table。

**当前值**: `MARK_BASE=0x800000`(bit 23)
- Android netd `0x10000-0xdffff` 段: ✅ 避开
- xt_socket `0xff000000` 段: ✅ 避开
- MPTCP / QoS: ✅ 空闲

**验证方法**: 在你的目标设备上,**修改 MARK_BASE 之前** 必须跑:

```sh
ip rule show | grep -i fwmark
ip rule show | awk '{print $0}' | grep -E '0x[0-9a-f]+'
```

看有没有任何 rule 的 fwmark 跟你想用的范围重叠。不是所有 Android 设备用同样的范围,某些 ROM 可能扩展 netd 的范围。

**如果你要改 MARK_BASE**: 同步改 `bin/iptables_manager.sh`、`daemon/hotspotd.c` 里的显示代码(`0x800000 + mid`),以及 `webroot/index.html` 的 MARK 显示(搜 `0x800000`)。**三处必须同步**。

---

### 坑 2: rules.json 必须保持单行 devices 段

**事故版本**: 暂未发生,但 v3.5.2 第三轮审查发现的 T7
**文件**: `bin/tc_manager.sh:582` (restore_rules), `bin/json_set.sh` (device 命令)

**症状(潜在)**: 重启 HNC 后,已有的限速规则**静默消失**。restore 没报错,但 tc filter 就是没加上。

**根因**: `restore_rules` 用 awk 在**单行 $0** 上扫 `"$mac": { ... }` 完整块。当前 `json_set.sh device` 命令把新设备插进 `"devices": {}` 这一行内部,保持单行。如果有人手动编辑 `rules.json` 或经过 `jq` 格式化,devices 段会被拆成多行,awk 的 `match($0, pat)` 只能匹配一行的开头,block 变量拿到的是不完整的 JSON,`mark_id` 抽不出来,restore 静默返回空。

**预防**:
- **永远不要**对 `rules.json` 跑 `jq .` 或任何 "美化" 工具
- 如果你必须 debug JSON,用 `jq . rules.json > /tmp/pretty.json`(写到**别处**)
- 如果怀疑 restore 失败: `awk '{print NR, length($0)}' rules.json` 看 devices 段是不是一行很长

**修复计划**: v3.6+ 可以检测多行 devices 段(`grep -c '"devices"'`),自动用 `tr -d '\n'` 临时压缩。当前没做。

---

### 坑 3: KSU kexec callback 必须是 global function 字符串

**事故版本**: v3.4.x 重构 kexec 时踩过
**文件**: `webroot/index.html:3283-3300`

**症状**: `kexec('sh xxx')` 调用后**永远不 resolve/reject**,Promise 挂死,后续 action 全部停。不是报错,是静默无响应。

**根因**: SukiSU / KernelSU 的 `window.ksu.exec(cmd, callback)` 底层是 Android `@JavascriptInterface`,**不能接收 JS function 引用**(那是 V8 的 heap 对象,跨 JNI 边界不存在)。它只能接收**字符串形式的 global function 名字**。

**错误写法(静默失败)**:
```js
window.ksu.exec('ls', function(exitCode, stdout, stderr) {  // ❌
    console.log(stdout);
});
```

**正确写法**:
```js
var cbName = '__kcb_' + (++__kcb);
window[cbName] = function(exitCode, stdout, stderr) {       // 挂到 window 全局
    delete window[cbName];
    // 处理结果
};
window.ksu.exec('ls', cbName);                              // 传字符串名字
```

参考 `webroot/index.html:3283` 的 `kexec()` 实现。**所有调 `window.ksu.exec` 的地方都必须走 `kexec()` 封装**,不要直接调。

**Magisk + MMRL** 和 **APatch** 也有类似限制,都用 `kexec()` 的统一路径。

---

### 坑 4: Android ash 的 `local` 关键字只能在函数体内

**事故版本**: v3.4.0 watchdog.sh 事故
**文件**: `bin/watchdog.sh`(当前代码已修,历史上踩过)

**症状**: `service.sh` 启动 `watchdog.sh` 后**立刻退出**,logcat 里看到 `local: not in a function` 错误。

**根因**: bash 支持 `local VAR=xxx` 在 script 顶层(它当作 global 处理)。**Android 的 `/system/bin/sh`(mksh/ash)不允许顶层 `local`**,直接报错终止脚本。

**规则**:
- `local` 只能在**函数体内**用
- 顶层 `while` / `for` / `if` 里的变量都是 global(不需要 local 声明)
- 如果你想限制作用域,**把代码包进一个函数**

**审查习惯**: 改任何 shell 脚本之前,先 `sh -n script.sh` 做语法检查。如果你用的是 bash,要额外 `dash -n script.sh` 做一次(dash 更接近 Android ash 的严格性)。

---

### 坑 5: `hotspotd -d` 后台化后 `$!` 不是真 PID

**事故版本**: v3.5.0 (P1-7)
**文件**: `daemon/hotspotd.c:write_pid()`, `bin/watchdog.sh` (历史上踩过)

**症状**: watchdog 每次试图 `kill -0 $pid` 判断 hotspotd 存活都失败(PID 不存在),然后立即 "重启",结果启了第二个实例,devices.json 被多个 writer 并发撕裂。

**根因**: `hotspotd -d` 自己做 **double-fork**(daemonize 的标准做法,脱离 controlling terminal + session leader)。shell 看到的 `$!` 是**中间层进程**的 PID,它立刻退出,留下真正的 daemon 进程。真 PID 只有 hotspotd 自己知道。

**规则**:
- ❌ **永远不要** `hotspotd -d & echo $! > hotspotd.pid`
- ✅ 让 hotspotd **自己** `write_pid()`(O_EXCL 创建,写 `getpid()`)
- ✅ shell 侧 `sleep 1` 等它写完,再 `cat hotspotd.pid` 读

当前实现见 `daemon/hotspotd.c:write_pid()`(v3.5.2 P1-D 修复,O_EXCL + 活性检查)。

**验证**:
```sh
# 装机后
ps -A | grep hotspotd
cat /data/local/hnc/run/hotspotd.pid
# 两个 PID 应该**一致**
```

---

### 坑 6: detect.pid 和 hotspotd.pid 必须互斥

**事故版本**: v3.5.1 P0-A(catastrophic architecture race)
**文件**: `service.sh:140-160`, `bin/watchdog.sh:check_services()`

**症状**: 长跑几小时后,`devices.json` 周期性破损(JSON parse error),WebUI 设备列表清空。同时 `hotspotd.pid` 文件消失,watchdog 失明。

**根因**: v3.5.1 之前,`service.sh` 同时写 `echo $HPID > detect.pid` 和 `hotspotd.pid`(两个文件存同一个 PID)。watchdog 的 `check_services` 有**两个独立 if**:一个检查 hotspotd.pid,一个检查 detect.pid。hotspotd 崩溃后:
1. 第一个 if 看到 hotspotd 死,重启 C daemon A
2. 第二个 if **没有 elif**,继续检查 detect.pid,也看到"死",**同时**启 device_detect.sh shell wrapper
3. shell wrapper 里的 daemon_shell_fallback 启第二个 hotspotd 实例 B
4. A 和 B **同时**写 devices.json.tmp → `rename()` 破坏
5. B 的 cleanup 无条件 `unlink(PID_FILE)` → A 的 PID 文件消失
6. watchdog 看不到任何 PID → 永远失明

**修复(v3.5.2 三层防御)**:
1. **语义互斥**: C daemon 模式下 `detect.pid` **不存在**(service.sh 显式 `rm -f`)
2. **优先级检查**: watchdog.sh `check_services` 先检查 hotspotd.pid,如果活着直接 `return 0`,**不看** detect.pid
3. **spawn 锁**: `daemon.spawn` 目录作为 mkdir-based 互斥,任何时候只有一个进程能 spawn hotspotd

**验证**:
```sh
ls /data/local/hnc/run/*.pid
# C daemon 模式: 只有 hotspotd.pid + watchdog.pid
# shell fallback 模式: 只有 detect.pid + watchdog.pid
# **绝不能同时看到 hotspotd.pid 和 detect.pid**
```

**如果你以后重构 watchdog**,**必须保持这个不变量**:**hotspotd 活着时不检查 detect.pid**。

---

### 坑 7: mdns_resolve 只接受 IP 作为参数

**事故版本**: v3.5.1 P0-1
**文件**: `daemon/hotspotd.c:261`, `daemon/mdns_resolve.c` (argv 解析)

**症状**: hotspotd 里 hostname 永远是 mac 兜底,mdns **从来没发过 DNS query**。

**根因**: v3.5.0 的调用方式:
```c
snprintf(cmd, sizeof(cmd), "%s -t 800 %s %s 2>/dev/null", BIN, ip, mac);  // ❌
```

传了 `<ip> <mac>` 两个位置参数。但 `mdns_resolve.c` 的 argv 循环对**任何非 flag 参数**都赋给 `ip` 变量:
```c
while (*++argv) {
    if ((*argv)[0] == '-') { /* flag */ }
    else { target_ip = *argv; }  // mac 覆盖了 ip
}
```
结果 `target_ip` 变成 mac 地址字符串,`inet_pton()` 必然失败,mdns 从未发出过查询。

**修复**: 只传 IP:
```c
snprintf(cmd, sizeof(cmd), "%s -t 800 %s 2>/dev/null", BIN, ip);  // ✅
```

**教训**: **argv 位置参数循环覆盖是隐性 bug**,没有任何编译/测试能自动发现。如果你要给 `mdns_resolve` 加新参数,用 flag(如 `-m <mac>`),不要加位置参数。

---

### 坑 8: 所有 kexec 里的 user input 必须 shellQuote

**事故版本**: v3.5.0 (saveHotspotConfig / testHotspotNow / editName injection)
**文件**: `webroot/index.html:shellQuote`, 所有 action 函数

**症状**: 恶意 WiFi SSID(如 `"; rm -rf /; #`)能 RCE 整个手机。

**根因**: 之前代码:
```js
kexec('sh iptables_manager.sh mark "'+ip+'" "'+mac+'" '+mid);  // ❌
```
用双引号拼接,但 ip/mac 如果含 `$`, \`, `\`, `"` 都会破坏 shell parsing,最坏情况 RCE。

**规则**:
- 所有 `kexec()` 里的变量插值**必须用 `shellQuote()`**
- `shellQuote()` 的实现用**单引号包裹 + 对内部单引号做 `'\''` 转义**,这是 shell 里**唯一**绝对安全的引用方式
- **永远不要**依赖"数据源格式约束"(比如 "mac 是 hotspotd.c 格式化出来的,保证没有特殊字符")。**今天成立,明天有人加新数据源就失效**

**已修复的调用点**(v3.5.1 + v3.6 T1):
- saveHotspotConfig, testHotspotNow, editName (v3.5.1)
- applyLimit, clearLimit, applyDelay, addBlacklist, rmBlacklist, shUpdate (v3.6 T1)

**规则的 meta 版本**: 任何传出 WebUI / user input 的数据,都**永远**要 shellQuote,**不管**数据源看起来多"受控"。

---

### 坑 9: json_escape 必须支持 UTF-8 边界回退

**事故版本**: v3.5.2 P2-F
**文件**: `daemon/hnc_helpers.c:hnc_json_escape()`

**症状(潜在)**: 用户给设备起很长的中文名字(> 60 字节),devices.json 里出现 "�" replacement character 或乱码,WebUI 显示异常。

**根因**: JSON escape 时如果输出 buffer 不够,**不能直接 break** — 这样可能在 UTF-8 多字节序列中间截断(中文 3 字节,emoji 4 字节),留下孤立的 continuation byte(0xB0-0xBF)。JSON parser 接受任何 UTF-8 字节序列为合法,但 `JSON.parse()` 之后字符串里出现 replacement character。

**正确的回退算法**:
1. 从当前位置往前扫,找最后一个 **non-continuation byte**(ASCII 或 lead byte)
2. 检查它需要多少 continuation(1/2/3 根据 lead byte 的高位 bit)
3. 检查已经写入了多少 continuation
4. 如果**不足**,**删掉整个残缺字符**(回退到 lead byte 之前)

**规则**: 任何 UTF-8 安全的 string 处理函数,**buffer 不够时都要做完整字符边界回退**。

**我在实现这个的时候发现的 bonus bug**: 最初的版本只看 "是不是 lead byte 就 `j--`",这会把**已经完整的字符也删掉**。正确的做法是**同时检查 have ≥ needed**,只有不完整才 `j = k - 1`。见 `hnc_helpers.c` 的注释,以及 `test_hostname_helpers.c` 的 4 个 UTF-8 边界测试。

---

### 坑 10: device_names.json 的 hostname 查找不能崩在 `"` 上

**事故版本**: v3.5.1 P0-2(和 坑 9 同时修的)
**文件**: `daemon/hnc_helpers.c:hnc_lookup_manual_name()`, `daemon/hotspotd.c:write_json()`

**症状**: 用户把设备命名为 `My "Phone"`(含双引号),之后 devices.json **完全破坏**,WebUI 设备列表清空。

**根因**:
1. `device_names.json` 里存的是 JSON escape 后的 `"mac":"My \"Phone\""`
2. `lookup_manual_name` 读回来解 escape 得到 `My "Phone"` 放进 `d->hostname`
3. `write_json` 用 `%s` 直接输出 `d->hostname` 到 devices.json
4. 未 escape 的 `"` 破坏 JSON 结构

**修复**(v3.5.1 P0-2):
- `lookup_manual_name` 正确解 JSON escape(`\"` → `"`, `\\` → `\`)
- `write_json` 输出 hostname 时必须走 `hnc_json_escape()`
- 两处缺一不可

**规则**: 任何从外部文件读出的字符串,写回 JSON 时**都要重新 json_escape**。假设它已经 escaped 是错的(因为经过 strcpy 可能已经解过 escape)。

---

### 坑 11: 测试绝对不能写 shadow function

**事故版本**: v3.5.0-rc R-2(AI 审查发现,v3.5.2 P1-A 修复,v3.6 Commit 2 彻底消除)
**文件**: `daemon/test/test_hostname_helpers.c`, `daemon/hnc_helpers.h`

**症状**: **测试 100% 通过,但主代码完全没被测到**。改主代码的阈值(60s → 30s)测试**永远 silent PASS**。假的 coverage 标签。

**事故详情**: v3.5.0-rc 写 R-2 测试时,test 文件定义了:
```c
typedef struct { ... } TestDevice;
static int should_re_resolve(TestDevice *d, long now) {  // ❌ 平行宇宙
    return d->last_resolve < now - 60;
}
```
**hotspotd.c 里根本没有这个 symbol**。主代码是两处**内联 if**:
```c
} else if (strcmp(d->hostname_src, "mac") == 0 || (now - d->last_resolve) >= 60) {
```
测试测的是 TestDevice + 平行 should_re_resolve,**跟主代码毫无关联**。AI 审查第二轮指出:"R-2 覆盖"是**假的 coverage 标签**。

**修复过程**:
- **v3.5.2 P1-A**: 提取 `should_re_resolve(const char *, time_t, time_t)` 成真函数,测试用相同签名**复制**(依然是复制,但签名对齐,drift 时会编译报错)
- **v3.6 Commit 2**: 提取到 `hnc_helpers.c` + `.h`,测试 `#include "../hnc_helpers.h"` + link 同一个 `hnc_helpers.o`,**彻底消除复制**

**规则**:
- **永远不要**在测试文件里定义跟主代码**同名但无关联**的函数
- 如果主代码的 helper 不好提取,**宁可不测它**,也别写 shadow
- 最好的做法:**提取成 helpers .c/.h**,主代码和测试 link 同一个 symbol
- 第二好的做法:**文本复制但签名完全一致**,drift 时编译报错

**元教训**: 我自己(作者)写这个 shadow 的时候**知道**它是平行宇宙的,但为了快速加测试 coverage 没澄清。**这是 dishonesty**。之后的 AI 审查抓到了,修复的 commit 里我明确承认了这件事(见 CHANGELOG v3.5.2 的 P1-A 段)。

**如果你写 HNC 的测试**: 每个测试的函数调用**必须**能 `grep` 到主代码的同名 symbol(或者通过 link-time 符号解析能映射到)。

---

### 坑 12: scan_arp 和 nl_process 的新设备路径绝不能同步调 mdns

**事故版本**: v3.5.2 P0-B(审查发现,v3.6 Commit 3 修复)
**文件**: `daemon/hotspotd.c:scan_arp()`, `nl_process()`, `process_pending_mdns()`

**症状(理论)**: 30 台设备同时上线时,主线程被阻塞 ~24 秒(每设备 popen `mdns_resolve -t 800`,串行)。期间:
- netlink socket 积压事件 → ENOBUFS → kernel 丢包 → 设备永久从 g_devs[] 消失
- UNIX socket IPC 挂起 → WebUI 无响应
- 恶意本机进程发 `REFRESH\n` 即可 DoS hotspotd

**根因**: v3.5.0 到 v3.5.2 的 scan_arp 对每个新设备调:
```c
resolve_hostname(mac, ip, ...);  // ❌ 内部同步 popen mdns_resolve -t 800
```
1 台 800ms,30 台 24 秒。主线程是单个 select loop,阻塞期间什么都不做。

**修复(v3.6 Commit 3,"pending 模式")**:
1. scan_arp / nl_process 新设备改调 `hnc_resolve_hostname_fast`(只做 manual 查找 + mac 兜底,~1μs)
2. 如果落到 mac 兜底,标 `hostname_src = "pending"` + 记 `pending_since = now`
3. 主循环每次 tick 调 `process_pending_mdns()`:
   - 找 `pending_since` 最老的 pending 设备(FIFO)
   - 如果挂 pending < 1 秒,跳过(给 netlink 事件 breathing room)
   - **一次最多解 1 个**,最坏 ~800ms
   - 成功 → src=mdns,失败 → src=mac
4. WebUI 显示 pending 状态为 `⏳` 图标

**保证**:
- 主线程永不阻塞超过 ~800ms
- N 台设备同时上线 → N 秒内全部解完(比 24 秒好 30 倍)
- 单线程模型不变,signal safety 保持,不引入锁/线程

**规则**:
- **scan_arp / nl_process 里永远不能 popen**(除了 v3.5.2 P1-A 留下的 re-resolve 路径,那是改名场景,不在瓶颈上)
- **任何新的 "从 netlink 路径反查信息" 的需求,都必须走 pending 模式**:填兜底值 + 标 pending + 异步解
- 如果你要加 DHCP hostname 查询 / ARP 反查 / 其他外部 lookup,**照抄 pending 模式**

---

### 坑 13: shell 脚本写 tmp 文件**必须**加 `$$` PID 后缀

**事故版本**: **v3.6.0 发布当天(2026-04-13)真机事故**,v3.6.1 修复
**文件**: `bin/device_detect.sh:do_scan_shell()` 的 json 写入行

**症状**: 用户点"释放所有资源"按钮后,WebUI 设备列表**完全空白**。WebUI 顶部统计显示"在线 N",但下面一个设备卡片都没有。查看 `devices.json`:

```json
{
  "e2:0d:4a:48:5d:40": {
    "ip": "10.118.156.30",
    "hostname": "mi10",
    "hostname_src": "manual",
    "iface": "",                    ← 空字符串
    "status": "wlan2|allowed"       ← 接口名和 status 被 | 粘在一起
  }
}
```

`iface` 字段是空的,`status` 字段是 `"wlan2|allowed"`(这个值从来不应该出现 — 正常是 `"allowed"` 或 `"blocked"`)。

**根因**: **并发写同一个 tmp 文件的字节级 race condition**。

事故场景:
1. 用户点"释放所有资源"(09:25:45) → `cleanup.sh` 按预期杀掉 hotspotd + watchdog(这是**正确行为**,不是 bug)
2. WebUI 检测不到 hotspotd,后续的 `doRefresh` 或用户点"刷新设备列表"触发 `device_detect.sh scan`
3. 命令 `device_detect.sh scan` 走 `do_scan_shell()` 路径(因为 hotspotd 已死)
4. shell scan 的执行时间约 5-10 秒(要调 iptables ensure_stats + stats_all + awk /proc/net/arp + 组装 JSON)
5. 在这窗口内,WebUI 的 2.5 秒 polling 会再次触发 scan → **多个 shell scan 进程并发**
6. 每个 scan 写到**同一个固定路径** `devices.json.tmp`(**没有 PID 后缀**)
7. kernel 不保证 `write(2)` 对 regular file 的原子性 → 两个并发 `printf > devices.json.tmp` 的字节流**交错混合**
8. 最终产生一个"看似合法 JSON,但字段语义错乱"的文件

**为什么错乱成 `"iface":"","status":"wlan2|allowed"`**: 
两个 scan A 和 B 的 printf 输出在 byte 级交错,A 的 `"iface":"wlan2","rx_bytes":...` 和 B 的 `"iface":"","...","status":"allowed"` 字节混合后,刚好拼出合法 JSON 语法,但 `iface` 变空串、`wlan2|` 被吃进 `status` 字段。这种交错每次都不一样,但**一旦出现,WebUI 的 `cardHTML()` 渲染某些字段(比如 `d.status === 'blocked'` 判断)会产生意外行为**,整个 render loop 抛 TypeError,设备列表变空白。

**修复(v3.6.1)**: tmp 路径加 `$$`(shell PID)后缀:

```sh
# 旧代码(race condition)
printf '%s' "$json" > "${DEVICES_FILE}.tmp" && \
    mv "${DEVICES_FILE}.tmp" "$DEVICES_FILE"

# 新代码(并发安全)
local tmp_out="${DEVICES_FILE}.tmp.$$"
printf '%s' "$json" > "$tmp_out" && mv "$tmp_out" "$DEVICES_FILE"
```

每个 scan 子进程有自己的 PID,tmp 文件路径唯一,**并发 printf 互不干扰**。最后的 `mv` 是原子 rename(kernel 保证),谁后 mv 谁赢(last-write-wins),但每个 tmp 文件本身都是完整合法的 JSON。

**同时更新 trap** 清理以避免进程异常退出时留下 `devices.json.tmp.$$` 文件。

**元教训 A — "纵深防御对齐"**: 
这个问题 v3.5.2 P0-A 审查**抓到了一半**。当时 hotspotd.c 的 `DEVICES_TMP_FMT` 宏已经改成了 `"devices.json.tmp.%d"`(带 PID 后缀),并且有注释明确写:

> *"v3.5.2 P0-A 修复:tmp 路径带 PID 后缀,避免跟 shell daemon 路径(bin/device_detect.sh do_scan_shell 用 devices.json.tmp)的字节级冲突。"*

**C 侧修了,shell 侧没跟上**。这是**典型的半修复** — 审查员发现了 A 和 B 两条路径的冲突,但只修了 A 侧的防御,觉得"A 和 B 永远不会同时跑"(因为 P0-A 的三层防御机制保证 C daemon 和 shell daemon 互斥)。

**盲点**: "B 和 B 自己并发跑" — 也就是 `device_detect.sh scan` 命令(单次 scan,不是 daemon 模式)可以被**同一时刻多次调用**。WebUI 的 2.5 秒 polling + 用户点刷新按钮,很容易触发这种并发。审查员没想到这个场景。

**元教训 B — "凡是 shell 写 tmp 必须 `$$`"**:
这是一个**绝对规则**。只要 shell 脚本用 `> file.tmp` 或 `> file.lock` 做"先写临时文件再 mv"模式,**永远**都要加 `$$`:

```sh
# ❌ 错
echo "$data" > /tmp/foo.tmp && mv /tmp/foo.tmp /tmp/foo

# ✅ 对
echo "$data" > /tmp/foo.tmp.$$ && mv /tmp/foo.tmp.$$ /tmp/foo
```

不管你认为"这个脚本只会被 cron 每分钟调一次不会并发",**用户迟早会想办法让它并发**(点按钮两次、多个终端、watchdog 重启),**规则是规则**,不要找借口。

**元教训 C — "真机事故是最好的 fuzz 测试"**:
三轮独立 AI 审查都没找到这个 bug。它在沙箱里**没法复现**(因为沙箱单进程跑不了 WebUI polling)。v3.6.0 发布当天,**用户主动点"释放所有资源"按钮 + WebUI 继续刷新** 的场景几秒钟内就暴露了。

**真实使用的意外行为,比审查员的想象力更丰富**。没有任何 CI 能模拟"用户点按钮的速度"。真机长跑 + 真实人类操作 = 最强 fuzz 测试。

**如何检测这个 bug 之外的同类问题**: `grep -rn "\.tmp['\"]" bin/ daemon/ service.sh post-fs-data.sh` 找所有没 `$$` 的 tmp 文件,逐一检查是否可能并发。

---

### 坑 14: v3.6.0 webroot devIcon ReferenceError

**事故版本**: v3.6.0 发布当天,v3.6.2 修复
**文件**: `webroot/index.html` 的 `cardHTML()` 函数

**症状**: 装机后 WebUI 完全空白。顶部统计显示"在线 1",下面一个设备卡片都没有。F12 console 一行红色 `ReferenceError: devIcon is not defined`。

**根因**: v3.6.0 Commit 6 做了一次 webroot 精简,**删除了 `devIcon` 这个变量的声明**(原本基于 iface 给设备加前缀图标,后来觉得多余),但**忘记删除 `cardHTML()` 里对 `devIcon` 的引用**。

```javascript
// Commit 6 删掉了这行
// var devIcon = (d.iface === 'wlan2') ? '📱' : '💻';

// 但这行忘了删
var cardHTML = '<div class="dev-card">' + devIcon + ' ' + name + ...;
//                                         ^^^^^^^ ReferenceError
```

JavaScript 严格模式下,引用未声明变量直接抛 `ReferenceError`。cardHTML 抛错 → render loop 中断 → 整个 WebUI 空白。

**为什么没被抓到**: HNC 的 JS 没有 linter,没有 TypeScript,没有 bundler。单元测试不覆盖 WebUI。Commit 6 的 diff 本身看起来"删得很干净" — 删的是变量声明,谁会想到还有个函数引用它?

**修复(v3.6.2)**: 回退 Commit 6 的所有 webroot 改动,保留 devIcon 的声明。

**元教训**: **删变量必须 grep 整个 repo**。任何删除变量 / 函数 / CSS 类 / API 的 commit,前置 checklist:

```bash
# 删之前必做
grep -rn "devIcon" webroot/ bin/ api/ daemon/ test/
# 如果有任何非自身的引用,删除前必须先改掉引用
```

这条规则同样适用于:
- 删 Shell 函数前 `grep -rn "函数名" bin/ service.sh`
- 删 C 函数前 `grep -n "函数名(" daemon/`
- 删 JSON 字段前 grep 所有 JS + shell + C 代码
- 删 CSS class 前 grep HTML + JS

**元教训 2**: **CI 里至少跑一次 headless JS 加载检查**。哪怕只是 `node -e "require('jsdom').JSDOM.fromFile('webroot/index.html')"` 都能抓到 `ReferenceError`。HNC 没这个因为沙箱里没 headless 浏览器,但是值得在 v3.9 加。

---

### 坑 15: `dumpsys network_stack` 才是 Android 14+ DHCP 状态的真实来源

**发现版本**: v3.7.0

**背景**: HNC 长期想显示设备的真实 hostname(比如"Mi-10"、"DESKTOP-ABC123"),而不是 MAC 后 8 位兜底。之前尝试过:

1. **dnsmasq.leases** — Android 原生用 netd/NetworkStack,**没有 dnsmasq**。只有 LineageOS 等少数 ROM 有,返回 `not found`。
2. **logcat DhcpClient** — 正确位置,但 `logcat` 默认只保留几分钟,设备连了 1 小时后再看就没了,而且需要 `system_server` 权限才能读完整 logcat。
3. **mDNS 反向查询** (by IP) — 成功率 30-40%,而且每次 800ms 阻塞。
4. **被动嗅探 DHCPREQUEST** — 需要 raw socket + 复杂的包解析,overkill。

**真实路径**(第 5 次尝试): `dumpsys network_stack`。Android 14+ 的 NetworkStack 是一个 **mainline module**(通过 Google Play System Update 独立更新),它把所有 DHCP 事件写到**内存 ring buffer**,dumpsys 能 dump 出来。每条格式:

```
2026-04-13T16:43:31 - [wlan2.DHCP] Transmitting DhcpAckPacket with lease
  clientId: XXX, hwAddr: 7a:d6:f7:ce:ba:76, netAddr: 10.201.76.69/24,
  expTime: 4968921,hostname: Mi-10
```

只要客户端发了 DHCP option 12,这里就有。35ms 拿到,零网络成本。

**为什么之前没想到**: `dumpsys` 在我脑子里的默认印象是"看 service 状态" — 比如 `dumpsys activity` / `dumpsys battery`。没意识到 `network_stack` 里有完整的 ring buffer。第二个 AI 在咨询中指出这条路径。

**元教训**: **Android 的数据源不在传统 Linux 路径里**。HNC 写了几年都在 `/proc/net/arp` 和 `dnsmasq` 里找数据,其实 Android 的核心网络栈数据全在 `netd` / `NetworkStack` / `system_server` 里,要通过 `dumpsys` / `cmd` / `binder` 查。下次找数据**先 `dumpsys list | grep <关键字>`**,再考虑 `/proc`。

---

### 坑 16: 同步路径和异步路径必须一起改 (v3.7.0 → v3.7.1)

**事故版本**: v3.7.0 发布后真机立刻发现,v3.7.1 修复
**文件**: `daemon/hotspotd.c:process_pending_mdns()`

**症状**: v3.7.0 装机后,Mi-10 连进来,WebUI 显示 "Android" 60 秒,之后才变成 "Mi-10"。

**根因**: v3.7.0 做了两件事:
1. 给 `resolve_hostname()` 加了 DHCP 查询分支
2. 让 `scan_arp` 的 re-resolve 路径(60 秒窗口触发)调用新版 `resolve_hostname`

**但忘了**: `process_pending_mdns()` 是 v3.6 Commit 3 加的**异步 pending 处理路径**,它**直接调 `try_mdns_resolve()`**,绕过了 `resolve_hostname`。新设备首次连接时走 pending 路径,**只查 mDNS,不查 DHCP**。Mi-10 的 mDNS 返回 "Android"(OEM 通用名),pending 处理写入 `hostname_src="mdns"`,60 秒后 re-resolve 才走完整链拿到 "Mi-10"。

```c
// v3.7.0 的 process_pending_mdns (BUG)
char new_hn[HN_LEN];
if (try_mdns_resolve(oldest->ip, oldest->mac, new_hn, sizeof(new_hn))) {
    // ← 绕过了 resolve_hostname 的 DHCP 查询
    strncpy(oldest->hostname, new_hn, ...);
    snprintf(oldest->hostname_src, ..., "mdns");
}
```

**怎么发现的**: 我推理了 3 次都走偏(怀疑时序 / write_json / cache 污染),最后从真机日志 `pending→mac mdns failed` 和代码追踪才定位。**armchair debugging 浪费 30 分钟,真机数据 5 分钟定位**。

**修复(v3.7.1)**: `process_pending_mdns` 改调 `resolve_hostname` 完整链。15 行改动。

**元教训**: **任何函数加新逻辑,必须 grep 所有调用点确认都会走到新逻辑**。这个 bug 的根源是 v3.7.0 diff 审查时我只看了 "resolve_hostname 改动是否正确" 和 "scan_arp 调用点是否正确",**没审查 "还有谁调 try_mdns_resolve / 还有谁在绕过 resolve_hostname"**。

v3.7.0 前应该做的检查:

```bash
# 1. 谁调 resolve_hostname?
grep -n "resolve_hostname(" daemon/hotspotd.c
# → scan_arp 的 re-resolve 分支 ✓
# → nl_process 的 re-resolve 分支 ✓

# 2. 谁直接调 try_mdns_resolve,绕过 resolve_hostname?
grep -n "try_mdns_resolve(" daemon/hotspotd.c
# → resolve_hostname 里 1 处(内部调用,OK)
# → process_pending_mdns 里 1 处(← 这个是 BUG,但我没看)

# 3. 谁写 hostname_src?
grep -n '"mdns"' daemon/hotspotd.c
# 同上
```

**一个更强的规则**: **不要有"重复实现同一个优先级链"的多个函数**。`process_pending_mdns` 里拷贝了 `resolve_hostname` 的简化版,注定会 drift。未来如果还需要"只查部分步骤"的变种,也要**共享同一个底层函数 + 参数化跳过步骤**,而不是复制粘贴。

v3.7.2 的 `resolve_hostname_dhcp_only` 是复制了一部分,但至少结构跟 `resolve_hostname` 一一对应,容易同步。真正的修复在 v3.8 后期考虑 — 把 `resolve_hostname` 改成 `resolve_hostname(flags, ...)` 接收 `INCLUDE_MDNS` / `INCLUDE_DHCP` 等标志。

---

### 坑 17: MAC 白名单 off-by-one → RCE (v3.7.0 → v3.7.2)

**事故版本**: v3.7.0 潜伏,Gemini 审查发现,v3.7.2 修复
**文件**: `daemon/hotspotd.c:try_ns_dhcp_resolve()`

**症状**: 代码审查时 Gemini 一眼看穿。本地沙箱 5 个 payload 测试验证可绕过。

**代码**:

```c
int i;
for (i = 0; mac[i] && i < 17; i++) {
    char c = mac[i];
    if (!((c >= '0' && c <= '9') || ... || c == ':')) {
        return 0;
    }
}
if (i != 17) return 0;  // ← 只检查循环跑了 17 次
// 没有检查 mac[17] == '\0'
```

**攻击 payload**: `"11:22:33:44:55:66;reboot"`

- 循环校验**前 17 个字符**(全合法) → `i` 递增到 17 → 循环条件 `i < 17` 为 false → 退出
- `if (i != 17)` 通过
- **`mac[17]` 是 `;` 从未被检查**
- 随后这个字符串被 `snprintf(cmd, ..., "dumpsys ... | grep -iF %s ...", mac)` 拼进 shell 命令
- shell 看到 `;`,执行 `reboot`
- **RCE 在 root 权限下**

**实际威胁评估**: 几乎不可触发。
- MAC 地址来自 netlink ARP neigh 事件
- 内核的 `struct nda_lladdr` 是定长 6 字节 binary
- HNC 自己用 `snprintf("%02x:%02x:%02x:%02x:%02x:%02x", ...)` 格式化,永远是精确 17 字符
- **不可能有外部攻击者构造畸形 MAC 送进来**

**但这不是不修的理由**。修复成本 1 行,白名单校验 bug 就是 bug,**防御深度原则**不容妥协。

**修复(v3.7.2)**: 

```c
if (i != 17 || mac[17] != '\0') return 0;
```

更彻底的修复是改用 `fork + execlp` 代替 `popen`,彻底抛弃 shell 参与。v3.7.2 一并做了(同时解决坑 18 和 19)。

**元教训 A — "循环终止条件后必须显式检查 `[i] == '\\0'`"**:

```c
// ❌ 错:只检查循环跑了 N 次,没检查字符串恰好 N 字符
for (i = 0; s[i] && i < N; i++) { ... }
if (i != N) return 0;

// ✅ 对:同时检查 N 字符 AND 第 N+1 个是 NUL
for (i = 0; s[i] && i < N; i++) { ... }
if (i != N || s[N] != '\0') return 0;

// ✅ 或:先检查长度
if (strnlen(s, N+1) != N) return 0;
for (i = 0; i < N; i++) { ... validate ... }
```

**元教训 B — "whitelist 的 bug 就是 bug,不接受'实际不可触发'作为免修理由"**:

安全代码的审查原则:
1. **假设调用方是恶意的**,即使当前调用方不是
2. **假设明天有人加新的调用方**,他不知道内部约定
3. **假设这段代码被 copy 到别的项目**,那里的调用链不同

HNC 的 `try_ns_dhcp_resolve` 现在只被 `resolve_hostname` 调,但明天如果有人加一个 IPC 命令 `GET_DHCP_NAME <mac>` 从 socket 读 MAC 直接传进来,原本的 RCE 就真的可触发。

**元教训 C — "AI 审查是基础设施"**: 

6 轮审查(Claude 自审 + 5 次外部 AI)有 5 次都漏掉了这个 bug。只有 Gemini 在明确要求"严格质疑所有输入校验"的情况下找到。这告诉我:
- Claude 的自审存在盲点(特别是自己写的代码)
- 代码 review 看 diff 的审查方式,天然会漏掉"调用关系"和"边界条件"
- 外部 AI 审查必须**明确要求找特定类型的 bug**,才能跳出"礼貌同意"模式

v3.7.2 之后 HNC 定下规则: **任何涉及 `popen/execlp/权限/内存/并发`的 P0 代码改动**必须经过外部 AI 审查才能发布。见"AI 审查流程"章节。

---

### 坑 18: popen 没超时 → system_server 卡死时主循环冻死

**事故版本**: v3.7.0 潜伏,v3.7.2 修复
**文件**: `daemon/hotspotd.c:try_ns_dhcp_resolve()` — 旧 popen 版本

**背景**: v3.7.0 用 `popen("dumpsys network_stack 2>/dev/null | grep -iF %s", mac)` 查 DHCP hostname。正常情况 35ms 返回,很快。

**潜伏 bug**: **`popen` 没有任何超时机制**。如果 `system_server` 卡死(ColorOS 后台杀手 / Doze 模式切换 / VPN 重连风暴 / kernel 资源紧张),`dumpsys` 是 binder 调用,会**无限期阻塞**等待 `system_server` 响应。

- hotspotd 主循环被 `popen` 的 `fgets()` 卡住
- netlink 事件队列积压
- WebUI IPC 请求超时
- watchdog 检测到 hotspotd 心跳异常
- **watchdog 重启 hotspotd**
- 重启后马上又被 `system_server` 卡住
- 死循环雪崩

**为什么没爆发**: 我的测试环境是 realme RMX5010 + SD8 Elite,system_server 卡死的频率低。如果是低端机或者负载高的机器,**一夜崩溃无限次**完全可能。

**发现**: Gemini 审查直接指出"popen 是同步阻塞调用,需要带超时的替代方案"。

**修复(v3.7.2)**: 完全重写 `try_ns_dhcp_resolve` 为 `fork + execlp + select(500ms 超时) + kill(SIGKILL) + waitpid`:

```c
pid_t pid = fork();
if (pid == 0) {
    dup2(pipefd[1], STDOUT_FILENO);
    execlp("dumpsys", "dumpsys", "network_stack", NULL);
    _exit(127);
}

// 父进程 select 超时 500ms
fd_set rd; FD_SET(pipefd[0], &rd);
struct timeval tv = {0, 500 * 1000};
int ret = select(pipefd[0] + 1, &rd, NULL, NULL, &tv);
if (ret == 0) {
    kill(pid, SIGKILL);  // 超时击杀
}
waitpid(pid, NULL, 0);   // 收割
```

真机测试: 用 `sleep 5` 模拟卡死的 dumpsys,**501ms** 后被 SIGKILL 收割。

**元教训 A — "任何外部命令都必须有硬超时"**:

规则很简单,但容易忘:

```c
// ❌ 任何 popen / system / 阻塞 read 没超时都是 bug
FILE *pf = popen(cmd, "r");
while (fgets(...)) { ... }

// ✅ 必须用 fork + select 或 timer
```

Shell 也一样:

```sh
# ❌
result=$(dumpsys something)

# ✅
result=$(timeout 0.5 dumpsys something)
```

**元教训 B — "ColorOS 比原生 Android 脆弱 10 倍"**:

ColorOS / MIUI / HarmonyOS 的后台管控逻辑非常激进:Doze 模式会冻结 system_server 的部分子系统,电源策略会延迟 binder 响应,VPN 重连风暴会耗尽 binder 线程池。**在 AOSP 上 35ms 返回的调用,在 ColorOS 上偶尔 5 秒,极端情况永远不返回**。

开发 Android root 模块的经验值: 任何同步调用预期耗时乘以 30,作为超时下限。`dumpsys` 预期 35ms → 超时至少 1 秒。我在 v3.7.2 用了 500ms,因为 `select` 超时后 kill 是干净退出,**宁可偶尔 false-positive 杀掉正常调用也不能让主循环冻死**。

---

### 坑 19: pclose "总是执行"的假设很脆弱 → 僵尸进程

**事故版本**: v3.7.0 潜伏,v3.7.2 修复
**文件**: `daemon/hotspotd.c:try_ns_dhcp_resolve()` — 旧 popen 版本

**代码模式**:

```c
FILE *pf = popen(cmd, "r");
if (!pf) return 0;

while (fgets(line, sizeof(line), pf) != NULL) {
    // parse 逻辑
    // ... 30 行代码 ...
}

int rc = pclose(pf);  // ← 依赖上面的所有分支都会走到这里
```

**问题**: 当前代码确实没有 early return,`pclose` 总是被调用。**但未来维护者加一个 `if (...) return 0;` 到循环里**,pclose 会被跳过,留下:
- 僵尸进程(子进程退出后父进程没 wait,占用 process table slot)
- 文件描述符泄漏(pf 对应的 pipe fd 没 close)

**极端场景**: 高负载(大量 pending 设备)+ 某个 early return 被触发,一分钟产生 60 个僵尸,系统 `ps` 变慢,最终 fork 失败。

**这种 bug 的可怕之处**: 代码审查看单次函数体觉得"OK 结构清晰",但系统性问题需要**分析所有控制流路径**才能发现。Gemini 审查指出了这个风险。

**修复(v3.7.2)**: 改用 `fork + execlp` 后,waitpid 在所有退出路径(包括 SIGKILL 超时)之后**无条件执行**:

```c
waitpid(pid, &status, 0);  // 函数退出前最后一步,所有路径都会到
```

**元教训 — "资源清理不要靠控制流自然走到"**:

C 语言几个强制资源清理模式,按推荐度排序:

1. **集中 cleanup + goto**: 

```c
int func(void) {
    FILE *pf = popen(...);
    char *buf = malloc(...);
    int result = 0;

    if (!buf) { result = -1; goto cleanup; }
    if (error_cond_1) { result = -2; goto cleanup; }
    // ... main logic ...
    result = parse_result;

cleanup:
    if (pf) pclose(pf);
    if (buf) free(buf);
    return result;
}
```

2. **RAII 宏**(GCC `__attribute__((cleanup))`):

```c
static inline void _close_pf(FILE **pp) { if (*pp) pclose(*pp); }
#define CLEANUP_PCLOSE __attribute__((cleanup(_close_pf)))

int func(void) {
    CLEANUP_PCLOSE FILE *pf = popen(...);
    // pf 自动 pclose,即使 early return
}
```

3. **fork + waitpid** (v3.7.2 的选择): 控制流集中在父进程底部 waitpid,子进程独立地址空间无泄漏。**功能比 popen 强(可以超时 + SIGKILL),资源管理比 popen 简单**。

**绝对禁止**: 让 pclose / close / free 分散在函数体中间的 if-else 里,依赖"正常控制流"走到。

---

### 坑 20: 同步调用链需要端到端测试,不是函数单测

**教训版本**: v3.7.0 发布前检查漏洞,v3.7.1 事故,v3.8 才补上对策

**背景**: 坑 16 (v3.7.0 → v3.7.1) 的根本问题是:
- `resolve_hostname()` 的单测覆盖了所有分支(manual/dhcp/mdns/mac 优先级)
- `process_pending_mdns()` 的 pending 逻辑单测覆盖了 FIFO 选择
- **但没有一个测试验证"pending 路径最终会走到 resolve_hostname"**

两个函数**单独**测都是绿的,合起来**坏**。这是典型的**单元测试覆盖不到集成问题**。

**应对**: 需要 **调用链级端到端测试**。HNC v3.8.2(阶段 3)已完成对策,采用**方案 G (Include + 同名 static 覆盖)**。

**方案选择历程**(是 v3.8.2 最大的设计决策,记录在案以便未来参考):

第一次尝试: **方案 E (契约测试 + drift 检测)** — 在测试文件里重新实现
resolve_hostname 的"规范版本",用 mock 驱动,另外写 awk 脚本对比
hotspotd.c 和测试里的 src 序列。凌晨 3 点选的,**不是好方案**:

- 本质是"shim 复制",两份代码都是执行逻辑
- drift 检测只看表面字符串,抓不到控制流变化
- 测的不是真代码

Gemini 审查明确指出方案 E 是"testing the mock 反模式"。

第二次尝试: **方案 F (`-Wl,--wrap` link-time mocking)** — Gemini 推荐。
**smoke test 失败**:`--wrap` 只能拦截**跨 translation unit** 的
undefined reference。hotspotd.c 里 `resolve_hostname` 调用
`try_ns_dhcp_resolve`,两者在同一个 .c 文件里,编译器在 .o 生成阶段
就把 call 绑定到本文件地址,链接器无从介入。

验证过程:写了一个最小 smoke test,同 TU 时 `--wrap` 完全不工作,
跨 TU 时工作。objdump 反汇编验证 call 指令直接硬编码本文件地址。

最终方案: **方案 G (Include + 同名 static 覆盖)** — Gemini 二次咨询给的。

- hotspotd.c 顶部加 try_mdns_resolve / try_ns_dhcp_resolve 的 `static` 前向声明
- 这两个函数的**定义**搬到文件底部,连同 `main()` 一起用 `#ifndef HNC_TEST_MODE` 包围
- `test_call_chain.c` 定义 `HNC_TEST_MODE` 然后 `#include "../hotspotd.c"`
- 测试文件自己提供同名 static 函数作为 mock
- 编译器看到两份定义候选:hotspotd.c 里的被 `#ifdef` 屏蔽,测试里的生效
- `resolve_hostname` 里的 `call try_ns_dhcp_resolve` 被解析到测试里的 mock

关键优势:
- **测的是 100% 真实的 resolve_hostname 机器码**,不是 shim 重实现
- 零 drift 风险(没有复制代码)
- 生产代码只有 1 处 `#ifndef`,可读性几乎不受影响
- hotspotd.c 符号表和原版完全一致(nm diff 通过)
- v3.8.4 pthread 改造时可以扩展:mock 函数里插 `usleep()` 测试线程调度

实际测试代码(27 个测试全过):

```c
// test_call_chain.c
#define HNC_TEST_MODE 1
#include "../hotspotd.c"

/* Mock 定义(替换被 #ifdef 屏蔽的真实定义) */
static int try_ns_dhcp_resolve(const char *mac, char *out, size_t outlen) {
    /* 查 g_mock_dhcp 数组... */
}

int main(void) {
    mock_dhcp_set("7a:d6:f7:ce:ba:aa", "Mi-10");
    mock_mdns_set("7a:d6:f7:ce:ba:aa", "Android");

    char hn[64], src[16];
    resolve_hostname_dhcp_only("7a:d6:f7:ce:ba:aa", hn, 64, src, 16);

    /* 这是真实的 resolve_hostname_dhcp_only,如果它绕过 DHCP 直接调 mDNS,
     * hn 就会是 "Android" 而非 "Mi-10",坑 16 回归 */
    assert(strcmp(hn, "Mi-10") == 0);
}
```

**元教训 A**: **任何跨函数的关键逻辑都需要"组装测试",而不是只测组件**。
HNC 的测试策略 v3.8 之后从"单元覆盖"升级为"调用链覆盖"。

**元教训 B**: **C 语言的测试方案选择要用 smoke test 验证,不要相信
"业界最佳实践"的直接推荐**。Gemini 的方案 F 看起来很专业,但在 HNC
的单文件结构下直接失败。如果没有 30 行的 smoke test,我们会花 1-2 小时
改 hotspotd.c 然后发现根本跑不起来。

**元教训 C**: **外部 AI 审查是有效的,但不能盲从**。Gemini 第一轮审查
指出方案 E 是反模式,是对的;但第一轮推荐的方案 F 有 TU 边界假设错误。
第二轮给出方案 G 才是可行方案。**"严格质疑"和"用数据验证"比"礼貌同意"
重要**。

---

### 坑 21: netem delay 的"作者意图 vs 用户直觉"语义冲突

**教训版本**: v3.3.2 (2025-10) 埋下,v3.8.5 (2026-04) 修复 — **存在 6 个月**

**背景**: v3.3.2 重构 set_delay 时,作者(过去的自己)写了:

```sh
set_netem_only "$iface"     "$class_id" "$delay_ms" ...  # wlan2 egress
set_netem_only "$IFB_IFACE" "$class_id" "$delay_ms" ...  # ifb0 ingress
log "  Netem applied: ${delay_ms}ms ... (both dirs)"
```

作者的心智模型是"**真实对称弱网模拟**":双向各加 delay_ms,更接近真实
蜂窝网络的表现。log 里明确写了 `(both dirs)`。

但是用户的心智模型是"**ping RTT 增量**":我设 200ms,ping 看到的 RTT
应该比不设时涨 200ms。用户根本不知道 "both dirs" 意味着 RTT 翻倍。

**症状**: 用户设 200ms,ping 看 400ms。用户设 250ms,ping 看 500ms。
永远是两倍,"好像 bug 了"。

**排查路径**:
1. 用户反馈"延迟翻倍" — 模糊的症状
2. Claude 写 hnc_delay_debug.sh 脚本读 tc 状态
3. `tc qdisc show` 显示 wlan2 和 ifb0 **都**有 netem delay 200ms
4. 临时手动 `tc qdisc change` 把两方向各改成 125ms
5. ping RTT 从 503 降到 270 — 验证"除以 2 分给两方向"是对的
6. grep tc_manager.sh 找到 set_delay 的源码,确认是 v3.3.2 的刻意设计

**修复** (v3.8.5):

```sh
# 用户输入的 delay_ms 现在是 RTT 视角,内部除以 2 分给两方向
local delay_eg delay_ig
if gt0 "$delay_ms"; then
    delay_eg=$(( (delay_ms + 1) / 2 ))  # egress 向上取整
    delay_ig=$(( delay_ms / 2 ))         # ingress 向下取整
fi
set_netem_only "$iface"     "$class_id" "$delay_eg" "$jitter_ms" "$loss"
set_netem_only "$IFB_IFACE" "$class_id" "$delay_ig" "$jitter_ms" "$loss"
```

奇数精度保留:101 → 51 + 50(总和 101,无损失)。

**元教训 A**: **技术正确 ≠ 用户可理解**。v3.3.2 的"对称双向 netem"技术上
更真实,但用户根本感知不到"真实"的价值,只感知到"数字对不上"。优先满足
用户的心智模型,而不是技术的理论优雅。

**元教训 B**: **log 里的提示"(both dirs)"只有代码作者能看懂**。普通
用户看 log 不知道 "both dirs" 意味着 RTT 翻倍。如果这个提示写成
"delay applied to both egress and ingress, RTT will increase by 2x"
就不会出问题。**技术术语要翻译成用户能理解的后果**。

**元教训 C**: **jitter 和 loss 的双向数学不简单**。作者的第一反应是"那
jitter 也除以 2",但:
- jitter 是独立随机源,合并后 RTT jitter ≈ √2 × 单方向(不是 2×)
- loss 是百分比,端到端 loss ≈ 2p(小 p 时),精确反算要 `p = 1-√(1-target)`

两者都需要浮点运算,在 shell 里不划算。**v3.8.5 的决策是:只修 delay,
jitter/loss 保持每方向语义,在 WebUI 上明确标注**。这是务实的妥协,
避免把简单的修复变成复杂的数学项目。

**元教训 D**: **长期遗留的"作者意图问题"只有用户反馈才能暴露**。v3.3.2
到 v3.8.4,6 个月内所有版本都有这个问题,所有测试都过,所有 CI 都绿。
因为**测试只测了代码符合作者意图,没测代码符合用户直觉**。真正暴露问题
的是用户的一句话"好像翻倍了"。

**用户反馈是最好的测试集**,没有之一。

---

## 🛡️ AI 审查流程(v3.7.2 之后的标准步骤)

HNC 项目每次 **P0 级改动** 发布前**必须**经过外部 AI 审查。

**什么是 P0 级改动**:

- 涉及 `popen` / `execlp` / `system` 等外部命令
- 涉及 `fork` / `pthread` / `signal` 等并发原语
- 涉及权限变更(`chmod` / `setuid` / `capabilities`)
- 涉及内存操作(指针、动态分配、缓冲区)
- 涉及安全边界(IPC 输入、shell 拼接、SQL/JSON 构造)
- 涉及并发数据结构(共享全局状态、锁、无锁数据结构)
- 任何会导致"真机一出问题整个 HNC 不可用"的改动

**审查流程**:

1. **本地跑全套测试**(Shell 64 + C hostname_helpers 50 + C mdns_parse 11 + 相关新增)
2. **Claude 自审** — 但不接受"我觉得没问题"作为充分理由
3. **生成审查文档** `HNC_vX.Y.Z_audit_prompt.md`,含:
   - 完整代码 diff(所有改动)
   - 调用关系上下文(被谁调,调谁)
   - 设计目标和取舍
   - 20+ 个明确的审查问题,按 P0/P1/P2/P3 分级
   - 末尾"额外发现"区,鼓励找没列出的问题
4. **发给外部 AI**(Gemini / GPT / 独立 Claude 实例),要求**严格质疑,不要礼貌**
5. **处理反馈**:
   - P0 必修(不修不发)
   - P1 评估(当次修 or 明确延后到哪个版本)
   - P2/P3 归档到 ROADMAP.md 或 HACKING.md
6. **CI 编译 + arm64 binary artifact**
7. **真机装机验证**(`diag.sh` + 核心场景手动测试)
8. **至少观察 30 分钟**真机运行(v3.7.0 的 bug 20 分钟暴露)

**已验证有效**:

| 审查事件 | 发现 | 影响 |
|---|---|---|
| v3.6.3 前 Gemini 审查 | REFRESH DoS (P1) + socket 0666 权限 (P1) | 避免了 DoS 攻击面 + 本地信息泄漏 |
| v3.7.0 设计阶段咨询 | 指出 `dumpsys network_stack` 路径 | 让核心功能能工作 |
| v3.7.2 前 Gemini 审查 | **真 RCE (P0) + popen 阻塞 (P0) + 僵尸进程 (P1) + grep 精度 (P2)** | 修复了 5 个潜在线上事故 |

**外部 AI 审查不是"可选优化",是"发布基础设施"**。

**什么情况可以跳过**: 只有以下改动可以跳过外部审查:
- 纯文档更新(README / HACKING / CHANGELOG)
- 纯测试代码新增(不改产品代码)
- Shell 脚本里的字符串改动(不改控制流)
- WebUI 的纯 CSS / 文案改动

**其他所有改动默认需要审查**。

---

## 🧪 测试策略

### 测试架构

```
test/                         ← Shell 测试
├── lib.sh                    ← 测试框架(assert_eq, log, etc.)
├── run_all.sh                ← 总入口
└── unit/
    ├── test_framework_sanity.sh  ← 15 个自检
    ├── test_json_set.sh          ← 30 个 json_set.sh 测试
    └── test_iptables_tc.sh       ← 19 个 iptables/tc 测试

daemon/test/                  ← C 测试
├── test_hostname_helpers.c   ← 50 个 helper 单元测试 (v3.6)
└── test_mdns_parse.c         ← 11 个 mDNS 解析测试
```

**总 125 测试**(v3.6),全部在 CI 上自动跑。

### 跑测试

```sh
# 所有 shell 测试
sh test/run_all.sh

# 单个 shell suite
sh test/unit/test_json_set.sh

# C 测试(需要 link hnc_helpers.c)
cd daemon/test
gcc -Wall -Wextra -o test_hostname_helpers \
    test_hostname_helpers.c ../hnc_helpers.c
./test_hostname_helpers

gcc -Wall -Wextra -o test_mdns_parse test_mdns_parse.c
./test_mdns_parse
```

### 加新测试的规则

1. **先确认你要测的函数在主代码里真的存在**(避开 坑 11 shadow function)
2. **测试名要描述行为**,不是描述实现:
   - ✅ `test_pending_ready_at_breathing_room_boundary`
   - ❌ `test_pending_ready_case_3`
3. **每个测试必须独立**,不依赖前面测试的副作用(v3.6 的测试都用 pid-unique 临时文件路径)
4. **边界条件优先**:0/1/最大/最小/刚好/刚过,这些是 bug 最多的地方
5. **负例也要测**:NULL 输入,empty string,错误 JSON 等防御性代码

### smoke test(真机验证)

`hnc_smoke_test.sh`(单独文件,不在 zip 里)跑以下检查:
- 模块装成功(module.prop 存在)
- hotspotd 进程存在且 PID 文件一致
- **P0-A 验证**: `hotspotd.pid` 和 `detect.pid` 不同时存在
- devices.json 含 `hostname_src` 字段
- 测试框架能跑

**真机验证是 CI 无法替代的**。每次 release 前至少跑一次。

---

## 🚢 发布流程

### 版本号规则

- `vMAJOR.MINOR.PATCH`
- `versionCode` = `MAJOR*10000 + MINOR*100 + PATCH`(v3.6.0 = 3600)
- **pre-release tag**(alpha/beta/rc)不触发正式 Release,**只**上传 artifact
- 正式 tag 触发 GitHub Release 创建 + release notes 从 CHANGELOG 提取

### 发布节奏

不要乱用 alpha/beta/rc。**默认直接发正式版**。只有以下情况才用 pre-release:
- 架构级改动需要真机长跑验证(比如 v3.5.0 beta1 的 hotspotd C daemon)
- 想让部分用户先试 feature 但不愿意作为 LTS 承诺

**v3.5.0 final 和 v3.5.1 就是因为"急着发正式版"跳过了 beta → 踩了 P0**。v3.5.2 和 v3.6.0 都是从 commit 到 release 之间没有 pre-release,但**前面有非常完善的测试 + AI 审查**兜底。

### 每次 release 前必做

1. **全套测试绿色**(125 测试)
2. **真机装机 smoke test 通过**
3. **至少一轮独立审查**(AI 或真人)
4. **CHANGELOG 写完整**(不是"fix bug"水账,是具体的 P0/P1/P2 每一条)
5. **ROADMAP 更新**(当前版本状态 + v3.X+1 planning)
6. **bump 版本**(module.prop + bin/diag.sh + webroot about-ver + smoke test expectation)

6 处版本号 — **缺一处 smoke test 会报警**。

### 审查轮次

v3.5 历史证明:

- **第 1 轮审查**: 找显性安全 bug(注入 / 格式化 / 覆盖)
- **第 2 轮审查**: 找架构 bug(race / 阻塞 / 资源协调)
- **第 3 轮审查**: 找回归 / 盲区 / 长跑风险
- **4 轮以上**: **不必要**。边际收益低于启动下一版本。

**HNC v3.5 系列在第 3 轮审查后正式停止 v3.5 的审查**(没出 v3.5.3)。v3.6 也应该最多 3 轮。**超过 3 轮通常是作者自己不自信,不是代码需要**。

---

## 🔧 常见任务

### 添加一个新的 action(比如 "reset device stats")

1. **Shell 侧**: 在 `bin/iptables_manager.sh` 加子命令 `reset_stats <mac>`
2. **Daemon 侧**: 可选,如果需要 hotspotd 配合
3. **WebUI 侧**: `webroot/index.html` 加 `window.resetStats = function(mac) { ... }`
4. **测试**: 加 `test/unit/test_iptables_tc.sh` 的 case
5. **绑按钮**: `cardHTML` 里加 `<button onclick="event.stopPropagation();window.resetStats(...)">`
6. **务必** 所有 kexec 里的 mac 用 `shellQuote(mac)` 包裹(坑 8)

### 扩展 hotspotd 的 IPC 命令

1. 当前支持: `GET_DEVICES` / `REFRESH` / `PING`
2. `daemon/hotspotd.c:handle_client()` 加新命令
3. **recv buffer** 当前是 `char req[64]`(见 T10),新命令如果 > 16 字节要调大
4. **所有新命令必须是非阻塞的**(坑 12):不能在 handle_client 里 popen / scan / mdns
5. 只能设**标志位**(像 `g_need_scan`),让主循环异步处理

### 修改 `should_re_resolve` 的阈值

从 `hnc_helpers.c:hnc_should_re_resolve()` 一处修改即可。主代码和测试都 link 同一个 symbol,不需要改别的地方(坑 11 的治本解)。

测试里的阈值断言(如 `test_re_resolve_manual_after_window` 用 1060)也要对应调整。

### 调试 hotspotd 的异常行为

```sh
# 1. 看日志
tail -100 /data/local/hnc/logs/hotspotd.log

# 2. 确认进程状态
ps -A | grep hotspotd
cat /data/local/hnc/run/hotspotd.pid
ls /data/local/hnc/run/

# 3. 确认 spawn lock 没被卡住
ls -la /data/local/hnc/run/daemon.spawn 2>/dev/null && \
    echo "WARN: spawn lock 存在,可能卡死(见坑 6)"

# 4. 手动触发 scan
kill -USR1 $(cat /data/local/hnc/run/hotspotd.pid)

# 5. 读 devices.json 确认 write 工作
cat /data/local/hnc/data/devices.json | head -20

# 6. IPC 验证
echo "PING" | nc -U /data/local/hnc/run/hotspotd.sock
# 应该返回 "OK"
```

---

## 📜 版本速查

每个大版本修了什么(详细见 CHANGELOG.md):

- **v3.4.10**: LTS 基线,只修 bug
- **v3.5.0**: 测试框架 + CI + hotspotd C daemon ❌ DEPRECATED(4 个 P0)
- **v3.5.1**: 显性功能正确性 ❌ DEPRECATED(P0-A 架构 race)
- **v3.5.2**: daemon 生命周期架构成熟(三层防御 + helpers 分离)✅ Released
- **v3.6.0**: 技术债清理 + helpers 提取 + scan_arp pending 异步 ✅
- **v3.6.3**: Gemini 审查 P1 修复 ✅
- **v3.7.0**: DHCP hostname(dumpsys network_stack)✅,但坑 16 导致 v3.7.1
- **v3.7.1**: pending 路径 DHCP 修复(坑 16 对策)✅
- **v3.7.2**: Gemini 发现的 5 个 P0(含真 RCE:fork+execlp 重写)✅
- **v3.8.0**: OUI 查表 444 条 + dumpsys 格式探针 + 坑 14-20 + AI 审查流程 ✅
- **v3.8.1**: hostname cache 持久化 + diag.sh 假警报修复 ✅
- **v3.8.2**: 调用链真代码集成测试(方案 G: include + 同名 static 覆盖)✅
- **v3.8.3**: OUI 表 444→907 条(+广覆盖厂商)+ 用户 OUI 覆盖机制 ✅ (当前)

**v3.5.0 → v3.5.2 是 "发三次被 AI 审查毙两次" 的历史**。看 CHANGELOG 的 v3.5.x 段能学到:
- 真 P0 长什么样
- 第二轮审查比第一轮更狠(从显性 bug 到架构 race)
- 什么时候该停止审查(v3.5.2 的三轮结论)

---

## 💭 元教训(给未来的自己)

### 关于代码

1. **架构决策比实现技巧重要**。v3.5.2 P0-A 不是某个字符转义错了,是 daemon 生命周期状态机设计错了。**修 race 的正确方式是消除 race 可能性,不是加 workaround**。

2. **"数据源格式约束"是脆弱的防线**。今天 mac 是 hotspotd.c 格式化出来的"安全",明天加个 nmap 扫描脚本就失效。**defense-in-depth 比正确性证明更耐操**。

3. **YAGNI 是真的**。v3.6 考虑过 pthread + 队列,最终用了简单的 pending 模式。**并发模型一升级,整个代码库正确性保证面 reset**。能不用就不用。

4. **测试的 coverage 必须是真的**。shadow function 是我 guilty 的例子。**宁可没测试,也别写假测试**,因为假测试会让你以为已经安全了。

### 关于流程

5. **多轮审查有递减收益,但前 3 轮几乎必出真 P0**。第 3 轮的"没找到真 bug"本身是有价值的信号(说明代码已经稳定),不是审查员偷懒。

6. **CHANGELOG 要写得像法律文件**,不是像 git log。每条 P0 都要有:触发条件 / 复现路径 / 根因 / 修复策略 / 验证方法。**未来的你会感谢现在的你**,因为 6 个月后你不会记得 "v3.5.1 P0-A 到底是咋回事"。

7. **疲劳驱动的工程是 P0 的温床**。v3.5.2 三层防御是凌晨 2 点写的 — 幸运的是 AI 审查兜底了。**不要连续高强度工作超过 6 小时再碰并发代码**。

### 关于项目

8. **单人项目最常见的死法不是代码,是作者不想维护了**。为了可持续性:
   - 写 HACKING.md(你正在读的这个)
   - 把 v3.6 拆成 v3.6.0 + v3.6.1(不要一次吞下 BPF 研究)
   - 不追求 star / 用户数 — HNC 自己用得爽就够了

9. **没有用户抱怨不等于没有 bug,有 bug 不等于必须立刻修**。v3.5.2 的 T1-T12 都是真的存在但不影响真实使用的技术债,归到 v3.6 backlog。**排优先级的勇气比修 bug 的能力更稀缺**。

10. **每一个版本都应该能独立 checkout 编译跑**。不要 "这个 commit 半做完了下一个 commit 再修"。即使是 v3.6 的 Commit 1→Commit 6 流程,每一个 commit 后项目都能跑测试 + 装机。

---

## 📞 求助

- **事故恢复**:
  1. 停 HNC:`rm -rf /data/local/hnc/run/*.pid` + `pkill hotspotd`
  2. 清 spawn 锁:`rm -rf /data/local/hnc/run/daemon.spawn`
  3. 清 iptables:`sh /data/local/hnc/bin/iptables_manager.sh cleanup`
  4. 清 tc:`tc qdisc del dev wlan0 root 2>/dev/null`
  5. 重启 HNC:`sh /data/local/hnc/service.sh`

- **如果以上都不行**: 重启手机。HNC 是 post-fs-data 模块,重启会重跑一遍 init。

- **真的坏了**: 在 KSU manager 里禁用 HNC 模块,重启,手机恢复正常,再决定要不要重装。

---

**最后更新**: v3.6.0 发布时 (2026-04-13)
**下次更新触发条件**: v3.7 架构改动,或者发现新的坑
