# 本个人版内置的中文 OpenABL
- 项目：https://github.com/OpenHandheldCollective/OpenABL
- 源码提交：fed5b5e57d38936bd4ab6e11be986b703fd44187（简体中文文案及字库改进）。
- 固件版本：OpenABL 1.0；构建选项：--lang zh-hans，保留默认功能。
- 内置中文固件：SM8550、SM8650、SM8750，均为532480字节。各芯片的精确SHA256与版本登记在 ../releases.tsv。
- SM8250：中文构建超出现有固件构建空间，保留原官方1.1.8，不混用其他芯片固件。
- 同目录 openabl-fed5b5e-source.tar.gz 包含本次提交及构建使用的固定依赖源码，SHA256为5630d88e50869131b820411cae92c5639b0c6729f1d24a8daea2511434098d10。
- 版权和授权见同目录 LICENSE、LICENSES.md、LICENSES/、CREDITS.md。源码与这些材料随系统镜像、OCI升级包及本版source.tar.gz提供。
- SM8750固件已在AYN Odin 3上由用户确认正常；本个人版完整系统镜像及其他芯片仍需各自设备复测。
- 系统镜像默认不自动刷写ABL，现有版本降级拒绝策略保留。升级系统不等于把设备上已有ABL改成中文。
This product includes software developed by the OpenSSL Project for use in the OpenSSL Toolkit (http://www.openssl.org/).
This product includes cryptographic software written by Eric Young (eay@cryptsoft.com).