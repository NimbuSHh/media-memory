#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
repository_directory="${script_directory:h}"
bundle_identifier="io.github.nimbushh.media-memory"
signing_identity="${MEDIA_MEMORY_SIGNING_IDENTITY:-Media Memory Release Signing}"
public_certificate="$repository_directory/Packaging/Signing/Media-Memory-Release-Signing.cer"
base_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$repository_directory/Packaging/Info.plist")"
next_build="$((base_build + 1))"
if [[ "$signing_identity" == "-" ]]; then
    print -u2 -- "稳定性验证拒绝使用 ad-hoc 签名。"
    exit 1
fi
identity_hash="$(
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/awk -F '"' -v identity="$signing_identity" \
            '$2 == identity { split($1, fields, " "); print tolower(fields[2]); exit }'
)"
if [[ -z "$identity_hash" ]]; then
    print -u2 -- "缺少代码签名身份：$signing_identity"
    exit 1
fi
temporary_directory="$(/usr/bin/mktemp -d /private/tmp/media-memory-signing-check.XXXXXX)"
cleanup() {
    /bin/rm -rf "$temporary_directory"
}
trap cleanup EXIT

build_copy() {
    local build_number="$1"
    local destination="$2"
    MEDIA_MEMORY_BUILD_NUMBER="$build_number" "$script_directory/build-app.sh" >/dev/null
    /usr/bin/ditto "$repository_directory/.build/Media Memory.app" "$destination"
    /usr/bin/codesign --verify --deep --strict "$destination"
}

first="$temporary_directory/Media Memory-$base_build.app"
second="$temporary_directory/Media Memory-$next_build.app"
build_copy "$base_build" "$first"
build_copy "$next_build" "$second"

bundle_version() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist"
}
[[ "$(bundle_version "$first")" == "$base_build" ]]
[[ "$(bundle_version "$second")" == "$next_build" ]]

requirement() {
    /usr/bin/codesign -d -r- "$1" 2>&1 \
        | /usr/bin/sed -n 's/^designated => //p'
}
authority() {
    /usr/bin/codesign -d --verbose=4 "$1" 2>&1 \
        | /usr/bin/sed -n 's/^Authority=//p' \
        | /usr/bin/head -1
}
first_requirement="$(requirement "$first")"
second_requirement="$(requirement "$second")"
first_authority="$(authority "$first")"
second_authority="$(authority "$second")"
baseline_certificate="$(/usr/bin/shasum -a 256 "$public_certificate" | /usr/bin/awk '{print $1}')"

[[ -n "$first_requirement" && "$first_requirement" == "$second_requirement" ]]
[[ -n "$first_authority" && "$first_authority" == "$second_authority" ]]
[[ -n "$baseline_certificate" ]]
if [[ "$first_requirement" != *"identifier \"$bundle_identifier\""* \
    || "$first_requirement" != *"certificate leaf = H\"$identity_hash\""* ]]; then
    print -u2 -- "Designated requirement 未绑定预期 Bundle ID 与证书指纹。"
    print -u2 -- "$first_requirement"
    exit 1
fi

print -r -- "Builds: $base_build and $next_build"
print -r -- "Authority: $first_authority"
print -r -- "Certificate baseline SHA-256: $baseline_certificate"
print -r -- "Designated requirement: $first_requirement"
print -r -- "Stable signing identity verified across consecutive builds."
