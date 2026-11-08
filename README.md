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

See [ROADMAP.md](ROADMAP.md) for planned backup encryption, local vault unlock
and release follow-up.

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

## Backup exchange (Android and desktop)

In **Settings > Backup exchange**, sign in with Google on each device and
press **Sync** to exchange compressed snapshots containing all training data
and referenced FIT files. An empty cloud history gets its first backup on
Sync. A new device with an existing cloud backup asks which snapshot to keep.
Garmin tokens and AI API keys are not included; sign in separately on each
device. Account tokens, file connections and revision baselines stay
device-local. Signing out of Google does not delete backups or training data.

Google uses the Drive API directly, not the installed Drive app or document
picker. Backups are hidden in FormForge's `appDataFolder`, accessible only to
this app under the same Google Cloud project. The app requests the narrow
`drive.appdata` permission, not access to other Drive files. Uploads create
immutable backup versions, preserving earlier data. Independent concurrent
uploads are detected and prompt for a snapshot to compare; an explicit
upload after this choice supersedes those heads without deleting them.
Backup versions currently accumulate in Drive and use the user's quota;
automatic pruning is not implemented. They are not WhatsApp/Android system
backups and cannot be opened from the ordinary Drive file list.

**This is backup/restore, not two-way merging.** A local-only change updates
the backup. A remote-only change prompts before replacing local data. When
both snapshots changed (or a new device connects), choose which to keep or
cancel. If cloud data is deleted externally, Sync fails explicitly; use
**Reset Google backup connection** to confirm starting a new history from the
current local data. This does not delete anything.

### File-based fallback

While signed out of Google, create `training.formforge` in a folder on desktop
or through Android's document picker, then connect the same file on the other
device. Existing file connections are preserved while signed in, but their
controls are hidden to prevent unintentionally exchanging with two destinations.
Desktop synced folders from OneDrive, Dropbox and Google Drive work as files.
Android file exchange requires persistent read/write access and advertised
write support; read-only cloud documents are rejected, not bypassed or treated
as bidirectional sync. Google account sign-in is the supported cloud route.
iOS cloud/file exchange is not implemented. OneDrive and Dropbox account
integrations are not implemented.

Snapshots are compressed but **not encrypted**: they contain sensitive
training, profile and GPS data. Keep them private. Before replacements, local
recovery copies are saved; restore them with **Restore local recovery backup**.
Recovery copies are not automatically deleted. Restore validates the current
backup format/schema and references, remaps FIT paths, and replaces database
rows in one transaction. It does not copy a live SQLite database file.
Missing original FIT files, invalid backups, revoked document permissions and
provider failures are surfaced in Settings, rather than silently dropping data.

For Google, **Sync** confirms the API upload and downloaded snapshot checksum.
For file exchange, it confirms document read/write verification, not completion
of the provider's cloud upload. If file access expires, reconnect the document.
Use one device at a time with file exchange and wait for the cloud app to finish
uploading. Provider caches and simultaneous file writes cannot be made reliably
conflict-free through file access alone. If a file write fails, preserve local
data and use recovery backups/provider version history or create a new file.
This version exchanges the complete snapshot on demand; it does not run in
the background.
The current expanded snapshot size limit is 512 MiB; an oversized export or
import fails explicitly.

### Google OAuth setup (maintainer)

No hosted FormForge server is required, but a Google Cloud project is:

1. Enable **Google Drive API**. Configure the Google Auth Platform consent
   screen/audience. During testing add the Google accounts that will use the
   app as test users. Add `drive.appdata`, `openid` and `email` scopes. Testing
   mode can expire offline grants; sign in again if authorization is revoked.
2. In this **same project**, create an **Android** OAuth client for
   `io.github.jpfeuffer.formforge` and the signing certificate's SHA-1.
   Register debug and release certificates separately if testing both builds.
3. Create a **Web application** OAuth client in that project. Its client ID is
   `GOOGLE_SERVER_CLIENT_ID`, required by Android Google Sign-In. No web
   backend, client secret, or redirect server is needed for the Android flow.
4. Create a **Desktop app** OAuth client in that project. Windows/Linux/macOS
   use its `GOOGLE_DESKTOP_CLIENT_ID` and `GOOGLE_DESKTOP_CLIENT_SECRET`, the
   system browser, PKCE/state, and a temporary loopback listener on
   `127.0.0.1`. macOS debug/release entitlements allow outgoing API requests
   and the local callback listener. Desktop clients are public installed apps: their distributed
   client secret cannot be kept confidential. Do not use a Web client secret.
   User refresh/access tokens are stored separately in OS secure storage.
5. In GitHub **Settings > Secrets and variables > Actions**, add repository
   variables `GOOGLE_SERVER_CLIENT_ID` and `GOOGLE_DESKTOP_CLIENT_ID`, and
   secret `GOOGLE_DESKTOP_CLIENT_SECRET`. The Android release and normal
   Android/Windows/macOS CI builds pass them as Dart defines. A build without
   these values still supports file exchange, but Google sign-in reports
   missing configuration instead of pretending to connect.

To upload these settings interactively with GitHub CLI, run:

```powershell
.\scripts\setup-google-oauth.ps1
```

The script prompts for the Web client ID, then a Desktop client JSON file path
or the Desktop ID and a hidden secret input. It sends the secret through stdin,
not command-line arguments, and replaces existing settings in `jpfeuffer/FormForge`.
You can pass `-DesktopClientJson 'C:\path\desktop-client.json'` to import a
downloaded Desktop credential without copying its secret. Never commit that
JSON. Save/download the Desktop secret before closing Google's creation dialog;
it may only be displayed once. The Web client secret is not used.

For local Windows builds:

Keep local credentials in the Git-ignored `.local` directory:
`google-desktop-client.json` is the downloaded Desktop OAuth JSON, and
`google-server-client-id.txt` contains the Web client ID. Then run:

```powershell
.\scripts\run-local.ps1
```

This generates an ignored `.local/google-defines.json` and passes its path to
Flutter, without putting the secret in command-line arguments. These local
files are plaintext credentials: keep them private and never force-add them
to Git. The run script does not upload anything or change GitHub settings.

Alternatively, with credentials already in environment variables:

```powershell
flutter run -d windows --dart-define="GOOGLE_DESKTOP_CLIENT_ID=$env:GOOGLE_DESKTOP_CLIENT_ID" --dart-define="GOOGLE_DESKTOP_CLIENT_SECRET=$env:GOOGLE_DESKTOP_CLIENT_SECRET"
```

For local Android builds, pass
`--dart-define="GOOGLE_SERVER_CLIENT_ID=$env:GOOGLE_SERVER_CLIENT_ID"`.
After configuring the project, test account sign-in/consent, restart and token
renewal, first upload, cross-device restore, conflict cancellation, and sign-out
on real devices. Builds/tests without OAuth credentials cannot verify Google's
live authorization or account storage. Debug installations do not silently
join a cloud account; connecting still requires Google sign-in/consent.
