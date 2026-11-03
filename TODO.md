# TODO

States: Candidate, Selected, In progress, Blocked, Completed.

Milestones are selected for v1. A checked item is implemented. "Scripted" means it was exercised through the debug driver, not by hand.

## Milestone 0: Planning (In progress)

- [x] Create repository
- [x] Inspect real project folders and a real Sony card
- [x] Write README, AGENTS, SPEC, DECISIONS, and TODO
- [x] Confirm the app name: ReelDock
- [ ] Raycal reviews the spec

## Milestone 1: Workspace, read-only (In progress: awaiting hands-on acceptance)

Goal: replace Finder for browsing, with no writes to any user files.

- [x] Xcode project, signing, and native tabs (scripted)
- [x] Choose a root folder and list projects, excluding templates (list scripted on real folders, chooser not exercised)
- [x] Build sections from the folder rules (unit tests, and scripted on real projects)
- [x] Stacked sections with collapse, resize, and maximize (collapse and maximize scripted, divider drag not exercised)
- [x] Column browser in each section, with thumbnails and keyboard navigation (scripted, column resize not exercised)
- [x] Inspector with metadata, inline playback with J, K, and L, and a frame grid (keys and rendering scripted on generated clips and a real card, not seen playing on screen)
- [x] Full-screen preview with F or P and no animation (keys and final frame scripted, not seen on screen)
- [x] Choosing the full-screen display (not exercised on a second display: only one was connected)
- [x] Smooth backward playback at 1× and 2× (60 frames a second reach the display layer on a real 4K60 HEVC clip, not judged by eye; rotation checked by layer geometry only)
- [x] New tabs list the projects, with Open Folder kept (scripted, rendering checked off screen)
- [x] Sideways scrolling of a section's columns (scripted with synthetic scroll events, real trackpad not exercised)
- [x] Drag files out into DaVinci Resolve and Finder (not exercised)
- [x] Favorites, ordinary folders, and mode switching (scripted, except sidebar clicks and drops)
- [x] Live refresh through FSEvents, and restoring tabs on launch (scripted on temporary fixtures)
- [ ] Hands-on check of appearance and mouse behavior on a real screen

Done when: a real project with many clips and nested folders stays responsive, and two projects can be worked on side by side using tabs.

Fixed after the first hands-on check: sections mode was blank because each header painted over the whole stack.

Measured so far: real projects with 9 to 12 sections opened in under 0.7 s, including about 0.2 to 0.4 s of test polling.

## Milestone 2: Card import (In progress: awaiting hands-on acceptance)

Unit tests cover parsing, grouping, statuses, routing, and the copier. "Scripted" means run through the debug driver on a real card (read-only) or simulated cards, writing only to temporary folders.

- [x] Sony adapter that parses metadata, with fixtures that contain no real identifiers
- [x] Card detection through mount and unmount notifications (scripted on simulated cards, real insertion not exercised)
- [x] Import panel beside the project, with date grouping, thumbnails, and preview (rendering and playback scripted, mouse use not exercised)
- [x] Panel opens when a card is inserted and closes when the last card leaves, and the card button is disabled with no card (scripted on a simulated card, real insertion not exercised)
- [x] Clip status from the ledger and a folder scan (scripted on real folders: the card's two clips show as already imported)
- [x] Copy engine with verification, safe naming, and failure handling (scripted)
- [x] Background queue with progress, pause, and cancel (scripted, progress popover not exercised)
- [x] Personal archive routing by shooting month, created from the template (scripted on a temporary archive)
- [x] Eject after import without blocking the app, with a spinner and sounds (scripted on a simulated card, refused while copying, accepted on a real card)
- [ ] Hands-on import from a real card into a real project and the real archive
- [ ] Timed comparison with Finder on a real card with multi-GB clips

Failure paths exercised on simulated volumes: card removed mid-copy, retry after reinserting, destination full during a copy, not enough space up front, cancel, and a crash leaving a temporary file. A hash mismatch is covered by unit tests only.

Not exercised: the prompt for an unknown camera, the prompt when a project has no video folder, and quitting during an import.

## Milestone 3: File operations and tags (In progress)

- [x] New folder, inline rename, move to Trash, and undo for all three (scripted on temporary fixtures, and refused on a simulated card)
- [ ] Copy, paste, and move
- [ ] Drag in and between sections
- [ ] Make dragging to Finder copy files. It currently creates an alias, because dragging out only allows copy and link.
- [x] Read tags and colors, and show them on rows, section headers, favorites, and the project list (colors read from real projects, rendering scripted on fixtures, sidebar not seen on screen)
- [x] Write tags on single and multiple selections, with Finder's color row and undo (scripted on fixtures through the palette's own handler, menus not seen on screen, not yet checked in Finder)
- [x] Show tag dots in front of names on projects, favorites, the new-tab list, and tabs (tabs and the new-tab list seen in snapshots, sidebar not seen on screen)
- [ ] Filter projects by tag
- [ ] New project from template

Done when: tags set in ReelDock appear in Finder and tags set in Finder appear in ReelDock, tested on temporary fixtures.

## Candidates (not selected)

- DJI Action video import
- TASCAM DR-05XP audio import
- FX3 photo import
- Importing FX3 proxies from `M4ROOT/SUB`
- Applying a LUT to S-Log3 previews
- Tagging clips during import
- Search across all projects
- Grid view for picture and cover sections
- Showing project size and storage use
