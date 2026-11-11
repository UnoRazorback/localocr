# LocalOCR notarization credential reference

The release operator is Scott's MacBook Air (user `scott`). Credentials belong in macOS Keychain, not in source, chat, logs, or a separate assistant-managed vault.

- Keychain: `/Users/scott/Library/Keychains/login.keychain-db`
- Profile: `localocr-notary`
- Developer team: `DZ8B5454ZN`
- Validated and stored: 2026-09-12, through interactive Apple `notarytool` setup.

Before a release, check access without retrieving or displaying the password:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun notarytool history \
  --keychain-profile localocr-notary \
  --keychain /Users/scott/Library/Keychains/login.keychain-db \
  --output-format json
```

The default Keychain search also succeeded after setup. Existing release scripts use `LOCALOCR_NOTARY_PROFILE=localocr-notary`. Keep the pinned Xcode version aligned with the reviewed release toolchain.

If access fails, check the host/user, explicit Keychain path, lock/access state, profile presence, and Apple's authentication response before requesting replacement credentials. Do not equate a missing default-profile lookup with a revoked password. Do not export credentials to another machine.

Only if setup is actually required, open interactive Terminal on the MBA. Supply the team ID as a command option; the Developer Apple ID prompt takes the Apple account email, not the team ID. Scott enters the app-specific password privately. Verify access afterward and retain only this reference, never the secret.
