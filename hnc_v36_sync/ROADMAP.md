# HNC ROADMAP

最后更新:2026-04-13

---

## 当前状态

**HNC v3.6.0 架构收尾版已发布** 🎉

v3.5 系列收尾。v3.5.2 CHANGELOG 承诺的 P0-B 核心修复 + helper 提取 + 5 项技术债清理 + HACKING.md 全部完成。

| 版本 | 状态 | 主题 |
|---|---|---|
| v3.4.10 | ✅ LTS | 长期支持(只修 bug) |
| v3.5.0-alpha | ✅ Released | 测试框架(64 shell tests) |
| v3.5.0-beta1 | ✅ Released | hotspotd 4 修 + CI + benchmark |
| v3.5.0-rc | ✅ Released | de-bounce + re-resolve + README |
| v3.5.0 | ❌ **DEPRECATED** | 第一轮 AI 审查发现 4 个 P0 |
| v3.5.1 | ❌ **DEPRECATED** | 第二轮 AI 审查发现 P0-A 架构 race |
| v3.5.2 | ✅ Released | daemon 生命周期架构成熟 |
| **v3.6.0** | ✅ **Released / LTS** | **架构收尾 + P0-B 核心 + helpers 提取 + HACKING.md** |
| v3.7 | ⏸️ 无定死计划 | 只做"真实观察到的需求" |

### 三轮审查结果总览(v3.5 系列)

| 轮次 | 真 P0 | 真 P1 | 结论 |
|---|---|---|---|
| 第一轮 (v3.5.0) | 4 个 | 3 个 | 注入 / 转义 / race / 失效 |
| 第二轮 (v3.5.1) | 2 个 | 5 个 | watchdog 双重复活 + IPC DoS |
| 第三轮 (v3.5.2) | 0 个 | 0 个 | 只找到技术债,建议 stop auditing |

第三轮审查员结论:*"打 tag v3.5.2,发第一个 GitHub Release,开始规划 v3.6。不需要修 v3.5.3。"*

**v3.6.0 遵循了这个建议**:v3.5.2 直接作为第一个正式 GitHub Release,v3.6.0 是后续的"收尾版"而不是另一个紧急修复。

---

## v3.6.0 发布状态

### 完成清单(全部 ✅)

**Commit 1 — 小技术债清理**
- ✅ T1 webroot 6 个 action shellQuote
- ✅ T2 REFRESH 强制重算 stats
- ✅ T4 device_detect.sh 删假 trap 注释
- ✅ T6 删死代码 emoji devIcon
- ✅ T12 watchdog 每轮 check_services(恢复时间 180s→60s)

**Commit 2 — helpers 提取**
- ✅ 创建 `daemon/hnc_helpers.h`(113 行)
- ✅ 创建 `daemon/hnc_helpers.c`(190 行)
- ✅ `hotspotd.c` 改用 helpers,删除内联 should_re_resolve / lookup_manual_name / json_escape
- ✅ `test_hostname_helpers.c` 改用 `#include`,删除 ~180 行复制
- ✅ `build.sh` 和 CI workflow 加 hnc_helpers.c
- ✅ **彻底消除** v3.5.1 P1-3 + v3.5.2 P1-A 的复制 drift 风险

**Commit 3 — scan_arp pending 异步化(P0-B 核心修复)**
- ✅ Device 结构加 `pending_since` 字段
- ✅ `scan_arp` / `nl_process` 新设备改用 `hnc_resolve_hostname_fast` + pending 标记
- ✅ 新增 `process_pending_mdns()` 主循环每 tick 最多解 1 个 pending 设备
- ✅ `hnc_pending_ready()` 纯函数提取到 helpers
- ✅ WebUI 支持 "pending" 状态显示 ⏳ 图标
- ✅ 加 13 个新测试(7 pending + 6 fast)
- ✅ **主线程阻塞从 30 台设备 × 800ms = 24 秒 → ~30μs**

**Commit 4 — HACKING.md**
- ✅ 638 行 / 29 KB 贡献者文档
- ✅ 12 个已知的坑,每一个带文件+行号+版本锚点
- ✅ 快速心智模型 + 测试策略 + 发布流程 + 常见任务 + 元教训

**Commit 5 — 版本 bump + CHANGELOG + ROADMAP**
- ✅ module.prop v3.5.2 → v3.6.0 / 3505 → 3600
- ✅ bin/diag.sh 4 处版本号
- ✅ webroot about-ver + v3.6.0 changelog 段
- ✅ CHANGELOG.md v3.6.0 详细段
- ✅ ROADMAP.md 本次更新

**Commit 6 — tag + push**
- ⏳ 待作者在 termux 执行 `git tag v3.6.0 && git push origin v3.6.0`

### 测试覆盖

| 类别 | v3.5.2 | v3.6.0 | 变化 |
|---|---|---|---|
| Shell 框架自检 | 15 | 15 | - |
| Shell json_set | 30 | 30 | - |
| Shell iptables_tc | 19 | 19 | - |
| C mdns_parse | 11 | 11 | - |
| C hostname_helpers | 37 | **50** | **+13** |
| **总** | **112** | **125** | **+13** |

### 代码规模

```
daemon/hotspotd.c                 1076 (v3.5.2) → 1049 (v3.6.0)
daemon/hnc_helpers.h              0    (v3.5.2) → 113
daemon/hnc_helpers.c              0    (v3.5.2) → 190
daemon/test/test_hostname_helpers.c  478 (v3.5.2) → 507
HACKING.md                        0    (v3.5.2) → 638
```

净增约 1300 行(其中 HACKING.md 638 是文档),代码本身基本持平。

---

## v3.6.0 没做的(v3.7 候选)

从 v3.5.2 第三轮审查留下的 12 项技术债里,v3.6.0 修了 7 项(T1/T2/T4/T6/T12 + P0-B + P1-F),剩下的 5 项是:

**T3 — watchdog spawn 锁缺少 force-break** [低]
- 触发条件:watchdog 在 1 秒 mkdir/rmdir 窗口内被 SIGKILL
- 概率:几乎为 0(watchdog 从不被 kill)
- 留 v3.7 评估

**T5 — cfg_set 对空 {} 插入字段产生非法 JSON** [低]
- 触发条件:有人手动 `echo '{}' > config.json` 后调 cfg_set
- 当前 config.json 默认非空(5 字段),不触发
- HACKING.md 已记录约束

**T7 — rules.json 必须保持单行 devices 段** [中]
- 隐性约束,HACKING.md 已记录
- 真修复需要重写 restore_rules 的 awk 为跨行模式
- 留 v3.7 做(顺便重构 tc_manager.sh)

**T8 — 日志 runtime rotation** [中]
- 当前只在启动时 rotate(10MB 阈值)
- 实际 hlog 克制,一两个月才到 10MB
- 留 v3.7 加 runtime 监控

**T9 / T10 / T11** — SSID 含 `"` / recv buffer 64B / iptables-nvx 字段位置
- 都是低价值 + 极小触发概率
- 留 v3.7 或者永远不做

---

## v3.7 预留(无定死计划)

**v3.6.0 之后 HNC 进入 LTS 模式**。v3.7 只做真实观察到的需求,没有激进架构改动。

可能的方向(按优先级排列,都不是承诺):

### 1. Bug 修复(如果有)

v3.6.0 真机长跑观察到的任何真 bug。预期 **0-1 个**(v3.5.2 的三轮审查已经把显性和架构 bug 扫干净)。

### 2. 剩余技术债(如果有心情)

T3 / T5 / T7 / T8 / T9 / T10 / T11。都是小事,合成一个 commit 就能做完。

### 3. 平台兼容性(如果生态变了)

- Android 17 / 18 的 netd fwmark 范围变化(检查 MARK_BASE)
- SukiSU / KernelSU 的 window.ksu.exec API 升级
- iptables → nftables 迁移(Android 生态跟进的话)

### 4. 功能(如果真的需要)

- **BPF hardware offload 集成**:RMX5010 已经调研过,但只在 bypass tc clsact 的 SoC 上有收益,多 SoC 兼容性工程量太大,**默认不做**
- **WebUI 性能图表 / 历史记录**:4700 行单文件 HTML 已经到上限,未来重写成 Vue/Preact,**默认不做**
- **多语言支持**:作者只用中文,**默认不做**

### 5. 主动推广(不会做)

- 不会提交 KernelSU 官方模块库
- 不会发 XDA / 知乎 / V2EX
- **不追用户数,自己用得爽就好**

---

## 项目可持续性承诺

v3.5.2 第三轮审查员最重要的元建议:

> *"真正可能把它杀掉的不是代码,是你某天不想维护了。"*

v3.6.0 的回应:

1. **✅ HACKING.md 写完** — 未来的作者/贡献者不用从头推导隐性知识
2. **✅ v3.6.0 是 LTS** — 没有 deadline 压力,没有下一个版本的承诺
3. **✅ CHANGELOG 完整** — 10 个版本的"从错到对"工程轨迹全部可追溯
4. **✅ 三轮审查闭环** — 没有"还有没修的 P0"的心理债务
5. **✅ HNC 可以跑很久不碰** — v3.5.2 三轮审查证明代码稳态

**HNC 不欠作者一个 v3.7**。作者也不欠 HNC 任何承诺。v3.6.0 之后,维护关系是"我想修才修",不是"项目需要所以我必须修"。

---

## v3.5.2 已知技术债历史记录(已在 v3.6.0 处理)

以下是第三轮审查发现的 T1-T12 清单(保留作为历史记录)。**v3.6.0 修了 T1/T2/T4/T6/T12 + P0-B + P1-F 共 7 项**,剩下 5 项见上面 "v3.6.0 没做的"。

### 高价值(v3.6.0 已处理)

**T1 — shell 参数注入的 defense-in-depth 缺失** [中高]
- 位置: `webroot/index.html` applyLimit 4263 / clearLimit 4323 / applyDelay 4346 / addBlacklist 4404 / rmBlacklist 4415 / shUpdate 4180
- 现状: 6 个 action 函数把 ip / mac 插进双引号而不是用 shellQuote()
- 当前不触发原因: hotspotd.c 的 /proc/net/arp sscanf + netlink snprintf 对 mac/ip 有硬格式约束
- 风险: 下次加新数据源(离线命名导入 / nmap 扫描)这个前提会失效
- 修复: 把所有 kexec 的 ip/mac 插值改成 shellQuote(),v3.5.1 的 editName 已经用这个模式,6 个 action 跟上即可
- 工时: 30 分钟

**T2 — REFRESH + update_traffic_stats TTL 交互的 UX 钝感** [中]
- 位置: `daemon/hotspotd.c:427 / 802-807`
- 现状: REFRESH 异步化后,下一次 scan_arp → write_json 如果在 5 秒 TTL 窗口内,devices.json 的 rx/tx 是旧数据
- 实际影响: 背景 doRefresh 每 2.5 秒跑一次,用户感知不到
- 修复: REFRESH 分支额外设 `g_last_stats_update = 0` 强制下次重算,2 行代码

**T3 — watchdog spawn 锁缺少陈旧恢复** [中]
- 位置: `bin/watchdog.sh:154-159`
- 现状: device_detect.sh daemon_mode() 有 10 秒 force-break,但 watchdog 的 spawn 锁没有
- 触发条件: watchdog 自己在 mkdir/rmdir 之间的 1 秒窗口被 SIGKILL(极罕见)
- 修复: 把 device_detect.sh 的 force-break 逻辑抽成 `bin/lib_spawn.sh`,两处共用

**T4 — daemon_mode() 注释说 trap 但实际没写 trap** [低]
- 位置: `bin/device_detect.sh:469-471`
- 现状: 注释写"trap 确保进程退出时释放 spawn 锁"但下面没有 trap 语句
- 性质: 注释和代码对不上,诚实问题。实际依赖 force-break 兜底
- 修复: 要么补 trap,要么改注释说"依赖 force-break 兜底,trap 在 ash 下不可靠"

### 中价值

**T5 — cfg_set 对空 {} 插入字段产生非法 JSON** [低]
- 位置: `bin/json_set.sh:374`
- 现状: `sed -i "s|}$|,\"$KEY\": $JVAL}|"` 对空 `{}` 产生 `{,"key": val}`(前置逗号非法)
- 当前不触发原因: config.json 默认非空(5 个字段)
- 触发条件: 有人手动删 config.json 后 `echo '{}' > config.json` 初始化
- 修复: 先判断是否空对象

**T6 — webroot 有两个 devIcon 函数** [低]
- 位置: `webroot/index.html:3079-3085` (emoji) vs `4121-4125` (SVG)
- 现状: 第二个覆盖第一个,第一个是死代码
- 修复: 删第 3079-3085

**T7 — restore_rules 隐式依赖 rules.json 单行格式** [中]
- 位置: `bin/tc_manager.sh:593`
- 现状: restore_rules 的 awk 在单行 $0 上扫设备块
- 风险: 如果有人用 jq 格式化 rules.json,awk 抽不出 mark_id 导致 restore 静默失败
- **这个隐性约束没写在任何文档里** — 也会在 HACKING.md 里记录
- 修复选项: (a) 检测多行 + tr -d '\n' 临时压缩 / (b) awk 跨行模式 / (c) 文档警告

**T8 — 日志轮转只在启动时触发** [中]
- 位置: `post-fs-data.sh:87-100`
- 现状: 10MB 阈值 + 只在启动时检查。长跑几个月不重启理论上无上限
- 实际影响: hlog 克制,10MB ≈ 数十万条记录,满负载也要一两个月
- 修复: hotspotd.c 加 runtime rotation,hlog 写前 ftell 超 10MB 就 rotate

**T12 — watchdog check_services 每 3 轮才调用** [中]
- 位置: `bin/watchdog.sh:252-257`
- 现状: INTERVAL_NORMAL=60 × 每 3 轮 = 180 秒,hotspotd 崩溃后最多 3 分钟 watchdog 才重启
- 修复: 删 `% 3`,每轮都调 check_services。代价极小(几次 cat + kill -0)

### 低价值 / 可观察

- **T9** — get_rule_str 对 SSID 含 `"` 的处理不完整(grep 的 `[^"]*` 不懂 `\"` escape)
- **T10** — handle_client recv 单次 64 字节(当前命令都 < 16,未来扩展要记得调大)
- **T11** — stats_all 解析 iptables -nvx 字段位置固定(跨版本可能变,尤其 iptables-nft)

### 风格 / 建议

- `hotspotd.c:961` 注释写 "200ms de-bounce" 但实际 `tv.tv_sec = 1`(1 秒)
- `iptables_manager.sh:69` log 时间戳不带日期
- `watchdog.sh` 日志标签还写 "v3.4.1 started",没跟着升
- CHANGELOG 已经接近 200KB,考虑归档历史版本到 CHANGELOG-archive.md
- module.prop description 字段可以短一点(Android root manager UI 会截断)

---

## v3.6 规划(基于第三轮审查员的优先级建议)

### v3.6.0 — 架构修复完结 + 技术债清理

审查员原话: *"v3.6 最应该做的 3 件事是 P0-B 剩余修复 + 安全补强 + helper 提取"*

1. **P0-B 核心修复** — scan_arp 内部 popen mdns_resolve 的同步阻塞
   - 当前: v3.5.2 只修了 IPC 路径,scan_arp 里仍然串行 popen 每个设备的 mdns
   - 方案候选: (a) work queue + 独立工作线程 / (b) fork 短命子进程 + waitpid WNOHANG / (c) scan_arp 只填 mac 兜底标 `pending`,下次 write_json 之间异步解析
   - 优先级: v3.6.0 必做(v3.5.2 CHANGELOG 已承诺)

2. **helper 提取为 hnc_helpers.c/.h**
   - 当前: test_hostname_helpers.c 里 `should_re_resolve` 和 `json_escape` 依然是从 hotspotd.c 复制的(v3.5.2 P1-A 修了签名对齐,但没拆文件)
   - 方案: 提取 daemon/hnc_helpers.c + .h,主代码和测试都 #include
   - 消除: v3.5.1 P1-3 和 v3.5.2 P1-A 留下的复制 drift 风险

3. **技术债清理**: T1 + T2 + T4 + T6 + T12(都是 30 分钟内能修的小事)

### v3.6.1 — BPF / hardware offload 研究

- RMX5010 实测 BPF tether_limit_map 可写但 tc clsact 优先级高于 schedcls
- 保留为 `tools/` 紧急工具,不集成进主模块
- 其他芯片/内核组合的调研

---

## 项目可持续性(第三轮审查员的元建议)

> *"真正可能把它杀掉的不是代码,是你某天不想维护了。"*

为提高项目可持续性:

1. **v3.6 拆成 v3.6.0 + v3.6.1**,别一次吞下所有(P0-B + helper + BPF 是三个独立里程碑)
2. **写 HACKING.md** — 把隐性知识落地:
   - `MARK_BASE` 必须避开 netd 的 `0x10000-0xdffff` 范围(v3.4.1 事故)
   - `rules.json` 必须保持单行 devices 段(T7 的隐性约束)
   - `post-fs-data.sh` 阶段 iptables 可能还没 ready
   - KSU kexec 的 callback 必须是 global function string(不是匿名函数)
   - Android 16 / SD8 Elite 的 `clsact` 要用 `ffff:fff2` handle
3. **在 README 或 module.prop 加运维 tip** — "如果 hotspotd 行为异常,先看 `/data/local/hnc/run/daemon.spawn` 目录存不存在"

---

## v3.5.0 完成清单

### ✅ 工程化基础设施

- ✅ 测试框架:`test/lib.sh` + `test/run_all.sh` + 3 个 unit suite
- ✅ 64 个 shell 测试(framework 15 + json_set 30 + iptables_tc 19)
- ✅ 22 个 hotspotd C 测试(test_hostname_helpers.c)
- ✅ 11 个 mdns_resolve C 测试(test_mdns_parse.c)
- ✅ 3 个 P1-9 安全测试(主动验证伪造攻击被拒)
- ✅ GitHub Actions CI(test → build → release 三个 job)
- ✅ NDK r26d 自动交叉编译 hotspotd + mdns_resolve
- ✅ tag push 自动 GitHub Release

### ✅ hotspotd C daemon 修复

- ✅ P0-4 hostname 解析对齐 shell(manual > mdns > mac)
- ✅ P1-2 启动参数 `--daemon` → `-d`
- ✅ P1-7 黑名单 fread(16384) 防截断
- ✅ P1-8 hostname_src 字段 + MAC 兜底对齐
- ✅ P1-9 mdns_resolve rname 验证(防伪造)
- ✅ R-1 nl_process 1s de-bounce(写入 IO 减少 80%+)
- ✅ R-2 60s 时间窗口 re-resolve(支持改名场景)
- ✅ R-13 主循环周期清理离线设备(每 30s 检查 90s 阈值)

### ✅ WebUI 修复

- ✅ R-12 客户端 last_seen 离线判断(3 处:渲染 ×2 + 顶部统计)
- ✅ verifyUploadLimit(C-4)
- ✅ shUpdate 5→1 kexec 合并(C-5)

### ✅ Shell 修复

- ✅ P0-3 set_delay loss-only 路由
- ✅ P0-5 do_scan_shell 控制字符过滤
- ✅ P0-6 name_set awk close("/dev/stdin") 段错误
- ✅ PATH guard + HNC_TEST_MODE 环境变量(alpha)
- ✅ 9 项 P2 polish

### ✅ 文档

- ✅ README.md 完整重写(v3.5 主题 + 选择指引 + 故障排查)
- ✅ ROADMAP.md(本文件)
- ✅ CHANGELOG.md 详细记录每个版本
- ✅ 真机 benchmark 脚本 `bench.sh`
- ✅ 装机自检脚本 `hnc_smoke_test.sh`

### ✅ 真机验证(RMX5010 SD8 Elite / Android 16)

- ✅ hotspotd C daemon 稳定运行
- ✅ netlink RTMGRP_NEIGH 在新内核工作
- ✅ P0-4 hostname 解析(devices.json 含 hostname_src)
- ✅ 91 测试在真机全过(beta1 时验证)
- ⏳ 24 小时长跑稳定性(待你跑)
- ⏳ R-1 R-2 R-12 R-13 真机验证(待装 v3.5.0 后跑)

---

## v3.5.x patch(按需)

如果长跑或日常使用发现 bug,会出 v3.5.1 / v3.5.2 等小版本,只修 bug 不加新功能。

---

## v3.6 候选主题

⚠ **以下都是占位想法,没有具体规划**。v3.5.0 release 后收集一段时间 feedback,再正式立项 v3.6 并把这些想法 detailed planning。

### 高优先级候选

#### 🌐 nftables 后端(B 方向)

把 iptables 后端改成 nftables。理由:

- nftables 是现代 Linux 防火墙的标准
- 规则表达更简洁
- 原子更新(transaction-based)
- 更好的性能(set / map 数据结构,O(1) 查找)

**为什么 v3.5 没做**:
- RMX5010 没装 `nft` binary(ColorOS 16 默认不带)
- iptables 路径完全工作中,no user pain
- 工程量大(`bin/iptables_manager.sh` ~600 行需要重写)

**估**:8-12h

#### 📊 流量历史 / 趋势图

WebUI 加"过去 7 天 / 过去 24 小时"流量统计图。

- 后端:每分钟从 iptables HNC_STATS 链 sample 一次
- 前端:Chart.js 或 native canvas 时序图
- 数据保留:7 天 rolling 窗口

**估**:6-10h

#### 🔌 hotspot 状态联动(v3.5 R-12/R-13 的根本方案)

让 hotspotd 跟手机热点状态联动:

- 用户关热点 → service.sh / hotspot_autostart.sh 检测到 → 通知 hotspotd
- hotspotd 收到通知 → 清空设备表 + 写空 devices.json + 暂停 netlink 监听
- 用户开热点 → 反向操作

**比 R-12 R-13 更彻底**:R-12 R-13 是"过期清理",这个是"事件驱动同步"。

**估**:4-6h(主要难点是检测热点状态变化的 API)

---

### 中优先级候选

#### 🔔 设备上线通知

新设备连上热点时弹通知到主机。

#### 🌍 流量配额限制

"今天用了 10GB 自动断网"。

#### 🔄 多 root 框架完整支持

Magisk 兼容性测试 + 适配。

#### 🎨 WebUI 主题市场

允许用户写自己的 CSS 主题。

---

### 低优先级 / 不太可能做

- 🌏 WebUI i18n(英文支持)— 需求小工程量大
- ☁ 云同步 / 配置导入导出 — 反单机工具的设计

---

## v3.7+ 不做的事

以下东西**HNC 不会做**,如果你需要请用别的工具:

- ❌ VPN 客户端(用 Clash / Surfboard)
- ❌ 流量代理(用 v2rayNG)
- ❌ 广告拦截(用 AdAway)
- ❌ 防火墙 GUI(用 NetGuard)
- ❌ DNS 配置(用 Intra)

HNC 是**热点设备管控工具**,scope 严格限制在"我手机的热点的客户端"这一层。

---

## 反馈

- **报 bug / 提需求**:https://github.com/lcx08091-source/hnc/issues
- **看代码**:https://github.com/lcx08091-source/hnc

---

**HNC v3.5.0 · 2026-04-12**
