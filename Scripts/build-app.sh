#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
repository_directory="${script_directory:h}"
developer_directory="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
signing_identity="${MEDIA_MEMORY_SIGNING_IDENTITY:-Media Memory Release Signing}"
bundle_identifier="io.github.nimbushh.media-memory"
public_certificate="$repository_directory/Packaging/Signing/Media-Memory-Release-Signing.cer"
cache_directory="$repository_directory/.build/PackagingCache"
build_directory="$(/usr/bin/mktemp -d /private/tmp/media-memory-release.XXXXXX)"
cleanup_build_directory() {
    /bin/rm -rf "$build_directory"
}
trap cleanup_build_directory EXIT
/bin/mkdir -p \
    "$cache_directory/clang" \
    "$cache_directory/modules" \
    "$cache_directory/cache" \
    "$cache_directory/config" \
    "$cache_directory/security"
swift_arguments=(
    --disable-sandbox
    --scratch-path "$build_directory"
    --cache-path "$cache_directory/cache"
    --config-path "$cache_directory/config"
    --security-path "$cache_directory/security"
    -Xswiftc -file-prefix-map
    -Xswiftc "$repository_directory=."
    -Xswiftc -debug-prefix-map
    -Xswiftc "$repository_directory=."
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
if [[ -n "${MEDIA_MEMORY_BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c \
        "Set :CFBundleVersion $MEDIA_MEMORY_BUILD_NUMBER" "$contents/Info.plist"
fi
if [[ "$signing_identity" == "-" ]]; then
    identity_hash="-"
    signing_description="ad-hoc development signature"
    signing_requirements=()
else
    identity_hash="$(
        /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
            | /usr/bin/awk -F '"' -v identity="$signing_identity" \
                '$2 == identity { split($1, fields, " "); print tolower(fields[2]); exit }'
    )"
    if [[ -z "$identity_hash" ]]; then
        print -u2 -- "缺少代码签名身份：$signing_identity"
        print -u2 -- "正式发布只能在持有该身份私钥的发布者 Mac 上执行。"
        exit 1
    fi
    if [[ ! -f "$public_certificate" ]]; then
        print -u2 -- "缺少公开发布证书基线：$public_certificate"
        print -u2 -- "请先安全创建或恢复发布身份；正式构建不接受未固定的新证书。"
        exit 1
    fi
    baseline_hash="$(/usr/bin/shasum -a 1 "$public_certificate" | /usr/bin/awk '{print $1}')"
    if [[ "$identity_hash" != "$baseline_hash" ]]; then
        print -u2 -- "钥匙串签名身份与仓库中的公开证书基线不匹配。"
        print -u2 -- "Expected: $baseline_hash"
        print -u2 -- "Actual:   $identity_hash"
        exit 1
    fi
    login_keychain="$(
        /usr/bin/security default-keychain -d user \
            | /usr/bin/awk -F '"' 'NF >= 2 { print $2; exit }'
    )"
    signing_certificate_pem="$build_directory/signing-certificate.pem"
    signing_certificate_der="$build_directory/signing-certificate.cer"
    /usr/bin/security find-certificate -c "$signing_identity" -p "$login_keychain" \
        > "$signing_certificate_pem"
    /usr/bin/openssl x509 -in "$signing_certificate_pem" -outform DER \
        -out "$signing_certificate_der"
    if ! /usr/bin/cmp -s "$public_certificate" "$signing_certificate_der"; then
        print -u2 -- "钥匙串中的发布证书与仓库 DER 基线不一致。"
        exit 1
    fi
    signing_description="$signing_identity ($identity_hash)"
    signing_requirements=(
        --requirements
        "=designated => identifier \"$bundle_identifier\" and certificate leaf = H\"$identity_hash\""
    )
fi
/usr/bin/codesign \
    --force \
    --identifier "$bundle_identifier" \
    "${signing_requirements[@]}" \
    --sign "$identity_hash" \
    --timestamp=none \
    "$application"
/usr/bin/codesign --verify --deep --strict "$application"
if [[ "$identity_hash" != "-" ]]; then
    actual_requirement="$(
        /usr/bin/codesign -d -r- "$application" 2>&1 \
            | /usr/bin/sed -n 's/^designated => //p'
    )"
    if [[ "$actual_requirement" != *"identifier \"$bundle_identifier\""* \
        || "$actual_requirement" != *"certificate leaf = H\"$identity_hash\""* ]]; then
        print -u2 -- "App 的 designated requirement 未绑定公开证书基线。"
        exit 1
    fi
fi

print -r -- "Signing identity: $signing_description"
print -r -- "$application"
