# D15 · mosdns 出厂自带配置，绕开 luci-app-mosdns 的生成器

- 状态：已采纳
- 日期：2026-11-23
- 关联：[D4](D4-patches-as-overlay-files.md)、[D9](D9-base-drift-hard-fail.md)、`scripts/check-mosdns-config.sh`

## 背景

镜像里装 `luci-app-mosdns` 是为了给 `openclash-dns-guard` 提供一个降级解析器：OpenClash 的 653 挂掉时，守护把 dnsmasq 上游切到 `127.0.0.1#953`（mosdns），保证全网 DNS 不断。也就是说 **mosdns 起不来的那天，守护的降级分支是死的，而且没人会发现** —— 653 平时是好的，dnsmasq 根本不走 953。

首版的做法是：不用生成器，另写一份 `/etc/mosdns/yunwrt.yaml`，把 `uci mosdns.config.configfile` 指过去。现网跑下来，这条路有三个各自独立的坑，任意一个都能让 953 无声消失。

### 一、生成器与二进制天生不配套

`luci-app-mosdns` 1.7.15 的 `generate_config` 会写出三样东西：

```
json_add_string "size" "$log_size"      # log 段
json_add_string "type" "stats_api"      # 插件
json_add_string "type" "adblock_set"    # 插件（无条件下发）
```

这三样来自 `QiuSimons/OpenWrt-Add` 的 `apps/luci-app-mosdns/mosdns/patches/` —— 那里有 31 个补丁，其中 `207-add-adblock_set-database-plugin`、`209-feat-add-size-and-backups-config-for-log-file-rotati`、`216-plugin-add-stats_api-plugin` 正好对应。但**补丁在 Makefile 里，不在 feed 的产物里**。取 feed 里那份 `mosdns-5.3.4-r15.apk` 解出来直接跑：

```
$ mosdns start -c probe.yaml -d /etc/mosdns     # probe.yaml 里 log 段写 size
FATAL  'log' has invalid keys: size
$ mosdns start -c probe2.yaml                   # 去掉 size，改用 stats_api / adblock_set
FATAL  failed to init plugin #0 stats, plugin type stats_api not defined
```

同一份二进制里 `strings` 能查到 `udp_server` / `tcp_server` / `forward` / `sequence` / `cache` / `domain_set` / `fallback`，查不到 `stats_api` / `adblock_set` / `query_log`。结论：**这套镜像里的 mosdns 是上游原版，生成器在这上面永远跑不出可加载的配置。**

### 二、自定义路径会被 LuCI 静默改回去

`/www/luci-static/resources/view/mosdns/basic.js` 把 `configfile` 做成了下拉框：

```js
o=s.taboption('basic',form.ListValue,'configfile',_('Config File'));
o.value('/var/etc/mosdns.json',_('Default Config'));
o.value('/etc/mosdns/config_custom.yaml',_('Custom Config'));
o.default='/var/etc/mosdns.json';
```

`/etc/mosdns/yunwrt.yaml` 是**第三个**取值，不在选项里。用户在 LuCI 的 mosdns 页面点一次「保存并应用」，`configfile` 就被写回默认值，init 脚本随即按默认路径生成那份必然 FATAL 的 JSON，953 消失。现网真的这么发生过一次：修好、验证通过，几分钟后被一次 LuCI 保存打回原形，日志里只有 uwsgi 有过活动。

### 三、那份 yaml 的上游在这台网络里是废的

```yaml
upstreams:
  - addr: "tls://1.1.1.1"
  - addr: "tls://8.8.8.8"
```

从路由器实测：

```
1.1.1.1:853   CONNECTED → SSL routines::unexpected eof while reading    Cipher is (NONE)
8.8.8.8:853   CONNECTED → Cipher is TLS_AES_256_GCM_SHA384              OK
```

看起来"一条死一条活"，但抓包说明这两条腿根本不是同一种状态：

```
# 8.8.8.8: 在 pppoe-wan 上一条包都没有，全部出现在 clash 的 TUN 上
tcpdump -i utun      host 8.8.8.8 and port 853   → SYN / SYN-ACK / ClientHello 1551B / ServerHello 5705B
tcpdump -i pppoe-wan host 8.8.8.8 and port 853   → 0 包（7 秒窗口）
ip route get 8.8.8.8 mark 0x162                  → dev utun table 354

# 1.1.1.1: 走真实 WAN 出口
tcpdump -i pppoe-wan host 1.1.1.1 and port 853   → SYN 从 180.116.49.106 发出，无 SYN-ACK，5 次重传
```

分工来自 clash 规则：`8.8.8.8` 命中 `- GEOIP,google,Google`（Google 组 → 节点选择 → 代理），`1.1.1.1` 不命中任何前置规则，落到 `- MATCH,其他`，而"其他"组当前是 **DIRECT**。也就是说：

- **1.1.1.1 是直连出 WAN 的**，撞上链路干扰：有时 SYN 被丢弃（无 SYN-ACK），有时 TCP 建连后收到 EOF —— `SSL handshake has read 0 bytes and written 1558 bytes`、`no peer certificate available`，ClientHello 发出去一个字节都没回。注意不是 RST（那会报 `Connection reset by peer`），也不是端口关闭（那会立刻 RST），是干净的单向中断。
- **8.8.8.8 之所以"通"，是因为它被分流进了代理**。它的通不能证明这条线路能直连 8.8.8.8:853。

这个区别对本决策是决定性的，而不是细节：mosdns 存在的意义是**代理已经挂掉时**兜底。那一刻 8.8.8.8 走不了代理、1.1.1.1 直连被墙 —— **两条腿同时废**，比"一条死一条活"更糟。另外，8.8.8.8 经代理拿到的必然是海外视图，这正是 `fbcontent.cn` 被 EdgeOne 判到新加坡节点的原因（国内直连 218.92.141.107，经海外 DoH 拿到 43.169.32.127）。备用解析器返回错误的 CDN 节点，比返回 SERVFAIL 更难排查。

顺带记一笔：uci 里 `local_dns='61.147.37.1' '218.2.135.1' '221.228.255.1'`（生成器用）三个在这条线路上全部无响应，`119.29.29.29` 也不通。实测可用且快的是 `223.5.5.5` 29ms、`223.6.6.6` 28ms、`114.114.114.114` 14ms。

## 决策

1. 配置改名为 **`/etc/mosdns/config_custom.yaml`**：LuCI 下拉框里唯一被承认的自定义路径，用户在界面上怎么保存都不会被改回去。文件随 overlay 发布，`prepare_rootfs` 在包安装之后叠加，因此会盖掉 `luci-app-mosdns` 的 conffile 版本。
2. 配置**只用上游原版插件**：`forward` / `sequence` / `cache` / `udp_server` / `tcp_server`，主路径走国内递归 UDP，`has_resp` 判断失败后再落到国内 DoH（`dns.alidns.com` 47ms 建连、`doh.pub` 145ms）。
3. **不用 `domain_set` 做 geosite 分流**。mosdns 的 `domain_set` 在文件缺失时是 FATAL（实测：`failed to load file #0 ... no such file or directory`），而备用解析器最不该有的就是"另一个起不来的原因"。CN/非 CN 的差别在降级窗口里只值十几毫秒，不值得换一个硬依赖。
4. `97-yunwrt-mosdns` 把 `adblock` 与 `geo_auto_update` 置 0：这两个选项只服务于生成器，开着只会让 init 脚本后台下载清单写进 `/etc/mosdns/rule`。
5. 删除 `overlay/files/etc/mosdns/yunwrt.yaml`。留着就是下一轮排查的陷阱 —— 它看起来"带了配置"，实际永远不会被加载。
6. **sysupgrade 的自愈**：升级会保留 `/etc`，`uci-defaults` 却只在首启跑一次，升上来的设备 `configfile` 仍是错的默认值。因此把「核对并纠正 `configfile`」挂进已有的 `yunwrt-mosdns-hotplug`（WAN ifup 时触发），纠正后由同一个 worker 合并重启，不阻塞 netifd 的 hotplug 队列。
7. 新增 `scripts/check-mosdns-config.sh` 并接进 `scripts/build.sh`：静态层查配置与 uci-defaults 自洽（无补丁插件、无 `log.size`、953 双栈监听、无境外 DoT、`etc/mosdns` 下没有第二份配置），镜像层查 rootfs 里的文件与 overlay 逐字节一致、`basic.js` 认这个路径、以及 mosdns 二进制到底带不带 `stats_api`（后者只作为 note，供日后判断能不能改回生成器）。

## 后果

- 出厂即有一个 mosdns 真能加载的配置，953 从首启就在。路由器实测（配置同步到 `192.168.2.1` 后）：

  ```
  drill -p 953 -t A m.fbcontent.cn @127.0.0.1
  m.fbcontent.cn.  301  IN CNAME  m.fbcontent.cn.eo.dnse0.com.
  ...eo.dnse0.com. 301  IN A      218.92.141.107      ← 上海，不再是新加坡
  drill -p 953 -t A github.com   → 20.6.7.17          （无污染）
  ```

- 因为走的是 LuCI 承认的路径，界面上「Config File」下拉框会显示 Custom Config，并额外露出一个 YAML 编辑器（`_custom` 字段就是这个文件）。生成器相关的「日志/缓存/adblock/统计」等选项在这个路径下**全部隐藏**，不会再给人"改了有用的"错觉。
- 放弃了生成器带来的 adblock、stats、prefetch、cache 落盘。域名拦截本来由 OpenClash 侧的规则集负责（`广告拦截` 组 `REJECT`，`ads-merged.mrs`），不需要 mosdns 再拦一遍。
- 若日后 feed 换成补丁版 mosdns（`check-mosdns-config.sh` 会打出 `带 stats_api` 的 note），可以改回默认生成器，把配置交还给 uci；届时应同时删掉本决策的第 1、6 条，否则两套配置会打架。
