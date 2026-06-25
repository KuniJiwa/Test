#!/bin/bash
# vmlinux-btf 注入脚本（挂载 img 方式）
# 用法: sudo ./inject-vmlinux-btf.sh <kernel_series>
# 先硬编码 6.6.y 版本跑通，后续再优化

set -e

KERNEL_SERIES="$1"
OUTPUT_DIR="/opt/openwrt_packit/output"
MOUNT_DIR="/mnt/firmware-inject"
BTF_DEST_DIR="/usr/lib/debug/boot"
ARCH="aarch64_cortex-a53"

echo "=========================================="
echo "🧬 vmlinux-btf 注入脚本（挂载 img 方式）"
echo "=========================================="
echo "内核系列: $KERNEL_SERIES"
echo "架构: $ARCH"
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

# 5. 下载 vmlinux-btf ipk
echo ""
echo "⬇️  下载 vmlinux-btf ipk..."

RELEASE_URL="https://github.com/kenzok8/vmlinux-btf/releases/download/latest"

# 先尝试用户提供的精确文件名
IPK_FILE="vmlinux-btf_6.6.141-r1_aarch64_cortex-a53.ipk"
IPK_URL="${RELEASE_URL}/${IPK_FILE}"

echo "尝试: $IPK_FILE"
if ! curl -sL --head "$IPK_URL" | grep -q "200 OK"; then
    echo "⚠️  精确文件名未找到，尝试其他格式..."
    
    # 尝试其他版本号格式
    FOUND=""
    for ver in "6.6.141" "6.6.140" "6.6.139" "6.6.0"; do
        TEST_FILE="vmlinux-btf_${ver}-r1_${ARCH}.ipk"
        TEST_URL="${RELEASE_URL}/${TEST_FILE}"
        echo "尝试: $TEST_FILE"
        if curl -sL --head "$TEST_URL" | grep -q "200 OK"; then
            IPK_FILE="$TEST_FILE"
            FOUND="yes"
            break
        fi
    done
    
    if [ -z "$FOUND" ]; then
        echo ""
        echo "❌ 未找到匹配的 vmlinux-btf ipk"
        echo "   Release 页面: https://github.com/kenzok8/vmlinux-btf/releases/tag/latest"
        umount "$MOUNT_DIR"
        losetup -d "$LOOP_DEV"
        rm -rf "$MOUNT_DIR"
        exit 1
    fi
fi

echo "✅ 找到 ipk: $IPK_FILE"

# 6. 下载并提取 ipk
TMP_DIR=$(mktemp -d)
echo ""
echo "📦 下载并提取 ipk..."

curl -sL "${RELEASE_URL}/${IPK_FILE}" -o "${TMP_DIR}/vmlinux-btf.ipk"

# IPK 是 tar.gz 格式，包含 control.tar.gz 和 data.tar.gz
cd "$TMP_DIR"
tar xzf vmlinux-btf.ipk 2>/dev/null || true

if [ ! -f data.tar.gz ]; then
    echo "❌ ipk 中未找到 data.tar.gz"
    echo "   ipk 内容:"
    tar tzf vmlinux-btf.ipk 2>/dev/null | head -20 || true
    umount "$MOUNT_DIR"
    losetup -d "$LOOP_DEV"
    rm -rf "$MOUNT_DIR" "$TMP_DIR"
    exit 1
fi

# 提取 data.tar.gz 到 rootfs
mkdir -p "${MOUNT_DIR}${BTF_DEST_DIR}"
tar xzf data.tar.gz -C "$MOUNT_DIR" 2>/dev/null || true

echo "✅ ipk 提取完成"

# 7. 验证文件
echo ""
echo "🔍 验证 vmlinux-btf 文件..."

# 查找提取出的 btf 文件
BTF_FOUND=""
for search_path in \
    "${MOUNT_DIR}${BTF_DEST_DIR}/vmlinux" \
    "${MOUNT_DIR}/usr/lib/debug/boot/vmlinux"* \
    "${MOUNT_DIR}/boot/"*btf* \
    "${MOUNT_DIR}/sys/kernel/btf/vmlinux"; do
    if [ -f "$search_path" ]; then
        BTF_FOUND="$search_path"
        break
    fi
done

# 也搜索一下
if [ -z "$BTF_FOUND" ]; then
    BTF_FOUND=$(find "$MOUNT_DIR" -name "vmlinux*" -type f 2>/dev/null | head -1)
fi

if [ -n "$BTF_FOUND" ]; then
    BTF_SIZE=$(stat -c%s "$BTF_FOUND" 2>/dev/null || echo 0)
    echo "✅ vmlinux-btf 已注入"
    echo "   路径: ${BTF_FOUND#$MOUNT_DIR}"
    echo "   大小: $BTF_SIZE bytes"
    
    # 确保在标准位置也有
    if [ "$BTF_FOUND" != "${MOUNT_DIR}${BTF_DEST_DIR}/vmlinux" ]; then
        mkdir -p "${MOUNT_DIR}${BTF_DEST_DIR}"
        cp "$BTF_FOUND" "${MOUNT_DIR}${BTF_DEST_DIR}/vmlinux" 2>/dev/null || true
        echo "   已复制到标准位置: ${BTF_DEST_DIR}/vmlinux"
    fi
else
    echo "❌ 未找到提取出的 vmlinux-btf 文件"
    echo "   提取的文件列表:"
    find "$MOUNT_DIR/usr/lib/debug" -type f 2>/dev/null | head -20 || true
    echo "   data.tar.gz 内容:"
    tar tzf data.tar.gz 2>/dev/null | head -20 || true
    umount "$MOUNT_DIR"
    losetup -d "$LOOP_DEV"
    rm -rf "$MOUNT_DIR" "$TMP_DIR"
    exit 1
fi

# 8. 清理临时文件
rm -rf "$TMP_DIR"

# 9. 卸载
echo ""
echo "📤 卸载并清理..."
umount "$MOUNT_DIR"
losetup -d "$LOOP_DEV"
rm -rf "$MOUNT_DIR"

# 10. 重新压缩（如果原来是 .gz）
if [ -n "$IMG_GZ" ]; then
    echo "📦 重新压缩固件..."
    gzip "$IMG_FILE"
fi

echo ""
echo "=========================================="
echo "✅ vmlinux-btf 注入完成"
echo "=========================================="
