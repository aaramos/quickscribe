# Releasing QuickScribe

A release is a GitHub release on `aaramos/quickscribe` with two files:

| File | Who uses it |
|---|---|
| `QuickScribe.dmg` | People installing for the first time, and anyone updating by hand |
| `QuickScribe.zip` | The in-app installer: the signed app, zipped with `ditto` |

Copies already installed find a release through GitHub's "latest release" API. They read
`tag_name` (the version, with or without a leading `v`), `html_url` (the release page)
and, from 2.1 on, the asset named exactly `QuickScribe.zip` with its `digest`. A release
without the zip is still announced, and installed by hand from its page.

## Why the signature matters

The in-app installer accepts a download only if the new app meets the running app's own
designated requirement:

```
identifier "local.quickscribe.native" and certificate leaf = H"<the QuickScribe Release certificate>"
```

That is the same rule macOS uses to treat an update as the same app for Microphone,
Accessibility and the keychain. So:

- Every release must be signed with the **QuickScribe Release** certificate in the
  release Mac's login keychain (made once by `app/make_signing_identity.sh`).
  `make_release.sh` refuses an ad-hoc build.
- Never change the bundle id or the certificate. A release signed with anything else is
  refused by every installed copy, which then sends people to the release page to update
  by hand. If the certificate is ever lost, the next release has to be a hand install for
  everyone.
- The certificate's private key stays in the keychain. Back it up somewhere safe, offline.

The SHA-256 digest that GitHub records for each uploaded file is checked too, but only as
a check on the transfer: the signature is what makes a download trusted.

The app is not notarised (that needs Apple's paid program). Updates installed by the app
are not quarantined, so they open without the Open Anyway step. A first install from the
disk image still needs it once.

## Steps

1. Set the new version in `app/Sources/QuickScribe/AppInfo.swift` (`version`), commit.
2. Run the tests:

   ```bash
   cd app && swift test
   ```

3. Rehearse the update on this Mac (optional for small changes, required after any change
   to the update code). It builds an old and a new copy as a separate app named
   "QuickScribe Rehearsal", serves the new one from a local feed, and waits for you to
   choose **Install version 9.0.1 and Relaunch** in its menu (the second QuickScribe icon):

   ```bash
   cd app && ./rehearse_update.sh
   ```

   It prints `PASS` when the installed copy is the new version, still validly signed, and
   running again. Then clean up:

   ```bash
   cd app && ./rehearse_update.sh --clean
   ```

4. Build and check the release files. This publishes nothing:

   ```bash
   cd app && ./make_release.sh
   ```

   It builds `build/QuickScribe.dmg` and `build/QuickScribe.zip`, unpacks the zip the way
   the installer will, checks the signature against the designated requirement and the
   version against `AppInfo.swift`, and prints the publish commands.

5. Publish, only when you mean to. Every installed copy sees the release from its next
   check:

   ```bash
   git tag v2.1.0 && git push origin v2.1.0
   ```

   ```bash
   gh release create v2.1.0 app/build/QuickScribe.dmg app/build/QuickScribe.zip --title "QuickScribe 2.1.0" --notes-file notes.md
   ```

   Both files must be uploaded in the same release, and the zip's name must stay
   `QuickScribe.zip`.

6. Check it from a real copy: on a Mac running the previous version, open the menu and
   choose Install. To check the release answer without a copy:

   ```bash
   gh api repos/aaramos/quickscribe/releases/latest --jq '.tag_name, (.assets[] | .name + " " + .digest)'
   ```

## The first release with the installer

Copies on 2.0.2 or earlier only announce a release and link to its page. Their users
install the first release that has the installer by hand, from the disk image, once.
Say so in that release's notes. From then on updates are one click.

## Testing against a local feed

The app reads `QUICKSCRIBE_UPDATE_FEED` from its environment at launch. When set, it must
be an `http` or `https` address on `127.0.0.1` or `localhost`; the app then asks
`<address>/releases/latest` instead of GitHub, and accepts pages and downloads only under
that address. A value that is not local disables the check rather than falling back to
GitHub. The download must still meet the running app's designated requirement, so a test
feed cannot install anything a real release could not. `rehearse_update.sh` sets it with
`open --env`.
