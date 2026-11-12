# YunWrt

个人自用的 x86_64 OpenWrt 镜像流水线，跟随 `QiuSimons/YAOF` 的 `25.12` 分支，只保留我自己在用的能力。

**这是自用项目，不是产品**：不承诺兼容性，不接泛用需求，不做安全审计。可以自己改，但我不负责别人的机器。

## 构建

需要 Linux x86_64。ImageBuilder 自带的宿主工具是 Linux 二进制，macOS 上请在 amd64 容器里跑。

依赖：`bash git curl rsync zstd unzip gawk gettext libssl-dev python3 jq cpio file bc swig build-essential`。

```bash
./scripts/build.sh
```

依次做接口检查、base 校验、包检查、组装、拉 ImageBuilder、调上游构建。缺包、上游 base 漂移、自有 feed 注入失败都直接失败，不降级。

产物在 `build/artifact/`：

```
YunWrt-x86-64-<上游版本>-<日期>-ext4-combined-efi.img.gz
YunWrt-x86-64-<上游版本>-<日期>-squashfs-combined-efi.img.gz
YunWrt-x86-64-<上游版本>-<日期>-ext4-combined-efi.vhdx.gz
```

前两个是物理机/U 盘可写的原始镜像，也是 PVE、VMware 等平台做转换的底图；`.vhdx.gz` 是 Hyper-V 的动态虚拟磁盘，解压后直接挂到虚拟机上。每个文件旁有对应 `.sha256`；每次构建另写 `build-log/<时间>-<commit>.json`（包清单与版本快照，只做排障线索，不参与门禁）。

能力验收（QEMU 起镜像查 18 项）：

```bash
./scripts/qemu-capability.sh build/artifact/YunWrt-...-ext4-combined-efi.img.gz
```

## 刷机

```bash
gunzip -c YunWrt-x86-64-<...>-ext4-combined-efi.img.gz |
  sudo dd of=/dev/sdX bs=4M status=progress oflag=sync
```

写到整块盘，不是分区；UEFI 启动。默认 LAN `192.168.2.1`，LuCI 在 `http://192.168.2.1/cgi-bin/luci`。

## 发版

手动触发 `.github/workflows/build.yml` 并选 `release` 模式，会建 tag `X86-<上游版本>` 的 Release；`nightly` 模式只上传 Actions artifact。

## 目录

- `upstream/yaof/` 上游纯净镜像，禁止手改
- `overlay/` rootfs 覆盖层、追加包清单、feed 公钥
- `patches/` 必须改行为的运行时文件
- `scripts/` 同步、检查、组装、构建、能力验收

## 文档

`docs/` 下是内部工程记录：迁移方案、能力保全审计、决策记录、能力清单。
