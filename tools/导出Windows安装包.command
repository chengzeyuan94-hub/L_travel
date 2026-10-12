#!/bin/zsh
# 一键导出「旅行L叔」Windows 版（x86_64，免安装 zip）到桌面。在访达里双击即可。
# 2026-09-27 Carlos：「另外再导出一个 windows 电脑版本安装包出来」。
# 需要：/Applications/Godot.app（4.7.1）和已安装的 4.7.1 导出模板（windows_release_x86_64.exe）。设置在 export_presets.cfg 的「Windows」预设。
# 在 Mac 上导出的限制：
#   · exe 文件本身的图标 / 版本信息要 rcedit（Windows 工具）才能写进去，这里关掉了（application/modify_resources=false）：
#     资源管理器里显示 Godot 默认图标；游戏运行时窗口和任务栏用 project.godot 的 config/icon（L叔）。
#   · 没有代码签名：第一次运行 Windows 会提示「已保护你的电脑」，点「更多信息 → 仍要运行」。
#   · 游戏里的圆体 / 手写体是苹果系统字体，Windows 上换成系统自带中文字体。
# 包里文件名用英文（LvXingLShu.exe / .pck），避免 Windows 解压 zip 时中文名乱码；exe 和 pck 必须在同一个文件夹。
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
TMP="$(mktemp -d -t lshu_win)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/LvXingLShu"
echo "导出 Windows 版（半分钟左右）…"
"$GODOT" --headless --path "$DIR" --export-release "Windows" "$TMP/LvXingLShu/LvXingLShu.exe"
[ -f "$TMP/LvXingLShu/LvXingLShu.pck" ] || { echo "导出失败"; exit 1; }
cat > "$TMP/LvXingLShu/README.txt" <<'TXT'
旅行L叔 · Windows 版 · 使用说明

1. 把整个 LvXingLShu 文件夹解压到任意位置，不要只拷 exe：LvXingLShu.exe 和 LvXingLShu.pck 必须在同一个文件夹里。
2. 双击 LvXingLShu.exe 开始游戏。
3. 第一次运行时 Windows 可能提示「Windows 已保护你的电脑」（没有数字签名）：点「更多信息」→「仍要运行」。
4. 第一次点「出发」进对局时要先准备 3D 画法，画面会停住几十秒到一两分钟，别关掉；以后就快了。旅人模式每一幕第一次进也一样。
5. 胜场和设置存在 %APPDATA%\ShanheLvren 里。
电脑要求：64 位 Windows 10 / 11；支持 Vulkan 的显卡（驱动更新到最新）；内存 8 GB 能跑、16 GB 更稳；硬盘约 1.5 GB。
TXT
xattr -cr "$TMP/LvXingLShu"
ZIP="$HOME/Desktop/旅行L叔-Windows-$STAMP.zip"
( cd "$TMP" && ditto -c -k --norsrc --noextattr --noqtn --keepParent LvXingLShu "$ZIP" )
echo "完成：$ZIP"
open -R "$ZIP"
