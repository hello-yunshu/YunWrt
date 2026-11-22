# D12 · 性能管理器纳入镜像（luci-app-performance-manager-all）

- 状态：已采纳
- 日期：2026-11-23
- 关联：[保全审计 §2.2/§8/§9.1](../plans/2026-11-11-yunwrt-capability-preservation.md)（被本文推翻的部分）、[能力清单](../capabilities.md)

## 背景

2026-11-11 保全审计把 `performance-manager` / `luci-app-performance-manager` / `luci-i18n-performance-manager-zh-cn`（1.0.4-r1）判为「来源不明：GitHub 未搜到对应仓库」，处置「放弃（除非用户要求）」。该结论已过时：

- 来源已明确：[hello-yunshu/luci-app-performance-manager](https://github.com/hello-yunshu/luci-app-performance-manager)，审计看到的是旧树里的历史拆分包。
- 设备现网在用：PM 已后装到主路由（1.0.7-r4 起，八页 LuCI 与 Rill 能力实机验收过），属于「现网在用」而非残留。
- 自有 feed 已具备交付条件：`yun-openwrt-packages` 以 `luci-app-performance-manager-all` 单包形式发布（25.12.6/x86_64 为 `1.0.7-r7`，build-verified；源锁锁定 v1.0.7 提交），硬依赖 `rill-runtime` / `rill-runtime-manager` 同源发布。

## 决策

1. `overlay/packages/common.extra` 追加 `luci-app-performance-manager-all`；旧拆分包名不进清单。
2. `scripts/check-packages.sh` 冻结线继续封禁旧拆分包名（与 all 单包 `CONFLICTS`），all 包名不在封禁正则内。
3. 首版冻结线（§10.4）为 PM 开此例外；后续新增包仍走 issue → 能力清单 → 评审。

## 后果

- 镜像内 PM 以 all 单包交付：Core + LuCI + ACL/menu + 简体中文 + Rill glue + 升级保留规则；`/usr/bin/rill-runtime` 由共享 `rill-runtime` 包提供，PM 不捆绑 Runtime 二进制。
- 与 CFI 共用同一 `rill-runtime`，避免 Preview/Stable 双通道互斥问题（旧 `rill-runtime-preview` 仍在冻结线内）。
- apk 依赖解析自动带入 `rill-runtime`、`rill-runtime-manager`；manifest 核对只断言请求包，自动依赖由 ImageBuilder 负责。
