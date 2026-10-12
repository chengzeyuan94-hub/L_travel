extends RefCounted
## Act 4 loop: stable 32-bit hashing shared by the clock and the postcard text picker.
## Pure integer maths (no RandomNumberGenerator, no String.hash()) so the same seed gives the
## same journey on every Godot version and every machine. All values stay non-negative.

const M32: int = 0xFFFFFFFF


## Low 32 bits of a * b without relying on 64-bit overflow behaviour.
static func mul32(a: int, b: int) -> int:
	var x: int = a & M32
	var y: int = b & M32
	var lo: int = x * (y & 0xFFFF)
	var hi: int = ((x * (y >> 16)) & 0xFFFF) << 16
	return (lo + hi) & M32


## murmur3 fmix32 finaliser.
static func fmix(h0: int) -> int:
	var h: int = h0 & M32
	h = h ^ (h >> 16)
	h = mul32(h, 0x85EBCA6B)
	h = h ^ (h >> 13)
	h = mul32(h, 0xC2B2AE35)
	h = h ^ (h >> 16)
	return h


## hash(a, b, c) -> [0, 2^32).
static func hash3(a: int, b: int, c: int) -> int:
	var h: int = fmix((a & M32) ^ 0x9E3779B9)
	h = fmix(h ^ fmix(((b & M32) + 0x7F4A7C15) & M32))
	h = fmix(h ^ fmix(((c & M32) + 0x2545F491) & M32))
	return h


## Uniform float in [0, 1).
static func unit(a: int, b: int, c: int) -> float:
	return float(hash3(a, b, c)) / 4294967296.0


## Uniform int in [lo, hi] (inclusive).
static func range_i(a: int, b: int, c: int, lo: int, hi: int) -> int:
	if hi <= lo:
		return lo
	var span: int = hi - lo + 1
	return lo + mini(span - 1, int(floor(unit(a, b, c) * float(span))))


## FNV-1a over UTF-8 bytes: stable string hash for ranking places / tiles independent of pool order.
static func str_hash(s: String) -> int:
	var h: int = 0x811C9DC5
	for byte: int in s.to_utf8_buffer():
		h = mul32(h ^ byte, 0x01000193)
	return h
