# QuickScribe Native

Hold a hotkey, talk, let go, and clean text appears wherever you're typing. It runs
entirely on Apple's own technology, on your Mac. There's no engine to install, no
Python, no third-party code and no AI model to download with the app.

## What it needs

- An Apple Silicon Mac on macOS 27
- Apple Intelligence turned on, for AI cleanup. Without it, dictation still works, with
  only the basic tidy-up.
- Microphone and Accessibility permission. Accessibility is what lets the hotkey work
  anywhere and lets the text paste in.

## How to use it

- Hold **⌃⌘** to talk and release to insert. Press any other key or Esc to cancel.
- Pick a mode with **⌃⌘1** Polish, **⌃⌘2** Concise or **⌃⌘3** Active Voice, from the menu
  bar, or by saying "switch to concise" at the start of a dictation.
- Hold **⌃⌘⇧** to Rewrite one dictation.
- Edit each mode's instructions in **Settings…**, and try them on sample text there.

Don't run it alongside the original QuickScribe. Both use the same hotkey, so this one
refuses to record and says why.

## How it works

| Step | Apple technology |
|---|---|
| Speech to text | SpeechAnalyzer with SpeechTranscriber, on-device |
| Cleanup | Foundation Models, Apple's on-device model |
| Everything else | AVFoundation, AppKit, Swift |

1. **Basic tidy-up.** Simple rules remove clear fillers ("um", "uh"). They can't reword
   anything and need no AI.
2. **AI cleanup.** Apple's model applies the chosen mode's instructions.
3. **Safety check.** Apple's model sometimes answers a dictated question or obeys a
   dictated command, such as "write me a poem". If the result adds numbers or names you
   never said, turns a question into a statement, or changes too much of the text, it's
   thrown away.
4. **Your words always arrive.** If the model refuses, takes too long, is unavailable or
   fails the check, the tidied text is inserted and the overlay says so.

Dictated text never leaves the Mac, and it never goes in the logs. The last 50 dictations
stay in `~/Library/Application Support/QuickScribe Native/history.json`, readable only by
your user. Edited prompts are saved beside them in `prompts.json`.

## Build and test

```bash
cd app && swift test
```

```bash
cd app && ./build_app.sh
```

The app lands in `app/build/QuickScribe Native.app`. To rename it, change `AppInfo.swift`.

`eval/` compares Apple's speech and cleanup with the original QuickScribe on 50 scripted
dictations, using Apple's text-to-speech voice. See `eval/README.md`.
