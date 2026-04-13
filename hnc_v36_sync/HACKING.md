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
- **v3.6.0**: 技术债清理 + helpers 提取 + scan_arp pending 异步 ✅ (当前)

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
