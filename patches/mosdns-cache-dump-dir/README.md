# mosdns-cache-dump-dir

## 为什么需要

`luci-app-mosdns` 的 init 脚本把 DNS 缓存的 dump 文件写死在 `/etc/mosdns/cache.dump`：

```sh
DUMP_FILE=/etc/mosdns/cache.dump
...
json_add_string "dump_file" "/etc/mosdns/cache.dump"
```

`/etc` 在 overlay 闪存上，缓存按 `dump_interval`（默认 3600s）周期性落盘，属于没有必要的闪存磨损；而这份 dump 的唯一用途是「重启后恢复缓存」，路由器很少重启，收益很低。

## 改什么

```diff
-DUMP_FILE=/etc/mosdns/cache.dump
+DUMP_FILE=/tmp/mosdns/cache.dump
...
-			json_add_string "dump_file" "/etc/mosdns/cache.dump"
+			json_add_string "dump_file" "/tmp/mosdns/cache.dump"
...
 	# init dump_file
+	mkdir -p "${DUMP_FILE%/*}"
```

`/tmp` 是 tmpfs；OpenWrt 上 `/var` 本来就是 `/tmp` 的软链，所以 `/tmp/mosdns` 就是 mosdns 自己的运行目录（geo 数据也在这里）。新增的 `mkdir -p` 保证重启后目录被重新创建，不会因 tmpfs 清空而写失败。

## 基线

- 包：`luci-app-mosdns` 1.7.15（`sbwml/luci-app-mosdns`，锁在 `yun-openwrt-packages/metadata/source-lock.json`）
- 源码 ref：`dbdd91ab8ac8b079b6a3ca1a48d99e970d17111b`
- 原文件 sha256：`666ddbb1fbc269d7d45f891bc58876c2b14ac3c3bdd9e218080788c48a859cdd`
- 以 `base/etc/init.d/mosdns` 提交在仓库内，`apply.sh` 先校验哈希再打补丁

## 失效怎么发现

- 内置基线被改动：`apply.sh` 直接失败
- 上游换了 init 脚本：`scripts/check-patch-bases.sh <version>` 按 meta.json 的 `source_ref` 取源码校验哈希，不一致即失败，必须人工复核后更新 base 与补丁
- 打完后 `grep 'DUMP_FILE=/tmp/mosdns/cache.dump'` 或 `mkdir -p "${DUMP_FILE%/*}"` 不命中：`apply.sh` 失败

## 注意

这个补丁只作用于**镜像组装**（`build/files/etc/init.d/mosdns`），所以重刷镜像会带上。设备上执行 `apk upgrade mosdns/luci-app-mosdns` 仍会把 init 脚本覆盖回包内版本，需要重新刷镜像或手工再打一次。
