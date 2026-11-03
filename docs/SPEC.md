# ReelDock v1 Specification

Status: draft for review. Milestone 1 is implemented and awaiting hands-on acceptance. See `TODO.md` for what has been verified.

## 1. Window layout

```
┌────────────┬──────────────────────────────────────────┬───────────┐
│ PROJECTS   │ [20261028_a] [20261019_b] [media/202611] │           │  native tabs
│ 🔍 filter  ├──────────────────────────────────────────┤ INSPECTOR │
│ ● 20261103 │ ▾ 1 output (2)                           │           │
│ ● 20261028 │   tc_4K60.mov    │                       │ preview   │
│ ● 20261027 │   sc_4K60.mov    │                       │           │
│            ├──────────────────────────────────────────┤ name      │
│ FAVORITES  │ ▾ 3 video (41)                           │ size      │
│ media      │   FX3          ▸ │ RAYCAL2251.MP4 │      │ duration  │
│ Raycal     │   screen rec.  ▸ │ RAYCAL2245.MP4 │      │ codec     │
│            │   RAYCAL2263.MP4 │ RAYCAL2244.MP4 │      │           │
│ CARDS      ├──────────────────────────────────────────┤ tags      │
│ ⏏ Untitled │ ▾ 4 audio (4)                            │ ● Green   │
│  2 new     │   bgm.mp3        │                       │ + add     │
│            ├──────────────────────────────────────────┤           │
│            │ ▸ 5 picture (empty)                      │           │
└────────────┴──────────────────────────────────────────┴───────────┘
```

- **Sections** are stacked vertically inside a split view that fits the window, so there is no outer scroll and scrolling never gets trapped between nested areas.
- **Each section is a column browser.** Clicking a folder opens its contents in the next column to the right, as in Finder's column view. Columns scroll independently, and a section scrolls sideways when columns overflow.
- **If too many sections are open to fit**, each keeps a minimum height and the stack scrolls as a fallback.
- **Section height** can be dragged. Collapsed sections keep their position as a one-line header. Empty sections always collapse.
- **Default height:** `video` always gets the most. Other sections get more with more items, within a limit. A dragged divider overrides this.
- **Default state:** when a folder has numbered sections, only `output`, `video`, and `cover` start open. A folder with no numbered sections starts with everything open. Toggling a section is remembered by name.
- **Clicking anywhere on a section's header** toggles it, except on its buttons. A maximize button gives that section most of the height, and pressing it again restores the layout. Heights and collapsed states are remembered by section name, so `3 video` behaves alike across projects.
- **Selection** is one per tab, across all sections. Selecting in another section clears the previous selection.
- **The inspector** is shared and can be hidden. It replaces Finder's per-browser preview column, which would not fit in a short section. It is 440 pt wide by default and can be dragged from 280 to 760 pt.
- **A section's columns scroll sideways** with a two-finger swipe or Shift and a mouse wheel, even with the pointer over a column.

## 2. Folders and sections

Any folder can open in either mode, and the mode can be switched per tab:

| Mode | Used by default for | Behavior |
| --- | --- | --- |
| Sections | Projects, and folders containing numbered subfolders | Each first-level subfolder is a section |
| Single browser | Other folders | One column browser fills the window |

A `media/202611` tab can be switched to sections mode to show `video`, `audio`, and `photo` together.

Rules for building sections from what is on disk:

| On disk | Result |
| --- | --- |
| `3 video`, `3video` | Numbered section, sorted by number. Both spellings exist in real projects. |
| Other first-level folders | Their own sections, after the numbered ones |
| Loose files at the project root | A `Files` section |
| Dot-files, `.DS_Store`, and files the system marks hidden | Hidden unless "Show hidden" is on |

Project list rules:

- Projects are the direct subfolders of the chosen root, newest first by the date in the name.
- `00000000_*` folders are templates and are not listed.
- Projects can be filtered by name and by tag.
- Opening a project that is already open switches to its tab.

Contents load only when they are shown. Real projects can contain Python environments, Git repositories, and deep proxy trees, so nothing scans a whole project in order to display it.

## 3. Tabs

- Native macOS window tabs: `⌘T` new tab, `⌘W` close, `⌘⇧[` and `⌘⇧]` switch. A tab can be dragged out into its own window.
- A new tab shows the project list.
- Open tabs, and the path open in each section, are restored on launch. Missing paths are skipped.

## 4. Sidebar

Listed in this order, because the project list is the longest:

- **Cards:** mounted cards, with a count of clips not yet imported. Arrives with milestone 2.
- **Favorites:** any folder or project, added by button or drag, and reorderable.
- **Projects:** the chosen root's list, with a filter field.

Clicking opens the folder in the current tab, or switches to its tab if it is already open. Command-click or the context menu opens a new tab.

## Preview and playback

Clips play in the inspector, not in a separate window, so the project stays in view.

| Key | Action |
| --- | --- |
| Space, or a click on the picture | Play or pause. A clip that has ended restarts. |
| `L` | Play forward. Each press doubles the speed, up to 8×. |
| `J` | Play backward, with the same doubling |
| `K` | Pause |
| Hold `K`, tap `L` or `J` | Step one frame forward or back |
| `F` or `P`, or the full-screen button | Full screen for videos and photos. `F`, `P`, or `Esc` exits. |

- The keys work with focus in the browser, the card list, or the inspector. They type normally while a name is being edited, and `J`, `K`, and `L` stay available for type-select when the selection can't be played.
- A clip opens only when it first plays, so browsing doesn't read whole files. If a clip is playing when the selection moves to another one, the next one plays too, at normal speed.
- Playback pauses when the inspector is hidden or the tab goes to the background. Pressing Space with the inspector hidden shows it.
- The preview follows the file's shape, so vertical footage and photos can use most of the panel's height.
- Full screen zooms out of the inspector's preview and back into it, covers the menu bar and Dock on that screen, and stays in the current Space. Playback keys keep working, Up and Down move through the list behind it, and controls hide after a moment without mouse movement. Moving to something that can't be shown closes it.
- Below a landscape video's details, a grid of evenly spaced frames fills the remaining height, showing only whole rows. Clicking a frame jumps there, and the frame nearest the playhead is outlined.

## 5. File operations

| Action | Behavior |
| --- | --- |
| Open / Open With | Default app, or chosen app |
| Space | Plays or pauses the selection in the inspector. See "Preview and playback". |
| Drag out | Real file URLs, usable by DaVinci Resolve and Finder. Copy and link only until milestone 3, so dragging can't move files. |
| Drag in, or between sections | Move on the same volume, copy across volumes (Option forces copy), as in Finder |
| Rename | Inline, with `Return`. A taken name is refused, never replaced. |
| New folder | `⇧⌘N` creates it inside the selected folder, or in the current column if none is selected. The column's context menu creates it in that column. The name starts in edit mode. |
| Copy, paste, move | Standard shortcuts |
| Delete | `⌘⌫` moves to Trash, with no permanent delete. The next file is then selected. |
| Undo | `⌘Z` undoes a new folder, a rename, or a move to Trash. Putting a file back never replaces one created since. |
| Camera cards | All of the above are unavailable on a camera card, in any folder view |
| Reveal in Finder | Available on every item |

Changes made outside the app appear automatically through FSEvents.

## 6. Finder tags

Tags are the real Finder tags, not a private copy. Tested on macOS 27.2:

- `NSURL.setResourceValue(_:forKey: .tagNamesKey)` writes tags, and a tag that already exists keeps its color (`Green` stayed 2 and `BGM` stayed 5).
- A new tag name written this way has no color.
- Colors are readable from the `com.apple.metadata:_kMDItemUserTags` attribute, stored as `name\ncolorIndex`. This format is not documented API, so a parsing failure must fall back to showing the tag without a color.

Behavior:

- Tag dots appear on rows, section headers, favorites, and project-list entries. A tag with no color shows as a hollow dot.
- Tags can be applied to multi-selections from the inspector or the context menu, and undone. A shortcut is not built yet.
- Suggestions come from the seven standard color tags plus tags seen on files. No public API listing Finder's full tag catalog was found.
- Setting a color on a brand-new tag is out of scope for v1. Users can create the color in Finder.

Existing tags already used this way: `Green`, `Orange`, and `Blue` on project folders, and `BGM` on audio files.

## 7. Card import

### Detection

- React to volume mount and unmount notifications.
- A volume is a Sony card if `PRIVATE/M4ROOT/CLIP` exists on it. Do not filter on "external": the built-in SD slot reports `removable=true` and `internal=true`.
- Device handling lives behind an adapter, so other cameras can be added without changing the main flow. v1 ships only the Sony adapter.

### Reading clips

The adapter reads metadata from the card, so listing is immediate and does not open any video:

| Field | Source |
| --- | --- |
| Clip list, codec, fps, duration in frames, UMID | `M4ROOT/MEDIAPRO.XML` |
| Camera model | `MEDIAPRO.XML` (`systemKind`), for example `ILME-FX3A` |
| Thumbnail | `M4ROOT/THMBNL/<name>T01.JPG` |
| Shooting time, lens, gamma | `CLIP/<name>M01.XML` |
| Size | File system |

- If `MEDIAPRO.XML` is missing or invalid, fall back to listing `*.MP4` in `CLIP` and show what can still be read.
- Ignore AppleDouble `._*` files, which can appear on exFAT.
- Use the shooting date as recorded in the XML, without converting it to the Mac's time zone.

### Import panel

Clicking the card button in the toolbar, or a card in the sidebar, opens a non-blocking panel beside the project: the project on the left, the card on the right, half of the content width by default. The divider can be dragged, and the width is remembered. The button shows an open state, and clicking it again closes the panel. Opening another project keeps the panel open, so clips can go there next.

```
Untitled · FX3 · 2 clips · 135 MB                 [⏏ Eject]
──────────────────────────────────────────────────────────
☑ Nov 3, 13:14 · 2 clips · 135 MB
  ☑ 🖼 20261103_RAYCAL2263.MP4                    67.7 MB
       13:14 · 3.5 s · 3840×2160 · 59.94p · S-Log3
       New
☐ Nov 2, 16:02 · 37 clips · 31 GB
  ☐ 🖼 20261102_RAYCAL2251.MP4                    67.7 MB
       16:02 · 8.0 s · 3840×2160 · 59.94p · S-Log3
       ✓ In 20261028_example
──────────────────────────────────────────────────────────
[Select New] [Deselect All]              ☐ Hide Imported
2 selected · 135 MB · 458 GB free
Into [3 video ▾]
          [Import to Archive]  [Import to 20261103_b ▾]
```

- Clips are grouped by day, then split when the gap between clips exceeds 60 minutes. A group's checkbox selects the whole group.
- Space plays a clip in the inspector. Previews show the source as shot, so S-Log3 looks flat.
- The panel opens by itself in the front window when a card is inserted or already present at launch, and closes when the last card leaves. The card button closes it, as does `Esc`. With no card, the button is disabled.
- Every new clip starts selected, so importing a whole card is one click. A group's checkbox and "Select New" never pick clips that are already imported.
- The panel stays open after an import, and the remaining new clips become the selection, so they can go to another project or the archive with one more click.
- The import button's menu can target any open project, favorite, or chosen folder.

### Clip status

| Status | Meaning | Default selection |
| --- | --- | --- |
| New | No match | Selected by "Select all" |
| In this project | Match inside the current target | Not selected |
| In `<place>` | Match elsewhere, and clicking reveals it | Not selected |
| Imported, now missing | Ledger entry, but the file is gone | Not selected, can be re-imported |

Matching uses two sources:

1. **The import ledger**, keyed by UMID, then by file name and size. It still recognizes clips that were later moved or renamed.
2. **A scan of existing folders**, keyed by file name **and** size. This covers clips copied before the app existed. It scans video sections under the project root and `media/*/video`, skipping `_proxy` and hidden folders.

File name alone is not enough. Real projects hold files with the same name and different contents, for example one 42 MB and the other 2.95 GB. Same name with a different size counts as not imported, and the import resolves the collision as described below.

Already-imported clips can still be selected and imported again deliberately.

### Destinations

**Project:** the section matching `video` (case-insensitive, with or without a number), at its top level by default. The panel can choose a subfolder, because some projects use `3 video/FX3`. If no video section exists, ask.

**Personal archive:** `<media root>/YYYYMM/video/<device folder>`.

- The month comes from each clip's shooting date, so one import can span several months.
- If the month folder is missing, create it by copying `<media root>/template`.
- `ILME-FX3A` maps to the `FX3` device folder. An unknown camera prompts for a folder.

### Copy pipeline

For each clip, one at a time per card:

1. Check free space for the whole batch before starting.
2. Copy to a hidden `.reeldock-<name>-<id>.part` in the destination, using large unbuffered reads, while hashing the source with SHA-256.
3. Read the written file back without the cache, and compare its hash.
4. Restore the original creation and modification dates.
5. Rename to the final name. If the name is taken, use `<name>_1.MP4`. Never overwrite.
6. Append the result to the ledger.

Clips are copied one at a time because parallel reads from one card add seeking without adding throughput.

**Background work:** copying continues while using any tab. A toolbar item shows progress, speed, and time remaining, with pause and cancel.

**When finished:** show a summary with an **Eject** button. Never eject automatically, and refuse to eject while a copy from that card is running.

**Failures:**

| Failure | Behavior |
| --- | --- |
| Card removed | Remove the `.part` file, mark that clip and the rest failed, and offer to retry after reinserting |
| Disk full or write error | Remove the `.part` file and stop the queue |
| Hash mismatch | Remove the `.part` file, retry once, then report the clip as failed |
| App quit or crash | Remove leftover `.part` files on next launch |

### What "faster" means

The transfer rate is limited by the card and reader, so ReelDock cannot exceed them. Time is saved in the steps around the copy: no navigating the card, no filtering XML, no checking for duplicates by hand, and no waiting while it copies. Verification adds a flush to disk and a read of each file from the destination SSD.

Measured on a freshly mounted 1.2 GB simulated card on the internal SSD: `cp` took about 1.2 s and ReelDock about 2.1 s, so verification costs about 0.7 s per GB. `cp` doesn't wait for its writes to reach the disk, so this slightly overstates the difference. A comparison on a real card with multi-GB clips is still to be done.

## 8. New project

- Duplicates `<root>/00000000_template` as `<root>/YYYYMMDD_<name>`, with today's date as an editable default. The template's `.DS_Store` is not copied.
- Does **not** copy a `.drp` file into `0 project`.
- Opens the new project in a new tab.
- If the name already exists, stay in the dialog and report it.

## 9. Stored data

Everything is in `~/Library/Application Support/ReelDock/`:

| File | Contents |
| --- | --- |
| `settings.json` | Root folder, media root, favorites, section heights, last tabs |
| `import-ledger.jsonl` | One line per imported clip: UMID, name, size, hash, destination, time |

The ledger is append-only plain text, so it can be inspected and backed up easily. Nothing is written into project folders or onto cards.

## 10. System access

- macOS will ask for access to the Desktop folder and to removable volumes, because projects live under `~/Desktop/video`.
- Builds need a stable code signature, or macOS asks again after each rebuild. A valid signing identity already exists on this Mac.
