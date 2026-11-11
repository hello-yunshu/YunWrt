# D8 · 不镜像 feed、不设哈希门禁；build-log 只记线索，Release 归档当次 APK 集合

- 状态：已采纳
- 日期：2026-11-12
- 关联：[迁移方案 §0.3、§2.5、§6 D8](../plans/2026-11-11-yunwrt-migration.md)

## 背景

上一版打算镜像 feed 索引与公钥、给索引做哈希门禁，并用快照复现历史镜像。这与"跟随上游"的取向冲突，而且解决不了"覆盖静默失效"这个真问题。

## 决策

1. **不镜像 feed**：不保存 feed 索引/公钥/工具的历史副本，不做 `feed-snapshot` 子目录。
2. **不做哈希门禁**：feed 索引哈希不参与任何通过与失败的判定。
3. **只记线索**：每次构建写一份 `build-log/<timestamp>-<yaof-sha7>.json`，记录 `yaof_commit`、实际 `openwrt_version`、`kernel_version`、`vermagic`、全量包与版本、`feed_index_sha256`。这些字段只用于排障，不用于校验、不回退。
4. **Release 归档当次 APK 集合**：每次发布把当次构建实际使用的 `.apk` 集合与 manifest 作为 Release 资产归档，供事后核对"那一版到底装了什么"。这是发布产物，不是 feed 镜像，也不承诺可被后续构建复用。

## 后果

- 不会出现"用快照复现"的验收项。
- 排障时以 build-log 与 Release 资产为准，不接受"同输入同输出"的假设——上游 feed 每天重建，本来就不成立。
- 回退方式只有 `git revert` 或重新触发构建。
