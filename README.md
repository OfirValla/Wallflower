# Aura Display

An open-source kiosk browser and device-management app for Android. Turns a
wall-mounted tablet into an always-on, locked-down smart-home dashboard with
two-way Home Assistant control.

A modern alternative to Fully Kiosk Browser: Flutter UI, Kotlin platform layer,
MQTT auto-discovery, and camera-based motion wake that costs under 1% of a core.

## Features

- **Fullscreen kiosk WebView** — immersive mode, custom User-Agent, local
  caching, opt-in self-signed SSL, crash recovery, network-restore reload,
  periodic reload
- **Real lockdown** — Device Owner Lock Task: HOME and RECENTS dead, status bar
  disabled by policy, keyguard suppressed, uninstall blocked. Degrades
  gracefully to screen pinning and then plain immersive mode
- **Motion wake** — front-camera Y-plane frame differencing via CameraX, with
  ambient light/proximity fallback. Wakes the display natively, before Dart is
  involved
- **Smart display power** — dim-with-overlay (instant wake) or real device lock,
  idle timeout, window- or system-scoped brightness
- **Home Assistant, two ways** — MQTT auto-discovery (12 entities) *or* a local
  REST API for installs with no broker
- **`window.Aura` JS bridge** — drive the kiosk from a dashboard button card

## Home Assistant entities

Screen (light, with brightness) · Motion (binary_sensor) · Motion detection
(switch) · Battery · Charging · Illuminance · Current URL · Kiosk locked ·
Reload (button) · Bring to foreground (button) · Navigate to (text) · Speak
(notify)

Commands: `screen_on`, `screen_off`, `set_brightness`, `navigate_to`, `reload`,
`load_start_url`, `bring_to_foreground`, `play_audio`, `set_motion_detection`,
`eval_js`.

## Getting started

Requires Flutter 3.27+ and JDK 17.

```bash
# 1. Restore the Gradle wrapper and local.properties that flutter create
#    generates. Commit first, because the template will overwrite some of the
#    files in this repo; the checkout afterwards puts them back and keeps only
#    the new, untracked wrapper files.
git add -A && git commit -m "wip"
flutter create . --platforms=android --org com.auradisplay --project-name aura_display
git checkout -- .

# 2. Build and run
flutter pub get
flutter run --release          # release: debug builds stutter with a full-screen WebView
```

Then, on the device: tap the **top-left corner four times** within three seconds
and enter the PIN (`1234` by default) to open the admin panel. Set the start URL
and — if you use MQTT — the broker details.

### Provisioning real kiosk mode

Levels 1 and 2 need nothing. Level 3 (the only one that cannot be escaped)
requires Device Owner, which requires a device with **zero** accounts:

```bash
# Factory reset, skip Google account setup, enable USB debugging, then:
adb install build/app/outputs/flutter-apk/app-release.apk
adb shell dpm set-device-owner com.auradisplay.kiosk/.kiosk.AuraDeviceAdminReceiver

# Optional: pre-grant the overlay permission used by the non-Device-Owner
# status-bar fallback
adb shell appops set com.auradisplay.kiosk SYSTEM_ALERT_WINDOW allow
```

Set Aura as the device Home app (admin panel → **Set as Home app**) so the HOME
key is a no-op and the dashboard auto-starts after a power cut.

To hand the device back: admin panel → **Exit kiosk**, then
`adb shell dpm remove-active-admin com.auradisplay.kiosk/.kiosk.AuraDeviceAdminReceiver`.

### Local REST API

```bash
curl -H "authorization: Bearer 1234" http://<tablet-ip>:2323/api/state
curl -H "authorization: Bearer 1234" -H "content-type: application/json" \
     -d '{"command":"navigate_to","url":"http://ha.local:8123/lovelace/kitchen"}' \
     http://<tablet-ip>:2323/api/command
```

The bearer token **is** the admin PIN. Change it from `1234` before putting a
device on a shared network, or turn the REST server off and use MQTT only.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the system design, the Dart/Kotlin
split and why it falls where it does, the channel contract, the motion-detection
rationale, the Android 12→15 foreground-service rules, and a milestone-by-
milestone implementation roadmap.

Short version: Flutter owns the UI, settings, MQTT/REST and command semantics.
Kotlin owns everything with no Dart API — Device Owner policy, Lock Task,
CameraX frame analysis, display power, the foreground service. They meet at one
`MethodChannel` plus one `EventChannel`, both defined in `AuraChannels.kt` and
consumed only by `lib/platform/aura_platform.dart`.

## Status

Early. The architecture and the platform layer are complete and documented; the
milestones in ARCHITECTURE.md §11 are the order to bring it up and verify it on
real hardware.

## License

MIT (add a `LICENSE` file before publishing).
