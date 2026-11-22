# D13 · LuCI 管理面取消 http→https 强制跳转

- 状态：已采纳
- 日期：2026-11-23
- 关联：[D5](D5-keep-nginx-uwsgi.md)、[能力清单](../capabilities.md)

## 背景

D5 定了 nginx + uwsgi 的 Web 栈，但没定"管理面用什么协议进"。实际落到设备上的行为是**强制 https**，来自 `nginx-util` 包自带的默认 `/etc/config/nginx`（不是 YunWrt 加的，`overlay/` 与 `patches/` 都没碰过 nginx）：

```
config server '_lan'
	list listen '443 ssl default_server'
	list listen '[::]:443 ssl default_server'
	option uci_manage_ssl 'self-signed'
	option ssl_certificate '/etc/nginx/conf.d/_lan.crt'

config server '_redirect2ssl'
	list listen '80'
	list listen '[::]:80'
	option return '302 https://$host$request_uri'
```

于是 `http://192.168.2.1/cgi-bin/luci` 被 302 到 `https://` 同一路径，而 443 上只有自签证书，浏览器必然拦一次。**没有受信任证书时，这个强跳换不来任何机密性，只是每次访问多点一次"继续前往"。**

另外确认过的两件事：`uhttpd` 被 `nginx-mod-luci` 的 `60_nginx-luci-support` 停用，它的 `redirect_https` 是 `0`，所以 80 上只有这一个 302；`_lan` 段 include 了 `restrict_locally`（只放 `127/8`、`10/8`、`172.16/12`、`192.168/16`、`fc00::/7`、`fe80::/10` 等私有段，末尾 `deny all`），管理面本来就只在 LAN 可达。

## 决策

1. 新增 `overlay/files/etc/uci-defaults/97-yunwrt-nginx-http`：删掉 `_redirect2ssl` 段，把 `80` / `[::]:80` 挂到 `_lan` 段上。
2. **443 原样保留**，既有 https 书签与 `nginx-manager` 的 SSL 站点都不受影响。
3. 改完先 `nginx -t`，不通过就还原 `/etc/config/nginx` 并重生成，绝不让 Web UI 起不来；重生成成功则 `reload`。

## 后果

- `http://192.168.2.1/` 直接命中 `/www/index.html`（页面内 meta refresh 到 `cgi-bin/luci/`），明文进 LuCI；`https://` 依旧可用。
- 明文入口仍只在 LAN：`restrict_locally` 未动，WAN 侧 80/443 都是 `deny all`。
- `luci-app-nginx-manager` 不受影响：它的站点配置在自己的 `/etc/nginx/conf.d/luci-manager/sites/` 下，每个 SSL 站点是否带 301 由它自己的 `redirect_http_port` 决定（该字段可选，默认不填），与本决策无关。
- 想恢复强制 https：`uci add nginx server` 重建 `_redirect2ssl` 段，或直接 `uci set nginx._redirect2ssl=server` 后补 `listen`/`return` 两项。

## 未采纳的关联方案：换 `nginx-full` 以启用 nginx-manager 的 HTTP/3

`luci-app-nginx-manager` 的 Core Config 里有 `http3`（HTTP/3 over QUIC）开关，但生成器 `nginx-manager-gen` 用 `_nginx_has_v3()` 探针（`nginx -V | grep http_v3_module`）判断，探针为假时**静默跳过** —— 也就是说在官方 `nginx-ssl` 上这个开关是空转的。

要让开关真生效，唯一途径是换官方 `nginx-full`：它是 `VARIANT:=full`「ALL config selected」，官方预编译二进制内嵌 `--with-http_v3_module` + `--with-compat`；同版本 `nginx-ssl` 没有 `--with-http_v3_module`（`Config_ssl.in` 的 `NGINX_HTTP_QUIC` 默认 `n`）。代价其实很小：`Installed-Size` 1,013,760 B vs 880,640 B（+130 KB），`Depends` 清单完全一致，`Provides` 含 `nginx` 与 `nginx-ssl`，`luci-nginx`、`nginx-mod-luci`、`luci-app-nginx-manager`（v1.8.8 起依赖虚拟包 `nginx`，见其 issue #4 / `4d20ddd`）三处依赖都能满足。

**仍然不做**，理由是 nginx-manager 自己的 UI 文案就写着：

> **Warning:** Nginx HTTP/3 module has a known bug where POST requests may trigger a massive memory allocation (8GB), causing 500 errors. If you encounter this issue, disable HTTP/3 until nginx fixes the bug.

给一个自带 8GB 内存分配风险、且只影响 LAN 内反代站点的能力换掉整个 nginx 变体，不划算。等上游修了这个 bug、同时把 `NGINX_HTTP_QUIC` 默认翻成 `y`，`nginx-ssl` 会自动带上 v3，届时零改动即可评估。

（顺带留档：GitHub 上没有可用的 nginx-quic feed —— 只有 `hnyyghk/OpenWrt_Nginx-QUIC` ★2 停更于 2024-10、`sbwml/feeds_packages_net_nginx` ★1 这类单人 fork；自建分叉的成本见 `yun-openwrt-packages` 的 `docs/BUILD.md §10`。）
