# D1 · `rc.local` 沿用上游，不覆盖

- 状态：已采纳
- 日期：2026-11-12
- 关联：[迁移方案 §6 D1](../plans/2026-11-11-yunwrt-migration.md)

## 背景

旧 SWrt 的 `SELF/X86` 覆盖了 `/etc/rc.local`，内容是一段被注释掉的 governor 设置加 `exit 0`，没有实际作用。YAOF 分支自带的 `files/etc/rc.local` 里有 `intel_pstate` 存在性守卫，Hyper-V 上会自动跳过。

## 决策

不覆盖 `rc.local`，直接使用 `upstream/yaof/files/etc/rc.local`。

## 后果

- 少一个覆盖项，少一份 base 校验负担。
- 上游若调整 governor 逻辑，自动跟随，不需要我们维护。
- 若将来确实需要在启动阶段插入动作，走 overlay 新增独立文件（`/etc/init.d/` 或 uci-defaults），不改 `rc.local`。

## 变更记录

- 2026-11-13：上游 YAOF `1139ab0` 删除 `files/`，把 `rc.local` 里的 DMI 兜底、intel_pstate、
  governor/EPP 以及 `99-zram.conf`、网卡 buffer hotplug 迁入 `system-addon` 包（OpenWrt-Add
  `536a4a0`，YAOF `cc48e9c` 在 `packages.common` 启用）。本决策的“跟随上游”对象从
  `upstream/yaof/files/etc/rc.local` 变为 `system-addon`；我们仍不覆盖 `rc.local`，
  `/etc/rc.local` 回到 `base-files` 默认内容。
