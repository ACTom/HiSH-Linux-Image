#!/bin/bash

# 检查参数数量
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <source.tar.gz> <target.qcow2>"
    exit 1
fi

SOURCE=$1
TARGET=$2
QCOW2_FILE="temp.qcow2"
MOUNT_DIR="mnt"
NBD_DEVICE="/dev/nbd0"

# 检查是否以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# 定义依赖包列表
DEPENDENCIES=("qemu-utils" "e2fsprogs" "mount" "util-linux" "rsync")

# 安装所有依赖项
echo "Installing required dependencies..."
apt-get update -qq
apt-get install -y "${DEPENDENCIES[@]}"
if [ $? -ne 0 ]; then
    echo "Failed to install required dependencies. Exiting..."
    exit 1
fi

# 检查 source 文件是否存在
if [ ! -f "$SOURCE" ]; then
    echo "Error: Source file $SOURCE does not exist."
    exit 1
fi

# 创建临时目录
mkdir -p "$MOUNT_DIR"

# Step 1: 创建一个 120G 的 qcow2 文件
echo "Creating a 120G qcow2 file..."
qemu-img create -f qcow2 "$QCOW2_FILE" 120G
if [ $? -ne 0 ]; then
    echo "Failed to create qcow2 file."
    rm -rf "$MOUNT_DIR"
    exit 1
fi

# Step 2: 使用 nbd 挂载 qcow2 文件
echo "Attaching qcow2 file to NBD device..."
modprobe nbd max_part=8
qemu-nbd -c "$NBD_DEVICE" "$QCOW2_FILE"
if [ $? -ne 0 ]; then
    echo "Failed to attach qcow2 file to NBD device."
    rm -f "$QCOW2_FILE"
    rm -rf "$MOUNT_DIR"
    exit 1
fi

# 等待设备就绪
sleep 5

# Step 3: 格式化 nbd 分区为 ext4
echo "Formatting NBD partition with ext4..."
mkfs.ext4 "$NBD_DEVICE"
if [ $? -ne 0 ]; then
    echo "Failed to format NBD partition."
    qemu-nbd -d "$NBD_DEVICE"
    rm -f "$QCOW2_FILE"
    rm -rf "$MOUNT_DIR"
    exit 1
fi

# Step 4: 挂载分区
echo "Mounting NBD partition..."
mount "$NBD_DEVICE" "$MOUNT_DIR"
if [ $? -ne 0 ]; then
    echo "Failed to mount NBD partition."
    qemu-nbd -d "$NBD_DEVICE"
    rm -f "$QCOW2_FILE"
    rm -rf "$MOUNT_DIR"
    exit 1
fi

# Step 5: 解压 .tar.gz 根文件系统到挂载目录
echo "Extracting rootfs tarball to mounted directory..."
tar -xzf "$SOURCE" -C "$MOUNT_DIR"
if [ $? -ne 0 ]; then
    echo "Failed to extract rootfs tarball."
    umount "$MOUNT_DIR"
    qemu-nbd -d "$NBD_DEVICE"
    rm -f "$QCOW2_FILE"
    rm -rf "$MOUNT_DIR"
    exit 1
fi

# Step 6: 配置 /etc/fstab 挂载
echo "Configuring /etc/fstab..."
mkdir -p "$MOUNT_DIR/mnt/share"
cat > "$MOUNT_DIR/etc/fstab" << 'EOF'
hostshare /mnt/share 9p trans=virtio,version=9p2000.L 0 0
EOF
echo "  Configured /etc/fstab with share mount"

# Step 7: 设置 root 默认密码
echo "Setting root default password..."
SHADOW_FILE="$MOUNT_DIR/etc/shadow"
HASH=$(openssl passwd -6 'hish')
sed -i "s|^root:[^:]*:|root:${HASH}:|" "$SHADOW_FILE"
if [ $? -ne 0 ]; then
    echo "Failed to set root password."
    umount "$MOUNT_DIR"
    qemu-nbd -d "$NBD_DEVICE"
    rm -f "$QCOW2_FILE"
    rm -rf "$MOUNT_DIR"
    exit 1
fi
echo "  Root password set to hish"

# Step 8: 配置 netplan 网络
echo "Configuring netplan..."
NETPLAN_DIR="$MOUNT_DIR/etc/netplan"
mkdir -p "$NETPLAN_DIR"
cat > "$NETPLAN_DIR/01-hish-default.yaml" << 'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
    all-eth:
      match:
        name: "eth*"
      dhcp4: true
EOF
echo "  Configured netplan with DHCP for en* and eth*"

# Step 9: 创建 /sbin/init 到 /init 的相对路径软链接
echo "Creating relative symbolic link sbin/init -> init..."
cd "$MOUNT_DIR" || { echo "Failed to change directory to $MOUNT_DIR"; exit 1; }
ln -srf "sbin/init" "init"
if [ $? -ne 0 ]; then
    echo "Failed to create relative symbolic link sbin/init -> init."
    cd -
    umount "$MOUNT_DIR"
    qemu-nbd -d "$NBD_DEVICE"
    rm -f "$QCOW2_FILE"
    rm -rf "$MOUNT_DIR"
    exit 1
fi
cd -

# Step 10: 禁用内核更新
echo "Disabling kernel updates in APT configuration..."
APT_CONF="$MOUNT_DIR/etc/apt/apt.conf.d/99no-kernel-update"
cat > "$APT_CONF" << 'EOF'
APT::Get::Upgrade-Allow-New "false";
EOF

# 使用 APT preferences 阻止内核包更新
PREF_DIR="$MOUNT_DIR/etc/apt/preferences.d"
mkdir -p "$PREF_DIR"
cat > "$PREF_DIR/99no-kernel-update" << 'EOF'
Package: linux-image-* linux-headers-* linux-modules-*
Pin: release *
Pin-Priority: -1
EOF
echo "  Disabled kernel updates"

# Step 11: 卸载分区并断开 nbd 连接
echo "Unmounting and detaching devices..."
umount "$MOUNT_DIR"
qemu-nbd -d "$NBD_DEVICE"
if [ $? -ne 0 ]; then
    echo "Failed to detach devices."
    exit 1
fi

# Step 12: 使用 qemu-img convert 压缩 qcow2 文件为目标文件
echo "Compressing qcow2 file using qemu-img convert..."
qemu-img convert -O qcow2 -c "$QCOW2_FILE" "$TARGET"
if [ $? -ne 0 ]; then
    echo "Failed to compress qcow2 file."
    exit 1
fi

# 清理临时文件
echo "Cleaning up temporary files..."
rm -rf "$QCOW2_FILE" "$MOUNT_DIR"

echo "Conversion completed successfully. Target file: $TARGET"
