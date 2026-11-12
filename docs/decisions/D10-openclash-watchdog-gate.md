# D10 · OpenClash 看门狗缺陷用构建门禁兜底，不改包文件

- 状态：已采纳
- 日期：2026-11-12
- 关联：[D6 自有 feed 编译](../decisions/D6-openclash-self-feed.md)、[D9 base 漂移硬失败](D9-base-drift-hard-fail.md)

## 背景

设备实测 `luci-app-openclash 0.47.156` 的 `/usr/share/openclash/openclash_watchdog.sh` 用

```sh
ubus call service list '{"name":"openclash"}' | jsonfilter -e '@.openclash.instances.*.running' | grep -q 'true'
```

判断主核心是否在跑。0.47.x 里 `openclash-watchdog` 自己是 `openclash` procd 服务的实例，通配符展开成两行 `true`，主核心崩溃后仍判为"在跑"，`enable=0 + stop` 分支永不触发。叠加 `respawn 300 5 3` 耗尽后 procd 不调用 `stop_service`，`revert_dnsmasq` / `revert_firewall` 一次都不执行，dnsmasq 停在 `127.0.0.1#653` 而该端口无人监听，全屋域名解析失效。

镜像侧事实（2026-11-12 产物核对）：YunWrt 不含 OpenClash 源码，`luci-app-openclash` 从自有 feed（`hello-yunshu/yun-openwrt-packages`）以 apk 安装，版本 `0.48.002`。该 apk 里的看门狗与 `vernesong/OpenClash` 标签 `v0.48.002` 逐字节一致，已改成精确探测 `instances.openclash`，并把看门狗拆成独立的 `openclash-watchdog` procd 服务。也就是说坏版本根本没进镜像。

## 决策

不改包文件、不加常驻脚本，只在构建末尾加门禁 `scripts/check-openclash-watchdog.sh`：从 ImageBuilder 组装出的 rootfs 读 `openclash_watchdog.sh`，断言

1. 不含 `instances.*.running`（缺陷签名）；
2. 含 `instances.openclash.running` 或 `instances.openclash.respawn.retry`（修复签名）。

任一不满足即构建失败。`scripts/build.sh` 在缺包检查之后调用它。

## 被否的落法

- **镜像层替换/`sed` 那一行**：ImageBuilder 的 `FILES` overlay 确实能盖掉包文件，但 `/usr/share/openclash/*` 是包文件，设备上 `apk upgrade luci-app-openclash` 会原样覆盖，补丁活不过一次升级；还要维护 25KB 副本或 base 哈希，而 0.48.002 已经修好，等于重复建设。
- **`/etc/openclash/custom/` 或 `/etc/uci-defaults` 放独立自愈脚本**：目录不属于包，升级不会删，但要长期生效得再拉起一个常驻 procd 服务；而且 `enable_redirect_dns=1` 时 OpenClash 自己的 "Force Reset DNS Hijack" 只要看门狗还活着就会把 dnsmasq 改回 `127.0.0.1#653`，自愈脚本必须同时 `enable=0` + `stop` 才不被改回去，逻辑与看门狗完全重复。

## 后果

- feed 回退到 `< 0.48.002` 或被打上坏版本：构建直接失败，不会出镜像。
- 门禁在构建期执行，不受设备 `apk upgrade` 影响，每次构建都重新复核。
- 上游若重构探测写法（不再出现 `instances.openclash.*`），门禁会硬失败，需要人工确认行为后更新断言，对齐 D9 的"不静默降级"。
