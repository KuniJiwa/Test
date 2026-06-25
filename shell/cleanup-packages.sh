#!/bin/bash
# 文件路径：shell/cleanup-packages.sh
# N1 旁路由固件编译后清理脚本，反向保留核心驱动，自动删除其余无用组件

set -euo pipefail

if [ -z "${GITHUB_WORKSPACE:-}" ]; then
    GITHUB_WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
fi

echo "========== 🔧 N1 固件后处理清理 =========="

ROOTFS_TAR=$(find ${GITHUB_WORKSPACE}/bin/targets/armsr/armv8/ -name "*rootfs.tar.gz" | head -1)

if [ -z "$ROOTFS_TAR" ] || [ ! -f "$ROOTFS_TAR" ]; then
    echo "❌ [失败] 未找到 rootfs.tar.gz，跳过清理"
    exit 0
fi

echo "📦 [信息] 找到 rootfs: $ROOTFS_TAR"

TMP_DIR="/tmp/rootfs_cleanup_$$"
mkdir -p "$TMP_DIR"
tar -xzf "$ROOTFS_TAR" -C "$TMP_DIR"
echo "✅ [成功] 解压完成"

trap 'rm -rf "$TMP_DIR"' EXIT

MODULES_DIR="$TMP_DIR/lib/modules"
KERNEL_VER=$(ls "$MODULES_DIR" | head -1)
MOD_PATH="$MODULES_DIR/$KERNEL_VER"
STATUS_FILE="$TMP_DIR/usr/lib/opkg/status"

# 通用函数：从 opkg 状态文件删除指定包记录
delete_pkg_record() {
    sed -i "/^Package: $1$/,/^$/d" "$STATUS_FILE"
}

# ==================== 1. 删除无线组件 ====================
echo ""
echo "========== 1. 删除无线组件 =========="

WIRELESS_DIR="$MOD_PATH/drivers/net/wireless"
[ -d "$WIRELESS_DIR" ] && rm -rf "$WIRELESS_DIR" && echo "  ✅ [成功] 已删除 wireless 目录"

for mod in mac80211 cfg80211 rfkill; do
    find "$MOD_PATH" -name "${mod}.ko*" -delete 2>/dev/null && echo "  ✅ [成功] 已删除模块: $mod" || true
done

rm -rf "$TMP_DIR/lib/firmware/brcm" 2>/dev/null && echo "  ✅ [成功] 已删除: brcm 固件" || true
rm -rf "$TMP_DIR/lib/firmware/rtl_"* 2>/dev/null && echo "  ✅ [成功] 已删除: rtl_* 固件" || true

for tool in hostapd wpa_supplicant wpa_cli hostapd_cli; do
    rm -f "$TMP_DIR/usr/sbin/$tool" 2>/dev/null && echo "  ✅ [成功] 已删除: $tool" || true
done

rm -rf "$TMP_DIR/usr/lib/hostapd" 2>/dev/null

for svc in wpad hostapd wpa_supplicant; do
    rm -f "$TMP_DIR/etc/init.d/$svc" 2>/dev/null && echo "  ✅ [成功] 已删除服务: $svc" || true
done

rm -rf "$TMP_DIR/etc/config/wireless" 2>/dev/null && echo "  ✅ [成功] 已删除无线配置" || echo "  ⚪ [跳过] 无线配置不存在"
rm -rf "$TMP_DIR/etc/wireless" 2>/dev/null && echo "  ✅ [成功] 已删除 /etc/wireless" || echo "  ⚪ [跳过] /etc/wireless 不存在"

# ==================== 2. 删除 PPPoE 组件 ====================
echo ""
echo "========== 2. 删除 PPPoE 组件 =========="

rm -rf "$MOD_PATH/drivers/net/ppp" 2>/dev/null && echo "  ✅ [成功] 已删除 PPPoE 内核模块目录" || true
rm -f "$TMP_DIR/usr/sbin/pppd" "$TMP_DIR/usr/sbin/pppoe-discovery" "$TMP_DIR/usr/bin/chat" 2>/dev/null && echo "  ✅ [成功] 已删除 PPP 工具" || true
rm -rf "$TMP_DIR/etc/ppp" 2>/dev/null
rm -f "$TMP_DIR/etc/init.d/ppp" 2>/dev/null && echo "  ✅ [成功] 已删除 /etc/init.d/ppp" || true

if [ -f "$STATUS_FILE" ]; then
    for pkg in ppp ppp-mod-pppoe kmod-ppp kmod-pppoe kmod-pppox; do
        delete_pkg_record "$pkg"
    done
    rm -f "$TMP_DIR/usr/lib/opkg/info/ppp"* 2>/dev/null
    echo "  ✅ [成功] 已从 opkg 数据库中移除 PPP 包记录"
fi

# ==================== 3. 删除无关网卡及虚拟化驱动 ====================
echo ""
echo "========== 3. 删除无关网卡及虚拟化驱动 =========="

KEEP_PATTERN="realtek|meson|amlogic|stmicro|usb"
BLACKLIST_KEYWORDS="atlantic bcmgenet dwmac e1000e fsl mvneta stmmac hyperv ena vmxnet3 octeontx2"

# 3.1 删除物理模块文件
for kw in $BLACKLIST_KEYWORDS; do
    count=$(find "$MOD_PATH" -type f -name "*${kw}*.ko*" -print -delete 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
        echo "  ✅ [成功] 已删除 $count 个包含关键字: ${kw} 的驱动"
    else
        echo "  ⚪ [跳过] 未找到包含关键字: ${kw} 的驱动"
    fi
done

# 3.2 net 目录逐文件甄别
if [ -d "$MOD_PATH/drivers/net" ]; then
    while IFS= read -r -d '' ko; do
        base=$(basename "$ko")
        if echo "$base" | grep -qE "$KEEP_PATTERN"; then
            echo "  ⚪ [保留] $base"
        else
            rm -f "$ko"
            echo "  ✅ [成功] 已删除: $base"
        fi
    done < <(find "$MOD_PATH/drivers/net" -type f -name "*.ko*" -print0 2>/dev/null)
else
    echo "  ⚪ [跳过] net 目录不存在"
fi

# 3.3 清理 opkg 残留记录
if [ -f "$STATUS_FILE" ]; then
    echo "  🔍 清理 opkg 中残留的 kmod 包记录..."
    for kw in $BLACKLIST_KEYWORDS; do
        sed -i "/^Package: kmod-.*${kw}.*$/,/^$/d" "$STATUS_FILE"
    done
    for pkg in kmod-amazon-ena kmod-octeontx2-net kmod-vmxnet3 kmod-gpio-pca953x kmod-i2c-mux-pca954x kmod-sp805-wdt kmod-mac80211 kmod-cfg80211 kmod-rfkill kmod-accessibility kmod-auxdisplay kmod-cb710 kmod-ssb kmod-bcma; do
        delete_pkg_record "$pkg"
    done
    tail -c1 "$STATUS_FILE" | read -r _ || echo >> "$STATUS_FILE"
    echo "  ✅ [成功] 已清理无用 kmod 包记录"
fi

# ==================== 4. 清理 PHY 驱动（仅保留 realtek） ====================
echo ""
echo "========== 4. 清理 PHY 驱动（仅保留 realtek） =========="

while IFS= read -r -d '' ko; do
    base=$(basename "$ko")
    if echo "$base" | grep -qi "^realtek"; then
        echo "  ⚪ [保留] PHY: $base"
    else
        rm -f "$ko"
        echo "  ✅ [成功] 已删除 PHY: $base"
    fi
done < <(find "$MOD_PATH" -type f -name "*phy*.ko*" -print0 2>/dev/null)

echo "  ⚪ [保留] realtek 开头的 PHY 驱动"

# ==================== 5. 删除其他无用杂项驱动 ====================
echo ""
echo "========== 5. 删除其他无用驱动 =========="

for dir in accessibility auxdisplay cb710 ssb bcma; do
    rm -rf "$MOD_PATH/drivers/$dir" 2>/dev/null && echo "  ✅ [成功] 已删除: $dir" || echo "  ⚪ [跳过] 目录不存在: $dir"
done

for mod in sp805_wdt gpio-pca953x i2c-mux-pca954x; do
    count=$(find "$MOD_PATH" -name "${mod}.ko*" -print -delete 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
        echo "  ✅ [成功] 已删除 $count 个 ${mod} 模块"
    else
        echo "  ⚪ [跳过] 未找到 ${mod} 模块"
    fi
done

echo "  ⚪ [保留] pps, ptp, macvlan, macsec, rtc-rx8025"

# ==================== 6. 精简系统文件 ====================
echo ""
echo "========== 6. 精简系统冗余文件 =========="

find "$TMP_DIR/usr/lib/lua/luci/i18n" -type f ! -name "*.zh-cn.lmo" ! -name "*.en.lmo" -delete 2>/dev/null
echo "  ✅ [成功] 已精简语言包（仅保留 zh-cn/en）"

rm -rf "$TMP_DIR/usr/share/man" "$TMP_DIR/usr/share/info" "$TMP_DIR/usr/share/doc" 2>/dev/null && echo "  ✅ [成功] 已删除帮助文档" || echo "  ⚪ [跳过] 帮助文档不存在"
rm -rf "$TMP_DIR/usr/include" "$TMP_DIR/usr/lib/pkgconfig" 2>/dev/null && echo "  ✅ [成功] 已删除开发文件" || echo "  ⚪ [跳过] 开发文件不存在"

find "$TMP_DIR" -name "*.a" -delete 2>/dev/null
echo "  ✅ [成功] 已删除静态库"

find "$TMP_DIR" -name "*.la" -delete 2>/dev/null
echo "  ✅ [成功] 已删除 libtool 文件"

# ==================== 修改软件源配置 ====================
DISTFEEDS="$TMP_DIR/etc/opkg/distfeeds.conf"

if [ -f "$DISTFEEDS" ]; then
    echo "🔧 修改软件源架构和镜像..."
    sed -i 's|/aarch64_generic/|/aarch64_cortex-a53/|g' "$DISTFEEDS"
    sed -i 's|downloads.immortalwrt.org|mirrors.ustc.edu.cn/immortalwrt|g' "$DISTFEEDS"
    echo "✅ 软件源已替换"
else
    echo "⚠️ 未找到 etc/opkg/distfeeds.conf，跳过"
fi

# ==================== 7. 重新打包 rootfs ====================
echo ""
echo "========== 7. 重新打包 rootfs =========="

cd "$TMP_DIR" || exit

OUT_DIR="$(dirname "$ROOTFS_TAR")"
mkdir -p "$OUT_DIR"

rm -f "$ROOTFS_TAR"

if tar --numeric-owner -czf "$ROOTFS_TAR" . ; then
    echo "✅ 打包成功"
else
    echo "❌ tar 打包失败"
    exit 2
fi

cd /

echo "✅ [成功] 清理结束，rootfs 已重新打包"
