#!/bin/bash
# 固件精简处理脚本（挂载 img 方式）
# 删除无线驱动、WiFi固件、USB网卡驱动、PPP驱动等
# 用法: sudo ./trim-firmware.sh

set -e

OUTPUT_DIR="/opt/openwrt_packit/output"
MOUNT_DIR="/mnt/firmware-trim"

echo "=========================================="
echo "✂️  固件精简处理脚本（挂载 img 方式）"
echo "=========================================="
echo "输出目录: $OUTPUT_DIR"
echo ""

# 1. 找到 img 文件
IMG_FILE=$(ls $OUTPUT_DIR/*.img 2>/dev/null | head -1)
if [ -z "$IMG_FILE" ]; then
    # 尝试找 .img.gz
    IMG_GZ=$(ls $OUTPUT_DIR/*.img.gz 2>/dev/null | head -1)
    if [ -z "$IMG_GZ" ]; then
        echo "❌ 找不到固件 img 文件"
        exit 1
    fi
    echo "📦 解压固件..."
    gunzip "$IMG_GZ"
    IMG_FILE="${IMG_GZ%.gz}"
fi

echo "✅ 找到固件: $IMG_FILE"

# 2. 关联循环设备
echo ""
echo "🔗 关联循环设备..."
LOOP_DEV=$(losetup -f -P --show "$IMG_FILE")
echo "✅ 循环设备: $LOOP_DEV"

# 3. 找到 btrfs 分区
BTRFS_PART=""
for part in ${LOOP_DEV}p*; do
    if blkid "$part" 2>/dev/null | grep -q 'TYPE="btrfs"'; then
        BTRFS_PART="$part"
        break
    fi
done

if [ -z "$BTRFS_PART" ]; then
    echo "⚠️  未检测到 btrfs 类型，尝试第2分区..."
    BTRFS_PART="${LOOP_DEV}p2"
fi

echo "✅ btrfs 分区: $BTRFS_PART"

# 4. 挂载 btrfs
echo ""
echo "📂 挂载 btrfs 分区..."
mkdir -p "$MOUNT_DIR"

# 尝试默认挂载
if mount -t btrfs "$BTRFS_PART" "$MOUNT_DIR" 2>/dev/null; then
    echo "✅ 挂载成功（默认子卷）"
else
    # 尝试 @ 子卷
    if mount -t btrfs -o subvol=@ "$BTRFS_PART" "$MOUNT_DIR" 2>/dev/null; then
        echo "✅ 挂载成功（@ 子卷）"
    else
        echo "❌ 挂载失败"
        losetup -d "$LOOP_DEV"
        exit 1
    fi
fi

# 5. 开始精简
echo ""
echo "=========================================="
echo "✂️  开始精简处理"
echo "=========================================="
echo ""

# 5.1 删除无线驱动
echo "1️⃣  删除无线驱动..."
WIRELESS_DIRS=$(find "$MOUNT_DIR/lib/modules" -path "*/kernel/drivers/net/wireless" -type d 2>/dev/null)
if [ -n "$WIRELESS_DIRS" ]; then
    for dir in $WIRELESS_DIRS; do
        echo "   删除: ${dir#$MOUNT_DIR}"
        rm -rf "$dir"
    done
    echo "   ✅ 无线驱动已删除"
else
    echo "   ℹ️  未找到无线驱动目录"
fi

# 5.2 删除 USB 网卡驱动
echo ""
echo "2️⃣  删除 USB 网卡驱动..."
USB_DIRS=$(find "$MOUNT_DIR/lib/modules" -path "*/kernel/drivers/net/usb" -type d 2>/dev/null)
if [ -n "$USB_DIRS" ]; then
    for dir in $USB_DIRS; do
        echo "   删除: ${dir#$MOUNT_DIR}"
        rm -rf "$dir"
    done
    echo "   ✅ USB网卡驱动已删除"
else
    echo "   ℹ️  未找到USB网卡驱动目录"
fi

# 5.3 删除 PPP 驱动
echo ""
echo "3️⃣  删除 PPP 驱动..."
PPP_DIRS=$(find "$MOUNT_DIR/lib/modules" -path "*/kernel/drivers/net/ppp" -type d 2>/dev/null)
if [ -n "$PPP_DIRS" ]; then
    for dir in $PPP_DIRS; do
        echo "   删除: ${dir#$MOUNT_DIR}"
        rm -rf "$dir"
    done
    echo "   ✅ PPP驱动已删除"
else
    echo "   ℹ️  未找到PPP驱动目录"
fi

# 5.4 删除 WiFi 固件
echo ""
echo "4️⃣  删除 WiFi 固件..."
BRCM_DIR="$MOUNT_DIR/lib/firmware/brcm"
if [ -d "$BRCM_DIR" ]; then
    echo "   删除: ${BRCM_DIR#$MOUNT_DIR}"
    rm -rf "$BRCM_DIR"
    echo "   ✅ WiFi固件已删除"
else
    echo "   ℹ️  未找到brcm固件目录"
fi

# 5.5 删除无线配置文件
echo ""
echo "5️⃣  删除无线配置..."
WIRELESS_CONFIG="$MOUNT_DIR/etc/config/wireless"
if [ -f "$WIRELESS_CONFIG" ]; then
    echo "   删除: ${WIRELESS_CONFIG#$MOUNT_DIR}"
    rm -f "$WIRELESS_CONFIG"
    echo "   ✅ 无线配置已删除"
else
    echo "   ℹ️  未找到无线配置文件"
fi

# 5.6 禁用 brcmfmac 模块加载
echo ""
echo "6️⃣  禁用无线模块加载..."
BRCM_MODULES=$(find "$MOUNT_DIR/etc/modules.d" -name "brcm*" 2>/dev/null)
if [ -n "$BRCM_MODULES" ]; then
    for mod in $BRCM_MODULES; do
        echo "   禁用: $(basename $mod)"
        rm -f "$mod"
    done
    echo "   ✅ 无线模块已禁用"
else
    echo "   ℹ️  未找到brcm模块配置"
fi

# 6. 统计精简效果
echo ""
echo "=========================================="
echo "📊 精简效果统计"
echo "=========================================="
echo ""

if mountpoint -q "$MOUNT_DIR"; then
    USED_SIZE=$(df -k "$MOUNT_DIR" 2>/dev/null | tail -1 | awk '{print $3}')
    echo "当前已用空间: ${USED_SIZE} KB"
fi

echo ""
echo "✅ 精简处理完成！"

# 7. 卸载
echo ""
echo "📤 卸载并清理..."
umount "$MOUNT_DIR"
losetup -d "$LOOP_DEV"
rm -rf "$MOUNT_DIR"

# 8. 重新压缩（如果原来是 .gz）
if [ -n "$IMG_GZ" ]; then
    echo "📦 重新压缩固件..."
    gzip "$IMG_FILE"
fi

echo ""
echo "=========================================="
echo "✅ 固件精简完成"
echo "=========================================="
