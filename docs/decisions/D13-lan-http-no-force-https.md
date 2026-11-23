# D13 · LuCI 管理面取消 http→https 强制跳转

- 状态：已采纳（2026-11-23 修订，见文末「修订」）
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

## 关联但独立的另一件事

LuCI 管理面的协议（本文）与 nginx 用哪个变体是两件互不影响的事，后者见 [D14](D14-nginx-full-variant.md)：已换用上游 `nginx-full`，目的是让 `luci-app-nginx-manager` 的 HTTP/3 开关真正生效（它的 `_nginx_has_v3()` 探针在 `nginx-ssl` 上为假，开关点了没反应）。

**LuCI 自身不开 h3**：管理面是 LAN 内低延迟场景，h2 够用；且 h3 模块在 nginx-manager 的 UI 里就带着一条警告——POST 可能触发 8GB 内存分配导致 500。所以 `97-yunwrt-nginx-http` 只处理「80 不跳 https」，不碰 quic 监听。

（顺带留档：GitHub 上没有可用的 nginx-quic feed —— 只有 `hnyyghk/OpenWrt_Nginx-QUIC` ★2 停更于 2024-10、`sbwml/feeds_packages_net_nginx` ★1 这类单人 fork；自建分叉的成本见 `yun-openwrt-packages` 的 `docs/BUILD.md §10`。）

## 修订 · 2026-11-23（实测推翻两处前提）

在 `192.168.2.1`（OpenWrt 25.12.6，nginx + uwsgi）上逐项复核后，本文「背景」与「决策」各有一处站不住，原方案按原样跑下去并不能解决用户实际看到的现象。

### 一、服务端根本没有那个 302

`uci show nginx` 里 `_redirect2ssl` 段只有 `listen` / `server_name` / `include` 三项，**没有 `option return '302 ...'`**；`curl -sI http://192.168.2.1/` 返回 `200 OK`、无 `Location`；`curl -sL` 全程停在 `http://`。也就是说，上游 nginx-util 这个版本的默认配置里已经没有强跳，D13 原本要删的东西并不存在（`_redirect2ssl` 只剩个名字）。

### 二、真正的「跳转」在浏览器，不在服务端

Edge / Chrome 的 **HTTPS-Upgrades** 会在发出请求前先把 `http://` 升级成 `https://`。443 上挂的是自签证书，点过一次「继续前往」之后浏览器就一路 https —— **显式敲 `http://192.168.2.1` 也拦不住**，因为升级发生在请求离开浏览器之前，路由器连明文请求都收不到。

结论：只要 443 还在监听，「删 302」就是白做。反过来说，**让 443 无人监听**，浏览器升级 https 会立刻连接失败，然后按内置逻辑静默回退到 http —— 这才能达到用户要的效果，且不需要用户去关浏览器的安全开关。

### 三、原脚本是「假成功」

`regen_and_test()` 里 `rm -f "$(readlink "${UCI_CONF}")"` 的意图是删掉符号链接目标再让 `init_lan` 重建。但 `/etc/nginx/uci.conf` 是**普通文件**，`readlink` 返回空串，`rm -f ""` 什么都没删；而实测 `nginx-util init_lan` **也不会重建这个文件**（把 `uci.conf` 移走后再跑 `init_lan`，它不重新生成）。

于是：uci 改了 → `nginx -t` 过了 → `exit 0` → 日志写「已取消 http→https 强跳」→ **nginx 实际加载的配置文件一个字节都没变**。uci-defaults 又成功即删除脚本，现场看起来一切正常，问题却还在。

### 四、修订后的做法

1. **UCI 与 `/etc/nginx/uci.conf` 双写**：后者才是 `nginx -c` 真正加载的文件，必须直接改。
2. 删 `_redirect2ssl` 段，`_lan` 的 `listen` 收缩为 `80` / `[::]:80`，**不再保留任何 ssl 监听**（`ssl_certificate` 行保留无害，`listen` 无 `ssl` 时 nginx 忽略它）。
3. 校验：`nginx -t` 必须过，且改完后不允许再出现监听 443 的行，否则整体回滚。
4. 收尾 `reload`；注意 listen 变更后旧监听要一两秒才释放，验收时别只测一次。

### 五、代价与回退

- 不再有 https 管理入口。内网 + 自签证书下，强制 https 换不来真正的机密性（每次都要点「继续前往」），这是显式取舍。
- 回退：`uci add_list nginx._lan.listen='443 ssl default_server'` 等恢复 443，并把 `uci.conf` 的 `listen 80` 改回 `listen 443 ssl default_server`，然后 `restart`。`uci-defaults` 里的改动不改 `uci.conf` 就等于没做，这一点在回退时同样成立。
