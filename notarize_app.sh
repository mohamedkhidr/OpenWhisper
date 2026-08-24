#!/bin/bash
set -e

# === Configuration Variables ===
APP_NAME="OpenSuperWhisper"                                   
APP_PATH="./build/Build/Products/Release/OpenSuperWhisper.app"                        
ZIP_PATH="./build/OpenSuperWhisper.zip"                        
BUNDLE_ID="ru.starmel.OpenSuperWhisper"                       
KEYCHAIN_PROFILE="Slava"
CODE_SIGN_IDENTITY="${1}"
DEVELOPMENT_TEAM="8LLDD7HWZK"

rm -rf libwhisper/build
cmake -G Xcode -B libwhisper/build -S libwhisper

rm -rf build
mkdir -p build

# Homebrew installs to /opt/homebrew on Apple Silicon and /usr/local on Intel.
LIBOMP_PREFIX=$(brew --prefix libomp 2>/dev/null)
if [[ -z "$LIBOMP_PREFIX" ]]; then
    echo "libomp not found via Homebrew! Run 'brew install libomp'."
    exit 1
fi

echo "Copying libomp.dylib..."
cp "${LIBOMP_PREFIX}/lib/libomp.dylib" ./build/libomp.dylib
install_name_tool -id "@rpath/libomp.dylib" ./build/libomp.dylib
codesign --force --sign "${CODE_SIGN_IDENTITY}" --timestamp ./build/libomp.dylib

# Builds for the host machine's architecture — produces an arm64 DMG on
# Apple Silicon and an x86_64 DMG on Intel. Not a universal binary.
HOST_ARCH=$(uname -m)

xcodebuild \
  -scheme "OpenSuperWhisper" \
  -configuration Release \
  -destination "platform=macOS,arch=${HOST_ARCH}" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY}" \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  -derivedDataPath build \
  build | xcpretty --simple --color

rm -f "${ZIP_PATH}"

current_dir=$(pwd)
cd $(dirname "${APP_PATH}") && zip -r -y "${current_dir}/${ZIP_PATH}" $(basename "${APP_PATH}")
cd "${current_dir}"

xcrun notarytool submit "${ZIP_PATH}" --wait --keychain-profile "${KEYCHAIN_PROFILE}"

xcrun stapler staple "${APP_PATH}"

swifty-dmg --skipcodesign "${APP_PATH}" --output "${APP_NAME}.dmg" --verbose

codesign --sign "${CODE_SIGN_IDENTITY}" "${APP_NAME}.dmg"
xcrun notarytool submit "${APP_NAME}.dmg" --wait --keychain-profile "${KEYCHAIN_PROFILE}"
xcrun stapler staple "${APP_NAME}.dmg"  

echo "Successfully notarized ${APP_NAME}"
