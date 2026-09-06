# CardScanMagic

An iPhone app for recording face-up playing cards as they pass anywhere through
the rear camera view. It is designed for an iPhone placed screen-down on a
table: start scanning while the screen is visible, turn the phone over, deal
the three cards, then turn it back to see the hand.

The app runs recognition locally. It does not upload camera frames or require a
network connection while scanning.

## What the first version does

The app is currently tuned for one 炸金花 hand: it accepts at most three unique
cards per round. After the third confirmed card it stops the camera automatically
and keeps the three-card result on screen. Tap Clear before the next hand.

- Requests the best available rear camera. On a multi-camera iPhone such as
  the 14 Pro it uses the virtual rear camera with automatic macro enabled, so
  a card brought close to the lens can switch to the close-focusing camera.
  It prefers 60 fps for that mode to give autofocus and exposure enough time;
  other devices use 120 fps when available, then 60 fps. 240 fps is
  intentionally not the default: it shortens exposure in ordinary indoor
  light without increasing the model's roughly 30 inferences per second.
- Samples the high-frame-rate stream, retaining a sharp candidate frame instead
  of trying to run the neural model on every camera frame.
- Detects the rank/suit corner anywhere in the frame, tracks it across time and
  records a card after two consistent recognitions. The upstream weight returns
  a small corner box (not a full-card outline), so the app accepts that geometry
  and uses the surrounding sharp frames to reject one-frame blur or glare.
- Keeps up to three unique cards in deal order. A duplicate callback or a
  re-detection cannot consume another slot.
- Stops after the third card so table texture and later cards cannot pollute
  the hand. Tap Clear to start the next three-card hand.

## Before building

This project intentionally does **not** include the trained model. Download and
export it from the MIT-licensed upstream project, then add the exported Core ML
package to `App/Models/`:

<https://github.com/cdpcre/french_cards_detector_pytorch>

On a cloud Mac, use Python 3.11 or later:

```bash
cd CardScanMagic
python3 -m venv .venv
source .venv/bin/activate
pip install -r scripts/requirements-export.txt
python scripts/export_coreml.py --download
```

The command downloads the upstream `deployment_hf/best.pt`, exports a
hardware-friendly FP16 Core ML package with built-in non-maximum suppression,
and writes `App/Models/CardDetector.mlpackage`.

The app expects the exported model to be called `CardDetector.mlpackage`.
After exporting, regenerate the Xcode project so the model is compiled into the
application bundle:

```bash
brew install xcodegen
xcodegen generate
open CardScanMagic.xcodeproj
```

## Install on your iPhone with a free Apple ID

1. In Xcode, select the `CardScanMagic` target, then **Signing & Capabilities**.
2. Change the bundle identifier to one that is unique to you, for example
   `com.yourname.cardscanmagic`.
3. Select your Apple ID as the Team. Xcode creates a free personal development
   provisioning profile.
4. Connect the iPhone 14 Pro by cable, trust the computer, choose that iPhone
   as the run target, and press Run.

The free development signature is valid for seven days. Build and install again
before it expires. The app uses the camera only while its scanning screen is
open and the app remains active.

## Build on GitHub, install from Windows

You do not need to rent a cloud Mac for a one-off iPhone test. This repository
includes a manually triggered GitHub Actions workflow that exports the model
and packages an **unsigned** device IPA. Sign that IPA locally on Windows with
Sideloadly and your free Apple ID; do not put Apple credentials in GitHub.

See [`Windows免费安装到iPhone.md`](Windows免费安装到iPhone.md) for the exact steps.

## First on-table test

1. Open the app with the screen facing up and tap `Start`.
2. Place the iPhone screen-down so the rear camera faces up.
3. Deal face-up cards over the camera with strong, diffuse light from both
   sides. The cards must be readable in at least a few video frames.
4. Turn the phone over. The list should contain the recognized cards in deal
   order (up to three), then show that the hand is complete.

Start with one card at a time. The current detector is a corner classifier: it
can recognize a card even when the whole rectangle is not visible, but a sharp
rank/suit corner must appear in at least two sampled frames. Glare, motion blur,
and a card held edge-on are still camera problems; use broad, diffuse light and
leave a little clearance from the camera frame edge.

## Model and license note

The upstream repository is MIT licensed. Its model is trained and exported with
Ultralytics YOLO, whose upstream license has its own conditions. This starter
project contains no Ultralytics source code, but you should review those terms
before selling or distributing a closed-source product.

## Project files

- `App/`: SwiftUI iOS app and camera/recognition logic.
- `scripts/export_coreml.py`: downloads and exports the upstream PyTorch model.
- `project.yml`: XcodeGen project definition for a cloud Mac.
- `Tests/`: logic tests for card-name parsing and duplicate prevention.
- `docs/plans/`: the approved first-version design.
