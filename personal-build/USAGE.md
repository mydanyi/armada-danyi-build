# Armada Danyi 个人版 · 安装与升级说明（USAGE）

本仓库（`mydanyi/armada-danyi-build`）发布 Danyi 的个人版 Armada 镜像与升级包，
统一放在 [Releases](https://github.com/mydanyi/armada-danyi-build/releases) 页面。
个人版**不自动回退到官方渠道**：默认通过本仓库 Release 的 OCI 升级包升级，只有在
Steam 的“操作系统更新渠道”里**显式选择**官方渠道（rel/beta/preview）时，才会切回
官方系统层。

每个 Release 同时提供两类产物，并以分卷分发（安装包为 `.img.gz.7z.NNN`，OCI 升级包为
`.partNNN`），以避免单个整包过大。

## 一、安装包分卷与 OCI 升级分卷的区别

| 用途 | 完整包 | 分卷命名 | 使用者 |
| --- | --- | --- | --- |
| 首次安装（刷机） | `armada-<版本>.img.gz`（由 7z 分卷解出） | `armada-<版本>.img.gz.7z.001…` | 尚未安装的新设备 |
| 已装机升级（OTA） | `armada-<版本>.oci.tar` | `armada-<版本>.oci.tar.part000…` | 已安装本个人版的设备 |

- **安装包分卷**：刷机镜像 `armada-<版本>.img.gz` 原样封装为多卷 7z，命名为
  `armada-<版本>.img.gz.7z.001`、`.002`……。请把**全部分卷放在同一目录**，用 7-Zip
  等支持 7z 分卷的工具打开**第一个** `.img.gz.7z.001`，工具会自动读取其余分卷并解出
  完整的 `.img.gz` 刷机镜像。
- **OCI 升级分卷**：把完整升级包 `armada-<版本>.oci.tar` 切成若干 `.partNNN`。
  升级脚本会按编号顺序下载、逐个校验，再合并回完整 OCI 后交给系统。
- 当前版本规模：安装包分卷解出约 7.14 GiB 的 `.img.gz`、OCI 约 6.95 GiB，
  二者各约 4 个分卷。

> 分卷（安装包 `.img.gz.7z.NNN` 与 OCI `.partNNN`）只在 GitHub Release 上分发；
> 完整 `.img.gz`、`.oci.tar` 及小型校验元数据另行留存副本，因此同一个整包不会被
> 重复传输。

## 二、完整性校验（SHA256SUMS）

每个 Release 都带有一份 `SHA256SUMS`，其中列出**完整 `.img.gz`/`.oci.tar`** 与
**每一个分卷**的 SHA256。清单中**不含**未压缩的 `raw.img`——安装包分卷解出的就是
`.img.gz` 本身。请在使用前校验，升级脚本也会自动逐卷校验。

## 三、首次安装（刷机）

1. 从 [Releases](https://github.com/mydanyi/armada-danyi-build/releases) 下载**全部**
   `armada-<版本>.img.gz.7z.001`、`.002`…… 分卷，并放在**同一个目录**下。
2. 用 7-Zip（或其他支持 7z 分卷的工具）打开**第一个** `armada-<版本>.img.gz.7z.001`，
   工具会自动读取同目录下的其余分卷，解出完整的 `.img.gz` 刷机镜像。
3. 直接用 [Etcher](https://etcher.balena.io/) 等工具选择解出的 `.img.gz` 刷机即可，
   **无需**再解压成 `.img`；也可按**官方安装文档**刷机：
   <https://armadaos.dev/getting-started/flashing-to-an-sd-card/>

请勿只下载部分分卷，也请勿单独使用 `.001` 之外的分卷；务必让工具从 `.001` 开始
自动解出完整 `.img.gz` 后再刷机。

## 四、已安装用户升级（一条命令）

> **下一次发行镜像起，也可以在 Steam 游戏模式里升级**：设置 → 系统 →
> **「操作系统更新渠道」→ 选择「单翼版」→「检查更新」→「应用」→ 手动重启**。
> **「单翼版」是本个人版的默认渠道**，它继续使用本仓库 Release 的 OCI 升级包与
> 元数据，**不是** Steam 客户端的更新渠道。
>
> - **旧镜像需要先执行本节这一条命令升级并重启**，重启装入新入口后才能在 Steam 内
>   看到「单翼版」；**只更新本仓库的 GitHub 文件不会改变已安装设备**。
> - Steam 会过滤“高级更新渠道”：当前选中「单翼版」时可以正常显示；若你已切到其他
>   渠道，可能需要在 Steam 设置里开启**「显示高级更新渠道」**才能重新看到它。
> - 选择官方渠道会**切回官方系统层**，个人预装/定制**不保证保留**；回到官方镜像后，
>   可以再用下面这一条命令切回个人版。
> - **当前 Release 尚未包含上述新功能与元数据**，这些新功能要等统一发行后才生效。

在设备的任意当前目录执行：

```bash
curl -fsSL -o update.sh \
  https://github.com/mydanyi/armada-danyi-build/releases/latest/download/update.sh \
  && sudo bash update.sh
```

该地址固定指向最新 Release 的 `update.sh`：

```
https://github.com/mydanyi/armada-danyi-build/releases/latest/download/update.sh
```

**已经安装官方 ARM Armada bootc 系统的设备**也可以使用本脚本切换到本个人版镜像；
切换之后，后续的个人版更新继续使用本脚本，或直接执行随镜像提供的
`armada-danyi-update`（效果等价）：

```bash
sudo armada-danyi-update
```

两种方式都会：查询最新 Release → 下载并**逐卷校验** → 合并并校验完整 OCI →
**只有校验通过才阶段化**到系统（`bootc switch --transport oci-archive`）。任何
下载失败、缺卷或哈希不符都会中止，且不会改动系统。

### 升级过程与电源保护

- 升级脚本在真正开始下载前，通过 `systemd-inhibit --what=idle:sleep --mode=block`
  申请系统电源抑制锁（`idle:sleep` 阻塞锁由 KDE PowerDevil 等识别），整个
  **下载 / 逐卷校验 / 合并 / 部署**流程都在锁保护下进行，避免升级途中设备休眠或空闲。
- 锁只在脚本运行时持有：流程正常结束、失败或用户中断（Ctrl-C / 终止）都会自动释放，
  **不会修改你的任何电源设置**，也不会安装后台服务或常驻进程。
- 本次实现的是系统级 `idle:sleep` 锁；**Steam 游戏模式下的实际屏幕保持仍需在真实图形
  会话中复测验收**，本说明不代表已验证。

> **关于旧镜像内置的 `armada-danyi-update`**：它随镜像内置，**不会**因为只更新 Release
> 附件而自动改变。因此即便你已经下载了本仓库最新的 Release，设备上原有的
> `armada-danyi-update` 仍是旧版本。要获得本电源保护修复，请**重新下载本仓库最新的
> `update.sh`** 并以 `sudo bash update.sh` 运行；未来新构建的镜像才会内置新版
> `armada-danyi-update`。

## 五、重启与回滚

- 阶段化完成后**不会自动重启**，请自行**手动重启**以应用升级。
- 升级会保留 `/var` 与 `/etc` 的用户状态（游戏与存档等通常不受影响），但本版不保证
  所有用户配置均保持不变。
- 需要回退时：执行 `sudo bootc rollback`，然后**手动重启**。

## 六、本版要点与已知限制

- 合并上游 PR #594、#608、#609、#651 与 #665 的相关改动。
- **待下次构建**：源码已撤销 PR #712，恢复 KONKR 手柄 MCU 原有的休眠与唤醒流程；现有 Release 镜像尚未包含此次回退。
- 刷新周期重复调度修复（Gamescope #2417）、改进 FIFO 处理、DRM 实际显示帧身份绑定，
  并保留此前恢复并验收的 HUD 曲线统计方式。
- 预装个人版 Decky 插件 Armada Installer、LSFG-VK ARM64（r16）与 DeckyClash（内置可执行代理核心）。
- **已知限制**：组合后的新镜像**尚未在真机验收**；本说明不代表所有游戏均已修复。
- 本个人版**不自动回退官方**；仅在系统更新渠道里**显式选择**官方渠道时才会切回官方
  系统层。
