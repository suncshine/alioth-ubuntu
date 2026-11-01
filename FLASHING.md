# 刷机指南 — Redmi K40 / POCO F3（alioth）

本指南把 **Ubuntu 26.04 LTS arm64 + GNOME** 刷入 Redmi K40 / POCO F3。
镜像和构建脚本来自 [suncshine/alioth-ubuntu](https://github.com/suncshine/alioth-ubuntu)。

> **会清空数据。** 刷写会覆盖 `userdata`（Android 的全部用户数据）和 `boot_b`。
> 刷机前请备份照片、聊天记录和 `/boot` 分区；解锁 bootloader 也会清空数据。

## 0. 准备

- 已解锁 bootloader 的 alioth（`fastboot` 可用）。
- 一台 Linux 或 macOS 电脑，安装 `adb`/`fastboot`；脚本还需要 `python3`、
  `dtc`、`fdtput`、`zstd`：
  - macOS：`brew install dtc zstd android-platform-tools`
  - Ubuntu/Debian：`sudo apt install device-tree-compiler zstd python3 android-sdk-platform-tools`
- 从 [Releases](https://github.com/suncshine/alioth-ubuntu/releases) 下载：
  - `alioth-debian.img.gz` — 16 GiB ext4 rootfs（gzip）
  - `boot-production-final.img` — 生产 boot image（**不含** WiFi MAC 和救援公钥）
  - `SHA256SUMS`

```bash
# Linux
sha256sum -c SHA256SUMS
# macOS
shasum -a 256 -c SHA256SUMS
```

本次发布文件的 SHA-256：

```text
ff25f6f89e93451a5221ff289189867aad24bac17978effb2a5d436093958904  alioth-debian.img.gz
f7131234726e446bff28844f8e8d21ff8a1564bd8bf2984c66bdd486db741d53  boot-production-final.img
96c3362110bd7f3b29c1520b41c11b5024d81570d7abe82e10d071d06b9af33a  alioth-debian.img（解压后的 raw，仅用于校验写盘）
```

## 1. 生成救援 SSH key

initramfs 救援通道只接受公钥登录。发布版 boot image **没有内置任何公钥**，
必须把自己的公钥注入后再刷入：

```bash
ssh-keygen -t ed25519 -C alioth-rescue
# 默认生成 ~/.ssh/id_ed25519 和 ~/.ssh/id_ed25519.pub
```

## 2. 读取本机 WiFi MAC（推荐）

QCA6390 没有内置 MAC 时会每次启动随机生成，WiFi 地址和 DHCP 租约都会变。
MAC 在 `persist` 分区的 `wlan_mac.bin` 中，内容形如 `wlan0=112233445566`。

在 Android（需 root）或已有的 Ubuntu 上读取：

```bash
# Android
adb shell su -c 'mount -o ro /dev/block/by-name/persist /mnt/persist && \
  cat /mnt/persist/wlan_mac.bin && umount /mnt/persist'

# 已在 Ubuntu 上
sudo mount -o ro /dev/disk/by-partlabel/persist /mnt/persist
cat /mnt/persist/wlan_mac.bin
sudo umount /mnt/persist
```

把 12 位十六进制转成冒号格式，例如 `wlan0=112233445566` →
`11:22:33:44:55:66`。**不要使用教程里的示例地址**；读不到时可以选一个
本机唯一的本地管理地址（第一字节 bit 1 置位，如 `02:...`）。

```bash
MAC=aa:bb:cc:dd:ee:ff   # 换成你自己的 MAC
```

## 3. 注入 MAC 和救援公钥

在仓库根目录执行（脚本只改本地文件，不刷机）：

```bash
# 1) 注入 WiFi MAC（会保留内核、cmdline 和 initramfs）
./alioth-debian/scripts/09-wifi-mac.sh \
  "$MAC" boot-production-final.img boot-wifi.img

# 2) 注入你的救援公钥
./alioth-debian/scripts/17-inject-rescue-key.sh \
  --boot boot-wifi.img --output boot-flash.img
```

`17-inject-rescue-key.sh` 默认从 `~/.ssh/id_ed25519.pub`、`~/.ssh/id_rsa.pub`
或 `~/.ssh/id_ecdsa.pub` 取公钥；也可以用 `--key` 指定。输出会打印
initramfs 里的公钥路径，例如 `/root-xxxxxxxxxx/.ssh/authorized_keys`。

> 如果只关心系统能不能启动、暂时不用救援 SSH，可以跳过第 2 步的 MAC
> 注入，但第 3 步的公钥注入不能跳过，否则刷完后无法通过 USB 网络执行
> 流式写盘。

## 4. 备份 boot 分区

进入 bootloader：

```bash
adb reboot bootloader     # 或关机后按住 音量下 + 电源
fastboot devices
```

至少备份两个 boot 槽和 dtbo：

```bash
fastboot fetch boot_a boot_a-backup.img
fastboot fetch boot_b boot_b-backup.img
fastboot fetch dtbo_a dtbo_a-backup.img
fastboot fetch dtbo_b dtbo_b-backup.img
```

如果 `fastboot fetch` 不可用，请用 TWRP/root adb 备份对应分区。没有备份
不要继续。

## 5. 刷入 boot_b 并进入 initramfs

以下固定使用 **b 槽**，保留 a 槽原厂 boot 作为 rollback：

```bash
# 清空 userdata，使 initramfs 无法挂载旧系统，停在救援 shell
fastboot erase userdata

# 刷入注入了 MAC 和公钥的 boot image
fastboot flash boot_b boot-flash.img
fastboot erase dtbo_b
fastboot set_active b
fastboot reboot
```

`userdata` 就是后面的 `/dev/sda35`，现在为空；rootfs 会在第 7 步写入。
如果 `fastboot erase userdata` 失败，可以改用 `fastboot -w`，但同样会清空数据。

重启后手机可能停在 initramfs shell（屏幕上有内核日志/`(initramfs)` 提示）。
这是正常的：此时 USB 救援网络和 dropbear 已经启动。

## 6. 配置电脑的 USB 网络

手机在 USB 网络中的地址固定为 `172.16.42.1`，电脑用 `172.16.42.2`。

Linux（把 `usb0` 换成 `ip -br link` 里新出现的 USB 网卡名）：

```bash
ip -br link
sudo ip addr add 172.16.42.2/24 dev usb0
sudo ip link set usb0 up
# 如果 NetworkManager 抢管理权：
# sudo nmcli device set usb0 managed no
```

macOS（把 `enX` 换成 `ifconfig -l` 里新出现的 USB 网卡）：

```bash
ifconfig -l
sudo ifconfig enX inet 172.16.42.2 netmask 255.255.255.0 up
```

测试并登录（把 key 路径换成你的私钥）：

```bash
ping -c 3 172.16.42.1
SSH="ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  root@172.16.42.1"
$SSH
```

看到 `(initramfs)` 提示符即成功。若 `Permission denied (publickey)`，说明
刷入的 boot image 不是注入了公钥的那个，回到第 3 步重新生成并刷 `boot_b`。

## 7. 流式写入 rootfs

**不要用 fastboot 传 1 GB 以上的 rootfs。** 在电脑上执行（保持 SSH 连接）：

```bash
cat alioth-debian.img.gz | $SSH \
  'gunzip -c | dd of=/dev/sda35 bs=4M'
```

写入 16 GiB，通常需要几分钟。完成后校验写盘内容：

```bash
$SSH 'dd if=/dev/sda35 bs=4M count=4096 2>/dev/null | sha256sum'
```

结果应等于：

```text
96c3362110bd7f3b29c1520b41c11b5024d81570d7abe82e10d071d06b9af33a
```

如果 initramfs 里没有 `sha256sum`，跳过这步；至少确认 `dd` 正常退出、没有
`No space left` / `I/O error`。然后：

```bash
$SSH 'sync; reboot -f'
```

手机会用 boot_b 的生产镜像重新启动，第一次启动约 1–2 分钟，随后自动登录
GNOME 桌面。

## 8. 首次启动后

默认账号：

| 用户 | 密码 |
|---|---|
| `root` | `root` |
| `user` | `user` |

**立即修改**，并且不要在改密码前接入不可信网络（root SSH 默认开启）：

```bash
passwd root
passwd user
```

把 16 GiB 文件系统扩展到整个 `userdata` 分区：

```bash
sudo resize2fs /dev/sda35
df -h /
```

其他检查：

```bash
nmcli device status          # WiFi 是否出现，MAC 是否固定
zramctl                      # 2 GiB zstd zram swap
speaker-test -c 2 -t sine    # 扬声器
monitor-sensor               # 加速度/光感/罗盘
```

Firefox 不在 rootfs 内（arm64 无 deb、Snap 不可用），联网后运行：

```bash
sudo /usr/local/lib/alioth/11-desktop-apps.sh --refresh-firefox
```

## 9. 回滚

只回滚 boot（保留 Ubuntu rootfs 数据）：

```bash
fastboot flash boot_b boot_b-backup.img
fastboot flash dtbo_b dtbo_b-backup.img
fastboot set_active b
fastboot reboot
```

要回到 Android，还需要用官方 fastboot 包恢复 `userdata`；只恢复 boot 分区
不会恢复 Android 数据。`boot_a` 未被本指南改动，但它的 `userdata` 已被
Ubuntu 覆盖。

## 安全与隐私

- 发布版 boot image **不含** WiFi MAC 和个人 SSH 公钥；蓝牙地址是固定
  占位值，不是本机原厂地址。你自己注入后的 `boot-flash.img` 含你的 MAC
  和公钥，不要上传或分享。
- 蓝牙地址在通用镜像中是占位值 `02:12:34:56:78:9A`；基本功能可用，但
  多台设备会相同。需要唯一地址可用
  `alioth-debian/scripts/06-bt-bdaddr.sh` 重新注入。
- rootfs 第一次启动会生成自己的 SSH host key 和 machine-id；不同设备不会
  共用。
- 默认密码和 root SSH 是为了首次调试方便，不是长期配置。改密码后建议
  关闭 root 密码登录：编辑 `/etc/ssh/sshd_config.d/10-alioth-rescue.conf`
  或删除该文件，然后 `sudo systemctl restart ssh`。

## 从源码构建

构建流程、依赖和可复现性说明见
[alioth-debian/README.md](alioth-debian/README.md)。在 `alioth-debian/`
目录下执行，发布镜像使用：

```bash
./scripts/02-rootfs.sh --no-rescue-key
./scripts/03-initramfs.sh
./scripts/15-rootfs-image.sh --recreate --sparse --gzip --fsck
KSRC=/root/kernel-build/linux \
KERNEL_IMG=/root/kernel-build/linux/arch/arm64/boot/Image.gz \
INITRD_IMG=out/initrd.img \
OUT_IMG=out/boot-production-final.img \
  ./scripts/16-production-boot-source.sh
```

`16-production-boot-source.sh` 在不设置 `WIFI_MAC` 时会生成不含
`local-mac-address` 的通用镜像，正是本指南第 3 步要再注入 MAC 的输入。
