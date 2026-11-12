# D11 · 镜像分区几何对齐设备 p1=64 MiB

- 状态：已采纳
- 日期：2026-11-13
- 关联：[D10 OpenClash 看门狗门禁](D10-openclash-watchdog-gate.md)

## 背景

ImageBuilder 打出的 x86-64 combined-efi 镜像，p1（kernel/FAT）只有 16 MiB；目标设备上的 p1 是 64 MiB。
两者 GPT 不一致：

| | p1 start | p1 扇区 | p2 start | p2 扇区 | 总扇区 |
|---|---|---|---|---|---|
| 设备 `/dev/sda` | 512 | 131072（64 MiB） | 131584 | 2097152（1024 MiB） | 2228799 |
| 旧镜像 | 512 | 32768（16 MiB） | 33280 | 2097152（1024 MiB） | 2130465 |

后果是一条静默失败链，全部在升级路径上：

1. `platform_check_image` 用 `get_partitions` 比对 `part lba size`，差集非空 → 打印
   "Partition layout has changed. Full image will be written."，随后 `platform_do_upgrade`
   走 `get_image_dd of=/dev/$diskdev`，整盘写。
2. 整盘写后设备 p1 变成 16 MiB，可用空间约 10 MiB；而 `sysupgrade -b` 生成的配置包
   有 54.1 MiB（历史包 56.6 MiB）。
3. `platform_copy_config` 只做 `cp -af "$UPGRADE_BACKUP" /mnt/sysupgrade.tgz`，不检查
   剩余空间；`do_stage2` 调完 `platform_copy_config` 也不检查返回值。
4. 重启后 `/lib/preinit/79_move_config` 找不到 `/boot/sysupgrade.tgz`，配置直接丢失，
   系统以默认配置启动——没有任何报错。

即：只要布局不一致，`sysupgrade` 保留配置**必然**失败，且失败是静默的。

## 决策

在 `scripts/build.sh` 的 `prepare_imagebuilder()` 里，解包后直接改 ImageBuilder 的
`.config`：

```
CONFIG_TARGET_KERNEL_PARTSIZE=64
CONFIG_TARGET_ROOTFS_PARTSIZE=1024
```

原因：ImageBuilder Makefile 只把 `ROOTFS_PARTSIZE` 映射成 make 变量并转给子 make
（`target/imagebuilder/files/Makefile`），**没有** `KERNEL_PARTSIZE` 的映射；x86 的
`gen_image_generic.sh` 读的是 `$(CONFIG_TARGET_KERNEL_PARTSIZE)`，所以只能写 `.config`。
`.config` 由 `rules.mk` 引入，命令行的 `CONFIG_TARGET_ROOTFS_PARTSIZE=1024`（上游
`build/scripts/build.sh` 已固定）优先级更高，两者取值一致，不冲突。

`CONFIG_TARGET_ROOTFS_PARTSIZE=1024` 也一并写死：IB 默认是 104，靠上游传参才变成 1024；
一旦有人用 `-S/--rootfs-size` 或改上游传参，p2 就会偏离设备的 1024 MiB，布局再次不一致。

## 验收

构建后实测镜像 GPT，必须与设备逐项相同：

- p1 `512/131072`（64 MiB）
- p2 `131584/2097152`（1024 MiB）
- 总扇区 ≤ 2228799

不满足即视为未生效，不发布。

## 后果

- p1 可用空间约 57 MiB，能放下 54.1 MiB 的配置包（历史 56.6 MiB 的包也放得下），
  `platform_copy_config` 走正常路径，不再整盘写。
- 设备上已经跑着 64 MiB 布局的系统，因此这次对齐是「镜像追设备」，不会强制设备改布局。
- 约束：`rootfs_size_mb` 这类会改 p2 的请求（ASU `-S`）仍然会破坏对齐，必须与镜像几何
  一起锁死；分区几何属于兼容性契约，不是可调参数。
