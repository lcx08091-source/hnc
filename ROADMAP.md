# HNC ROADMAP

最后更新:2026-04-12

---

## 当前状态

**HNC v3.5.0 正式版已发布** 🎉

| 版本 | 状态 | 主题 |
|---|---|---|
| v3.4.10 | ✅ LTS | 长期支持(只修 bug) |
| v3.5.0-alpha | ✅ Released | 测试框架(64 shell tests) |
| v3.5.0-beta1 | ✅ Released | hotspotd 4 修 + CI + benchmark |
| v3.5.0-rc | ✅ Released | de-bounce + re-resolve + README + ROADMAP |
| **v3.5.0** | ✅ **Released** | **R-12 WebUI offline + R-13 周期清理 + 工程化主题完成** |
| v3.5.x patch | ⏳ 按需 | 长跑发现的 bug 修复 |
| v3.6 | ⏳ 待立项 | 等 v3.5 收集 feedback 后规划 |

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
