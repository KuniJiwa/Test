#!/bin/bash
# 固件诊断 - 仅诊断不清理，操作副本，原始不动
OUTPUT_DIR="/opt/openwrt_packit/output"
MOUNT_DIR="/mnt/fw-diag"
REPORT="/tmp/diagnose-report.txt"

echo "=========================================="
echo "🔍 固件诊断（14 项清理检查）"
echo "=========================================="
echo "诊断时间: $(date '+%Y-%m-%d %H:%M:%S')" > "$REPORT"
echo "原始固件: $(ls "$OUTPUT_DIR"/openwrt_s905d_n1_*.img.gz 2>/dev/null | head -1)" >> "$REPORT"
echo "" >> "$REPORT"

IMG_GZ=$(ls "$OUTPUT_DIR"/openwrt_s905d_n1_*.img.gz 2>/dev/null | head -1)
[ -z "$IMG_GZ" ] && { echo "❌ 找不到固件"; exit 0; }
echo "✅ 原始固件: $IMG_GZ"

DIAG_GZ="${IMG_GZ%.img.gz}-diagnose.img.gz"
cp "$IMG_GZ" "$DIAG_GZ"
gunzip "$DIAG_GZ"
DIAG_IMG="${DIAG_GZ%.gz}"

LOOP=$(losetup -fP --show "$DIAG_IMG")
mkdir -p "$MOUNT_DIR"
mount -t btrfs -o subvol=@ "${LOOP}p2" "$MOUNT_DIR" 2>/dev/null || mount -t btrfs "${LOOP}p2" "$MOUNT_DIR" 2>/dev/null || { echo "❌ 挂载失败"; losetup -d "$LOOP"; rm -f "$DIAG_IMG"; exit 0; }

KERNEL_DIR=$(find "$MOUNT_DIR/lib/modules" -maxdepth 1 -type d -name "[0-9]*" 2>/dev/null | head -1)
MOD_BASE="${KERNEL_DIR}/kernel/drivers/net"
MOD_DIR="$MOUNT_DIR/etc/modules.d"

PASS=0; FAIL=0; FAIL_LIST=""

check() {
    local desc="$1" path="$2" type="$3" expect="$4"
    local exists=false
    case "$type" in dir) [ -d "$path" ] && exists=true ;; file) [ -f "$path" ] && exists=true ;; esac

    if [ "$expect" = "absent" ]; then
        if [ "$exists" = false ]; then
            echo "✅ ${desc} → ${path}"
            echo "✅ ${desc} → ${path}" >> "$REPORT"
            PASS=$((PASS+1))
        else
            echo "❌ ${desc} → ${path}"
            echo "❌ ${desc} → ${path}" >> "$REPORT"
            FAIL=$((FAIL+1))
            FAIL_LIST="${FAIL_LIST}  ❌ ${desc}\n"
        fi
    else
        if [ "$exists" = true ]; then
            echo "✅ ${desc} → ${path}"
            echo "✅ ${desc} → ${path}" >> "$REPORT"
            PASS=$((PASS+1))
        else
            echo "❌ ${desc} → ${path}"
            echo "❌ ${desc} → ${path}" >> "$REPORT"
            FAIL=$((FAIL+1))
            FAIL_LIST="${FAIL_LIST}  ❌ ${desc}\n"
        fi
    fi
}

echo ""
echo "📊 诊断结果:"
echo "" >> "$REPORT"

# 1-3 驱动目录
check "wireless 驱动目录" "${MOD_BASE}/wireless" dir absent
check "usb 网卡驱动目录" "${MOD_BASE}/usb" dir absent
check "ppp 驱动目录" "${MOD_BASE}/ppp" dir absent

# 4 WiFi 固件
check "WiFi 固件 (brcm)" "$MOUNT_DIR/lib/firmware/brcm" dir absent

# 5 无线配置
check "无线配置文件" "$MOUNT_DIR/etc/config/wireless" file absent

# 6 brcmfmac 模块
check "brcmfmac 模块" "${MOD_DIR}/brcmfmac" file absent

# 7 10个USB/无线模块
for mod in usb-net-asix-ax88179 usb-net-rtl8152 rtl8188eu rt2500-usb rt2800-usb rt2x00-usb mt7601u mt7663u mt76x0u mt76x2u; do
    check "${mod} 模块" "${MOD_DIR}/${mod}" file absent
done

# 8-11 MAC/WiFi 脚本
check "fix_wifi_macaddr.sh" "$MOUNT_DIR/usr/bin/fix_wifi_macaddr.sh" file absent
check "find_macaddr.pl" "$MOUNT_DIR/usr/bin/find_macaddr.pl" file absent
check "inc_macaddr.pl" "$MOUNT_DIR/usr/bin/inc_macaddr.pl" file absent
check "get_random_mac.sh" "$MOUNT_DIR/usr/bin/get_random_mac.sh" file absent

# 12-14 保留项
check "看门狗模块" "${MOD_DIR}/watchdog" file present
check "GPU 模块" "${MOD_DIR}/panfrost" file present
check "PWM 模块" "${MOD_DIR}/pwm_meson" file present

# 清理
umount "$MOUNT_DIR" 2>/dev/null
losetup -d "$LOOP" 2>/dev/null
rm -rf "$MOUNT_DIR" "$DIAG_IMG"

# 汇总
TOTAL=$((PASS+FAIL))
echo ""
echo "📈 汇总: 共 ${TOTAL} 项，✅ ${PASS} 项，❌ ${FAIL} 项"
echo "" >> "$REPORT"
echo "📈 汇总: 共 ${TOTAL} 项，✅ ${PASS} 项，❌ ${FAIL} 项" >> "$REPORT"
if [ "$FAIL" -gt 0 ]; then
    echo "❌ 失败项明细:"
    echo -e "$FAIL_LIST"
    echo "❌ 失败项明细:" >> "$REPORT"
    echo -e "$FAIL_LIST" >> "$REPORT"
else
    echo "✅ 全部通过"
    echo "✅ 全部通过" >> "$REPORT"
fi
echo "📄 报告: $REPORT"

exit 0
