# NFSU2Recomp on iOS (jailbroken iPad mini 2)

This branch (`ios`) ports the NFSU2Recomp runtime from macOS to **iOS 12 on 64-bit
Apple devices**, starting with the **iPad mini 2** (A7 "cyclone", PowerVR G6430,
1 GB RAM, iOS 12.5.8, rootful jailbreak). The recompiled game code is the same as
the macOS build (the North American v1.2 `SPEED2.EXE`); only the platform layer
changes. All iOS changes are behind `TARGET_OS_IPHONE`, so the macOS builds are
unaffected.

As with the main project: **no game code or assets are in this repository.** You
need your own copy of the game; the lifted C (`gen/`) and every build (`out/`)
stay out of git.

## Status (2026-11-07)

**The full game runs on the iPad mini 2**: boot, front end, menus, Quick Race,
with sound, touch controls and the original rendering.

- On low graphics settings it holds a **stable 60 fps** (tested by playing on the
  device).
- On maxed-out settings it runs at **about 30 fps, dipping towards 20**. Measured
  in an automated Quick Race: median frame 33.7 ms, 95th percentile ~51 ms,
  ~1,200 draw calls per frame. That race is GPU-bound: GPU ~31 ms per frame,
  while the guest CPU thread waits ~12 ms per frame.
- Title screen and menus: 60 fps (16.7 ms, vsync-locked).
- Memory (phys_footprint, which jetsam enforces): **peak 376 MB** through a race and back
  to the menu, down from 570 MB in the first iOS build (target: under 450 MB).
- **Movies play** (intro, PSA, opening FMV, story movies) with the game's own VP6
  decoder; tap to skip the movies the game allows to be skipped.
- Music no longer stutters (fair GIL, see below); the iOS keyboard comes up for the
  profile name.

More optimisation is on the way: 16-bit DXT1 textures, render-pass and bandwidth
work for the tile-based GPU, and memory. The next device to test is the
**iPhone SE (2016)** (A9, 2 GB RAM).

## What the port changes

| Area | iOS change |
|---|---|
| App shell | `runtime/ios_app.m`: UIKit owns the main thread. `tests/boot.c` is compiled with `-Dmain=nfs_boot_main` and runs on a boot thread, which starts the guest thread (1 GB stack) and then runs the Metal frame loop itself. A `CAMetalLayer` view is scaled aspect-fit to the screen. |
| Input | A touch outside the controls acts as the mouse (the front end is mouse-driven). On-screen keys send DirectInput scan codes (steer, gas, brake, e-brake, N2O, Esc, Enter); remap with `NFSU2_KEY_*` in `env.txt`. MFi controllers go through the existing `gamepad.m` (iOS 13/14-only APIs are guarded). |
| Paths | `runtime/bundle_ios.m`: game data in `/var/mobile/Media/NFSU2`, `env.txt` overrides, `nfsu2.log`, `saves/`, `home/` (registry). |
| Guest memory | With the default 4 GB `__PAGEZERO`, only ~1.1–1.6 GB of contiguous VA is free on the mini 2. A 16 KB pagezero frees enough, but then the jailbreak's injected `pspawn_payload` dylib loads below 4 GB and libxpc crashes in dyld init. Fix (`NFS_GUEST_IN_IMAGE`): the 4 GB guest space is a zero-fill section `__GUEST,__mem` inside the executable. The image covers 0–4 GB, every dylib loads above it, and the full 4 GB is available on every launch. |
| GPU (A7 / family 1) | No BC sampling: DXT is decoded on upload (DXT1 to 16-bit `BGR5A1`, DXT3/5 to BGRA8). Mipmapped textures above `NFSU2_TEXMAXDIM` (512) drop their top levels. No base vertex: folded into the vertex buffer offset. No mirror-clamp sampler mode: mirror-repeat is used instead. |
| Texture freeing | Metal textures are freed on the game's last `Release` (upstream never freed them), after a quarantine of 300 frames. |
| Memory | Free guest pages in ranges of 1 MB or more are returned to the OS. Quarantines are smaller (heap 8 MB, buffer heap 600 presents). A `[mem]` line every 5 s logs footprint, textures by format and the battery. |
| Audio | RemoteIO instead of the DefaultOutput unit; AVAudioSession Playback. |
| Lifecycle | Resign active pauses the frame loop (no GPU work in the background). A battery guard exits at < 8 % unplugged or < 5 % charging, because a flat battery reboots the device and loses the jailbreak. |
| Input | Keyboard actions are edge events. A key held across an action-map switch is re-reported as pressed once it stays down 250 ms past the switch (re-reporting at once closed the pause menu with the Esc that opened it). |
| Movies | `SPEED2.EXE` has On2's VP6 decoder. It hung because EA's CPU-speed probe (`sub_006f5f14`) busy-waits 1 s of `QueryPerformanceCounter` time, which the virtual clock never delivers within a frame: QPC calls from its delay helper (return `0x006f5eab`, NA) get real time. The movie audio watchdog (`sub_007260f7`) rebuilds DirectSound when the cursor reads the same 100 times: `GetCurrentPosition` now moves smoothly between callbacks. A tap during a movie is Enter (the EA/THX/PSA screens are unskippable, as on the PC). |
| Text entry | The `WM_CHAR` branch feeds the text box at `0x0083a7b0` while `byte[0x0083a9c0] && dword[0x0083a9c4]` (NA). `nfs_textbox_active()` is polled to show/hide the system keyboard; typed text goes to the `WM_CHAR` queue. |
| Audio / GIL | The game's sound tick (a `timeSetEvent` callback) waited up to 250 ms for the GIL behind the main thread on 2 cores, so ~12 % of the music was muted. FIFO ticket GIL (`NFSU2_FAIRGIL`) + timer thread at user-interactive QoS: 0 ms muted. Smaller RemoteIO slice (256 frames) and a 100 ms write lead (`SNDLEAD_MS`). |
| Textures | Only DXT textures shed their guest copy after upload: the game re-locks A8R8G8B8 textures to recomposite car skins, rims and vinyls (shedding those removed the wheels). |

## Build and install

Requirements: Xcode (iOS SDK), `ldid` (Homebrew), the Python venv from the main
README, the **NA v1.2** `SPEED2.EXE`, and an SSH host alias for the device
(rootful jailbreak, `uicache`).

```sh
tools/gen_v2.sh                        # lift the NA exe into gen/na (see the main README)
ios/build_ios.sh                       # shards + runtime -> out/ios/NFSU2.app (about 70 s on an M5)
ios/build_ios.sh rt                    # runtime only (shards already built)
ios/push_data.sh "<game folder>" ipadmini2   # resumable copy to /var/mobile/Media/NFSU2 (~1.8 GB, no MOVIES)
ios/install.sh ipadmini2               # staged install into /Applications, then uicache
ssh ipadmini2 uiopen -b com.legacylab.nfsu2
```

- The app icon is generated at build time from `ICON=<square image>` (default
  `../nfsug2.jpg`, outside the repo). No logo is committed.
- `out/ios/NFSU2.dSYM` symbolicates device crash reports:
  `atos -o out/ios/NFSU2.dSYM/Contents/Resources/DWARF/NFSU2 -l <load address> <addresses>`.
- Signing: `ldid -Sios/entitlements.plist -Icom.legacylab.nfsu2` (platform-application,
  no-container, skip-library-validation).

## env.txt (in /var/mobile/Media/NFSU2)

One `KEY=VALUE` per line, applied before the game starts. Useful keys:

| Key | Meaning |
|---|---|
| `NFSRES` | render size (default `1024x768`, scaled to the 2048x1536 screen) |
| `NFSU2_TEXMAXDIM` | largest texture edge kept for mipmapped textures (default 512) |
| `NFSU2_DXT1_16`, `NFSU2_TEXSHED`, `NFSU2_TEXFREE`, `NFSU2_PAGERETURN`, `NFSU2_FAIRGIL` | memory / scheduling features (default on for iOS; `0` turns off) |
| `NOMOVIES` | `0` (default on iOS) plays the movies; `1` skips them |
| `TIMERSTAT`, `TEXTLOG`, `TEXSHEDLOG`, `DIMAP`, `DIDATA=<n>` | diagnostics: timer/GIL wait, text-box state, re-locks of shed textures, action maps and input events |
| `NFSU2_KEY_GAS` and others | on-screen key mapping (DIK hex codes) |
| `FPSCSV`, `DUMPFRAME` + `DUMPDIR` | per-frame timing CSV, PNG frame dumps |
| `AUTOSEQ`, `MOUSEAT`, `QUITFRAMES` | scripted runs (as `tools/check.sh`); `QUITFRAMES` exits cleanly and prints the frame-budget report |
