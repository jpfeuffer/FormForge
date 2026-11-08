# FormForge

Local-first running & strength training planner with Garmin sync. No server:
your data stays on your device, you bring your own Garmin account and AI key.

## Brand

![FormForge FF mark](assets/brand/formforge_mark.svg)

The app and platform launcher icons use this white-and-lime FF mark on navy.

- Adaptive running plans from target paces and past runs (VDOT, MAS, critical
  speed, LTHR), regular test runs, HR/pace evaluation.
- Garmin Connect sync (activities in, structured workouts + calendar out),
  FIT import as fallback.
- Strength/calisthenics sessions by focus area, scheduled alongside runs.

Targets: Android, Windows, macOS, iOS (Flutter).

## Development

```sh
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter test
(cd packages/training_core && dart test)
flutter run -d windows
```

Training science lives in [packages/training_core](packages/training_core)
(pure Dart, no Flutter).

## Android APK release

Release APKs must be signed with a private key. Create the key once and keep a
secure backup; losing it prevents signing updates that install over existing
copies of the app.

From the repository root, create a keystore (choose and securely record the
password when prompted):

```powershell
keytool -genkey -v -keystore android\upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias formforge
```

Create `android/key.properties` with the alias and passwords you chose:

```properties
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=formforge
storeFile=upload-keystore.jks
```

`android/key.properties` and keystore files are ignored by Git. Never commit or
share them. Build the signed APK from the repository root:

```powershell
flutter build apk --release
```

The APK is at `build\app\outputs\flutter-apk\app-release.apk`. Install and test
that exact build on a device before sharing it, including Garmin sync and
workout import/export. If neither `android/key.properties` nor release-signing
environment variables are configured, Gradle does not use the debug key, so
the resulting release APK is not suitable for distribution. The regular CI
workflow's `formforge-android-unsigned` APK is only for build verification.
Before each subsequent release, increment the build number in `pubspec.yaml`
(for example, change `0.1.0+1` to `0.1.1+2`).

### Build a signed APK with GitHub Actions

No Android Studio or Android SDK is needed on your computer. Create the
keystore once with `keytool` (a Java JDK tool). Windows does not include it by
default. If Java is not installed, download a Windows x64 JDK 17 ZIP from
[Eclipse Temurin](https://adoptium.net/temurin/releases/?version=17) and extract
it locally; no installer or PATH change is required. In PowerShell, use the
full path to `bin\keytool.exe` in the extracted JDK (replace the example path
below with your actual path):

```powershell
Set-Location E:\dev\FormForge
& "C:\Tools\jdk-17\bin\keytool.exe" -genkeypair -v -keystore "E:\dev\FormForge\android\upload-keystore.jks" -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias formforge
```

Use the same password for the keystore and key when prompted, and use that
password for both password secrets. Do not recreate an existing release key.
Then base64-encode the
`upload-keystore.jks` file and save that value as the repository Actions secret
`ANDROID_KEYSTORE_BASE64`. Add these other repository Actions secrets too:
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD`.
In GitHub, add them under **Settings > Secrets and variables > Actions**. Do
not put their values in workflow files or commit them.

On Windows PowerShell, you can base64-encode the keystore with:

```powershell
$keystorePath = (Resolve-Path .\android\upload-keystore.jks -ErrorAction Stop).Path
[Convert]::ToBase64String([IO.File]::ReadAllBytes($keystorePath)) | Set-Clipboard
```

Paste the clipboard value directly into the `ANDROID_KEYSTORE_BASE64` secret
form in GitHub; do not send it in chat or save it in the repository.

Run **Actions > Android release > Run workflow** on the branch you want to
release. Download the `formforge-android-release` artifact from that run and
test the APK before sharing it. The signing key is not included in the
artifact. Keep a secure backup of the original keystore; GitHub secrets alone
are not a replacement for that backup.

## Shared backup file (Android and desktop)

In **Settings > Shared backup file**, create `training.formforge` in a synced
folder on desktop, or create a document through Android's file picker. On the
other device, connect the same existing file. Press **Sync** to exchange
compressed snapshots containing all training data and referenced FIT files.
Garmin tokens and AI API keys are not included; sign in separately on each
device. The shared-file connection and revision baseline stay device-local.

OneDrive, Dropbox and Google Drive synced folders work as ordinary files on
desktop. Android clouds are not mounted paths: this feature remembers a
document URI with persistent read/write permission. Only providers exposing
writable documents through Android's picker can work; availability differs
by provider, app version and account. A provider that offers only sharing or
read-only documents cannot be used. No provider API registration is required.
iOS remembered cloud documents are not implemented.

**This is backup/restore, not two-way merging.** A local-only change updates
the shared backup. A remote-only change prompts before replacing local data.
When both snapshots changed (or a new device connects), choose which to keep
or cancel. Use one device at a time and wait for your cloud app's upload to
finish before switching devices. Provider caches and simultaneous writes
cannot be made reliably conflict-free through file access alone.

Snapshots are compressed but **not encrypted**: they contain sensitive
training, profile and GPS data. Keep them private. Before replacements, local
recovery copies are saved; restore them with **Restore local recovery backup**.
Recovery copies are not automatically deleted. Restore validates the current
backup format/schema and references, remaps FIT paths, and replaces database
rows in one transaction. It does not copy a live SQLite database file.
Missing original FIT files, invalid backups, revoked document permissions and
provider failures are surfaced in Settings, rather than silently dropping data.

The **Sync** status confirms document read/write verification, not completion
of the provider's cloud upload. If access expires, reconnect the same document.
If a write fails, preserve local data and recover the shared file using the
provider's version history or create a new shared file. This first version
exchanges the complete snapshot on demand; it does not run in the background.
The current expanded snapshot size limit is 512 MiB; an oversized export or
import fails explicitly.
