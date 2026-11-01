# alioth-debian

Redmi K40 / POCO F3（`alioth`，SM8250）上的 **Ubuntu 26.04 LTS arm64 +
原生 Ubuntu 桌面**（GDM 自动登录 → `gnome-session --session=ubuntu`）。
内核为 Kupfer 7.2.0（本地重建开启 `CONFIG_DEVFREQ_THERMAL`），Phosh 已移除。

当前实机可用：显示/触控、WiFi（固定 MAC）、蓝牙、音频（扬声器 + 四路麦）、
IMX582 主摄 + DW9800 手动对焦、SSC 传感器（加速度/光感/罗盘）、GPU 温控、
电源键、充电阈值、2 GiB zstd zram swap（无磁盘 swap）、USB NCM/OTG 救援
通道。

## 脚本与执行位置

| 脚本 | 在哪跑 | 作用 |
|---|---|---|
| `scripts/01-kernel.sh` | macOS 或 Linux | 解包 Kupfer 预编译内核包 → `out/kernel/` |
| `scripts/02-rootfs.sh` | **arm64 Linux**（VM 或手机） | mmdebstrap 建 Ubuntu 26.04 GNOME rootfs，注入固件/UCM/相机/传感器/桌面层 |
| `scripts/03-initramfs.sh` | **arm64 Linux** | chroot 生成 initramfs |
| `scripts/15-rootfs-image.sh` | **arm64 Linux** | `mke2fs -d` 生成 16 GiB ext4 镜像（可选 sparse/gzip），无需 loop mount |
| `scripts/04-bootimg.sh` | macOS 或 Linux | 从 `out/kernel` 打基底/debug boot image（`KERNEL_IMG`/`DTB_IMG` 可覆盖） |
| `scripts/06-bt-bdaddr.sh` | macOS/Linux | DTB 注入蓝牙 `local-bd-address`（历史流程；源 DTS 已含） |
| `scripts/09-wifi-mac.sh` | macOS/Linux | DTB 注入 WiFi `local-mac-address`（MAC 从 persist 读取，不写进仓库） |
| `scripts/13-camera-dtb.sh` | macOS/Linux | 删除无驱动的 CAMSS port@0/2/4，保留 IMX582 |
| `scripts/10-splash-mem.sh` | macOS/Linux | 保留 ABL 开机 Logo 帧缓冲（幂等；源 DTS 已含节点） |
| `scripts/14-production-boot.sh` | macOS/Linux | 从 audio 基底重放 BT/WiFi/相机/splash，逐字节复现生产 boot image |
| `scripts/16-production-boot-source.sh` | macOS/Linux | 从 tracked DTS + thermal Image.gz + initrd 重新构建生产 boot image；不设 `WIFI_MAC` 时生成通用镜像 |
| `scripts/17-inject-rescue-key.sh` | macOS/Linux | 把救援 SSH 公钥注入 boot image 的 initramfs |
| `tools/inject-initramfs-key.py` | 任意 | `17-inject-rescue-key.sh` 的底层实现 |
| `scripts/13-camera-modules.sh` | 手机或 `--root` | 编译/安装 imx582+dw9800（固定 build dir，优先 gcc-16） |
| `scripts/20-sensors-ssc.sh` | 手机或 `--root` | 安装 libssc + SSC 版 iio-sensor-proxy + drop-in/udev |
| `scripts/10-daemons.sh` | VM | 编译 qbootctl（`--build-daemons` 时） |
| `scripts/11-desktop-apps.sh` | 手机（root） | 安装桌面应用；Firefox 用 Mozilla arm64 tarball（snap 不可用） |
| `scripts/12-desktop-settings.sh` | 手机（root） | 同步 dconf 系统默认值到当前用户 |
| `tools/bootimg.py` | 任意 | Android boot image 解包/打包（已对参考镜像做字节级验证） |

## 快速流程

### A. 生产 boot image（无需重编内核）

精确复现历史 boot image（同一 MAC 时与历史产物逐字节一致）：

```bash
WIFI_MAC=xx:xx:xx:xx:xx:xx      # 从 persist /dev/sda22 的 wlan_mac.bin 读取
./scripts/14-production-boot.sh \
  --base out/boot-production-audio.img \
  --wifi-mac "$WIFI_MAC" \
  --output out/boot-production-final.img
```

从源码重建（tracked DTS + thermal 内核 + initrd）：

```bash
KSRC=/root/kernel-build/linux \
KERNEL_IMG=/root/kernel-build/linux/arch/arm64/boot/Image.gz \
./scripts/16-production-boot-source.sh
# 产物 out/boot-production-final.img；DTB 顺序与历史镜像不同，功能等价
# 不设置 WIFI_MAC 时生成不含 local-mac-address 的通用镜像
```

内核 artifact 的来源、哈希和配置见 `files/kernel/README.md`。

### B. 生产 rootfs image

```bash
# arm64 Linux 构建机；手机自身也可（需 mmdebstrap、gcc-16、dtc、depmod）
# 发布镜像用 --no-rescue-key，避免把构建机的 SSH 公钥带进镜像；
# 需要刷机救援通道时，之后用 17-inject-rescue-key.sh 注入到 boot image。
./scripts/02-rootfs.sh --no-rescue-key   # 约 20-40 min（首次下载 ~1-2 GB）
./scripts/03-initramfs.sh
./scripts/15-rootfs-image.sh --recreate --sparse --gzip
# 产物 out/alioth-debian.img、out/alioth-debian-sparse.img、out/initrd.img
```

`03-initramfs.sh` 通过 `files/initramfs-hook-remoteproc-fw` 把 adsp/slpi/cdsp
固件（`.mbn` + `.jsn`）放进 initrd 并校验。**必须保留这一步**：
`MODULES=most` 会把 `qcom_q6v5_pas.ko` 带进 initrd，缺少固件时 DSP probe
会永久失败，导致无声卡、传感器/hexagonrpcd 全挂。

手机侧构建时，`02-rootfs.sh` 会从运行中的 `/lib/modules/7.2.0`、
`/lib/firmware`、`/usr/share/qcom` 复制内核模块和固件，并从 host 复制
qbootctl；无需 `downloads/` 与 VM。`--build-daemons` 可在干净 VM 上从源码
构建 qbootctl。

### C. 刷机

完整步骤见 [`../FLASHING.md`](../FLASHING.md)：下载发布镜像、注入 WiFi MAC
和救援公钥、备份分区、刷 `boot_b`，再通过 initramfs USB 网络流式写入
`/dev/sda35`。

## 已核实的关键事实

- boot image：header v0、pagesize 4096、kernel_addr 0x8000、ramdisk_addr
  0x1000000、tags 0x100、second_addr=0；内核 blob = `Image.gz` + DTB 拼接。
- 生产 cmdline 含 `ip=172.16.42.1::172.16.42.2:...::usb0:off`，initramfs
  的 dropbear/救援网络因此无需等待 rootfs。
- rootfs 分区 `/dev/sda35`；ext4 4096 字节块；发布镜像的 SHA-256 见
  [`../FLASHING.md`](../FLASHING.md)。
- 发布 rootfs 含 2 GiB zstd zram，系统没有磁盘 swap（无 swap 分区、
  swapfile 或 fstab 条目）。
- 救援通道：USB NCM（`usb-gadget.service`，手机 172.16.42.1）；OTG 角色
  自动切换由 DTB 的 `dr_mode="otg"` + `80-alioth-usb-gadget.rules` 负责。

## 已知未完成

- RTC 硬件只读（靠 timesyncd 时间戳跨重启恢复）；蓝牙 PAN/HFP 缺
  `bnep`/`rfcomm`；Modem/GPS（外置 SDX55m + ESOC）未 bring-up；
  NFC 缺 userspace；指纹/振动无驱动；默认密码未改。
- 相机：仅主摄；AF 守护进程未常驻（手动 `focus_absolute`）；1080p
  ABGR8888 受 32 MB CMA 限制；前摄/超广角/微距未启用。
- Firefox 不在 rootfs 内（无 arm64 deb，snap 不可用）：首次启动后运行
  `sudo /usr/local/lib/alioth/11-desktop-apps.sh --refresh-firefox`。
