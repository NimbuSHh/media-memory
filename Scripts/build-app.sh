#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
repository_directory="${script_directory:h}"
developer_directory="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cache_directory="$repository_directory/.build/PackagingCache"
/bin/mkdir -p \
    "$cache_directory/clang" \
    "$cache_directory/modules" \
    "$cache_directory/cache" \
    "$cache_directory/config" \
    "$cache_directory/security"
swift_arguments=(
    --disable-sandbox
    --cache-path "$cache_directory/cache"
    --config-path "$cache_directory/config"
    --security-path "$cache_directory/security"
)

cd "$repository_directory"
DEVELOPER_DIR="$developer_directory" \
CLANG_MODULE_CACHE_PATH="$cache_directory/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$cache_directory/modules" \
    /usr/bin/xcrun swift build -c release "${swift_arguments[@]}"
binary_directory="$(
    DEVELOPER_DIR="$developer_directory" \
    CLANG_MODULE_CACHE_PATH="$cache_directory/clang" \
    SWIFTPM_MODULECACHE_OVERRIDE="$cache_directory/modules" \
        /usr/bin/xcrun swift build -c release --show-bin-path "${swift_arguments[@]}"
)"

application="$repository_directory/.build/Media Memory.app"
contents="$application/Contents"
/bin/rm -rf "$application"
/bin/mkdir -p "$contents/MacOS" "$contents/Resources"
/usr/bin/install -m 755 "$binary_directory/MediaMemoryApp" "$contents/MacOS/MediaMemory"
/usr/bin/ditto "$binary_directory/MediaMemory_MediaMemoryCore.bundle" \
    "$contents/Resources/MediaMemory_MediaMemoryCore.bundle"
/usr/bin/plutil -convert binary1 -o "$contents/Info.plist" \
    "$repository_directory/Packaging/Info.plist"
/usr/bin/codesign --force --deep --sign - "$application"
/usr/bin/codesign --verify --deep --strict "$application"

print -r -- "$application"
