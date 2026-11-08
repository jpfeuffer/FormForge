# FormForge

Local-first running & strength training planner with Garmin sync. No server:
your data stays on your device, you bring your own Garmin account and AI key.

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
