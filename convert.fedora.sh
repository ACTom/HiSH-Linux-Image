#!/bin/bash

# 检查参数数量
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <source.raw.xz> <target.qcow2>"
    exit 1
fi

SOURCE=$1
TARGET=$2
RAW_FILE="temp.raw"
QCOW2_FILE="temp.qcow2"
MOUNT_DIR="mnt"
SOURCE_MOUNT_DIR="mnt_source"
NBD_DEVICE="/dev/nbd0"
LOOP_DEVICE=""
PARTITION_LOOP_DEVICE=""

# 检查是否以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# 定义依赖包列表
DEPENDENCIES=("qemu-utils" "e2fsprogs" "mount" "util-linux" "xz-utils" "rsync")

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

# Step 1: 解压 .raw.xz 文件为 .raw
echo "Decompressing .raw.xz to .raw..."
xz -d -k "$SOURCE" -c > "$RAW_FILE"
if [ $? -ne 0 ]; then
    echo "Failed to decompress .raw.xz file."
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

# Step 2: 使用 losetup 挂载 .raw 文件为块设备
echo "Attaching .raw file to loop device..."
LOOP_DEVICE=$(losetup -f)
losetup "$LOOP_DEVICE" "$RAW_FILE"
if [ $? -ne 0 ]; then
    echo "Failed to attach .raw file to loop device."
    rm -f "$RAW_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

# Step 3: 获取第三个分区的起始扇区和大小
echo "Reading partition table..."
PART_INFO=$(fdisk -l "$LOOP_DEVICE" | grep "^${LOOP_DEVICE}p")
if [ $? -ne 0 ]; then
    echo "Failed to read partition table."
    losetup -d "$LOOP_DEVICE"
    rm -f "$RAW_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

# 提取第三个分区的信息
PART_START=$(echo "$PART_INFO" | awk 'NR==3 {print $2}')
PART_SIZE=$(echo "$PART_INFO" | awk 'NR==3 {print $4}')
if [ -z "$PART_START" ] || [ -z "$PART_SIZE" ]; then
    echo "Failed to extract partition information for the third partition."
    losetup -d "$LOOP_DEVICE"
    rm -f "$RAW_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

# Step 4: 使用 losetup 挂载第三个分区
echo "Attaching third partition to loop device..."
PARTITION_LOOP_DEVICE=$(losetup -f)
losetup -o $((PART_START * 512)) --sizelimit $((PART_SIZE * 512)) "$PARTITION_LOOP_DEVICE" "$LOOP_DEVICE"
if [ $? -ne 0 ]; then
    echo "Failed to attach third partition to loop device."
    losetup -d "$LOOP_DEVICE"
    rm -f "$RAW_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

# Step 5: 创建一个 120G 的 qcow2 文件
echo "Creating a 120G qcow2 file..."
qemu-img create -f qcow2 "$QCOW2_FILE" 120G
if [ $? -ne 0 ]; then
    echo "Failed to create qcow2 file."
    losetup -d "$LOOP_DEVICE"
    losetup -d "$PARTITION_LOOP_DEVICE"
    rm -f "$RAW_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

# Step 6: 使用 nbd 挂载 qcow2 文件
echo "Attaching qcow2 file to NBD device..."
modprobe nbd max_part=8
qemu-nbd -c "$NBD_DEVICE" "$QCOW2_FILE"
if [ $? -ne 0 ]; then
    echo "Failed to attach qcow2 file to NBD device."
    losetup -d "$LOOP_DEVICE"
    losetup -d "$PARTITION_LOOP_DEVICE"
    rm -f "$RAW_FILE" "$QCOW2_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

# 等待设备就绪
sleep 5

# Step 7: 格式化 nbd 分区为 ext4
echo "Formatting NBD partition with ext4..."
mkfs.ext4 "$NBD_DEVICE"
if [ $? -ne 0 ]; then
    echo "Failed to format NBD partition."
    qemu-nbd -d "$NBD_DEVICE"
    losetup -d "$LOOP_DEVICE"
    losetup -d "$PARTITION_LOOP_DEVICE"
    rm -f "$RAW_FILE" "$QCOW2_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

# Step 8: 挂载分区
echo "Mounting NBD partition..."
mount "$NBD_DEVICE" "$MOUNT_DIR"
if [ $? -ne 0 ]; then
    echo "Failed to mount NBD partition."
    qemu-nbd -d "$NBD_DEVICE"
    losetup -d "$LOOP_DEVICE"
    losetup -d "$PARTITION_LOOP_DEVICE"
    rm -f "$RAW_FILE" "$QCOW2_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

# Step 9: 挂载第三个分区
echo "Mounting third partition..."
mount "$PARTITION_LOOP_DEVICE" "$SOURCE_MOUNT_DIR"
if [ $? -ne 0 ]; then
    echo "Failed to mount third partition."
    umount "$MOUNT_DIR"
    qemu-nbd -d "$NBD_DEVICE"
    losetup -d "$LOOP_DEVICE"
    losetup -d "$PARTITION_LOOP_DEVICE"
    rm -f "$RAW_FILE" "$QCOW2_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

# Step 10: 将第三个分区的内容复制到目标分区
echo "Copying data from third partition to mounted directory..."
rsync -a --info=progress2 "$SOURCE_MOUNT_DIR/" "$MOUNT_DIR/"
if [ $? -ne 0 ]; then
    echo "Failed to copy data from third partition."
    umount "$SOURCE_MOUNT_DIR"
    umount "$MOUNT_DIR"
    qemu-nbd -d "$NBD_DEVICE"
    losetup -d "$LOOP_DEVICE"
    losetup -d "$PARTITION_LOOP_DEVICE"
    rm -f "$RAW_FILE" "$QCOW2_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi

umount "$SOURCE_MOUNT_DIR"

# Step 11: 创建 /sbin/init 到 /init 的相对路径软链接
echo "Creating relative symbolic link sbin/init -> init..."
cd "$MOUNT_DIR" || { echo "Failed to change directory to $MOUNT_DIR"; exit 1; }
ln -srf "sbin/init" "init"
if [ $? -ne 0 ]; then
    echo "Failed to create relative symbolic link sbin/init -> init."
    cd -
    umount "$MOUNT_DIR"
    qemu-nbd -d "$NBD_DEVICE"
    losetup -d "$LOOP_DEVICE"
    losetop -d "$PARTITION_LOOP_DEVICE"
    rm -f "$RAW_FILE" "$QCOW2_FILE"
    rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
    exit 1
fi
cd -

# Step 12: 禁用 kernel 和 kernel-core 的更新
echo "Disabling kernel updates in DNF configuration..."
DNF_CONF="$MOUNT_DIR/etc/dnf/dnf.conf"
if [ -f "$DNF_CONF" ]; then
    # 添加 exclude 规则
    echo "exclude=kernel* kernel-core*" >> "$DNF_CONF"
    if [ $? -ne 0 ]; then
        echo "Failed to update DNF configuration."
        umount "$MOUNT_DIR"
        qemu-nbd -d "$NBD_DEVICE"
        losetup -d "$LOOP_DEVICE"
        losetup -d "$PARTITION_LOOP_DEVICE"
        rm -f "$RAW_FILE" "$QCOW2_FILE"
        rm -rf "$MOUNT_DIR" "$SOURCE_MOUNT_DIR"
        exit 1
    fi
else
    echo "Warning: DNF configuration file not found at $DNF_CONF. Skipping kernel update disable."
fi

# Step 13: 卸载分区并断开 nbd 和 loop 连接
echo "Unmounting and detaching devices..."
umount "$MOUNT_DIR"
qemu-nbd -d "$NBD_DEVICE"
losetup -d "$LOOP_DEVICE"
losetup -d "$PARTITION_LOOP_DEVICE"
if [ $? -ne 0 ]; then
    echo "Failed to detach devices."
    exit 1
fi

# Step 14: 使用 qemu-img convert 压缩 qcow2 文件为目标文件
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