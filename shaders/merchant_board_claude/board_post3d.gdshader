// 《山河旅人》 merchant board — 3D post overlay ("painted relief + soft pen").
// A camera-parented full-screen quad in the transparent queue. It must be drawn FIRST in that
// queue (material render_priority -128 in build_post()), so the sea, clouds, storm, rain, mist,
// smoke and dust devils all cover it; nothing is lost, because every pixel it touches lies above
// the water.
// Blending is premultiplied: out = ALBEDO + frame * (1 - ALPHA), so the one pass both lays ink
// (ALPHA) and adds / removes light (ALBEDO with no alpha).
//  1. Pen: a thin line tinted to what it outlines, drawn only from the depth buffer.
//     * silhouettes: depth Laplacian, near side only, with a coverage estimate from all four
//       neighbour pairs so staircase tips get partial ink (soft, anti-aliased-looking lines);
//       big steps (mountains, cities, cliff tops) get a deep warm-brown pen with a second inner
//       pixel; small ones (trees, coins, dashes, boats) a light line in their own darkened hue;
//       greens (trees, grass hills) never get the brown pen; pale subjects (snow, sea coins,
//       seabirds, white walls) get a blue-grey line instead of a pink / brown one;
//     * creases: faint, sharp normal breaks only (roof and wall corners, ridges), dropped in the
//       wide views and lightened in close-ups so it never turns into a comic cel outline;
//     * coast: a soft stroke where dry land meets the water line.
//     Water-aware depth: an opaque hit under the sea counts as the sea plane, so the seabed,
//     fish and kelp never produce lines.
//  2. Painted light (after the "paint" study): on slopes, faces turned to the sun take warm
//     golden light (capped on bright surfaces so snow and white walls never wash out) and faces
//     turned away gain a little colour without being lifted; rock and earth slopes turned away
//     from the sun (mountains — not walls, cliffs, trees or snow) sink toward a deeper warm brown
//     by multiplication, so the shade gets richer, never grey; on gentle terrain the sunward
//     facets are pushed brighter than the others are darkened. Flat ground is untouched, so the
//     calibrated sand and grass keep their colour. No channel may fall below 60 % of itself
//     (no acid-olive forest shade).
// Sun direction: fixed to the noon preset (sun_to = -sun_dir). The renders use it for every
// preset; optionally the scene can pass set_post_param("sun_to", -sun_dir) per preset.
// Presets: the scene key (average luma of the frame) scales the ink darkness and the added
// light, so noon, dusk and twilight share one set of numbers.
// Cost: 13 depth, 5 normal, 6 colour taps (24); +4 depth only in the thin band above the water.
// Renderers: the normal-roughness buffer exists only in Forward+ (desktop). Under Mobile (the
// Android build) and Compatibility, Godot refuses hint_normal_roughness_texture and swaps in its
// default material, which ignores the full-screen POSITION trick below: the 2x2 quad was then drawn
// as a plain grey square 1 unit in front of the camera, stuck in the middle of the screen (Android
// bug 2026-09-29). So the buffer is only declared under Forward+, whose code is kept verbatim (same
// pixels); elsewhere the five normals are rebuilt from the depth buffer at the same 13 taps the pen
// reads (view-space face normals, one-sided differences toward the nearer neighbour so silhouettes
// do not bleed into the creases).
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_test_disabled, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
#if CURRENT_RENDERER == RENDERER_FORWARD_PLUS
uniform sampler2D normal_tex : hint_normal_roughness_texture, filter_nearest;
#endif
uniform sampler2D scene_tex : hint_screen_texture, filter_linear_mipmap;

// --- pen
uniform vec3 ink_color = vec3(0.30, 0.16, 0.07);   // linear; deep pen for the big steps
uniform float ink_dark = 0.24;                     // big steps: a little of the local hue
uniform float ink_light = 0.62;                    // small objects: local hue, darkened
uniform vec3 pale_ink = vec3(0.34, 0.42, 0.56);    // snow / white walls / sea coins: blue-grey
uniform float sil_alpha = 0.85;
uniform float small_keep = 0.38;                   // alpha kept by the small-object line
uniform float crease_alpha = 0.2;
uniform float coast_alpha = 0.6;
uniform float sil_lo = 1.2;                        // Laplacian, in pixel footprints
uniform float sil_hi = 14.0;
uniform float thick_lo = 30.0;                     // big step: second, inner pen pixel
uniform float thick_hi = 80.0;
uniform float crease_lo = 0.35;                    // 1 - cos(angle) between neighbouring normals
uniform float crease_hi = 0.65;
uniform float sea_y = -0.06;
uniform float ref_px = 0.0292;                     // world size of one pixel in the east / west views
uniform float far_keep = 0.45;                     // pen alpha kept at ~2x that footprint (full view)
// --- painted light
uniform vec3 sun_to = vec3(-0.69, 0.72, -0.09);    // world direction toward the noon sun
uniform float lit_gain = 0.48;
uniform vec3 lit_tint : source_color = vec3(1.0, 0.88, 0.68);
uniform float lit_chroma = 0.7;
uniform float facet_gain = 0.6;
uniform float facet_shade = 0.3;
uniform float shade_chroma = 0.25;
uniform vec3 back_mul = vec3(0.72, 0.64, 0.62);   // slopes turned from the sun: warm, deeper (never grey)
uniform float back_strength = 0.8;
uniform float land_y = 0.02;
uniform float key_noon = 0.36;                     // measured frame key at noon (linear luma)

float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

vec3 view_pos(vec2 uv, float d, mat4 inv_proj) {
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return v.xyz / v.w;
}

// View depth of the surface the eye meets: the opaque depth, or the sea plane when the opaque
// hit lies under water (the sea writes no depth).
float surf_z(vec2 uv, mat4 inv_proj, mat4 inv_view, float sea) {
	vec2 ndc = uv * 2.0 - 1.0;
	vec4 b = inv_proj * vec4(ndc, texture(depth_tex, uv).r, 1.0);
	b.xyz /= b.w;
	float yb = (inv_view * vec4(b.xyz, 1.0)).y;
	if (yb >= sea) {
		return -b.z;
	}
	vec4 a = inv_proj * vec4(ndc, 1.0, 1.0);  // reversed-Z: 1 = near plane
	a.xyz /= a.w;
	float ya = (inv_view * vec4(a.xyz, 1.0)).y;
	float t = clamp((sea - ya) / min(yb - ya, -1e-5), 0.0, 1.0);
	return -mix(a.z, b.z, t);
}

float world_y(vec2 uv, mat4 inv_proj, mat4 inv_view) {
	return (inv_view * vec4(view_pos(uv, texture(depth_tex, uv).r, inv_proj), 1.0)).y;
}

#if CURRENT_RENDERER != RENDERER_FORWARD_PLUS
vec3 depth_pos(vec2 uv, mat4 inv_proj) {
	return view_pos(uv, texture(depth_tex, uv).r, inv_proj);
}

// View-space face normal at c from its four neighbours, turned toward the eye.
vec3 depth_normal(vec3 c, vec3 l, vec3 r, vec3 u, vec3 d, vec3 eye) {
	vec3 dx = abs(r.z - c.z) < abs(c.z - l.z) ? r - c : c - l;
	vec3 dy = abs(d.z - c.z) < abs(c.z - u.z) ? d - c : c - u;
	vec3 n = normalize(cross(dx, dy));
	return dot(n, eye) < 0.0 ? -n : n;
}
#endif

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 px = 1.0 / VIEWPORT_SIZE;
	float d0 = texture(depth_tex, uv).r;
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
	if (d0 > 0.0) {
		mat4 ip = INV_PROJECTION_MATRIX;
		mat4 iv = INV_VIEW_MATRIX;
		vec3 pc = view_pos(uv, d0, ip);
		vec3 wc = (iv * vec4(pc, 1.0)).xyz;
		float zc = surf_z(uv, ip, iv, sea_y);
		bool ortho = PROJECTION_MATRIX[3][3] > 0.5;
		// world size of one pixel here (PROJECTION_MATRIX[1][1] is negative on this backend)
		float foot = max(2.0 / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y) * (ortho ? 1.0 : zc), 1e-4);
		float zf = ref_px / foot;                      // 1 at east / west, ~1.6 close, ~3.5 reef
		float inv = 1.0 / foot;

		// scene key: noon ~0.36, dusk ~0.18, twilight ~0.05 (linear, pre-transparent frame)
		vec3 kc = textureLod(scene_tex, vec2(0.5, 0.5), 7.0).rgb + textureLod(scene_tex, vec2(0.2, 0.25), 7.0).rgb
			+ textureLod(scene_tex, vec2(0.8, 0.25), 7.0).rgb + textureLod(scene_tex, vec2(0.2, 0.75), 7.0).rgb
			+ textureLod(scene_tex, vec2(0.8, 0.75), 7.0).rgb;
		float key = luma(kc) / 5.0;
		float kf = clamp(key / key_noon, 0.12, 1.0);
		float day = mix(0.3, 1.0, smoothstep(0.06, 0.3, key));

		vec3 local = textureLod(scene_tex, uv, 0.0).rgb;
		float ll = luma(local);
		float lmx = max(local.r, max(local.g, local.b));
		float lmn = min(local.r, min(local.g, local.b));
		float sat = lmx > 1e-4 ? (lmx - lmn) / lmx : 0.0;
		// foliage and grass: green at least as strong as red, little blue (walls / snow / teal roofs are not)
		float greenish = smoothstep(0.88, 0.97, local.g / max(local.r, 1e-4))
			* (1.0 - smoothstep(0.35, 0.6, local.b / max(local.g, 1e-4)));

		// ---------------- 1. pen
		float zl = surf_z(uv + vec2(-px.x, 0.0), ip, iv, sea_y);
		float zr = surf_z(uv + vec2(px.x, 0.0), ip, iv, sea_y);
		float zu = surf_z(uv + vec2(0.0, -px.y), ip, iv, sea_y);
		float zd = surf_z(uv + vec2(0.0, px.y), ip, iv, sea_y);
		float z1 = surf_z(uv - px, ip, iv, sea_y);
		float z2 = surf_z(uv + px, ip, iv, sea_y);
		float z3 = surf_z(uv + vec2(px.x, -px.y), ip, iv, sea_y);
		float z4 = surf_z(uv + vec2(-px.x, px.y), ip, iv, sea_y);
		float lh = (zl + zr - 2.0 * zc) * inv;
		float lv = (zu + zd - 2.0 * zc) * inv;
		float la = (z1 + z2 - 2.0 * zc) * inv;
		float lb = (z3 + z4 - 2.0 * zc) * inv;
		// coverage: a straight edge scores ~2.4, a staircase tip ~0.7 -> partial ink
		float cov = smoothstep(sil_lo, sil_hi, lh) + smoothstep(sil_lo, sil_hi, lv)
			+ 0.7071 * (smoothstep(sil_lo, sil_hi, la) + smoothstep(sil_lo, sil_hi, lb));
		float sil = clamp(cov * 0.5, 0.0, 1.0);
		float lapmax = max(max(lh, lv), max(la, lb) * 0.7071);
		float weight = smoothstep(10.0, 60.0, lapmax);
		// second, inner pixel of the pen for the big steps
		float j2 = max(max(surf_z(uv + vec2(-2.0 * px.x, 0.0), ip, iv, sea_y), surf_z(uv + vec2(2.0 * px.x, 0.0), ip, iv, sea_y)),
			max(surf_z(uv + vec2(0.0, -2.0 * px.y), ip, iv, sea_y), surf_z(uv + vec2(0.0, 2.0 * px.y), ip, iv, sea_y))) - zc;
		float thick = smoothstep(thick_lo, thick_hi, j2 * inv) * (1.0 - 0.85 * greenish);   // trees: 1-px line only
		sil = max(sil, thick * 0.7);
		weight = max(weight, thick);
		weight *= 1.0 - 0.75 * greenish;              // trees and green hills: own-hue line, no brown pen

		// creases: sharp normal breaks on continuous surfaces only
#if CURRENT_RENDERER == RENDERER_FORWARD_PLUS
		vec3 nc = texture(normal_tex, uv).xyz * 2.0 - 1.0;
		vec3 nr = texture(normal_tex, uv + vec2(px.x, 0.0)).xyz * 2.0 - 1.0;
		vec3 nd = texture(normal_tex, uv + vec2(0.0, px.y)).xyz * 2.0 - 1.0;
		vec3 nl = texture(normal_tex, uv + vec2(-px.x, 0.0)).xyz * 2.0 - 1.0;
		vec3 nu = texture(normal_tex, uv + vec2(0.0, -px.y)).xyz * 2.0 - 1.0;
#else
		vec3 eye = ortho ? vec3(0.0, 0.0, 1.0) : -pc;
		vec3 pl = depth_pos(uv + vec2(-px.x, 0.0), ip);
		vec3 pr = depth_pos(uv + vec2(px.x, 0.0), ip);
		vec3 pu = depth_pos(uv + vec2(0.0, -px.y), ip);
		vec3 pd = depth_pos(uv + vec2(0.0, px.y), ip);
		vec3 pul = depth_pos(uv - px, ip);
		vec3 pdr = depth_pos(uv + px, ip);
		vec3 pur = depth_pos(uv + vec2(px.x, -px.y), ip);
		vec3 pdl = depth_pos(uv + vec2(-px.x, px.y), ip);
		vec3 nc = depth_normal(pc, pl, pr, pu, pd, eye);
		vec3 nr = depth_normal(pr, pc, depth_pos(uv + vec2(2.0 * px.x, 0.0), ip), pur, pdr, eye);
		vec3 nd = depth_normal(pd, pdl, pdr, pc, depth_pos(uv + vec2(0.0, 2.0 * px.y), ip), eye);
		vec3 nl = depth_normal(pl, depth_pos(uv + vec2(-2.0 * px.x, 0.0), ip), pc, pul, pdl, eye);
		vec3 nu = depth_normal(pu, pul, pur, depth_pos(uv + vec2(0.0, -2.0 * px.y), ip), pc, eye);
#endif
		float nb = max(max(1.0 - dot(nc, nr), 1.0 - dot(nc, nd)), max(1.0 - dot(nc, nl), 1.0 - dot(nc, nu)) * 0.5);
		float crease = smoothstep(crease_lo, crease_hi, nb) * (1.0 - smoothstep(4.0, 12.0, abs(lh)));
		crease *= 1.0 - 0.6 * greenish;

		// coast: soft 2-px stroke on land just above the water line
		float coast = 0.0;
		if (wc.y > sea_y && wc.y < sea_y + 0.6) {
			float s_d = smoothstep(sea_y + 0.015, sea_y - 0.03, world_y(uv + vec2(0.0, px.y), ip, iv));
			float s_d2 = smoothstep(sea_y + 0.015, sea_y - 0.03, world_y(uv + vec2(0.0, 2.0 * px.y), ip, iv));
			float s_l = smoothstep(sea_y + 0.015, sea_y - 0.03, world_y(uv + vec2(-px.x, 0.0), ip, iv));
			float s_r = smoothstep(sea_y + 0.015, sea_y - 0.03, world_y(uv + vec2(px.x, 0.0), ip, iv));
			coast = clamp(0.75 * s_d + 0.45 * s_d2 + 0.4 * (s_l + s_r), 0.0, 1.0);
		}

		// wide views keep calm silhouettes only; close-ups get a lighter, not heavier, pen
		float k = clamp(zf, 0.0, 1.0);
		float fade = mix(far_keep, 1.0, smoothstep(0.45, 0.95, k));
		float close_lite = 1.0 - 0.35 * smoothstep(1.3, 3.5, zf);
		float crease_fade = smoothstep(0.55, 0.95, k) * (1.0 - 0.5 * smoothstep(1.3, 3.5, zf));
		float dry = smoothstep(sea_y - 0.05, sea_y + 0.03, wc.y);

		float a = max(sil * sil_alpha * fade * close_lite * mix(small_keep * (1.0 - 0.45 * greenish), 1.0, weight),
			crease * crease_alpha * crease_fade);
		a = clamp(max(a * dry, coast * coast_alpha * fade * close_lite), 0.0, 1.0);

		vec3 warm = vec3(1.0, 0.86, 0.72);
		vec3 deep = mix(ink_color * kf, local * ink_dark * warm, 0.45);
		vec3 soft = local * ink_light * warm;
		vec3 ink = mix(soft, deep, max(weight, coast));
		float pale = smoothstep(0.45, 0.85, ll) * (1.0 - smoothstep(0.12, 0.3, sat));
		ink = mix(ink, pale_ink * min(ll, 1.2) * 0.8, pale * (1.0 - 0.5 * weight));

		// ---------------- 2. painted light (land only)
		vec3 add = vec3(0.0);
		if (wc.y > land_y) {
			vec3 nw = normalize((iv * vec4(normalize(nc), 0.0)).xyz);
			vec3 L = normalize(sun_to);
			float ndl = dot(nw, L);
			float slope = smoothstep(0.1, 0.4, 1.0 - nw.y);
			float lit = smoothstep(0.35, 0.9, ndl) * slope * (1.0 - smoothstep(0.8, 1.6, ll)) * day;
			float shade = (1.0 - smoothstep(0.0, 0.35, ndl)) * slope;
			vec3 chroma = (local - ll) * (1.0 - sat);
			add = lit * lit_gain * (local * lit_tint + lit_chroma * chroma)
				+ shade * shade_chroma * day * day * chroma
				+ (1.0 - slope) * (ndl > L.y ? facet_gain : facet_shade) * (ndl - L.y) * local * day;
			// rock and earth slopes turned away from the sun (mountains, not walls, cliffs, trees
			// or snow) sink toward a deeper warm brown, for the concept's light / shade facets
			float back = (1.0 - smoothstep(-0.05, 0.45, ndl)) * slope * smoothstep(0.15, 0.4, nw.y)
				* (1.0 - greenish) * (1.0 - pale) * day;
			add += local * (back_mul - 1.0) * back * back_strength;
			add = max(local + add, local * 0.6) - local;
		}

		ALBEDO = ink * a + add * (1.0 - a);
		ALPHA = a;
	}
}
