# alioth-ubuntu — Redmi K40 / POCO F3 上的 Ubuntu 26.04 GNOME

把 Redmi K40 / POCO F3（`alioth`，Qualcomm SM8250）刷成
**Ubuntu 26.04 LTS arm64 + 原生 Ubuntu 桌面**（GDM + GNOME）的构建脚本与
实测记录。内核使用 Kupfer 7.2.0（本地重编开启 GPU 温控）。

已实机验证：显示/触控、WiFi（固定 MAC）、蓝牙、音频（扬声器 + 四麦）、
主摄、SSC 传感器、GPU 温控、电源键、充电阈值、2 GiB zram、USB NCM
救援通道。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `alioth-debian/` | 构建脚本、注入文件与文档 |
| `references/` | 从两个参考项目归档的关键文件 |

## 快速开始

见 [alioth-debian/README.md](alioth-debian/README.md)。

## 安全提示

构建出的系统带有默认密码 **`root/root`**、**`user/user`**，并允许 root
SSH 登录。首次启动后请立即执行 `passwd root` 和 `passwd user`，不要在未改
密码的情况下接入不可信网络。

## 致谢

- [Vae555/kupfer-alioth-builds](https://github.com/Vae555/kupfer-alioth-builds)
  — Kupfer 7.2.0 内核、alioth DTS/面板/触摸与音频补丁。
- [nasaarmas/pmaports-alioth](https://github.com/nasaarmas/pmaports-alioth)
  — deviceinfo、ALSA UCM、固件清单与设备规则。

来源、固定提交与许可证见 [CREDITS.md](CREDITS.md)。

## 许可证

本项目原创部分以 **GPL-2.0-only** 发布，见 [LICENSE](LICENSE)。
`references/` 与 `alioth-debian/files/` 中的第三方文件保留各自原许可证，
详见 [CREDITS.md](CREDITS.md)。
