#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# A tiny executable self-test avoids SwiftPM's current CLT 27 macro-plugin
# mismatch for SwiftUI/Swift Testing while still exercising the MiniGoose core.
SWIFT_CACHE_PATH="$PWD/.build/spm-cache"
CLANG_CACHE_PATH="$PWD/.build/clang-module-cache"
mkdir -p "$SWIFT_CACHE_PATH" "$CLANG_CACHE_PATH"
export CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_PATH"
if [[ -n "${TOKENUSAGE_SWIFT_SDK:-}" ]]; then
    export SDKROOT="$TOKENUSAGE_SWIFT_SDK"
elif [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" && -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
fi
swift build --target TokenUsageSelfTest --cache-path "$SWIFT_CACHE_PATH"
.build/debug/TokenUsageSelfTest

if [[ "${1:-}" == "--live" ]]; then
    .build/debug/TokenUsageSelfTest --live
fi
