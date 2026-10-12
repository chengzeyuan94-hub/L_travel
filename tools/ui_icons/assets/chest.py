import math
c = asset_col(KEY)
wood = mat("chest_wood", hexrgb("#9C5F36"), rough=0.7)
wood_dk = mat("chest_wood_dark", hexrgb("#6F4124"), rough=0.7)
brass = mat("brass", hexrgb("#C99A3C"), rough=0.35, metal=0.7)
leather = mat("leather", hexrgb("#7A4A2B"), rough=0.6)
tag = mat("tag_cream", hexrgb("#EFE0C0"), rough=0.7)
W, D, H = 0.74, 0.46, 0.32
box("chest_body", c, size=(W, D, H), bevel=0.03, m=wood, loc=(0, 0, H / 2))
box("chest_lid", c, size=(W + 0.02, D + 0.02, 0.16), bevel=0.05, segs=2, m=wood, loc=(0, 0, H + 0.08))
for z in (0.11, 0.21):
    box(f"chest_plank_{z}", c, size=(W + 0.004, D + 0.004, 0.012), bevel=0.0, m=wood_dk, loc=(0, 0, z))
for sx in (-1, 1):
    for sy in (-1, 1):
        for z in (0.04, H + 0.12):
            box(f"chest_corner_{sx}_{sy}_{z}", c, size=(0.1, 0.1, 0.1), bevel=0.025, m=brass, loc=(sx * (W / 2 - 0.03), sy * (D / 2 - 0.03), z))
box("chest_strap", c, size=(0.12, D + 0.05, 0.012), bevel=0.004, m=leather, loc=(0, 0, H + 0.165))
box("chest_strap_front", c, size=(0.12, 0.012, H + 0.14), bevel=0.004, m=leather, loc=(0, -D / 2 - 0.018, (H + 0.14) / 2 + 0.02))
b = box("chest_buckle", c, size=(0.14, 0.02, 0.12), bevel=0.02, m=brass, loc=(0, -D / 2 - 0.03, H - 0.02))
box("chest_buckle_hole", c, size=(0.08, 0.02, 0.06), bevel=0.01, m=leather, loc=(0, -D / 2 - 0.036, H - 0.02))
box("chest_tag", c, size=(0.09, 0.012, 0.12), bevel=0.012, m=tag, loc=(0.13, -D / 2 - 0.03, 0.14), rot=(0, 0.25, 0))
box("chest_tag_L1", c, size=(0.012, 0.004, 0.06), bevel=0.0, m=wood_dk, loc=(0.12, -D / 2 - 0.038, 0.14), rot=(0, 0.25, 0))
box("chest_tag_L2", c, size=(0.035, 0.004, 0.012), bevel=0.0, m=wood_dk, loc=(0.133, -D / 2 - 0.038, 0.113), rot=(0, 0.25, 0))
print(finish(KEY))
