#!/bin/zsh
# 一键导出「旅行L叔」安卓安装包（APK，给 AYN Thor 掌机自己装着玩）到桌面。在访达里双击即可。
# 2026-09-27 Carlos：「基于奥丁 thor 做一个安卓版本的导出」。掌机是他自己玩的机器，不是正式支持平台：不承诺帧率、不为它改美术参数。
# 需要（2026-09-27 已装好）：
#   · Godot 4.7.1 + 安卓导出模板（~/Library/Application Support/Godot/export_templates/4.7.1.stable/android_*.apk）
#   · JDK 17（~/Library/Java/JavaVirtualMachines/jdk-17*，Eclipse Temurin）
#   · Android SDK（~/Library/Android/sdk：build-tools/35.0.1 的 apksigner、platform-tools 的 adb）
#   · 发布签名证书 ~/Library/Application Support/Godot/keystores/lshu-release.keystore（别名 lshu），
#     密码只在同目录 lshu-release.pass（仅本人可读），这里经环境变量交给 Godot，不写进工程。
# 导出设置在 export_presets.cfg 的「Android」预设：只有 arm64、全屏沉浸、包名 com.lvxinglshu.game、图标 assets/game/app/android_icon_*。
# 安卓用 Mobile 渲染器（project.godot 的 renderer/rendering_method.mobile）；游戏里的圆体 / 手写体是苹果系统字体，安卓上会换成系统自带中文字体。
# 装到掌机：把 APK 拷过去点开安装（允许「安装未知来源应用」）；或者掌机开 USB 调试、连上电脑后：~/Library/Android/sdk/platform-tools/adb install -r <APK>
set -e
DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
# 导出门禁（2026-09-30 安卓压力测试 PAD-MAR-1）：generated/ 不在版本库里，worktree、新 clone 里没有长安的地图；
# 从这样的检出导出的包长安一进去就卡在载入卡。缺了就不导（工程里的 addons/lshu_export_gate 也会把这种包删掉）
if [ ! -f "$DIR/generated/traveler/atlas/atlas_world.tscn" ]; then
	echo "导出失败：这个检出里没有 generated/traveler/atlas（长安的地图，版本库不收它）。"
	echo "先从正式检出拷过来，或用 tools/traveler/build_atlas_scene.gd 重烘，再导出。"
	exit 1
fi
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
KS="$HOME/Library/Application Support/Godot/keystores"
STAMP=$(date +%Y%m%d-%H%M)
OUT="$HOME/Desktop/旅行L叔-安卓-$STAMP.apk"
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$KS/lshu-release.keystore"
export GODOT_ANDROID_KEYSTORE_RELEASE_USER=lshu
export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$(cat "$KS/lshu-release.pass")"
echo "导出 APK（一两分钟）…"
"$GODOT" --headless --path "$DIR" --export-release "Android" "$OUT"
[ -f "$OUT" ] || { echo "导出失败"; exit 1; }
"$HOME/Library/Android/sdk/build-tools/35.0.1/apksigner" verify "$OUT" && echo "签名有效"
echo "完成：$OUT"
open -R "$OUT"
