#!/bin/bash
# 固件诊断脚本 - 检查全部 14 项清理
# 用法: sudo ./diagnose-firmware.sh
# 原始 img.gz 不动，操作诊断副本

OUTPUT_DIR="/opt/openwrt_packit/output"
MOUNT_DIR="/mnt/fw-diag"
REPORT="/tmp/diagnose-report.txt"

echo "=========================================="
echo "🔍 固件诊断（14 项清理检查）"
echo "=========================================="

# 初始化报告
echo "==========================================" > "$REPORT"
echo "📋 固件诊断报告" >> "$REPORT"
echo "检查时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$REPORT"
echo "==========================================" >> "$REPORT"
echo "" >> "$REPORT"

# 1. 找到原始 img.gz
IMG_GZ=$(ls "$OUTPUT_DIR"/openwrt_s905d_n1_*.img.gz 2>/dev/null | head -1)
[ -z "$IMG_GZ" ] && { echo "❌ 找不到固件"; echo "❌ 找不到固件" >> "$REPORT"; exit 1; }
echo "✅ 原始固件: $IMG_GZ"
echo "原始固件: $(basename $IMG_GZ)" >> "$REPORT"

# 2. 创建诊断副本
DIAG_GZ="${IMG_GZ%.img.gz}-diagnose.img.gz"
cp "$IMG_GZ" "$DIAG_GZ"
echo "📋 诊断副本: $DIAG_GZ"

# 3. 解压诊断副本
gunzip "$DIAG_GZ"
DIAG_IMG="${DIAG_GZ%.gz}"
echo "📦 解压完成: $DIAG_IMG"

# 4. 挂载
LOOP=$(losetup -fP --show "$DIAG_IMG")
BTRFS_PART="${LOOP}p2"
mkdir -p "$MOUNT_DIR"

MOUNTED=false
if mount -t btrfs -o subvol=@ "$BTRFS_PART" "$MOUNT_DIR" 2>/dev/null; then
    MOUNTED=true
elif mount -t btrfs "$BTRFS_PART" "$MOUNT_DIR" 2>/dev/null; then
    MOUNTED=true
fi

[ "$MOUNTED" = false ] && { echo "❌ 挂载失败"; losetup -d "$LOOP"; rm -f "$DIAG_IMG"; exit 1; }
echo "✅ 挂载成功"

# 5. 获取内核版本目录
KERNEL_DIR=$(find "$MOUNT_DIR/lib/modules" -maxdepth 1 -type d -name "[0-9]*" 2>/dev/null | head -1)
MOD_BASE="${KERNEL_DIR}/kernel/drivers/net"
echo "" >> "$REPORT"

# 6. 逐项检查
PASS=0
FAIL=0
FAIL_LIST=""

check() {
    local num="$1" desc="$2" path="$3" type="$4" expect="$5"
    local result=""
    case "$type" in
        dir)  [ "$expect" = "absent" ] && [ ! -d "$path" ] && result="OK" || [ "$expect" = "present" ] && [ -d "$path" ] && result="OK" || result="FAIL" ;;
        file) [ "$expect" = "absent" ] && [ ! -f "$path" ] && result="OK" || [ "$expect" = "present" ] && [ -f "$path" ] && result="OK" || result="FAIL" ;;
    esac
    if [ "$result" = "OK" ]; then
        echo "  [OK]    ${num}. ${desc}"
        echo "  [OK]    ${num}. ${desc}" >> "$REPORT"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL]  ${num}. ${desc}"
        echo "  [FAIL]  ${num}. ${desc}" >> "$REPORT"
        FAIL=$((FAIL + 1))
        FAIL_LIST="${FAIL_LIST}  ${num}. ${desc}\n"
    fi
}

echo ""
echo "=========================================="
echo "📊 开始逐项检查"
echo "=========================================="
echo ""
echo "检查详情:" >> "$REPORT"

# 1-3: 驱动目录
check 1 "wireless 驱动目录" "${MOD_BASE}/wireless" dir absent
check 2 "usb 网卡驱动目录" "${MOD_BASE}/usb" dir absent
check 3 "ppp 驱动目录" "${MOD_BASE}/ppp" dir absent

# 4: WiFi 固件
check 4 "WiFi 固件 (brcm)" "$MOUNT_DIR/lib/firmware/brcm" dir absent

# 5: 无线配置
check 5 "无线配置文件" "$MOUNT_DIR/etc/config/wireless" file absent

# 6: brcmfmac 模块
check 6 "brcmfmac 模块文件" "$MOUNT_DIR/etc/modules.d/brcmfmac" file absent

# 7: 10 个 USB/无线模块文件
MOD_DIR="$MOUNT_DIR/etc/modules.d"
for mod in usb-net-asix-ax88179 usb-net-rtl8152 rtl8188eu rt2500-usb rt2800-usb rt2x00-usb mt7601u mt7663u mt76x0u mt76x2u; do
    check 7 "${mod} 模块" "${MOD_DIR}/${mod}" file absent
done

# 8-11: MAC/WiFi 脚本
check 8  "fix_wifi_macaddr.sh"   "$MOUNT_DIR/usr/bin/fix_wifi_macaddr.sh" file absent
check 9  "find_macaddr.pl"       "$MOUNT_DIR/usr/bin/find_macaddr.pl"    file absent
check 10 "inc_macaddr.pl"        "$MOUNT_DIR/usr/bin/inc_macaddr.pl"     file absent
check 11 "get_random_mac.sh"     "$MOUNT_DIR/usr/bin/get_random_mac.sh"  file absent

# 12-14: 保留项
check 12 "看门狗模块" "$MOUNT_DIR/etc/modules.d/watchdog" file present
check 13 "GPU 模块"   "$MOUNT_DIR/etc/modules.d/panfrost"  file present
check 14 "PWM 模块"   "$MOUNT_DIR/etc/modules.d/pwm_meson" file present

# 7. 清理
echo ""
echo "📤 卸载并清理诊断副本..."
umount "$MOUNT_DIR" 2>/dev/null
losetup -d "$LOOP" 2>/dev/null
rm -rf "$MOUNT_DIR"
rm -f "$DIAG_IMG"
echo "✅ 诊断副本已清理，原始固件未改动"

# 8. 汇总报告
TOTAL=$((PASS + FAIL))
echo ""
echo "=========================================="
echo "📈 诊断汇总"
echo "=========================================="
echo ""
echo "  总计: ${TOTAL} 项"
echo "  通过: ${PASS} 项"
echo "  失败: ${FAIL} 项"

cat >> "$REPORT" << EOF

==========================================
📈 诊断汇总
==========================================

检查项: ${TOTAL}
通过:   ${PASS}
失败:   ${FAIL}

原始固件: $(basename $IMG_GZ)（未改动）
诊断副本: 已自动清理
==========================================
EOF

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "⚠️  失败项列表:"
    echo ""
    echo -e "$FAIL_LIST"
    echo ""
    echo "⚠️  失败项列表:" >> "$REPORT"
    echo -e "$FAIL_LIST" >> "$REPORT"
else
    echo ""
    echo "✅ 全部 14 项通过"
    echo ""
    echo "✅ 全部通过" >> "$REPORT"
fi

echo "📄 报告已保存: $REPORT"
echo "=========================================="
