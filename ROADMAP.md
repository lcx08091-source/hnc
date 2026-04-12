# HNC ROADMAP

最后更新:2026-04-12

---

## 当前状态

**HNC v3.5.0-rc** 进行中。详细见 [CHANGELOG.md](CHANGELOG.md)。

| 版本 | 状态 | 主题 |
|---|---|---|
| v3.4.10 | ✅ LTS | 长期支持(只修 bug) |
| v3.5.0-alpha | ✅ Released | 测试框架(64 shell tests) |
| v3.5.0-beta1 | ✅ Released | hotspotd 4 修 + CI + benchmark + 真机验证 |
| **v3.5.0-rc** | 🚧 **进行中** | de-bounce + re-resolve + README + 长跑 |
| v3.5.0 final | ⏳ 下一步 | 正式 release + GitHub Release Notes |

---

## v3.5.0-rc 任务清单

### 已完成

- ✅ **R-1** hotspotd nl_process 1s de-bounce(合并连续 netlink 事件)
- ✅ **R-2** Device.last_resolve 字段 + 60s 时间窗口 re-resolve(修改名 bug)
- ✅ **R-3** 删除 device_detect.sh "v3.4.11 LTS hotspotd 不要启用" 过时警告
- ✅ **R-4** smoke test 期望更新(hotspotd 应该在跑 + 验证 -d 参数 + P0-4 字段)
- ✅ **R-2 测试** 6 个新 C 测试(test_hostname_helpers 16 → 22)
- ✅ **R-5** README.md 完整更新到 v3.5
- ✅ **R-6** 本 ROADMAP.md(你正在看)

### 进行中

- 🚧 **R-7** CHANGELOG.md 加 v3.5.0-rc 段落
- 🚧 **R-8** bump module.prop 到 v3.5.0-rc
- 🚧 **R-9** push 到 GitHub 触发 CI build,等 artifact

### 待办(你做)

- ⏳ **R-10** 装 v3.5.0-rc CI artifact 到真机,验证 R-1 R-2 修复(de-bounce 日志变少 + 改名 60s 内生效)
- ⏳ **R-11** 24 小时长跑稳定性测试(让 hotspotd 跑一整天,看 RSS / CPU / 日志大小)

---

## v3.5.0 final 任务

- ⏳ **F-1** 修长跑期间发现的所有 bug(预期 0-3 个)
- ⏳ **F-2** 写 GitHub Release Notes(从 CHANGELOG 提炼成 release-friendly 版本)
- ⏳ **F-3** 打 git tag `v3.5.0` → CI release job 自动创建 GitHub Release + 上传 zip
- ⏳ **F-4** 庆祝 🎉

---

## v3.6 候选主题

⚠ **以下都是占位想法,没有具体规划**。v3.5.0 final release 后才会正式立项 v3.6 并把这些想法 detailed planning。

### 高优先级候选

#### 🌐 nftables 后端(B 方向)

把 iptables 后端改成 nftables。理由:

- nftables 是现代 Linux 防火墙的标准,iptables 在 Linux 5.0+ 实际上是 nftables 的兼容层
- 规则表达更简洁(单条 rule 替代多条 iptables 规则)
- 原子更新(transaction-based,不会有规则部分应用的状态)
- 更好的性能(set / map 数据结构,O(1) 查找)

**为什么 v3.5 没做**:
- RMX5010 没装 `nft` binary(ColorOS 16 默认不带)
- iptables 路径完全工作中,no user pain
- 工程量大(`bin/iptables_manager.sh` ~600 行需要重写)

**如果做**:估 8-12h,需要写 `bin/nftables_manager.sh` 平行实现,加 backend 自动选择(优先 nft 失败 fallback iptables)。

---

#### 📊 流量历史 / 趋势图

WebUI 加"过去 7 天 / 过去 24 小时"流量统计图。

- 后端:每分钟从 iptables HNC_STATS 链 sample 一次,写到 sqlite 或者 append 到 csv
- 前端:Chart.js 或者 native canvas 画时序图
- 数据保留:7 天 rolling 窗口,自动删旧数据

**估**:6-10h(后端 sampler + 前端图表 + 存储管理)

---

#### 🔔 设备上线通知

新设备连上热点时弹通知到主机(你的手机)。

- 通过 KernelSU 的 notification API(如果有)
- 或者通过 termux-notification(如果用户装了 termux)
- 或者通过 ADB 转发到电脑的某个 webhook

**估**:3-5h,主要难点是 KSU 的通知 API 不一定稳定

---

### 中优先级候选

#### 🌍 流量配额限制

"今天用了 10GB 自动断网"功能。

- 配置:per-device 或全局,每日 / 每月配额
- 检测:从 HNC_STATS 周期采样
- 触发:超配额时把设备加到临时黑名单 / 限速到 0
- 重置:每天 0 点 / 每月 1 号自动重置

**估**:6-8h

---

#### 🔄 多 root 框架完整支持

当前 HNC 主要在 KernelSU / SukiSU 上测试。Magisk 在某些路径可能有问题(SELinux context 不一样)。

如果开源后有人用 Magisk 报问题,需要做兼容性适配。

**估**:看具体问题,5-15h

---

#### 🎨 WebUI 主题市场

允许用户写自己的 CSS 主题,WebUI 加载选择。

**估**:4-6h(主要是 CSS variable 重构 + 主题切换 UI)

---

### 低优先级 / 不太可能做

#### 🌏 WebUI i18n(英文支持)

- 用户群以中文为主,需求小
- 工程量大(每个文案都要双语)
- 估 10h+

#### ☁ 云同步 / 配置导入导出

- 反单机工具的设计
- 没安全保证(谁来托管?)

#### 📱 原生 GUI App

- 现在的 WebUI 已经够好用
- App 需要维护两份代码

---

## v3.7+ 不做

以下东西**HNC 不会做**,如果你需要请用别的工具:

- ❌ VPN 客户端(用 Clash / Surfboard)
- ❌ 流量代理(用 v2rayNG)
- ❌ 广告拦截(用 AdAway)
- ❌ 防火墙 GUI(用 NetGuard)
- ❌ DNS 配置(用 Intra)

HNC 是**热点设备管控工具**,scope 严格限制在"我手机的热点的客户端"这一层。

---

## 时间预期

| 里程碑 | 预期时间 |
|---|---|
| v3.5.0-rc release | 2026-04-12 ~ 2026-04-15(本周内) |
| v3.5.0 final release | 2026-04-15 ~ 2026-04-25(测试通过后) |
| v3.6 立项 | v3.5.0 final 后 1-2 周 |
| v3.6 release | 看选什么主题,估 1-3 个月 |

**这是单人项目,时间预期都是宽泛估计**。延期是常态。

---

## 反馈

有 v3.6 想要的功能?有用 v3.5 时遇到的痛点?

- **报 bug / 提需求**:https://github.com/lcx08091-source/hnc/issues
- **私下聊**:跟项目维护者直接沟通

---

**HNC v3.5.0-rc · 2026-04-12**
