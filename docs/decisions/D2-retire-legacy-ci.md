# D2 · 弃用旧仓 x86 构建，YunWrt 接管

- 状态：已采纳
- 日期：2026-11-12
- 关联：[迁移方案 §6 D2](../plans/2026-11-11-yunwrt-migration.md)、[保全审计 §1.4.5](../plans/2026-11-11-yunwrt-capability-preservation.md)

## 背景

旧仓 `paniy-little/SWrt` 的活跃 workflow `OpenWrt-Matrix.yml` 仍按"源码构建"路径引用 `SCRIPTS/`、`PATCH/`，而这两棵目录已被 `sync-files.yml` 的 `rsync --delete` 删除。origin/25.12 目前不可构建。

## 决策

不再修旧仓的 x86 构建。x86 镜像由 YunWrt 接管；旧仓保持只读，不删分支、不改其 CI、不搬其历史。

## 后果

- 修旧管线要恢复三棵旧树并持续对抗上游同步，成本高于重建。
- 旧仓的源码级内核补丁能力（SFE 等）随之放弃，见 [D3](D3-track-upstream-no-version-pin.md) 与保全审计 §4.3 的 FlowCone 定案。
- 旧仓仅作为功能对照与历史证据来源被引用。
