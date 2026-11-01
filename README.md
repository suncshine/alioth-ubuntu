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
| `AGENTS.md` | 决策、约束、当前状态与待办 |
| `alioth-debian/` | 构建脚本、注入文件与文档 |
| `references/` | 从两个参考项目归档的关键文件 |

## 快速开始

见 [alioth-debian/README.md](alioth-debian/README.md) 与
[alioth-debian/BUILD-LOG.md](alioth-debian/BUILD-LOG.md)。

## 致谢

- [Vae555/kupfer-alioth-builds](https://github.com/Vae555/kupfer-alioth-builds)
  — Kupfer 7.2.0 内核、alioth DTS/面板/触摸与音频补丁。
- [nasaarmas/pmaports-alioth](https://github.com/nasaarmas/pmaports-alioth)
  — deviceinfo、ALSA UCM、固件清单与设备规则。

来源、固定提交与许可证见 [CREDITS.md](CREDITS.md)。
