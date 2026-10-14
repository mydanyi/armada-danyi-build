# Armada Danyi 个人版 · 安装与升级说明（USAGE）

本仓库（`mydanyi/armada-danyi-build`）发布 Danyi 的个人版 Armada 镜像与升级包，
统一放在 [Releases](https://github.com/mydanyi/armada-danyi-build/releases) 页面。
个人版**不使用 Steam/官方渠道覆盖**：系统升级通过本仓库的 OCI 升级包完成，不会
跟随官方 Beta 通道被替换。

每个 Release 同时提供两类产物，并用分卷（`.partNNN`）分发，以避免单个整包
过大。

## 一、安装包分卷与 OCI 升级分卷的区别

| 用途 | 完整包 | 分卷命名 | 使用者 |
| --- | --- | --- | --- |
| 首次安装（刷机） | `armada-<版本>.img.gz` | `armada-<版本>.img.gz.part000…` | 尚未安装的新设备 |
| 已装机升级（OTA） | `armada-<版本>.oci.tar` | `armada-<版本>.oci.tar.part000…` | 已安装本个人版的设备 |

- **安装包分卷**：把完整刷机镜像 `armada-<版本>.img.gz` 切成若干 `.partNNN`。
  分卷只用于传输，按原文件名重组后得到的仍是刷机用的完整 `.img.gz`。
- **OCI 升级分卷**：把完整升级包 `armada-<版本>.oci.tar` 切成若干 `.partNNN`。
  升级脚本会按编号顺序下载、逐个校验，再合并回完整 OCI 后交给系统。

> 分卷（`.partNNN`）只在 GitHub Release 上分发；完整的 `.img.gz` 与 `.oci.tar`
> 及小型校验元数据另行留存副本，因此同一个整包不会被重复传输。

## 二、完整性校验（SHA256SUMS）

每个 Release 都带有一份 `SHA256SUMS`，其中同时列出**完整包**与**每一个分卷**的
SHA256。请在使用前校验，升级脚本也会自动逐卷校验。

## 三、首次安装（刷机）

1. 从 [Releases](https://github.com/mydanyi/armada-danyi-build/releases) 下载全部
   `armada-<版本>.img.gz.partNNN` 分卷。
2. 按文件名顺序重组为原始完整包（保持原名）：

   ```bash
   cat armada-<版本>.img.gz.part* > armada-<版本>.img.gz
   ```

3. 使用重组后的完整 `.img.gz`，按**官方安装文档**刷机：
   <https://armadaos.dev/getting-started/flashing-to-an-sd-card/>

请勿直接刷分卷文件；务必先重组回完整 `.img.gz`。

## 四、已安装用户升级（一条命令）

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

## 五、重启与回滚

- 阶段化完成后**不会自动重启**，请自行**手动重启**以应用升级。
- 升级会保留 `/var` 与 `/etc` 的用户状态（游戏与存档等通常不受影响），但本版不保证
  所有用户配置均保持不变。
- 需要回退时：执行 `sudo bootc rollback`，然后**手动重启**。

## 六、本版要点与已知限制

- 合并上游 PR #594、#608、#609、#651、#665 与 #712 的相关改动。
- 刷新周期重复调度修复（Gamescope #2417）、改进 FIFO 处理、DRM 实际显示帧身份绑定，
  并保留此前恢复并验收的 HUD 曲线统计方式。
- 预装个人版 Decky 插件 Armada Installer、LSFG-VK ARM64（r16）与 DeckyClash（内置可执行代理核心）。
- **已知限制**：组合后的新镜像**尚未在真机验收**；本说明不代表所有游戏均已修复。
- 本个人版不会经由 Steam 官方渠道被覆盖。
