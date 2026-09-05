# CardScanMagic

An iPhone app for recording face-up playing cards as they pass anywhere through
the rear camera view. It is designed for an iPhone placed screen-down on a
table: start scanning while the screen is visible, turn the phone over, deal
the cards, then turn it back to see the cumulative card history.

The app runs recognition locally. It does not upload camera frames or require a
network connection while scanning.

## What the first version does

- Requests the rear camera and prefers 1920x1080 at 240 fps for fast dealing;
  it falls back to 120 fps, then 60 fps when needed.
- Samples the high-frame-rate stream, retaining a sharp candidate frame instead
  of trying to run the neural model on all 240 frames.
- Detects cards anywhere in the frame, tracks their position, and records a
  card on one very high-confidence recognition or two consistent recognitions.
- Keeps the complete detection history until the `Clear` button is tapped.
- Records each exact card only once per scan session, even if tracking briefly
  loses it and redetects it. Different cards with the same suit are still
  recorded separately. Clear the history to start a fresh deck/session.

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
4. Turn the phone over. The list should contain each recognized card in deal
   order.

Start with one card at a time. Do not judge the model by its first result under
uncontrolled lighting: glare, motion blur, and a card held edge-on are camera
problems before they are model problems.

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
