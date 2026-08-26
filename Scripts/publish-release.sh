#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
repository_directory="${script_directory:h}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repository_directory/Packaging/Info.plist")"
tag="v$version"
artifact="$repository_directory/.build/releases/Media-Memory-${version}-arm64.dmg"
checksum="$artifact.sha256"

cd "$repository_directory"
if [[ -n "$(/usr/bin/git status --porcelain)" ]]; then
    print -u2 -- "工作区存在未提交改动，拒绝发布。"
    exit 1
fi
if [[ "$(/usr/bin/git branch --show-current)" != "main" ]]; then
    print -u2 -- "只能从 main 分支发布。"
    exit 1
fi
if gh release view "$tag" --repo NimbuSHh/media-memory >/dev/null 2>&1; then
    print -u2 -- "GitHub Release $tag 已存在，拒绝覆盖不可变发布。"
    exit 1
fi

"$script_directory/package-release.sh"

if /usr/bin/git rev-parse "$tag" >/dev/null 2>&1; then
    if [[ "$(/usr/bin/git rev-list -n 1 "$tag")" != "$(/usr/bin/git rev-parse HEAD)" ]]; then
        print -u2 -- "标签 $tag 已存在但不指向当前提交，拒绝发布。"
        exit 1
    fi
else
    /usr/bin/git tag -a "$tag" -m "Media Memory $version"
fi

if ! /usr/bin/git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
    /usr/bin/git push origin "$tag"
fi
gh release create "$tag" \
    "$artifact" \
    "$checksum" \
    --repo NimbuSHh/media-memory \
    --title "Media Memory $version" \
    --generate-notes
