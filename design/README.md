# CINÉ 设计源文件

这里同时保留当前暗色方案的设计数据、Figma 图层导出，以及较早的浅色探索稿。运行中的三维影厅以 iOS 源码为准。

## 当前方案

| 文件 | 内容 |
| --- | --- |
| [latest/figma-overview-ui.svg](latest/figma-overview-ui.svg) | 最新俯视选座页的 Figma UI 矢量与文字图层 |
| [latest/figma-seat-view-ui.svg](latest/figma-seat-view-ui.svg) | 最新观影视角页的 Figma UI 矢量与文字图层 |
| [latest/ui-spec.json](latest/ui-spec.json) | 402 × 874 pt 参考画布、10 个主要状态的文案、卡片与控件边界 |
| [latest/tokens.json](latest/tokens.json) | 暗色、金色操作按钮、玻璃材质、圆角、字体角色及卡片动画参数 |
| [latest/theater-layout.json](latest/theater-layout.json) | 从 Swift 模型导出的 168 个座位、库存示例、三维坐标、阶梯高度、横向过道、银幕与视点 |

两个 Figma SVG 是现存设计页面的真实图层导出，保留了可编辑的矢量和文字，**不是整页截图，也不是原生 `.fig` 文件**。可以将 SVG 导入 Figma 后继续编辑；系统字体在不同环境中可能需要替换。

SVG 中的三维场景栅格填充已移除，因此不包含影片帧。影厅、阶梯、座椅材质和相机由 [RealityKit 场景源码](../iOSDemo/CinemaDemo/Scene)生成；公开版 App 的实际运行画面另见 [docs/images](../docs/images)。

当前布局是每排连续 14 座、共 12 排，按前中后三段分区；第 4 排和第 8 排后各有 1.45 m 横向过道。从银幕向后每排升高 0.30 m，第一排地面高度为 0 m，最后一排为 3.30 m。设计数据中的场景长度单位为米，UI 边界单位为逻辑点。

底部卡片使用 iOS 原生 regular glass 与额外暗色底，面板圆角 30 pt、内容边距 16 pt。高度和内容的切换使用 0.42 s 弹簧动画。静态 SVG 只记录界面状态，实际玻璃折射、视频播放、三维转头和镜头过渡需要运行 App。

这些 UI 尺寸是参考设备上的实测近似值；其他屏幕由 SwiftUI 布局。库存、票价、保留与支付状态均为演示数据。

## Figma 源页面

- [俯视选座页面](https://www.figma.com/design/2Lpz6SXUPbAjcHAytHZhBd?node-id=7-184)
- [观影视角页面](https://www.figma.com/design/2Lpz6SXUPbAjcHAytHZhBd?node-id=70-884)

Figma 源文件继续使用原文件的访问权限，不保证匿名访问。仓库中的 SVG 与 JSON 可以直接下载，不依赖 Figma 权限。本仓库不包含原生 `.fig` 下载文件。

## 早期浅色探索稿

[archive/light-concept](archive/light-concept) 保存较早的暖白与橙色方案：

- 5 个紧凑版 SVG：总览、单座、双座、侧边选中、前排选中。
- 原始座位布局 JSON。
- 生成展开 SVG 的 `generate_overviews.py`。
- 将重复座椅转成可复用矢量形状的 `compress_svg.py`。

这些 SVG 全部由路径、渐变和矢量复用组成，没有嵌入位图。它们采用较早的 4 / 6 / 4 三列与纵向通道布局，**不代表当前暗色、横向过道、逐排抬高的实现**。

从仓库根目录执行以下命令可以重新生成归档稿，输出会写回脚本所在目录：

```sh
python3 design/archive/light-concept/generate_overviews.py
python3 design/archive/light-concept/compress_svg.py
```

也可以只运行压缩脚本；它会在缺少展开 SVG 时先调用生成器。只依赖 Python 3 标准库。原始归档 JSON 记录最初的三个选择变体；重生成时会同时补入侧边和前排两个变体。

## 更新当前三维布局数据

修改 Swift 模型后，在仓库根目录运行：

```sh
python3 design/scripts/export-theater-layout.py
```

导出器从 `iOSDemo/CinemaDemo/Models/CinemaModel.swift` 读取标量常量与已售座位列表，按同一套坐标和视线公式生成 JSON，并记录源码 SHA-256。坐标四舍五入至 6 位小数；运行时采用 Swift `Float`。如果改变 Swift 中的几何公式，也应同时更新这个导出器。UI 文案、尺寸和 tokens 则在修改 SwiftUI 后人工核对。

设计完善过程参考了 [unslop](https://github.com/heydamir/unslop)（Damir Sokolovsky，CC BY 4.0）的界面整理指导。
