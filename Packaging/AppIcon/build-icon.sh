#!/bin/zsh
set -euo pipefail

# 再生成应用图标：源图形在 make-app-icon.swift，产物入库的只有
# AppIcon.icns 与 AppIcon-1024.png，中间 iconset 留在临时目录。
script_directory="${0:A:h}"
temporary_directory="$(/usr/bin/mktemp -d /private/tmp/media-memory-appicon.XXXXXX)"
trap '/bin/rm -rf "$temporary_directory"' EXIT

/usr/bin/xcrun swift "$script_directory/make-app-icon.swift" "$temporary_directory"
/usr/bin/iconutil -c icns "$temporary_directory/AppIcon.iconset" \
    -o "$script_directory/AppIcon.icns"
/bin/cp "$temporary_directory/AppIcon-1024.png" "$script_directory/AppIcon-1024.png"

print -r -- "$script_directory/AppIcon.icns"
print -r -- "$script_directory/AppIcon-1024.png"
