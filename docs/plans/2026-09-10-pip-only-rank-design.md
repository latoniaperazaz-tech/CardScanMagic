# Build 3: OCR-free body PipTopology repair

Scope approved by the user: targeted A–10 evidence-chain repair after source audit. No PHASE 2 cardness architecture, model training, camera/motion/ring/track changes or threshold reductions. Frozen capture branch is `phase1-event-capture` at `827a6007b454ef907629192f9c2204337c486c4f`; diagnostics branch remains `1616319f549fa2b68913f7f12a55b2199339f903`. Implementation lives on `build3-pip-topology-fix`.

## Source-audit conclusions

1. `extractPips` runs before corner OCR. OCR=nil is not a direct pip-extraction guard. Fusion already uses `textRank ?? layoutRank`, but neither being resolved produces no local detection.
2. Each connected ink component previously needed area, aspect, occupancy and suit template similarity >= 0.61 to survive. This incorrectly coupled geometric pip retention to full shape classification. Clipped components were additionally removed from body pips.
3. Occlusion, connected foreground, blur and template mismatch could reduce the input point set. Fallback localization with unknown geometry can also fail its existing 0.50 localization threshold.
4. Fusion requires rank and suit from the same candidate; this association is preserved. It does not mix features from separate cards or frames.
5. The failure chain OCR=nil -> discarded/poorly located pips -> unresolved layout -> no local detection is possible in the actual source. Its exact contribution to the reported phone image cannot be measured without that image and its diagnostics.
6. Full-surface missing-pip penalties did not model foreground occlusion.
7. `visibleRegion` represents frame-edge cropping, not internal visibility. It cannot by itself distinguish hand occlusion from visible empty card positions.

## Chosen design

Preserve geometric ink candidates after area/aspect/occupancy checks. The old shape threshold qualifies suit evidence only. Body pip areas provide a consistency measure, and same-suit body supporters are counted separately from corner evidence. Standalone OCR-free fusion requires body support, geometric layout, valid rank distribution, absolute score, confidence and margin; black blocks alone cannot supply suit certainty.

Represent uncertain foreground with normalized crop-local rectangles from a bounded 16 x 16 component tile mask. Tiles follow large non-paper components, including edge entrants, instead of hiding their entire bounding rectangle. This is a conservative traditional visibility heuristic, not a hand segmentation model. It creates neither pips nor suits. Unknown expected-but-unseen pips are neutral for missing, center and symmetry terms. Already observed pips remain positive evidence in estimator inputs. If distinguishing pips could all be hidden, rank remains unresolved.

Complete localized upright surfaces independently establish normalized layout coordinates. This surface anchor supports low-count A/2 inference without inventing extra observations or lowering confidence thresholds. Partial crops retain similarity fitting and require sufficient points. The production `RecognitionEngine.partialEvidence` helper carries visibility and surface geometry into the estimator and is shared by image integration tests.

Alternative rejected: lower confidence/shape thresholds globally, which adds false identities. Alternative deferred: train a segmentation or new card model, which is outside this repair.

## Validation contract

Run all existing Swift and Python tests, new A–10 OCR-free topology cases, generated image -> extraction -> production topology handoff -> Fusion -> coordinator cases, corner/body occlusion, 9/10 ambiguity, random ink, blocks, weak suit/geometry, physical and session dedup. Build the existing iPhone Release target through the repository macOS workflow. Preserve Core ML outputs, 111 operation, three-card session cap, phase 1 diagnostics and all camera scheduling code. Real-device recall remains a separate measurement; generated fixtures do not establish real-camera accuracy.
