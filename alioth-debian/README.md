# alioth-debian

Redmi K40 / POCO F3 (alioth) 上的 Debian trixie + Phosh。
背景与总体方案见上级目录 `../PLAN.md`。

## 脚本与执行位置

| 脚本 | 在哪跑 | 作用 |
|---|---|---|
| `scripts/01-kernel.sh` | macOS 或 VM | 解包 Kupfer 预编译内核包 → `out/kernel/` |
| `scripts/02-rootfs.sh` | **VM** | mmdebstrap 建 trixie rootfs + 注入固件/UCM/udev/守护进程 |
| `scripts/03-initramfs.sh` | **VM** | chroot 生成 initramfs |
| `scripts/04-bootimg.sh` | **VM** | 打 ext4 rootfs 镜像 + boot.img（header v0）+ sparse |
| `scripts/05-flash.sh` | **macOS** | fastboot 刷入（erase dtbo_b → boot_b → userdata → set_active b） |
| `scripts/06-bt-bdaddr.sh` | macOS 或 VM | 给 boot.img 内追加的 DTB 注入蓝牙 `local-bd-address`（不重编内核） |
| `scripts/10-daemons.sh` | **VM**（02 自动调用） | 编译 qbootctl（必需）+ 可选高通守护进程 |
| `tools/bootimg.py` | 任意 | Android boot image 解包/打包；已对 Kupfer 参考镜像做字节级验证 |

## 快速流程

```bash
# macOS 侧准备（仅一次）
bash scripts/01-kernel.sh           # 解包内核（macOS 就能跑）

# VM 侧（arm64 Ubuntu 24.04, OrbStack: orb -m build）
bash scripts/00-vm-setup.sh         # 装依赖（仅一次）
bash scripts/02-rootfs.sh           # ~20-40 min
bash scripts/03-initramfs.sh
bash scripts/04-bootimg.sh

# macOS 侧刷机
bash scripts/05-flash.sh
```

构建状态与下次开工清单见 [BUILD-LOG.md](BUILD-LOG.md)。

## 已核实的关键事实

- boot image：**header v0**、pagesize 4096、kernel_addr 0x8000、ramdisk_addr
  0x1000000、tags_addr 0x100、**second_addr = 0**（deviceinfo 里的 0xf00000
  实际未使用）；内核 blob = `Image.gz` + DTB 直接拼接
- 参考镜像 cmdline 用 `kupfer earlymodules=...` 交给自带 initramfs 找根分区；
  我们改用 `root=/dev/sda35 rootwait rw`（Debian initramfs 常规路径）
- rootfs 分区 `/dev/sda35`（Kupfer deviceinfo）；UFS 4K 扇区 → mkfs -b 4096
- 内核 UFS/ext4/devtmpfs 全部内置（=y）→ initramfs 只承担挂载前流程
- 救援通道：USB NCM（`usb-gadget.service`，手机 172.16.42.1）；
  终极手段 UART（pmaports README 第 5 节）

## 首次启动后

```bash
# Mac 侧
sudo ifconfig en<X> inet 172.16.42.2 netmask 255.255.255.0 up
ssh root@172.16.42.1          # root/root 或 user/user，刷完立即改
dmesg | grep -iE "alioth|panel|ft8756|ath11k|ufs"   # 检查固件加载与硬件识别
```

WiFi 型号以 `dmesg | grep ath11k` 实测为准（预期 QCA6390，固件在
`firmware-atheros` 内）；GPU 加速依赖 `qcom/a650_sqe.fw`、`a650_gmu.bin`
（来自 `firmware-qcom-soc`）+ 设备专用 `a650_zap.mbn`（已注入）。

## 已知未完成

- `10-daemons.sh` 只保证 qbootctl；rmtfs/pd-mapper/tqftpserv/hexagonrpcd/
  bootmac 首次运行后按实际构建系统补 systemd unit（参考 Kupfer
  `etc/kupfer/systemd/*.lst`）
- 音频（扬声器/听筒）、调制解调器属第二梯队，见 PLAN.md 第 9 节
