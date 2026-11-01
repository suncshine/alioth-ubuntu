# Credits

本项目使用了以下两个项目的成果，感谢作者。

## [Vae555/kupfer-alioth-builds](https://github.com/Vae555/kupfer-alioth-builds)

- 提交：`14a5dfd`（2026-09-08，Vae555）
- 上游：Kupfer — <https://kupfer.gitlab.io/>
- 使用：7.2.0 预编译内核、alioth DTS/面板/触摸补丁、WCD938x 音频补丁、
  Kupfer 打包配置。
- 许可证：内核补丁 GPL-2.0-only；打包文件沿用各自声明。

## [nasaarmas/pmaports-alioth](https://github.com/nasaarmas/pmaports-alioth)

- 提交：`fef537b`（2026-05-15，Bartek G）
- 上游：postmarketOS — <https://postmarketos.org/>
- 使用：deviceinfo、ALSA UCM、固件清单、传感器/网络规则、内核补丁。
- 许可证：device 包 MIT；内核包 GPL-2.0-only；固件为 proprietary
  （本仓库不含固件二进制）。

## 其他

- 固件来自
  [N1kroks/firmware-xiaomi-alioth](https://github.com/N1kroks/firmware-xiaomi-alioth)
  （提交 `95dfcdf6...`，proprietary，仅构建时下载）。
- `references/` 是上述项目的关键文件副本，校验和见
  [`references/SHA256SUMS`](references/SHA256SUMS)。第三方文件保留原许可证。
