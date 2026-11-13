# QuickScribe

Hold a hotkey, talk, let go, and clean text appears wherever you're typing. By default
it runs entirely on Apple's own technology, on your Mac. There's no engine to install, no
Python, no third-party code and no AI model to download with the app. Optionally, any
route can point at your own OpenAI-compatible service instead (see below).

## What it needs

- An Apple Silicon Mac on macOS 27
- Apple Intelligence turned on, for AI cleanup. Without it, dictation still works, with
  only the basic tidy-up.
- Microphone and Accessibility permission. Accessibility is what lets the hotkey work
  anywhere and lets the text paste in. On macOS 27, Accessibility lives under
  **System Settings > Device Control and Data Access**.

## Install

1. Open `QuickScribe.dmg` and drag the app to Applications.
2. Open it from Applications. macOS will block it the first time, because this free,
   open-source app isn't signed with a paid Apple Developer ID: macOS can't check who made
   it, so it asks you. Then go to System Settings: **Open Anyway** appears there only
   after a launch attempt has actually been blocked, and it stays available for about an
   hour after the attempt. Click it where it appears next to the message about
   QuickScribe; if you don't see it where you are, search "Open Anyway" in System
   Settings. This is a one-time step.
3. Grant Microphone and Accessibility when asked, then quit and reopen the app. If the
   menu bar says hotkeys are off but QuickScribe already looks switched on in System
   Settings, remove it with the minus button and add it again. A switch can look on
   while it does not apply, usually after an older copy of the app.
4. Look for the icon in the menu bar. There's no window.

To build the installer yourself, run `app/make_installer.sh`.

## How to use it

- Hold **⌃⌘** to talk and release to insert. Press any other key or Esc to cancel.
- From the menu bar, choose **Start Recording (hands-free)** to record until you pick
  Stop — for when your hands are busy.
- Pick a mode with **⌃⌘1** Polish, **⌃⌘2** Concise or **⌃⌘3** Active Voice, from the
  **Mode** submenu in the menu bar, or by saying "switch to concise" at the start of a
  dictation. The submenu's title shows the mode in use.
- Hold **⌃⌘⇧** to Rewrite one dictation.
- Edit each mode's instructions in **Settings…**, and try them on sample text there.

## Updating

The app checks GitHub at launch and once a day, reading the latest release of
[aaramos/quickscribe](https://github.com/aaramos/quickscribe/releases). When a newer
version is out you get one short notice on screen, and the menu grows an "Update
available: version X" item that opens that release's page; the menu bar icon itself
does not change. The notice never
interrupts a dictation: if you are recording, it waits for a quiet moment. The app never
downloads or installs anything itself: you drag the new disk image to Applications when
you choose. Coming from version 1.0, the old app is named QuickScribe Native, not
QuickScribe: after installing this version, quit QuickScribe Native and drag it to the
Trash, or you will have both apps. After an update macOS may ask for Microphone and Accessibility again; switch
them back on if the hotkeys go quiet. If a switch already looks on but the hotkeys are
dead, remove QuickScribe from that list with the minus button and add it again. Your settings and edited prompts survive the update. Releases carry one steady self-made signature, so an update is the same app to macOS; coming from v1.0, which had a throwaway signature, means granting permissions again once, whatever the signature. If you saved an API key,
macOS may ask for your password after an update so QuickScribe can read it: choose
Always Allow.

## Your own service (optional)

By default everything runs on Apple's on-device models and no words leave the Mac.
Settings can point speech, cleanup, or both at any OpenAI-compatible address you run
(`/v1`). Set the address, add an API key if your service needs one (kept in the Keychain),
and press Test Connection: it says how many speech and clean up models the service has.
The models themselves are picked in the menu bar, from the **Speech Model** and **Clean Up
Model** submenus, which always list Apple Native first. Speech and cleanup are independent,
so any mix of Apple and your server works, and a choice applies from the next dictation.
With no address set, only Apple Native is offered.

If the address is not on this Mac or your local network, your words and your key travel
to it, and they are only encrypted if the address uses https; plain http to a remote
address is refused. A non-local address also shows a warning on screen.

What always leaves the Mac, even with no address set: a plain HTTPS question to GitHub's
release API ("is there a newer version?") at launch and once a day, carrying nothing but
the app name and version. No words, no audio. Like any web request, it lets GitHub see
your network address.

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

Apple's on-device cleanup may leave some self-corrections in, and an inference server may handle them better.

If nothing that accepts text has focus, the cleaned-up text goes on the clipboard instead
and the overlay says so. With Apple's models (the default) dictated text never leaves the
Mac, never goes in the logs, and isn't saved: there is no history. If you set a custom
service in Settings, only the routes you switched to your server go to that address. Edited
prompts are saved in `~/Library/Application Support/QuickScribe/prompts.json`.

## Build and test

```bash
cd app && swift test
```

```bash
cd app && ./build_app.sh
```

The app lands in `app/build/QuickScribe.app`. To rename it, change `AppInfo.swift`.
The installer disk image is built by `app/make_installer.sh`. Both sign ad-hoc by
default, so anyone can build from source with no certificate and nothing to set up.

Releases share one steady self-made signature. `app/make_signing_identity.sh` creates a
"QuickScribe Release" certificate in the login keychain once, free, with no Apple
account; `CODESIGN_IDENTITY="QuickScribe Release" ./make_installer.sh` then builds with
it. macOS recognizes updates from that identity as the same app, which is what lets
permissions survive an update. It does not remove the first-open block, which only
Apple's paid program can, and it changes no system trust settings.

`eval/` runs 50 scripted dictations, spoken by Apple's text-to-speech voice, through
the app's own speech and cleanup paths. See `eval/README.md`.
