#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
repository_directory="${script_directory:h}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repository_directory/Packaging/Info.plist")"
tag="v$version"
artifact="$repository_directory/.build/releases/Media-Memory-${version}-arm64.dmg"
checksum="$artifact.sha256"
cask="$repository_directory/.build/releases/media-memory.rb"
release_notes="$repository_directory/Packaging/release-notes-v${version}.md"

cd "$repository_directory"
if [[ -n "$(/usr/bin/git status --porcelain)" ]]; then
    print -u2 -- "工作区存在未提交改动，拒绝发布。"
    exit 1
fi
if [[ ! -f "$release_notes" ]]; then
    print -u2 -- "缺少当前版本的已审阅 Release notes：$release_notes"
    exit 1
fi
if [[ "$(/usr/bin/git branch --show-current)" != "main" ]]; then
    print -u2 -- "只能从 main 分支发布。"
    exit 1
fi
release_commit="$(/usr/bin/git rev-parse HEAD)"
if ! gh auth status -h github.com >/dev/null 2>&1; then
    print -u2 -- "GitHub CLI 尚未登录或凭据已失效，拒绝创建标签。"
    exit 1
fi
remote_main="$(/usr/bin/git ls-remote origin refs/heads/main | /usr/bin/awk '{print $1}')"
if [[ -z "$remote_main" || "$release_commit" != "$remote_main" ]]; then
    print -u2 -- "当前 main 尚未完整推送到上游，拒绝发布。"
    exit 1
fi
if gh release view "$tag" --repo NimbuSHh/media-memory >/dev/null 2>&1; then
    print -u2 -- "GitHub Release $tag 已存在，拒绝覆盖不可变发布。"
    exit 1
fi

"$script_directory/verify-signing-stability.sh"
"$script_directory/package-release.sh"

if [[ -n "$(/usr/bin/git status --porcelain)" \
    || "$(/usr/bin/git rev-parse HEAD)" != "$release_commit" ]]; then
    print -u2 -- "构建期间工作区或 HEAD 已变化，拒绝给旧提交创建标签。"
    exit 1
fi
remote_main="$(/usr/bin/git ls-remote origin refs/heads/main | /usr/bin/awk '{print $1}')"
if [[ "$remote_main" != "$release_commit" ]]; then
    print -u2 -- "构建期间远端 main 已变化，拒绝发布。"
    exit 1
fi

if /usr/bin/git rev-parse "$tag" >/dev/null 2>&1; then
    if [[ "$(/usr/bin/git rev-list -n 1 "$tag")" != "$(/usr/bin/git rev-parse HEAD)" ]]; then
        print -u2 -- "标签 $tag 已存在但不指向当前提交，拒绝发布。"
        exit 1
    fi
else
    /usr/bin/git tag -a "$tag" -m "Media Memory $version"
fi

remote_tag_lines="$(/usr/bin/git ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}")"
remote_tag_commit="$(
    print -r -- "$remote_tag_lines" \
        | /usr/bin/awk -v peeled="refs/tags/$tag^{}" \
            '$2 == peeled { print $1; found = 1 } END { if (!found && NR == 1) print first } NR == 1 { first = $1 }'
)"
if [[ -n "$remote_tag_commit" && "$remote_tag_commit" != "$release_commit" ]]; then
    print -u2 -- "远端标签 $tag 已存在但不指向当前提交，拒绝发布。"
    exit 1
fi
if [[ -z "$remote_tag_commit" ]]; then
    /usr/bin/git push origin "$tag"
fi
gh release create "$tag" \
    "$artifact" \
    "$checksum" \
    "$cask" \
    --repo NimbuSHh/media-memory \
    --title "Media Memory $version" \
    --notes-file "$release_notes" \
    --verify-tag
