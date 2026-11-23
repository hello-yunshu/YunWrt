# D15 · mosdns 与 luci-app-mosdns 必须同为配套补丁版

- 状态：已采纳（2026-11-23 修订，推翻同日早先版本）
- 日期：2026-11-23
- 关联：[D4](D4-patches-as-overlay-files.md)、[D9](D9-base-drift-hard-fail.md)、`scripts/check-mosdns-config.sh`

## 背景

镜像里装 `luci-app-mosdns` 是为了给 `openclash-dns-guard` 提供一个降级解析器：OpenClash 的 653 挂掉时，守护把 dnsmasq 上游切到 `127.0.0.1#953`（mosdns），保证全网 DNS 不断。也就是说 **mosdns 起不来的那天，守护的降级分支是死的，而且没人会发现** —— 653 平时是好的，dnsmasq 根本不走 953。

### 早先版本的错误结论

最初把故障归因为「生成器与二进制天生不配套」，于是弃用生成器，另写一份 `/etc/mosdns/config_custom.yaml` 并让 `configfile` 指向它。

这个归因只对了一半：生成器确实起不来，但**根因不是生成器，而是我们装错了 mosdns 的构建**。

### 真正的原因：同名同版本的两种构建

`mosdns-5.3.4-r15` 这个名字对应互不兼容的两个东西：

| | `qiusimons.github.io/OpenWrt-Add`（原用源） | `sbwml/luci-app-mosdns`（配套源） |
| --- | --- | --- |
| 二进制 | 20,028,792 B | 17,141,624 B |
| `stats_api` | 无 | 有 |
| `adblock_set` | 无 | 有 |
| `ip_set` | 无 | 有 |
| `log.size` / `backups` | `invalid keys` | 接受 |
| cache prefetch / dump | 无 | 有 |

包名、版本号乃至文件大小都很接近，靠元数据**分不出来**。装在无补丁版上的表现是静默降级：生成器写出的 `/var/etc/mosdns.json` 含 `log.size` 与 `stats_api`，加载即 FATAL；而 FATAL 只进 procd 日志。

`sbwml/luci-app-mosdns` 仓库的 `mosdns/patches/` 下就是那套补丁（207/208/210 `adblock_set`、209 log 轮转、211 查询日志、213/214 cache 预取、216-218 `stats_api`）。OpenWrt 构建系统会自动应用 `patches/` 下全部 `*.patch`，因此只要从这个仓库构建，补丁一定在。

实测该版本在设备上：`/plugins/stats_collector/api/v1/{stats,top,logs}` 全部返回真实数据（含带 `elapsed_ms`、`upstream`、`rule` 的逐条查询日志），`adblock_set` 加载 `||ad.test.com^` 后查询返回 NXDOMAIN。

### 界面开关为什么"设了没用"

这是同一件事的另一面。`basic.js` 里几乎每个 `taboption` 都挂着：

```js
o.depends('configfile', '/var/etc/mosdns.json');
```

而 `configfile` 只有两个合法取值。选「Custom Config」后，**界面上 90% 的开关全部消失**，只剩一个 YAML 编辑器。所以「在 LuCI 里配了 adblock 却不生效」不是开关坏了，是它只对生成器那条路生效——而那条路当时被无补丁二进制堵死了。

## 决策

1. **mosdns 与 luci-app-mosdns 都由自有 feed 提供**，源码锁定到 `sbwml/luci-app-mosdns`（`ref` 见 `yun-openwrt-packages/metadata/source-lock.json`），两者同源同补丁。
2. **配置走上游生成器**（`configfile=/var/etc/mosdns.json`），不再随镜像发布手写 YAML。`overlay/files/etc/mosdns/` 整个移除——留着会覆盖包自带文件，并让界面开关再次全部失效。
3. **发行版限制**：`releaseSeries ["25.12"]`，架构限 `x86_64` + `aarch64_generic`。只声明实际会验证的组合。
4. **构建期门禁**（`scripts/check-mosdns-config.sh`）：
   - 静态层：overlay 不得再有 `/etc/mosdns`；`uci-defaults` 必须把 `configfile` 指向 `/var/etc/mosdns.json` 并回读；`listen_port=953`、`listen_address=127.0.0.1`、`redirect=0`；`remote_dns` 不得是境外 DoT。
   - 镜像层：rootfs 里的 `/usr/bin/mosdns` 必须同时含 `stats_api`、`adblock_set`、`ip_set` 三个插件名；`/etc/mosdns` 下不得有多余 YAML。
5. **发布侧另一道门禁**：`yun-openwrt-packages/scripts/verify_mosdns_binary.py` 在打包前解包实跑候选构建——插件注册、`log.size` 接受、命中 `adblock_set` 的查询返回 NXDOMAIN 且被 `stats_api` 计数。两道门禁一在源、一在镜像，互相独立。
6. **上游地址固定为国内可用值**：生成器默认 `remote_dns=tls://8.8.8.8`，而这条线路上 853 会被中断（SYN 无响应或握手后单向 EOF），留着只会让"国外域名"分支卡到超时。`uci-defaults` 改为 `https://dns.alidns.com/dns-query`。
7. **端口必须显式对齐 953**：生成器默认 `0.0.0.0:5335`，而 `openclash-dns-guard` 的 `fallback_port` 与 OpenClash 指向 mosdns 的地址都是 953。不改就会让整条 DNS 链断掉。
8. **构建期自有 feed 必须排在第一位**：上游 `build/scripts/build.sh` 会把 `qiusimons.github.io/OpenWrt-Add` 用 `sed -i "1i"` 插到 ImageBuilder `repositories` 首行，把自有 feed 挤到第二位。mosdns 在两个源里是同名同版本，源顺序就决定了装哪一份。`prepare_imagebuilder()` 因此先把 OpenWrt-Add **追加到末尾**，让上游那句 `if ! grep -qxF` 幂等检查命中而不再插入；上游跑完后还会再复核首行确实是自有 feed，不符即失败。
9. **发布侧版本号唯一化**：`metadata/mainstream-support.json` 给 `mosdns` 与 `luci-app-mosdns` 声明 `"localRelease": "1"`，产物 `PKG_RELEASE` 变成 `上游 × 100 + 1`（r15 → r1501，r1 → r101）。apk 版本比较因此天然压过 OpenWrt-Add 的同版本包，与仓库顺序无关。详见 `yun-openwrt-packages/docs/MOSDNS.md`。

## 后果

- LuCI 的「基本设置 / 高级 / 统计 / 日志 / 规则 / 更新」六个页面**全部可用**，包括广告拦截与查询日志——这是装对构建之后白拿的，不需要另写应用。
- 设备升级不再卡在版本号上：feed 出的是 `mosdns-5.3.4-r1501`，大于 OpenWrt-Add 与旧镜像里的 `r15`，`apk upgrade` 会正常替换。全新刷 ImageBuilder 镜像本来就走 feed 的最新版。
- 跨架构（`aarch64_generic`）的发布侧门禁只做静态断言，没有在真实设备上跑过实跑项。x86_64 会实跑，其结论代表同一份源码树。
- `luci-i18n-mosdns-zh-cn`、`geo2txt`、`v2ray-geoip`、`v2ray-geosite` 仍由上游 feed 满足，不在自有 feed 内。

## 教训

这次的排查链条很长，但起点是一个可以更早发现的问题：**当时没有先验证「同一个包名版本是否存在多种构建」，就下了「生成器不配套」的结论**，随后用一整套 overlay 配置、热插拔自愈、门禁断言去绕开它。这些 workaround 本身写得很仔细，但它们全都在对抗一个本不该存在的问题——而且其中「配置里不许出现 `stats_api`」这条断言，恰好会把正确答案拦在门外。

判据应该是「这个二进制能做什么」，而不是「它叫什么」。这也是为什么现在两道门禁都以**实际行为**为准，而不是包名或版本号。
