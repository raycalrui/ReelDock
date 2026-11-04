# ReelDock

[English](README.md) | 简体中文

一个原生 macOS 视频项目工作台：打开项目就能看到所有文件夹，拷卡也不用再在 Finder 里一层层翻。

**状态：浏览、拷卡、内置播放、基础文件操作和 Finder 标签都已实现，等待实际使用验收。** 下面的列表描述的是计划中的第一版。具体行为见 [docs/SPEC.md](docs/SPEC.md)，里程碑见 [TODO.md](TODO.md)，长期决策的理由见 [DECISIONS.md](DECISIONS.md)，这些文档都是英文。

## 为什么做

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

Finder 在两件事上很慢：

- **在文件夹之间切换。** 看素材、看成片、再看音频，都要进进出出，同时做两个项目还得在两个地方重复一遍。
- **从卡里拷素材。** Sony 卡把片段放在 `PRIVATE/M4ROOT/CLIP`，旁边还混着要手动筛掉的 XML 文件。一张卡里常常有好几个项目的素材，还夹着个人片段。

## v1 计划

**项目工作台**

- 选一个根文件夹，然后从侧边栏打开其中任意项目。
- 每个子文件夹是一个纵向堆叠的分区，每个分区都能像 Finder 分栏视图那样浏览。
- 一个项目一个标签页，用的是 macOS 原生窗口标签页。
- 普通文件夹也能用同样的方式打开，还能加入收藏。
- 读写真正的 Finder 标签，和 Finder 保持同步。
- 用模板文件夹新建项目，命名为 `YYYYMMDD_name`。
- 用入点和出点剪辑 MP4 和 MOV 片段，也能即时旋转，都不用重新编码。
- 旋转和裁剪 JPEG、PNG、HEIC、TIFF 图片。保存时原文件进废纸篓，也可以在旁边另存一份。

**拷卡**

- 检测插入的 Sony 卡，只列出视频片段，并显示缩略图。
- 按日期和时间间隔给片段分组，选择前可以预览。
- 把全部或选中的片段导入当前打开的项目。
- 显示哪些片段已经导入过、导入到了哪里，范围包括所有项目和个人归档。
- 把剩下的片段送到个人归档，按拍摄日期自动放进 `media/YYYYMM/video/FX3`。
- 在后台拷贝并校验每个文件，绝不覆盖任何文件，也绝不写入存储卡。

## v1 不包含

- 从 DJI Action、TASCAM 录音机导入，或导入 FX3 照片。导入代码按设备拆分，以后可以加上。
- 删除卡里的片段。请在相机里格式化存储卡。
- 给预览套 LUT、生成代理，以及除拖入文件之外的 DaVinci Resolve 集成。

## 安装

从 [Releases](https://github.com/raycalrui/ReelDock/releases) 下载 DMG，把 ReelDock 拖进“应用程序”文件夹。安装包使用 Developer ID 签名，并通过了 Apple 公证。ReelDock 每天检查一次更新，**ReelDock > Check for Updates…** 可以立即检查。安装更新前一定会先询问。

## 系统要求

- macOS 26 或更高版本
- 构建需要 Xcode 27

## 构建

在 Xcode 里打开 `ReelDock.xcodeproj`，在 Signing & Capabilities 里选择你自己的团队，然后按 ⌘R。首次启动时，选择存放项目的文件夹。

用命令行运行测试：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ReelDock.xcodeproj -scheme ReelDock test
```

## 许可证

[MIT](LICENSE)。更新功能使用 [Sparkle](https://sparkle-project.org)，它有自己的[许可证](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE)。
