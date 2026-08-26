#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
repository_directory="${script_directory:h}"
application="$repository_directory/.build/Media Memory.app"
release_directory="$repository_directory/.build/releases"
staging_directory="$repository_directory/.build/DMG-Staging"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repository_directory/Packaging/Info.plist")"
artifact_name="Media-Memory-${version}-arm64.dmg"
artifact="$release_directory/$artifact_name"

"$script_directory/build-app.sh"

/bin/rm -rf "$staging_directory"
/bin/mkdir -p "$staging_directory" "$release_directory"
/usr/bin/ditto "$application" "$staging_directory/Media Memory.app"
/bin/ln -s /Applications "$staging_directory/Applications"
/usr/bin/ditto "$repository_directory/LICENSE" "$staging_directory/LICENSE.txt"
/usr/bin/ditto "$repository_directory/Packaging/安装说明.txt" "$staging_directory/安装说明.txt"

/bin/rm -f "$artifact" "$artifact.sha256"
/usr/bin/hdiutil create \
    -volname "Media Memory" \
    -srcfolder "$staging_directory" \
    -ov \
    -format UDZO \
    "$artifact"
/bin/sh -c 'cd "$1" && /usr/bin/shasum -a 256 "$2" > "$2.sha256"' \
    sh "$release_directory" "$artifact_name"
/usr/bin/hdiutil verify "$artifact"
checksum_line="$(/bin/cat "$artifact.sha256")"
checksum="${checksum_line%% *}"
/usr/bin/sed "s/REPLACE_WITH_RELEASE_SHA256/$checksum/" \
    "$repository_directory/Packaging/Homebrew/media-memory.rb" \
    > "$release_directory/media-memory.rb"

print -r -- "$artifact"
print -r -- "$artifact.sha256"
print -r -- "$release_directory/media-memory.rb"
