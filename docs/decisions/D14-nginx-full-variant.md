# D14 · nginx 变体改用上游 nginx-full

- 状态：已采纳
- 日期：2026-11-23
- 关联：[D5](D5-keep-nginx-uwsgi.md)、[D13](D13-lan-http-no-force-https.md)、[能力清单](../capabilities.md)

## 背景

D5 定了 nginx + uwsgi 的 Web 栈，但没定用哪个 nginx 变体，实际由 `luci-nginx` 的 `+nginx` 虚拟依赖 + `nginx-ssl` 的 `DEFAULT_VARIANT:=1` 决定，镜像里落的是 `nginx-ssl`。

需要换的理由只有一个：**`luci-app-nginx-manager` 的 HTTP/3 开关在 `nginx-ssl` 上是空转的。**

它的 Core Config 里有 `http3`（HTTP/3 over QUIC）开关，生成器 `nginx-manager-gen` 用探针判断能不能写 quic 指令：

```sh
_nginx_has_v3() {
	[ -z "${_NGINX_HAS_V3+x}" ] && {
		_NGINX_HAS_V3=0
		nginx -V 2>&1 | grep -q "http_v3_module" && _NGINX_HAS_V3=1
	}
	[ "${_NGINX_HAS_V3}" = "1" ]
}
```

探针为假时，`listen ... quic`、`add_header Alt-Svc`、`http3_stream_buffer_size` 三处全被静默跳过 —— 开关点了没反应，也不报错。

而官方预编译二进制里，只有 `nginx-full` 带这个模块。把 24.10.8 的两个 ipk 拆开，直接读二进制内嵌的 `configure arguments`：

```
nginx-full:  --with-compat --with-http_ssl_module --with-http_v2_module --with-http_v3_module
nginx-ssl :  --with-compat --with-http_ssl_module --with-http_v2_module
```

同源同版本，差异只在变体：feed 的 `net/nginx/Makefile` 里 `nginx-full` 是 `VARIANT:=full`「ALL config selected」，`nginx-ssl` 走 `Config_ssl.in`，其中 `NGINX_HTTP_QUIC` 默认 `n`。

## 决策

`overlay/packages/common.extra` 里显式列 `nginx-full`，并加负条目 `-nginx-ssl`，放在 Web 管理栈段首。不引入第三方 feed、不自建分叉（后两条的调研与放弃理由见 D13 附录和 `yun-openwrt-packages/docs/BUILD.md §10`）。

## 代价与兼容性（都核过）

| 项 | nginx-ssl | nginx-full |
|---|---|---|
| Installed-Size | 880,640 B | 1,013,760 B（+130 KB） |
| Depends | libc / libopenssl3 / libpthread / libpcre2 / zlib / libxml2-16 / nginx-ssl-util | **完全一致** |
| Provides | nginx | **nginx, nginx-ssl** |
| --with-compat | 有 | 有 |

- **不新增依赖**：`libxml2-16` 看着像新增，实则 `nginx-ssl` 因 `NGINX_DAV` 已依赖它，最近一次成功构建的 `build-log/20261113T130048Z-cc48e9c.json` 里已在装。
- **三处依赖都被满足**：`luci-nginx` 集合 `+nginx`、`nginx-mod-luci` `Depends: nginx-ssl`、`luci-app-nginx-manager` `+nginx`（v1.8.8 起，见其 issue #4 / `4d20ddd`）。后者的 `LUCI_DEPENDS` 早已从 `+nginx-ssl` 改成虚拟包，自有 feed 现发布 1.8.11。
- **动态模块照常加载**：`nginx-mod-*` 与二进制同版本同 release 滚动，且 `--with-compat` 只放宽 `NGX_MODULE_SIGNATURE_*` 位，不影响版本匹配。
- **负条目的真实作用域**：ImageBuilder 会把 `-x` 从请求列表里整条剔除（`include/target.mk` 的 `filter_packages`、顶层 `Makefile` 的两处 `filter-out`），所以 `-nginx-ssl` 并**不会**阻止 apk 通过依赖路径选中 nginx-ssl —— 它只是"没人要求就不请求"。真正保证只装 full 的是"显式请求 nginx-full 且它 `Provides: nginx, nginx-ssl`"。负条目留着是为了声明意图、并防止将来有人把 `nginx-ssl` 显式写进清单。

## 后果

- 镜像里 `nginx -V` 含 `--with-http_v3_module`，nginx-manager 的 HTTP/3 开关从"点了没反应"变成真正可写 quic 指令。**是否开启仍由用户在那个开关上决定**（默认关），本决策不替用户打开。

### 解析结果实测（2026-11-23）

用 ImageBuilder 自带的 `staging_dir/host/bin/apk`（apk-tools 3.0.5）对着真实的 25.12.6 x86_64 仓库做 `add --simulate`：

| 组合 | 装进来的 nginx 包 | 事务总包数 |
|---|---|---|
| `nginx-full` + `luci-nginx` + `nginx-mod-luci` | **nginx-full 1.30.7-r1**（无 nginx-ssl） | 72 |
| `luci-nginx` + `nginx-mod-luci`（现状基线） | nginx-ssl 1.30.7-r1 | 72 |
| 只请求 `nginx-full` | nginx-full 1.30.7-r1 | 13 |

两种情况事务包数都是 72 —— **换变体没有引入任何新依赖**，只是把第 61 项从 nginx-ssl 换成了 nginx-full。`nginx-mod-luci` 的 `Depends: nginx-ssl` 由 `nginx-full` 的 `Provides` 满足，apk 没有把真包再拉一遍。

- HTTP/3 模块的已知风险由 nginx-manager 的 UI 自行警告（POST 可能触发 8GB 内存分配导致 500），那里已经写了「遇到就关掉，等 nginx 修」。镜像层面不做拦截。
- LuCI 自身的协议与跳转由 D13 管，与本决策无关：本决策不改任何 uci 配置。
- 上游若把 `NGINX_HTTP_QUIC` 默认翻成 `y`，`nginx-ssl` 也会带 v3，届时可回退变体省回 130 KB；回退方式就是删掉这两行。
