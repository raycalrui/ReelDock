# ReelDock

A native macOS workspace for video projects: open a project and see every folder at once, and offload camera cards without digging through them in Finder.

一个原生 macOS 视频项目工作台：打开项目就能看到所有文件夹，拷卡也不用再在 Finder 里一层层翻。

**Status: browsing, card import, inline playback, basic file operations, and Finder tags are implemented and awaiting hands-on acceptance.** The list below describes the intended first version. See [docs/SPEC.md](docs/SPEC.md) for behavior, [TODO.md](TODO.md) for milestones, and [DECISIONS.md](DECISIONS.md) for the reasoning behind lasting choices.

**状态：浏览、拷卡、内置播放、基础文件操作和 Finder 标签都已实现，等待实际使用验收。** 下面的列表描述的是计划中的第一版。具体行为见 [docs/SPEC.md](docs/SPEC.md)，里程碑见 [TODO.md](TODO.md)，长期决策的理由见 [DECISIONS.md](DECISIONS.md)，这些文档都是英文。

## Why / 为什么做

Video projects here all share one layout:

这里的视频项目都用同一种结构：

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

Finder 在两件事上很慢：

- **Moving between folders.** Checking footage, then output, then audio means going in and out of folders, and working on two projects means doing that in two places.<br>**在文件夹之间切换。** 看素材、看成片、再看音频，都要进进出出，同时做两个项目还得在两个地方重复一遍。
- **Copying from a card.** Sony cards keep clips at `PRIVATE/M4ROOT/CLIP`, next to XML sidecars that have to be filtered out by hand. A single card often holds footage for several projects plus personal clips.<br>**从卡里拷素材。** Sony 卡把片段放在 `PRIVATE/M4ROOT/CLIP`，旁边还混着要手动筛掉的 XML 文件。一张卡里常常有好几个项目的素材，还夹着个人片段。

## Planned for v1 / v1 计划

**Project workspace / 项目工作台**

- Pick a root folder, then open any project inside it from the sidebar.<br>选一个根文件夹，然后从侧边栏打开其中任意项目。
- Each subfolder is a section stacked vertically, and each section browses like Finder's column view.<br>每个子文件夹是一个纵向堆叠的分区，每个分区都能像 Finder 分栏视图那样浏览。
- One tab per project, using native macOS window tabs.<br>一个项目一个标签页，用的是 macOS 原生窗口标签页。
- Open any ordinary folder the same way, and save favorites.<br>普通文件夹也能用同样的方式打开，还能加入收藏。
- Read and write real Finder tags, so they stay in sync with Finder.<br>读写真正的 Finder 标签，和 Finder 保持同步。
- Create a project from the template folder, named `YYYYMMDD_name`.<br>用模板文件夹新建项目，命名为 `YYYYMMDD_name`。
- Trim MP4 and MOV clips with in and out points, and rotate them instantly, without re-encoding.<br>用入点和出点剪辑 MP4 和 MOV 片段，也能即时旋转，都不用重新编码。
- Rotate and crop JPEG, PNG, HEIC, and TIFF images. Saving keeps the original in the Trash, or writes a copy beside it.<br>旋转和裁剪 JPEG、PNG、HEIC、TIFF 图片。保存时原文件进废纸篓，也可以在旁边另存一份。

**Card import / 拷卡**

- Detect inserted Sony cards and list only the video clips, with thumbnails.<br>检测插入的 Sony 卡，只列出视频片段，并显示缩略图。
- Group clips by date and time gap, and preview them before choosing.<br>按日期和时间间隔给片段分组，选择前可以预览。
- Import everything or a selection into the open project.<br>把全部或选中的片段导入当前打开的项目。
- Show which clips were already imported and where, across all projects and the personal archive.<br>显示哪些片段已经导入过、导入到了哪里，范围包括所有项目和个人归档。
- Send remaining clips to the personal archive, sorted automatically into `media/YYYYMM/video/FX3` by shooting date.<br>把剩下的片段送到个人归档，按拍摄日期自动放进 `media/YYYYMM/video/FX3`。
- Copy in the background, verify every file, never overwrite anything, and never write to the card.<br>在后台拷贝并校验每个文件，绝不覆盖任何文件，也绝不写入存储卡。

## Not in v1 / v1 不包含

- Importing from DJI Action, TASCAM recorders, or FX3 photos. The import code is split by device so these can be added later.<br>从 DJI Action、TASCAM 录音机导入，或导入 FX3 照片。导入代码按设备拆分，以后可以加上。
- Deleting clips from cards. Format cards in the camera.<br>删除卡里的片段。请在相机里格式化存储卡。
- Applying LUTs to previews, generating proxies, or integrating with DaVinci Resolve beyond dragging files into it.<br>给预览套 LUT、生成代理，以及除拖入文件之外的 DaVinci Resolve 集成。

## Install / 安装

Download the DMG from [Releases](https://github.com/raycalrui/ReelDock/releases), and drag ReelDock to Applications. Builds are signed with a Developer ID and notarized by Apple. ReelDock checks for updates once a day, and **ReelDock > Check for Updates…** checks right away. An update always asks before installing.

从 [Releases](https://github.com/raycalrui/ReelDock/releases) 下载 DMG，把 ReelDock 拖进“应用程序”文件夹。安装包使用 Developer ID 签名，并通过了 Apple 公证。ReelDock 每天检查一次更新，**ReelDock > Check for Updates…** 可以立即检查。安装更新前一定会先询问。

## Requirements / 系统要求

- macOS 26 or later<br>macOS 26 或更高版本
- Xcode 27 to build<br>构建需要 Xcode 27

## Building / 构建

Open `ReelDock.xcodeproj` in Xcode, choose your own team under Signing & Capabilities, and press ⌘R. On first launch, choose the folder that contains your projects.

在 Xcode 里打开 `ReelDock.xcodeproj`，在 Signing & Capabilities 里选择你自己的团队，然后按 ⌘R。首次启动时，选择存放项目的文件夹。

To run the tests from the command line:

用命令行运行测试：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ReelDock.xcodeproj -scheme ReelDock test
```

## License / 许可证

[MIT](LICENSE). Updates use [Sparkle](https://sparkle-project.org), which has its own [license](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE).

[MIT](LICENSE)。更新功能使用 [Sparkle](https://sparkle-project.org)，它有自己的[许可证](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE)。
