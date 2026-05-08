# HiSH Linux Image

提供 [HiSH](https://github.com/harmoninux/HiSH) 支持的 Linux 镜像。HiSH 是一个运行在 HarmonyOS 上的 Linux 模拟器。

## 支持的发行版

| 发行版 | 配置文件 | 说明 | 下载 |
|--------|----------|------|------|
| Fedora | `Fedora.json` | Fedora 最小化安装（.raw.xz） | [HiSH-image-Fedora-43-1.6.qcow2](https://github.com/ACTom/HiSH-Linux-Image/releases/download/HiSH-image-Fedora-43-1.6/HiSH-image-Fedora-43-1.6.qcow2) |
| Ubuntu | `Ubuntu.json` | Ubuntu WSL 根文件系统（.tar.gz） | [HiSH-image-Ubuntu-26.04.qcow2](https://github.com/ACTom/HiSH-Linux-Image/releases/download/HiSH-image-Ubuntu-26.04/HiSH-image-Ubuntu-26.04.qcow2) |
| Debian | `Debian.json` | Debian QEMU 云磁盘镜像（.tar.xz） | [HiSH-image-Debian-13.qcow2](https://github.com/ACTom/HiSH-Linux-Image/releases/download/HiSH-image-Debian-13/HiSH-image-Debian-13.qcow2) |
| Rocky Linux | `RockyLinux.json` | Rocky Linux WSL 根文件系统（.wsl） | [HiSH-image-RockyLinux-10.qcow2](https://github.com/ACTom/HiSH-Linux-Image/releases/download/HiSH-image-RockyLinux-10/HiSH-image-RockyLinux-10.qcow2) |

前往 [Releases](../../releases) 页面下载所需的 qcow2 镜像文件，然后在 HiSH 中导入即可使用。

## 使用方法

> **Ubuntu / Rocky Linux 默认登录信息：** 用户 `root`，密码 `hish`
>
> **Fedora / Debian 首次启动时会运行初始设置向导**，需要根据提示创建用户和设置密码。

## 工作原理

本仓库通过 GitHub Actions 自动将官方 Linux 发行版的原始镜像转换为 HiSH 可用的 qcow2 格式镜像，并发布为 GitHub Release。

### 转换流程

不同发行版的源镜像格式不同，转换流程有所差异：

**Fedora（.raw.xz 磁盘镜像）：**

1. 下载官方 `.raw.xz` 格式的镜像
2. 解压并挂载原始镜像的根分区
3. 创建 120G 的 qcow2 镜像并格式化为 ext4
4. 将根文件系统内容复制到新镜像
5. 对新镜像做 HiSH 所需的修改
    - 删除原有磁盘挂载配置（systemd mount unit）
    - 新增共享目录挂载配置
    - 创建 `/init` → `/sbin/init` 的符号链接
    - 禁用内核更新（HiSH 自带内核）
6. 压缩输出最终的 qcow2 镜像

**Ubuntu（.tar.gz WSL 根文件系统）：**

1. 下载官方 `.tar.gz` 格式的 WSL 根文件系统
2. 创建 120G 的 qcow2 镜像并格式化为 ext4
3. 将根文件系统直接解压到新镜像
4. 对新镜像做 HiSH 所需的修改
    - 配置 `/etc/fstab` 添加共享目录挂载
    - 设置 root 默认密码为 `hish`
    - 配置 netplan 网络（DHCP）
    - 创建 `/init` → `/sbin/init` 的符号链接
    - 禁用内核更新（HiSH 自带内核）
5. 压缩输出最终的 qcow2 镜像

**Debian（.tar.xz 磁盘镜像）：**

1. 下载官方 `.tar.xz` 格式的镜像
2. 解压获取 `disk.raw`，挂载其中的根分区
3. 创建 120G 的 qcow2 镜像并格式化为 ext4
4. 将根文件系统内容复制到新镜像
5. 对新镜像做 HiSH 所需的修改
    - 配置 `/etc/fstab` 添加共享目录挂载
    - 配置 `/etc/network/interfaces` 网络（DHCP）
    - 创建 `/init` → `/sbin/init` 的符号链接
    - 禁用内核更新（HiSH 自带内核）
6. 压缩输出最终的 qcow2 镜像

**Rocky Linux（.wsl WSL 根文件系统）：**

1. 下载官方 `.wsl` 格式的 WSL 根文件系统
2. 创建 120G 的 qcow2 镜像并格式化为 ext4
3. 将根文件系统直接解压到新镜像
4. 对新镜像做 HiSH 所需的修改
    - 删除原有磁盘挂载配置（systemd mount unit）
    - 设置 root 默认密码为 `hish`
    - 配置 `/etc/fstab` 添加共享目录挂载
    - 创建 `/init` → `/sbin/init` 的符号链接
    - 禁用内核更新（HiSH 自带内核）
5. 压缩输出最终的 qcow2 镜像


### 本地构建

如果需要本地构建镜像，可以运行转换脚本：

```bash
# Fedora
sudo ./convert.fedora.sh <source.raw.xz> <output.qcow2>

# Ubuntu
sudo ./convert.ubuntu.sh <source.tar.gz> <output.qcow2>

# Debian
sudo ./convert.debian.sh <source.tar.xz> <output.qcow2>

# Rocky Linux
sudo ./convert.rockylinux.sh <source.wsl> <output.qcow2>
```

**依赖：** `qemu-utils`、`e2fsprogs`、`mount`、`util-linux`、`rsync`（Fedora/Debian 额外需要 `xz-utils`，Debian 额外需要 `parted`）

> **注意：** 脚本必须以 root 权限运行。

## 相关项目

- [HiSH](https://github.com/harmoninux/HiSH) - HarmonyOS 上的 Linux 模拟器
