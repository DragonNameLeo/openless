#!/usr/bin/env bash
# Personal side-by-side build: "OpenLess Local" (com.openless.app.local), installed next to the
# official /Applications/OpenLess.app instead of replacing it.
#
# It gets its own identifier, data / log directories, Keychain service, macOS permissions and
# launch-at-login entry, and an empty updater feed, so the two apps never touch each other's
# state and the official updater can never overwrite it. A stable local signing identity keeps
# its microphone / accessibility grants and Keychain access across rebuilds.
#
# Usage (from anywhere):
#     openless-all/app/scripts/install-local-mac.sh             # build + install
#     INSTALL=0 openless-all/app/scripts/install-local-mac.sh   # build only
#     OPENLESS_SIGNING_IDENTITY="Other Name" openless-all/app/scripts/install-local-mac.sh

set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"

PRODUCT_NAME="OpenLess Local"
# Read at compile time by src-tauri (persistence::BUNDLE_ID / APP_DIR_NAME).
export OPENLESS_BUNDLE_ID="com.openless.app.local"
export OPENLESS_APP_DIR_NAME="${PRODUCT_NAME}"
APP="src-tauri/target/release/bundle/macos/${PRODUCT_NAME}.app"
INFO="${APP}/Contents/Info.plist"
DEST="/Applications/${PRODUCT_NAME}.app"
INSTALL="${INSTALL:-1}"

IDENTITY="${OPENLESS_SIGNING_IDENTITY:-OpenLess Local Signing}"
if security find-identity -p codesigning | grep -qF "\"${IDENTITY}\""; then
  export APPLE_SIGNING_IDENTITY="${IDENTITY}"
  echo "▶ 署名証明書: ${IDENTITY}"
else
  export APPLE_SIGNING_IDENTITY="-"
  echo "▶ 署名証明書「${IDENTITY}」が見つからないため ad-hoc 署名で続けます"
  echo "  （入れ替えのたびにマイクとアクセシビリティの許可を出し直す必要があります）"
fi

source scripts/macos-build-env.sh

CONFIG="$(printf '{"identifier":"%s","productName":"%s","plugins":{"updater":{"endpoints":[]}}}' \
  "${OPENLESS_BUNDLE_ID}" "${PRODUCT_NAME}")"

echo "▶ tauri build（${PRODUCT_NAME} / ${OPENLESS_BUNDLE_ID}）"
rm -rf "${APP}"
npm run tauri -- build --ci --bundles app --config "${CONFIG}" -- --locked

EXECUTABLE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "${INFO}")"
if [ ! -x "${APP}/Contents/MacOS/${EXECUTABLE}" ]; then
  echo "✗ ${APP} が見つからないか、今回のビルド結果ではありません"
  exit 1
fi
if [ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${INFO}")" != "${OPENLESS_BUNDLE_ID}" ]; then
  echo "✗ バンドル ID が ${OPENLESS_BUNDLE_ID} になっていません"
  exit 1
fi

echo "▶ Info.plist / 署名の確認"
bash scripts/check-macos-audio-usage-description.sh "${INFO}"
codesign -d --entitlements :- "${APP}" 2> /dev/null | grep -q "com.apple.security.device.audio-input"
codesign --verify --deep --strict --verbose=2 "${APP}" 2>&1 | tail -2
xattr -cr "${APP}" 2> /dev/null || true

if [ "${INSTALL}" = "1" ]; then
  echo "▶ ${DEST} に配置（公式の /Applications/OpenLess.app には触れません）"
  pkill -f "${PRODUCT_NAME}.app/Contents/MacOS/" 2> /dev/null || true
  sleep 1
  # Same rule as build-mac.sh: grants follow the designated requirement, so reset them only
  # when it changes (first install, or after switching certificates / ad-hoc).
  OLD_REQUIREMENT="$(codesign -d -r- "${DEST}" 2> /dev/null || true)"
  NEW_REQUIREMENT="$(codesign -d -r- "${APP}" 2> /dev/null || true)"
  if [ -z "${NEW_REQUIREMENT}" ] || [ "${OLD_REQUIREMENT}" != "${NEW_REQUIREMENT}" ]; then
    echo "▶ 署名の要件が変わったため、マイク / アクセシビリティの許可をリセット"
    tccutil reset Accessibility "${OPENLESS_BUNDLE_ID}" 2> /dev/null || true
    tccutil reset Microphone "${OPENLESS_BUNDLE_ID}" 2> /dev/null || true
  fi
  rm -rf "${DEST}"
  cp -R "${APP}" "${DEST}"
  xattr -dr com.apple.quarantine "${DEST}" 2> /dev/null || true
  echo "✓ 配置しました: ${DEST}"
  echo "  起動: open \"${DEST}\""
fi
