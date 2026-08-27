cask "media-memory" do
  version "0.1.2"
  sha256 "REPLACE_WITH_RELEASE_SHA256"

  url "https://github.com/NimbuSHh/media-memory/releases/download/v#{version}/Media-Memory-#{version}-arm64.dmg"
  name "Media Memory"
  desc "Local-first evidence-based video search for macOS"
  homepage "https://github.com/NimbuSHh/media-memory"

  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "Media Memory.app"

  caveats <<~EOS
    Media Memory uses a stable self-signed identity and is not notarized by Apple. On
    first launch, macOS may require approval in System Settings > Privacy & Security.
    When upgrading from v0.1.1, confirm model authentication in Settings and reauthorize
    an existing media library from its context menu if macOS no longer accepts the old grant.
  EOS

  zap trash: [
    "~/Library/Application Support/MediaMemory",
    "~/Library/Preferences/io.github.nimbushh.media-memory.plist",
  ]
end
