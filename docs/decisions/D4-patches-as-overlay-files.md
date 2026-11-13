# D4 · 两个必留补丁放 patch 层，产物是 overlay 文件

- 状态：已采纳
- 日期：2026-11-12
- 关联：[迁移方案 §2.3、§2.6、§6 D4](../plans/2026-11-11-yunwrt-migration.md)

## 背景

设备上有两处必须改行为的运行时文件：`fw4.uc` 的 flow offload（要用 `net.device` 而不是 `net.physdev`）与 `miniupnpd` 的 `ext_allow_private_ipv4` 强制转发。两者都来自官方 feed 的已编译包，ImageBuilder 没有源码树，也没有包内源码。

## 决策

放在 `patches/` 层，每个补丁目录包含 `*.patch`、`meta.json`、`README.md`。构建时先校验 base（上游原文件 sha256 + 结构断言），再把补丁应用成 `build/files/...` 下的 overlay 文件。

## 后果

- 补丁只在组装阶段作用于 `build/`，`upstream/yaof/` 始终保持逐字节一致。
- base 哈希对不上就硬失败（[D9](D9-base-drift-hard-fail.md)），不静默跳过。
- 不整体移植旧仓的 78 个补丁，只保留这两个。

## 变更记录

- 2026-11-13：UPnP 对齐现网，首版不再安装 `miniupnpd-nftables`，只保留自有 `upnp-nat-relay`。`miniupnpd-force-forwarding` 补丁随之作废，本决策当前只适用于 `fw4.uc` 一个补丁。
