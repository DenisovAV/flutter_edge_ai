# Download Testing Guide

Manual testing guide for large model downloads, including reproduction of issue #192
(Android download timeout on slow connections).

---

## Issue #192: Android 9-minute timeout on slow connections

### Root cause

`background_downloader` uses Android WorkManager internally. `TaskRunner` has a hard
9-minute internal timeout that applies to **all** workers, including foreground service workers.
`foreground: true` does NOT bypass this limit — it only prevents the OS from killing the
process due to battery optimization. On slow connections (< 2 Mbps), downloading a 2.6 GB
model takes > 9 minutes → `TaskConnectionException: Task timed out`.

(#356: `SmartDownloader` now calls `configureNotification` when `foreground: true` so the
foreground service actually activates — previously `foreground: true` set the config flag but
never registered a notification, so `setForeground()` was never called. #357 review: on
Android 13+ (API 33) a notification alone is still not enough — `setForeground()` is only
reached if `POST_NOTIFICATIONS` is granted at RUNTIME, so `SmartDownloader` now also requests
that permission automatically before a foreground download. Layer 3: on Android 14+ (API 34+),
`setForeground()` additionally throws `IllegalArgumentException: foregroundServiceType ... is
not a subset of ...` unless the HOST APP declares `FOREGROUND_SERVICE_DATA_SYNC` and a
`tools:node="merge"` override of `foregroundServiceType="dataSync"` on WorkManager's
`SystemForegroundService` in its own manifest — see the README's Foreground Service section
and `example/android/app/src/main/AndroidManifest.xml`. This is host-app responsibility, not
something flutter_edge_ai adds automatically. None of these fixes change the 9-minute
`TaskRunner` limit described above.)

### Why `allowPause` doesn't help

HuggingFace CDN returns **weak ETags** (`W/"..."`). `background_downloader` refuses to resume
a partial download if the ETag is weak (both Android and Desktop implementations check this).
So even if allowPause were enabled for HF URLs, the resume would be rejected and the download
would restart from byte 0 — making the situation worse.

### Potential fix: `ParallelDownloadTask`

`background_downloader` supports splitting a download into parallel chunks
(`ParallelDownloadTask`). This bypasses the 9-minute timeout because each chunk is a
separate task with its own timer. Requirements:

- Server must support `Accept-Ranges: bytes` ✅ (HF CDN does)
- Server must return `Content-Length` ✅ (HF CDN does after redirect)
- Each chunk must complete within 9 minutes

The CDN contract integration tests (Group A in `download_reliability_test.dart`) verify
that these prerequisites are met for HuggingFace URLs.

---

## Reproducing issue #192

### Requirements

- Android device (physical)
- Slow WiFi connection (< 2 Mbps sustained) or network throttling
- Model > 2 GB (e.g., Gemma 4 E2B IT ~2.6 GB)
- HuggingFace token (for gated models)

### Steps

1. Connect device to throttled network
2. Run the download reliability tests:
   ```bash
   flutter test integration_test/download_reliability_test.dart \
     -d <device_id> \
     --dart-define=HF_TOKEN=<your_token> \
     2>&1 | tee /tmp/download_test.log
   ```
3. Observe: download starts, reaches ~70–90%, then fails with:
   ```
   TaskConnectionException: Task timed out
   ```
4. Note: progress may reset to 0% and retry — this is the "silent restart" behavior
   (Group B test B2 catches this regression)

### Expected after fix

Download completes or uses chunked parallel download that avoids the 9-minute limit.

---

## Network throttling

### Android emulator (Linux/macOS host)

Add traffic shaping via `adb shell` (requires root or emulator):
```bash
# Throttle to 2 Mbps
adb shell tc qdisc add dev eth0 root tbf rate 2mbit burst 32kbit latency 400ms

# Remove throttling
adb shell tc qdisc del dev eth0 root
```

### Android device via WiFi router

Use router QoS settings to limit bandwidth for the device's MAC address to 2 Mbps.

### Android Developer Options (Android 8+)

Some devices have "Simulated network conditions" in Developer Options (requires Wireless
ADB). This option is device/manufacturer-specific.

### macOS Network Link Conditioner

Useful for testing on iOS/macOS. Install via Xcode → Additional Tools → Network Link
Conditioner.prefPane. Set profile to "Edge" (240 Kbps) or create a custom profile.

---

## Running only CDN contract tests (CI-friendly, no device needed)

Group A tests use only HEAD requests — no model download, no device required.
They can run on any host with internet access:

```bash
# These tests can run on any Flutter-supported platform
flutter test integration_test/download_reliability_test.dart \
  --name "HuggingFace CDN contract" \
  -d macos \
  2>&1 | tee /tmp/cdn_contract_test.log
```

Expected output:
```
[CDN] Accept-Ranges: bytes
[CDN] Content-Length: 297893376
[CDN] Model size: 284.1 MB
[CDN] ETag: W/"..."
[CDN] ETag is WEAK
[CDN] KNOWN LIMITATION (issue #192): weak ETag prevents background_downloader from
      resuming interrupted downloads. timeout → fail → full restart from byte 0.
```

---

## Test matrix

| Test group | Android | iOS | macOS/Win/Linux | CI |
|------------|---------|-----|-----------------|-----|
| A: CDN contract | ✅ | ✅ | ✅ | ✅ |
| B: Download behavior | ✅ | ✅ | ✅ | ⚠️ needs network |
| C: Foreground service | ✅ | ❌ skip | ❌ skip | ❌ skip |

CI note: Group A runs fast (HEAD-only, ~2s per test). Group B requires downloading 284 MB.
