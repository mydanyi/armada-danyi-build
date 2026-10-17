# Armada Danyi 个人版发行说明

本版是 Danyi 个人版 Armada 的正式发行，包含完整安装镜像、OCI 升级包与中文
OpenABL 固件。安装包与升级包均在本仓库 Releases 页面提供；本个人版不经由
Steam/官方渠道分发或被覆盖。

## 本次内容

- 同步官方上游 `2fdf06e`，并合入最新 Wi-Fi 补丁 `1022/1023` 与 PR #712。
- 游戏模式新增升级入口：设置 → 系统 → 操作系统更新渠道 →「单翼版」，
  默认使用本仓库 Release 的 OCI 升级包与元数据。
- 预装 Armada Installer、LSFG-VK ARM64（r16）与 DeckyClash（内置可执行代理核心）。
- 保留 Gamescope 刷新周期重复调度修复与 FIFO 处理、DRM 实际显示帧身份绑定，
  以及此前已验收的 HUD 统计方式。

## 中文 OpenABL 1.0

- 基于 `fed5b5e57d38936bd4ab6e11be986b703fd44187` 构建。
- SM8550 / SM8650 / SM8750 内置已审核的简体中文文案，并补齐所需字库。
- SM8250 的中文构建超出现有构建空间，因此沿用官方 1.1.8。
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
  [`USAGE.md`](https://github.com/mydanyi/armada-danyi-build/blob/main/personal-build/USAGE.md)。

## 验证边界

- SM8750 中文固件已由用户在 Odin3 中验收。
- 其余芯片及本次完整系统镜像尚未完成真机验收。
- 软件自测结果与实际构建结果以构建流程的核验为准。
