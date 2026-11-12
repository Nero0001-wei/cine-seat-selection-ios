# CINÉ iOS Demo

SwiftUI 原生界面、系统 Liquid Glass 与 RealityKit 三维影厅。最低 iOS 26，使用 Xcode 26 或更新版本，无第三方依赖，不需要 API Key。

## 运行

打开 `CinemaDemo.xcodeproj`，选择 **CinemaDemo** scheme 和 iOS 26+ iPhone 模拟器，按 **⌘R**。

```sh
./scripts/run-simulator.sh
# 或指定设备
./scripts/run-simulator.sh SIMULATOR_ID
```

脚本自动选择可用 iPhone 模拟器并构建、安装、启动。Xcode 27 使用 Device Hub 显示设备；在其中选择设备并点 **View Screen**。真机需设置自己的开发团队。

## 体验

1. 总览点击座位，拖动平移，双指缩放；也可直接试坐推荐位置。
2. 进入实景后切换前排、中区、后排、侧边，拖动环视。
3. 切换开灯 / 放映中，查看材质与空间光影。
4. 点「影厅结构」观察逐排升高的平台与横向过道。
5. 选择位置，返回总览加选同行座位，确认并本地演示预留。

`TheaterLayout` 是排座、碰撞命中、平台高度与镜头视线的共同数据源。12×14 共 168 座；4/8 排后设置横向过道，每排升高 0.30 米。正交俯视和坐姿实景使用同一个 ARView 与相机转场；座椅共享程序化织物贴图、网格和材质。

两页共用磨砂 GlassPanel，使用原生 regular Liquid Glass、28% 炭灰局部底色、30pt 圆角和轻描边；底部固定，按内容自然高度做约 0.42 秒的弹簧变化。主操作使用柔金色系统 glassProminent 按钮。减少动态效果与降低透明度均有对应回退。

## 可选银幕视频

公开版本没有打包电影预告片或电影图片，直接运行会显示静态蓝色银幕。将自有或获授权的素材命名为 `cinema-trailer.mp4` 放入 `CinemaDemo/Media/` 后重新构建，也支持同名 mov/m4v。

视频通过 RealityKit VideoMaterial 默认静音循环，按原比例适配而不裁切。进入坐姿实景、转场结束后播放；返回总览、结构模式、弹层或失活时暂停。没有视频或无法解码时回到静态银幕。

## 测试

```sh
xcodebuild -project CinemaDemo.xcodeproj -scheme CinemaDemo \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -derivedDataPath .build CODE_SIGNING_ALLOWED=NO test
```

只跑模型测试时加 `-only-testing:CinemaDemoTests`。验证说明见 [../docs/validation.md](../docs/validation.md)，设计源文件见 [../design](../design)。

座位库存、票价、预留、倒计时和支付按钮均为本地演示，不连接真实影院或支付服务。
