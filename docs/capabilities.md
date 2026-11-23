# YunWrt 能力清单

- 状态：骨架（P0 建立；P5 收口定稿）
- 日期：2026-11-12
- 判定口径：只看一件事——这个能力在首版镜像里能不能用。不要求包名相同、不要求配置项逐项对齐、不要求与旧镜像包集合一致。
- 关联：[迁移方案 §7](../plans/2026-11-11-yunwrt-migration.md)、[功能保全审计](../plans/2026-11-11-yunwrt-capability-preservation.md)

## 字段

| 字段 | 说明 |
|---|---|
| 能力域 | Web / 代理 / DNS / 转发与加速 / UPnP / VPN / 网络初始化 / 性能 / 存储 / 运维工具 |
| 我在用的能力 | 描述功能，可附当前实现作为参考，**不作为判定依据** |
| 首版 | `要有` / `用替代` / `不要` |
| 实现方式 | 包 / overlay / patch / 自研 feed / 替代品名 |
| 可执行验收 | QEMU 里能跑的命令与期望输出 |
| 结果 | 最近一次能力验收的 pass/fail |

## 清单

| 能力域 | 我在用的能力 | 首版 | 实现方式 | 可执行验收 | 结果 |
|---|---|---|---|---|---|
| Web 管理界面（含反代与大文件上传） | LuCI 跑在 nginx + uwsgi 上，80/5686/9083（443 已按 D13 修订关闭）；管理面只走明文 http，浏览器不再自动升级 https | 要有 | 官方 feed `luci-nginx`/`nginx-full`/`uwsgi`/`uwsgi-cgi-plugin` + overlay 配置（变体见 D14，取消强跳见 D13） | `curl -sI http://192.168.2.1/` 返回 200 且无 `location: https`；`/cgi-bin/luci` 返回 LuCI 登录页（未认证时状态码 403、页面正常）；`pgrep uhttpd` 为空；80 端口仅 nginx；`nginx -V` 含 `--with-http_v3_module`（h3 能力在位，默认不开） | —（P4 验收后填） |
| 自研 LuCI（nginx-manager / upnp-nat-relay / cloudflare-ip） | 三个 app 都在用；nginx-manager 管站点与反代，cloudflare-ip 把 CF 段写进 nft/dnsmasq | 要有（三个都必须先进自有 feed） | 自研 feed `yun-openwrt-packages` | 菜单可见；`apk info -e` 三个包均成功；`nft list set` 有 CF 段 | —（P3 验收后填） |
| 性能管理器（PM，D12） | 现网后装在用：性能调优、基准测试、Rill 智能建议、历史回滚 | 要有 | 自有 feed `luci-app-performance-manager-all`（旧拆分包名冻结，见 D12） | `apk info -e luci-app-performance-manager-all rill-runtime`；`/etc/init.d/performance-manager status` running；LuCI 菜单可见 | 2026-11-22 QEMU 已验证（feed 资格 `device-runtime-qualified`）：`apk list --installed` 显示 PM 1.0.7-r7 + `rill-runtime` 1.5.6-r8 + `rill-runtime-manager` 1.0.0-r2，init 已 enabled 且进程 running，`luci-app-performance-manager.json` 菜单在位；证据见 feed 仓 `docs/QUALIFICATION-PROGRESS.md` |
| 降级解析器 + DNS 管理（mosdns，D15） | 独立在 `127.0.0.1:953` 服务，只在 OpenClash 的 653 挂掉时由 dns-guard 顶上去。配置走上游生成器（`/var/etc/mosdns.json`），镜像里的 mosdns 是**配套补丁版**（`stats_api` / `adblock_set` / `ip_set` 齐全），因此 LuCI 的六个页面全部真实可用：上游分组、缓存与预取、广告拦截（规则订阅）、查询日志、统计、配置编辑。`listen_port`/`listen_address` 由 uci-defaults 钉为 `953`/`127.0.0.1`（生成器默认 `0.0.0.0:5335` 会断链），`remote_dns` 改为国内 DoH（默认 `tls://8.8.8.8` 在这条线路上 853 被中断）。hotplug 用 `flock` 且只在 953 不在监听时才重启（惰性自愈）；`banip` 仅出现在 seed 里，设备未装 | 要有（mosdns + flock）；`banip` **不要** | 自有 feed 从 `sbwml/luci-app-mosdns` 构建（`mosdns` + `luci-app-mosdns`，补丁随源码树自带），`uci configfile` 保持生成器默认路径 | `uci get mosdns.config.configfile` = `/var/etc/mosdns.json`；`uci get mosdns.config.listen_port` = `953`；`grep -ci :03B9 /proc/net/udp` ≥ 1；`drill -p 953 -t A m.fbcontent.cn @127.0.0.1` 返回国内节点（非新加坡）；`curl -s 127.0.0.1:9091/plugins/stats_collector/api/v1/stats` 返回 JSON 且 `total_queries` 增长；`strings /usr/bin/mosdns \| grep -c stats_api` ≥ 1；`command -v flock`；`ifup wan` 后 953 正常时 mosdns PID 不变 | —（P4 验收后填） |
| 透明代理 | `luci-app-openclash 0.47.156`，`clash` 进程，653/890-895/9090，两条订阅 | 要有 | 自有 feed 从 `vernesong/OpenClash` 编译（`PKGARCH:=all`）；`nikki` 仅回退 | `apk info -e luci-app-openclash`；`pgrep -f clash` 有进程；`/etc/init.d/openclash status` running；核心 sha256 与记录一致 | —（P3b 验收后填） |
| 转发加速 | 设备用 `kmod-shortcut-fe-cm` + `kmod-nft-fullcone`，内核被旧补丁改过 | 用替代（**FlowCone 定案**） | OpenWrt-Add `apps/FlowCone`（eBPF）+ 官方 `kmod-nft-offload` + BBR | 审计 §4.4 五条功能断言：`apk info -e flowcone` 且 `/sys/kernel/btf/vmlinux` 存在；`pgrep -f flowcone`；`nft list ruleset \| grep -E 'flowtable\|offload'`；`dmesg` 无 flowcone/bpf 报错；`uci get firewall.@defaults[0].shortcut_fe` 不存在 | —（P4 验收后填） |
| WireGuard | `kmod-wireguard` + `wireguard-tools` + `luci-proto-wireguard`，`wg0` 监听 8978/udp、`10.8.0.1/24`；未装 `luci-app-wireguard` | 要有 | 官方 feed（kmod 在 target `kmods/`） | `apk info -e kmod-wireguard wireguard-tools luci-proto-wireguard`；`wg show` 有接口 | —（P4 验收后填） |
| 默认 IP / WAN 初始化 / Hyper-V 调优 | `99-x86-vm-network`、`90-swrt-x86-network.conf`、`swrt-vm-performance`、Hyper-V ring 脚本 | 要有 | overlay 重写（重写 `99-x86-vm-network`） | P4 阻塞验收 ①–⑦（WAN 存在、LAN `192.168.2.1/24`、首启删脚本、端口范围、`fw4 check`、`upnp_nat_relay` running） | —（P4 验收后填） |
| UPnP / NAT-PMP | 现网只有 `miniupnpc` 客户端 + 自研 `upnp-nat-relay`（enabled 但未运行）；`miniupnpd` 未装 | 要有（只保留中继，修到 running） | 自有 feed `upnp-nat-relay`（客户端中继 + nftables DNAT）；**不装** `miniupnpd-nftables` 与上游 `luci-app-upnp` | `apk info -e luci-app-upnp-nat-relay`；`upnp_nat_relay` running；`/etc/config/upnp_nat_relay` 存在；镜像内无 `miniupnpd`、无 `/etc/config/upnpd` | —（P4 验收后填） |
| DDNS 与 Cloudflare 联动 | `ddns-scripts-cloudflare` + `cf-ip-auto` 每日 3 次 cron（服务 `cf_ip` 本身无实例） | 要有 | 官方 feed + 自研 `luci-app-cloudflare-ip` | `apk info -e ddns-scripts-cloudflare luci-app-cloudflare-ip`；cron 条目存在 | —（P3 验收后填） |
| 文件共享与局域网发现 | samba4、avahi、wsdd2 | 要有 | 官方 feed | 三个服务 running；`smbclient -L localhost` 可列共享 | —（P4 验收后填） |
| 运维基础 | dropbear、cron、sysntpd、fail2ban | 要有 | 官方 feed | 四个服务 running；`fw4 check` 退出 0 | —（P4 验收后填） |
| 主题与监控 | `luci-theme-aurora`、`luci-app-aurora-config`、`luci-app-bandix`、`luci-app-ramfree` | 要有（`bandix` 保留包、默认不启用） | OpenWrt-Add `themes/`、`apps/` | `apk info -e` 四项成功；主题菜单可见 | —（P3 验收后填） |
| TCP 拥塞控制 | BBR（`kmod-tcp-bbr`） | 要有 | 官方 target `kmods/` | `sysctl net.ipv4.tcp_congestion_control` = `bbr` | —（P4 验收后填） |

## 待收口项

P5 发布评审时逐行复核：不保留「待定」；每行「结果」与最近一次能力验收报告一致；三方对照表入库。
