#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
DEMO_DIR="${SCRIPT_DIR:h}"
SIMULATOR_ID="${1:-}"
DERIVED_DIR="${DEMO_DIR}/.build"

if [[ -z "$SIMULATOR_ID" ]]; then
  SIMULATOR_ID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
phones = [device for runtime, devices in data["devices"].items()
          if ".iOS-" in runtime and int(runtime.split(".iOS-")[1].split("-")[0]) >= 26
          for device in devices
          if device.get("isAvailable", False)
          and "iPhone" in device.get("deviceTypeIdentifier", "")]
preferred = next((d for d in phones if d["name"] == "CINE 3D Demo"), None)
preferred = preferred or next((d for d in phones if d["state"] == "Booted"), None)
preferred = preferred or next(iter(phones), None)
print(preferred["udid"] if preferred else "")
')"
fi

if [[ -z "$SIMULATOR_ID" ]]; then
  print -u2 "没有可用的 iPhone 模拟器，请先在 Xcode 中安装 iOS 26 或更新的 Simulator runtime。"
  exit 1
fi

xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcodebuild -project "$DEMO_DIR/CinemaDemo.xcodeproj" -scheme CinemaDemo \
  -configuration Debug -destination "id=$SIMULATOR_ID" \
  -derivedDataPath "$DERIVED_DIR" CODE_SIGNING_ALLOWED=NO build
xcrun simctl install "$SIMULATOR_ID" "$DERIVED_DIR/Build/Products/Debug-iphonesimulator/CinemaDemo.app"
xcrun simctl launch "$SIMULATOR_ID" com.cine.seatdemo

CINE_SIMULATOR_APP="$(xcode-select -p)/Applications/Simulator.app"
CINE_DEVICE_HUB_APP="$(xcode-select -p)/../Applications/DeviceHub.app"
if [[ -d "$CINE_SIMULATOR_APP" ]]; then
  open -a "$CINE_SIMULATOR_APP" --args -CurrentDeviceUDID "$SIMULATOR_ID" || true
elif [[ -d /Applications/Simulator.app ]]; then
  open -a /Applications/Simulator.app --args -CurrentDeviceUDID "$SIMULATOR_ID" || true
elif [[ -d "$CINE_DEVICE_HUB_APP" ]]; then
  if open -a "$CINE_DEVICE_HUB_APP"; then
    print "已打开 Device Hub。请在侧栏选择本次模拟器（默认 CINE 3D Demo），点击 View Screen 显示设备。"
  else
    print "App 已启动到模拟器 $SIMULATOR_ID。请从 Xcode > Open Developer Tool > Device Hub 打开设备窗口。"
  fi
else
  print "App 已启动到模拟器 $SIMULATOR_ID。请通过 Xcode 的 Open Developer Tool 打开设备窗口。"
  print "可使用 xcrun simctl io $SIMULATOR_ID screenshot screenshot.png 导出运行画面。"
fi
