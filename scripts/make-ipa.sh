#!/bin/bash
# 把 .xcarchive 打成未签名 IPA。
# 用法：make-ipa.sh <archive_path(不带.xcarchive)> <输出文件名>
#   例：make-ipa.sh archive LiveContainer.ipa
set -euo pipefail

ARCHIVE="${1:-archive}"
OUT="${2:-LiveContainer.ipa}"
APP_DIR="${ARCHIVE}.xcarchive/Products/Applications"

if [ ! -d "$APP_DIR" ]; then
  echo "找不到 ${APP_DIR}，archive 阶段可能失败了" >&2
  exit 1
fi

rm -rf Payload "$OUT"
mv "$APP_DIR" Payload

# strip 瘦身：-S 保留导出符号，-x 删本地符号。运行期用不到本地符号，
# 但崩溃堆栈会变成裸地址。STRIP_SYMBOLS=false 可跳过。
if [ "${STRIP_SYMBOLS:-false}" = "true" ]; then
  echo "==> strip 瘦身"
  find Payload -type f | while IFS= read -r f; do
    if file "$f" | grep -q "Mach-O"; then
      strip -S -x "$f" 2>/dev/null || true
    fi
  done
else
  echo "==> 跳过 strip"
fi

# 上游 build_github.sh 的单版本逻辑就是先把 SideStoreSupport.framework 移走再 zip，
# 之后还原用于打包二合一版。本仓库只出单版本，直接删掉即可，产物与上游 LiveContainer.ipa 等价。
SS="Payload/LiveContainer.app/Frameworks/SideStoreSupport.framework"
if [ -d "$SS" ]; then
  echo "==> 移除 SideStoreSupport.framework"
  rm -rf "$SS"
fi

# -y 保留符号链接，iOS 的 .app 里不能没有它
zip -9 -qry "$OUT" Payload -x "._*" -x ".DS_Store" -x "__MACOSX/*"

rm -rf Payload

echo "==> 产物："
ls -lh "$OUT"
shasum -a 256 "$OUT"
