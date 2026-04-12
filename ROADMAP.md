# HNC ROADMAP

最后更新:2026-04-13

---

## 当前状态

**HNC v3.5.2 架构修复版已发布** 🎉

经过**三轮独立 AI 代码审查**,v3.5.2 是 v3.5 系列第一个**可以作为 GitHub Release 发布**的版本。

| 版本 | 状态 | 主题 |
|---|---|---|
| v3.4.10 | ✅ LTS | 长期支持(只修 bug) |
| v3.5.0-alpha | ✅ Released | 测试框架(64 shell tests) |
| v3.5.0-beta1 | ✅ Released | hotspotd 4 修 + CI + benchmark |
| v3.5.0-rc | ✅ Released | de-bounce + re-resolve + README |
| v3.5.0 | ❌ **DEPRECATED** | 第一轮 AI 审查发现 4 个 P0 |
| v3.5.1 | ❌ **DEPRECATED** | 第二轮 AI 审查发现 P0-A 架构 race |
| **v3.5.2** | ✅ **Released** | **daemon 生命周期架构成熟** |
| v3.6.0 | ⏳ 规划中 | P0-B 核心修复 + helper 提取 + 技术债清理 |
| v3.6.1 | ⏳ 规划中 | BPF / hardware offload 研究 |

### 三轮审查结果总览

| 轮次 | 真 P0 | 真 P1 | 结论 |
|---|---|---|---|
| 第一轮 (v3.5.0) | 4 个 | 3 个 | 注入 / 转义 / race / 失效 |
| 第二轮 (v3.5.1) | 2 个 | 5 个 | watchdog 双重复活 + IPC DoS |
| **第三轮 (v3.5.2)** | **0 个** | **0 个** | **只找到技术债,建议 stop auditing** |

第三轮审查员结论:*"打 tag v3.5.2,发第一个 GitHub Release,开始规划 v3.6。不需要修 v3.5.3。继续打磨 v3.5 的边际收益已经小于启动 v3.6 的价值。"*

---

## v3.5.2 已知技术债(第三轮审查整理,归入 v3.6 backlog)

这些是第三轮审查发现的问题,**全部不是会影响真实用户的真 bug**,而是"要构造特定场景才会出问题"的边角,或"哪天生态变了会成为真问题"的风险。按审查员判断的价值从高到低排列:

### 高价值(v3.6.0 优先做)

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
