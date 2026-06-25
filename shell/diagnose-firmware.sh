#!/bin/bash

# 固件诊断 - 操作副本，原始不动

OUTPUT_DIR="/opt/openwrt_packit/output"
MOUNT_DIR="/mnt/fw-diag"

echo "🔍 固件诊断"
echo ""

IMG_GZ=$(ls "$OUTPUT_DIR"/openwrt_s905d_n1_*.img.gz 2>/dev/null | head -1)
[ -z "$IMG_GZ" ] && { echo "❌ 找不到固件文件"; exit 1; }

echo "📦 固件文件: $(basename "$IMG_GZ")"

# 复制副本，不碰原始文件
DIAG_GZ="${IMG_GZ%.img.gz}-diagnose.img.gz"
cp "$IMG_GZ" "$DIAG_GZ" && gunzip "$DIAG_GZ"
DIAG_IMG="${DIAG_GZ%.gz}"

# 挂载镜像
LOOP=$(losetup -fP --show "$DIAG_IMG")
mkdir -p "$MOUNT_DIR"

# 尝试挂载 btrfs（先试 subvol=@，再试默认）
mount -t btrfs -o subvol=@ "${LOOP}p2" "$MOUNT_DIR" 2>/dev/null \
    || mount -t btrfs "${LOOP}p2" "$MOUNT_DIR" 2>/dev/null \
    || {
        echo "❌ 挂载失败"
        losetup -d "$LOOP" 2>/dev/null
        rm -f "$DIAG_IMG"
        exit 1
    }

# 探测内核模块目录
KERNEL_DIR=$(find "$MOUNT_DIR/lib/modules" -maxdepth 1 -type d -name "[0-9]*" 2>/dev/null | head -1)
if [ -z "$KERNEL_DIR" ]; then
    echo "❌ 找不到内核模块目录"
    umount "$MOUNT_DIR" 2>/dev/null
    losetup -d "$LOOP" 2>/dev/null
    rm -f "$DIAG_IMG"
    exit 1
fi

MOD_BASE="${KERNEL_DIR}/kernel/drivers/net"
MOD_DIR="$MOUNT_DIR/etc/modules.d"

PASS=0
FAIL=0

check_absent() {
    # 检查应不存在的文件/目录
    if [ ! -e "$1" ]; then
        echo "  ✅ [已清理] $2"
        PASS=$((PASS+1))
    else
        echo "  ❌ [残留] $2"
        FAIL=$((FAIL+1))
    fi
}

check_present() {
    # 检查应存在的文件
    if [ -f "$1" ]; then
        echo "  ✅ [保留] $2"
        PASS=$((PASS+1))
    else
        echo "  ❌ [缺失] $2"
        FAIL=$((FAIL+1))
    fi
}

# ========== 已清理项检查 ==========

echo ""
echo "========== 1. 无线驱动目录 =========="
check_absent "${MOD_BASE}/wireless" "wireless 驱动目录"

echo ""
echo "========== 2. USB 网卡驱动目录 =========="
check_absent "${MOD_BASE}/usb" "usb 网卡驱动目录"

echo ""
echo "========== 3. PPP 驱动目录 =========="
check_absent "${MOD_BASE}/ppp" "ppp 驱动目录"

echo ""
echo "========== 4. WiFi 固件 =========="
check_absent "$MOUNT_DIR/lib/firmware/brcm" "brcm 固件目录"

echo ""
echo "========== 5. 无线配置文件 =========="
check_absent "$MOUNT_DIR/etc/config/wireless" "wireless 配置"

echo ""
echo "========== 6. brcmfmac 驱动模块 =========="
check_absent "${MOD_DIR}/brcmfmac" "brcmfmac 模块"

echo ""
echo "========== 7. USB/无线网卡模块 =========="
for mod in usb-net-asix-ax88179 usb-net-rtl8152 rtl8188eu rt2500-usb rt2800-usb rt2x00-usb mt7601u mt7663u mt76x0u mt76x2u; do
    check_absent "${MOD_DIR}/${mod}" "${mod}"
done

echo ""
echo "========== 8. MAC/WiFi 脚本 =========="
check_absent "$MOUNT_DIR/usr/bin/fix_wifi_macaddr.sh" "fix_wifi_macaddr.sh"
check_absent "$MOUNT_DIR/usr/bin/find_macaddr.pl" "find_macaddr.pl"
check_absent "$MOUNT_DIR/usr/bin/inc_macaddr.pl" "inc_macaddr.pl"
check_absent "$MOUNT_DIR/usr/bin/get_random_mac.sh" "get_random_mac.sh"

# ========== 应保留项检查 ==========

echo ""
echo "========== 9. 核心功能保留检查 =========="
check_present "${MOD_DIR}/watchdog" "看门狗模块"
check_present "${MOD_DIR}/panfrost" "GPU 模块 (panfrost)"
check_present "${MOD_DIR}/pwm_meson" "PWM 模块"

echo ""
echo "========== 10. vmlinux-btf 注入检查 =========="
BTF_FILE="$MOUNT_DIR/usr/lib/debug/boot/vmlinux"
if [ -f "$BTF_FILE" ]; then
    SIZE=$(ls -lh "$BTF_FILE" | awk '{print $5}')
    echo "  ✅ [已注入] vmlinux-btf (${SIZE})"
    PASS=$((PASS+1))
else
    echo "  ❌ [未注入] vmlinux-btf"
    # 顺便看看目录结构，方便排查
    if [ -d "$MOUNT_DIR/usr/lib/debug" ]; then
        echo "     debug 目录内容: $(ls "$MOUNT_DIR/usr/lib/debug/" 2>/dev/null)"
    else
        echo "     usr/lib/debug 目录不存在"
    fi
    FAIL=$((FAIL+1))
fi

# ========== 清理 ==========

umount "$MOUNT_DIR" 2>/dev/null
losetup -d "$LOOP" 2>/dev/null
rm -rf "$MOUNT_DIR" "$DIAG_IMG"

# ========== 汇总 ==========

echo ""
echo "=========================================="
echo "📈 诊断结果: 共 $((PASS+FAIL)) 项"
echo "   ✅ 通过: $PASS"
echo "   ❌ 失败: $FAIL"
echo "=========================================="

if [ $FAIL -eq 0 ]; then
    echo "🎉 全部通过"
    exit 0
else
    echo "⚠️  有 $FAIL 项失败，请检查上方明细"
    exit 1
fi
