# tools/traveler

《山海之旅》旅人模式的工具与参考实现。

## `subviewport_capture_reference.gd` —— 固定分辨率取图的参考实现

**为什么需要它**：2026-09-18 发现，传 `--resolution 1920x1080` 并不能得到 1920×1080 的画面。
这台机器的屏幕正好是 1920×1080，加上菜单栏与窗口边框，Godot 把窗口压到了约 **1499×937**；
而 `get_viewport().get_visible_rect().size` 报的是工程配置的 **1600×1000**。
三个数都不一样，于是那一批被我命名为 "1080p" 的证据图其实都不是 1080p，文件名已按真实像素更正。

**实测结论**（本机 Godot 4.7.1，Forward+）：把世界挂在一个 `size = Vector2i(1920, 1080)` 的 `SubViewport` 下，
即使窗口只有 640×400，`SubViewport.get_texture().get_image()` 仍然是**精确的 1920×1080**：

```
SUBVIEWPORT_PROBE {"requested":[1920,1080],"subviewport_size":[1920,1080],
                   "image_size":[1920,1080],"window_size":[640,400],
                   "root_viewport":[640.0,400.0],"save_error":0,"renderer":"forward_plus"}
```

**规则**：凡是要拿来度量或并排对比的渲染，一律走这条路径，不要用窗口/主 viewport 取图。
每张图旁边的 JSON 必须同时记 `image_size`（从保存的 `Image` 读）与 `viewport_size`，
不一致时**以 `image_size` 为准**——否则分辨率会静默取决于当时的显示器，不同轮次的数字无法互相比较。

要点（见脚本）：
- `render_target_update_mode = SubViewport.UPDATE_ALWAYS`
- 取图前 `await RenderingServer.frame_post_draw` 至少两次，中间夹一个 `process_frame`，否则可能取到空帧
- 相机要 `make_current()`，且必须是 SubViewport 的子节点

## Atlas 合并与再生链

授权源在 `art-src/cities-enhanced/`（16 城），海陆与尺度源在 `art-src/world-reference/`。
原再生链为 `build_world.py` → `export_tiles.py` → `prepare_assets.py` → Godot `--headless --import` → `build_atlas_scene.gd`。
**已知缺口**：前三步的完整上游仍在仓库外的 `~/Desktop/Eurasia-Atlas-WebGL.zip`（118,611,361 B）；`*.zip` 被忽略。仅 clone 仓库还不能从零生成这 89 个 GLB。
本单不搬 `assets/tiles/` 与 `assets/terrain/world.glb`。运行资产落在 `generated/traveler/atlas/assets/{terrain,cities,prototypes}/`，共 89 个 GLB。
恢复这些中间 GLB 可从该 zip 的 `Eurasia-Atlas/assets/` 按以上白名单解包；随后重新 import，不能复用旧导入缓存。

构建命令（在工程根目录执行）：

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --import
/Applications/Godot.app/Contents/MacOS/Godot --path . --script res://tools/traveler/build_atlas_scene.gd
```

**构建脚本禁止 `--headless`，必须真窗口及真实 GPU；禁止照搬旧的 559 个 `.res` 与 `atlas_world.tscn`。**
生成物位于 `generated/traveler/atlas/{meshes,instances}/` 和 `generated/traveler/atlas/atlas_world.tscn`；
该目录禁止放 `.gdignore`，也不能换成带 `.gdignore` 的 `artifacts/`。报告写入 `docs/reports/traveler-merge-atlas/godot-build.json`。
删除全部 `generated/` 后必须先恢复 89 个 GLB 并 import，再运行构建脚本；只删除 `.res` 与场景时才能直接重建。
每次运行都须检查退出码 **及** ERROR / SCRIPT ERROR 行数。

## 入口与截图

调试版标题页按 **T** 进入旅人，旅人按 **Esc** 返回商旅标题。未添加正式标题按钮。
直接启动：`Godot --path . res://scenes/traveler/traveler_main.tscn`。
支持 `--capture/--view/--night/--routes/--hud/--no-trees`（放在 `--` 后）。
1920×1080 证据：

```sh
/Applications/Godot.app/Contents/MacOS/Godot --path . --script res://tools/traveler/capture_traveler.gd -- --capture=res://docs/reports/traveler-merge-atlas/traveler-1920x1080.png
```

`capture_traveler.gd` 使用固定 1920×1080 SubViewport；截图旁 JSON 记录实际 `image_size` 与 `viewport_size`，以 `image_size` 为准。
直接场景的 `--capture` 仍用于本机 1280×720 冒烟统计，不作为固定 1080p 证据。
`AudioManager` 会给旅人 UI 的 26 个 `BaseButton` 自动挂商旅音效；如需禁用，在 `atlas_viewer.build_ui()` 给按钮调用 `set_meta("silkroad_sfx_connected", true)` 预占即可。本次保留默认音效。
