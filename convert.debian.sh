#!/bin/bash

# 检查参数数量
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <source.tar.xz> <target.qcow2>"
    exit 1
fi

SOURCE=$1
TARGET=$2
RAW_FILE="disk.raw"
QCOW2_FILE="temp.qcow2"
MOUNT_DIR="mnt"
SOURCE_MOUNT_DIR="mnt_source"
NBD_DEVICE="/dev/nbd0"
LOOP_DEVICE=""
ROOT_PARTITION_DEVICE=""

# 检查是否以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# 定义依赖包列表
DEPENDENCIES=("qemu-utils" "e2fsprogs" "mount" "util-linux" "xz-utils" "rsync" "parted")

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
mkdir -p "$SOURCE_MOUNT_DIR"

# Step 1: 解压 .tar.xz 文件获取 disk.raw
echo "Extracting disk.raw from tar.xz..."
tar -xJf "$SOURCE" disk.raw
if [ $? -ne 0 ]; then
    echo "Failed to extract disk.raw from tar.xz."
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

# Step 2: 使用 losetup 挂载 disk.raw 为块设备
echo "Attaching disk.raw to loop device..."
LOOP_DEVICE=$(losetup -f)
losetup "$LOOP_DEVICE" "$RAW_FILE"
if [ $? -ne 0 ]; then
    echo "Failed to attach disk.raw to loop device."
    rm -f "$RAW_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

# Step 3: 扫描分区表并找到根分区
echo "Scanning partition table..."
partprobe "$LOOP_DEVICE" 2>/dev/null
sleep 2

# 使用 blkid 查找 ext4 分区（根分区）
ROOT_PARTITION_DEVICE=""
for part_dev in "${LOOP_DEVICE}p"*; do
    if [ -e "$part_dev" ]; then
        FSTYPE=$(blkid -o value -s TYPE "$part_dev" 2>/dev/null)
        if [ "$FSTYPE" = "ext4" ]; then
            ROOT_PARTITION_DEVICE="$part_dev"
            echo "  Found root partition: $ROOT_PARTITION_DEVICE (ext4)"
            break
        fi
    fi
done

# 如果没有找到分区设备，尝试用 fdisk 解析并使用 losetup 偏移挂载
if [ -z "$ROOT_PARTITION_DEVICE" ]; then
    echo "  Partition devices not found, trying offset mount..."
    PART_INFO=$(fdisk -l "$LOOP_DEVICE" | grep "^${LOOP_DEVICE}p")
    PART_COUNT=$(echo "$PART_INFO" | wc -l)

    # 从最后一个分区开始查找 ext4
    for i in $(seq "$PART_COUNT" -1 1); do
        PART_START=$(echo "$PART_INFO" | awk -v nr="$i" 'NR==nr {print $2}')
        PART_SIZE=$(echo "$PART_INFO" | awk -v nr="$i" 'NR==nr {print $4}')
        if [ -n "$PART_START" ] && [ -n "$PART_SIZE" ]; then
            ROOT_PARTITION_DEVICE=$(losetup -f)
            losetup -o $((PART_START * 512)) --sizelimit $((PART_SIZE * 512)) "$ROOT_PARTITION_DEVICE" "$LOOP_DEVICE"
            FSTYPE=$(blkid -o value -s TYPE "$ROOT_PARTITION_DEVICE" 2>/dev/null)
            if [ "$FSTYPE" = "ext4" ] || [ "$FSTYPE" = "ext2" ] || [ "$FSTYPE" = "ext3" ]; then
                echo "  Found root partition at offset $((PART_START * 512)): $ROOT_PARTITION_DEVICE ($FSTYPE)"
                break
            else
                losetup -d "$ROOT_PARTITION_DEVICE"
                ROOT_PARTITION_DEVICE=""
            fi
        fi
    done
fi

if [ -z "$ROOT_PARTITION_DEVICE" ]; then
    echo "Failed to find root partition."
    losetup -d "$LOOP_DEVICE"
    rm -f "$RAW_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

# Step 4: 创建一个 120G 的 qcow2 文件
echo "Creating a 120G qcow2 file..."
qemu-img create -f qcow2 "$QCOW2_FILE" 120G
if [ $? -ne 0 ]; then
    echo "Failed to create qcow2 file."
    losetup -d "$ROOT_PARTITION_DEVICE" 2>/dev/null
    losetup -d "$LOOP_DEVICE"
    rm -f "$RAW_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

# Step 5: 使用 nbd 挂载 qcow2 文件
echo "Attaching qcow2 file to NBD device..."
modprobe nbd max_part=8
qemu-nbd -c "$NBD_DEVICE" "$QCOW2_FILE"
if [ $? -ne 0 ]; then
    echo "Failed to attach qcow2 file to NBD device."
    losetup -d "$ROOT_PARTITION_DEVICE" 2>/dev/null
    losetup -d "$LOOP_DEVICE"
    rm -f "$RAW_FILE" "$QCOW2_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

# 等待设备就绪
sleep 5

# Step 6: 格式化 nbd 分区为 ext4
echo "Formatting NBD partition with ext4..."
mkfs.ext4 "$NBD_DEVICE"
if [ $? -ne 0 ]; then
    echo "Failed to format NBD partition."
    qemu-nbd -d "$NBD_DEVICE"
    losetup -d "$ROOT_PARTITION_DEVICE" 2>/dev/null
    losetup -d "$LOOP_DEVICE"
    rm -f "$RAW_FILE" "$QCOW2_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

# Step 7: 挂载 qcow2 分区
echo "Mounting NBD partition..."
mount "$NBD_DEVICE" "$MOUNT_DIR"
if [ $? -ne 0 ]; then
    echo "Failed to mount NBD partition."
    qemu-nbd -d "$NBD_DEVICE"
    losetup -d "$ROOT_PARTITION_DEVICE" 2>/dev/null
    losetup -d "$LOOP_DEVICE"
    rm -f "$RAW_FILE" "$QCOW2_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

# Step 8: 挂载根分区
echo "Mounting root partition..."
mount "$ROOT_PARTITION_DEVICE" "$SOURCE_MOUNT_DIR"
if [ $? -ne 0 ]; then
    echo "Failed to mount root partition."
    umount "$MOUNT_DIR"
    qemu-nbd -d "$NBD_DEVICE"
    losetup -d "$ROOT_PARTITION_DEVICE" 2>/dev/null
    losetup -d "$LOOP_DEVICE"
    rm -f "$RAW_FILE" "$QCOW2_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

# Step 9: 复制根分区内容到目标分区
echo "Copying data from root partition to mounted directory..."
rsync -a --info=progress2 "$SOURCE_MOUNT_DIR/" "$MOUNT_DIR/"
if [ $? -ne 0 ]; then
    echo "Failed to copy data from root partition."
    umount "$SOURCE_MOUNT_DIR"
    umount "$MOUNT_DIR"
    qemu-nbd -d "$NBD_DEVICE"
    losetup -d "$ROOT_PARTITION_DEVICE" 2>/dev/null
    losetup -d "$LOOP_DEVICE"
    rm -f "$RAW_FILE" "$QCOW2_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

umount "$SOURCE_MOUNT_DIR"

# Step 10: 配置 /etc/fstab 挂载
echo "Configuring /etc/fstab..."
mkdir -p "$MOUNT_DIR/mnt/share"
cat > "$MOUNT_DIR/etc/fstab" << 'EOF'
hostshare /mnt/share 9p trans=virtio,version=9p2000.L 0 0
EOF
echo "  Configured /etc/fstab with share mount"

# Step 11: 配置网络
echo "Configuring network..."
NETWORK_INTERFACES="$MOUNT_DIR/etc/network/interfaces"
mkdir -p "$(dirname "$NETWORK_INTERFACES")"
cat > "$NETWORK_INTERFACES" << 'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
echo "  Configured /etc/network/interfaces with DHCP for eth0"

# Step 12: 创建 /sbin/init 到 /init 的相对路径软链接
echo "Creating relative symbolic link sbin/init -> init..."
cd "$MOUNT_DIR" || { echo "Failed to change directory to $MOUNT_DIR"; exit 1; }
ln -srf "sbin/init" "init"
if [ $? -ne 0 ]; then
    echo "Failed to create relative symbolic link sbin/init -> init."
    cd -
    umount "$MOUNT_DIR"
    qemu-nbd -d "$NBD_DEVICE"
    losetup -d "$ROOT_PARTITION_DEVICE" 2>/dev/null
    losetup -d "$LOOP_DEVICE"
    rm -f "$RAW_FILE" "$QCOW2_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi
cd -

# Step 13: 禁用内核更新
echo "Disabling kernel updates in APT configuration..."
APT_CONF="$MOUNT_DIR/etc/apt/apt.conf.d/99no-kernel-update"
mkdir -p "$(dirname "$APT_CONF")"
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

# Step 14: 卸载分区并断开连接
echo "Unmounting and detaching devices..."
umount "$MOUNT_DIR"
qemu-nbd -d "$NBD_DEVICE"
losetup -d "$ROOT_PARTITION_DEVICE" 2>/dev/null
losetup -d "$LOOP_DEVICE"
if [ $? -ne 0 ]; then
    echo "Failed to detach devices."
    exit 1
fi

# Step 15: 使用 qemu-img convert 压缩 qcow2 文件为目标文件
echo "Compressing qcow2 file using qemu-img convert..."
qemu-img convert -O qcow2 -c "$QCOW2_FILE" "$TARGET"
if [ $? -ne 0 ]; then
    echo "Failed to compress qcow2 file."
    exit 1
fi

# 清理临时文件
echo "Cleaning up temporary files..."
rm -rf "$RAW_FILE" "$QCOW2_FILE" "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"

echo "Conversion completed successfully. Target file: $TARGET"
