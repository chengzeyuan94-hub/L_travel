class_name TitleEffectCatalog

## TASK-006C-REV3：960×540 PXD 设计舞台参数与资产路径（唯一来源）。

const DESIGN_SIZE := Vector2(960, 540)
const SOURCE_ART_SIZE := Vector2(1672, 941)
const SCROLL_LIMIT_X := 860.0
const RNG_SEED := 20260721
## 开屏世界动态统一速度（UI Tween 不受影响）。
const WORLD_ANIMATION_SPEED := 1.5

const LAYER_DIR := "res://assets/title/layers"
const DIR := "res://assets/title_dynamic"
const PEOPLE_BOATS_DIR := "res://assets/title_dynamic/people_boats"

const SHEET_H_FRAMES := 4
const SHEET_FRAME_SIZE := Vector2(256, 256)
const ACTOR_FOOT_ANCHOR := Vector2(128, 242)
const ACTOR_FPS := 6.5
const SEAGULL_CLOSE_FPS := 10.0

const SEAGULL_CLOSE_FRAME_OFFSETS: Array[Vector2] = [
	Vector2(0, -52),
	Vector2(0, -2),
	Vector2(0, 28),
	Vector2(0, 2),
]

## EffectsLayer 内底→顶绘制顺序。
const DRAW_ORDER: Array[String] = [
	"OceanLayer",
	"LandLayer",
	"SpiceVendorRTLActor",
	"FlowerWomanRTLActor",
	"FarSailboatWake",
	"FarSailboat",
	"MidSailboatWake",
	"MidSailboat",
	"DockWorkerActor",
	"DocksLayer",
	"IslandsLayer",
	"SkyLayer",
	"CloseSeagull",
	"SailboatRipple",
	"ForegroundSailboat",
	"CumulusBand",
	"CargoBoatRipple",
	"ForegroundCargoBoat",
	"SmokePool",
	"ForegroundBranchV1",
	"WomanActor",
	"MerchantActor",
	"DriftingPetalPool",
	"RightParchmentPanel",
	"ForegroundBranchV2",
]

const STATIC_LAYER_REGIONS := {
	"background": Rect2(0, 0, 1672, 941),
	"ocean": Rect2(20, 24, 1626, 605),
	"land": Rect2(0, 159, 1566, 758),
	"docks": Rect2(203, 195, 1456, 746),
	"islands": Rect2(181, 69, 1395, 128),
	"sky": Rect2(0, 0, 1671, 89),
}

const STATIC_LAYER_RECTS := {
	"background": Rect2(0.0, 0.0, 986.0, 554.919856),
	"ocean": Rect2(-13.595041, 25.5, 876.158678, 326.0),
	"land": Rect2(0.0, 121.5, 796.428760, 385.5),
	"docks": Rect2(199.5, 303.186813, 646.5, 331.242445),
	"islands": Rect2(153.5, 57.5, 697.5, 64.0),
	"sky": Rect2(0.0, 0.0, 960.0, 51.131059),
}

const STATIC_LAYER_FILES := {
	"background": "title_background_clean_v2.png",
	"ocean": "layer_ocean_v1.png",
	"land": "layer_land_v1.png",
	"docks": "layer_docks_v1.png",
	"islands": "layer_islands_v1.png",
	"sky": "layer_sky_v1.png",
}

const ACTOR_ORDER: Array[String] = [
	"merchant",
	"flower_woman_rtl",
	"woman",
	"spice_vendor_rtl",
	"dock",
]

const ACTOR_CONFIGS := {
	"merchant": {
		"tex_id": "pedestrian_merchant_walk_6f_v3",
		"start": Vector2(232.798650, 410.5),
		"end": Vector2(324.947131, 410.5),
		"display_size": Vector2(46.074241, 46.074241),
		"duration": 12.5,
		"first_start": 0.8,
		"frame_count": 6,
		"frame_size": Vector2(256, 256),
		"fps": 5.0,
		"gait_fps": 5.0,
		"frame_sequence": [0, 1, 2, 3, 4, 5],
		"flip_h": false,
		"shadow_size": Vector2(20.0, 5.0),
		"shadow_offset": Vector2(0.0, -1.0),
		"node": "MerchantActor",
	},
	"flower_woman_rtl": {
		"tex_id": "pedestrian_flower_woman_walk_6f_v3",
		"start": Vector2(293.805310, 340.5),
		"end": Vector2(118.230088, 340.5),
		"display_size": Vector2(35.115044, 35.115044),
		"duration": 20.0,
		"first_start": 2.6,
		"frame_count": 6,
		"frame_size": Vector2(256, 256),
		"fps": 5.0,
		"gait_fps": 5.0,
		"frame_sequence": [0, 1, 2, 3, 4, 5],
		"flip_h": true,
		"shadow_size": Vector2(15.0, 4.0),
		"shadow_offset": Vector2(0.0, -0.8),
		"node": "FlowerWomanRTLActor",
	},
	"woman": {
		"tex_id": "pedestrian_basket_woman_walk_6f_v3",
		"start": Vector2(362.157627, 357.0),
		"end": Vector2(434.763277, 357.0),
		"display_size": Vector2(36.302825, 36.302825),
		"duration": 13.0,
		"first_start": 4.4,
		"frame_count": 6,
		"frame_size": Vector2(256, 256),
		"fps": 5.0,
		"gait_fps": 5.0,
		"frame_sequence": [0, 1, 2, 3, 4, 5],
		"flip_h": false,
		"shadow_size": Vector2(15.0, 4.0),
		"shadow_offset": Vector2(0.0, -0.8),
		"node": "WomanActor",
	},
	"spice_vendor_rtl": {
		"tex_id": "pedestrian_spice_vendor_walk_6f_v3",
		"start": Vector2(436.201578, 377.0),
		"end": Vector2(231.438307, 377.0),
		"display_size": Vector2(40.952654, 40.952654),
		"duration": 23.0,
		"first_start": 6.4,
		"frame_count": 6,
		"frame_size": Vector2(256, 256),
		"fps": 5.0,
		"gait_fps": 5.0,
		"frame_sequence": [0, 1, 2, 3, 4, 5],
		"flip_h": true,
		"shadow_size": Vector2(18.0, 4.5),
		"shadow_offset": Vector2(0.0, -0.9),
		"node": "SpiceVendorRTLActor",
	},
	"dock": {
		"tex_id": "pedestrian_dock_worker_walk_6f_v3",
		"start": Vector2(448.047126, 332.5),
		"end": Vector2(532.203448, 332.5),
		"display_size": Vector2(42.078161, 42.078161),
		"duration": 14.0,
		"first_start": 8.5,
		"frame_count": 6,
		"frame_size": Vector2(256, 256),
		"fps": 5.0,
		"gait_fps": 5.0,
		"frame_sequence": [0, 1, 2, 3, 4, 5],
		"flip_h": false,
		"shadow_size": Vector2(18.0, 4.5),
		"shadow_offset": Vector2(0.0, -0.9),
		"node": "DockWorkerActor",
	},
}

## 程序化地面阴影（共享纹理参数）。
const ACTOR_SHADOW_CENTER_COLOR := Color(0.12, 0.09, 0.06, 0.34)
const ACTOR_SHADOW_EDGE_COLOR := Color(0.12, 0.09, 0.06, 0.0)
const ACTOR_SHADOW_TEX_SIZE := Vector2i(64, 32)

const ACTOR_MAX_VISIBLE := 4
const ACTOR_MIN_START_GAP := 1.6
const ACTOR_LOOP_GAP_MIN := 2.4
const ACTOR_LOOP_GAP_MAX := 4.0
const ACTOR_RECOVERY_GAP_MIN := 0.8
const ACTOR_RECOVERY_GAP_MAX := 1.4
const ACTOR_CROWD_TARGET_MIN := 2
const ACTOR_CROWD_TARGET_MAX := 4
const ACTOR_FADE := 0.08

const SEAGULL_CONFIG := {
	# 近景海鸥只作为视线引导，不与主商船、城楼争夺焦点。
	"start": Vector2(42.0, 151.0),
	"end": Vector2(505.0, 143.0),
	"display_size": Vector2(54.0, 54.0),
	"duration_min": 3.8,
	"duration_max": 4.4,
	"first_delay_min": 2.5,
	"first_delay_max": 3.5,
	"cooldown_min": 10.0,
	"cooldown_max": 14.0,
}

const RIPPLE_ATLAS := {
	"path": "res://assets/title_dynamic/title_water_ripple_v1.png",
	"atlas_region": Rect2(248, 281, 1298, 321),
}

const BOAT_CONFIGS := {
	"cargo": {
		"tex_id": "small_cargo_boat_near",
		"atlas_region": Rect2(153, 162, 717, 444),
		"rect": Rect2(511.033784, 436.0, 104.966216, 65.0),
		"center": Vector2(563.516892, 468.5),
		"bob_px": 1.5,
		"rot_deg": 0.25,
		"period_min": 3.8,
		"period_max": 4.6,
		"node": "ForegroundCargoBoat",
		"ripple_node": "CargoBoatRipple",
		"ripple_rect": Rect2(523.5, 473.5, 80.0, 19.8),
		"ripple_phase": 1.7,
		"ripple_scale_x_min": 0.96,
		"ripple_scale_x_max": 1.05,
		"ripple_scale_y_min": 0.94,
		"ripple_scale_y_max": 1.04,
		"ripple_alpha_min": 0.22,
		"ripple_alpha_max": 0.42,
	},
	"sail": {
		"tex_id": "foreground_sailboat_v2",
		"atlas_region": Rect2(12, 0, 1511, 1023),
		"rect": Rect2(523.0, 332.5, 240.017107, 162.5),
		"center": Vector2(643.008553, 413.75),
		"bob_px": 2.0,
		"rot_deg": 0.20,
		"period_min": 4.8,
		"period_max": 5.8,
		"node": "ForegroundSailboat",
		"ripple_node": "SailboatRipple",
		"ripple_rect": Rect2(523.0, 452.5, 240.0, 59.3),
		"ripple_phase": 0.0,
		"ripple_scale_x_min": 0.95,
		"ripple_scale_x_max": 1.08,
		"ripple_scale_y_min": 0.92,
		"ripple_scale_y_max": 1.05,
		"ripple_alpha_min": 0.18,
		"ripple_alpha_max": 0.38,
	},
}

const CLOUD_CONFIG := {
	"atlas_region": Rect2(34, 271, 1974, 166),
	"rect": Rect2(26.0, -0.207194, 656.5, 55.207194),
	"drift_px": 2.0,
	"period_min": 45.0,
	"period_max": 60.0,
}

## 花枝：双频风摆（根部锚点固定）。
const BRANCH_CONFIGS := {
	"branch_r": {
		"path": "res://assets/title_dynamic/title_foreground_branch_v2.png",
		"atlas_region": Rect2(252, 0, 1196, 944),
		"rect": Rect2(692.0, 56.891304, 279.5, 220.608696),
		"base_angle": 0.0,
		"pivot": Vector2(971.5, 56.891304),
		"main_swing_deg": 1.40,
		"secondary_swing_deg": 0.30,
		"main_period": 5.8,
		"secondary_period": 2.9,
		"phase": 0.0,
		"node": "ForegroundBranchV2",
	},
	"branch_l": {
		"path": "res://assets/title_dynamic/title_foreground_branch_v1.png",
		"atlas_region": Rect2(0, 169, 1038, 693),
		"rect": Rect2(-15.701267, 385.507136, 226.142775, 150.979714),
		"base_angle": -10.144910,
		"pivot": Vector2(-15.701267, 536.486850),
		"main_swing_deg": 1.70,
		"secondary_swing_deg": 0.40,
		"main_period": 6.4,
		"secondary_period": 3.2,
		"phase": PI,
		"node": "ForegroundBranchV1",
	},
}

## 右上落花：固定池 + 三区起点 + 三通道路径。
const DRIFT_SPAWN_ZONES := {
	"upper_tip": {"center": Vector2(811.5, 117.5), "jitter": Vector2(28, 18)},
	"mid_bloom": {"center": Vector2(766.5, 162.5), "jitter": Vector2(32, 20)},
	"lower_tip": {"center": Vector2(731.5, 212.5), "jitter": Vector2(28, 22)},
}

const DRIFT_SPAWN_ZONE_ORDER: Array[String] = ["upper_tip", "mid_bloom", "lower_tip"]

const DRIFT_LANES := {
	"upper": {
		"end_x_min": 570.0,
		"end_x_max": 640.0,
		"end_y_min": 260.0,
		"end_y_max": 310.0,
		"duration_min": 6.5,
		"duration_max": 9.0,
		"sway_min": 4.0,
		"sway_max": 9.0,
		"c1_x_min": -80.0,
		"c1_x_max": -35.0,
		"c1_y_min": 5.0,
		"c1_y_max": 40.0,
		"c2_x_min": 20.0,
		"c2_x_max": 65.0,
		"c2_y_min": -35.0,
		"c2_y_max": 5.0,
	},
	"middle": {
		"end_x_min": 510.0,
		"end_x_max": 590.0,
		"end_y_min": 305.0,
		"end_y_max": 355.0,
		"duration_min": 8.5,
		"duration_max": 12.0,
		"sway_min": 7.0,
		"sway_max": 14.0,
		"c1_x_min": -115.0,
		"c1_x_max": -55.0,
		"c1_y_min": 25.0,
		"c1_y_max": 75.0,
		"c2_x_min": 25.0,
		"c2_x_max": 85.0,
		"c2_y_min": -50.0,
		"c2_y_max": 15.0,
	},
	"lower": {
		"end_x_min": 445.0,
		"end_x_max": 540.0,
		"end_y_min": 345.0,
		"end_y_max": 395.0,
		"duration_min": 11.0,
		"duration_max": 15.0,
		"sway_min": 10.0,
		"sway_max": 18.0,
		"c1_x_min": -145.0,
		"c1_x_max": -70.0,
		"c1_y_min": 45.0,
		"c1_y_max": 105.0,
		"c2_x_min": 30.0,
		"c2_x_max": 100.0,
		"c2_y_min": -65.0,
		"c2_y_max": 20.0,
	},
}

const DRIFT_LANE_ORDER: Array[String] = ["upper", "middle", "lower"]

const DRIFT_CONFIG := {
	"gust_count_min": 5,
	"gust_count_max": 9,
	"gust_gap_min": 0.90,
	"gust_gap_max": 2.20,
	"quiet_min": 2.5,
	"quiet_max": 5.0,
	"max_normal_visible": 8,
	"max_lane_active": 3,
	"min_spawn_sep": 28.0,
	"min_end_sep": 35.0,
	"spawn_retry": 5,
	"near_delay_min": 0.3,
	"near_delay_max": 0.6,
	"min_scale_gap": 0.08,
	"first_gust_delay": 2.0,
	"cluster_chance": 0.35,
	"bob_amp_min": 2.0,
	"bob_amp_max": 8.0,
	"bob_cycles_min": 1.2,
	"bob_cycles_max": 2.8,
	"fade_start_min": 0.58,
	"fade_start_max": 0.78,
}

const DRIFT_POOL := {
	"petal": {
		"path": "res://assets/title_dynamic/title_petal_v1.png",
		"atlas_region": Rect2(374, 333, 485, 572),
		"display_size": Vector2(30.228229, 35.650612),
		"base_angle": 51.420449,
		"count": 8,
		"scale_min": 0.48,
		"scale_max": 1.00,
		"spin_min": 180.0,
		"spin_max": 420.0,
		"flip_min": 1,
		"flip_max": 4,
		"alpha_peak": 1.0,
	},
	"leaf": {
		"path": "res://assets/title_dynamic/title_leaf_v1.png",
		"atlas_region": Rect2(414, 410, 424, 429),
		"display_size": Vector2(26.077594, 26.385113),
		"base_angle": 101.318002,
		"count": 4,
		"scale_min": 0.52,
		"scale_max": 1.05,
		"spin_min": 240.0,
		"spin_max": 540.0,
		"flip_min": 1,
		"flip_max": 4,
		"alpha_peak": 1.0,
	},
	"leaf_spin": {
		"path": "res://assets/title_dynamic/title_leaf_spin_v2.png",
		"atlas_region": Rect2(511, 350, 226, 523),
		"display_size": Vector2(19.013384, 44.0),
		"base_angle": 0.0,
		"count": 3,
		"scale_min": 0.45,
		"scale_max": 0.92,
		"spin_min": 240.0,
		"spin_max": 540.0,
		"flip_min": 1,
		"flip_max": 4,
		"alpha_peak": 1.0,
	},
	"petal_cluster": {
		"path": "res://assets/title_dynamic/title_petal_cluster_v2.png",
		"atlas_region": Rect2(243, 167, 801, 870),
		"display_size": Vector2(107.705833, 116.983864),
		"base_angle": -57.517626,
		"count": 1,
		"scale_min": 0.42,
		"scale_max": 0.62,
		"spin_min": -6.0,
		"spin_max": 6.0,
		"flip_min": 0,
		"flip_max": 0,
		"alpha_peak": 0.48,
		"cooldown_min": 20.0,
		"cooldown_max": 30.0,
	},
}

const DRIFT_FLIP_SCALE_MIN := 0.08
const DRIFT_POOL_TOTAL := 16

## 炊烟：每烟囱 A/B 两节点，底部向上揭示。
const SMOKE_SHADER_PATH := "res://assets/title_dynamic/smoke_bottom_up_reveal.gdshader"

const SMOKE_CONFIGS := {
	"smoke_m": {
		"path": "res://assets/title_dynamic/title_smoke_puff_v1.png",
		"atlas_region": Rect2(283, 346, 334, 973),
		"rect": Rect2(406.478417, 251.5, 18.021583, 52.5),
		"nodes": ["SmokePuffV1_A", "SmokePuffV1_B"],
		"cycle_min": 2.4,
		"cycle_max": 3.0,
		"rise_min": 16.0,
		"rise_max": 24.0,
		"sway_px": 1.5,
		"scale_min": 0.92,
		"scale_max": 1.10,
		"alpha_peak": 0.50,
	},
	"smoke_l": {
		"path": "res://assets/title_dynamic/title_smoke_puff_v2.png",
		"atlas_region": Rect2(319, 423, 258, 843),
		"rect": Rect2(198.5, 364.0, 14.231317, 46.5),
		"nodes": ["SmokePuffV2_A", "SmokePuffV2_B"],
		"cycle_min": 2.6,
		"cycle_max": 3.2,
		"rise_min": 14.0,
		"rise_max": 20.0,
		"sway_px": 1.5,
		"scale_min": 0.94,
		"scale_max": 1.09,
		"alpha_peak": 0.52,
	},
}

## 远景/中景动态船（不改动前景两船）。仅保留轻微航迹。
const DISTANT_BOAT_WAKE_ATLAS := {
	"path": "res://assets/title_dynamic/people_boats/title_small_boat_wake_v1.png",
	"atlas_region": Rect2(300, 155, 353, 75),
}

const DISTANT_BOAT_ORDER: Array[String] = ["far_sailboat", "mid_sailboat"]

const DISTANT_BOAT_CONFIGS := {
	"mid_sailboat": {
		"tex_id": "sailboat_mid",
		"atlas_region": Rect2(205, 26, 613, 460),
		"rect": Rect2(443.0, 134.0, 77.957609, 58.5),
		"stern_anchor_uv": Vector2(0.0538336, 0.7369565),
		"bow_anchor_uv": Vector2(0.9624796, 0.8130435),
		"start": Vector2(480.0, 145.0),
		"end": Vector2(660.0, 145.0),
		"control_1": Vector2(530.0, 145.0),
		"control_2": Vector2(610.0, 145.0),
		"duration_min": 48.0,
		"duration_max": 56.0,
		"first_delay": 1.5,
		"cooldown_min": 14.0,
		"cooldown_max": 22.0,
		"bob_px": 0.70,
		"bob_period_min": 5.2,
		"bob_period_max": 6.2,
		"rotation_sway": 0.15,
		"wake_node": "MidSailboatWake",
		"boat_node": "MidSailboat",
		"wake_size": Vector2(40.0, 7.0),
		"wake_alpha": 0.42,
	},
	"far_sailboat": {
		"tex_id": "sailboat_far",
		"atlas_region": Rect2(179, 25, 410, 334),
		"rect": Rect2(538.610560, 101.667787, 49.665885, 40.459526),
		"stern_anchor_uv": Vector2(0.0121951, 0.7305389),
		"bow_anchor_uv": Vector2(0.9902439, 0.6586826),
		"start": Vector2(500.0, 124.0),
		"end": Vector2(650.0, 115.0),
		"control_1": Vector2(548.0, 121.1),
		"control_2": Vector2(608.0, 117.5),
		"duration_min": 60.0,
		"duration_max": 72.0,
		"first_delay": 8.0,
		"cooldown_min": 18.0,
		"cooldown_max": 28.0,
		"bob_px": 0.45,
		"bob_period_min": 6.0,
		"bob_period_max": 7.5,
		"rotation_sway": 0.10,
		"wake_node": "FarSailboatWake",
		"boat_node": "FarSailboat",
		"wake_size": Vector2(28.0, 5.0),
		"wake_alpha": 0.34,
	},
}

## 开屏 UI（960×540 PXD；资产带透明边，用 Atlas 裁切）。
const TITLE_UI_DIR := "res://assets/title_ui"
const TITLE_UI_ATLASES := {
	"parchment": {
		"path": "res://assets/title_ui/ui_right_parchment_panel_v1.png",
		"region": Rect2(209, 181, 606, 1685),
	},
	"hanging_scroll": {
		"path": "res://assets/title_ui/ui_hanging_scroll_title_hd_v1.png",
		"region": Rect2(240, 229, 543, 1590),
	},
	"start_normal": {
		"path": "res://assets/title_ui/ui_button_start_normal_v1.png",
		"region": Rect2(214, 25, 595, 270),
	},
	"start_hover": {
		"path": "res://assets/title_ui/ui_button_start_hover_v1.png",
		"region": Rect2(214, 25, 595, 270),
	},
	"start_pressed": {
		"path": "res://assets/title_ui/ui_button_start_pressed_v1.png",
		"region": Rect2(214, 31, 595, 270),
	},
	"exit_normal": {
		"path": "res://assets/title_ui/ui_button_exit_normal_v1.png",
		"region": Rect2(213, 25, 598, 270),
	},
	"exit_hover": {
		"path": "res://assets/title_ui/ui_button_exit_hover_v1.png",
		"region": Rect2(213, 25, 598, 270),
	},
	"exit_pressed": {
		"path": "res://assets/title_ui/ui_button_exit_pressed_v1.png",
		"region": Rect2(213, 31, 598, 270),
	},
	"slogan": {
		"path": "res://assets/title_ui/ui_slogan_hailu_xiangfeng_v1.png",
		"region": Rect2(442, 163, 139, 73),
	},
	"seal": {
		"path": "res://assets/title_ui/ui_focus_seal_v1.png",
		"region": Rect2(67, 61, 377, 390),
	},
}

const TITLE_UI_RECTS := {
	"parchment": Rect2(837.58, -4.59, 195.86, 544.59),
	"hanging_scroll": Rect2(858.65, 53.00, 98.35, 288.00),
	"slogan": Rect2(884.50, 248.00, 47.50, 25.00),
	"seal": Rect2(897.00, 292.76, 21.50, 22.24),
	"start_button": Rect2(810.92, 377.00, 142.14, 64.50),
	"exit_button": Rect2(812.50, 456.55, 140.54, 63.45),
	# 版本号位于退出按钮下方：留出完整 8px 字号基线，且不与按钮重叠。
	"version": Rect2(850.0, 522.0, 98.0, 14.0),
}

const PEOPLE_BOAT_FILES := {
	"pedestrian_merchant": "title_pedestrian_merchant_walk_v1.png",
	"pedestrian_woman": "title_pedestrian_woman_walk_v1.png",
	"pedestrian_dock_worker": "title_pedestrian_dock_worker_walk_v1.png",
	"pedestrian_woman_walk_6f_v2": "title_pedestrian_woman_walk_6f_v2.png",
	"pedestrian_spice_vendor_walk_6f_v2": "title_pedestrian_spice_vendor_walk_6f_v2.png",
	"pedestrian_merchant_walk_6f_v3": "title_pedestrian_merchant_walk_6f_v3.png",
	"pedestrian_basket_woman_walk_6f_v3": "title_pedestrian_basket_woman_walk_6f_v3.png",
	"pedestrian_dock_worker_walk_6f_v3": "title_pedestrian_dock_worker_walk_6f_v3.png",
	"pedestrian_flower_woman_walk_6f_v3": "title_pedestrian_flower_woman_walk_6f_v3.png",
	"pedestrian_spice_vendor_walk_6f_v3": "title_pedestrian_spice_vendor_walk_6f_v3.png",
	"seagull_close_sheet": "title_seagull_close_flight_sheet_v1.png",
	"small_cargo_boat_near": "title_small_cargo_boat_near_v1.png",
	"foreground_sailboat_v2": "title_foreground_sailboat_v2.png",
	"sailboat_mid": "title_sailboat_mid_v1.png",
	"sailboat_far": "title_sailboat_far_v1.png",
	"small_sailboat_near": "title_small_sailboat_near_v1.png",
	"small_boat_wake": "title_small_boat_wake_v1.png",
}

const CUMULUS_PATH := "res://assets/title_dynamic/title_cumulus_band_v1.png"

static var _cache: Dictionary = {}
static var _sheet_cache: Dictionary = {}
static var _atlas_cache: Dictionary = {}


static func layer_path(id: String) -> String:
	return LAYER_DIR.path_join(STATIC_LAYER_FILES[id])


static func people_boat_path(id: String) -> String:
	return PEOPLE_BOATS_DIR.path_join(PEOPLE_BOAT_FILES[id])


static func texture(path: String) -> Texture2D:
	if _cache.has(path):
		return _cache[path]
	var tex: Texture2D = load(path)
	assert(tex != null, "TitleEffectCatalog: failed to load %s" % path)
	_cache[path] = tex
	return tex


static func layer_texture(id: String) -> Texture2D:
	return texture(layer_path(id))


static func people_boat_texture(id: String) -> Texture2D:
	return texture(people_boat_path(id))


static func cumulus_texture() -> Texture2D:
	return texture(CUMULUS_PATH)


static func make_atlas(base: Texture2D, region: Rect2, filter_clip: bool = false) -> AtlasTexture:
	var key := "%s|%s|%s" % [base.resource_path, str(region), str(filter_clip)]
	if _atlas_cache.has(key):
		return _atlas_cache[key]
	var atlas := AtlasTexture.new()
	atlas.atlas = base
	atlas.region = region
	atlas.filter_clip = filter_clip
	_atlas_cache[key] = atlas
	return atlas


static func ui_atlas(id: String) -> AtlasTexture:
	var cfg: Dictionary = TITLE_UI_ATLASES[id]
	return make_atlas(texture(String(cfg["path"])), cfg["region"] as Rect2, true)


static func layer_atlas(id: String) -> AtlasTexture:
	return make_atlas(layer_texture(id), STATIC_LAYER_REGIONS[id])


static func sheet_frames(
	tex_id: String,
	frame_count: int = SHEET_H_FRAMES,
	frame_size: Vector2 = SHEET_FRAME_SIZE
) -> Array:
	var cache_key := "%s|%d|%s" % [tex_id, frame_count, str(frame_size)]
	if _sheet_cache.has(cache_key):
		return _sheet_cache[cache_key]
	var sheet: Texture2D = people_boat_texture(tex_id)
	var frames: Array = []
	for i in frame_count:
		var atlas := AtlasTexture.new()
		atlas.atlas = sheet
		atlas.region = Rect2(float(i) * frame_size.x, 0.0, frame_size.x, frame_size.y)
		frames.append(atlas)
	_sheet_cache[cache_key] = frames
	return frames


static func boat_atlas(boat_key: String) -> AtlasTexture:
	var cfg: Dictionary = BOAT_CONFIGS[boat_key]
	return make_atlas(people_boat_texture(String(cfg["tex_id"])), cfg["atlas_region"])


static func distant_boat_atlas(key: String) -> AtlasTexture:
	var cfg: Dictionary = DISTANT_BOAT_CONFIGS[key]
	return make_atlas(people_boat_texture(String(cfg["tex_id"])), cfg["atlas_region"] as Rect2, true)


static func distant_wake_atlas() -> AtlasTexture:
	return make_atlas(texture(DISTANT_BOAT_WAKE_ATLAS["path"]), DISTANT_BOAT_WAKE_ATLAS["atlas_region"])


static func cloud_atlas() -> AtlasTexture:
	return make_atlas(cumulus_texture(), CLOUD_CONFIG["atlas_region"])


static func ripple_atlas() -> AtlasTexture:
	return make_atlas(texture(RIPPLE_ATLAS["path"]), RIPPLE_ATLAS["atlas_region"])


static func branch_atlas(key: String) -> AtlasTexture:
	var cfg: Dictionary = BRANCH_CONFIGS[key]
	return make_atlas(texture(String(cfg["path"])), cfg["atlas_region"])


static func drift_atlas(kind: String) -> AtlasTexture:
	var cfg: Dictionary = DRIFT_POOL[kind]
	return make_atlas(texture(String(cfg["path"])), cfg["atlas_region"])


static func smoke_atlas(key: String) -> AtlasTexture:
	var cfg: Dictionary = SMOKE_CONFIGS[key]
	return make_atlas(texture(String(cfg["path"])), cfg["atlas_region"])


static func people_boat_ids() -> Array[String]:
	var ids: Array[String] = []
	for k in PEOPLE_BOAT_FILES.keys():
		ids.append(String(k))
	return ids
