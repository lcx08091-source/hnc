# daemon/

## ⚠️ LTS 警告:hotspotd 是实验性未完成功能

本目录包含 **HNC 的两个 C 工具**:

| 文件 | 状态 | 用途 |
|---|---|---|
| `mdns_resolve.c` | ✅ **已编译并启用**(`bin/mdns_resolve`) | mDNS 反向 PTR 查询,自动识别设备 hostname |
| `hotspotd.c` | ⚠️ **未编译,LTS 禁用** | 设计中的 netlink 事件驱动 daemon,取代 shell 轮询 |

### 关于 hotspotd

`hotspotd.c` 是一个**未完成的架构升级**。设计目标:用 netlink RTGRP_NEIGH 事件驱动取代 `device_detect.sh` 的 8 秒 shell 轮询,实现实时设备上线/下线感知。

**但它在 v3.4.11 LTS 阶段不应启用**,因为存在 4 个已知 P0/P1 bug:

| Bug | 后果 |
|---|---|
| **P0-4**:write_json 不调 mDNS / 不读 device_names.json / 不写 hostname_src | 启用后所有"手动命名"和"mDNS 自动识别"功能立刻失效 |
| **P1-2**:watchdog 用 `--daemon` 重启失败(hotspotd 只识别 `-d`) | 死循环重启 |
| **P1-7**:`fgets(256)` 黑名单解析对长 JSON 截断 | 多设备时黑名单识别失败 |
| **P1-8**:hostname 用 mac+9(8 字节)跟其他路径长度不一致 | 设备名格式混乱 |

加上**没有任何真机长时间测试记录**。

### 如何确认 hotspotd 未启用(默认状态)

```sh
adb shell
ls -l /data/local/hnc/bin/hotspotd
# 应该输出: No such file or directory
```

如果上面的命令找不到文件 → hotspotd 未启用 → `device_detect.sh` 自动 fall back 到 shell daemon → 一切正常。

### 想推动 v3.5+ 启用 hotspotd 怎么办

**不要在 LTS 阶段做这件事**。等 LTS 维护期结束(6-12 个月)后:

1. 修 P0-4(让 hotspotd 写 JSON 后通过 shell enrich 补 hostname_src + 调 mDNS)
2. 修 P1-2(watchdog 用 `-d` 不用 `--daemon`,且不要 `&` + `echo $!`)
3. 修 P1-7(整个文件读到 buffer,strstr 解析,不用 fgets)
4. 修 P1-8(hostname 用 mac+6 改成 8 字节大写 hex,跟 shell/JS 兜底一致)
5. 真机跑 24+ 小时不崩溃 + 内存稳定 + fd 不泄漏
6. 跟 shell daemon 平行运行一段时间对比

只编译它放到 `bin/hotspotd` 不修这些 bug = 立刻翻车。**HNC v3.4.11 LTS 故意不编译 hotspotd 进 zip 包**。

## 关于 mdns_resolve

`mdns_resolve.c` 是**已经稳定运行**的工具,详细单元测试在 `daemon/test/`。RMX5010 / SD8 Elite / Android 16 / KSU `u:r:su:s0` 实测能正常发 5353 UDP 包并接收响应。

## 编译

如果你确实需要编译(只编译 mdns_resolve,**不要编译 hotspotd**):

```sh
export ANDROID_NDK=/path/to/android-ndk-r26
cd daemon
bash build.sh arm64    # 只 build mdns_resolve
```

build.sh 默认两个都 build,但 hotspotd 编译产物**不要**复制到 `bin/`。
