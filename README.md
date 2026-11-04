# ReelDock

A native macOS workspace for video projects: open a project and see every folder at once, and offload camera cards without digging through them in Finder.

**Status: browsing, card import, inline playback, basic file operations, and Finder tags are implemented and awaiting hands-on acceptance.** The list below describes the intended first version. See [docs/SPEC.md](docs/SPEC.md) for behavior, [TODO.md](TODO.md) for milestones, and [DECISIONS.md](DECISIONS.md) for the reasoning behind lasting choices.

## Why

Video projects here all share one layout:

```
project/
└── 20261028_example/
    ├── 0 project/
    ├── 1 output/
    ├── 2 cover/
    ├── 3 video/
    ├── 4 audio/
    ├── 5 picture/
    └── _proxy/
```

Finder makes this slow in two ways:

- **Moving between folders.** Checking footage, then output, then audio means going in and out of folders, and working on two projects means doing that in two places.
- **Copying from a card.** Sony cards keep clips at `PRIVATE/M4ROOT/CLIP`, next to XML sidecars that have to be filtered out by hand. A single card often holds footage for several projects plus personal clips.

## Planned for v1

**Project workspace**

- Pick a root folder, then open any project inside it from the sidebar.
- Each subfolder is a section stacked vertically, and each section browses like Finder's column view.
- One tab per project, using native macOS window tabs.
- Open any ordinary folder the same way, and save favorites.
- Read and write real Finder tags, so they stay in sync with Finder.
- Create a project from the template folder, named `YYYYMMDD_name`.
- Trim MP4 and MOV clips with in and out points, and rotate them instantly, without re-encoding.
- Rotate and crop JPEG, PNG, HEIC, and TIFF images. Saving keeps the original in the Trash, or writes a copy beside it.

**Card import**

- Detect inserted Sony cards and list only the video clips, with thumbnails.
- Group clips by date and time gap, and preview them before choosing.
- Import everything or a selection into the open project.
- Show which clips were already imported and where, across all projects and the personal archive.
- Send remaining clips to the personal archive, sorted automatically into `media/YYYYMM/video/FX3` by shooting date.
- Copy in the background, verify every file, never overwrite anything, and never write to the card.

## Not in v1

- Importing from DJI Action, TASCAM recorders, or FX3 photos. The import code is split by device so these can be added later.
- Deleting clips from cards. Format cards in the camera.
- Applying LUTs to previews, generating proxies, or integrating with DaVinci Resolve beyond dragging files into it.

## Install

Download the DMG from [Releases](https://github.com/raycalrui/ReelDock/releases), and drag ReelDock to Applications. Builds are signed with a Developer ID and notarized by Apple. ReelDock checks for updates once a day, and **ReelDock > Check for Updates…** checks right away. An update always asks before installing.

## Requirements

- macOS 26 or later
- Xcode 27 to build

## Building

Open `ReelDock.xcodeproj` in Xcode, choose your own team under Signing & Capabilities, and press ⌘R. On first launch, choose the folder that contains your projects.

To run the tests from the command line:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ReelDock.xcodeproj -scheme ReelDock test
```

## License

[MIT](LICENSE). Updates use [Sparkle](https://sparkle-project.org), which has its own [license](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE).
