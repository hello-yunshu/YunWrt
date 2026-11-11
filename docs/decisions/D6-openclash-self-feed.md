# D6 · 代理栈首版用 OpenClash，走自有 feed 编译

- 状态：已采纳
- 日期：2026-11-12
- 关联：[迁移方案 §6 D6、§8.1](../plans/2026-11-11-yunwrt-migration.md)、[保全审计 §10.2](../plans/2026-11-11-yunwrt-capability-preservation.md)

## 背景

设备实测 `luci-app-openclash 0.47.156` 在运行（`clash` 进程、`/etc/config/openclash`、653/890-895/9090 端口）。`QiuSimons/OpenWrt-Add` 把 OpenClash 放在 `legacy/`，而 `build-feed.yml` 只发布 `apps/*` 与 `themes/*`，所以官方 feed 里确定没有。

## 决策

从 `vernesong/OpenClash` 固定 tag 拉源码，用 SDK 编译并签名，随自有 feed 发布。该包 `PKGARCH:=all`，依赖在官方 25.12.6 已核实齐全。`nikki`（OpenWrt-Add `apps/OpenWrt-mihomo` 已发布）只作为回退。

## 后果

- P3b 与 P3 并行，只依赖 P2 的 feed 密钥/索引与 SDK。
- `clash_meta` 核心不放进包里，由 overlay 预置并记录 sha256。
- 上游出新 tag 才重编；版本对应关系进 `build-log` 与能力清单。
