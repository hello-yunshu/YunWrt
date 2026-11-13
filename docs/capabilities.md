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
| Web 管理界面（含反代与大文件上传） | LuCI 跑在 nginx + uwsgi 上，80/443/5686/9083 | 要有 | 官方 feed `luci-nginx`/`nginx-full`/`uwsgi`/`uwsgi-cgi-plugin` + overlay 配置 | `/cgi-bin/luci` 返回 200；`pgrep uhttpd` 为空；80 端口仅 nginx | —（P4 验收后填） |
| 自研 LuCI（nginx-manager / upnp-nat-relay / cloudflare-ip） | 三个 app 都在用；nginx-manager 管站点与反代，cloudflare-ip 把 CF 段写进 nft/dnsmasq | 要有（三个都必须先进自有 feed） | 自研 feed `yun-openwrt-packages` | 菜单可见；`apk info -e` 三个包均成功；`nft list set` 有 CF 段 | —（P3 验收后填） |
| 分流去重与域名防护 | mosdns + `v2ray-geoip/geosite`，`127.0.0.1:953`，hotplug 用 `flock`；`banip` 仅出现在 seed 里，设备未装 | 要有（mosdns + flock）；`banip` **不要** | OpenWrt-Add `apps/luci-app-mosdns`（含 `mosdns`）+ overlay 配置 | mosdns 进程 running；`ss -lnup \| grep :953` 有输出；`command -v flock` | —（P4 验收后填） |
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
