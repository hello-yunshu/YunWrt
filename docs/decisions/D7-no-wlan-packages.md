# D7 · x86 不要 WLAN 包

- 状态：已采纳
- 日期：2026-11-12
- 关联：[迁移方案 §6 D7](../plans/2026-11-11-yunwrt-migration.md)

## 背景

旧 seed 里有一批 WLAN 相关包（约 120 项），x86 软路由用不到，设备上也未使用。

## 决策

首版不写入任何 WLAN 包。若将来恢复，放在 `overlay/packages/disabled/wlan.extra`，默认不启用。

## 后果

- 包清单更小，缺包检查更快。
- 恢复 WLAN 只需把该文件移出 `disabled/` 并重新走能力清单评审。
