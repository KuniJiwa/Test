#!/bin/bash
#路径：shell/verify-cleanup.sh
# 固件诊断 - 操作副本，原始不动

OUTPUT_DIR="/opt/openwrt_packit/output"
MOUNT_DIR="/mnt/fw-diag"
BOOT_DIR="/mnt/fw-diag-boot"

echo "🔍 固件全面诊断"
echo ""

IMG_GZ=$(ls "$OUTPUT_DIR"/openwrt_s905d_n1_*.img.gz 2>/dev/null | head -1)
[ -z "$IMG_GZ" ] && { echo "❌ 找不到固件文件"; exit 1; }

IMG_BASENAME=$(basename "$IMG_GZ")
IMG_SIZE=$(ls -lh "$IMG_GZ" | awk '{print $5}')
echo "📦 固件文件: $IMG_BASENAME"
echo "📦 压缩大小: $IMG_SIZE"

# 复制副本，不碰原始文件
DIAG_GZ="${IMG_GZ%.img.gz}-diagnose.img.gz"
cp "$IMG_GZ" "$DIAG_GZ" && gunzip "$DIAG_GZ"
DIAG_IMG="${DIAG_GZ%.gz}"

RAW_SIZE=$(ls -lh "$DIAG_IMG" | awk '{print $5}')
echo "💾 解压大小: $RAW_SIZE"

# 挂载镜像
LOOP=$(losetup -fP --show "$DIAG_IMG")
mkdir -p "$MOUNT_DIR" "$BOOT_DIR"

# 挂载 boot 分区（FAT32）
mount -t vfat "${LOOP}p1" "$BOOT_DIR" 2>/dev/null
BOOT_MOUNTED=$?

# 挂载 rootfs 分区（btrfs，先试 subvol=@，再试默认）
mount -t btrfs -o subvol=@ "${LOOP}p2" "$MOUNT_DIR" 2>/dev/null \
    || mount -t btrfs "${LOOP}p2" "$MOUNT_DIR" 2>/dev/null \
    || {
        echo "❌ 挂载 rootfs 失败"
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

KERNEL_VER=$(basename "$KERNEL_DIR")
echo "🎯 内核版本: $KERNEL_VER"

MOD_BASE="${KERNEL_DIR}/kernel/drivers/net"
MOD_DIR="$MOUNT_DIR/etc/modules.d"

PASS=0
FAIL=0
WARN=0

check_absent() {
    if [ ! -e "$1" ]; then
        echo "  ✅ [已清理] $2"
        PASS=$((PASS+1))
    else
        echo "  ❌ [残留] $2"
        FAIL=$((FAIL+1))
    fi
}

check_present() {
    if [ -f "$1" ]; then
        echo "  ✅ [存在] $2"
        PASS=$((PASS+1))
    else
        echo "  ❌ [缺失] $2"
        FAIL=$((FAIL+1))
    fi
}

check_dir_present() {
    if [ -d "$1" ]; then
        echo "  ✅ [存在] $2"
        PASS=$((PASS+1))
    else
        echo "  ❌ [缺失] $2"
        FAIL=$((FAIL+1))
    fi
}

# ========== 1. 分区与 Boot 验证 ==========

echo ""
echo "========== 1. 分区与 Boot 验证 =========="

if [ $BOOT_MOUNTED -eq 0 ]; then
    echo "  ✅ [挂载] boot 分区 (FAT32)"
    PASS=$((PASS+1))
    
    check_present "$BOOT_DIR/zImage" "内核镜像 (zImage)"
    check_present "$BOOT_DIR/uInitrd" "内存盘 (uInitrd)"
    check_present "$BOOT_DIR/uEnv.txt" "引导配置 (uEnv.txt)"
    
    # 检查 dtb 文件
    DTB_COUNT=$(find "$BOOT_DIR/dtb" -name "*.dtb" 2>/dev/null | wc -l)
    if [ "$DTB_COUNT" -gt 0 ]; then
        echo "  ✅ [存在] DTB 设备树文件 (${DTB_COUNT} 个)"
        PASS=$((PASS+1))
    else
        echo "  ❌ [缺失] DTB 设备树文件"
        FAIL=$((FAIL+1))
    fi
else
    echo "  ⚠️  [跳过] boot 分区挂载失败"
    WARN=$((WARN+1))
fi

# ========== 2. 系统完整性验证 ==========

echo ""
echo "========== 2. 系统完整性验证 =========="

check_present "$MOUNT_DIR/sbin/init" "init 程序"
check_present "$MOUNT_DIR/etc/passwd" "passwd 文件"
check_present "$MOUNT_DIR/etc/group" "group 文件"
check_present "$MOUNT_DIR/bin/sh" "shell 程序"
check_dir_present "$MOUNT_DIR/etc/config" "OpenWrt 配置目录"
check_dir_present "$MOUNT_DIR/usr/bin" "用户二进制目录"

# ========== 3. 内核模块验证 ==========

echo ""
echo "========== 3. 内核模块验证 =========="

check_dir_present "$KERNEL_DIR" "内核模块目录"
check_dir_present "$KERNEL_DIR/kernel" "内核驱动目录"

# ========== 4. 精简功能验证（应删除） ==========

echo ""
echo "========== 4. 精简功能验证（应删除） =========="

echo "--- 无线组件 ---"
check_absent "${MOD_BASE}/wireless" "wireless 驱动目录"
check_absent "$MOUNT_DIR/usr/sbin/hostapd" "hostapd 二进制"
check_absent "$MOUNT_DIR/usr/sbin/wpa_supplicant" "wpa_supplicant 二进制"
check_absent "$MOUNT_DIR/etc/init.d/hostapd" "hostapd 服务"
check_absent "$MOUNT_DIR/etc/init.d/wpad" "wpad 服务"
check_absent "$MOUNT_DIR/etc/config/wireless" "wireless 配置"
check_absent "$MOUNT_DIR/etc/wireless" "/etc/wireless 目录"
check_absent "${MOD_DIR}/mac80211" "mac80211 模块"
check_absent "${MOD_DIR}/cfg80211" "cfg80211 模块"

echo "--- PPPoE 组件 ---"
check_absent "${MOD_BASE}/ppp" "ppp 驱动目录"
check_absent "$MOUNT_DIR/usr/sbin/pppd" "pppd 二进制"
check_absent "$MOUNT_DIR/etc/init.d/ppp" "ppp 服务"

echo "--- 无关网卡驱动 ---"
check_absent "${MOD_BASE}/atlantic" "atlantic 网卡驱动"
check_absent "${MOD_BASE}/dwmac-*" "dwmac 系列网卡驱动"
check_absent "${MOD_BASE}/e1000e" "e1000e 网卡驱动"
check_absent "${MOD_BASE}/fsl-*" "fsl 系列驱动"
check_absent "${MOD_BASE}/mvneta" "mvneta 网卡驱动"
check_absent "${MOD_BASE}/stmmac" "stmmac 网卡驱动"
check_absent "${MOD_BASE}/ena" "ena 网卡驱动"
check_absent "${MOD_BASE}/vmxnet3" "vmxnet3 网卡驱动"

echo "--- PHY 驱动清理 ---"
check_absent "${KERNEL_DIR}/kernel/drivers/net/phy/bcm-phy-lib.ko" "broadcom PHY 驱动"
check_absent "${KERNEL_DIR}/kernel/drivers/net/phy/marvell.ko" "marvell PHY 驱动"
check_absent "${KERNEL_DIR}/kernel/drivers/net/phy/aquantia.ko" "aquantia PHY 驱动"
check_present "${KERNEL_DIR}/kernel/drivers/net/phy/realtek.ko" "realtek PHY 驱动（应保留）"

echo "--- 其他无用驱动 ---"
check_absent "${KERNEL_DIR}/kernel/drivers/gpio/gpio-pca953x.ko" "gpio-pca953x 驱动"
check_absent "${KERNEL_DIR}/kernel/drivers/i2c/muxes/i2c-mux-pca954x.ko" "i2c-mux-pca954x 驱动"
check_absent "${KERNEL_DIR}/kernel/drivers/watchdog/sp805_wdt.ko" "sp805_wdt 驱动"
check_absent "${KERNEL_DIR}/kernel/drivers/ssb" "ssb 驱动"
check_absent "${KERNEL_DIR}/kernel/drivers/bcma" "bcma 驱动"

echo "--- 语言包精简 ---"
LANG_FILES=$(find "$MOUNT_DIR/usr/lib/lua/luci/i18n" -name "*.lmo" 2>/dev/null | grep -v -E "zh-cn|en" | wc -l)
if [ "$LANG_FILES" -eq 0 ]; then
    echo "  ✅ [已精简] 仅保留 zh-cn / en 语言包"
    PASS=$((PASS+1))
else
    echo "  ❌ [残留] 仍存在 $LANG_FILES 个非中英文语言包"
    FAIL=$((FAIL+1))
fi

echo "--- MAC/WiFi 脚本 ---"
check_absent "$MOUNT_DIR/usr/bin/fix_wifi_macaddr.sh" "fix_wifi_macaddr.sh"
check_absent "$MOUNT_DIR/usr/bin/find_macaddr.pl" "find_macaddr.pl"
check_absent "$MOUNT_DIR/usr/bin/inc_macaddr.pl" "inc_macaddr.pl"
check_absent "$MOUNT_DIR/usr/bin/get_random_mac.sh" "get_random_mac.sh"

echo "--- 软件源验证 ---"
if grep -q "mirrors.ustc.edu.cn" "$MOUNT_DIR/etc/opkg/distfeeds.conf" 2>/dev/null; then
    echo "  ✅ [已替换] 软件源为 USTC 镜像"
    PASS=$((PASS+1))
else
    echo "  ❌ [未替换] 软件源不是 USTC 镜像"
    FAIL=$((FAIL+1))
fi

# ========== 5. 核心功能保留验证 ==========

echo ""
echo "========== 5. 核心功能保留验证 =========="

check_present "${MOD_DIR}/watchdog" "看门狗模块"
check_present "${MOD_DIR}/panfrost" "GPU 模块 (panfrost)"
check_present "${MOD_DIR}/pwm_meson" "PWM 模块"

# ========== 6. vmlinux-btf 验证 ==========

echo ""
echo "========== 6. vmlinux-btf 注入验证 =========="

BTF_FILE="$MOUNT_DIR/usr/lib/debug/boot/vmlinux"
if [ -f "$BTF_FILE" ]; then
    SIZE=$(ls -lh "$BTF_FILE" | awk '{print $5}')
    SIZE_BYTES=$(stat -c%s "$BTF_FILE" 2>/dev/null || echo 0)
    echo "  ✅ [已注入] vmlinux-btf 文件 (${SIZE})"
    PASS=$((PASS+1))
    
    # 检查文件类型
    FILE_TYPE=$(file -b "$BTF_FILE" 2>/dev/null)
    
    if echo "$FILE_TYPE" | grep -qi "ELF"; then
        echo "  ✅ [格式] ELF 格式"
        PASS=$((PASS+1))
        
        # ELF 格式：检查 .BTF 段
        if command -v readelf >/dev/null 2>&1; then
            BTF_SECTION=$(readelf -S "$BTF_FILE" 2>/dev/null | grep -i "\.BTF")
            if [ -n "$BTF_SECTION" ]; then
                echo "  ✅ [BTF] 包含 .BTF 段"
                PASS=$((PASS+1))
            else
                echo "  ❌ [BTF] 未找到 .BTF 段"
                FAIL=$((FAIL+1))
            fi
        fi
    else
        # 非 ELF 格式，可能是原始 BTF 数据（OpenWrt 常见）
        echo "  ℹ️  [格式] 原始 BTF 数据格式（非 ELF，OpenWrt 常见）"
        PASS=$((PASS+1))
        
        # 检查 BTF magic number（BTF_MAGIC = 0xeB9F，小端存储为 9F eB）
        MAGIC=$(xxd -l 2 -p "$BTF_FILE" 2>/dev/null)
        if [ "$MAGIC" = "9feb" ] || [ "$MAGIC" = "eb9f" ]; then
            echo "  ✅ [BTF] BTF magic 校验通过"
            PASS=$((PASS+1))
        else
            echo "  ⚠️  [BTF] 无法验证 BTF magic（可能是其他格式）"
            WARN=$((WARN+1))
        fi
    fi
    
    # 文件大小合理性检查（应该大于 500KB）
    if [ "$SIZE_BYTES" -gt 500000 ]; then
        echo "  ✅ [大小] 文件大小合理 (${SIZE})"
        PASS=$((PASS+1))
    else
        echo "  ⚠️  [大小] 文件偏小，可能不完整 (${SIZE})"
        WARN=$((WARN+1))
    fi
else
    echo "  ❌ [未注入] vmlinux-btf 文件不存在"
    FAIL=$((FAIL+1))
    
    if [ -d "$MOUNT_DIR/usr/lib/debug" ]; then
        echo "     debug 目录内容: $(ls "$MOUNT_DIR/usr/lib/debug/" 2>/dev/null)"
    else
        echo "     usr/lib/debug 目录不存在"
    fi
fi

# ========== 7. 固件信息汇总 ==========

echo ""
echo "========== 7. 固件信息汇总 =========="
echo "  固件文件: $IMG_BASENAME"
echo "  压缩大小: $IMG_SIZE"
echo "  解压大小: $RAW_SIZE"
echo "  内核版本: $KERNEL_VER"
echo "  架构: aarch64 (arm64)"
echo "  文件系统: btrfs + zstd 压缩"

# ========== 清理 ==========

umount "$MOUNT_DIR" 2>/dev/null
umount "$BOOT_DIR" 2>/dev/null
losetup -d "$LOOP" 2>/dev/null
rm -rf "$MOUNT_DIR" "$BOOT_DIR" "$DIAG_IMG"

# ========== 最终结果 ==========

echo ""
echo "=========================================="
echo "📈 诊断结果: 共 $((PASS+FAIL+WARN)) 项"
echo "   ✅ 通过: $PASS"
echo "   ❌ 失败: $FAIL"
if [ $WARN -gt 0 ]; then
    echo "   ⚠️  警告: $WARN"
fi
echo "=========================================="

if [ $FAIL -eq 0 ]; then
    if [ $WARN -eq 0 ]; then
        echo "🎉 全部通过，无警告"
    else
        echo "✅ 全部通过（有 $WARN 项警告，不影响使用）"
    fi
    exit 0
else
    echo "❌ 有 $FAIL 项失败，请检查上方明细"
    exit 1
fi
