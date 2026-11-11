# YunWrt

跟随 `QiuSimons/YAOF` 分支 `25.12` 的 x86_64 自用镜像流水线。不 fork 上游、不锁版本，只保留自己在用的能力。

- 迁移方案：[docs/plans/2026-11-11-yunwrt-migration.md](docs/plans/2026-11-11-yunwrt-migration.md)
- 功能保全审计：[docs/plans/2026-11-11-yunwrt-capability-preservation.md](docs/plans/2026-11-11-yunwrt-capability-preservation.md)
- 决策记录：[docs/decisions/](docs/decisions/)
- 能力清单：[docs/capabilities.md](docs/capabilities.md)

## 结构

| 路径 | 作用 |
|---|---|
| `upstream/yaof/` | YAOF 纯净镜像，同步机器人唯一可写目录，禁止手工修改 |
| `overlay/files/` | rootfs 覆盖层，覆盖项旁带 `.meta.json` |
| `overlay/packages/` | 追加包清单（`*.extra`），缺包即失败 |
| `patches/` | 少数必须改行为的运行时文件，带 base 哈希与断言 |
| `scripts/` | 同步、检查、组装、构建、能力验收 |
| `build-log/` | 每次构建的只读快照，只做排障线索，不参与门禁 |

## 构建

```bash
./scripts/build.sh
```
