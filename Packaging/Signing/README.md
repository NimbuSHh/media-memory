# Release signing baseline

`Media-Memory-Release-Signing.cer` is the DER-encoded public leaf certificate
for the `Media Memory Release Signing` identity held in the release maintainer's
login Keychain. It contains no private key and is committed so every formal
build can reject a replacement signing identity.

The private key and encrypted `.p12` backup must never be placed here.
