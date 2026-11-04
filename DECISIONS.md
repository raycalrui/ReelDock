# Decisions

Lasting choices and why they were made. Dates are absolute.

## 2026-11-04: Pastes use the import pipeline, not `FileManager.copyItem`

Footage may not exist anywhere else, so every pasted file is hashed, read back, and verified like an import, and a folder appears only once all of it is done. This costs some time on large copies. The originals of a move across volumes go to the Trash rather than being deleted, so a mistake can still be undone.

## 2026-11-04: Taken names get a new name without asking

The media rules allow a new name or an explicit choice. A new name keeps a batch moving, and the activity popover reports it. Replacing is not offered at all.

## 2026-11-04: New projects can't be undone with `⌘Z`

Footage is often imported straight after creating a project, and imports aren't on the undo stack, so `⌘Z` could send freshly imported footage to the Trash. Rename fixes a typo.

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

A native full-screen window moves to its own Space with a slow transition, which is wrong for a quick look at a clip. A borderless window above the menu bar opens instantly. Raycal asked for no animation at all, so it has none. It hides when the app is deactivated, so it never covers other apps.

## Slow backward playback doesn't use AVPlayer

Measured on a 4K 59.94p HEVC 10-bit clip with one-second keyframes: `AVPlayer` delivers 18 frames a second at -1× and 34 at -2×, with or without audio, but 58 at -4×. The decoder alone manages about 500 frames a second at 1080p. So at 1× and 2×, ReelDock decodes a stretch forward with `AVAssetReader` and shows it backward on a sample-buffer layer above the player, reaching 60 frames a second. Frames are scaled to 1920 pixels because a stretch is held in memory whole. At 4× and 8×, `AVPlayer` stays, since decoding that many stretches wouldn't keep up. Decoded frames arrive unrotated, so the layer is rotated to match the clip.

## Tag menus are AppKit menus

Finder's row of color dots is `NSMenu.palette`, which a SwiftUI context menu can't hold. The sidebar's rows therefore catch secondary clicks with a small AppKit view and show an `NSMenu`, so every tag menu in the app is the same one.

## Tags show as dots in front of the name

A faint background in the tag's color was tried on project rows and rejected after use, since it made the list look heavy. Dots at the far edge sat too far from the name, so they go in front of it. `NSWindowTab.accessoryView` always sits at the tab's far edge, so tabs put the dots in `attributedTitle` instead. They are an image there because the tab recolors its title's text, which turns a colored glyph gray.

## The app icon is an Icon Composer document

`ReelDock/AppIcon.icon` holds layered SVGs, so the system renders the glass and handles the default, dark, and clear appearances itself. A flat image can't refract or blur what's behind it. Edit it in Icon Composer, which ships inside Xcode.

## Updates use Sparkle

Replacing a running app safely, and checking that a download really came from us, is easy to get subtly wrong, so this is the one third-party dependency, as in Raycal's other apps. Both the appcast and the DMG are checked against an EdDSA key. A Debug build has the release's bundle ID, so it never starts the updater, or a download could replace the build Xcode is running.

## A card opens its panel when it appears

The panel exists only while a card is present, so it opens on insertion and closes when the last card leaves. Only a newly seen card opens it, including one already inserted when the app launches, so closing the panel stays closed until a card is inserted again. It opens in the front window only.

## The inspector follows the selection

An empty inspector only takes width from the browser, so it hides when nothing is selected and returns with a selection. Hiding it by hand with something selected is a choice about that tab, so it stays hidden until it's shown again. The window's minimum width now fits all three panes, so showing the inspector doesn't have to resize the window.

## Dragging uses Finder's rules, and paste's machinery

A drag within the app moves on one volume and copies across volumes, with Option and Command overriding that, because that's what the hands already expect. It runs through the same transfer queue as paste, so verification, naming, undo, and the card rules don't have a second implementation. A drop on a section header exists because a collapsed or empty section has no column to drop on.

## Finder's tags are gathered, not read from a list

macOS has no public API for the tags Finder lists, and this system has no readable file holding them. More Tags combines the tags Spotlight finds on files with the names in Finder's preferences. The preference keys are undocumented, so they're read only, and missing ones just mean a shorter list. A private framework would be more complete, but could break with any macOS update.

## Dragging out only allows copy

Allowing link made Finder create an alias. Allowing move would let a drag take footage out of a project, or off to the Trash. Copy is the one thing every drag out should do.

## Hovering opens folders by selecting them

Selecting a folder already opens its column, so spring loading uses the same path and needs no second way of opening one. A drag's source column can be replaced by this, so it's kept alive until the drag ends.

## Saving an edited image never destroys the original

Preview changes a file in place, while this app never overwrites one. Save gives the same result on the file's path, but builds and checks the new version first and moves the original to the Trash, so undo can swap them back. Save Copy is there for when both are wanted. Only formats that hold one flat image can be edited, because writing a PSD or PDF back through ImageIO would lose its layers or pages, and RAW has no writer.

## Rotating bakes the pixels

Setting the orientation flag would avoid re-encoding a JPEG, but not everything that reads these files honors it, and crop has to re-encode anyway. Saved edits are upright with the flag cleared.

## Video edits never re-encode

Trimming is a passthrough export that copies the marked samples and uses an edit list to start on the exact frame, so it keeps the codec and audio as they are, including Sony's LPCM in MP4. It takes a verified new file, so Save follows the same path as images: original to the Trash, new version in its place.

## Rotating a video changes the file in place

Rotation only needs a different display matrix in each video track's header. Patching those few bytes is instant at any file size, leaves the media untouched, and is undone by turning back, so a copy would only add a wait and fill the Trash. This is the one edit that writes to an existing file, and it never runs on a card or while the file is busy.
