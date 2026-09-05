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
  -> sharp-frame sampler (about 14 model inputs/sec)
  -> Core ML object detector, entirely on the phone
  -> position-aware card event coordinator
  -> persistent SwiftUI card history
```

`CameraService` chooses the fastest 1920x1080 back-camera format that supports
120 fps. If unavailable, it chooses a 60 fps format. `SharpFrameSampler`
measures luma-edge contrast on the inexpensive camera luma plane and retains
the clearest frame from each sampling interval. This avoids queuing 120 neural
inferences per second.

`RecognitionEngine` loads `CardDetector.mlmodelc` from the application bundle
and submits selected frames through Vision/Core ML. The export script produces
this model from the `cdpcre/french_cards_detector_pytorch` weight with NMS
enabled, so Vision returns labelled card boxes. Vision uses aspect-fit scaling,
which keeps the whole camera image in scope instead of cropping it to a square.

`CardEventCoordinator` matches detection boxes across frames by overlap and
nearby centre position. It requires the same label in two of the three latest
detections and a mean confidence of at least 0.62 before emitting a record. A
track is then marked recorded until it has disappeared. A 0.65 second
same-label guard avoids duplicated records if a very fast card briefly breaks
tracking; a later physical card with the same face may still be recorded.

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
