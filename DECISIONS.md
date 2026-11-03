# Decisions

Lasting choices and why they were made. Dates are absolute.

## 2026-11-03: Sections stacked vertically, each a column browser

Requested by Raycal. Sections fit the window in a split view rather than sitting in an outer scroll view, because a scrolling page containing scrolling columns traps the pointer. To be checked on a real project early in milestone 1.

## 2026-11-03: Columns built from `NSTableView`, not `NSBrowser`

Rows need tag dots, thumbnails, inline rename, multi-selection, and file drag and drop. `NSBrowser` is cell-based and makes these harder, while one view-based table per column gives direct control. Revisit only if keyboard behavior proves costly to match.

## 2026-11-03: Last column fills the remaining width

Finder leaves empty space after the last column. In a stacked layout most sections hold one column, which would leave a large void beside every section, so the last column stretches instead.

## 2026-11-03: Debug-only test driver

`App/DebugDriver.swift` runs scripted commands and is compiled only in Debug builds. It exercises the real controllers when no desktop automation is available. Its window snapshots omit the sidebar and toolbar, so appearance still needs checking on a real screen. They are still useful: a blank-section bug that looked like a snapshot limitation turned out to be real, so missing content in a snapshot must be investigated, not assumed to be an artifact.

## 2026-11-03: `_proxy` is an ordinary section

Requested by Raycal. "Show hidden" now only affects real hidden files. Like other folders, `_proxy` starts collapsed.

## 2026-11-03: Only output, video, and cover start open

Requested by Raycal, so the folders used daily get the height. A folder with no numbered sections, such as a code project, has nothing to prioritize and starts fully open.

## 2026-11-03: Video gets the most height by default

Decided by Raycal. Item count alone misleads, because footage is often grouped in a few subfolders while covers and stills sit loose.

## 2026-11-03: Header click toggles, and a button maximizes

Requested by Raycal: the whole header bar toggles a section. Double-click to maximize would have forced a delay on every single click to tell the two apart, so maximizing moved to a button.

## 2026-11-03: No Recent list in the sidebar

Removed at Raycal's request. The project list and Favorites cover it.

## 2026-11-03: New clips start selected

Raycal asked for one-click import. The cost is unchecking clips on a mixed card, which is easy, since a group checkbox clears a whole shoot. Importing the wrong clip is also recoverable, because nothing is removed from the card.

## 2026-11-03: Import panel sits beside the project

It replaced the browser at first, which hid the folders clips were going into. It now shares the tab side by side, because the sections need their height more than their width. Return no longer starts an import, since it would also fire while browsing the project next to the panel.

## 2026-11-03: Import panel replaces the browser within its tab (superseded)

It keeps the sidebar and inspector, so selecting a clip previews it the same way as selecting a file. Other tabs stay usable, and closing the panel doesn't stop the copy.

## 2026-11-03: Unreadable and hidden cards

A card's clips come from the folder listing, not `MEDIAPRO.XML`, so a damaged database can't hide footage. Volumes mounted as hidden aren't listed. Normal camera cards are never hidden, so this only affects special tools.

## 2026-11-03: Native window tabs

Native tabs provide the Finder-like shortcuts and drag-out-to-window behavior for free. This favors an AppKit shell with one window controller per tab over a SwiftUI `WindowGroup`.

## 2026-11-03: Not sandboxed, no Mac App Store

The app browses arbitrary folders and reads cards, so a sandbox would add security-scoped bookmarks for no benefit in personal use. A later Developer ID release would still work. An App Store release would require revisiting this.

## 2026-11-03: Deployment target macOS 26

The app is for Raycal's own machine first, currently on macOS 27.2. This is easy to lower if it is released or needs to run on an older Mac.

## 2026-11-03: A clip counts as imported on name and size, or a ledger match

Real projects contain files with the same name and different sizes (42 MB and 2.95 GB), so name alone gives wrong answers. Modification time is not part of the key because other copy tools may not preserve it. The ledger also uses Sony's UMID, which survives renames.

## 2026-11-03: Import state lives outside project folders and cards

The ledger is `import-ledger.jsonl` in Application Support. Sidecar files would clutter projects, and cards must stay untouched. The folder scan means losing the ledger only loses history for moved or renamed clips.

## 2026-11-03: SHA-256 from CryptoKit, with a read-back from the destination

This needs no dependency. Hashing only during the copy would prove what was read, not what reached the disk, so the destination is read back without the cache. The cost is to be measured in milestone 2.

## 2026-11-03: Personal archive routed by shooting month

Destination is `media/YYYYMM/video/FX3`, matching the existing structure. The month comes from clip metadata rather than the import date, since cards are often offloaded later.

## 2026-11-03: v1 imports FX3 video only

Selected by Raycal to finish the main workflow first. Other devices are candidates behind the adapter boundary. DJI and TASCAM layouts have not been inspected on real media.

## 2026-11-03: New project does not copy a `.drp`

Requested by Raycal. New projects copy only the template folder.

## Clips play in the inspector, and Quick Look is gone

Raycal wants to review clips the way an editing app does, with the project still in view and J, K, and L working. Quick Look can't do either, so Space now plays in the inspector, and the Quick Look panel and its menu command were removed. Files that can't be played have no Space action, and open in their default app with "Open".

A wider inspector leaves a tall gap below a landscape video. A frame grid fills it because it helps choose clips, where stretching the details would only spread them out. It uses evenly spaced frames near keyframes, loaded after a short delay so that arrowing through a folder doesn't read every clip.

Keys are caught by one window-level monitor, because focus can be in an AppKit table, a SwiftUI list, or selectable text in the inspector.

## Tags are read from the attribute and written through the system

Reading a file's tag names from the file system leaves out their colors, so ReelDock reads `com.apple.metadata:_kMDItemUserTags`, which stores each tag as `Name\n7`. Writing goes through the `tagNames` resource value instead, because it also sets the color in `com.apple.FinderInfo` and keeps the color Finder has for each known tag. A test on a temporary file confirmed that writing only the attribute leaves that color unset.

## The full-screen preview is a borderless window

A native full-screen window moves to its own Space with a slow transition, which is wrong for a quick look at a clip. A borderless window above the menu bar opens instantly and can zoom out of the inspector's preview. It hides when the app is deactivated, so it never covers other apps.

## A card opens its panel when it appears

The panel exists only while a card is present, so it opens on insertion and closes when the last card leaves. Only a newly seen card opens it, including one already inserted when the app launches, so closing the panel stays closed until a card is inserted again. It opens in the front window only.
