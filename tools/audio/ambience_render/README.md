# 环境音渲染

把 `~/Desktop/音效/` 里的原始素材处理成游戏用的环境音（`assets/audio/ambience/*.ogg`）：去低频轰鸣和电源嗡声、修海浪的爆音、打乱重排做无缝长循环、寺庙钟补尾巴、按目标响度（底床约 −30 LUFS、一次性约 −20 LUFS）归一化、转 Ogg Vorbis。

配方都在 `render.py` 的 `RECIPES` 里。重跑：

```bash
cd tools/audio/ambience_render && ~/.local/bin/uv run -q --with numpy --with scipy python render.py
```

需要 `~/.local/bin/ffmpeg`。输出在本目录 `renders/` 下（不入库），挑 `renders/ogg/*.ogg` 拷到 `assets/audio/ambience/`。
方案与逐文件分析见 `docs/design/shanhe-luren/sound-20260926/README.md`。
