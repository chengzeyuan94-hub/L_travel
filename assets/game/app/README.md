# App 图标与启动画面

- `app_icon_1024.png`：Mac 安装包图标（export_presets.cfg 的 application/icon）和游戏窗口图标（project.godot 的 config/icon）。
  2026-09-27 Carlos：换成开场主界面那个小人。取自开场原画 `docs/design/shanhe-luren/title-home-20260926/01_master.jpg`
  的 (975, 200)–(1595, 820) 这一块（620 像素见方：头顶小揪到挎包，左手拿花），放进 824 像素圆角方块，暖棕细边 + 软阴影。
- `android_icon_192.png`：安卓旧式启动图标，同一张图、同一个框。
- `android_icon_bg_432.png` / `android_icon_fg_432.png`：安卓自适应图标。背景层是同一处取景放大成 1.5 倍范围
  （(820, 45)–(1749, 974)），让脸和花落在中间三分之二里——桌面启动器按圆形 / 方形裁的都是这一块；前景层是透明的。
- `boot_splash.png`：启动画面。
