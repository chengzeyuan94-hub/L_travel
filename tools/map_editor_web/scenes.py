# -*- coding: utf-8 -*-
"""场景描述表 —— 编辑器唯一的"哪些键可以改"来源。

页面和保存逻辑都读这一份，避免两边各写一套导致写回错键。
新增一景只需在 SCENES 里加一条，页面和服务端都不用改。

字段含义：
  path        进入 JSON 的路径（顶层键开始）
  kind        list   = 该路径是一个对象数组
              single = 该路径本身就是一个对象
              ridges = 椭圆起伏块（center[x,z] / radius[rx,rz] / height_u / angle_deg）
  id_key      用哪个键匹配条目；None 表示按数组下标匹配
  pos_key     位置键名（三元组）。**各景不同**：盘橐用 stage_position，巴格达道具用 position
  yaw_key     朝向键名（角度）
  size_key    尺寸键名；gizmo 缩放写回到这个键
  size_axis   size_key 量的是资产包围盒的哪个轴（x/y/z），用来反解缩放
  asset_key   每条目自带资产路径的键名
  asset_fixed 整类共用一个资产路径
  locked      这些键只读，不写回（例如已定版的角色身高）
"""

BAGHDAD = {
    "title": "巴格达旅人",
    "file": "data/traveler/baghdad_scene.json",
    "safe_copy": "data/traveler/baghdad_scene.edited.json",
    # 实机渲染：每次从 Codex 当前的 viewer 脚本重新克隆一份，只把数据路径换成副本。
    # 这样他的文件零写入，而且不会因为他改了 viewer 而漂移。
    "viewer_script": "scripts/traveler/baghdad/baghdad_viewer.gd",
    "data_res_path": "res://data/traveler/baghdad_scene.json",
    "safe_res_path": "res://data/traveler/baghdad_scene.edited.json",
    "capture_flags": [
        {"label": "夕阳（cinematic）", "args": ["--cinematic-sunset"]},
        {"label": "默认时段", "args": []},
        {"label": "棚拍（studio）", "args": ["--studio"]},
    ],
    # 相机：巴格达用 camera.position / camera.look_at（不是盘橐的 camera_composition）
    "camera": {"path": ["camera"], "pos_key": "position", "look_key": "look_at",
               "fov_key": "fov_vertical_deg"},
    # 「Stage X screen-right / Y up / Z away from camera」——与盘橐同一套屏幕映射
    "stage_note": "Stage X 屏幕右 / Y 上 / Z 远离相机",
    "groups": [
        {"key": "arch", "label": "拱门", "path": ["arch"], "kind": "single",
         "pos_key": "stage_position", "yaw_key": "yaw_deg",
         "size_key": "opening_height_u", "size_axis": "y",
         "asset_from": ["assets", "arch"],
         "note": "opening_height_u 是券洞净高，不是包围盒高（source_opening_height_u 记着源尺寸）"},

        {"key": "tree", "label": "生命树", "path": ["tree"], "kind": "single",
         "pos_key": "stage_position", "yaw_key": "yaw_deg",
         "size_key": "height_u", "size_axis": "y",
         "asset_from": ["assets", "tree"]},

        {"key": "skyline", "label": "远景城", "path": ["skyline", "instances"], "kind": "list",
         "id_key": "id", "pos_key": "stage_position", "yaw_key": "yaw_deg",
         "size_key": "height_scale", "size_axis": "scale",
         "asset_from": ["assets", "mosque"]},

        {"key": "mountains", "label": "远山", "path": ["mountains", "layers"], "kind": "list",
         "id_key": "id", "pos_key": "stage_position", "yaw_key": "yaw_deg",
         "size_key": "height_u", "size_axis": "y", "asset_key": "asset"},

        {"key": "rocks", "label": "石头", "path": ["supporting_props", "rocks"], "kind": "list",
         "id_key": "id", "pos_key": "position", "yaw_key": "yaw_deg",
         "size_key": "width_u", "size_axis": "x", "asset_key": "asset"},

        {"key": "palms", "label": "棕榈", "path": ["supporting_props", "palms"], "kind": "list",
         "id_key": "id", "pos_key": "position", "yaw_key": "yaw_deg",
         "size_key": "height_u", "size_axis": "y", "asset_key": "asset"},

        {"key": "tufts", "label": "草丛", "path": ["supporting_props", "tufts"], "kind": "list",
         "id_key": None, "pos_key": "position", "yaw_key": "yaw_deg",
         "size_key": "height_u", "size_axis": "y"},

        {"key": "plants", "label": "地面物件", "path": ["supporting_props", "plants"], "kind": "list",
         "id_key": "id", "pos_key": "position", "yaw_key": "yaw_deg",
         "size_key": "width_u", "size_axis": "x", "asset_key": "asset"},

        {"key": "fire", "label": "营火", "path": ["supporting_props", "fire"], "kind": "single",
         "pos_key": "position", "yaw_key": "yaw_deg",
         "size_key": "height_u", "size_axis": "y"},

        {"key": "character", "label": "L 叔", "path": ["character"], "kind": "single",
         "pos_key": "stage_position", "yaw_key": "yaw_deg",
         "locked": ["height_u"],
         "note": "height_u 0.6375 已定版，编辑器不写回"},

        {"key": "ridges", "label": "沙丘块", "path": ["ground", "relief", "ridges"],
         "kind": "ridges", "id_key": None},
    ],
}

PANTI = {
    "title": "盘橐旅人",
    "file": "data/traveler/panti_scene.json",
    "safe_copy": "data/traveler/panti_scene.edited.json",
    "viewer_script": "scripts/traveler/panti/panti_viewer.gd",
    "data_res_path": "res://data/traveler/panti_scene.json",
    "safe_res_path": "res://data/traveler/panti_scene.edited.json",
    "capture_flags": [
        {"label": "清晨", "args": ["--morning"]},
        {"label": "深夜", "args": ["--midnight"]},
    ],
    "camera": {"path": ["camera_composition"], "pos_key": "position_stage",
               "look_key": "look_at_stage", "fov_key": "fov_vertical_deg"},
    "stage_note": "Stage X 屏幕右 / Y 上 / Z 远离相机",
    "groups": [
        {"key": "fortress", "label": "城堡", "path": ["fortress"], "kind": "single",
         "pos_key": "stage_position", "yaw_key": "yaw_relative_camera_deg",
         "size_key": "height_u", "size_axis": "y", "asset_key": "asset"},

        {"key": "trees", "label": "雪松", "path": ["trees", "instances"], "kind": "list",
         "id_key": "id", "pos_key": "stage_position", "yaw_key": "yaw_deg",
         "size_key": "height_u", "size_axis": "y",
         "asset_from": ["trees", "asset"],
         "extra_keys": ["crown_diameter_u"]},

        {"key": "rocks", "label": "石头", "path": ["rocks", "instances"], "kind": "list",
         "id_key": "id", "pos_key": "stage_position", "yaw_key": "yaw_deg",
         "size_key": "height_u", "size_axis": "y"},

        {"key": "camp", "label": "营地", "path": ["camp", "props"], "kind": "list",
         "id_key": "id", "pos_key": "offset_stage", "yaw_key": "yaw_deg",
         "size_key": "size_u", "size_axis": "y", "asset_key": "asset",
         "origin_from": ["camp", "root_stage"],
         "note": "营地道具存的是相对 camp.root_stage 的偏移"},

        {"key": "character", "label": "L 叔", "path": ["character"], "kind": "single",
         "pos_key": "stage_position", "yaw_key": "yaw_deg", "locked": ["height_u"]},

        {"key": "ridges", "label": "雪坡块", "path": ["ground", "relief", "ridges"],
         "kind": "ridges", "id_key": None},
    ],
}

SCENES = {"baghdad": BAGHDAD, "panti": PANTI}
DEFAULT_VIEW = "baghdad"
