# 《旅行L叔》景德镇＋青花瓷素材包 v01

2026-10-01。首批独立原创素材，尚未接入正式游戏或地图编辑器。

## 文件

- `models/jingdezhen.glb`：窑坊城市群，含前大后小的半鸭蛋形窑、开放窑房、两间制瓷作坊、砖烟囱、三层晾坯架、匣钵、木柴与青花瓷陈列。
- `icons/qinghuaci.png`：1024×1024 RGBA 透明商品图标；另有 256、128 尺寸。
- `models/qinghuaci-icon-source.glb`：图标三维源，不是商品运行所需资源。
- `source/design.json`、`source/build_assets.py`：可编辑配色、造型和原创程序几何。仅用 Python 3 标准库，无安装依赖。
- `source/jingdezhen.tscn`、`source/qinghuaci-icon-source.tscn`：Godot 4.7.1 可编辑自包含场景。原点、Mesh、材质和命名部件可直接在独立 Godot 工程编辑。GLB 也可导入 Blender 再另存 `.blend`；本次未找到 Blender，没有交付或假称验证 `.blend`。
- `source/render_validate.gd`：独立测试工程渲染和导入验证脚本；默认输出 /tmp，可用 `-- --pack=/absolute/package` 指定本包。勿以主项目作为测试工程。
- `previews/`：城市三分之四、前侧、后侧实机渲染；青花瓷棋盘格透明检查图。
- `validation/`：GLB 几何统计、Godot 实际导入渲染报告、结构与文件哈希。

## 实际接入方式

只在本目录新增文件；未改主项目代码、配置、规则、现有模型或编辑器。本目录的 `.gdignore` 防止主项目自动扫描此素材包。将来接入时应复制所需运行素材到正式运行资产目录，保留本包为源资料。

城市加载方式核对自 `tools/merchant_board_claude_review.gd:1206`：`GLTFDocument.append_from_file` → `generate_scene`，保留所有 Mesh 与材质，按包围盒/建筑宽度归一到地图 `foot`，然后应用城市 yaw 和位置。不是棋子的 `first_mesh` 方式。本包 15 个命名 Mesh，不能作为棋子首 Mesh 替换。

城市 Y 向上，所有几何底部 Y=0，X/Z 包围盒中心为 0，无烘焙地图坐标；正面窑口与作坊立面朝 +Z。这是本包符合当前城市相机的前侧定义，**不是沿用旧载具的 −Z 约定**。宽 X=3.455、高 Y=1.644、深 Z=2.8225。当前实际城市由 loader 再缩放和旋转；不要求原始 GLB 固定宽 2.1。没有额外地形底板或水面，避免与编辑器地形重复。

如未来城市没有 `building_bounds` 记录，当前 loader 走完整 AABB fallback：缩放值 `foot / max(width, depth)`，水平中心和最低点自动校正。若需要记录建筑 bounds，本包测量：`building_centre_xz: [0,0]`、`building_width: 3.455`、`building_depth: 2.8225`。这里只说明，未写入主项目。

材质使用内嵌 glTF PBR `baseColorFactor`（sRGB 调色转线性）、`metallicFactor=0`、哑光屋瓦/木材与较低 roughness 的瓷器；无需外部贴图。保留中性白色 COLOR_0，并非依赖原项目专用顶点色 Shader。请保留 GLB 自带材质，不用棋子材质整体覆盖。

商品图标遵循现有 `scripts/lshu_ui/lshu_icons.gd` 入口：正式接入时可将 1024 PNG 命名为 `qinghuaci.png` 放在 `assets/game/ui/lshu_3d/icons/`。还须新增商品 ID、显示名、供应/交易规则及景德镇城市数据、路线/卡牌和产地绑定。不要只复制文件就宣称新增城市/商品可玩。

## 重建与验证

1. 在本包副本运行 `python3 source/build_assets.py`，重建两个 GLB。
2. 建一个独立临时 Godot 工程，设 Compatibility 渲染，运行 `Godot --path /tmp/isolated-project --script /absolute/package/source/render_validate.gd -- --pack=/absolute/package`。这是实际 GPU 渲染，不用 headless 证明美术。
3. 脚本保存可编辑场景、PNG 和导入报告。查看预览后再决定地图尺寸与位置。

本次验证为 Godot 4.7.1、Apple M1 Ultra、Compatibility。未运行主项目，未验证 Forward+ 正式游戏帧率、棋盘遮挡、城市 ID 或交易规则。

来源与许可见 `SOURCES-LICENSE.md`，其余四题材建议见 `EXPANSION-PLAN.md`。
