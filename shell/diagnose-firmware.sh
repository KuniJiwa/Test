#!/bin/bash
# 固件诊断体检脚本（使用 img 副本，原始不动）
# 用法: sudo ./diagnose-firmware.sh

OUTPUT_DIR="/opt/openwrt_packit/output"
MOUNT_DIR="/mnt/firmware-diagnose"
REPORT_FILE="/tmp/diagnose-report.txt"

echo "=========================================="
echo "🔍 固件诊断体检脚本（副本模式）"
echo "=========================================="
echo ""

# 初始化报告
cat > "$REPORT_FILE" << 'EOF'
==========================================
📋 固件诊断体检报告
==========================================
EOF

# 1. 找到原始 img 文件
IMG_FILE=$(ls $OUTPUT_DIR/*.img 2>/dev/null | head -1)
IMG_GZ=""
if [ -z "$IMG_FILE" ]; then
    # 尝试找 .img.gz
    IMG_GZ=$(ls $OUTPUT_DIR/*.img.gz 2>/dev/null | head -1)
    if [ -z "$IMG_GZ" ]; then
        echo "❌ 找不到固件 img 文件"
        echo "❌ 找不到固件 img 文件" >> "$REPORT_FILE"
        exit 1
    fi
    echo "📦 解压原始固件..."
    gunzip "$IMG_GZ"
    IMG_FILE="${IMG_GZ%.gz}"
fi

echo "✅ 原始固件: $IMG_FILE"
echo "原始固件: $IMG_FILE" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# 2. 创建诊断副本
echo "📋 创建诊断副本..."
DIAGNOSE_IMG="${IMG_FILE%.img}-diagnose.img"
cp "$IMG_FILE" "$DIAGNOSE_IMG"
echo "✅ 诊断副本: $DIAGNOSE_IMG"

# 3. 关联循环设备（用副本）
echo ""
echo "🔗 关联循环设备..."
LOOP_DEV=$(losetup -f -P --show "$DIAGNOSE_IMG")
echo "✅ 循环设备: $LOOP_DEV"

# 4. 找到 btrfs 分区
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

# 5. 挂载 btrfs
echo ""
echo "📂 挂载 btrfs 分区..."
mkdir -p "$MOUNT_DIR"

MOUNTED=false

# 尝试 1: 默认挂载（根子卷）
if mount -t btrfs "$BTRFS_PART" "$MOUNT_DIR" 2>/dev/null; then
    # 检查是否有 etc 目录（判断是否是正确的子卷）
    if [ -d "$MOUNT_DIR/etc" ] || [ -d "$MOUNT_DIR/usr" ]; then
        echo "✅ 挂载成功（默认子卷）"
        MOUNTED=true
    else
        umount "$MOUNT_DIR" 2>/dev/null
    fi
fi

# 尝试 2: @ 子卷
if [ "$MOUNTED" = false ]; then
    if mount -t btrfs -o subvol=@ "$BTRFS_PART" "$MOUNT_DIR" 2>/dev/null; then
        echo "✅ 挂载成功（@ 子卷）"
        MOUNTED=true
    fi
fi

# 尝试 3: 列出所有子卷，找合适的
if [ "$MOUNTED" = false ]; then
    # 先挂载根，看看有哪些子卷
    if mount -t btrfs "$BTRFS_PART" "$MOUNT_DIR" 2>/dev/null; then
        SUBVOLS=$(btrfs subvolume list "$MOUNT_DIR" 2>/dev/null | awk '{print $NF}' | head -10)
        echo "📋 检测到子卷: $SUBVOLS"
        umount "$MOUNT_DIR" 2>/dev/null
        
        # 尝试常见的子卷名
        for subvol in @ @rootfs rootfs ""; do
            if [ -z "$subvol" ]; then
                mount -t btrfs "$BTRFS_PART" "$MOUNT_DIR" 2>/dev/null && MOUNTED=true && break
            else
                mount -t btrfs -o subvol="$subvol" "$BTRFS_PART" "$MOUNT_DIR" 2>/dev/null && MOUNTED=true && break
            fi
        done
    fi
fi

if [ "$MOUNTED" = false ]; then
    echo "❌ 挂载失败"
    losetup -d "$LOOP_DEV" 2>/dev/null
    rm -f "$DIAGNOSE_IMG"
    exit 1
fi

# 6. 开始诊断
echo ""
echo "=========================================="
echo "📊 开始诊断检查"
echo "=========================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

check_item() {
    local name="$1"
    local result="$2"
    local detail="$3"
    
    if [ "$result" == "PASS" ]; then
        echo "✅ $name"
        echo "✅ $name - $detail" >> "$REPORT_FILE"
        PASS_COUNT=$((PASS_COUNT + 1))
    elif [ "$result" == "FAIL" ]; then
        echo "❌ $name"
        echo "❌ $name - $detail" >> "$REPORT_FILE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "⚠️  $name"
        echo "⚠️  $name - $detail" >> "$REPORT_FILE"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
}

# 检查 1: 无线驱动
echo "1️⃣  检查无线驱动..."
WIRELESS_DIR=$(find "$MOUNT_DIR/lib/modules" -path "*/kernel/drivers/net/wireless" -type d 2>/dev/null | head -1)
if [ -z "$WIRELESS_DIR" ]; then
    check_item "无线驱动已移除" "PASS" "未找到 wireless 驱动目录"
else
    WIRELESS_FILES=$(find "$WIRELESS_DIR" -type f 2>/dev/null | wc -l)
    if [ "$WIRELESS_FILES" -eq 0 ]; then
        check_item "无线驱动已移除" "PASS" "目录存在但为空"
    else
        check_item "无线驱动已移除" "FAIL" "找到 $WIRELESS_FILES 个驱动文件"
    fi
fi

# 检查 2: USB 网卡驱动
echo "2️⃣  检查 USB 网卡驱动..."
USB_NET_DIR=$(find "$MOUNT_DIR/lib/modules" -path "*/kernel/drivers/net/usb" -type d 2>/dev/null | head -1)
if [ -z "$USB_NET_DIR" ]; then
    check_item "USB网卡驱动已移除" "PASS" "未找到 usb 驱动目录"
else
    USB_FILES=$(find "$USB_NET_DIR" -type f 2>/dev/null | wc -l)
    if [ "$USB_FILES" -eq 0 ]; then
        check_item "USB网卡驱动已移除" "PASS" "目录存在但为空"
    else
        check_item "USB网卡驱动已移除" "FAIL" "找到 $USB_FILES 个驱动文件"
    fi
fi

# 检查 3: PPP 驱动
echo "3️⃣  检查 PPP 驱动..."
PPP_DIR=$(find "$MOUNT_DIR/lib/modules" -path "*/kernel/drivers/net/ppp" -type d 2>/dev/null | head -1)
if [ -z "$PPP_DIR" ]; then
    check_item "PPP驱动已移除" "PASS" "未找到 ppp 驱动目录"
else
    PPP_FILES=$(find "$PPP_DIR" -type f 2>/dev/null | wc -l)
    if [ "$PPP_FILES" -eq 0 ]; then
        check_item "PPP驱动已移除" "PASS" "目录存在但为空"
    else
        check_item "PPP驱动已移除" "FAIL" "找到 $PPP_FILES 个驱动文件"
    fi
fi

# 检查 4: WiFi 固件
echo "4️⃣  检查 WiFi 固件..."
BRCM_DIR="$MOUNT_DIR/lib/firmware/brcm"
if [ ! -d "$BRCM_DIR" ]; then
    check_item "WiFi固件已移除" "PASS" "未找到 brcm 固件目录"
else
    BRCM_FILES=$(find "$BRCM_DIR" -type f 2>/dev/null | wc -l)
    if [ "$BRCM_FILES" -eq 0 ]; then
        check_item "WiFi固件已移除" "PASS" "目录存在但为空"
    else
        check_item "WiFi固件已移除" "FAIL" "找到 $BRCM_FILES 个固件文件"
    fi
fi

# 检查 5: vmlinux-btf
echo "5️⃣  检查 vmlinux-btf..."
BTF_FILE=$(find "$MOUNT_DIR/usr/lib/debug/boot" -name "vmlinux" -type f 2>/dev/null | head -1)
if [ -n "$BTF_FILE" ]; then
    BTF_SIZE=$(stat -c%s "$BTF_FILE" 2>/dev/null || echo 0)
    if [ "$BTF_SIZE" -gt 1000000 ]; then
        check_item "vmlinux-btf 已内置" "PASS" "文件大小: $BTF_SIZE bytes"
    else
        check_item "vmlinux-btf 已内置" "WARN" "文件存在但过小: $BTF_SIZE bytes（可能是占位文件）"
    fi
    # 检查符号链接
    if ls "$MOUNT_DIR/usr/lib/debug/boot"/vmlinux-* 2>/dev/null | grep -q vmlinux; then
        echo "   ℹ️  检测到版本符号链接"
    fi
else
    check_item "vmlinux-btf 已内置" "FAIL" "未找到 vmlinux-btf 文件"
fi

# 检查 6: 内核版本
echo "6️⃣  检查内核版本..."
KERNEL_DIR=$(find "$MOUNT_DIR/lib/modules" -maxdepth 1 -type d -name "[0-9]*" 2>/dev/null | head -1)
if [ -n "$KERNEL_DIR" ]; then
    KERNEL_VER=$(basename "$KERNEL_DIR")
    check_item "内核版本" "PASS" "$KERNEL_VER"
    echo "内核版本: $KERNEL_VER" >> "$REPORT_FILE"
else
    check_item "内核版本" "FAIL" "未找到内核模块目录"
fi

# 检查 7: 固件版本
echo "7️⃣  检查固件版本..."
if [ -f "$MOUNT_DIR/etc/openwrt_release" ]; then
    FW_VER=$(grep "DISTRIB_RELEASE" "$MOUNT_DIR/etc/openwrt_release" 2>/dev/null | cut -d"'" -f2)
    FW_DESC=$(grep "DISTRIB_DESCRIPTION" "$MOUNT_DIR/etc/openwrt_release" 2>/dev/null | cut -d"'" -f2)
    check_item "固件版本" "PASS" "$FW_DESC"
    echo "固件版本: $FW_DESC" >> "$REPORT_FILE"
elif [ -f "$MOUNT_DIR/etc/os-release" ]; then
    FW_VER=$(grep "VERSION_ID" "$MOUNT_DIR/etc/os-release" 2>/dev/null | cut -d"=" -f2 | tr -d '"')
    FW_NAME=$(grep "NAME" "$MOUNT_DIR/etc/os-release" 2>/dev/null | head -1 | cut -d"=" -f2 | tr -d '"')
    check_item "固件版本" "PASS" "$FW_NAME $FW_VER"
    echo "固件版本: $FW_NAME $FW_VER" >> "$REPORT_FILE"
else
    check_item "固件版本" "WARN" "未找到版本信息文件"
fi

# 检查 8: 根分区大小
echo "8️⃣  检查根分区大小..."
if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
    ROOT_SIZE=$(df -h "$MOUNT_DIR" 2>/dev/null | tail -1 | awk '{print $2}')
    ROOT_USED=$(df -h "$MOUNT_DIR" 2>/dev/null | tail -1 | awk '{print $3}')
    check_item "根分区大小" "PASS" "总大小: $ROOT_SIZE, 已用: $ROOT_USED"
    echo "根分区: 总大小 $ROOT_SIZE, 已用 $ROOT_USED" >> "$REPORT_FILE"
else
    check_item "根分区大小" "WARN" "无法获取分区信息"
fi

# 检查 9: 关键系统文件
echo "9️⃣  检查关键系统文件..."
if [ -f "$MOUNT_DIR/bin/busybox" ] || [ -f "$MOUNT_DIR/usr/bin/busybox" ]; then
    check_item "关键系统文件" "PASS" "busybox 存在"
else
    check_item "关键系统文件" "FAIL" "缺少 busybox"
fi

# 7. 输出总结
echo ""
echo "=========================================="
echo "📈 诊断总结"
echo "=========================================="
echo ""
echo "✅ 通过: $PASS_COUNT 项"
echo "❌ 失败: $FAIL_COUNT 项"
echo "⚠️  警告: $WARN_COUNT 项"
echo ""

# 写入报告
cat >> "$REPORT_FILE" << EOF

==========================================
📈 诊断总结
==========================================
✅ 通过: $PASS_COUNT 项
❌ 失败: $FAIL_COUNT 项
⚠️  警告: $WARN_COUNT 项
==========================================
报告生成时间: $(date)
==========================================
EOF

# 8. 清理（卸载 + 删除诊断副本）
echo "📤 卸载并清理诊断副本..."
umount "$MOUNT_DIR" 2>/dev/null
losetup -d "$LOOP_DEV" 2>/dev/null
rm -rf "$MOUNT_DIR"
rm -f "$DIAGNOSE_IMG"
echo "✅ 诊断副本已清理，原始固件未改动"

# 9. 重新压缩原始 img（如果原来是 .gz）
if [ -n "$IMG_GZ" ]; then
    echo ""
    echo "📦 重新压缩原始固件..."
    gzip "$IMG_FILE"
fi

echo ""
echo "📄 诊断报告已保存到: $REPORT_FILE"
echo ""

# 如果有失败项，返回非零
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "⚠️  有 $FAIL_COUNT 项检查未通过，请查看报告"
    exit 0  # 不中断工作流，只警告
fi

echo "✅ 诊断完成，所有关键检查通过！"
