# HNC · Hotspot Network Control

> **手机热点的设备级管控工具** · 限速 · 延迟注入 · 黑白名单 · 自动开热点

[![version](https://img.shields.io/badge/version-v3.4.10-blue.svg)](CHANGELOG.md)
[![platform](https://img.shields.io/badge/platform-Android-green.svg)]()
[![root](https://img.shields.io/badge/root-KernelSU%20%7C%20SukiSU-orange.svg)]()
[![LTS](https://img.shields.io/badge/v3.4.10-LTS-purple.svg)](#长期支持-lts)

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

---

## 长期支持 (LTS)

**v3.4.10** 是 HNC 真正的长期支持版本(v3.4.9.x 是 LTS 准备阶段)。从此版本开始:

- ✅ **维护期 6-12 个月**:只修 bug,不加新功能
- ✅ **稳定的 JSON schema**:配置文件格式不变
- ✅ **自动备份**:每天开机自动备份 `data/`,保留 7 天
- ✅ **自检工具**:`bin/diag.sh` 12 项核心检查,出问题一键诊断
- ✅ **完整 CHANGELOG**:每个改动都有详细记录

新功能去 v3.5.x 分支,LTS 用户不会被打扰。

---

## 截图

设备列表 + 限速面板 + 暗色模式

```
                                            (实机截图见 GitHub Releases)
```

---

## 支持的环境

| 组件 | 要求 |
|---|---|
| **Root 方案** | KernelSU 11485+ / SukiSU Ultra 4.x |
| **Android** | 10 ~ 16(测试到 ColorOS 16 / Android 16) |
| **Kernel** | 4.14+(需要 sched_htb / sched_netem 模块) |
| **架构** | aarch64(armv8-a) |
| **WebView** | Chromium 90+(KSU 自带) |
| **已实测机型** | realme RMX5010 (SD8 Elite, ColorOS 16) |

理论上任何 KSU/Magisk 支持的现代 Android 设备都能跑。**未实测的机型请先小范围测试**。

---

## 安装

### 方式 1:KernelSU Manager

1. 下载最新 `HNC_v3_4_10.zip` from [Releases](#)
2. 打开 KernelSU Manager → 模块 → 从存储安装 → 选 zip
3. 重启手机
4. 浏览器访问 KernelSU Manager → 模块 → HNC → "WebUI"

### 方式 2:命令行

```sh
# 把 zip 推到设备
adb push HNC_v3_4_10.zip /sdcard/

# adb shell + ksud install
adb shell
su
ksud module install /sdcard/HNC_v3_4_10.zip
reboot
```

---

## 首次使用

1. **打开手机热点**(设置 → 个人热点 → 启用)
2. **打开 HNC WebUI**(KernelSU Manager → HNC → 打开 WebUI)
3. **手机连上你的热点**
4. **回 WebUI 看到设备出现**(IP / MAC / 名字)
5. **点击设备卡片**展开,设置限速 / 延迟 / 黑名单

### 给设备命名

- 第一次扫描后,设备名可能是 `Android` 或 MAC 后 8 位
- **点击名字旁的图标**(✏️ 或 🔍)弹出输入框,输入你想要的名字(例 "客厅打印机" "Mi-10")
- 名字保存到 `data/device_names.json`,**优先级最高**,永远显示

### 限速

- 展开设备卡片 → "限速控制"
- 输入下载 / 上传速度(MB/s,例 5.0)
- 点"应用限速" → 立即生效
- 想取消 → 点"清除"

### 延迟注入(模拟弱网)

- 展开设备卡片 → "延迟注入"
- **延迟**:基础延迟,例 50ms / 100ms / 200ms
- **抖动**:延迟波动范围,例 10ms (实际延迟在 ±10ms 内随机)
- **丢包率**:百分比,1% 模拟轻度,5% 严重弱网
- 三个值任意组合,点"应用"即可

### 自动开热点

- 全局控制 → "开机自动开热点" 总开关
- 配置 SSID / 密码 / 开机后延迟启动秒数
- 点"保存"
- 重启后会自动尝试开热点(需要 SELinux 策略,HNC 自动注入)

---

## 功能列表

| 模块 | 文件 | 作用 |
|---|---|---|
| **设备扫描** | `bin/device_detect.sh` | ARP 直读 + 5 级 hostname 优先级链 |
| **限速** | `bin/tc_manager.sh` | tc HTB + netem,精度到 0.01 MB/s |
| **iptables 标记** | `bin/iptables_manager.sh` | mangle 表 mark + stats |
| **mDNS 识别** | `bin/mdns_resolve` | C 工具,RFC 6762 反向 PTR 查询 |
| **配置存取** | `bin/json_set.sh` | 纯 awk JSON 操作,无 python 依赖 |
| **自检** | `bin/diag.sh` | 12 项核心健康检查 |
| **看门狗** | `bin/watchdog.sh` | 每 60s 检查规则是否被系统清掉 |
| **自启热点** | `bin/hotspot_autostart.sh` | 开机自动开热点,自动注入 sepolicy |
| **WebUI** | `webroot/index.html` | 单文件,3700+ 行,iOS 风格 |
| **API** | `api/server.sh` | 备用 HTTP API(WebUI 主要走 kexec) |

---

## 故障排查

### Step 1:跑自检脚本

```sh
adb shell
su
sh /data/local/hnc/bin/diag.sh
```

输出示例:
```
  HNC v3.4.10 自检
  ──────────────────────────────────────────────
  ✓ 安装目录              /data/local/hnc (v3.4.10 LTS)
  ✓ shell 脚本            5 个核心脚本就位
  ✓ mDNS 工具             二进制存在 (696320 bytes)
  ✓ iptables 链           4 个 HNC 链都存在
  ✓ tc qdisc              htb 已附加到 wlan2
  ✓ watchdog              运行中 (pid=12345)
  ✓ 数据文件              rules=2 设备 / devices=3 在线 / names=1 命名
  ✓ hostname 缓存         5 条记录
  ✓ 数据备份              3 个备份,最近 20260412
  ✓ 日志目录              4 文件 / 128K
  ✓ KSU 环境              SukiSU detected
  ✓ SELinux               Enforcing (正常)
  ──────────────────────────────────────────────
  汇总: 12 OK  0 WARN  0 FAIL
  ✓ 系统完全正常
```

任何 ✗ 或 ! 标记都告诉你哪里出问题了。

### Step 2:看日志

```sh
ls /data/local/hnc/logs/
# boot.log         开机日志
# detect.log       设备扫描日志
# hotspot.log      热点自启日志
# tc.log           限速操作日志
```

### Step 3:常见问题

**Q: WebUI 打开是空白 / 加载失败**
A: 检查 KernelSU Manager 版本是否 11485+,旧版 WebView 可能不支持。

**Q: 设备扫描不到任何东西**
A: 确认手机热点已开启,客户端已连上。跑 `cat /proc/net/arp` 看 ARP 表是否有客户端。

**Q: 限速不生效(SD8 Elite / 联发科旗舰)**
A: 这些机型有 BPF/IPA 硬件卸载,大流量绕过 tc。WebUI 顶部会显示警告横幅。HNC 限速对小流量(控制包/握手)有效,大流量(视频/下载)效果可能不准确。建议改用黑名单。

**Q: mDNS 一台都识别不到**
A: 大概率是 SELinux 拦了 5353/UDP。`setenforce 0` 后再试,如果能命中说明是 sepolicy 问题,加 `magiskpolicy --live "allow su * udp_socket {create connect read write}"`。

**Q: 重启后规则丢了**
A: 检查 watchdog 是否在跑(`ps -ef | grep watchdog`),没跑的话从 `service.sh` 启动。也看 `data/.backup-*/` 有没有最近的备份可以恢复。

---

## 报 bug

报 issue 时请附上:

1. `bin/diag.sh --json` 的完整输出
2. `module.prop` 里的 version
3. KSU 版本 + Android 版本 + ROM(ColorOS / MIUI / 原生)
4. 截图(如果是 UI 问题)
5. `logs/` 里相关的日志文件

---

## 致谢 / License

HNC 是个**单人维护**的开源项目,从 v3.0 → v3.4.9 经历了 50+ 次迭代。每个版本都有具体的 bug 修复或功能新增,详见 [CHANGELOG.md](CHANGELOG.md)。

特别感谢:

- **Anthropic Claude** — 整个项目的代码协作者(代码 / 架构 / 调试)
- **KernelSU / SukiSU 团队** — 提供了模块运行的基础
- **Linux tc / netem / iptables** — 限速和延迟注入的底层

License: MIT (见 `LICENSE`)

---

## 不维护 / 不做的事(诚实告知)

- ❌ **iOS / Apple 设备不会有特殊优化** — HNC 是 Android root 模块
- ❌ **不做 GUI App**(没有 Java/Kotlin 版本) — 只有 WebUI
- ❌ **不做云同步 / 配置导入导出** — 单机工具
- ❌ **不做多语言** — 中文为主
- ❌ **不做 Magisk 专用版** — 主力 KSU,Magisk 兼容是顺带
- ❌ **不做主题市场** — 内置亮 / 暗两套足够

如果这些是你的需求,HNC 不适合你,建议看其他工具。

---

**HNC v3.4.10 真 LTS 1.0 · 2026-04-12**
