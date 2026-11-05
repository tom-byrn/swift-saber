# Swift Saber

A neon rhythm-slicing game for macOS where your **AirPods are the sabers**. Take the buds out, hold one in each fist, face the screen, and cut blocks to the beat.

- **AirPods motion control.** Uses `CMHeadphoneMotionManager`. Each sample is tagged with the bud that sent it, so each bud drives its own saber.
- **Calibration that works with any grip.** You point at the screen, then at the ceiling. The app works out how each bud sits in your hand and which way is up.
- **An original track, "Prism Run".** A 128 BPM, 2½-minute electronic track synthesized entirely in code: no samples, no licensed audio.
- **Four hand-designed difficulties** (Easy to Expert), plus One Saber maps. Blocks follow swing flow (forehand/backhand alternation), with bombs and a full light show synced to the music.
- **Scoring.** Directional cuts, swing-in / follow-through / accuracy points (max 115 per block), combo multiplier (×1 to ×8), energy bar, ranks SS to E, and saved personal bests.
- **Neon stage.** Bloom, a reflective runway, rotating prism rings, laser fans, sliced block halves, spark bursts and saber trails.
- **Audio routing.** Game audio goes to the Mac's speakers by default, so your AirPods keep streaming motion while the music plays with low latency.

## Build & run

Requires **macOS 14 Sonoma or later** and Xcode 15+ (or just the Command Line Tools: `xcode-select --install`).

```bash
./Scripts/build-app.sh --run
```

This compiles a release build, assembles and ad-hoc signs `build/Swift Saber.app`, and launches it. Use `--install` to copy it to `/Applications`. You can also open `Package.swift` in Xcode and run the `SwiftSaber` scheme.

The first launch renders the soundtrack (a few seconds) and caches it. Later launches are instant.

**Prebuilt app:** every push is built on a macOS runner by GitHub Actions (`.github/workflows/build.yml`). Download the `SwiftSaber-app` artifact from the latest run, unzip it, then right-click › Open the first time (it's ad-hoc signed). The same workflow runs the unit tests and launches the game in autoplay mode to capture screenshots of every screen (`SwiftSaber-captures` artifact).

**Watch Demo:** the level select has a *Watch Demo* button that plays the selected map with perfect autoplay sabers, so you can see how a map flows before trying it.

## Setting up your AirPods

1. **Connect your AirPods** (Pro / Max / 3rd gen or newer, anything with spatial audio head tracking) to the Mac.
2. **Turn off Automatic Ear Detection**: System Settings › *your AirPods* › Automatic Ear Detection. Otherwise the AirPods stop reporting motion as soon as they leave your ears.
3. Launch Swift Saber, choose **Set Up AirPods**, and allow motion access when macOS asks.
4. Hold one bud in each fist and follow the three prompts:
   - point at the screen
   - point at the ceiling
   - point at the screen again

   Hold still at each step until the ring fills.

### One saber or two?

AirPods label each motion sample as coming from the left or the right bud. If both buds stream, you get **two sabers** (red = left, blue = right). Some AirPods/macOS combinations only stream from **one bud at a time**. The setup screen shows exactly what's streaming. If it's one bud, you have two options:

- Play the **One Saber** maps, where a single saber cuts every block. The game switches to them automatically.
- Switch input to **AirPod + Mouse** in Settings, so the mouse or trackpad drives the second saber.

There's also a **Mouse / Trackpad** mode for playing or testing without AirPods.

## Controls

| Key | Action |
| --- | --- |
| `Return` | Play / start level |
| `Esc` or `Space` | Pause / resume (with a 3-2-1 countdown) |
| `R` | Recenter sabers: point at the screen centre first |
| `F` | Toggle full screen |
| `⌘K` | Calibrate AirPods |

AirPods have no compass, so the "forward" direction can slowly drift. With **Auto-recenter** on (the default), the sabers re-centre at every song start, so aim at the screen during the countdown. Press `R` any time to fix drift.

## Tuning (Settings)

- **Saber sensitivity**: scales your wrist rotation. Raise it if you have to swing too far.
- **AirPods motion delay**: how late motion arrives over Bluetooth. Collisions are checked against where the blocks were when you actually swung.
- **Audio offset**: shift the music relative to the blocks if hits feel early or late.
- **Lenient cut angles**: widens the accepted cut direction from ±60° to ±75°.
- **Play game audio on**: Mac speakers (recommended), the system default, or any output device.
- **Keep AirPods awake**: sends a silent stream to the AirPods so they don't go idle while in your hands.

## How it works

```
Sources/
  SaberCore/            platform-independent, unit-tested game logic
    Song.swift            arrangement of "Prism Run" (sections, chords, melody)
    MusicSynth.swift      offline synthesizer: drums, bass, pads, arps, lead, FX, reverb/delay
    LevelDesigner.swift   rhythm per section/difficulty + swing-parity direction/position rules, lights
    Calibration.swift     two-pose calibration, quaternion-convention detection via gravity
    Swing.swift           pose prediction/smoothing for ~25 Hz sensors, swing-arc tracking
    GameSession.swift     swept blade-vs-block collision, cut validation, misses, bombs
    Scoring.swift         cut score, combo/multiplier, energy, ranks
  SwiftSaber/           macOS app
    Input/                CMHeadphoneMotionManager service, thread-safe input hub, calibration flow
    Audio/                AVAudioEngine playback, output-device routing (CoreAudio)
    Render/               SceneKit stage, blocks (clip-plane shader for real halves), sabers, effects
    UI/                   SwiftUI menus, calibration, HUD, pause, results
```

There's no positional tracking (AirPods only report orientation), so each saber pivots from a virtual shoulder. Pointing the bud moves the blade across the block grid, and swinging through a block cuts it. Blade sweeps between frames are sub-sampled, so fast swings at low sensor rates still connect.

Run the core tests with `swift test`. One of them plays a whole level automatically and checks that every block can be cut cleanly.
