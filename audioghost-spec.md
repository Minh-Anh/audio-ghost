# AudioGhost — Implementation Spec & Plan (v2)

A GPS-anchored spatial audio "ghost" for iOS. The user places a mono audio file at a real-world coordinate + height; walking around with AirPods in and the phone in a pocket, the sound appears to emanate from that fixed world point regardless of body or head movement.

**This document is self-contained.** It is written to be handed to Claude (Opus for design-critical modules, Sonnet for implementation plumbing) in Claude Code with no human clarification available. Where reality may disagree with this spec (SDK signatures, sensor frame conventions), the spec prescribes an empirical procedure rather than an assumption — follow those procedures instead of guessing. §16 tells the implementing model exactly how to work through this document.

**Working title:** AudioGhost.

---

## 0. Reading Guide for the Implementing Model

- Everything marked **[VERIFY]** is a claim that must be checked against the current SDK or the physical device before building on it. Do not silently "fix" spec code to match a hallucinated API — check the actual headers/docs.
- Everything marked **[EMPIRICAL]** has a prescribed measurement procedure. Run the procedure; hard-code the result in `Frames.swift` or `Tuning.swift` with a comment citing the procedure.
- All angles are **radians** internally. Degrees exist only at UI boundaries and CoreLocation boundaries. All positions are **meters, Double** internally; `Float` only at the PHASE handoff.
- Maintain a `CLAUDE.md` in the repo root containing: the frame conventions table (§6.1 results), the tuning constants table (§13), and the "current phase" status. Update it as phases complete — it is the memory between Claude Code sessions.

---

## 1. MVP Definition

### In scope
- Import one audio file (Files app document picker); auto-downmix to mono.
- Place one ghost: type lat/lon + height, or "Drop here" (capture current smoothed GPS fix), with a MapKit pin for visual confirmation. Height = meters above the local ground plane (§5.4).
- Listening session: audio loops forever via PHASE, attenuating with distance, world-anchored.
- Head tracking via `CMHeadphoneMotionManager`; position via `CLLocationManager`. No camera, no ARKit.
- Yaw calibration flow (compass-assisted ritual) + course-based drift correction while walking.
- Runs with phone locked / in pocket (background audio + background location).
- Debug HUD + CSV session logging (this is a developer instrument as much as a product).
- Ghost persists across launches. Fully local; no backend, no accounts.

### Explicit non-goals (MVP)
Multiple simultaneous ghosts (architect for N, build UI for 1) · proximity triggers / one-shot playback · ARKit fusion · occlusion/reverb/environment modeling · ghost sharing · barometric altitude · Android · lock-screen UI (Live Activity) · Watch.

### Target hardware & OS
- iOS 17.0+ deployment target. **[VERIFY]** Raise to 18 only if an API you need demands it.
- AirPods with head tracking (AirPods Pro any gen, AirPods 3/4, AirPods Max). Gate on `CMHeadphoneMotionManager().isDeviceMotionAvailable` at session start; show a blocking explainer if false or if the route is not headphones.
- Outdoor use assumed. The app reports GPS accuracy honestly rather than pretending.

### Acceptance criteria (field-testable, phone locked & pocketed for all)
1. **Rotate-in-place @ 30 m:** perceived source direction drifts < ~15° over 2 minutes post-calibration.
2. **Circle walk (r ≈ 20 m):** source stays centered on the anchor; loudness roughly constant.
3. **Approach from 100 m:** loudness rises smoothly; no teleports on GPS jumps.
4. **Inside GPS noise of the anchor:** audio is stable near/overhead, not whipping around the head (near-field clamp §5.6).
5. **Robustness:** survives a Siri interruption and an AirPods-out-and-back-in mid-session without needing an app relaunch.

---

## 2. Key References & What to Take From Each

- **Cenatus, "The Situationists' Walkman — a deep dive into Apple's PHASE audio engine"** (cenatus.org blog). Architectural blueprint for the PHASE side: engine → listener → source graph, spatial mixer + geometric-spreading distance model, looping sampler nodes, listener transform driven by headphone motion. Also existence proof that the locked-screen, phone-in-pocket experience is achievable.
- **Headitude (github.com/DanielRudrich/Headitude)** — macOS app streaming AirPods orientation via OSC. Take the **concept** of its gravity-based mounting calibration (press → nod → release; solve for the fixed rotation between sensor frame and true head frame). Do not port code without checking its license; it's a different platform anyway. Mounting calibration is post-MVP (§6.5) but the architecture reserves a slot for it.

The novel engineering — solved by neither reference — is (a) aligning drifting, arbitrarily-referenced AirPods yaw to true north with no camera and the phone pocketed (§6), and (b) GPS→audio-space conversion with noise handling (§5). Those two sections plus their appendices are where the project's risk lives; everything else is standard iOS work.

---

## 3. Architecture

Strict separation of *tracking* (where is the listener, where is their nose pointing), *world model* (where is the ghost), and *rendering* (PHASE). All tracking converges into one value type:

```swift
struct ListenerPose: Sendable {
    var enuPosition: SIMD3<Double>    // meters, East-North-Up, relative to session origin
    var headOrientationPHASE: simd_quatf // final listener rotation, PHASE world frame
    var horizontalAccuracy: Double    // meters (GPS-reported)
    var motionTimestamp: TimeInterval // last headphone-motion sample time
    var locationTimestamp: TimeInterval
}
```

### 3.1 Modules

| Module | Responsibility | Model |
|---|---|---|
| `CoordinateMath` | Geodetic↔ENU, bearing/distance, quaternion helpers, frame remaps. Pure functions. Unit-tested (Appendix A/B). | Opus |
| `LocationService` | CLLocationManager wrapper: permissions, background updates, outlier rejection, smoothing, interpolation. Conforms to `LocationProviding`. | Sonnet, Opus review |
| `HeadTrackingService` | CMHeadphoneMotionManager wrapper: connect/disconnect, staleness detection, raw attitude stream, mounting-correction slot. Conforms to `HeadPoseProviding`. | Sonnet |
| `CalibrationService` | Yaw-offset estimation (compass ritual), course-based drift correction, calibration-quality state. | Opus |
| `SpatialAudioEngine` | PHASE graph and lifecycle; listener transform updates; near-field clamp applied at this boundary. | Opus setup, Sonnet plumbing |
| `SessionCoordinator` | State machine (§8); update loop; interruption/route/disconnect handling; logging. | Opus |
| `GhostStore` | JSON-file persistence of ghosts + copied audio assets. | Sonnet |
| `SessionLogger` | Ring buffer of per-tick records; CSV export via share sheet. | Sonnet |
| UI (SwiftUI) | Home, GhostEditor, CalibrationFlow, SessionScreen, DebugHUD, FrameProbe (debug-only). | Sonnet |

### 3.2 Provider protocols (test seams — build these first)

```swift
protocol LocationProviding: AnyObject {
    var latest: SmoothedFix? { get }          // thread-safe snapshot
    func start() async throws                 // throws PermissionError
    func stop()
}
protocol HeadPoseProviding: AnyObject {
    var isConnected: Bool { get }
    var onSample: ((HeadSample) -> Void)? { get set } // called on trackingQueue
    func start() throws
    func stop()
}
```

Two extra conformers ship in the app target (debug builds): `ScriptedLocationProvider` (plays a GPX-like path at real time or Nx speed) and `ReplayProviders` (re-run a field CSV log through the whole pipeline). These make the pipeline testable at a desk — without them every tuning iteration costs a field walk. **They are not optional.**

### 3.3 Concurrency model
- One serial `trackingQueue` (DispatchQueue) owns all pose fusion. CoreMotion delivers onto an `OperationQueue` targeting it; CoreLocation delegate callbacks hop onto it.
- The **headphone-motion callback is the heartbeat** (~25 Hz **[EMPIRICAL: measure]**): each sample triggers pose fusion + `SpatialAudioEngine.updateListener(_:)`. Rationale: display-linked timers stop when backgrounded; motion callbacks continue (verified in Spike S1). Location updates (~1 Hz) just refresh the smoothed-position target; position is interpolated per tick (§5.5).
- UI state lives in a `@MainActor @Observable SessionViewModel` fed by throttled (4 Hz) snapshots from the trackingQueue. Never touch PHASE or fusion state from the main actor.
- PHASE calls (`transform` sets, event start/stop) happen only on trackingQueue. **[VERIFY]** PHASE thread-safety is undocumented enough that single-queue discipline is the safe design regardless.

---

## 4. Data Model & Audio Import

```swift
struct Ghost: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = "Ghost"
    var latitude: Double            // WGS84 degrees
    var longitude: Double
    var heightAboveGround: Double = 1.6   // meters; see §5.4 for semantics
    var audioFileName: String       // relative to Documents/Audio/
    var rolloffFactor: Double = 1.0
    var cullDistance: Double = 400
    var referenceLevelDB: Double = 0      // per-ghost trim via PHASE calibration level
}
```

`GhostStore`: read/write a single `ghosts.json` in Documents atomically. No SwiftData/CoreData — nothing here justifies it.

### 4.1 Audio import pipeline (`AudioImport.swift`)
1. `.fileImporter` → security-scoped URL → `startAccessingSecurityScopedResource`, copy into a temp location, stop accessing. Never retain scoped URLs.
2. Open with `AVAudioFile`. Validate duration > 0.5 s; reject > 20 min (memory: assets load resident, §7).
3. If channel count > 1: downmix to mono — average channels sample-wise via `AVAudioConverter` (or manual buffer math: `mono[i] = mean(ch[c][i])`, then scale by 1/√N to be safe against clipping? No — plain mean; then peak-normalize below).
4. Peak-normalize to −1 dBFS (scan max abs sample, scale). This makes `referenceLevelDB` trims meaningful across differently-mastered files.
5. Write Linear PCM `.caf` (Float32, source sample rate) to `Documents/Audio/<uuid>.caf`. PHASE resamples internally **[VERIFY]** — if a sample-rate error surfaces at asset registration, resample to 48 kHz here.
6. Report to the user: "Converted to mono, normalized" when applicable.

Edge cases to handle: DRM/unreadable file (catch AVAudioFile init throw → user-facing error) · zero-byte file · import while a session is running (disallow; sessions are read-only over the store).

---

## 5. Positioning & Coordinate Systems

Three frames:

1. **Geodetic**: WGS84 lat/lon (degrees) from CoreLocation.
2. **ENU**: local East-North-Up tangent plane, meters, origin = session origin (first accepted fix of the session; also recompute the ghost's ENU position against this origin at session start).
3. **PHASE world**: right-handed, y-up (SceneKit-like): **+x right, +y up, −z forward**. Convention chosen here: identity listener faces **true north**, so `east → +x`, `up → +y`, `north → −z`.

### 5.1 Geodetic → ENU (canonical formulas)

Use distance + initial bearing between origin and point (great-circle; exact enough at any scale, no per-axis approximation errors):

```
φ = latitude in radians, λ = longitude in radians, R = 6_371_000 m
Δφ = φ2 − φ1;  Δλ = λ2 − λ1

haversine distance:
  a = sin²(Δφ/2) + cos φ1 · cos φ2 · sin²(Δλ/2)
  d = 2R · atan2(√a, √(1−a))

initial bearing (radians clockwise from true north):
  θ = atan2( sin Δλ · cos φ2 ,  cos φ1 · sin φ2 − sin φ1 · cos φ2 · cos Δλ )

ENU (relative to point 1 as origin):
  east  = d · sin θ
  north = d · cos θ
  up    = 0            // altitude handled separately, §5.4
```

Implement as pure functions in `Geo.swift`; unit tests with the worked vectors in **Appendix B** (tolerance 0.15 m at 100 m). `CLLocation.distance(from:)` may be used to cross-check in tests but the shipped math is the above (deterministic, testable without CoreLocation).

### 5.2 ENU → PHASE position

```swift
@inline(__always)
func phasePosition(_ enu: SIMD3<Double>) -> SIMD3<Float> {
    // enu = (east, north, up)  →  PHASE (x=east, y=up, z=−north)
    SIMD3<Float>(Float(enu.x), Float(enu.z), Float(-enu.y))
}
// enu is stored as (x: east, y: north, z: up); write the component shuffle explicitly, no clever swizzles.
```

Build the listener transform as a rigid `simd_float4x4` from `headOrientationPHASE` (rotation) + `phasePosition(pose.enuPosition)` (translation, columns.3). **No scale ever** — PHASE listener transforms must be rigid.

Sign conventions here are the intended design and **[EMPIRICAL]** — the §15 troubleshooting tree makes a wrong sign a ten-minute fix on the first field walk, not a mystery. Do not churn on signs at a desk; encode the design, test in the field, flip per the tree.

### 5.3 GPS pipeline (`LocationService`)

Configuration:
```swift
manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
manager.activityType = .fitness
manager.allowsBackgroundLocationUpdates = true
manager.pausesLocationUpdatesAutomatically = false
manager.showsBackgroundLocationIndicator = true
```

Per raw fix, in order:
1. **Reject** if `horizontalAccuracy < 0` or `> Tuning.maxAcceptableAccuracy (30 m)` or `abs(fix.timestamp.timeIntervalSinceNow) > 5`.
2. **Teleport check:** if `distance(raw, smoothed) > Tuning.teleportDistance (20 m)` — increment a counter; at 3 consecutive, snap smoothed := raw (the filter was wrong, e.g. after tunnel/signal loss). Otherwise:
3. **Exponential smoothing** with accuracy-scaled time constant:
```swift
// dt = seconds since previous accepted fix
let tau = Tuning.tauMin + (Tuning.tauMax - Tuning.tauMin)
        * clamp((accuracy - 5) / 25, 0, 1)      // τ: 1 s @ ≤5 m … 3 s @ 30 m
let alpha = 1 - exp(-dt / tau)
smoothedENU += alpha * (rawENU - smoothedENU)
```
4. Also store `fixVelocity = (smoothedENU − previousSmoothedENU) / dt` (clamped to 3 m/s) for interpolation.

A 2D constant-velocity Kalman filter is the designed upgrade path — keep smoothing behind a `PositionFilter` protocol so it can be swapped without touching callers. Do **not** build the Kalman filter for MVP.

### 5.4 Height / altitude

GPS vertical accuracy is ±10 m or worse — **never use GPS altitude**. Flat-ground model:
- Listener ears are at `up = 0` always.
- Ghost `up = ghost.heightAboveGround − Tuning.listenerEarHeight (1.6 m)`.

So height 5 m renders 3.4 m above ear level: correct elevation cues on flat terrain, graceful degradation on slopes. UI copy: "height above the ground where you're standing." Barometer (`CMAltimeter` relative altitude) is post-MVP.

### 5.5 Per-tick position interpolation

On each motion heartbeat (~25 Hz), the position handed to the pose is:
```swift
let age = now - lastFixTime               // typically 0…1.2 s
let predicted = smoothedENU + fixVelocity * min(age, 1.5)
```
Dead-reckoning beyond 1.5 s is frozen (velocity extrapolation over stale data walks the source away). If `age > Tuning.gpsStaleTimeout (8 s)` → session enters `.degraded(reason: .gpsLost)` (§8): keep rendering at last pose, surface a warning; recover automatically on next accepted fix.

### 5.6 Near-field clamp (applied inside `SpatialAudioEngine`, at the boundary)

Raw geometry inside GPS noise makes the ghost orbit the head violently. Per tick:
```swift
let rel = ghostENU - listenerENU                    // horizontal components
let r = length(rel.horizontal)
let rMin = max(Tuning.nearFieldFloor(4.0), pose.horizontalAccuracy)
if r < rMin {
    // hold distance at rMin along a slowly-smoothed bearing
    smoothedBearing = lowpass(smoothedBearing, atan2Bearing(rel), tau: 3.0, dt: dt) // wrap-aware!
    renderRel.horizontal = rMin * unitVector(bearing: smoothedBearing)
    renderRel.up = rel.up                            // keep true height
} else {
    smoothedBearing = atan2Bearing(rel)              // track truth when outside
    renderRel = rel
}
```
The bearing low-pass must interpolate on the circle (wrap-aware: filter the error via `wrapToPi`, not raw angles). Hysteresis: exit the clamp only when `r > rMin * 1.25` to avoid boundary flapping. Note this moves the *source's rendered* transform, not the listener — implement by setting the source transform to `listener + renderRel` in this regime. This is the one exception to "source transform is static."

---

## 6. Head Tracking & Calibration

### 6.1 The FrameProbe procedure **[EMPIRICAL — do this before writing fusion code]**

Apple's documentation of the headphone-motion sensor frame is thin, community reports conflict, and this spec refuses to guess. Build a debug-only screen (`FrameProbe`) first, in Phase 1:

- Displays live: quaternion components (w,x,y,z), gravity vector, and three derived vectors `q.act(±x̂/ŷ/ẑ)`.
- Scripted moves, each held 3 s while the screen logs means: (1) look straight ahead, level; (2) turn head 90° right, level; (3) return, nod 45° down; (4) roll head to right shoulder.
- From the logs, determine and record in `Frames.swift` as named constants with comments:
  - `headForwardLocal: SIMD3<Double>` — the sensor-frame vector pointing out the nose.
  - `headUpLocal: SIMD3<Double>` — sensor-frame vector pointing out the top of the head.
  - Handedness/sign of yaw: does turning right increase or decrease the derived yaw (§6.2)?
- Reference frame facts to confirm: gravity is constant in the *reference* frame (z-vertical), yaw is arbitrary at connect, pitch/roll are absolute.

Ten minutes of measurement eliminates the entire class of "which axis is forward" bugs. All downstream math is written against `headForwardLocal`/`headUpLocal`, never against literal axes.

### 6.2 Yaw extraction and alignment

Definitions (compass convention): **yaw is radians clockwise from north**, in [−π, π).

```swift
// attitude q: rotation from head-local to CoreMotion reference frame (z-up, x/y arbitrary)
func attitudeYaw(_ q: simd_quatd) -> Double {
    let f = q.act(Frames.headForwardLocal)
    let fh = SIMD2<Double>(f.x, f.y)                 // horizontal projection (reference z is up)
    guard length(fh) > 0.05 else { return lastAttitudeYaw }  // gimbal guard: looking straight up/down
    let ccw = atan2(fh.y, fh.x)                      // math-convention CCW angle
    return wrapToPi(-ccw + Frames.yawSignFix)        // sign per FrameProbe; absolute value is arbitrary anyway
}
```

The absolute value of `attitudeYaw` is meaningless (reference x/y are arbitrary at connect) — only *changes* matter, because calibration absorbs the constant:

```
trueYaw = wrapToPi(attitudeYaw + yawOffset)
```

`yawOffset` is the single most important scalar in the app. It is owned by `CalibrationService`, is invalid until first calibration, and is invalidated on AirPods reconnect (reference frame resets **[VERIFY in S1 logs]** — assume it does; a reconnect forces recalibration or, if walking, silent course-based re-acquisition §6.4).

The gimbal guard matters: someone lying on the grass looking straight up makes `fh ≈ 0`; hold last yaw rather than emitting noise.

### 6.3 Calibration ritual (compass-assisted)

Flow (full-screen guided UI):
1. Instruct: "Hold the phone flat like a compass, pointing where your nose points. Stand still."
2. Start `manager.startUpdatingHeading()` with `headingOrientation = .portrait` **only now** (heading updates are power-hungry, and a pocketed compass is garbage — never read heading outside this flow).
3. Collect ~2 s of concurrent samples. Require every `heading.headingAccuracy` ∈ (0, 15°]; if iOS reports −1 (needs calibration) show the "wave in a figure 8" instruction. Average heading on the circle (average the unit vectors, not the degrees — 359° and 1° must average to 0°). Average attitudeYaw the same way. Reject if heading spread > 5° or attitude spread > 3° (user moved).
4. `yawOffset = wrapToPi(trueHeadingRadians − attitudeYawMean)`.
5. **Verification screen:** an arrow rendered from live `trueYaw` and the bearing to the ghost — "the arrow should point at where you placed the ghost." Confirm / Redo. This screen doubles as the fastest field diagnostic in the app; make Recalibrate reachable from the session screen in one tap.
6. `stopUpdatingHeading()`.

Store `calibrationTimestamp` and show calibration age on the HUD. If the app also detects sustained course-correction error > 25° (§6.4), surface a "recalibrate?" hint.

### 6.4 Course-based drift correction (ship in MVP)

AirPods yaw is gyro-integrated with no magnetometer: expect drift of several degrees per 10 minutes **[EMPIRICAL: S5 measures your units]**. People walking mostly face their direction of travel; use GPS course as a slow truth source. On each accepted fix:

```swift
guard fix.speed > Tuning.courseMinSpeed(0.8),          // m/s; course is noise when slow
      fix.courseAccuracy >= 0, fix.courseAccuracy < 25,  // degrees [VERIFY field name/availability]
      calibration.isValid else { return }
let err = wrapToPi(fix.courseRadians - trueYawNow)
guard abs(err) < Tuning.courseGateAngle(60°.rad) else { return } // head turned while walking: don't corrupt
yawOffset = wrapToPi(yawOffset + Tuning.courseGain(0.02) * err)
```

With ~1 Hz fixes, gain 0.02 corrects a 10° drift in ~2–3 minutes of walking while being insensitive to glances. Expose live `err` on the HUD; it is the tuning signal for the gain. **Cold-start bonus:** if `calibration.isValid == false` but the user has walked > 15 m with valid course, seed `yawOffset` directly from `course − attitudeYaw` and mark calibration `.coarse` — the app self-calibrates on a walk even if the user skipped the ritual. Keep the ritual as the precise path; surface calibration quality (`none / coarse / precise`) in the UI.

### 6.5 Mounting correction (post-MVP; reserve the slot)

AirPods sit differently in every ear → raw attitude can be tilted 10–20° vs. the true head frame, distorting mainly elevation cues. `HeadTrackingService` applies `mountingCorrection: simd_quatd = .identity` to every sample (`q_corrected = q_raw * mountingCorrection` — verify side during implementation with FrameProbe). Post-MVP, implement Headitude-style estimation: press → slow nod → release; the nod's rotation axis is the head's pitch (ear-to-ear) axis and averaged gravity gives down; solve the fixed sensor→head rotation from those two direction pairs (classic two-vector alignment, e.g. TRIAD method). Skipping this in MVP is deliberate: elevation is the weakest binaural cue and the ghost is usually meters away.

### 6.6 Composing the final PHASE listener rotation

```
q_PHASE = C ∘ R_up(−yawOffset_ccwEquivalent) ∘ q_attitude ∘ H
```
- `q_attitude`: raw (mounting-corrected) sample.
- `R_up(·)`: rotation about the reference-frame vertical that realizes `trueYaw = attitudeYaw + yawOffset` (sign resolved by the unit tests below — compass-cw vs math-ccw is exactly the kind of thing tests must pin, not prose).
- `H`: fixed remap sensor-head-frame → PHASE-listener-local frame (listener local: −z out the nose, +y out the top of the head). Built from `headForwardLocal`/`headUpLocal` (FrameProbe).
- `C`: fixed basis change CoreMotion-reference (z-up) → PHASE world (y-up, −z north).

Implement `C` and `H` as constant quaternions in `Frames.swift` constructed from explicit basis vectors (`simd_quatd(from:to:)` composed, or build a 3×3 matrix from basis columns and convert) — never hand-typed component literals.

**The three canonical unit tests** (write them before the implementation; they define correctness):
1. Level head, `trueYaw = 0` ⇒ `q_PHASE.act((0,0,-1)) ≈ (0,0,-1)` (facing north) and `q_PHASE.act((0,1,0)) ≈ (0,1,0)`.
2. Level head, `trueYaw = +90°` (east) ⇒ forward ≈ `(1,0,0)`.
3. Facing north, pitched up 30° ⇒ forward ≈ `(0, sin30°, −cos30°)`.

Feed synthetic `q_attitude` values constructed in the test from the same Frames constants (rotate about reference-vertical / ear axis), so the tests exercise the full composition. If these pass and the field walk still mirrors, the flip is in §5.2's position mapping — the troubleshooting tree (§15) separates the two cases.

### 6.7 Staleness & disconnect
- Track `lastSampleAge` on the heartbeat consumer side; if > 0.5 s while "connected", treat as stalled (rare; recover by restarting updates).
- `headphoneMotionManagerDidDisconnect` → session `.paused(.airpodsDisconnected)`: stop the sound event (fade 0.3 s if API allows **[VERIFY]**, else stop), keep GPS warm.
- Reconnect → invalidate yawOffset per §6.2, auto-recalibrate via course if moving, else prompt.

---

## 7. PHASE Audio Graph (`SpatialAudioEngine`)

Graph shape (per the Cenatus architecture). **[VERIFY]** every initializer signature against the current SDK before use — PHASE signatures have drifted between iOS versions; the *shape* below is correct, the exact spellings may not be. If a signature doesn't exist, find the current one in the headers; do not invent parameters.

```swift
let engine = PHASEEngine(updateMode: .automatic)

let listener = PHASEListener(engine: engine)
listener.transform = matrix_identity_float4x4
try engine.rootObject.addChild(listener)

let source = PHASESource(engine: engine)             // point source; volumetric is post-MVP
source.transform = transform(position: ghostPHASEPosition)
try engine.rootObject.addChild(source)

let asset = try engine.assetRegistry.registerSoundAsset(
    url: monoCafURL, identifier: ghost.id.uuidString,
    assetType: .resident,                            // switch to .streamed if files exceed ~5 min
    channelLayout: nil, normalizationMode: .dynamic)

let pipeline = PHASESpatialPipeline(flags: [.directPathTransmission])!  // failable init [VERIFY]
let mixer = PHASESpatialMixerDefinition(spatialPipeline: pipeline)
let dist = PHASEGeometricSpreadingDistanceModelParameters()
dist.rolloffFactor = ghost.rolloffFactor
dist.fadeOutParameters = PHASEDistanceModelFadeOutParameters(cullDistance: ghost.cullDistance)
mixer.distanceModelParameters = dist

let sampler = PHASESamplerNodeDefinition(soundAssetIdentifier: ghost.id.uuidString,
                                         mixerDefinition: mixer)
sampler.playbackMode = .looping
sampler.setCalibrationMode(calibrationMode: .relativeSpl, level: ghost.referenceLevelDB)
try engine.assetRegistry.registerSoundEventAsset(rootNode: sampler, identifier: eventID)

try engine.start()
let event = try PHASESoundEvent(engine: engine, assetIdentifier: eventID,
                                mixerParameters: /* bind spatial mixer → source + listener */)
event.start()   // consider event.prepare(...) then start for gapless begin [VERIFY]
```

Per tick (trackingQueue only): set `listener.transform`; in near-field regime also set `source.transform` (§5.6). Rigid transforms only.

### 7.1 AVAudioSession & backgrounding
- Category `.playback`, mode `.default`, activate before `engine.start()`.
- Background modes: `audio`, `location`. The active audio session is what keeps the app alive and (per S1) keeps motion callbacks flowing.
- **Interruptions** (`AVAudioSession.interruptionNotification`): on `.began` → `session.pause(.audioInterruption)` (stop event, keep engine). On `.ended` with `.shouldResume` → recreate/restart the sound event and resume. Test with Siri and a phone call (acceptance criterion 5).
- **Route changes** (`routeChangeNotification`): if new route is not headphones (speaker/CarPlay) → pause with reason `.routeNotHeadphones`; spatial audio through a speaker is meaningless and loud.
- **Media remote**: nice-to-have, not MVP; the Stop control lives in the app.

### 7.2 Double-spatialization guard **[EMPIRICAL — Spike S2]**
Because this app consumes raw head motion and rotates the PHASE listener itself, the OS-level "Spatial Audio / head tracked" feature must NOT also rotate the output. Symptom if it does: turning the head sweeps the source ~2× or fights itself. S2 verifies with a fixed source; if double-rotation appears, investigate `AVAudioSession` spatialization controls (e.g. `setSupportsMultichannelContent(false)`) and instruct the user to disable head-tracked Spatial Audio for the app (Control Center → volume long-press) as a last resort; document whichever resolution works in CLAUDE.md.

### 7.3 Loudness sanity
Real-world falloff over 100 m with rolloff 1.0 is a 40 dB swing — likely too dynamic for street ambience. Expose `rolloffFactor` (0.3–2.0) in advanced settings; expect field tuning toward ~0.6–0.8 for audibility at distance. `cullDistance` 400 m default with fade-out avoids hard cuts at the boundary.

---

## 8. Session State Machine (`SessionCoordinator`)

States (enum with associated values; drive both behavior and UI directly from it):

```
idle
acquiringFix            // waiting for first accepted GPS fix ≤ 20 m accuracy
awaitingCalibration     // pose available, yawOffset invalid
running(quality: .precise | .coarse)
degraded(reason)        // running but impaired: .gpsLost | .accuracyPoor
paused(reason)          // .airpodsDisconnected | .audioInterruption | .routeNotHeadphones | .userPaused
failed(SessionError)    // unrecoverable this session: permissions, no head-tracking AirPods, asset load failure
```

Transitions worth spelling out:
- `acquiringFix → awaitingCalibration` on first accepted fix (this fix seeds the ENU origin).
- `awaitingCalibration → running(.precise)` on ritual success; `→ running(.coarse)` on course-based auto-seed (§6.4).
- `running ↔ degraded(.gpsLost)` per §5.5 timeout / next accepted fix. In `degraded`, audio keeps playing at last pose — going silent is worse than being slightly wrong.
- `running → paused(x)` on the §6.7/§7.1 events; `paused → running` on the matching recovery, re-entering `awaitingCalibration` first if yawOffset was invalidated and no coarse re-seed is available.
- Any state → `failed` only for genuinely unrecoverable causes; everything else self-heals.

The state machine is a pure `reduce(state, event) → (state, [effects])` function with unit tests for every transition above — Sonnet implements it mechanically from this table; Opus reviews the event list for completeness.

### 8.1 Failure-mode table

| Condition | Detection | Behavior |
|---|---|---|
| Location permission denied/restricted | authorizationStatus | `failed`; blocking screen with Settings deep-link |
| Motion permission denied | CMHeadphoneMotionManager error | same |
| No head-tracking AirPods | `!isDeviceMotionAvailable` or route ≠ headphones at start | `failed` with explainer listing supported models |
| GPS stale > 8 s | fix age on heartbeat | `degraded(.gpsLost)`; banner; hold last pose |
| Accuracy > 30 m sustained 15 s | accepted-fix starvation | `degraded(.accuracyPoor)`; banner "GPS is weak here" |
| AirPods out / case | didDisconnect | `paused`; stop event; invalidate yawOffset |
| Siri/call | interruption notification | `paused`; auto-resume if `.shouldResume` |
| Route → speaker | route change | `paused(.routeNotHeadphones)` |
| Audio file missing/corrupt at start | asset registration throw | `failed(.assetLoad)`; point user to re-import |
| App killed in background | n/a | acceptable for MVP; session does not auto-restart. Persist last session config so restart is one tap. |
| Low Power Mode | `ProcessInfo.isLowPowerModeEnabled` | warn at session start (GPS cadence may drop); no behavior change |

---

## 9. UI (SwiftUI, deliberately minimal)

1. **Home** — single ghost card or empty state; Edit / Start Session; footer shows AirPods + location permission status proactively.
2. **GhostEditor** — name; audio import (shows duration + "converted to mono" note); coordinates: *Drop here* (shows live accuracy, enabled ≤ 10 m, override allowed with warning) and manual lat/lon fields (paste "48.8584, 2.2945" style input and parse both numbers from one paste); a small `Map` with a draggable pin bound two-way to the fields — the cheapest sanity check in the app; height field/slider 0–30 m; Advanced disclosure: rolloff, cull, level trim, ear height.
3. **CalibrationFlow** — the §6.3 steps as full-screen pages with a progress ring and the verification-arrow page.
4. **SessionScreen** — big Stop; distance ("42 m NE"); GPS accuracy chip; AirPods chip; calibration quality + age chip; Recalibrate button; state-machine banners; collapsible **DebugHUD**.
5. **DebugHUD** (debug + TestFlight builds) — raw vs smoothed position delta, accuracy, fix age; attitudeYaw / yawOffset / trueYaw / course / course-error; distance, bearing, clamp-active flag; engine + event state; sample rates (motion Hz, fix Hz); Export CSV button.
6. **FrameProbe** (debug builds only) — §6.1.

Locked-screen: nothing to render; the session must simply survive (criterion: all acceptance tests run pocketed). Live Activity is post-MVP.

---

## 10. Project Setup Checklist

- Targets: iOS app + unit-test target. Swift 5.10+/6 language mode as the template defaults; if strict concurrency fights CoreMotion callbacks, prefer `@preconcurrency import` over disabling checking globally.
- Signing: standard; no special entitlements needed for PHASE/CoreMotion/CoreLocation.
- Capabilities: Background Modes → **Audio**, **Location updates**.
- Info.plist: `NSLocationWhenInUseUsageDescription` ("Positions sounds in the real world around you"), `NSMotionUsageDescription` ("Tracks your head orientation via AirPods to place sounds in space"). Use When-In-Use + background mode (blue indicator is fine and honest); do **not** request Always.
- Frameworks: PHASE, CoreMotion, CoreLocation, AVFAudio, MapKit, simd. All first-party — **no third-party dependencies in this project**; every candidate (Kalman libs, etc.) is more code than the feature needs.
- Device-only development: simulator has no PHASE spatialization, no headphone motion, fake GPS. Run unit tests on simulator; run the app on device from day one.

---

## 11. Testing Infrastructure

### 11.1 Unit tests (run in CI/simulator; these are the project's safety net)
- `Geo` — Appendix B vectors (north/east/diagonal at 100 m and 1 km; tolerance 0.15 m / 1.5 m), bearing wraps, antimeridian input sanity (reject or handle |Δλ| > π by wrapping — sessions never span it, but math shouldn't explode).
- `Quaternions/Frames` — the three canonical tests (§6.6) + `wrapToPi` table (±π edges) + circular-mean tests (359°,1° → 0°).
- `Smoothing` — τ scaling; teleport counter; interpolation freeze at 1.5 s; near-field clamp entry/exit hysteresis and wrap-aware bearing filtering (source due north then due south of listener must not sweep through east arbitrarily).
- `CalibrationService` — offset computation, rejection rules, course-correction gating (speed, gate angle, gain step), coarse auto-seed.
- `SessionReducer` — every §8 transition.

### 11.2 Desk simulation (build in Phase 3, before the first field walk)
- `ScriptedLocationProvider`: plays a hardcoded path (e.g., 100 m approach at 1.4 m/s; a 20 m-radius circle) with injectable Gaussian noise (σ = 4 m) and simulated `horizontalAccuracy`. Toggleable from DebugHUD in debug builds. With real AirPods on, this lets you *hear* the approach and circle scenarios from a chair — most tuning happens here, not in the field.
- Also note Xcode's Simulate Location with GPX files works on-device; the custom provider is still preferred (controls noise + accuracy fields, works away from the Mac).
- `ReplayProviders`: feed an exported field CSV back through fusion + audio. Every field bug becomes a desk-reproducible case. This is the highest-leverage tool in the project — do not skip it.

### 11.3 Field protocol (repeat identically every field build)
Four walks — rotate-in-place @ 30 m · circle r ≈ 20 m · approach from 100 m · fly-by (pass 10 m abeam) — rate each 1–5 subjectively, export CSV, one-line notes. Keep CSVs; they are replay fixtures.

### 11.4 CSV log schema (one row per heartbeat tick, ring buffer ~30 min)
```
t, state, rawLat, rawLon, rawAcc, smoothedE, smoothedN, fixAge,
attYaw, yawOffset, trueYaw, course, courseErr, calibQuality,
ghostDist, ghostBearing, clampActive, motionHz, note
```
Plus an events stream (state transitions, calibrations, interruptions) appended as rows with `note` set. Export via share sheet as a single file.

---

## 12. Tuning Constants (`Tuning.swift` — single source of truth)

| Constant | Default | Rationale / tuning signal |
|---|---|---|
| `listenerEarHeight` | 1.6 m | settings-exposed |
| `tauMin / tauMax` | 1 s / 3 s | HUD raw-vs-smoothed delta: jittery → raise, laggy on turns → lower |
| `maxAcceptableAccuracy` | 30 m | fix-starvation rate in logs |
| `teleportDistance / teleportCount` | 20 m / 3 | post-signal-loss recovery time |
| `deadReckonMax` | 1.5 s | walk-away artifacts when stale |
| `gpsStaleTimeout` | 8 s | degraded-state entry |
| `nearFieldFloor` | 4 m | criterion 4 stability |
| `nearFieldBearingTau` | 3 s | orbiting vs sluggishness near anchor |
| `clampExitFactor` | 1.25 | boundary flapping |
| `courseMinSpeed` | 0.8 m/s | course validity |
| `courseGateAngle` | 60° | glance immunity |
| `courseGain` | 0.02 | HUD courseErr decay rate; S5 drift data |
| `motionStaleTimeout` | 0.5 s | stall detection |
| `defaultRolloff / cull` | 1.0 / 400 m | §7.3; expect field tune toward 0.6–0.8 |

Every constant: one file, doc comment, and where applicable a DebugHUD live-override (sliders in a debug sheet) so field tuning doesn't require rebuilds.

---

## 13. Risks & Spikes (Phase 0 — do first; each < half a day)

| # | Risk (existential first) | Spike |
|---|---|---|
| S1 | Headphone motion may stop with screen locked/backgrounded | Throwaway target: active `.playback` session + background modes; log motion timestamps to a file, 10 min locked in a pocket. Also log across an AirPods out/in cycle to answer §6.2's reference-reset question. **Go/no-go for the whole concept.** |
| S2 | OS spatializer double-rotating PHASE output | Same target: fixed PHASE source, turn head, confirm 1:1. Resolution per §7.2. |
| S3 | GPS quality at the actual venues (narrow streets, stone walls) | Log raw fixes + accuracy on candidate walks; decide viable zones. |
| S4 | Compass unusable at venue (metal, trams) | Log heading + headingAccuracy standing at venue. Fallback already designed: coarse course-based seeding (§6.4) means the ritual is an accuracy upgrade, not a hard dependency. |
| S5 | Yaw drift rate of the specific AirPods | 15-min stationary attitudeYaw log → informs `courseGain`. |

Record all spike numbers in CLAUDE.md; several Tuning defaults reference them.

---

## 14. Implementation Plan

Every phase ends with something runnable/testable. Suggested split: **Opus** for CoordinateMath, CalibrationService, SpatialAudioEngine setup, SessionCoordinator design, and review of everything else; **Sonnet** for services plumbing, UI, persistence, logging, and mechanical test-writing from this spec's tables.

- **Phase 0 — Spikes (0.5–2 d).** S1–S5. Deliverable: numbers in CLAUDE.md; go/no-go.
- **Phase 1 — Static spatial audio + FrameProbe (1–2 d).** Skeleton; `SpatialAudioEngine` looping a mono asset 5 m "north" (yawOffset = 0); `HeadTrackingService` raw; **FrameProbe run → Frames.swift constants recorded.** Indoor test: head-turns keep the source world-stable-ish.
- **Phase 2 — Calibration (1–2 d).** `CalibrationService` + ritual UI + verification arrow; the three canonical unit tests green *before* the fusion code is considered done. Test: the hardcoded north source is actually north after calibration.
- **Phase 3 — GPS + desk sim (2–3 d).** `LocationService` (smoothing/outliers/interpolation), `Geo` with Appendix B tests, `SessionCoordinator` loop + state machine, near-field clamp, `ScriptedLocationProvider`. Desk test: audible approach + circle scenarios from a chair. Then **first field walk** — expect a sign flip; use §15.
- **Phase 4 — Product wrapper (2–3 d).** GhostEditor (drop-here + manual + map pin), audio import pipeline, GhostStore, CalibrationFlow polish, SessionScreen, CSV export + ReplayProviders, interruption/route/disconnect handling per §8.1. Full acceptance run, pocketed.
- **Phase 5 — Tuning (ongoing).** Field protocol per build; tune via HUD overrides; adjust Tuning defaults from CSVs.
- **Post-MVP backlog (ordered):** proximity triggers & one-shot mode → multiple ghosts + map authoring → mounting calibration (§6.5) → barometric height → CMPedometer dead-reckoning between fixes → Kalman position filter → ARKit VIO fusion mode → volumetric sources/reverb → Live Activity → sharing.

---

## 15. Field-Walk Troubleshooting Tree (first walk, in order)

1. **Left/right mirrored** (ghost east sounds west): position mapping sign — flip `east → +x` in §5.2 first; if unit tests §6.6 pass, the bug is *not* in the rotation.
2. **Front/back mirrored only:** `north → −z` sign in §5.2.
3. **Head turns sweep the source ~2×:** OS spatializer double-rotation → §7.2.
4. **Head turns move the source the *same* direction (world not stable):** listener rotation applied inverted → conjugate `q_PHASE` (rotation vs. its inverse — classic transform-of-listener vs transform-of-world confusion).
5. **Source direction constant offset (e.g., always ~90° off) that calibration doesn't fix:** compass-cw vs math-ccw sign in `R_up` — flip yawOffset application sign.
6. **Correct at calibration, drifts within minutes:** drift correction not engaging — check HUD courseErr and §6.4 gates (speed/courseAccuracy fields).
7. **Ghost 'follows' you when walking straight at it:** smoothing lag or dead-reckoning overshoot — check raw-vs-smoothed delta; lower τ / clamp velocity.
8. **Chaos only near the anchor:** clamp not engaging (check `clampActive` flag) or bearing filter not wrap-aware.
9. **Elevation feels wrong / source inside skull:** ignore for MVP unless egregious (weakest cue; mounting calibration is the eventual fix).

Each is distinguishable from the HUD + CSV; none requires guessing.

---

## 16. How to Drive Opus & Sonnet Through This (for the human, and for CLAUDE.md)

- Put this file in the repo root; create `CLAUDE.md` at project start containing: current phase, Frames results, spike numbers, deviations from spec (dated, one line each).
- One Claude Code session per phase. Start each session: "Read audioghost-spec.md §§X–Y and CLAUDE.md; we are in Phase N."
- **Tests before fusion code**: instruct the model to write Appendix A/B and §6.6 tests first and get them green before wiring services together. Math bugs caught in tests cost minutes; caught in the field they cost an afternoon.
- **SDK drift rule** (repeat verbatim to the model when it hits PHASE): "If a signature in the spec doesn't compile, find the real API in the SDK headers/docs and record the correction in CLAUDE.md. Do not invent parameters, and do not delete functionality to make it compile."
- Sonnet is excellent at: the state-machine reducer from §8's table, UI from §9, log schema from §11.4, tests transcribed from tables. Opus should write or review: `Frames.swift`, §6.2–6.6, §5.6, `SessionCoordinator` design, and any change that touches a sign convention.
- Commit at every green-test milestone; tag the commit that passes each acceptance criterion.
- When something field-fails, export the CSV, add it as a replay fixture, and hand the fixture to the model with the §15 symptom number.

---

## 17. Project Structure

```
AudioGhost/
├── CLAUDE.md                    living memory between sessions
├── audioghost-spec.md           this document
├── App/                         AudioGhostApp.swift, AppState
├── Core/
│   ├── CoordinateMath/          Geo.swift, Frames.swift, Quaternions.swift, WrapMath.swift
│   ├── Location/                LocationService.swift, PositionFilter.swift, ScriptedLocationProvider.swift
│   ├── HeadTracking/            HeadTrackingService.swift
│   ├── Calibration/             CalibrationService.swift
│   ├── Audio/                   SpatialAudioEngine.swift, AudioImport.swift
│   └── Session/                 SessionCoordinator.swift, SessionReducer.swift, ListenerPose.swift
├── Store/                       GhostStore.swift, Ghost.swift
├── Support/                     Tuning.swift, SessionLogger.swift, Permissions.swift, Replay.swift
├── UI/                          Home/ GhostEditor/ Calibration/ Session/ DebugHUD/ FrameProbe/
└── Tests/                       GeoTests, FrameTests, SmoothingTests, CalibrationTests, ReducerTests
```

Conventions: radians + meters + Double internally · every frame convention documented at the top of `Frames.swift` with FrameProbe dates · no singletons (services injected via environment) · no third-party dependencies · every tuning constant in `Tuning.swift`.

---

## Appendix A — Math Utilities (exact contracts)

```swift
/// Wrap to [-π, π). wrapToPi(π) == -π. wrapToPi(3π/2) == -π/2.
func wrapToPi(_ x: Double) -> Double {
    var r = x.truncatingRemainder(dividingBy: 2 * .pi)
    if r >= .pi { r -= 2 * .pi }
    if r < -.pi { r += 2 * .pi }
    return r
}

/// Circular mean of angles (radians). mean([359°, 1°]) == 0°. Undefined (return nil) if
/// the resultant vector length < 0.1 (angles spread over the circle).
func circularMean(_ angles: [Double]) -> Double?

/// Wrap-aware low-pass: filters the *error* via wrapToPi.
func lowpassAngle(current: Double, target: Double, tau: Double, dt: Double) -> Double {
    let alpha = 1 - exp(-dt / tau)
    return wrapToPi(current + alpha * wrapToPi(target - current))
}

/// Bearing (radians cw from north) of a horizontal ENU offset. atan2Bearing(east:0, north:1) == 0;
/// (east:1, north:0) == π/2.
func atan2Bearing(east: Double, north: Double) -> Double { wrapToPi(atan2(east, north)) }
```

Unit-test each with the doc-comment cases plus edges (±π, tiny vectors).

## Appendix B — Worked Geodetic Test Vectors

Origin: **lat₀ = 43.949317, lon₀ = 4.805528** (Avignon; any origin works, tests just need consistency). Using R = 6 371 000 m: 1° latitude ≈ 111 194.93 m; 1° longitude at this latitude ≈ 111 194.93 × cos(43.949317°) ≈ 80 068 m.

| Case | lat | lon | expected ENU (east, north) | tol |
|---|---|---|---|---|
| 100 m north | 43.950216 | 4.805528 | (0, 100) | 0.15 m |
| 100 m east | 43.949317 | 4.806777 | (100, 0) | 0.15 m |
| ~141.4 m NE (100 E, 100 N) | 43.950216 | 4.806777 | (≈100, ≈100) | 0.3 m |
| 1 km south | 43.940324 | 4.805528 | (0, −1000) | 1.5 m |

Also assert: bearing(origin → 100 m north case) ≈ 0 rad; bearing(origin → 100 m east case) ≈ π/2; round-trip `enu(geodetic(enu(p)))` stable to 1 mm at 500 m. If the implementation disagrees with a vector by a near-constant scale factor, check degrees-vs-radians at the trig boundary — the classic failure.

---
*End of spec. When in doubt: measure (FrameProbe, spikes, HUD) rather than assume; keep audio playing rather than going silent; flip signs per §15 rather than re-deriving at a desk.*
