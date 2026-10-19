# Armada Danyi 个人版发行说明

本版是 Danyi 个人版 Armada 的正式发行，包含完整安装镜像、OCI 升级包与中文
OpenABL 固件。安装包与升级包均在本仓库 Releases 页面提供；本个人版不经由
Steam/官方渠道分发或被覆盖。

## 本次内容

- 修复首次启动直接进入 Steam 登录页的问题，恢复语言与时区设置向导。
- 修复 Armada Installer 点击“刷新”后无法显示内置磁盘和容量的问题。
- 同步官方上游 `64207e6`（官方 main 源码，2026 年 10 月 19 日同步）；Wi-Fi 补丁
  `1022/1023` 与 PR #712 仍与官方保持一致。
- 合入 PR #751 Plasma 语言修复：界面语言遵循系统/Steam 所选语言，修复桌面中文显示，
  并保留日期与数字格式偏好。
- 游戏模式升级入口：设置 → 系统 → 操作系统更新渠道 →「单翼版」，默认使用本仓库
  Release 的 OCI 升级包与元数据。Steam 客户端保持默认稳定版，与「单翼版」系统更新
  渠道相互独立。
- 预装 Armada Installer 0.2.1、LSFG-VK ARM64（r16）与 DeckyClash 1.3.5（含内置
  可执行代理核心）。插件更新保留用户已更新或修改的副本，仅更新未改动的随镜像副本。
- 内置 Decky 平台在每次手动构建时选取最新预览版，原生 ARM64（当前为 v3.3.0-pre1，
  不是永久固定版本）；已有的较新 Loader 与 `loader.json` 用户选择会被保留。
- 保留 Gamescope 刷新周期重复调度修复与 FIFO 处理、DRM 实际显示帧身份绑定，
  以及既有的 HUD 统计方式。

## 中文 OpenABL 1.0

- 中文 OpenABL 使用新增的 `OpenABL` 目录提供。
- 基于 `fed5b5e57d38936bd4ab6e11be986b703fd44187` 构建。
- SM8550 / SM8650 / SM8750 内置已审核的简体中文文案，并补齐所需字库。
- SM8250 保留官方 1.1.8。
- 源码、固定依赖与许可随系统 `/usr/share/doc/OpenABL` 及本 Release 的
  `source.tar.gz` 提供。

系统升级默认**不会**自动刷写设备的 ABL，升级后已有引导菜单也不会自动变为中文。
本版没有强制降级或刷写新 ABL 的行为。如需中文引导界面，请使用与实际设备/芯片
匹配的固件，并按既有专项刷写流程操作。

## 安装与升级

首次安装：下载**全部** `armada-<版本>.img.gz.7z.001…` 分卷并放在同一目录，
用 7-Zip 打开第一个 `.001`，解出的 `.img.gz` 可直接用 Etcher 等工具刷机，
无需再解压成 `.img`。

已安装用户：OCI 升级包以 `armada-<版本>.oci.tar.partNNN` 分卷提供，由升级脚本
按序下载、逐卷校验并合并。本 Release 同时提供 `SHA256SUMS`、
`oci-image-info.json`、`update.sh` 与 `source.tar.gz`。

固定一键升级命令：

```bash
curl -fsSL -o update.sh https://github.com/mydanyi/armada-danyi-build/releases/latest/download/update.sh && sudo bash update.sh
```

- 旧镜像首次升级：先用上面这条命令升级并手动重启，之后才能在 Steam 设置中看到
  「单翼版」入口；只更新本仓库文件不会改变已安装设备。
- 升级过程持有 `idle:sleep` 抑制锁，覆盖下载、校验、合并与部署；完成后**不会自动
  重启**，请手动重启应用。
- 详细安装、升级与回滚说明见
  [`USAGE.md`](https://github.com/mydanyi/armada-danyi-build/blob/main/personal-build/USAGE.md).
