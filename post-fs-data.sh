#!/system/bin/sh
# post-fs-data.sh — 在文件系统挂载后、Zygote启动前执行
# 此阶段主要做目录初始化和文件权限设置

# v3.5.0 alpha-0:PATH 健壮性(见 service.sh 同段注释)
[ -z "$HNC_SKIP_PATH_HARDENING" ] && [ -z "$HNC_TEST_MODE" ] && export PATH=/system/bin:/system/xbin:/vendor/bin:$PATH

MODDIR=${0%/*}
HNC_DIR=/data/local/hnc

# 创建持久化数据目录
mkdir -p $HNC_DIR/data
mkdir -p $HNC_DIR/logs
mkdir -p $HNC_DIR/run

# 初始化规则文件
[ ! -f $HNC_DIR/data/rules.json ] && cat > $HNC_DIR/data/rules.json << 'EOF'
{
  "version": 1,
  "whitelist_mode": false,
  "devices": {},
  "blacklist": [],
  "whitelist": []
}
EOF

# 初始化配置文件
[ ! -f $HNC_DIR/data/config.json ] && cat > $HNC_DIR/data/config.json << 'EOF'
{
  "api_port": 8080,
  "hotspot_iface": "auto",
  "poll_interval": 3,
  "watchdog_interval": 10,
  "log_level": "info"
}
EOF

chmod -R 755 $HNC_DIR
chmod 644 $HNC_DIR/data/rules.json
chmod 644 $HNC_DIR/data/config.json

# Fix #7: 先建目录，再统一复制（去除重复操作）
mkdir -p $HNC_DIR/bin $HNC_DIR/api $HNC_DIR/webroot $HNC_DIR/test
cp -rf $MODDIR/bin/* $HNC_DIR/bin/ 2>/dev/null || true
cp -rf $MODDIR/api/* $HNC_DIR/api/ 2>/dev/null || true
cp -rf $MODDIR/webroot/* $HNC_DIR/webroot/ 2>/dev/null || true
# v3.5.0 alpha: 复制测试框架(让 user 能在真机跑 sh test/run_all.sh)
cp -rf $MODDIR/test/* $HNC_DIR/test/ 2>/dev/null || true

chmod 755 $HNC_DIR/bin/*.sh
chmod 755 $HNC_DIR/api/server.sh
chmod 755 $HNC_DIR/test/run_all.sh 2>/dev/null
chmod 755 $HNC_DIR/test/lib.sh 2>/dev/null
chmod 755 $HNC_DIR/test/unit/*.sh 2>/dev/null

# v3.4.9: 自动备份用户数据 — 每天首次开机时备份 data/ 目录
# (rules.json / device_names.json / devices.json),保留最近 7 天。
# 防止 HNC 升级 / JSON schema 变更 / 用户误操作导致配置丢失。
TODAY=$(date +%Y%m%d 2>/dev/null)
if [ -n "$TODAY" ]; then
    BACKUP_DIR="$HNC_DIR/data/.backup-$TODAY"
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR" 2>/dev/null
        # 只备份 .json 文件,不备份 .backup-* 子目录(避免递归)
        for f in $HNC_DIR/data/*.json; do
            [ -f "$f" ] && cp "$f" "$BACKUP_DIR/" 2>/dev/null
        done
        echo "[HNC] backup: created $BACKUP_DIR" >> $HNC_DIR/logs/boot.log
    fi

    # 清理 7 天前的备份(简化:按目录名排序保留最新 7 个)
    BACKUP_LIST=$(ls -d $HNC_DIR/data/.backup-* 2>/dev/null | sort -r)
    KEEP=7
    n=0
    for dir in $BACKUP_LIST; do
        n=$((n+1))
        if [ "$n" -gt "$KEEP" ]; then
            rm -rf "$dir" 2>/dev/null
            echo "[HNC] backup: pruned $dir" >> $HNC_DIR/logs/boot.log
        fi
    done
fi

# PID文件清理（防上次未正常退出）
rm -f $HNC_DIR/run/*.pid

# v3.5.0 P2-6: 日志轮转 — 启动时检查每个 .log 文件,>10MB 的轮转一次
# 之前 HNC 没有日志轮转,长跑(几周)后 logs 目录可能涨到几百 MB
# 简单策略:超过 10MB 就 mv 到 .log.1(覆盖之前的 .1),原文件清空
# 这会丢失约 1/2 的历史(.1 → 删除,.log → .1),但避免无限增长
LOG_MAX_BYTES=$((10 * 1024 * 1024))
for logf in $HNC_DIR/logs/*.log; do
    [ -f "$logf" ] || continue
    size=$(wc -c < "$logf" 2>/dev/null)
    if [ -n "$size" ] && [ "$size" -gt "$LOG_MAX_BYTES" ]; then
        mv "$logf" "${logf}.1" 2>/dev/null
        : > "$logf"
        echo "[HNC] logrotate: $logf rotated (was ${size} bytes)" >> $HNC_DIR/logs/boot.log
    fi
done

echo "[HNC] post-fs-data: initialization complete" >> $HNC_DIR/logs/boot.log
