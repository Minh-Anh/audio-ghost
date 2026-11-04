# AudioGhost — living memory

Read this first, then `audioghost-spec.md` for the sections you're touching. `README.md` has the code walkthrough and the list of known issues.

**Current phase: everything indoors is cleared. FrameProbe done, S1 and S2 passed, calibration
ritual verified on hardware. The only remaining unknown is the first field walk** (which also
answers S3–S5). See "Open on device" below.

---

## 1. Build & test

```bash
# Unit + integration tests (simulator; 129 tests)
xcodebuild -project AudioGhost.xcodeproj -scheme AudioGhost \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

# Device build (needs a signing team set in Xcode → Signing & Capabilities)
xcodebuild -project AudioGhost.xcodeproj -scheme AudioGhost -destination 'generic/platform=iOS' build
```

- Xcode 27.2 / iOS 27.2 SDK (last verified 2026-11-04), deployment target **iOS 17.0**, Swift language mode 5 (strict
  concurrency `minimal` — CoreMotion/CoreLocation delegate callbacks are not worth fighting).
- The Xcode project uses **file-system synchronized groups**: new files under `AudioGhost/` and
  `AudioGhostTests/` are picked up automatically, no `.pbxproj` editing needed.
- No third-party dependencies, and none are wanted.

## 2. Frame conventions

`AudioGhost/Core/CoordinateMath/Frames.swift` is the single source of truth; the table is
repeated here because the spec asks for it.

| Frame | Definition |
|---|---|
| Sensor / head-local | **MEASURED, not assumed.** `FrameConfig.headForwardLocal` / `.headUpLocal`, produced by FrameProbe and persisted in `UserDefaults`. Defaults are the starting hypothesis (`forward = (1,0,0)`, `up = (0,0,1)`) and are marked UNVERIFIED. |
| CoreMotion reference | Gravity-aligned, vertical along ±z (`FrameConfig.referenceUpSign`, measured). Horizontal axes arbitrary, re-randomised on every AirPods reconnect. |
| ENU | `SIMD3(x: east, y: north, z: up)`, meters, origin = first accepted fix of the session. |
| PHASE world | +x east, +y up, −z north. Identity listener faces true north. |
| PHASE listener-local | −z out of the nose, +y out of the top of the head, +x out of the right ear. |

Handedness convention used everywhere: **`right = forward × up`** (so `{right, up, −forward}` is
right-handed, as in SceneKit).

Composition (spec §6.6), implemented in `Frames.listenerRotation`:

```
q_PHASE = C ∘ R(yawOffset) ∘ q_attitude ∘ H
```

`C` = ENU→PHASE, `R` = CoreMotion-reference→ENU built from two direction pairs so it works for
either sign of `referenceUpSign`, `H` = listener-local→sensor-local from the measured vectors.
All three are built from explicit basis vectors — never from hand-typed quaternion components.

### FrameProbe results — RUN 2026-07-28 (AirPods + iPhone 13 mini)

```
headForwardLocal = (-0.295,  0.940, -0.174)
headUpLocal      = (-0.219,  0.110,  0.969)
headRightLocal   = ( 0.930,  0.324,  0.173)   (derived, F × U)
referenceUpSign  = +1
probeNotes       = turn-right Δyaw +73° (expect ≈ +90°); roll axis · forward = 0.87 (expect ≈ 1.00)
```

**The headline result: the sensor frame is approximately +x out the right ear, +y out the nose,
+z out the top of the head** — i.e. forward and right are *swapped* relative to the old default
hypothesis, which had `forward = (1,0,0)`. Anything written against literal axes would have been
90° wrong. This is why the probe exists.

Interpretation of the numbers:

- Vectors are unit and exactly perpendicular (forward is constructed as `up × right`), and the
  turn-right yaw sense is positive, so the handedness and `referenceUpSign` are right.
- The measured frame sits ~14–20° off the clean axis-aligned frame. That is the mounting tilt
  §6.5 predicts ("AirPods sit differently in every ear → 10–20°"), baked into the vectors for
  this particular fit. Valid as long as the buds are worn roughly the same way each session.
- **The two imperfect cross-checks are tolerable, and the reason is structural.** 73° instead of
  90° is a human under-rotating a head turn; the 29.5° roll-axis discrepancy means the nod and
  roll moves weren't perfectly clean. Neither matters much, because `forward` is derived as
  `up × right` with `up` coming from *gravity* — so any error in the measured nod axis survives
  only as a rotation **about up**, i.e. a constant yaw offset, which the compass calibration
  absorbs exactly. `FrameTests.testNodAxisErrorIsAbsorbedByCalibration` injects a deliberate 25°
  nod-axis error and proves the rendered nose direction is unchanged after calibration.
  The residual that is *not* absorbed is second-order: a slight yaw wobble when the head pitches.
- Re-running the probe with cleaner moves would tighten it, but is not required to walk.

The measured config is checked into `FrameTests.configs`, so the three canonical §6.6 tests run
against the frame the app actually uses, not only tidy hypotheses.

### How the probe works

`Home → Developer → Frame probe` (debug builds). It does not just display numbers: it *solves*
for the frame and saves it.

- `headUpLocal` = −(mean gravity) with the head level. Gravity is unambiguous.
- `headRightLocal` = −(rotation axis of the "nod down" move); a downward nod is a negative
  rotation about the ear-to-ear axis under the right-hand rule.
- `headForwardLocal` = up × right.
- `referenceUpSign` = sign of the reference-frame z component of the level head's up vector.
- The "turn right 90°" step is an independent check: derived yaw must increase by ≈ +90°. If it
  decreases, the probe warns that the derived frame is mirrored (usually step 3 was nodded the
  wrong way).
- The "roll to right shoulder" step cross-checks that the roll axis ≈ the derived nose axis.

Record the numbers here once measured, with the date.

## 3. Spike status (spec §13)

| # | Risk | Status |
|---|---|---|
| S1 | Motion callbacks with screen locked / pocketed | **PASS (2026-07-28).** Heartbeat continues with the phone pocketed and locked. The architecture's central bet — that the `.playback` session keeps motion callbacks flowing in the background — holds. **The concept is go.** |
| S2 | OS spatializer double-rotating PHASE output | **PASS (2026-07-28).** Head turns sweep the source 1:1, not 2:1, with `automaticHeadTrackingFlags = []` (see the spec correction below). No need for the Control Centre "Spatialize Stereo" workaround. |
| S3 | GPS quality at the venue | NOT RUN. |
| S4 | Compass usable at the venue | NOT RUN. Fallback already shipped: course-based coarse seeding means the ritual is an accuracy upgrade, not a hard dependency. |
| S5 | Yaw drift rate of these AirPods | NOT RUN. `courseGain = 0.02` is the spec default; the HUD's `courseErr` is the tuning signal. |

## 4. Deviations from the spec, dated

- **2026-07-27 — §7.2 double-spatialization has an explicit API.** `PHASEListener.automaticHeadTrackingFlags`
  (iOS 18+) controls whether PHASE itself rotates the listener from head motion. We set it to `[]`
  under `if #available(iOS 18.0, *)` in `SpatialAudioEngine.start`, since we drive the listener
  ourselves. The spec's `setSupportsMultichannelContent(false)` suggestion was not needed and is
  not used. If head turns still sweep the source ~2× in the field, the remaining suspect is the
  OS "Spatialize Stereo" setting for AirPods (Control Centre → long-press volume) — the sign-flip
  sheet in the HUD says so.
- **2026-07-27 — `PositionFilter` returns a three-way outcome** (`.smoothed` / `.snapped` /
  `.heldAsOutlier`) instead of a bool, so a suspect fix can be dropped without emitting a pose.
- **2026-07-27 — the acceptance pipeline was factored into `FixPipeline`**, shared by
  `LocationService`, `ScriptedLocationProvider` and `ReplayLocationProvider`. A desk simulation
  that skipped the real filter would prove nothing.
- **2026-07-27 — `degraded(.accuracyPoor)` redefined to be reachable.** The spec's trigger
  ("accuracy > 30 m sustained 15 s") can never fire, because fixes worse than 30 m are rejected
  outright and the 8 s staleness timeout always wins. It now means: *accepted* fixes have been
  weaker than `Tuning.weakAccuracy` (15 m) for `accuracyPoorTimeout` (15 s). GPS complaints are
  suppressed while `awaitingCalibration` — that banner has something more actionable to say.
- **2026-07-27 — the near-field bearing filter is seeded on the first tick** with the true
  bearing, instead of filtering in from a stale value.
- **2026-07-27 — `attitudeYaw` has no additive `yawSignFix`.** The spec's constant is absorbed by
  `yawOffset` anyway, and a genuine *sign* error cannot be fixed by a rotation — it means the
  measured basis is mirrored, which FrameProbe detects and reports directly.
- **2026-07-27 — a bundled demo drone ships with the app** (`Resources/demo-ghost.wav`, a
  6 s seamless loop) so a fresh install is testable without hunting for a file.
- **2026-07-28 — permissions are requested from Home, and the route gate moved to the end of
  `startServices`.** Original ordering checked the headphone route *first* and returned before
  `location.start()` / `head.start()` — the only calls that raise the iOS prompts. A first-run
  user without AirPods connected therefore got an instant failure, was never asked for anything,
  and (because iOS only lists an app in Settings once it has requested a permission) found no
  toggles in Settings either. Home now has a Permissions section with explicit Allow buttons
  (`PermissionCoordinator`), and session start requests location before any gate can bail out.
  Motion access still cannot be requested without compatible AirPods connected —
  `isDeviceMotionAvailable` is false and iOS will not ask — so the UI says so plainly.
- **2026-07-28 — `headingFilter = kCLHeadingFilterNone` is required for the ritual.**
  CoreLocation's default `headingFilter` is 1°: it only delivers a heading update once the
  heading has *changed* by more than that. The §6.3 ritual asks the user to stand perfectly
  still, which suppressed nearly every update, so the sample window starved and the ritual always
  failed with `.notEnoughSamples` — the stiller you held the phone, the more reliably it failed.
  Pinned by `CalibrationTests.testHeadingUpdatesAreUnfiltered`. The collection window now also
  extends to 6 s while waiting for enough samples instead of failing at a hard 2 s deadline.
- **2026-07-28 — heading samples carry `isTrueHeadingValid`.** `CLHeading.trueHeading` is −1
  unless location updates are running (it needs the magnetic declination for the current
  location). The ritual was averaging that placeholder into `yawOffset`, which would have
  produced a confidently wrong calibration. Invalid readings are now dropped, and a window that
  saw updates but no valid true heading reports `.trueNorthUnavailable` ("no GPS fix yet")
  instead of blaming the user's steadiness.
- **2026-07-28 — `LiveLocationProbe` no longer requests authorization on appear.** Merely
  opening the editor is not a reason to raise a system prompt, and it made the UI smoke tests pop
  a real alert in the test host app (which then sat queued in SpringBoard across launches and
  looked like a launch-time bug). The prompt now belongs to an explicit "Drop here" tap.

- **2026-11-04 — behaviour-preserving simplification pass.** Verified by the full suite, Debug and
  Release device builds, and an old-vs-new reducer comparison over all 1,224 state/event/calibration
  combinations (no differences beyond the removed effects). The measured frame and `Tuning` overrides
  saved on the device still load (now pinned by tests).
  - `Tuning` is now a struct read as `Tuning.current.x`; each default is declared once.
  - `FixPipeline` is shared: the coordinator owns one and every location provider pushes into it.
    It fires `onFix`/`onRejected` and is tracking-queue only, so its lock is gone. `LocationProviding`
    is now just `start`/`stop`.
  - Removed the `.seedOrigin` and `.log` effects and the never-sent `.calibrationInvalidated` event.
    The ghost is placed once, in `handle(fix)`, from `Ghost.enuPosition(origin:)`.
  - Removed `FrameConfig.mountingCorrection` (the slot is on `HeadTrackingService`). New `FrameConfig`
    fields must be optional, or the saved measured frame stops decoding.
  - `Frames.solveSensorFrame` holds the FrameProbe math, so its test now exercises the real code.
  - Small visible changes: ear height applies at the next session start; the HUD's fix counters now
    work in desk simulation; CSV note rows `gps stale`/`gps weak`/`gps recovered`/`calibration x` are
    gone because the `state …` rows already record them.
- **2026-11-04 — GPS banners no longer get swallowed (`GPSHealthMonitor`).** The heartbeat's
  `gpsDegraded` Bool was replaced by a small pure type that records *which* complaint the reducer
  was actually sent (`DegradedReason?`). Two bugs fixed: (1) the flag latched during
  `.awaitingCalibration`, where the reducer ignores GPS complaints, so a weak or stale spell that
  began before calibrating never produced a banner once running; nothing is recorded as delivered
  there now, while the weak-fix timer keeps running so the complaint fires as soon as the session
  runs. (2) `accuracyPoor → gpsLost` was unreachable; staleness now escalates it. Each complaint
  is still sent once, not at 25 Hz, `gpsLost` never downgrades, and only a strong fix (≤
  `weakAccuracy`) sends `.gpsRecovered`. Reducer table unchanged. `GPSHealthMonitorTests` covers
  it clock-free; `testSustainedWeakFixesDegradeTheSession` now outlasts the timeout before
  calibrating (it previously calibrated early, which hid bug 1). **Written without Xcode: not
  yet compiled or run** — run the suite before the field walk.

## 5. Tuning constants

`AudioGhost/Support/Tuning.swift` is the single source of truth, read as `Tuning.current.x`. The
key values are live-editable in the field from **Debug HUD → Tuning** (persisted, "Reset to spec
defaults" restores §12).
Current defaults are exactly the spec's §12 table, plus `weakAccuracy = 15 m` (see deviation
above) and `uiSnapshotHz = 4`.

## 6. Where things are

```
AudioGhost/
├── App/                 AudioGhostApp, AppEnvironment (composition root; no singletons)
├── Core/
│   ├── CoordinateMath/  Geo, Frames, Quaternions, WrapMath        ← pure, heavily tested
│   ├── Location/        LocationService, FixPipeline, PositionFilter, ScriptedLocationProvider
│   ├── HeadTracking/    HeadTrackingService (+ SyntheticHeadPoseProvider)
│   ├── Calibration/     CalibrationService (ritual solver + course drift correction)
│   ├── Audio/           SpatialAudioEngine (PHASE + near-field clamp), AudioImport, AudioSessionController
│   └── Session/         SessionCoordinator (heartbeat), SessionReducer (pure), ListenerPose
├── Store/               Ghost, GhostStore (ghosts.json + Documents/Audio/)
├── Support/             Tuning, SessionLogger (CSV), Replay, Permissions, DebugSettings, FrameConfigStore, Log, AppClock
├── Resources/           demo-ghost.wav
└── UI/                  Home, GhostEditor, Calibration, Session, DebugHUD, FrameProbe
```

Threading contract: one serial `trackingQueue` owns pose fusion, PHASE and the filters. The
headphone-motion callback is the heartbeat (~25 Hz measured in the desk run). UI gets 4 Hz
snapshots on the main queue. `SessionCoordinator.state` / `.snapshot` / `.needsCalibration` are
written on the main queue only; everything else stays on `trackingQueue`.

## 7. Testing

129 tests, all green in the simulator:

- `WrapMathTests` / `GeoTests` — Appendix A contracts and Appendix B worked vectors.
- `FrameTests` — the three canonical §6.6 tests, run against **three different sensor-frame
  hypotheses** (including one with a mirrored reference vertical) so nothing downstream can
  depend on the unverified defaults. Plus the FrameProbe solver against a known frame.
- `SmoothingTests` — τ scaling, teleport counter, dead-reckoning freeze, clamp entry/exit
  hysteresis, wrap-aware bearing filtering across the ±π seam.
- `CalibrationTests` — ritual gates, course gating, gain, coarse cold-start seeding.
- `ReducerTests` — every §8 transition.
- `SessionIntegrationTests` — a full desk run: demo audio → import → store → coordinator with the
  synthetic head and a scripted GPS path → PHASE graph plays → heartbeat rate measured from the
  log rows → CSV exports and parses back as a replay fixture → clean stop.
- `TuningTests` / `SessionLoggerTests` — override persistence and reset; the CSV ring buffer.
- `UISmokeTests` — every screen laid out in a hosting controller.

**Desk simulation** (`Home → Developer → Desk simulation`, debug builds): scripted GPS paths
(approach / circle / fly-by / stand / GPS dropout) with injectable noise, and a synthetic head so
the pipeline runs without AirPods. Changes take effect on the next session start.

## 8. Open on device (do these first, in order)

0. **Grant permissions from the Home screen first** (Permissions → Allow). Motion needs AirPods
   connected before iOS will even ask. Neither permission appears in iOS Settings until the app
   has requested it once.
1. **Set a signing team** in Xcode and run on hardware. `DEVELOPMENT_TEAM = K66Q788LB3` is already
   set in the project; the Apple Developer Program License Agreement must be accepted at
   developer.apple.com/account or profile creation fails with "PLA Update available".
2. ~~**FrameProbe**~~ — done 2026-07-28, numbers in §2.
3. ~~**S1**~~ — passed 2026-07-28. Concept is go.
4. ~~**S2**~~ — passed 2026-07-28. Rotation is 1:1.
5. **First field walk** with the §15 troubleshooting tree. Everything indoors is now cleared;
   this is the only remaining unknown. S3 (GPS at the venue), S4 (compass at the venue) and S5
   (drift rate of these AirPods) are all answered by the CSV from the walk rather than by
   separate spikes. Every symptom in that tree is a switch
   in **Debug HUD → Sign flips** (flip east / flip north / conjugate listener / flip yaw-offset
   sign) — a ten-minute fix in the field, not a rebuild. Whatever you end up flipping, fold it
   into the defaults here and note it as a dated deviation.
6. Then the four acceptance walks of §1, pocketed, exporting a CSV each time. Keep the CSVs —
   they are replay fixtures (`ReplayLocationProvider(csv:queue:)`).

## 9. Not built (deliberate, per spec §1)

Multiple simultaneous ghosts (the store and engine are architected for N; only the UI is
single-ghost) · proximity triggers · ARKit fusion · occlusion/reverb · ghost sharing · barometric
altitude · mounting calibration (§6.5 — the `mountingCorrection` slot exists and is applied to
every sample, currently identity) · Kalman position filter (`PositionFilter` is the seam) ·
Live Activity · Watch.
