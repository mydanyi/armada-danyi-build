# Armada Danyi 个人版 · 安装与升级说明（USAGE）

本仓库（`mydanyi/armada-danyi-build`）发布 Danyi 的个人版 Armada 镜像与升级包，
统一放在 [Releases](https://github.com/mydanyi/armada-danyi-build/releases) 页面。
个人版**不自动回退到官方渠道**：默认通过本仓库 Release 的 OCI 升级包升级，只有在
Steam 的“操作系统更新渠道”里**显式选择**官方渠道（rel/beta/preview）时，才会切回
官方系统层。

每个 Release 同时提供两类产物，并以分卷分发（安装包为 `.img.gz.7z.001…`，OCI 升级包为
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
- 具体文件大小与分卷数量以该 Release 页面列出的附件为准。

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

> **本版已包含 Steam 游戏模式内的升级入口**：设置 → 系统 →
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
> `update.sh`** 并以 `sudo bash update.sh` 运行；本版新构建的镜像已内置新版
> `armada-danyi-update`。

## 五、重启与回滚

- 阶段化完成后**不会自动重启**，请自行**手动重启**以应用升级。
- 升级会保留 `/var` 与 `/etc` 的用户状态（游戏与存档等通常不受影响），但本版不保证
  所有用户配置均保持不变。
- 需要回退时：执行 `sudo bootc rollback`，然后**手动重启**。

## 六、本版要点与已知限制

- 本版已同步官方上游 `64207e6`（官方 main 源码，2026 年 10 月 19 日同步），Wi-Fi 补丁
  `1022/1023` 与 PR #712 均采用官方版本，并合入 PR #751 Plasma 语言修复：界面语言遵循
  系统/Steam 所选语言，修复桌面中文显示，保留日期与数字格式偏好；同时包含 PR #594、
  #608、#609、#651、#665 的相关改动。
- 游戏模式升级入口：设置 → 系统 → 操作系统更新渠道 →「单翼版」，默认使用本仓库
  Release 的 OCI 升级包；旧镜像需先按上一节命令升级并重启才能看到该入口。Steam 客户端
  保持默认稳定版，与「单翼版」系统更新渠道相互独立。
- 刷新周期重复调度修复（Gamescope #2417）、改进 FIFO 处理、DRM 实际显示帧身份绑定，
  并保留既有的 HUD 曲线统计方式。
- 预装个人版 Decky 插件 Armada Installer 0.2.1、LSFG-VK ARM64（r16）与 DeckyClash
  1.3.5（含内置可执行代理核心）。插件更新保留用户已更新或修改的副本，仅更新未改动的
  随镜像副本。
- 内置 Decky 平台在每次手动构建时选取最新预览版，原生 ARM64（当前为 v3.3.0-pre1，
  不是永久固定版本）；已有设备保留较新的 Loader 与 `loader.json` 用户选择。
- **已知限制**：并非所有游戏均已修复，兼容性以实际设备与游戏表现为准。
- 本个人版**不自动回退官方**；仅在系统更新渠道里**显式选择**官方渠道时才会切回官方
  系统层。

### 中文 OpenABL

- 四个芯片（SM8250 / SM8550 / SM8650 / SM8750）统一使用 OpenABL 1.1 的中英双语
  变体：没有保存过语言设置时，引导菜单默认简体中文；已在菜单里显式选择 English 的
  设备保持英文，两种语言仍可随时切换。
- 系统升级会在关机时按 OpenABL 上游的更新逻辑自动检查并写入设备 ABL，默认开启、
  无需额外操作：可识别的旧版 ROCKNIX/OpenABL 会被替换；版本高于目标的、同版本但
  字节不同的自定义构建，以及无法识别的镜像会被拒绝，不会改动现有引导。
- 更新在下次关机时执行；要让新的引导界面生效，请按提示关机后重新开机。
- 刷写工具位于 SD 卡的 `OpenABL/` 目录（按芯片分目录，内含备份与刷写脚本）。完整
  对应源码与补丁随系统安装在 `/usr/share/doc/OpenABL`（`openabl-v1.1-source.tar.xz`
  与 `default-zh.patch`）；许可与构建说明见 `OpenABL-notices`。

## 七、预装插件与每日发行同步

- 随镜像预装三个独立的 Decky 插件：Armada Installer 0.2.1、LSFG-VK ARM64（r16）与
  DeckyClash 1.3.5（含内置可执行代理核心）。
  三者的版本、下载地址与 SHA256 记录在 `personal-build/plugins.lock.json`；私有
  LSFG 的原始 ZIP 同时保存在 `personal-build/plugin-assets/`，供镜像内置。
- 每日上游同步（服务器定时器与手动 GitHub workflow 共用
  `personal-build/sync-upstream.sh`）在合并上游后调用
  `personal-build/sync-plugins.py`：只查询这三个插件的 GitHub Releases 最新正式版，
  下载 ARM64 资产并边下载边校验 SHA256，再核对 ZIP 内该插件目录下的
  `plugin.json`、`main.py`、`dist/index.js`。**整批校验通过后**才原子替换锁文件与
  私有包；任一条目哈希或包结构不符都会整批放弃、返回失败，同步不会推送。
  草稿或预发布版本一律不采用，已锁定版本不会被降级。
- 只有这三个独立插件随发行包更新；其余随上游源码构建的插件仍跟随上游源码，不在
  该锁文件中。插件更新**不会**触发镜像构建：个人版镜像仍只手动构建和发布。
- 私有仓库（LSFG-VK ARM64）需要只读凭据，按以下顺序取第一个可用的：
  环境变量 `ARMADA_PLUGIN_TOKEN_FILE` 指向的 token 文件；执行环境提供的
  `credentials/plugin-release-read-token`（相对 `ARMADA_EXECUTION_BASE`）；环境变量
  `GH_TOKEN` / `GITHUB_TOKEN`。GitHub Actions 中对应只读 secret 名为
  `PLUGIN_RELEASE_READ_TOKEN`。该凭据只需要私有仓库 Release 的只读 Contents 权限，
  只用于读取发行资产，不会写入锁文件、下载地址或日志。**缺少凭据时只跳过私有
  LSFG 并标记为 skipped**，公开插件照常更新；跳过的条目保持原锁定版本，不会被
  当成“已是最新”。
- 插件目录在开机播种时的处理：保留用户在设备上较新或已修改的副本；由镜像管理的
  副本可随系统更新替换；无法判定归属的同版本旧目录保持原样，不做清理。已有的用户
  配置与其他文档不受影响。

### Decky 平台

镜像内置的 Decky Loader 平台与上述三个插件 ZIP 相互独立：每次**手动**构建镜像时，
从 Decky Loader 的 GitHub Release 列表中获取**最新预览版**（非草稿的 prerelease，
按 `published_at` 取最新，当前为 v3.3.0-pre1）的原生 ARM64 `PluginLoader-arm64`，
校验 Release 记录的版本、资产 SHA256 与 ELF 目标架构后才写入镜像；没有可用预览版时
构建失败，不会回退到正式版。设备开机时由 `armada-decky-sync` 播种该 Loader；全新
安装默认使用预览版，已有设备保留自身的 `loader.json` 记录与更高版本，已安装的较新
正式版（如 v3.3.0）不会被强制降级。镜像与升级包仍需**手动**构建和发布，本说明不
改变现有设备的更新渠道，也不改动 Steam 的稳定版设置。
