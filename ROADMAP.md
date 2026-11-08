# FormForge roadmap

This records the current direction, not a release schedule. Future items below
are plans, not features already available.

## Principles

- Local-first: no FormForge account server or hosted account database.
- Android APK distribution through CI; Google Play is not required yet.
- Prefer simple, safe backup exchange over a complex multi-device merge engine.
- Keep credentials device-local and out of Git.

## Implemented foundation

- [x] Signed Android APK builds and GitHub releases without a local Android SDK.
- [x] Compressed full snapshots containing training data and referenced FIT files.
- [x] File-based backup exchange, restore confirmation and local recovery copies.
- [x] Direct Google Drive sign-in and one-button snapshot exchange.
- [x] Preserve file connections, but expose file exchange only while signed out
  of Google.
- [x] Detect independent Google uploads and preserve competing backup versions.
- [x] Ignored project-local OAuth configuration and a Windows run script.

Google backup code has automated coverage and a Windows build; local sign-in
has been tried. It is not yet in the published APK. Backups and local recovery
copies are currently compressed but **not encrypted**.

## Next: validate and release Google backup

- [ ] Verify configured Android sign-in with the release signing certificate.
- [ ] Test phone-to-desktop upload/restore using the same Google account.
- [ ] Exercise restart/token renewal, consent denial, revoked access, offline
  errors, conflict cancellation and missing remote history on real devices.
- [ ] Confirm restores refresh the app and preserve device-local credentials.
- [ ] Commit, build and publish a new signed APK after validation.

## Planned: encrypted backups and local vault unlock

The desired experience is a password prompt when starting the app, combined
with encrypted backups. This is a **local vault**, not an online account.
Google sign-in authorizes storage access; it does not provide an encryption key.

### Encrypted snapshot format

- [ ] Compress first, then encrypt with authenticated encryption using a
  maintained cryptographic library.
- [ ] Define a versioned envelope with bounded password-derivation parameters,
  a random salt and unique encryption nonce. Never include the password or key.
- [ ] Use a suitably reviewed password-based key derivation scheme; verify its
  cost and compatibility on Android and desktop before choosing parameters.
- [ ] Encrypt Google backups, file exports and local recovery snapshots through
  the same shared format.
- [ ] Authenticate before applying data; reject wrong passwords, tampering,
  truncation and unsupported formats without modifying local data.
- [ ] Plan explicit migration of existing plaintext backups. Encrypting future
  uploads does not protect older cloud versions or recovery files.

### Startup and cross-device experience

- [ ] First device: create a vault password and confirm it.
- [ ] New device: allow Google sign-in and backup selection before vault setup;
  unlock the downloaded backup with the same password.
- [ ] Later launches: unlock with the password; optionally support biometric
  unlock backed by an OS-protected local key.
- [ ] Keep keys/passwords out of the training database, backups, logs and Git.
- [ ] Define password changes, cross-device key handling and recovery-key
  behavior before implementation. No server-based password reset is planned.
- [ ] Clearly warn that losing both the password and any recovery key means
  encrypted data cannot be recovered.

### Local data protection

- [ ] Decide and implement protection for the local database and FIT files.
  A startup screen alone does not encrypt data on disk.
- [ ] Account for decrypted temporary files, exports, cached keys and device
  lock behavior.
- [ ] Test encryption/restore across devices, wrong-password failures, recovery,
  migrations and interrupted operations before shipping.

## Later candidates, not commitments

- [ ] Backup history browsing and explicit retention/pruning controls. No
  automatic deletion until a safe policy and user consent are defined.
- [ ] More automated exchange triggers if needed, without silent replacement
  of local data or hiding conflicts.
- [ ] Direct OneDrive or Dropbox account integrations if demand justifies them.
  Read-only Android document-picker workarounds are not the cloud strategy.
- [ ] Revisit true record-level multi-device sync only if snapshot exchange
  becomes insufficient; merging is not currently planned.
- [ ] Validate additional platforms; iOS cloud/file exchange is not implemented.
- [ ] Consider Google Play distribution later.

See [README.md](README.md) for current setup, limitations and release commands.
