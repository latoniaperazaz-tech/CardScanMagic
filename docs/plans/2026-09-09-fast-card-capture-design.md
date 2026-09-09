# Fast Card Capture Tuning

## Goal

Tune the iPhone 14 Pro capture path for a stationary phone observing a fast
moving playing card. The camera should deliver a usable frame with minimal
motion smear as quickly as possible. This work changes capture only; it does
not train a model or add UI.

## Decision

Use the physical 1x wide camera instead of the virtual triple-camera device.
Prefer a 1920x1080 format at 120 fps and fall back to 60 fps when the selected
device does not expose that format. Keep video stabilization off because the
phone is stationary and stabilization cannot freeze subject motion.

Keep continuous auto exposure so the camera can adapt to the installation,
but cap the auto-exposure algorithm at approximately 1/500 second through
`activeMaxExposureDuration`. Clamp the requested duration to the active
format's supported exposure range. This deliberately trades brightness and
noise for shorter pip trails, so the physical setup requires strong diffuse
lighting.

Continuous near-range autofocus remains enabled for this pass. A fixed lens
position depends on the final card-to-camera distance and must be calibrated
on the actual phone before it can safely replace autofocus.

## Diagnostics

Log the selected device, dimensions, requested frame rate, exposure ceiling,
and stabilization mode when configuration completes. While scanning, emit a
rate-limited diagnostic line containing the delivered buffer dimensions,
actual frame interval, exposure duration, ISO, lens position, and focus and
exposure adjustment state. The log is diagnostic output only and is not shown
in the app UI.

## Failure Handling

If 1080p/120 is unavailable, select the best 1080p/60 format, then the largest
supported 120 or 60 fps format. If the requested exposure ceiling is outside
the active format's range, clamp it. Camera configuration failures retain the
existing 30 fps fallback and surface through the existing camera error path.

## Verification

Pure selection and clamping rules are kept deterministic and covered by unit
tests where practical. The project is generated after edits and repository
tests are run. A real iPhone is still required to verify active format,
exposure, ISO, focus behavior, thermals, and the number of sharp card frames.
The required acceptance recording is the original app camera stream, not a
messenger-compressed copy.
