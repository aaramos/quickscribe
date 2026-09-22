# QuickScribe — testing & known failure modes

## Hotkey / capture-start proof (t_50da3b54)

Hotkeys: hold Control+Command (dwell ≥150 ms) = PTT; Control+Command+Shift
= Rewrite; Esc = cancel. Menu-bar "Start Recording (hands-free)" calls the
same SessionController.start() path without HotkeyManager.

### Failure mode: silent no-op on menu-record AND hotkey (fixed 2026-09-22)

Symptom: menu-bar icon live, "Start Recording" clicked, NO overlay pill,
no capture, no error. Both entry points dead.

Root cause (proven from unified log, 15:05:37):
  AVAEInternal.h:88 required condition is false:
  [AVAudioEngineGraph.mm:2046:InstallTapOnNode:
   (format.sampleRate == inputHWFormat.sampleRate)]
  → NSException com.apple.coreaudio.avfaudio thrown from installTap,
  INSIDE AudioCapture.start() but OUTSIDE the ExceptionGuard.
  AppKit caught and swallowed it at the menu layer ("This is a bug in the
  client code"). The pre-start inputNode.outputFormat reported 16 kHz
  while the C920 hardware came up at 48 kHz/2ch — tap installed with a
  stale nominal format.

Fix: read engine.inputNode.outputFormat(forBus: 0) AFTER
engine.start()/prepare() and install the tap with the LIVE format;
installTap is now also wrapped in ExceptionGuard so any future mismatch
surfaces as an honest overlay error instead of a silent no-op.

Proof harness: app/build/proofs/tapstart-proof
build:
  clang -c -O -I Sources/SpecCatch/include Sources/SpecCatch/SpecCatch.m -o /tmp/SpecCatch.o
  swiftc -O -o build/proofs/tapstart-proof \
    -I Sources/SpecCatch/include \
    -Xcc -fmodule-map-file=$PWD/Sources/SpecCatch/include/module.modulemap \
    Sources/QuickScribe/AudioCapture.swift Sources/QuickScribe/InputDeviceResolver.swift \
    Sources/QuickScribe/AppInfo.swift proof-src/tapstart/main.swift /tmp/SpecCatch.o \
    -framework AVFoundation -framework AppKit
  codesign --force -s "Pure Voice Local Development" build/proofs/tapstart-proof
PASS criteria: "PASS: capture live, device=HD Pro Webcam C920" +
non-zero peakLevel + chunks=0 with "gated" lines in a silent room
(silence gate working, t_b3e7802c).

### Related history (do not re-litigate)
- t_220b8507: inputNode pre-touch + ExceptionGuard for prepare()/start().
- t_b3e7802c: BlackHole default-input trap → InputDeviceResolver bind + silence gate.

## Owner hand test (final acceptance)
Hold Control+Command in any focused app → overlay pill appears within
~100 ms → speak → release → text inserts exactly once.
