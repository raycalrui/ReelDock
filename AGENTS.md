# AGENTS.md

These rules apply to agents working in this repository unless the user explicitly overrides them.

## Product and language

- ReelDock is a native macOS app for managing video project folders and importing from camera cards. It is built for Raycal's own workflow first.
- Use English for UI, code comments, filenames, documentation, and commit messages. Communicate with Raycal in Simplified Chinese.
- The README and release notes are in both English and Simplified Chinese. The README is one file, with each passage or list item in English followed by its Chinese.
- `docs/SPEC.md` defines intended behavior. Implement only what is selected in `TODO.md`; other ideas stay as candidates.

## Before changes

1. Read this file, then `README.md`, `TODO.md`, `DECISIONS.md`, and the relevant part of `docs/SPEC.md`.
2. Check Git status and the affected files. Preserve unrelated uncommitted work.
3. Ask when a missing choice would materially change the result. Do not stop for low-risk details.

## Stack

- Swift with an AppKit app shell and native window tabs. SwiftUI is fine for the sidebar, panels, and settings.
- Column browsers use view-based `NSTableView` columns, not `NSBrowser` (see `DECISIONS.md`).
- No third-party dependencies unless Raycal agrees. Sparkle is the one exception, for signed updates.
- Not sandboxed, not targeting the Mac App Store.
- `xcode-select` on this Mac points at the Command Line Tools, so `xcodebuild` needs the developer directory set:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version
```

Debug builds can be driven by script through `ReelDock/App/DebugDriver.swift`. Set `REELDOCK_DEBUG_DIR`, and use `REELDOCK_SUPPORT_DIR` and `REELDOCK_PROJECT_ROOT` to isolate test runs from real settings. These hooks must stay out of Release builds.

## Protecting media

This app handles footage that may not exist anywhere else. These rules are not negotiable:

- **Never write to a camera card.** No deletes, renames, tags, sidecars, or ledgers on the card. Only ejecting is allowed, and only when the user asks.
- **Never overwrite a file.** Name collisions get a new name or an explicit choice.
- **Never publish a partial copy.** Copy to a hidden temporary file, verify it, then rename it into place.
- **Deleting means moving to Trash.** The app has no permanent delete.
- **Do not store app data inside project folders.** Settings and the import ledger live in Application Support.

## Testing

- Run write tests only against temporary fixtures. Never test writes under `~/Desktop/video`, or tag operations on real projects.
- A real card and real project folders may be used read-only.
- Do not leave test Finder tags behind, because tags can reach Finder's tag list.
- Test failure paths for import: card removed mid-copy, not enough space, name collisions, and a verification mismatch.
- Check rendering in the running app rather than relying on a successful build. Use a real project with many clips and a nested folder.

## Privacy

Client and project names, footage, and device serial numbers stay out of the repository. Fixtures use invented names, and any real metadata sample must have identifiers removed.

## Documentation

- Track milestones in `TODO.md`, and mark an item done only after implementation and proportionate verification.
- Record lasting choices in `DECISIONS.md`. Update `README.md` when capabilities or limitations change, in both languages.
- Describe current facts. Do not equate planned, built, verified on a real card, signed, and released.

## Git

- Stage only paths related to the task and review the staged diff before committing.
- Commit or push only when Raycal asks. A commit does not imply permission to push.

## Releases

Create a release only when Raycal asks. Its notes have the English first, then a `---` line, then the same notes in Simplified Chinese. Build with `scripts/build-release.sh`, upload the DMG to the GitHub release and check it, then run `scripts/prepare-update.sh` and push `appcast.xml`. Sparkle's private key is in the login Keychain under the account `cc.raycal.ReelDock` and never goes in the repository. Debug builds never update themselves.

Test builds outside DerivedData stay registered with LaunchServices and can leave the Dock showing a blank icon. Unregister and delete them when done.
