# Fast-Pass Partial Recognition (Build 3)

## Runtime

The iPhone now runs the partial path itself, without a Python service:

1. Choose a supported 120/60/30 FPS camera format in that order. Use exact
   rational frame durations and an approximately 1 ms auto-exposure ceiling,
   clamped to the selected format. Low light may raise noise or darken frames.
2. Copy delivered camera samples into a bounded capture reservoir (24 frames,
   96 MiB, 850 ms capture age). Preserve capture timestamps. Prefer transient
   motion to stationary background when the reservoir is full. Drain after the
   card has left, without waiting for another sample. Capacity and processing
   limits mean this is not a promise to retain every delivered frame.
3. Run the existing Core ML detector, plus bounded local Vision/Core Image
   analysis: card localization, perspective correction for complete rectangles,
   clipped-surface fallback, pip centers, suit shape/color, and corner OCR.
4. Match A-10 pip layouts including cropped, rotated and scaled observations.
   J/Q/K require the detector or readable corner text. Rank and suit must both
   resolve; a card-shaped blur or red/black color alone is insufficient.
5. Fuse geographically overlapping evidence. Conflicting strong cues suppress
   the region. Independently supported detections at score >= 0.85 may confirm
   from one capture. Model-only detections still need distinct timestamps.
6. Keep inference off the main queue. The device IPA is now Release-optimized;
   simulator tests retain the normal test configuration. The 111 gesture remains.

## Scope And Limits

This ports the rule-based partial baseline, not a newly trained blur-restoration
network. Swift uses similarity fitting; full-card perspective is rectified by
Vision. Severe perspective in a clipped card may remain ambiguous. Template
layout and suit shape vary by deck. Evidence scores are heuristic, not calibrated
accuracy probabilities. Arbitrarily severe blur cannot reveal erased identities.

At 120 FPS frames are about 8.33 ms apart. A passage lasting only a few milliseconds
may fall between exposures. Even a recorded silhouette need not preserve enough
information to distinguish ranks/suits. More light and shorter exposure reduce
blur; queueing addresses inference delay, not missing sensor information.

## Validation

XCTest covers camera timing boundaries, bounded capture memory/session isolation,
capture deduplication, local synthetic bitmap extraction, layout ambiguity, fusion
conflicts and single-frame confirmation. The build artifact's verification record
contains actual CI results, hashes and rollback checks. Synthetic tests do not
establish accuracy on a real moving deck or throughput on the user's iPhone.

Device acceptance still requires a labelled fast-pass clip or physical deck:
record the phone/camera settings, lighting, pass count, correct identities, misses,
false identities, duplicate records, and end-to-end latency. Compare build 2 and
build 3 under the same conditions; do not count a plausible guess as correct.
