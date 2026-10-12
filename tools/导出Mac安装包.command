#!/bin/zsh
# 一键导出「旅行L叔」Mac 安装包（DMG）到桌面。在访达里双击即可。
# 需要：/Applications/Godot.app（4.7.1）和已安装的 4.7.1 导出模板（~/Library/Application Support/Godot/export_templates/4.7.1.stable）。
# 入口是 3D 棋盘对局（project.godot 里 run/main_scene.lshu_release）；资料、源稿、测试、实验不打包（export_presets.cfg）。
# 旅人模式四幕（长安 / 盘橐 / 巴格达 / L叔去哪儿）运行时要读的场景、资源、数据都打包；各幕的开发工具、原始 FBX / 动画源、
# 旧的烘焙场景按 export_presets.cfg 的 exclude_filter 排除（2026-09-27）。导出后可跑 tools/traveler/release_act_smoke.sh <App> 逐幕冒烟。
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
STAMP=$(date +%Y%m%d-%H%M)
# 打包目录必须在项目外面：里面有指向 /Applications 的快捷方式，放在项目里 Godot 扫描时会顺着它把整个
# 应用程序文件夹当成项目资源去导入（2026-09-26 出过一次，往别的 App 包里写了几千个 .import 文件）
TMP="$(mktemp -d -t lshu_dmg)"
STAGE="$TMP/stage"
mkdir -p "$STAGE"
trap 'rm -rf "$TMP"' EXIT
echo "① 导出 App（几分钟）…"
"$GODOT" --headless --path "$DIR" --export-release "macOS" "$STAGE/旅行L叔.app"
[ -d "$STAGE/旅行L叔.app" ] || { echo "导出失败"; exit 1; }
ln -s /Applications "$STAGE/应用程序"
cat > "$STAGE/第一次打开请看.txt" <<'TXT'
旅行L叔 · 安装与第一次打开

1. 把「旅行L叔」拖进旁边的「应用程序」文件夹。
2. 第一次打开时，系统可能提示「无法验证开发者」（这个包没有苹果开发者签名）：
   打开「系统设置 → 隐私与安全性」，往下找到「旅行L叔」那一行，点「仍要打开」，再确认一次。
   以后就能直接双击打开了。
3. 第一次点「出发」进对局时，电脑要先把 3D 地图的画法准备好，画面会停住 30 秒到一两分钟，
   这是正常的，别关掉。只有这台 Mac 第一次会这样，以后进对局就快了。
   旅人模式每一幕第一次进也一样，会先显示「L叔在收拾行李…」（巴格达最久，可能一分钟左右）。
4. 胜场、提示开关、对局时长存在这台 Mac 自己的「~/Library/Application Support/ShanheLvren」里。
TXT
echo "② 打包 DMG…"
DMG="$HOME/Desktop/旅行L叔-$STAMP.dmg"
hdiutil create -volname "旅行L叔" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "完成：$DMG"
open -R "$DMG"
