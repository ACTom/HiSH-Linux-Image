# HiSH Linux Image

用于生成 [HiSH](https://github.com/harmoninux/HiSH) 支持的 Linux 镜像。HiSH 是一个运行在 HarmonyOS 上的 Linux 模拟器。

## 工作原理

本仓库通过 GitHub Actions 自动将官方 Linux 发行版的原始镜像转换为 HiSH 可用的 qcow2 格式镜像，并发布为 GitHub Release。

### 转换流程

1. 下载官方 `.raw.xz` 格式的镜像
2. 解压并挂载原始镜像的根分区
3. 创建 120G 的 qcow2 镜像并格式化为 ext4
4. 将根文件系统内容复制到新镜像
5. 对新镜像做 HiSH 所需的修改
    - 删除原有磁盘挂载配置
    - 新增共享目录挂载配置
    - 创建 `/init` → `/sbin/init` 的符号链接
    - 禁用内核更新（HiSH自带内核）
7. 压缩输出最终的 qcow2 镜像

## 支持的发行版

| 发行版 | 配置文件 | 说明 |
|--------|----------|------|
| Fedora | `Fedora.json` | Fedora 最小化安装 |

## 使用方法

### 下载镜像

前往 [Releases](../../releases) 页面下载所需的 qcow2 镜像文件，然后在 HiSH 中导入即可使用。

### 触发构建

修改对应发行版的 JSON 配置文件（如 `Fedora.json`）并推送到仓库，即可自动触发 GitHub Actions 构建新的镜像。

以 `Fedora.json` 为例：

```json
{
  "name": "Fedora",
  "version": "43-1.6",
  "url": "https://download.fedoraproject.org/pub/fedora/linux/releases/43/Spins/aarch64/images/Fedora-Minimal-43-1.6.aarch64.raw.xz"
}
```

| 字段 | 说明 |
|------|------|
| `name` | 发行版名称 |
| `version` | 版本号 |
| `url` | 官方 aarch64 原始镜像下载地址 |

### 本地构建

如果需要本地构建镜像，可以运行转换脚本：

```bash
sudo ./convert.fedora.sh <source.raw.xz> <output.qcow2>
```

**依赖：** `qemu-utils`、`e2fsprogs`、`mount`、`util-linux`、`xz-utils`、`rsync`

> **注意：** 脚本必须以 root 权限运行。

## 相关项目

- [HiSH](https://github.com/harmoninux/HiSH) - HarmonyOS 上的 Linux 模拟器
