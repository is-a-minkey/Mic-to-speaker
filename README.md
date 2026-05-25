# 📢 Megaphone — Real-Time Audio Passthrough App

A minimal Flutter app that routes your microphone directly to the speaker in real time.
Tap once to mute/unmute. Works in background and with screen locked.

---

## Architecture

```
Microphone (44.1 kHz, PCM-16, mono)
       │
       ▼
FlutterSoundRecorder ──► StreamController<Food> (broadcast)
                                    │
                                    ▼
                        FlutterSoundPlayer.feedFromStream()
                                    │
                                    ▼
                     Speaker / Bluetooth / Headphones
```

**AEC**: Android uses hardware AEC via `AudioSource.microphone`; iOS uses
`AVAudioSession` category `PlayAndRecord` (AEC applied automatically by CoreAudio).

---

## Prerequisites

| Tool          | Minimum version | Install guide                              |
|---------------|-----------------|--------------------------------------------|
| Flutter SDK   | 3.10.0          | https://docs.flutter.dev/get-started/install |
| Dart SDK      | 3.0.0           | bundled with Flutter                       |
| Android Studio| Hedgehog (2023) | for Android builds                         |
| Xcode         | 15.x            | for iOS builds (macOS only)                |

---

## 1 · Clone / Create the Project

```bash
# Create a new Flutter project
flutter create megaphone --org com.example --platforms android,ios
cd megaphone
```

---

## 2 · Install Dependencies

```bash
flutter pub get
```

---

## 3 · Android Setup

### 3a. Minimum SDK version

Open `android/app/build.gradle` and ensure:

```groovy
android {
    compileSdkVersion 34

    defaultConfig {
        minSdkVersion 23        // flutter_sound requires ≥ 23
        targetSdkVersion 34
        // ...
    }
}
```

### 3b. Kotlin version (if needed)

In `android/build.gradle`:

```groovy
buildscript {
    ext.kotlin_version = '1.9.10'
    // ...
}
```

### 3c. Permissions — already declared in AndroidManifest.xml

Key permissions used:

| Permission | Purpose |
|---|---|
| `RECORD_AUDIO` | Capture microphone input |
| `MODIFY_AUDIO_SETTINGS` | Route audio to speaker |
| `FOREGROUND_SERVICE` | Keep audio alive in background |
| `FOREGROUND_SERVICE_MICROPHONE` | Required on Android 14+ for mic in foreground service |
| `WAKE_LOCK` | Prevent CPU sleep during transmission |
| `BLUETOOTH_CONNECT` | Bluetooth headset audio output |

### 3d. Run on Android

```bash
# List available devices
flutter devices

# Run (replace <device-id> with your device)
flutter run -d <device-id>

# Release APK
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

---

## 4 · iOS Setup (macOS required)

### 4a. Set minimum deployment target

Open `ios/Podfile` and set:

```ruby
platform :ios, '14.0'
```

### 4b. Install CocoaPods

```bash
cd ios
pod install
cd ..
```

### 4c. Open in Xcode (for signing)

```bash
open ios/Runner.xcworkspace
```

In Xcode → Signing & Capabilities:
- Select your **Team**
- Verify Bundle Identifier is unique (e.g. `com.yourname.megaphone`)
- Confirm **Background Modes** → ✅ Audio, AirPlay, and Picture in Picture

### 4d. Run on iOS

```bash
flutter run -d <ios-device-id>

# Release IPA
flutter build ipa --release
```

---

## 5 · Key Files Reference

```
megaphone/
├── lib/
│   └── main.dart               ← Entire app (UI + audio engine)
├── android/
│   └── app/src/main/
│       └── AndroidManifest.xml ← Android permissions + foreground service
├── ios/
│   └── Runner/
│       └── Info.plist          ← iOS permissions + background audio modes
└── pubspec.yaml                ← Dependencies (flutter_sound, permission_handler)
```

---

## 6 · Tuning Latency

The buffer size is declared as a constant at the top of `main.dart`:

```dart
static const int _bufferSize = 4096;  // ~93 ms at 44.1 kHz
```

| Buffer size | Approx. latency | Notes |
|---|---|---|
| `8192` | ~186 ms | Most stable, no glitches |
| `4096` | ~93 ms  | **Default** — good balance |
| `2048` | ~46 ms  | Low latency; may glitch on older devices |
| `1024` | ~23 ms  | Very low; only for flagship hardware |

Decrease the value for lower latency. If you hear crackles or dropouts, increase it.

---

## 7 · Feedback / Echo Prevention

The app provides two layers of echo prevention:

1. **Hardware AEC** — requested from the OS on both platforms (enabled by default).
   Works best when you hold the device away from you or use earphones.

2. **Volume slider** — lower the output volume to reduce the chance of the
   speaker feeding back into the microphone when no earphones are used.

> **Best practice**: Use Bluetooth earphones or wired headphones. This physically
> separates input from output and eliminates feedback entirely.

---

## 8 · Troubleshooting

| Issue | Fix |
|---|---|
| No audio on Android | Ensure `minSdkVersion 23` in `build.gradle` |
| App crashes on Android 14 | Confirm `FOREGROUND_SERVICE_MICROPHONE` is in manifest |
| High-pitched feedback | Lower volume slider; use earphones |
| Permission dialog doesn't appear | Revoke microphone permission in device Settings and re-run |
| iOS pod install fails | `sudo gem install cocoapods`, then retry |
| `flutter_sound` build error on iOS | Run `pod repo update` then `pod install` again |

---

## License

MIT — do whatever you want with it.
