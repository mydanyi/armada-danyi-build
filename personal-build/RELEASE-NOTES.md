# Armada Danyi 个人版更新说明

本次为 Danyi 的个人版 Armada 镜像与升级包发布。安装包与 OCI 升级包均在本仓库
的 Releases 页面提供；本个人版不经由 Steam/官方渠道分发或被覆盖。

## 本次改动要点

- 合并上游 PR #594、#608、#609、#651、#665 与 #712 的相关改动。
- 刷新周期重复调度修复（Gamescope #2417），并改进 FIFO 处理。
- DRM 实际显示帧身份绑定。
- 保留此前恢复并验收的 HUD 曲线统计方式。

## 预装内容

- 安装个人版 Decky 插件 Armada Installer。
- LSFG-VK ARM64（r16）。
- DeckyClash（内置可执行代理核心）。

## 使用方式

- 首次安装：下载全部 `armada-<版本>.img.gz.7z.001…` 分卷并放在同一目录，用 7-Zip 等
  支持 7z 分卷的工具打开第一个 `.001`，自动解出完整 `.img.gz`；用 Etcher 等工具直接
  选择该 `.img.gz` 刷机即可（无需再解压成 `.img`），详见
  [`USAGE.md`](https://github.com/mydanyi/armada-danyi-build/blob/main/personal-build/USAGE.md)。
- 已安装用户：下载 `update.sh` 后运行 `sudo bash update.sh`，或直接执行
  `sudo armada-danyi-update`；校验通过后由用户手动重启完成升级。已经安装官方
  ARM Armada bootc 系统的设备也可以改用本脚本切换到本个人版，之后的个人版更新
  继续使用本脚本或 `armada-danyi-update`。

## 说明

- 本次仅调整安装包分发格式：`.img.gz` 原样封装为多卷 7z（不再解压成巨大 raw 镜像）；
  镜像内容不变。
- 本个人版不会经由 Steam 官方渠道被覆盖。
- 组合后的新镜像尚未在真机验收；本次说明不代表所有游戏均已修复。
