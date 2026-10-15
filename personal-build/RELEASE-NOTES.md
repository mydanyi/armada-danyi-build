# Armada Danyi 个人版更新说明

本次为 Danyi 的个人版 Armada 镜像与升级包发布。安装包与 OCI 升级包均在本仓库
的 Releases 页面提供；本个人版不经由 Steam/官方渠道分发或被覆盖。

## 本次改动要点

- 合并上游 PR #594、#608、#609、#651 与 #665 的相关改动。
- **待下次构建**：源码已撤销 PR #712，恢复 KONKR 手柄 MCU 原有的休眠与唤醒流程；现有 Release 镜像尚未包含此次回退。
- 刷新周期重复调度修复（Gamescope #2417），并改进 FIFO 处理。
- DRM 实际显示帧身份绑定。
- 保留此前恢复并验收的 HUD 曲线统计方式。
- 升级脚本 `update.sh` 新增电源保护：下载 / 逐卷校验 / 合并 / 部署全程持有
  `systemd-inhibit` 的 `idle:sleep` 阻塞锁。

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
- **电源保护与内置脚本更新**：本次为 `update.sh` 引入系统电源抑制锁
  （`systemd-inhibit --what=idle:sleep --mode=block`，KDE PowerDevil 等识别），
  下载 / 逐卷校验 / 合并 / 部署全程持锁，流程结束、失败或中断时自动释放，且不改动
  用户的电源设置。旧镜像内置的 `armada-danyi-update` **不会**因仅更新 Release 附件而
  改变，需**重新下载最新 `update.sh`** 运行才能获得该修复；未来新构建的镜像会内置新版。
- 本次实现的是系统 `idle:sleep` 锁；Steam 游戏模式下的实际屏幕保持仍需在真实图形会话
  中复测验收。
- 本个人版不会经由 Steam 官方渠道被覆盖。
- 组合后的新镜像尚未在真机验收；本次说明不代表所有游戏均已修复。
