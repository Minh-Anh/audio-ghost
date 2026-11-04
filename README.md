# AudioGhost

A GPS-anchored spatial audio "ghost" for iOS. You place a sound at a real-world coordinate and height. Then you walk around with AirPods in and the phone in your pocket, and the sound stays at that point in the world, however you move your body or head.

- No third-party dependencies, no backend, no accounts.
- [`audioghost-spec.md`](audioghost-spec.md) is the original design. [`CLAUDE.md`](CLAUDE.md) records measurements, spike results and every dated deviation from the spec.
- Status: everything indoors is verified on hardware. The first field walk hasn't happened yet.

```bash
# Tests (simulator, 133 tests)
xcodebuild -project AudioGhost.xcodeproj -scheme AudioGhost \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

---

# Quickstart: understanding the code

## 1. The one idea

Apple's PHASE engine does the hard audio work. Tell it where a source is and where the listener is, including which way their head points, and it renders binaural sound. The source barely moves, so **nearly all the code exists to answer two questions, about 25 times a second:**

1. **Where is the listener?** GPS knows, but it's noisy, slow (about 1 Hz) and sometimes wrong by tens of meters.
2. **Which way is their nose pointing?** AirPods know how the head is *turning*, but not where north is, and they forget their reference whenever they reconnect.

Those two weaknesses explain most of the design: the position filter handles the first, and `yawOffset` handles the second.

## 2. The system on one page

```
 CoreLocation ───────┐
 ScriptedLocation ───┼─ RawFix ─▶ FixPipeline ─▶ latest SmoothedFix ───────┐
 ReplayLocation ─────┘   ~1 Hz    gates + filter         │                  │ position
                                                         │ onFix            │
 Compass ritual ──▶ CalibrationService ◀── GPS course ───┘                  │
                       owns yawOffset ───────────────────────────────────┐  │
                                                                         ▼  ▼
 AirPods ──▶ HeadTrackingService ── HeadSample, ~25 Hz ──▶ SessionCoordinator.handle(sample)
             (or synthetic head)                               THE HEARTBEAT
                                                                     │ ListenerPose
                                                                     ▼
                                                         SpatialAudioEngine
                                                         near-field clamp, then PHASE
                                                                     │ RenderState
                                                     ┌───────────────┴───────────────┐
                                                     ▼                               ▼
                                              SessionLogger (CSV)          SessionSnapshot, 4 Hz
                                                                                     ▼
                                                                                  SwiftUI

 Separately: events ──▶ SessionReducer (pure) ──▶ new state + effects ──▶ coordinator runs effects
```

Three rhythms run at once:

| Rhythm | Rate | Trigger | Job |
|---|---|---|---|
| **Heartbeat** | ~25 Hz | AirPods motion callback | Fuse the pose, update PHASE, log |
| **Fix** | ~1 Hz | GPS | Refresh the smoothed position, correct yaw drift |
| **UI** | 4 Hz | Throttled from the heartbeat | Publish a read-only snapshot |

The motion callback drives everything because it keeps firing when the phone is locked in a pocket, as long as an audio session is active. Display timers don't. Spike S1 verified this on hardware, and the whole concept depends on it.

## 3. Six ideas to hold in your head

### Five coordinate frames

| Frame | Axes |
|---|---|
| **Sensor** (AirPods) | Undocumented, so *measured* by FrameProbe and stored in `FrameConfig` |
| **CoreMotion reference** | Vertical along ±z; horizontal axes arbitrary, re-randomised on reconnect |
| **ENU** | x east, y north, z up, in meters; origin is the session's first accepted fix |
| **PHASE world** | +x east, +y up, −z north |
| **PHASE listener** | −z out of the nose, +y out of the top of the head, +x out of the right ear |

### The rotation chain

`Frames.listenerRotation` is one line of composition, read right to left:

```
q_PHASE = C ∘ R(yawOffset) ∘ q_attitude ∘ H
```

- `H`: listener axes → sensor axes (from the FrameProbe measurement)
- `q_attitude`: sensor → CoreMotion reference (live from the AirPods)
- `R(yawOffset)`: reference → ENU (this is what lines the reference up with true north)
- `C`: ENU → PHASE world (a fixed axis shuffle)

### `yawOffset`, the most important number in the app

```
trueYaw = attitudeYaw + yawOffset
```

`attitudeYaw` only means something as a *change*, because the reference frame's zero is arbitrary. `yawOffset` converts it to a real compass direction. `CalibrationService` owns it, and it gets set in two ways:

- **Compass ritual (`precise`):** hold the phone like a compass for about 2 s; offset = heading − attitudeYaw.
- **GPS course (`coarse`):** walk 15 m and assume you're facing your direction of travel. While walking, the same signal also corrects drift slowly (gain 0.02 per fix), skipping any fix more than 60° off, since that's probably a glance.

Disconnecting the AirPods invalidates the calibration. Course updates only run while head samples are fresh (one within `motionStaleTimeout`), so walking with the AirPods out can't seed a coarse offset from the old frame's yaw.

### Position: distrust every fix

Each `RawFix` goes through `FixPipeline`, then `ExponentialPositionFilter`:

1. Reject if accuracy is invalid or worse than 30 m, or the fix is more than 5 s old.
2. A jump over 20 m is held as an outlier. Three in a row means the *filter* was wrong, so it snaps to GPS.
3. Otherwise smooth, trusting good fixes more (τ runs from 1 s at ≤5 m accuracy to 3 s at 30 m).

Between fixes the heartbeat extrapolates using velocity, for at most 1.5 s, then freezes. **Scripted and replayed GPS feed the same pipeline**, so desk tests exercise the real filter.

### The near-field clamp

Within GPS noise of the ghost, true geometry is meaningless and the sound would whip around your head. So inside `rMin = max(4 m, GPS accuracy)`, `SpatialAudioEngine` holds the source at distance `rMin` along a slowly filtered bearing, keeping its true height. It only lets go past `rMin × 1.25`, which prevents flapping at the boundary. This changes where the source is *rendered*, never the world model. It's also the only time the source's position changes.

### A pure state machine

`SessionReducer.reduce(state, event, calibration)` returns `(newState, [effects])` and touches nothing else. `SessionCoordinator` feeds it events and runs the effects. To learn what the app does in any situation, read that one function. The policy to remember: **keep playing rather than go silent.** `degraded` keeps playing; only `paused` stops the sound.

## 4. Reading order

Read these in order and skim the rest. It's about 1,500 lines out of 4,700.

| # | File | Look for |
|---|---|---|
| 1 | `Core/Session/SessionReducer.swift` | The app's vocabulary: every state, event and effect |
| 2 | `Core/Session/SessionCoordinator.swift`, `MARK: Heartbeat` | The two `handle` methods. This is the real main loop |
| 3 | `Core/CoordinateMath/Frames.swift` | The frames comment, then `listenerRotation` |
| 4 | `AudioGhostTests/FrameTests.swift`, the three `testCanonical…` tests | What "correct" means for rotation |
| 5 | `Core/Calibration/CalibrationService.swift` | `solveRitual`, `updateWithCourse` |
| 6 | `Core/Location/FixPipeline.swift`, `PositionFilter.swift` | Gates, teleport handling, smoothing |
| 7 | `Core/Audio/SpatialAudioEngine.swift` | `updateListener` first, then `start` |
| 8 | Rest of `SessionCoordinator.swift`, `MARK: Effects` | Why `startServices` runs in that order |

Then skim as needed:

- `UI/`: mostly views. `CalibrationFlowView` and `FrameProbeView` each contain a small model worth reading.
- `Support/Tuning.swift`: every constant, each with a comment on what it does. Read values as `Tuning.current.x`.
- `AudioImport`, `GhostStore`, `SessionLogger`, `Permissions`: self-contained plumbing.

## 5. Three journeys to trace through the code

**Tap Start → first sound**

1. `session.start(ghost:)` resets the tracking state and sends `.startRequested`. State becomes `.acquiringFix`, effect `.startServices`.
2. `startServices` activates the audio session, starts location, starts head tracking, then checks the headphone route. Location comes first because it raises the permission prompt, which must happen even without AirPods.
3. The heartbeat is now ticking, with no position and no audio graph yet.
4. The first accepted fix becomes the ENU origin. `handle(fix)` places the ghost and sends `.firstFixAccepted`. State becomes `.awaitingCalibration`, effects `.startAudio` and `.promptCalibration`.
5. The sound is now playing, unaligned. Finishing the ritual sends `.calibrationBecameValid(.precise)`, and state becomes `.running`.

**One heartbeat tick** (`handle(_ sample:)`)

Attitude → `attitudeYaw` → add `yawOffset` → `listenerRotation` → predicted position from the latest fix → `ListenerPose` → `updateListener` (clamp, then set PHASE transforms) → GPS health check → CSV row → snapshot if one is due.

**AirPods out and back in**

1. Disconnect sends `.airpodsDisconnected`: `paused`, stop the sound, invalidate calibration. The route change usually also fires and may overwrite the pause reason. GPS fixes keep arriving, but `courseUpdate` skips them until a head sample arrives from the new reference frame, and the skipped distance doesn't count toward the 15 m seed.
2. Reconnect sends the event matching the current pause reason. With calibration gone, state becomes `.awaitingCalibration`, audio resumes, and the ritual is prompted.

## 6. Threads

| Where | What |
|---|---|
| **`trackingQueue`** (serial) | Pose fusion, the filter, and every PHASE call. PHASE's thread safety is undocumented, so it stays on one queue |
| **Main** | SwiftUI, the state machine, the writes to `state` / `snapshot` / `needsCalibration` |
| **Crossing over** | `SessionSnapshot` is copied to main. `FrameConfigStore` and `CalibrationService` use locks because both sides touch them. `FixPipeline` needs no lock: it's tracking-queue only |

## 7. Debugging tools

- **Debug HUD** (session screen): live values for everything, plus CSV export.
- **Sign flips** (in the HUD): switches for the spec's §15 field troubleshooting tree, so a wrong sign takes minutes to fix rather than a rebuild.
- **Tuning** (in the HUD): live sliders for key constants.
- **Desk simulation** (Home → Developer): scripted GPS paths and a synthetic head.
- **Frame probe** (Home → Developer): measures the AirPods' sensor frame. **Run it on any fresh install:** the code's default frame is 90° wrong for these AirPods, and the measured one lives only in `UserDefaults`.

Test files map onto layers: `WrapMath`/`Geo`/`Frame` (math), `Smoothing` (filter and clamp), `Calibration`, `Reducer`, `Tuning`, `SessionLogger`, `SessionIntegration` (a full desk run through real PHASE) and `UISmoke` (every screen renders).

## 8. Known issues

Found while reviewing the code, and deliberately not changed by the refactor. None of them has been reproduced on hardware.

| Severity | Issue | Where |
|---|---|---|
| High | **Replace audio, then Cancel, loses the saved ghost's sound.** The old file is deleted during import, before Save. | `GhostEditorView.adopt(importing:)` |
| Medium | **GPS banners can get swallowed.** `gpsDegraded` is set while awaiting calibration even though the reducer ignores the event, so the banner never appears once running until a strong fix clears the flag. The same flag makes `accuracyPoor → gpsLost` unreachable. | `SessionCoordinator.checkGPSHealth` |
| Low | `state` is read on the tracking queue while main writes it, which is an unsynchronised read. | `checkGPSHealth`, `appendLogRow` |
| Gap | The "recalibrate?" hint is never shown, and it fires on one bad fix rather than sustained error. | `CalibrationService.suggestsRecalibration` |
| Gap | CSV replay is only tested for parsing. Nothing in the app can start it. | `ReplayLocationProvider` |

---

# Check your mental model

If you can answer these confidently, you know what's going on. Try each one before opening its answer.

<details>
<summary><b>1. GPS drops out for 10 seconds while you're walking. What do you hear, and what happens in the code second by second?</b></summary>

The sound never stops, because the heartbeat comes from the AirPods, not GPS. The position extrapolates for 1.5 s, then freezes. At 8 s `checkGPSHealth` sends `.gpsWentStale` and the state becomes `degraded(.gpsLost)`: a banner appears and audio plays from the last pose. The next *strong* fix (≤15 m) sends `.gpsRecovered`. If that fix is more than 20 m from the frozen estimate, it's held as an outlier, and three in a row snap the filter.
</details>

<details>
<summary><b>2. Why can't the app just use the AirPods' yaw as a compass direction? How does it get a real direction, and when does it lose it?</b></summary>

The CoreMotion reference frame's horizontal axes are arbitrary, so `attitudeYaw` only means something as a change. `yawOffset` supplies the constant: `trueYaw = attitudeYaw + yawOffset`. It comes from the compass ritual (precise) or from 15 m of GPS course (coarse), then gets slow course correction while walking. Disconnecting invalidates it, because the reference frame re-randomises on reconnect.
</details>

<details>
<summary><b>3. Name each term in <code>C ∘ R ∘ q_attitude ∘ H</code>. If FrameProbe's measured nose direction is 25° off, why does the sound still point the right way once calibrated?</b></summary>

`H` is listener → sensor (measured), `q_attitude` is sensor → reference (live), `R` is reference → ENU (`yawOffset`), `C` is ENU → PHASE (fixed). `up` comes from gravity and `forward` is derived as `up × right`, so a bad nod axis can only rotate `forward` *about up*. That's a constant yaw error, which `yawOffset` absorbs exactly. What remains is a small second-order wobble when the head pitches. `testNodAxisErrorIsAbsorbedByCalibration` proves the level-head case.
</details>

<details>
<summary><b>4. You're 2 m from the ghost with 8 m GPS accuracy, and the ghost is 3 m above your ears. Where does PHASE think the source is? When does that stop?</b></summary>

The clamp is active, with `rMin = max(4, 8) = 8 m`. The source renders 8 m away horizontally along a slowly low-passed bearing, still 3 m up (height survives the clamp). It's placed at `listener + renderRel`, so the listener and the world model are untouched. It releases when horizontal distance exceeds `8 × 1.25 = 10 m`. `rMin` follows accuracy, so better GPS shrinks both numbers.
</details>

<details>
<summary><b>5. A single fix lands 100 m away, then GPS returns to normal. What happens? What if the 100 m position is actually correct?</b></summary>

The fix is rejected as `.teleportCandidate`: the estimate doesn't move and the streak becomes 1. The next plausible fix resets the streak, so there's no audible jump. If the far position is real, three consecutive far fixes snap the filter there with velocity zeroed, on the view that the filter was wrong rather than the GPS. `FixPipeline` and `Tuning` hold the gates and thresholds.
</details>

<details>
<summary><b>6. Why does the app start playing before calibration? And which two states differ in whether the sound plays, despite both being "something's wrong"?</b></summary>

An unaligned ghost is still useful feedback, and walking can calibrate it hands-free, so `.firstFixAccepted` emits `.startAudio` regardless. `degraded` keeps playing, because being slightly wrong beats silence. `paused` stops the sound, because the output can't be trusted to work at all: the AirPods are gone, the audio route is a speaker, or there's an interruption. `SessionState.shouldPlayAudio` encodes this, though `awaitingCalibration` is also audible once audio has started.
</details>

<details>
<summary><b>7. What does a desk simulation with scripted GPS and a synthetic head actually prove, and what can only a field walk prove?</b></summary>

It proves the real `FixPipeline`, filter, clamp, reducer, coordinator and PHASE graph work together, because scripted fixes enter at the same point as real ones. It can't prove real GPS quality, real compass behaviour (with a scripted path `headingProvider` is nil, so the ritual reports no compass), real AirPods drift, or that the signs are right against the physical world. Those are spikes S3–S5 and the §15 tree.
</details>

<details>
<summary><b>8. <code>FixPipeline</code> has no lock but <code>CalibrationService</code> has one. Why? And why must PHASE calls stay on one queue?</b></summary>

Only the tracking queue ever touches `FixPipeline`. `CalibrationService` is written from two sides: course updates on the tracking queue, the ritual and invalidation on main, and `quality` is read by the reducer on main. PHASE's thread safety is undocumented, so single-queue use is the safe design regardless.
</details>

<details>
<summary><b>9. On the first field walk the ghost sounds mirrored left/right, while head turns feel stable. Where's the bug likely to be, and how do you fix it without rebuilding?</b></summary>

Stable head turns point away from the rotation chain and towards the position mapping: `east → +x` in `Frames.phasePosition`. Turn on **Debug HUD → Sign flips → flip east** (§15 step 1). If head turns moved the source the *same* way as your head, that would instead be the listener rotation, fixed with "conjugate listener". Whatever you flip, fold it into the defaults afterwards and record it in `CLAUDE.md`.
</details>
