#!/bin/bash
# 固件诊断（直接检查 .img.gz，原始文件不动）
set -e

# 配置
OUTPUT_DIR="/opt/openwrt_packit/output"
MOUNT_POINT="/mnt/diag"
REPORT_FILE="/tmp/diag-report.txt"

# 找镜像
IMG_GZ=$(ls "$OUTPUT_DIR"/openwrt_s905d_n1_*.img.gz 2>/dev/null | head -1)
if [ -z "$IMG_GZ" ]; then
    echo "❌ 找不到固件"
    exit 1
fi

echo "检查固件: $(basename $IMG_GZ)"
echo ""

# 创建临时副本（挂载后删除）
cp "$IMG_GZ" /tmp/diag.img.gz
gunzip /tmp/diag.img.gz
IMG=/tmp/diag.img

# 挂载
LOOP=$(losetup -fP --show "$IMG")
ROOTFS="${LOOP}p2"
mkdir -p "$MOUNT_POINT"
mount -t btrfs -o ro,subvol=@ "$ROOTFS" "$MOUNT_POINT" 2>/dev/null || mount -t btrfs -o ro "$ROOTFS" "$MOUNT_POINT"

# 内核模块路径
KVER=$(ls "$MOUNT_POINT/lib/modules" | grep -E '^[0-9]' | head -1)
MOD_PATH="$MOUNT_POINT/lib/modules/$KVER/kernel/drivers/net"

# 检查项列表（顺序展示）
checks=(
    "删除:wireless驱动:$MOD_PATH/wireless:dir"
    "删除:usb网卡驱动:$MOD_PATH/usb:dir"
    "删除:ppp驱动:$MOD_PATH/ppp:dir"
    "删除:WiFi固件brcm:$MOUNT_POINT/lib/firmware/brcm:dir"
    "删除:无线配置:$MOUNT_POINT/etc/config/wireless:file"
    "删除:brcmfmac模块:$MOUNT_POINT/etc/modules.d/brcmfmac:file"
    "删除:usb-net-asix:$MOUNT_POINT/etc/modules.d/usb-net-asix-ax88179:file"
    "删除:usb-net-rtl8152:$MOUNT_POINT/etc/modules.d/usb-net-rtl8152:file"
    "删除:rtl8188eu:$MOUNT_POINT/etc/modules.d/rtl8188eu:file"
    "删除:rt2500-usb:$MOUNT_POINT/etc/modules.d/rt2500-usb:file"
    "删除:rt2800-usb:$MOUNT_POINT/etc/modules.d/rt2800-usb:file"
    "删除:rt2x00-usb:$MOUNT_POINT/etc/modules.d/rt2x00-usb:file"
    "删除:mt7601u:$MOUNT_POINT/etc/modules.d/mt7601u:file"
    "删除:mt7663u:$MOUNT_POINT/etc/modules.d/mt7663u:file"
    "删除:mt76x0u:$MOUNT_POINT/etc/modules.d/mt76x0u:file"
    "删除:mt76x2u:$MOUNT_POINT/etc/modules.d/mt76x2u:file"
    "删除:fix_wifi_macaddr.sh:$MOUNT_POINT/usr/bin/fix_wifi_macaddr.sh:file"
    "删除:find_macaddr.pl:$MOUNT_POINT/usr/bin/find_macaddr.pl:file"
    "删除:inc_macaddr.pl:$MOUNT_POINT/usr/bin/inc_macaddr.pl:file"
    "删除:get_random_mac.sh:$MOUNT_POINT/usr/bin/get_random_mac.sh:file"
    "保留:watchdog:$MOUNT_POINT/etc/modules.d/watchdog:file:present"
    "保留:panfrost:$MOUNT_POINT/etc/modules.d/panfrost:file:present"
    "保留:pwm_meson:$MOUNT_POINT/etc/modules.d/pwm_meson:file:present"
)

pass=0
fail=0
echo "=========================================="
for item in "${checks[@]}"; do
    IFS=':' read -r type name path kind expected <<< "$item"
    [[ "$expected" != "present" ]] && expected="absent"
    
    if [ "$kind" = "dir" ]; then
        if [ "$expected" = "absent" ]; then
            if [ ! -d "$path" ]; then
                echo "✅ $name"
                pass=$((pass+1))
            else
                echo "❌ $name"
                fail=$((fail+1))
            fi
        else
            if [ -d "$path" ]; then
                echo "✅ $name"
                pass=$((pass+1))
            else
                echo "❌ $name"
                fail=$((fail+1))
            fi
        fi
    else  # file
        if [ "$expected" = "absent" ]; then
            if [ ! -f "$path" ]; then
                echo "✅ $name"
                pass=$((pass+1))
            else
                echo "❌ $name"
                fail=$((fail+1))
            fi
        else
            if [ -f "$path" ]; then
                echo "✅ $name"
                pass=$((pass+1))
            else
                echo "❌ $name"
                fail=$((fail+1))
            fi
        fi
    fi
done
echo "=========================================="
echo "通过: $pass  失败: $fail"
echo ""

# 清理
umount "$MOUNT_POINT"
losetup -d "$LOOP"
rm -f "$IMG" /tmp/diag.img.gz
