# Releasing Mynah

From a clean checkout to a stapled `Mynah.app` that opens on someone else's Mac.

Apple Silicon only — the app runs speech recognition on the Neural Engine, so an
x86 build would be the wrong answer rather than a fallback.

---

## Once per machine

**Xcode**, not just the command line tools. `notarytool` and `stapler` ship
inside Xcode; a machine with only the CLT has `codesign` and will get all the
way to the upload before failing.

**A Developer ID Application certificate.** This is the certificate for apps
distributed outside the App Store. `Apple Development` and `Mac App
Distribution` are different certificates and neither can be notarized this way.

```
security find-identity -v -p codesigning
```

You want the line that starts `Developer ID Application:`. The whole quoted
string, including the team id in brackets, is what goes in
`SAGE_VOICE_CODESIGN_IDENTITY`.

**Notarization credentials**, stored in the keychain so they never reach a
shell history or a file:

```
xcrun notarytool store-credentials MYNAH_NOTARY \
  --apple-id you@example.com \
  --team-id 2N7GKZ8D8Z \
  --password <app-specific-password>
```

The password is an *app-specific password* from
appleid.apple.com → Sign-In and Security → App-Specific Passwords. It is not
your Apple ID password. `scripts/notarize.sh` also accepts an App Store Connect
API key, which is the better choice on CI because it can be revoked without
touching the Apple ID — see the comment at the top of that script.

---

## Every release

```bash
git clone https://github.com/l33tdawg/sage-voice-bridge
cd sage-voice-bridge

# 1. Put a SAGE node in vendor/. Ships inside the app, so the owner never
#    installs anything and never sees a Gatekeeper prompt for it.
scripts/vendor-sage.sh

# 2. Compile. package-app.sh does NOT do this — it only packages what it finds.
swift build -c release --arch arm64

# 3. Draw the icon. Only needed if resources/Mynah.icns is missing or the
#    drawing in scripts/make-icon.sh changed; the .icns is committed, and
#    re-running it for no reason produces a 1.4 MB diff (see below).
scripts/make-icon.sh

# 4. Lay out and sign the bundle.
export SAGE_VOICE_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
SAGE_VOICE_VERSION=0.1.0 SAGE_VOICE_BUILD=1 scripts/package-app.sh

# 5. Notarize, staple, verify.
export MYNAH_NOTARY_PROFILE=MYNAH_NOTARY
scripts/notarize.sh
```

You end up with:

```
dist/Mynah.app                              stapled, ready to ship
dist/Mynah-0.1.0-macOS-arm64.zip            the same app, packed with ditto
dist/Mynah-0.1.0-macOS-arm64.zip.sha256
```

Ship the zip. `ditto -c -k --keepParent` is the only zipper that preserves the
bundle's symlinks and extended attributes; `zip -r` mangles them and the
signature no longer verifies on the other end.

### Version and build

`SAGE_VOICE_VERSION` sets `CFBundleShortVersionString` (what a person sees) and
`SAGE_VOICE_BUILD` sets `CFBundleVersion` (what macOS compares to decide one
build is newer than another). `SAGE_VOICE_RELEASE_LABEL=beta.3` adds a suffix
to the archive name. Left unset, the values already in `resources/Info.plist`
are used.

---

## What each step guarantees

### `scripts/make-icon.sh`

Draws `resources/Mynah.icns` from Swift source — a mynah in profile, near-black
plumage, one warm-yellow patch behind the eye. All ten `iconutil` slots are
rendered from the vector at their native size rather than downscaled from one
1024 PNG, because 16 and 32pt are the two sizes anyone actually looks at all
day. The tile is 824pt inside a 1024pt canvas, which is Apple's macOS grid; a
tile that fills all 1024 sits visibly oversized next to Finder in the Dock.

It is not byte-reproducible. Two runs from identical source differ in roughly
5% of pixels at the 512 and 1024 sizes, by at most 1 in 255 in one channel —
the shadow blur landing on a different code path between processes. Nobody can
see it; the only cost is that an idle re-run looks like a 1.4 MB change in the
diff. So regenerate when the drawing changed, not as a habit.

### `scripts/package-app.sh`

Stages both binaries into `Contents/MacOS` — `MynahMac`, which is what the
owner double-clicks, and `sage-voiced` beside it, which stays as the debugging
surface. Copies the icon and the vendored `SAGE.app` into `Contents/Resources`.

Then it signs **strictly inside out**, and that order is the reason the file
exists:

1. helpers inside `SAGE.app`, then `SAGE.app` itself
2. `Contents/MacOS/sage-voiced`
3. `Contents/MacOS/MynahMac`
4. the outer bundle
5. `codesign --verify --deep --strict`

macOS seals a hash of everything inside a bundle into the bundle's own
signature. Sign the outer bundle first and the next inner signature silently
invalidates it — and the failure mode is the worst one available: it launches
perfectly on the machine that built it, because that machine already trusts the
certificate, and every other Mac says *"Mynah is damaged and can't be
opened."* Nothing in the build output tells you. Only step 5 does.

It refuses to continue if:

- `CFBundleIdentifier` is not `local.sage.voicebridge` (see below)
- `CFBundleExecutable` does not name the binary actually staged as the app
- the icon named by `CFBundleIconFile` is not there
- the vendored `SAGE.app` is not arm64, not runnable, or has the wrong bundle id
- `SAGE.app` grew a nested framework or XPC service the script does not know
  how to sign in the right order
- the signed bundle lost the microphone entitlement
- any staged executable is missing the hardened runtime

### `scripts/notarize.sh`

Checks the signature **before** uploading: real Developer ID rather than ad-hoc,
hardened runtime, a secure timestamp, and seals that verify. Apple checks all
four too, but only after the upload and the queue, so a local check turns a
five-minute round trip into a one-second one.

Then: `ditto` to a zip → `notarytool submit --wait` → on failure, fetch and
print Apple's own log with a plain-language guide → on success,
`stapler staple` the **app** (a zip cannot hold a ticket) → `stapler validate` →
`spctl --assess --type exec` → repack the stapled app and write a checksum.

`spctl` is the check that matters. Notarization can succeed and the app still be
refused in the field if the ticket did not attach to what Gatekeeper looks at.
A correct build reports `accepted`.

---

## The bundle identifier

`local.sage.voicebridge`. Do not change it.

macOS files every TCC grant — microphone, automation, files and folders — under
that string. A build with a new identifier is a different app as far as the
system is concerned: every existing owner silently loses every permission they
granted and starts getting permission boxes with no idea why. `package-app.sh`
hard-fails on a change for exactly this reason. If you genuinely need a new
identifier, you need a migration plan first, and the script edit should be in
the same commit as the plan.

---

## Entitlements

The GUI gets exactly one: `com.apple.security.device.audio-input`. Confirm it
survived signing with

```
codesign --display --entitlements :- dist/Mynah.app
```

`com.apple.security.cs.disable-library-validation` is deliberately absent, and
`resources/SageVoiceBridge.entitlements` explains why at length. The short
version: library validation governs code loaded *into* a process, and SAGE,
Ollama and the WhisperKit server are all separate processes with their own
signatures. Nothing foreign is loaded into `MynahMac`.

The trap worth knowing: a development build is ad-hoc signed, ad-hoc code has no
Team ID, and library validation is not enforced without one. So a missing
entitlement of this kind cannot show up on the build machine — only on a
Developer ID build, on someone else's Mac, as `Library validation failed` in a
crash report. If that ever happens, add the key back to the entitlements file
and say in the commit message which library forced it.

---

## When something goes wrong

**"Mynah is damaged and can't be opened"** on another Mac, while it opens fine
on yours. The signing order was broken, or a file changed after signing. Do not
re-sign one piece by hand — that is how it got here. Run `package-app.sh` again
from scratch.

**Notarization comes back `Invalid`.** The script already prints Apple's log and
a translation of the common reasons. The one that catches people is *"The
signature does not include a secure timestamp"*, which means the signing machine
was offline or behind something blocking `timestamp.apple.com`. Get online and
re-package; `--timestamp` is passed automatically for real identities.

**`spctl` says `rejected`, `source=Unnotarized Developer ID`.** The build is
signed but the ticket is not attached. Re-run `xcrun stapler staple
dist/Mynah.app`. If it was submitted less than a minute ago, Apple's service may
not have published the ticket yet.

**The owner's microphone permission disappeared after an update.** The bundle
identifier changed. Check it against `local.sage.voicebridge` and ship a build
with the original one; there is no way to restore the grant from the app's side.

**The Dock shows a blank page instead of the icon.** `Contents/Resources` is
missing `Mynah.icns`, or `CFBundleIconFile` names something else.
`package-app.sh` checks both, so this means the bundle was assembled by hand.
macOS also caches icons aggressively — `killall Dock` after fixing it.

---

## What is verified by whom

Everything up to the upload is checked on the build machine by the two scripts
and can be re-run at any time:

```
codesign --verify --deep --strict --verbose=2 dist/Mynah.app
codesign --display --entitlements :- dist/Mynah.app
codesign --display --verbose=4 dist/Mynah.app | grep -E 'Authority|Timestamp|flags'
```

Notarization, stapling and the final `spctl` verdict need an Apple ID with a
Developer Program membership and cannot be exercised without one. If you are
picking this up from a machine that has never released before, the first run of
`scripts/notarize.sh` is the first time that path executes for real.
