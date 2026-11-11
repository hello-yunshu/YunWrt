# D5 · Web 栈保留 nginx + uwsgi

- 状态：已采纳
- 日期：2026-11-12
- 关联：[迁移方案 §6 D5、§8.1](../plans/2026-11-11-yunwrt-migration.md)

## 背景

设备实际在跑 nginx（80/443/5686/9083）与 uwsgi，LuCI 走 `uwsgi_modifier1 9`，另有自研 `luci-app-nginx-manager` 管理站点与反代。

## 决策

保留 nginx + uwsgi + LuCI 的组合，不切回 uhttpd。镜像内 `pgrep uhttpd` 必须为空，80 端口只属于 nginx。

## 后果

- 需要一个 overlay/包清单层面的处理来停用 `uhttpd` 与 `luci` 元包的默认拉起，验收项写入 P3 与 P4。
- 上游若把 LuCI 从 uwsgi 迁走，`uwsgi_modifier1 9` 那套配置会失效，由能力验收发现。
