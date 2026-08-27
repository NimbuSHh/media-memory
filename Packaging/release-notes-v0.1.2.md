Media Memory v0.1.2 introduces a stable self-signed App identity, lazy media-library authorization, explicit per-model authentication, and nonmodal background warnings. It also includes playback keyboard fixes and additional regression coverage.

Upgrade notes from v0.1.1:

- This is the one-time transition from an ad-hoc signature to the stable release identity. macOS may ask you to allow the App again in Privacy & Security.
- Media bookmarks are resolved only when scanning, processing, or playing. If an old authorization no longer works, right-click the original library and choose “重新授权”; indexed data is retained.
- Old model configurations did not record whether an endpoint used authentication. The App will keep local browsing and literal search available, while model indexing and semantic search pause until you confirm and save the authentication modes in Model Settings.
- If an old Keychain ACL cannot be read, re-enter the Bearer key and save. macOS may show a one-time authorization prompt while Media Memory rebuilds that Keychain item for the stable identity.

The App remains self-signed and is not Apple-notarized. The signing private key and encrypted backup are not included in the repository, DMG, or Release assets.
