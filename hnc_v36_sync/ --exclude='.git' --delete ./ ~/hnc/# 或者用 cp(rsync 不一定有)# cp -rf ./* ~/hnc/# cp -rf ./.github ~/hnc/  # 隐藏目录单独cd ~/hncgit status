# HNC · Hotspot Network Control

> **Android 手机热点的设备级管控工具** · 限速 · 延迟注入 · 黑白名单 · 自动开热点

![version](https://img.shields.io/badge/version-v3.5.0-purple.svg)
![platform](https://img.shields.io/badge/platform-Android%2010%E2%80%9316-green.svg)
![root](https://img.shields.io/badge/root-KernelSU%20%7C%20SukiSU-orange.svg)
![tests](https://img.shields.io/badge/tests-97%20passing-brightgreen.svg)

---

## 这是什么

HNC 是一个 **KernelSU / SukiSU 模块**,让你的手机变成一个**可控的热点路由器**:

- 🚦 **每台设备单独限速**(MB/s 精度,上下行独立)
- 🌐 **延迟注入**(模拟弱网,游戏 / 直播测试用)
- 🚫 **黑白名单封锁**(MAC 级别)
- 🔄 **开机自动开热点**(SELinux 自动注入,Android 13+ 全机型)
- 📊 **实时流量统计**(per-device,跨重启持久化)
- 🎨 **iOS 风格 WebUI**(深色 / 浅色 / 跟随系统三态切换)
- 🔍 **mDNS 自动设备命名**(自动识别 iPhone / 小米 / 华为等)
- ⚡ **C 语言事件驱动 daemon**(v3.5+ 加速 50-200 倍,netlink 实时响应)

---

## v3.5 是什么版本

**v3.5 是 HNC 的工程化主题版本**。从 v3.5 开始,HNC 不再是"一个 shell 脚本",而是一个有完整工程基础设施的开源项目:

| 主题 | v3.5 之前 | v3.5+ |
|---|---|---|
| **测试** | 0 个 | **97 个**(64 shell + 22 hostname C + 11 mdns C) |
| **CI/CD** | 无 | GitHub Actions(NDK r26d 自动交叉编译) |
| **C 代码** | hotspotd 实验性,bug 多 | hotspotd **生产可用** |
| **设备扫描** | shell 轮询(2-8 秒延迟) | **netlink 事件驱动**(实时,1s de-bounce 合并) |
| **安全测试** | 无 | mDNS 伪造攻击拒绝测试 |
| **打包** | 手动 | tag push 自动 GitHub release |

### v3.5 关键修复

- **P0-4**:hotspotd 现在调 `lookup_manual_name + try_mdns_resolve`,hostname 解析跟 shell 路径完全一致
- **P0-5**:`do_scan_shell` 删 hostname 控制字符,防 mDNS 注入破坏 JSON
- **P1-2**:watchdog 用 `-d` 参数(原来用 `--daemon` hotspotd 不识别)
- **P1-7**:`write_json` 用 `fread(16384)` 读黑名单,30+ 设备不再截断
- **P1-8**:`Device.hostname_src` 字段加入,MAC 兜底跟 shell 算法对齐
- **P1-9**:mdns_resolve 验证 PTR 应答的 rname,拒绝 multicast 伪造攻击
- **R-1**:nl_process 1s de-bounce,合并连续 netlink 事件(写入 IO 减少 80%+)
- **R-2**:resolve_hostname 60s 时间窗口,改名场景下 60s 内自动生效

---

## 长期支持(LTS)

**v3.4.10** 是 HNC 真正的长期支持版本。维护期 6-12 个月,只修 bug,不加新功能。

如果你需要"装上不动"的稳定版本,装 v3.4.10。如果你想要更快的设备扫描和更现代的工程化基础,装 v3.5。

| 选哪个? | 推荐 |
|---|---|
| 装上一年都不更新 | **v3.4.10 LTS** |
| 想要 hotspotd C daemon 加速 | **v3.5+** |
| 用 Android 16 / SD8 Elite 等新机 | **v3.5+** |
| 想报 bug / 测试 / 贡献代码 | **v3.5+** |

---

## 支持的环境

| 组件 | 要求 |
|---|---|
| **Root 方案** | KernelSU 11485+ / SukiSU Ultra 4.x / Magisk(部分功能) |
| **Android** | 10 ~ 16(实测到 ColorOS 16 / Android 16) |
| **Kernel** | 4.14+(需 sched_htb / sched_netem 模块,绝大多数 ROM 默认有) |
| **架构** | aarch64 (armv8-a) |
| **WebView** | Chromium 90+(KSU Manager 自带) |
| **已实测机型** | realme RMX5010 (SD8 Elite, ColorOS 16, kernel 6.6.102) |

---

## 安装

### 方式 1:KernelSU Manager

1. 下载 zip:
   - **正式 release**:https://github.com/lcx08091-source/hnc/releases
   - **每日 nightly**:GitHub Actions artifacts(每次 main 分支 push 自动 build)
   - **v3.4.10 LTS**:Releases 里找 v3.4.10
2. KernelSU Manager → 模块 → 从存储安装 → 选 zip
3. 重启
4. KernelSU Manager → 模块 → HNC → "WebUI"

### 方式 2:命令行

```sh
adb push HNC_v3.5.0.zip /sdcard/
adb shell
su
ksud module install /sdcard/HNC_v3.5.0.zip
reboot
```

---

## 首次使用

1. **打开手机热点**(设置 → 个人热点 → 启用)
2. **打开 HNC WebUI**(KernelSU Manager → HNC → 打开 WebUI)
3. **手机连上你的热点**
4. **WebUI 看到设备出现**(IP / MAC / 名字 / 流量)
5. **点击设备卡片**展开,设置限速 / 延迟 / 黑名单

详细使用见 WebUI 内的"帮助"页面。

---

## 开发与贡献

### 跑测试

真机上跑 shell 测试:

```sh
su
cd /data/local/hnc
sh test/run_all.sh
# 期望: ALL PASS: 64/64
```

C 测试在 GitHub Actions 自动跑(每次 push):

```
test_hostname_helpers: 22/22
test_mdns_parse:       11/11
```

### 装机自检

下载 [hnc_smoke_test.sh](https://github.com/lcx08091-source/hnc/raw/main/hnc_smoke_test.sh):

```sh
sh /sdcard/Download/hnc_smoke_test.sh
```

输出 9 个 section 检查报告,验证版本号 / binary / 服务状态 / 测试 / WebUI / 防火墙等。

### 本地编译 hotspotd C daemon(可选)

```sh
# 需要 Android NDK r26d
cd daemon
./build.sh
# 输出: bin/hotspotd 和 bin/mdns_resolve
```

或者**等 GitHub Actions 自动 build**:任何 push 到 main 都会自动跑 CI,5-10 分钟后 artifacts 区可下载。

### 提 issue

issue 时请附:

1. `sh /data/local/hnc/bin/diag.sh` 完整输出
2. `module.prop` version
3. KSU 版本 + Android 版本 + ROM
4. 截图(UI 问题)
5. 相关日志(`/data/local/hnc/logs/`)

---

## 故障排查

### Step 1:跑自检

```sh
adb shell
su
sh /data/local/hnc/bin/diag.sh
```

### Step 2:看日志

```sh
ls /data/local/hnc/logs/
# boot.log         开机
# detect.log       shell daemon 设备扫描
# hotspotd.log     C daemon 设备扫描(v3.5+)
# hotspot.log      热点自启
# tc.log           限速操作
```

### Step 3:常见问题

**Q: WebUI 打开是空白**
A: 检查 KernelSU Manager 版本是否 11485+,旧版 WebView 可能不支持。

**Q: 设备扫描不到任何东西**
A: 确认手机热点已开启,客户端已连。`cat /proc/net/arp` 看 ARP 表是否有客户端。

**Q: 限速不生效(SD8 Elite / 联发科旗舰)**
A: 这些机型有 BPF / IPA 硬件卸载,大流量绕过 tc。WebUI 顶部会显示警告横幅。HNC 限速对小流量(控制包/握手)有效,大流量效果不准。建议改用黑名单。

**Q: mDNS 一台都识别不到**
A: 大概率是 SELinux 拦了 5353/UDP。`setenforce 0` 后再试。

**Q: hotspotd 频繁写 devices.json(日志一秒好几次 JSON written)**
A: v3.5.0 之前的 bug。升级 v3.5.0 或更新版本(R-1 加了 1s de-bounce)。

**Q: 改设备名后 WebUI 没立即更新**
A: v3.5.0 之前 hotspotd 对 manual 设备不会 re-resolve。升级 v3.5.0 或更新版本(R-2 加了 60s 时间窗口,改名后最多 60s 生效)。

---

## 致谢 / License

HNC 是个**单人维护**的开源项目,从 v3.0 → v3.5 经历了 60+ 次迭代。详见 [CHANGELOG.md](CHANGELOG.md)。

特别感谢:

- **Anthropic Claude** — 整个项目的代码协作者(代码 / 架构 / 调试 / 测试 / CI 配置)
- **KernelSU / SukiSU 团队** — 提供模块运行的基础
- **NDK / Linux netlink / tc / netem / iptables** — 底层基础设施

License: MIT(见 `LICENSE`)

---

## 不维护 / 不做的事(诚实告知)

- ❌ **不做 GUI App** — 只有 WebUI
- ❌ **不做云同步 / 配置导入导出** — 单机工具
- ❌ **不做多语言** — 中文为主
- ❌ **不做主题市场** — 内置亮 / 暗两套
- ❌ **不优化 iOS 客户端的 mDNS** — 部分老 iPhone 不响应反向 PTR

---

**HNC v3.5.0 · 2026-04-12**

仓库:https://github.com/lcx08091-source/hnc
