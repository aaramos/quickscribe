# QuickScribe

Hold a hotkey, talk, let go, and clean text appears wherever you're typing. It runs
entirely on Apple's own technology, on your Mac. There's no engine to install, no
Python, no third-party code and no AI model to download with the app.

## What it needs

- An Apple Silicon Mac on macOS 27
- Apple Intelligence turned on, for AI cleanup. Without it, dictation still works, with
  only the basic tidy-up.
- Microphone and Accessibility permission. Accessibility is what lets the hotkey work
  anywhere and lets the text paste in.

## Install

1. Open `QuickScribe.dmg` and drag the app to Applications.
2. Open it from Applications. macOS will block it the first time, because it isn't signed
   with a paid Apple Developer ID. Go to System Settings > Privacy & Security, scroll down
   and click Open Anyway.
3. Grant Microphone and Accessibility when asked, then quit and reopen the app.
4. Look for the icon in the menu bar. There's no window.

To build the installer yourself, run `app/make_installer.sh`.

## How to use it

- Hold **⌃⌘** to talk and release to insert. Press any other key or Esc to cancel.
- Pick a mode with **⌃⌘1** Polish, **⌃⌘2** Concise or **⌃⌘3** Active Voice, from the menu
  bar, or by saying "switch to concise" at the start of a dictation.
- Hold **⌃⌘⇧** to Rewrite one dictation.
- Edit each mode's instructions in **Settings…**, and try them on sample text there.

## Your own service (optional)

By default everything runs on Apple's on-device models and no words leave the Mac.
Settings can point speech, cleanup, or both at any OpenAI-compatible address you run
(`/v1`). Set the address, add an API key if your service needs one (kept in the Keychain),
pick the Speech and Cleanup models by name, and press Test Connection to check the four
things it needs to work. With no address set, Apple's models are used.

If the address is not on this Mac or your local network, your words and your key travel
to it, and they are only encrypted if the address uses https; plain http to a remote
address is refused. A non-local address also shows a warning on screen.

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

If nothing that accepts text has focus, the cleaned-up text goes on the clipboard instead
and the overlay says so. With Apple's models (the default) dictated text never leaves the
Mac, never goes in the logs, and isn't saved: there is no history. If you set a custom
service in Settings, only the routes you switched to Custom go to that address. Edited
prompts are saved in `~/Library/Application Support/QuickScribe/prompts.json`.

## Build and test

```bash
cd app && swift test
```

```bash
cd app && ./build_app.sh
```

The app lands in `app/build/QuickScribe.app`. To rename it, change `AppInfo.swift`.
The installer disk image is built by `app/make_installer.sh`.

`eval/` compares Apple's speech and cleanup with the original QuickScribe on 50 scripted
dictations, using Apple's text-to-speech voice. See `eval/README.md`.
