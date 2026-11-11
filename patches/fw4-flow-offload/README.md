# fw4-flow-offload

## 为什么需要

`fw4.uc` 在收集 flow offload 设备时只取 `net.physdev`：

```
if (net.physdev && !e.invert)
    push(related_physdevs, net.physdev);
```

`physdev` 只在 L2 设备（如 PPPoE 的底层网口）上才有值。x86 虚拟机用的是 virtio/vmxnet3 这类 L3 接口，`physdev` 为空，`resolve_offload_devices()` 拿到的设备集是空的，生成的 `flowtable` 不会包含 `eth0`/`eth1`，软件 offload 实际不生效。

## 改什么

```
- if (net.physdev && !e.invert)
-     push(related_physdevs, net.physdev);
+ if (!e.invert)
+     push(related_physdevs, net.physdev || net.device);
```

一行回退：有 `physdev` 仍用 `physdev`，没有就用 `net.device`。`related_physdevs` 只被 offload 设备解析使用（`resolve_hw_offload_devices` / `resolve_offload_devices`），不影响其他规则生成。

## 基线

- 包：`firewall4`（openwrt v25.12.6 对应源码提交 `b6e5157`）
- 原文件 sha256：`148ded17db6a8984e97875c8e60ed7e4ab4c475fbd84a31bba6b543190b4e524`
- 以 `base/usr/share/ucode/fw4.uc` 提交在仓库内，`apply.sh` 先校验哈希再打补丁。

## 失效怎么发现

- 内置基线被改动：`apply.sh` 直接失败。
- 上游改了 `fw4.uc`：`scripts/check-patch-bases.sh <version>` 从 `openwrt/firewall4` 取本次 release 对应的源文件，哈希不一致即失败，必须人工复核后更新 base 与补丁。
- 打完后 `grep 'net.physdev || net.device'` 不命中：`apply.sh` 失败。
