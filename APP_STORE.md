# Publishing The Scrollinator on the Mac App Store

The project is set up so the App Store flavor is close to plug and play. `./build.sh appstore`
already produces a sandboxed, universal (Apple Silicon + Intel) app with:

- the App Sandbox and only the entitlements it needs (microphone, the Music folder, folders the user
  picks, security-scoped bookmarks);
- a privacy manifest (`Resources/PrivacyInfo.xcprivacy`) declaring no tracking and no data collected,
  plus the required-reason APIs it uses;
- `ITSAppUsesNonExemptEncryption = false`, a category, a copyright line and a build number that rises
  automatically;
- AAC (`.m4a`) recording with Apple's encoder, so no LGPL code (LAME) ships in the App Store build.

What's left happens in your Apple accounts. If you publish it, please make it free.

**Change the icon first.** The repo's icon is a parody featuring a real actor's likeness, which App
Review rejects without permission. Delete `Resources/AppIcon.png` to get the original pixel-art robot
icon instead (drawn by `scripts/make-icon.swift`), or replace it with your own square PNG.

## 1. Apple Developer setup (one time)

1. Join the **Apple Developer Program**.
2. **Register an App ID**: Identifiers → + → App IDs → App, with an explicit bundle ID you own, e.g.
   `com.yourname.scrollinator`. No extra capabilities are needed.
3. **Certificates** (Xcode → Settings → Accounts → Manage Certificates, or the developer website):
   - Apple Distribution (signs the app)
   - Mac Installer Distribution (signs the upload package)
4. **Provisioning profile**: Profiles → + → Mac App Store Connect, your App ID, your Apple Distribution
   certificate. Download it.

## 2. App Store Connect

1. My Apps → + → New App: platform macOS, a name that isn't taken (it doesn't have to be The
   Scrollinator), your bundle ID, any SKU.
2. **App Privacy**: "Data Not Collected". Nothing leaves the Mac.
3. **Category**: Productivity (secondary: Business or Video).
4. **Price**: Free, please.

## 3. Build and upload

```sh
BUNDLE_ID=com.yourname.scrollinator \
PROVISIONING_PROFILE=~/Downloads/YourProfile.provisionprofile \
./build.sh appstore
```

The script picks your Apple Distribution and Mac Installer Distribution certificates from the keychain,
embeds the profile, adds the team and app identifiers to the entitlements, and writes
`build.noindex/appstore/The Scrollinator.pkg`. Upload it with Apple's free **Transporter** app (drag the
.pkg in). Every upload needs a higher build number; the default (date and time) handles that. Set
`VERSION=1.0.1` and so on for releases.

Before uploading, run the sandboxed app once (`./build.sh appstore` without a profile signs it for
local testing; open `build.noindex/appstore/The Scrollinator.app`) and try: Start Prompting, read aloud,
turn on recording.

## 4. Notes for App Review (paste and adjust)

> The Scrollinator is a teleprompter that sits under the camera. In voice mode it listens to the
> microphone so the script scrolls while you speak, and optionally uses on-device speech recognition
> to keep your place in the script. Nothing is sent off the Mac. To try it: click the menu bar icon →
> Scripts…, choose the Welcome script, click Start Prompting, and read aloud. Global shortcuts
> (Control-Option-Space and others) use RegisterEventHotKey and need no special permission. "Hide
> from screen sharing" excludes the prompter window from screen capture so only the presenter sees
> it. Recording is off by default; when on, it saves to ~/Music/Scrollinator Recordings or a folder
> the user picks.

## 5. Listing copy (draft)

- **Subtitle** (30 max): `The teleprompter that hears you`
- **Promotional text**: Read your script right under the camera. The Scrollinator follows your voice,
  keeps your place when you ad-lib, and stays invisible on screen shares.
- **Keywords** (100 max):
  `teleprompter,prompter,script,autocue,presentation,video,camera,speech,notch,podcast,zoom,recording`
- **Description**:

  > The Scrollinator puts your script right under your camera, so you keep eye contact while you read.
  >
  > • Follows your words: on-device speech recognition keeps the text on your place at your natural
  >   pace. Speed up, slow down, re-read a line; it keeps up.
  > • Knows when you ad-lib: the waveform turns green on script and the text waits when you go off it.
  > • Voice-activated: moves while you talk, eases to a stop when you pause.
  > • Invisible on screen shares and screenshots: only you see it.
  > • Optional recording of every session.
  > • Shortcuts that work from any app.
  >
  > Private by design: no accounts, no tracking, and your voice never leaves your Mac.

- **Screenshots**: 16:10, e.g. 2880×1800 or 1440×900. Show the prompter over a video call, the green
  waveform and Settings. `docs/` has renders you can start from.

## Notes

- The direct build (`./build.sh`) stays non-sandboxed and records MP3 with LAME, which
  `scripts/build-lame.sh` downloads and compiles (LGPL). The App Store build leaves LAME out entirely.
- Following your words uses SpeechAnalyzer on macOS 26, which works whether or not Dictation is on.
  On macOS 14–15 it falls back to SFSpeechRecognizer, which needs Dictation turned on; Settings says so.
