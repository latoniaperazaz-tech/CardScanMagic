# Partial Card Inference MVP

## Scope

Build a standalone Python/OpenCV inference baseline alongside the existing iOS
application. It does not train a model and does not change the Swift camera or
Core ML pipeline. The MVP accepts one image, extracts suit and pip evidence,
estimates which part of a card is visible, and ranks A through 10. It may return
`unknown` when evidence is weak.

## Architecture

The normalized template layer stores every pip for A through 10 as an `(x, y,
orientation)` record plus derived row, column, center, and symmetry structure.
The feature layer extracts permissive pip candidates with several HSV and
grayscale masks and estimates suit probabilities from color and contour shape.
The geometry layer detects card boundaries and returns a probability
distribution over visible regions instead of assuming a full card.

Rank inference compares the observed point set with each normalized template.
It proposes understandable similarity transforms from point pairs, refines the
best transform, and scores matched distance, unsupported observations,
crop-explainable missing pips, count consistency, center and middle-row
evidence, left/right structure, and symmetry. Evidence fusion calibrates the
rank and suit candidates and applies an explicit unknown threshold. A future
pretrained detector is represented by a neutral adapter interface and is not a
required dependency.

## Data Flow

1. Load and validate an image.
2. Detect probable card boundaries and visible-region hypotheses.
3. Detect pip candidates without requiring the observed count to equal rank.
4. Estimate suit probabilities from candidate color and shape.
5. Rank all A through 10 templates under geometric transform hypotheses.
6. Fuse evidence and return candidates, explanations, and optional unknowns.
7. Draw detected pips, boundaries, region, suit, and rank candidates to a debug
   image.

## Error Handling

Invalid or unreadable images fail with a clear command-line error. Empty or
ambiguous detections return low-confidence candidates or `unknown`; no default
card is fabricated. Optional pretrained models return unavailable evidence when
weights are absent.

## Verification

Tests generate deterministic card faces for 4 through 10 and focused A through
10 template checks. Rank 5 must remain first for full, right-cropped,
top-cropped, center-plus-left, and 15-degree rotated observations. Confusion
tests cover 4/5, 5/9, 6/8, 6/7, and 8/10. Additional integration tests apply
motion blur and verify that pip detection remains permissive. Real-image
validation is reported separately and requires real partial-card samples in
the repository or supplied by the user.
