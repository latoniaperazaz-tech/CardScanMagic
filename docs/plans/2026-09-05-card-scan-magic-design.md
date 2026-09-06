# CardScanMagic First-Version Design

## Purpose

Record the identity and deal order of face-up playing cards passing over an
iPhone 14 Pro placed screen-down on a table. The result is viewed when the
performer turns the phone over after dealing.

## Agreed interaction

- The phone screen faces the table; the rear camera faces upward.
- Any position in the camera view is valid. There is no fixed scanning box.
- Each physical card should be added only once while it remains visible.
- The recognized-card list remains on screen and accumulates in deal order.
- The performer later turns the phone over and views the list.
- First-version output is only the on-phone list. It has a `Clear` command for
  the next routine.

## Architecture

```text
Rear camera (1080p, 120 fps preferred)
  -> sharp-frame sampler (at most 30 model inputs/sec)
  -> Core ML object detector, entirely on the phone
  -> position-aware card event coordinator
  -> persistent SwiftUI card history
```

`CameraService` chooses a 1920x1080 back-camera format first, using 120 fps when
that resolution supports it, then falling back to 60 fps. It only uses a
lower-resolution high-speed format when no clear 1080p mode exists. 240 fps is
not selected by default because it reduces exposure time indoors while the
recognition pipeline is capped near 30 model inferences per second.
`SharpFrameSampler`
measures luma-edge contrast on the inexpensive camera luma plane and retains
the clearest frame from each sampling interval. It keeps collecting while the
previous inference runs, so a short card pass is not lost to a busy model. This
avoids queuing a neural inference for every camera frame.

`RecognitionEngine` loads `CardDetector.mlmodelc` from the application bundle
and submits selected frames through Vision/Core ML. The export script produces
this model from the `cdpcre/french_cards_detector_pytorch` weight with NMS
enabled, so Vision returns labelled card boxes. Vision uses aspect-fit scaling,
which keeps the whole camera image in scope instead of cropping it to a square.

`CardEventCoordinator` matches detection boxes across frames by overlap,
predicted centre position and velocity. Normal results require two consistent
observations in a four-frame vote with an average confidence of at least 0.85.
Each exact card face is recorded only once per scan session, and a short
spatial/trajectory guard suppresses a duplicate when a fast pass briefly loses
tracking. Different ranks with the same suit are separate cards.

## Failure behavior

- Missing model: the app explains that `CardDetector.mlpackage` must be
  exported and added before it can scan; it does not open a misleading camera
  session.
- Camera permission denied or unavailable: the scan control reports the
  problem with a usable status message.
- Dark, blurry, reflective, or low-confidence frames: they are ignored rather
  than written as incorrect cards.
- Camera mode less capable than 120 fps: scanning continues at 60 fps.

## Validation

Unit tests cover detector-label parsing and event coordinator duplicate
prevention. On-device validation uses 20 to 30 real cards under the actual
table lighting and dealing speed. A pass requires clear card faces in the
recorded 120 fps footage and no repeated entry while a card remains in view.
