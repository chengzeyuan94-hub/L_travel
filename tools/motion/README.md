# Motion toolkit — 「旅行L叔」动态影像

Render toolkit for the four 15 s 旅人模式 entrance films and the 60 s project film. Everything here runs offline on
this Mac (Godot 4.7.1, headless Chrome, ffmpeg 7.1, node 22, uv python with numpy / scipy / pillow). All numbers
below were measured on the M1 Ultra (20 cores) on 2026-09-27.

## 中文摘要

- **Godot 实拍**：`python3 tools/motion/godot/capture.py <shot.json> --out <目录>` —— 在真游戏里开四幕 / 开场插画 /
  3D 商旅棋盘，隐藏全部界面（返回药丸、提示、载入卡、商旅 HUD），等场景就绪、跑热身帧，按 shot 文件里的关键帧推镜头
  （或保持这一幕自己的机位），逐帧写出干净的 1920×1080 PNG + 同步的游戏原声 `audio.wav` + 清单 `capture.json`
  （机位、兴趣点坐标、耗时）。可以几条同时跑（每条占一个「槽」，小预览窗各在屏幕右上一个位置，互不遮挡）。
  15 秒一条单跑 20–35 秒，4 条并行约 76 秒全部拍完。
- **HTML 逐帧渲染**：`node tools/motion/html/render.mjs <页面.html> --out <目录> --frames 0:450 [--alpha] [--workers 6]`
  —— 页面提供 `renderFrame(i, fps)`，不依赖真实时间；支持 Canvas2D / WebGL / SVG / CSS 动画（自动按帧定位）/ 中文字体
  （娃娃体、圆体等）/ 透明背景。6 个并行时约 65 帧/秒。
- **合成与成片**：`python3 tools/motion/comp/mc.py comp|grade|ramp|mix|loudnorm|measure|spectrum|master|ogv` ——
  叠层（透明叠加 / 滤色等混合）、调色（五个自带 LUT 风格 + eq / 色彩平衡 / 曲线）、颗粒、暗角、漏光、遮幅、变速、
  混音、两遍 EBU R128 响度标准化、H.264 + ProRes 母版、游戏内 `.ogv`（Theora + Vorbis）。
- **`.ogv` 已在 Godot 4.7.1 实测可播**：`load("res://…ogv")` 进 `VideoStreamPlayer`，画面走、有声（声音在命名总线
  `IntroVideo` 上，峰值 −0.7 dBFS）、15.45 秒时 `finished`；1080p / 8 Mbps 解码约占 0.19 个 CPU 核；15 秒 15.3 MB。
  视频自带声音可用，另出一份 `.ogg` 备用（也实测过）。
- **审片**：`contact_sheet.py`（每秒一帧 + 时间码拼图）、`stills.py`（按秒 / 帧取原尺寸静帧）。
- **声音**：`tools/motion/audio/synth.py`（numpy/scipy 合成：拨弦、钟、鼓、风、雨、呼啸、邮戳、纸声、混响……），
  响度用 `mc.py measure / loudnorm` 量和标准化，用 `mc.py spectrum` 出频谱图看。

---

## 0. Layout

```
tools/motion/
  README.md                 this file
  godot/
    capture.py              Godot capture driver (slots, retries, audio trim, manifest)       <- use this
    motion_capture.gd/.tscn the in-engine controller (plate SubViewport, readiness, camera, frame writer)
    shots/*.json            demo shots (one per target) + vantage surveys (see §2.6)
    ogv_test.gd/.tscn/.sh   proof that an intro .ogv plays in Godot, with CPU measurement
    tests/path_test.gd      headless test of the camera-path sampler
  html/
    render.mjs              deterministic HTML -> PNG renderer over the DevTools protocol     <- use this
    lib/fonts.css           the game's CJK faces as @font-face (Wawati SC, Yuanti SC, Kaiti, Xingkai, …)
    lib/motion.js           deterministic helpers (easing, envelopes, seeded rng, noise, image sequences)
    demo/demo_title.html    Canvas2D + WebGL + CSS/CJK text demo with transparent output
  comp/
    mc.py                   compositing / grading / retime / audio / encoding recipes (prints every ffmpeg call)
    make_luts.py            generates the built-in looks into comp/luts/*.cube (git-ignored, auto-built)
    leak.py                 procedural light leaks on black (screen-blend layer)
  review/
    contact_sheet.py        one frame per second, tiled, with timecodes
    stills.py               full-resolution stills at given seconds / frames
  audio/
    synth.py                synthesis kit + a demo cue
  docs/*.jpg                proof sheets referenced below
```

Scratch (never commit): `/private/tmp/claude-501/-Users-chengzeyuan-Developer-SilkRoad/881e8717-f317-4a7f-9cf5-81713e061c3a/scratchpad/motion/<your-area>/`.
Masters: `/Users/chengzeyuan/Desktop/旅行L叔-动态影像/`. Below, `$W` = the worktree
`/Users/chengzeyuan/Developer/SilkRoad/.claude/worktrees/night2-motion`, `$S` = the scratch `motion` dir.

Prerequisites already done in this worktree: `Godot --headless --import` (marker `$S/import_done`), and the
git-ignored Chang'an world `generated/traveler/atlas/` copied from the main checkout (without it
`traveler_main.tscn` cannot load: `Cannot open file 'res://generated/traveler/atlas/atlas_world.tscn'`).

## 1. Quick start (exact commands)

```bash
cd $W
# 1. a clean game plate: 3 s Chang'an push-in (frames + audio.wav + capture.json)
python3 tools/motion/godot/capture.py tools/motion/godot/shots/demo_changan_push.json --out $S/me/changan_push
# 2. an HTML layer with alpha
~/.local/bin/node tools/motion/html/render.mjs tools/motion/html/demo/demo_title.html --out $S/me/title --frames 0:90 --alpha --workers 4
# 3. put it together, grade, finish
python3 tools/motion/comp/mc.py comp  --base $S/me/changan_push --layer $S/me/title:over --out $S/me/comp
python3 tools/motion/comp/mc.py grade $S/me/comp --out $S/me/graded --lut lshu_dusk --grain 0.15 --vignette 0.35 --letterbox 2.39
python3 tools/motion/comp/mc.py loudnorm $S/me/changan_push/audio.wav --out $S/me/mix.wav --I -16 --TP -1
python3 tools/motion/comp/mc.py master $S/me/graded --audio $S/me/mix.wav --out "/Users/chengzeyuan/Desktop/旅行L叔-动态影像/test"
python3 tools/motion/comp/mc.py ogv    $S/me/graded --audio $S/me/mix.wav --out $S/me/intro          # Theora -q:v 8, BT.601
# 4. review
~/.local/bin/uv run -q --offline --with pillow python tools/motion/review/contact_sheet.py "/Users/chengzeyuan/Desktop/旅行L叔-动态影像/test.mp4"
```

## 2. Godot capture kit

### 2.1 How it works (and why)

Two facts found while building this, both measured:

1. **Movie Maker writes at the project's base size, 1280×720**, no matter what `--resolution` says (the project
   uses `canvas_items` stretch with a 1280×720 base). Changing that needs a different `project.godot`.
2. **macOS stops drawing a fully covered window, and Movie Maker then silently writes the last image again**
   (a test with two capture windows on this 1080p screen produced 70 identical frames after frame 21).

So `motion_capture.gd` loads the scene inside a **1920×1080 SubViewport "plate"** (own World3D, the root
viewport's render settings copied — MSAA, debanding, shadow atlas …; the game's UI base 1280×720 kept via
`size_2d_override` + stretch, so UI proportions match the game at 1080p). After each drawn frame
(`RenderingServer.frame_post_draw`) the plate is read back (≈15–23 ms) and PNG-encoded on WorkerThreadPool
threads. A frame that was never drawn is counted as a **stall** and fails the capture (`capture.py` retries once).
The real window is only a **320×180 always-on-top borderless preview** at a per-slot position (top-right of the
screen, right to left), so up to 5 captures run side by side without covering each other. Movie Maker still runs
(writing throw-away MJPEG) because it gives the fixed 1/fps timestep and records the game's own audio.
Verified: a plate frame and a root-viewport Movie Maker frame of the same Chang'an moment are visually identical.

Clean plate = the act started exactly as the title screen starts it (`--lshu-act=<id>` + the ACTS args from
`scripts/lshu_ui/lshu_progress.gd`), then its overlay (`act_exit_button.gd`: back pill, hint, loading card) hidden
and its 30-fps cap / vsync switched off. The board: the formal game in `--showcase` (4 AI players), recorded from
the board's own 3D SubViewport (no HUD, no 2D city plaques, the board's tilt-shift kept). The title home: the
`lshu_home_scene.gd` illustration with mouse parallax held at zero.

### 2.2 `capture.py`

```
python3 tools/motion/godot/capture.py SHOT.json --out DIR [--home DIR] [--slot auto|N] [--no-audio]
                                      [--retries 1] [--timeout 1800] [--keep-raw] [--debug-counter] [--sync-test]
```

Output in DIR: `frame_00000.png …` (exactly `duration × fps` frames, first clean frame = shot time 0),
`audio.wav` (48 kHz stereo, the game's audio for exactly those frames), `capture.json` (manifest: `act_camera`,
`poi`, `wall_s` timings, `stalls`, command line). `--home` defaults to `$S/home_capture_slot<N>` (Godot's HOME is
always a scratch dir, never the real save dir). Exit code 0 = OK. Stdlib only.

### 2.3 Shot file

```jsonc
{
  "target": "changan",            // changan | panti | baghdad | lshu | home | board
  "duration": 15.0, "fps": 30,    // clean frames = duration * fps
  "warmup_frames": 60,            // after the scene reports ready; camera already at t=0 (TAA / fog / particle history)
  "args": [...],                  // replace the default act args (below); "args_extra": [...] appends instead
  "no_act_flag": false,           // true: do not add --lshu-act=<target> (acts then run in their dev/tool mode)
  "time_scale": 1.0,              // Engine.time_scale during capture (in-engine slow motion of delta-driven things)
  "seed": 3,                      // global RNG seed (home: blink timing)
  "hide": ["NodeName"],           // extra nodes to hide (find_child under the plate)
  "events": [{"t": 6.0, "call": "act_poke"}, {"t": 2, "node": "Director", "set": {"x": 1}}],
  "camera": {"mode": "hold"}      // or keys, see 2.4
  // target-specific: "baghdad": {"start": 30.0, "rate": 1.0} | "lshu_director": false |
  //                  "board_feed": "clean"|"plate", "board_tilt": true, "board_ready_frames": 60 | "ui_base": [1280,720]
}
```

Default args per target (what the game passes when the player enters): changan `--view=changan --far --dusk`;
panti `--view=panti --morning`; baghdad `--view=baghdad --lookdev=m_grass --cycle-auto`; lshu none (use
`args_extra: ["--tile=D05", "--light=sunset"]`); board `--showcase --seed=7 --ai-delay=0.6`. Never pass the acts'
own `--capture=` flag (it takes a screenshot and quits).

### 2.4 Camera

```jsonc
"camera": {
  "mode": "keys",
  "space": "act",           // "world" (scene units) or "act": x right, y up, z back in the act camera's own frame at
                            // readiness, origin at the act camera -> {"pos":[0,0,0],"look":[0,0,-10]} IS the act framing
  "look_space": "world",    // optional: aim at world POIs while moving in act space
  "interp": "catmull",      // time-aware Catmull-Rom (C1 across uneven key spacing; a hold = two equal keys stays put)
                            // or "linear"
  "projection": "perspective", "near": 0.1, "far": 800,
  "dof_focus": {"near_offset": 3, "far_offset": 5},   // optional: focus the camera's own DOF on the look point
  "keys": [
    {"t": 0.0, "pos": [0, 0.30, -2.4], "look": [0.1, 0.02, -12.4], "fov": 36, "roll": 0, "ease": "linear"},
    {"t": 4.0, "pos": [0, 0.30, -2.4], "look": [0.1, 0.02, -12.4], "ease": "inOutSine"},
    {"t": 13.5, "pos": [0, 0, 0], "look": [0, 0, -10]}
  ]
}
```

`ease` belongs to the segment that starts at that key: linear, inSine, outSine, inOutSine (default), inQuad,
outQuad, inOutQuad, inCubic, outCubic, inOutCubic, outQuart, inOutQuart, outExpo, inOutExpo, outBack, smooth,
hold (= hard cut at the next key). `size` animates an orthographic camera. Baghdad drives both of its worlds'
cameras with the same path. Home (2D): keys `{t, zoom, center: [x, y] in 1920×1080 output px, roll}`.
Verified: act space `[0,0,0]→[0,0,-10]` reproduces the act's own frame (17 of 2 073 600 pixels differ, all
particles); `tests/path_test.gd` checks holds (0.0 drift), exact keys and velocity continuity.

### 2.5 Per target: camera, vantage points, what moves by itself

Coordinates are world units, read from `capture.json` (`act_camera`, `poi`). Proof: `docs/demo_captures.jpg`
(one 3 s camera move per target) and `docs/vantage_survey.jpg` (hard-cut surveys, `shots/survey_*.json`).

| target | camera driven | ready signal | act camera | points of interest |
| --- | --- | --- | --- | --- |
| changan | `EurasiaAtlas/World/AtlasCamera` (fov 36) | act overlay `mark_ready` (~3 s) | pos `[34.57,3.97,14.92]` fwd `[-0.577,-0.123,-0.808]` | gate `[29.65,1.01,6.20]` · L叔 ≈`[28.78,0.64,8.75]` (walks) · cliff Buddha `[20,1.05,6]` (scale 6.7) |
| panti | `PantiTraveler/FrozenCamera` (fov 40, DOF) | `mark_ready` (~3 s) | pos `[7.716,0.253,15.379]` look `[-2.162,3.403,1.543]` | fire `[5.859,0.100,13.473]` · L叔 `[5.574,0.135,13.667]` · fortress `[-1.61,0,-3.70]` |
| baghdad | `viewer_a.camera` + `viewer_b.camera` (both, fov 40) | `ready_state` (9–17 s) | pos `[0,0.18,0]` fwd `[0,0.181,0.984]` | L叔 `[0.47,0,2.79]` · potato bundle `[0.378,0.314,2.867]` |
| lshu | `LshuWhere/TileCamera` (fov 22) | `mark_ready` (~2 s) | D05: pos `[14.60,18.37,17.46]` (yaw 40.1°, pitch 37.8°, r 28.4) | `poi.camera_fit` (tile bounds, target) · L叔 at tile origin |
| board | BoardWorld camera (ortho by default; keys switch it to perspective) | world built + `board_ready_frames` (~10–13 s) | ortho size 31.7 | city anchors in `poi.cities`, e.g. 长安 `[87.7,0.9,19.5]` 泉州 `[103.7,1.0,28.1]` 罗马 `[14.5,0.9,20.0]` 君士坦丁堡 `[23.9,0.9,14.1]` 盘橐 `[59.7,0.9,11.7]` 狮子国 `[70.9,0.9,53.7]`; board x 0–128, z 0–59.6 |
| home | 2D rig around the illustration | immediate | — | L叔 ≈ `[1110,600]` output px at zoom 1 |

Good vantage points (world space, all in `shots/survey_*.json`, look at `docs/vantage_survey.jpg`):
- **changan**: gate low `pos [30.9,1.05,8.6] look [29.65,1.05,6.2] fov 40` · Buddha niche `pos [26.5,3.4,11] look [20.8,2.8,6.5]` ·
  reverse behind the temple (sea beyond) `pos [28.3,2.4,1.8] look [31.5,0.9,11] fov 38`. High wide `[42,13,24]` shows set edges — avoid.
- **panti**: L叔 + fire `pos [6.75,0.42,14.75] look [5.7,0.28,13.6] fov 35` · fire macro `pos [6.35,0.2,14.05] look [5.86,0.16,13.47] fov 30` ·
  toward the fortress `pos [5.2,0.6,11.8] look [-1.6,1.2,-3.7] fov 32` · wide `pos [11,3,20] look [0,1.5,2] fov 42`.
- **baghdad**: potato close-up `pos [0.2,0.36,2.05] look [0.4,0.33,2.87] fov 35` · pulled back through the arch `pos [0,0.9,-1.6] look [0.3,0.5,5]`.
  The set is built for the frontal view: `pos [1.6,0.45,2.3]` is inside an arch pillar. Keep lateral moves < ~1 unit.
- **board**: 长安 low oblique `pos [84,6.5,29] look [87.7,0.9,19.5] fov 34` · 泉州 harbour `pos [100,5,38] look [103.7,1,28.1]` ·
  Mediterranean `pos [15,14,36] look [20,0.9,17] fov 38` · whole board as an object `pos [64,70,110] look [64,0,28] fov 40` ·
  盘橐 pass `pos [58,6,22] look [59.7,1.5,11.7]` · Indian Ocean `pos [60,10,68] look [62,0.5,50]`.
- **lshu**: orbit on the circle of radius 22.76 at height 18.37 around the tile (demo `shots/demo_lshu_orbit.json`, 40°→20°).

What animates by itself (and how to steer it):
- **changan**: clouds, birds, falling leaves, sparks (`motion_director.gd`), L叔 walks his path, lanterns / Buddha glow at dusk,
  ambience. `{"call": "act_poke"}` = clicking the gate: 8 s transition dusk ↔ day. `--day` instead of `--dusk` starts in daylight.
- **panti**: snowfall, wind mist, tree wind, campfire + sparks, castle lights, L叔 seated. `act_poke` toggles morning ↔ midnight
  (8 s, `data/traveler/panti_period_transition.json`); `{"call":"request_lighting_period","args":["midnight"]}` is explicit;
  `--midnight`, `--blend=<0..1>` hold a state. Snowfall / glitter / wind are set up relative to the act camera: small moves only.
- **baghdad**: the cycle clock is wall-clock in the game; the kit drives it frame-exactly: clock = `start + rate × t`
  (warm-up runs up to `start`). Timeline (`cycle_config.json`): 0–8 rain → flowers open (0–4), light beams (3–6), leaf glow
  (6.2–8), city lights (4–8) · 8–16 clouds roll away to dusk · 16–26 dusk hold · 26–30 rain returns · 30–34 rain hold, loops.
  The game's opening "rain, waiting for a click" state = cycle 30–34 (or 0). `rate` 0 freezes, 2 doubles.
- **lshu**: single tile with `--tile=<id> --light=morning|day|sunset|night` (or `--light-blend=a,b,t`); L叔 idles / acts on his tile.
  160 tiles in `data/traveler/lshu/pool.json` (D01 雪林来信 · D02 海角等风 · D03 红岩古道 · D04 风车草丘 · D05 长安石窟 ·
  D06 刺桐海港 · D07 玉门关塞 · D08 盘橐绿洲 · D09 平城京寺塔 · D10 真腊塔庙 · D11 巴格达学宫 · D12 德里阶井 …).
  The director mode (`"lshu_director": true`: random tiles, postcards, travel book) runs on the system clock — not reproducible.
  No ambience in single-tile mode (it attaches with the director).
- **board**: 4 AI players take turns (camels / boats move along routes), sea life, the day light follows match time.
  `--daytime=<s>` pins the light, `--day-speed=<n>` speeds the day (put them in `args_extra`). Deterministic apart from AI timing.
- **home**: clouds drift, balloon bobs, paper plane every 26 s (on screen when t mod 26 ∈ [14, 26)), birds every 38 s,
  camel caravan, L叔 breathes and blinks (blinks use the seeded RNG), a 3.2 s zoom-in at start.

### 2.6 Measured timings (15 s = 450 frames, 1080p, M1 Ultra)

| target | solo: wall total | ready | ms / clean frame | 4 in parallel: wall each |
| --- | --- | --- | --- | --- |
| changan | 19.4 s | 3.2 s | 29 | 60 s |
| panti | 19.5 s | 3.1 s | 31 | 57 s |
| baghdad | 33.0 s | 11.0 s | 41 | 75 s |
| lshu | 28.3 s | 2.2 s | 48 | 76 s |
| board | 34.5 s | 9.8 s | 46 | — |
| home | 21.2 s | 0.2 s | 41 | — |

Four 15 s plates in parallel finish in ~76 s total. Add ~1 s for the PNG flush. Stalls in all runs: 0.

### 2.7 A/V sync and audio

`--sync-test` flashes the plate white and plays a 1 kHz beep at every whole second: flashes land on frames
0 / 30 / 60 exactly and beep onsets at +3.5, +6.2, +8.8 ms — i.e. the trimmed `audio.wav` is aligned to ±11 ms
(the audio server's 512-sample block), no drift. Game audio loudness in 15 s plates: changan −26.1 LUFS,
panti −27.3, baghdad −27.6, board −30.4; lshu (single tile) and home are silent (title music belongs to the
title screen: `assets/audio/title/title_bgm_loop_v1.wav`, −18.8 LUFS).

## 3. HTML frame renderer

```
node tools/motion/html/render.mjs PAGE.html --out DIR [--frames 0:450] [--fps 30] [--workers 6] [--alpha]
     [--size 1920x1080] [--query "act=changan&t=3"] [--only 12,40] [--seed 1234] [--timeout 120]
```

Page contract: `window.renderFrame(i, fps)` (async, required) draws frame *i* as a pure function of *i* — workers
render contiguous chunks in parallel in separate Chrome instances, so never depend on the previous frame.
`window.setupScene(info)` (optional, awaited once per worker) for loading. The renderer makes time virtual before
each frame (`performance.now()` = i/fps s, `Date.now()` fixed epoch + i/fps), seeds `Math.random` (same sequence
in every worker), and after `renderFrame` seeks every CSS / Web Animation (`document.getAnimations()`) and SVG SMIL
timeline to i/fps, waits for fonts and images, then screenshots the viewport (deviceScaleFactor 1). So CSS
`@keyframes` with delays just work. Do not rely on requestAnimationFrame.

Served routes: the page's own folder at `/`, the worktree at `/__repo/…` (game art: `/__repo/assets/game/title_cg/changan.jpg`,
`/__repo/art-src/cards-v2/masters/…`), scratch at `/__scratch/…` (Godot plates: `ImageSeq("/__scratch/me/changan/frame_%05d.png")`
from `lib/motion.js`), system CJK fonts at `/__fonts/…`, and `lib/` at `/__motion/…`. Include
`<link rel="stylesheet" href="/__motion/fonts.css">`. Verified by rendering: `"Wawati SC"`, `"Yuanti SC"`, `"Hannotate SC"`,
`"Kaiti SC"`, `"Songti SC"`, `"Weibei SC"`, `"Yuppy SC"`, `"PingFang SC"` resolve by name; `"STXingkai"` does **not** — use
`MotionXingkai` (or `var(--font-brush)`). Variables: `--font-headline`, `--font-body`, `--font-hand`, `--font-brush`, `--font-kai`, `--font-song`. WebGL is hardware (ANGLE Metal, WebGL2).
`--alpha`: transparent background → RGBA PNGs (verified: `docs/html_demo_alpha.jpg`).

Measured on `demo/demo_title.html` (WebGL points + Canvas2D + DOM text + CSS keyframes): 1 worker 12 fps, 4 workers
31 fps, 6 workers 65 fps (450 frames in 6.9 s); screenshot ≈ 65 ms per frame per worker, the page's own drawing
adds on top. 1 worker vs 4 workers: max pixel difference 3/255 (GPU rasterisation), i.e. deterministic.

## 4. Compositing, grading, finishing — `mc.py`

Every subcommand prints the ffmpeg command it runs. Inputs: frame dirs (`frame_%05d.png`), patterns, videos, stills.
Outputs: a frame dir, `.mov` (ProRes 4444 with alpha, as intermediate) or any ffmpeg file.

```bash
mc=tools/motion/comp/mc.py
python3 $mc comp --base PLATE --layer TITLES:over --layer LEAK:screen:0.5 --layer HTML2:over:1:4.0 --out COMP   # PATH:mode:opacity:start_s
python3 $mc grade COMP --out GRADED --lut lshu_dusk --eq contrast=1.04:saturation=1.05 --balance rs=.02:bh=-.03 \
        --grain 0.15 --vignette 0.35 --leak LEAKDIR --leak-opacity 0.45 --letterbox 2.39
python3 $mc blendto GRADED PLATE --at 12.0 --dur 1.5 --out HANDOVER    # graded -> pure game frame before the handover
python3 $mc ramp PLATE --out RAMPED --map "0:0,2:2,6:3,8:9" --blend      # out_s:src_s keys: slow-mo 2–6 s, fast 6–8 s
python3 $mc mix --track score.wav@0:0 --track plate/audio.wav@0:-6:0.5:1.0 --track sfx.wav@11.93:-4 --duration 15 --out mix.wav
python3 $mc loudnorm mix.wav --out mix_norm.wav --I -16 --TP -1.0        # two-pass, linear; prints the result
python3 $mc measure a.wav b.ogg                                           # integrated LUFS, LRA, true peak (JSON)
python3 $mc spectrum mix_norm.wav --out spec.png                          # look at it with the Read tool
python3 $mc master GRADED --audio mix_norm.wav --out "/Users/chengzeyuan/Desktop/旅行L叔-动态影像/长安旅人_入场_v1"
python3 $mc ogv GRADED --audio mix_norm.wav --out $S/me/changan_intro      # -q:v 8, BT.601 (see 4.2)
~/.local/bin/uv run -q --offline --with numpy --with pillow python tools/motion/comp/leak.py --out LEAKDIR --duration 15 --palette lantern --flash 5.2,11.93
~/.local/bin/uv run -q --offline --with numpy python tools/motion/comp/make_luts.py --preview some_frame.png   # -> some_frame_luts.jpg
```

- Blend modes: `over` (alpha), `screen`, `add`, `multiply`, `softlight`, `overlay`, `lighten`, `darken`, `hardlight`, `difference`.
- Looks (`docs/lut_looks.jpg`): `lshu_dusk`, `lshu_night`, `lshu_morning`, `lshu_parchment`, `lshu_bleach` (33³ .cube,
  sRGB in/out, built from `make_luts.py`; any other `.cube` path works too). Leak palettes: dusk, lantern, snow, parchment.
- Pitfall fixed inside `mc.py`: `vignette` silently switches to YUV and a following `blend` then mixes YUV with RGB plane
  by plane (a strong magenta cast); every branch ends in `format=gbrp`. If you write your own graphs, do the same.
- Colour: masters are converted with the BT.709 matrix, limited range, and tagged bt709/bt709/bt709 (PNG input would
  otherwise tag the sRGB transfer, which QuickTime renders differently).
- `ramp` maps output time → source time piecewise-linearly (verified: output frame 120 of `0:0,2:2,6:3,8:9` = source frame 75).
- Grading of the entrance films must fade to zero before the handover (art brief §4): `blendto` cross-fades the
  finished (graded) sequence into the untouched game plate over the same moments —
  `python3 $mc blendto GRADED PLATE --at 12.0 --dur 1.5 --out HANDOVER` (verified frame-exact: frames before 12.0 s equal
  GRADED, frames from 13.5 s equal PLATE bit for bit, 450 in → 450 out, 6.7 s).

Measured for a 15 s (450-frame) 1080p piece: comp (1 alpha layer) 5 s · grade (LUT + vignette + leak + grain) 14 s ·
mix 1 s · loudnorm 1 s · master mp4 + ProRes 18 s · ogv 34 s · leak generation 7 s · ramp 2.4 s · blendto 6.7 s.
`docs/pipeline_proof_sheet.jpg` is the finished test master (Chang'an 15 s plate, `act_poke` at 6 s, HTML title layer,
lantern leak, `lshu_dusk`, grain, synth cue + game ambience at −15.8 LUFS / −1.0 dBTP).

### 4.1 Masters

`master` → `NAME.mp4` (H.264 High 4.2, CRF 14, preset slow, yuv420p BT.709, keyint 2 s, AAC 320 kb/s 48 kHz (256 before the series pass),
`+faststart`) and `NAME.mov` (ProRes 422 HQ `apch`, yuv422p10le, PCM 24-bit). Sizes for the 15 s test with grain:
mp4 62.9 MB (33 Mb/s — grain is expensive), mov 441 MB. `--no-prores`, `--crf`, `--preset` available.

### 4.2 In-game intros (.ogv)

`ogv` → `NAME.ogv` (Theora yuv420p **BT.601** (tagged smpte170m) + Vorbis q5 ≈ 160 kb/s 48 kHz stereo) and `NAME.ogg` (the audio alone).

> **Series finishing pass (2026-09-27, art-src/motion/series/README.md) — two corrections to this section.**
> 1. Godot 4.7.1's Theora player decodes with the **BT.601** matrix whatever the stream says (measured on its own decoded
>    texture by all four intro reviews), so `ogv` now encodes BT.601; the earlier BT.709 encode played back up to 4 levels off.
> 2. Use constant quality **`-q:v 8`** (the default; the four intros all ship at q8), not `--vbitrate 8M`: the one-pass ABR
>    starved the hard moments (长安 push/place 29–32 dB in Godot's own decode with visible 8×8 blocks; 巴格达 27.9 dB). At q8 the
>    intros are 18–24 MB with every frame ≥ 34 dB. The numbers below are the original toolkit test.

Size / quality for the 15 s test: `--vbitrate 8M` → **15.3 MB**, PSNR 39.2 dB vs the H.264 master (the original recommendation, superseded above);
`--vq 7` → 22.1 MB; `--vq 8` → 30.4 MB. Grain inflates Theora the most — keep in-game grain light (≤ 0.1).

**Godot 4.7.1 playback proof** — `tools/motion/godot/ogv_test.sh FILM.ogv [AUDIO.ogg] [--audible]` copies the film to
`tools/motion/godot/_test/` (git-ignored), plays it with `VideoStreamPlayer.stream = load("res://…ogv")` in a 960×540
window with vsync, audio on a bus named `IntroVideo` (Dummy driver = silent but mixed and metered), then runs a
baseline without video. Result for the 8 Mb/s test film:

| check | result |
| --- | --- |
| advances | `stream_position` tracks wall time (0.195 s at 0.221 s … 14.192 s at 14.222 s), 927 frames advanced |
| audio | Theora's own Vorbis track plays: bus `IntroVideo` peak −0.68 dBFS, signal on 923 of 959 frames |
| end | `finished` at 15.45 s wall (position runs ~0.2 s past 15.0 s, then stops) |
| CPU | 4.25 s CPU for the 16 s run vs 1.25 s baseline → **≈ 0.19 cores** to decode 1080p Theora (≈ 3 CPU-s per 15 s film) |
| fallback | video-only .ogv + the `.ogg` in an `AudioStreamPlayer` on the same bus, started together: also plays, `finished` 15.02 s |

Integration notes: use `load("res://…/intro_<act>.ogv")` (no import step for .ogv); route to your own bus; start the act
handover on `stream_position >= length - fade` rather than waiting for `finished` (it arrives ~0.45 s late).

## 5. Review tools

```bash
~/.local/bin/uv run -q --offline --with pillow python tools/motion/review/contact_sheet.py INPUT [-o sheet.jpg] [--every 1] [--offset 0] [--cols 5] [--width 384]
python3 tools/motion/review/stills.py INPUT --at 0.5,7.25,14.9 [--frames] [--jpg] [-o OUTDIR]
```

INPUT = frame dir or video. Tiles are labelled `MM:SS:FF  #frame`. Stills are frame-exact for both kinds of input.
Use `--every 1 --offset 0.8` on the survey captures (cut + 0.8 s so TAA / DOF have settled).

## 6. Audio

You cannot listen: build sound from code and existing assets, then verify by measurement.

- **Synthesis**: `tools/motion/audio/synth.py` (numpy + scipy, 48 kHz float stereo). Voices: `pad`, `pluck`
  (Karplus-Strong: dutar / zither colour), `bell` (inharmonic partials: temple / camel bells), `drum` (frame drum / taiko),
  `wind`, `rain`, `whoosh` (rising / falling filtered noise), `riser`, `subdrop`, `paper` (postcard / page), `stamp`
  (the postmark 「咚」). Tools: `adsr`, `lowpass/highpass/bandpass`, `reverb` (synthetic IR, FFT convolution), `delay`,
  `place(mix, x, at, gain_db, pan)`, `beat()/bar()`, `master()` (soft clip + peak), `read()/write()`.
  Demo cue (15 s, 84 BPM, whoosh → stamp + sub-drop landing on 11.93 s): 
  `~/.local/bin/uv run -q --offline --with numpy --with scipy python tools/motion/audio/synth.py --demo OUT.wav` (1.2 s to render).
- **Game assets to layer**: `assets/audio/ambience/*.ogg` (beds ≈ −31…−33 LUFS: campfire, rain, wind, waves, birds;
  one-shots: temple bell −23 LUFS, bells, bird calls, hooves, oars), `assets/audio/sfx/*.wav` (camel walk, dice, cards,
  trade, ship), `assets/audio/title/title_bgm_loop_v1.wav` (16.6 s loop, −18.8 LUFS), and each plate's own `audio.wav`.
  `tools/audio/ambience_render/common.py` has `read_wav`, `write_wav`, `rms_env`, `stft_mag`, `band_levels`, `pick_onsets`, `ebur128`.
- **Loudness**: `mc.py measure` (integrated / LRA / true peak), `mc.py loudnorm --I -16 --TP -1` (two-pass, linear).
  Targets: showreel master −16 LUFS / −1 dBTP; entrance films: follow the art brief (music out by 14.5 s, tail = the act's
  live ambience at its in-game level, −26…−28 LUFS as measured above). Check with `mc.py spectrum` (log-frequency PNG).
- **Sync**: hits land on frames when their times are multiples of 1/30 s; the plate audio is aligned to ±11 ms.

## 7. Rules of the road

- Godot: only through `capture.py` (HOME in scratch, `perl alarm` timeout, slots). Never kill Godot processes you did
  not start (pid 83000 is Carlos's). Preview windows are tiny and always on top in the top-right corner.
- Commit sources, shot files, small stills and the final in-game `.ogv` only; frames and intermediates stay in scratch.
- `git -C $W commit -- <paths>` with the `Co-Authored-By` line; never push, never touch main.
