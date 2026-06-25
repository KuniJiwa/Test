#!/bin/bash
# 固件诊断 - 操作副本，原始不动
OUTPUT_DIR="/opt/openwrt_packit/output"
MOUNT_DIR="/mnt/fw-diag"

echo "🔍 固件诊断"
IMG_GZ=$(ls "$OUTPUT_DIR"/openwrt_s905d_n1_*.img.gz 2>/dev/null | head -1)
[ -z "$IMG_GZ" ] && { echo "❌ 找不到固件"; exit 0; }

DIAG_GZ="${IMG_GZ%.img.gz}-diagnose.img.gz"
cp "$IMG_GZ" "$DIAG_GZ" && gunzip "$DIAG_GZ"
DIAG_IMG="${DIAG_GZ%.gz}"
LOOP=$(losetup -fP --show "$DIAG_IMG")
mkdir -p "$MOUNT_DIR"
mount -t btrfs -o subvol=@ "${LOOP}p2" "$MOUNT_DIR" 2>/dev/null || mount -t btrfs "${LOOP}p2" "$MOUNT_DIR" 2>/dev/null || { echo "❌ 挂载失败"; losetup -d "$LOOP"; rm -f "$DIAG_IMG"; exit 0; }

KERNEL_DIR=$(find "$MOUNT_DIR/lib/modules" -maxdepth 1 -type d -name "[0-9]*" 2>/dev/null | head -1)
MOD_BASE="${KERNEL_DIR}/kernel/drivers/net"
MOD_DIR="$MOUNT_DIR/etc/modules.d"
PASS=0; FAIL=0

check_dir() { if [ ! -d "$1" ]; then echo "  ✅ [已清理] $2"; PASS=$((PASS+1)); else echo "  ❌ [残留] $2"; FAIL=$((FAIL+1)); fi; }
check_file() { if [ ! -f "$1" ]; then echo "  ✅ [已清理] $2"; PASS=$((PASS+1)); else echo "  ❌ [残留] $2"; FAIL=$((FAIL+1)); fi; }
check_keep() { if [ -f "$1" ]; then echo "  ✅ [保留] $2"; PASS=$((PASS+1)); else echo "  ❌ [缺失] $2"; FAIL=$((FAIL+1)); fi; }

echo ""
echo "========== 1. 删除无线驱动目录 =========="
check_dir "${MOD_BASE}/wireless" "wireless 驱动目录"

echo ""
echo "========== 2. 删除 USB 网卡驱动目录 =========="
check_dir "${MOD_BASE}/usb" "usb 网卡驱动目录"

echo ""
echo "========== 3. 删除 PPP 驱动目录 =========="
check_dir "${MOD_BASE}/ppp" "ppp 驱动目录"

echo ""
echo "========== 4. 删除 WiFi 固件 =========="
check_dir "$MOUNT_DIR/lib/firmware/brcm" "brcm 固件目录"

echo ""
echo "========== 5. 删除无线配置 =========="
check_file "$MOUNT_DIR/etc/config/wireless" "无线配置文件"

echo ""
echo "========== 6. 禁用 brcmfmac 驱动 =========="
check_file "${MOD_DIR}/brcmfmac" "brcmfmac 模块文件"

echo ""
echo "========== 7. 禁用 USB/无线网卡驱动 =========="
for mod in usb-net-asix-ax88179 usb-net-rtl8152 rtl8188eu rt2500-usb rt2800-usb rt2x00-usb mt7601u mt7663u mt76x0u mt76x2u; do
    check_file "${MOD_DIR}/${mod}" "${mod} 模块"
done

echo ""
echo "========== 8. 删除 MAC/WiFi 脚本 =========="
check_file "$MOUNT_DIR/usr/bin/fix_wifi_macaddr.sh" "fix_wifi_macaddr.sh"
check_file "$MOUNT_DIR/usr/bin/find_macaddr.pl" "find_macaddr.pl"
check_file "$MOUNT_DIR/usr/bin/inc_macaddr.pl" "inc_macaddr.pl"
check_file "$MOUNT_DIR/usr/bin/get_random_mac.sh" "get_random_mac.sh"

echo ""
echo "========== 9. 保留功能检查 =========="
check_keep "${MOD_DIR}/watchdog" "看门狗模块"
check_keep "${MOD_DIR}/panfrost" "GPU 模块"
check_keep "${MOD_DIR}/pwm_meson" "PWM 模块"

# 清理
umount "$MOUNT_DIR" 2>/dev/null; losetup -d "$LOOP" 2>/dev/null; rm -rf "$MOUNT_DIR" "$DIAG_IMG"

echo ""
echo "=========================================="
echo "📈 诊断结果: 共 $((PASS+FAIL)) 项，✅ ${PASS}，❌ ${FAIL}"
[ $FAIL -eq 0 ] && echo "✅ 全部通过" || echo "❌ 有失败项，请检查上方明细"
echo "=========================================="

exit 0
