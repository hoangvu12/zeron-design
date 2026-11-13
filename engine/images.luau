--!nonstrict
-- Image bytes kept in zeron.db (pure/NEEDS.md §2): each picture once, keyed
-- by a fast hash of its bytes (M.key), stored as base64 (zeron.db binds text and
-- numbers). A Design maps each image paint's `url` as written to a key, so
-- its file round-trips while the scene gives the tab `src = "img:<key>"`.
-- Drawing them needs zgx to make a Bitmap from bytes (Q10); until then the
-- tab draws a placeholder for `img:` sources.

local M = {}

local zeron: any = nil
local ready = false
M.MAX_BYTES = 15 * 1024 * 1024

function M.init(z: any)
	zeron = z
end

local function schema()
	if not ready then
		ready = true
		zeron.db.exec([[
CREATE TABLE IF NOT EXISTS images (key TEXT PRIMARY KEY, mime TEXT, w INTEGER, h INTEGER, size INTEGER, data TEXT, at INTEGER);
CREATE TABLE IF NOT EXISTS image_links (did TEXT, url TEXT, key TEXT, PRIMARY KEY (did, url));
]]):await()
	end
end

-- ── base64 ──────────────────────────────────────────────────────────────

local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DEC = {}
for i = 1, 64 do
	DEC[string.byte(ALPHA, i)] = i - 1
end
DEC[string.byte("-")] = 62
DEC[string.byte("_")] = 63

-- Bytes (a string) from base64, or nil when it isn't. Four characters at a
-- time (5 MB in well under a second); `yield` every 1 MB of text.
function M.decode64(s: string, yield: (() -> ())?): string?
	if string.find(s, "[^%w%+/=_%-]") then
		s = string.gsub(s, "%s", "")
	end
	s = string.gsub(s, "=+$", "")
	if string.find(s, "[^%w%+/%-_]") then
		return nil
	end
	local n = #s
	local tail = n % 4
	if tail == 1 then
		return nil
	end
	local whole = n - tail
	local byte, char, D = string.byte, string.char, DEC
	local out = table.create(whole // 16 + 2)
	local k = 0
	-- 16 characters (12 bytes) per step, then the rest 4 at a time
	local big = whole - whole % 16
	for i = 1, big, 16 do
		local a1, a2, a3, a4, b1, b2, b3, b4, c1, c2, c3, c4, d1, d2, d3, d4 = byte(s, i, i + 15)
		local va = D[a1] * 262144 + D[a2] * 4096 + D[a3] * 64 + D[a4]
		local vb = D[b1] * 262144 + D[b2] * 4096 + D[b3] * 64 + D[b4]
		local vc = D[c1] * 262144 + D[c2] * 4096 + D[c3] * 64 + D[c4]
		local vd = D[d1] * 262144 + D[d2] * 4096 + D[d3] * 64 + D[d4]
		k += 1
		out[k] = char(va // 65536, (va // 256) % 256, va % 256, vb // 65536, (vb // 256) % 256, vb % 256,
			vc // 65536, (vc // 256) % 256, vc % 256, vd // 65536, (vd // 256) % 256, vd % 256)
		if yield and i % 1048576 == 1 and i > 1 then
			yield()
		end
	end
	for i = big + 1, whole, 4 do
		local c1, c2, c3, c4 = byte(s, i, i + 3)
		local v1, v2, v3, v4 = D[c1], D[c2], D[c3], D[c4]
		if not (v1 and v2 and v3 and v4) then
			return nil
		end
		local v = v1 * 262144 + v2 * 4096 + v3 * 64 + v4
		k += 1
		out[k] = char(v // 65536, (v // 256) % 256, v % 256)
		if yield and i % 1048576 == 1 and i > 1 then
			yield()
		end
	end
	if tail > 0 then
		local c1, c2, c3 = byte(s, whole + 1, n)
		local v1, v2, v3 = D[c1], D[c2], if c3 then D[c3] else 0
		if not (v1 and v2 and v3) then
			return nil
		end
		local v = v1 * 262144 + v2 * 4096 + v3 * 64
		k += 1
		out[k] = if tail == 2 then char(v // 65536) else char(v // 65536, (v // 256) % 256)
	end
	return table.concat(out)
end

-- ── SHA-256 ─────────────────────────────────────────────────────────────

local K = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
local band, bxor, bnot, rrotate, rshift = bit32.band, bit32.bxor, bit32.bnot, bit32.rrotate, bit32.rshift

-- `yield` (optional) is called every 64 KB, so a long hash can await
-- between parts (a service call has 2 s of work at a time).
function M.sha256(msg: string, yield: (() -> ())?): string
	local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
	local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
	local len = #msg
	local bitlen = len * 8
	local pad = "\128" .. string.rep("\0", (55 - len) % 64)
	msg = msg .. pad .. string.pack(">I4I4", math.floor(bitlen / 4294967296), bitlen % 4294967296)
	local w = table.create(64, 0)
	local unpack = string.unpack
	local k = K
	for chunk = 1, #msg, 64 do
		w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15], w[16] =
			unpack(">I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4", msg, chunk)
		for i = 17, 64 do
			local a, b = w[i - 15], w[i - 2]
			local s0 = bxor(rrotate(a, 7), rrotate(a, 18), rshift(a, 3))
			local s1 = bxor(rrotate(b, 17), rrotate(b, 19), rshift(b, 10))
			w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 4294967296
		end
		local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
		for i = 1, 64 do
			local t1 = (h + bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25)) + bxor(band(e, f), band(bnot(e), g)) + k[i] + w[i]) % 4294967296
			local t2 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22)) + bxor(band(a, b), band(a, c), band(b, c))
			h, g, f, e, d, c, b, a = g, f, e, (d + t1) % 4294967296, c, b, a, (t1 + t2) % 4294967296
		end
		h0, h1, h2, h3 = (h0 + a) % 4294967296, (h1 + b) % 4294967296, (h2 + c) % 4294967296, (h3 + d) % 4294967296
		h4, h5, h6, h7 = (h4 + e) % 4294967296, (h5 + f) % 4294967296, (h6 + g) % 4294967296, (h7 + h) % 4294967296
		if yield and chunk % 65536 == 1 and chunk > 1 then
			yield()
		end
	end
	return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4, h5, h6, h7)
end

-- ── the key: a fast content hash ───────────────────────────────────────

-- Image keys identify content inside this plugin's own database; they
-- needn't resist anyone. M.key(s) is "p1-" .. two independent 31-bit
-- polynomial hashes over `s` taken as little-endian 32-bit words (tail
-- zero-padded), 8 hex digits each, .. #s in hex. A picture's key (M.put)
-- is that over its canonical base64 text, with the length part being the
-- decoded byte count:
--   a = (a * 1000003 + w) mod 2147483647,  b = (b * 999983 + w) mod 2147483629
-- (exact in Luau's doubles: a * K stays under 2^52). Keys are stored, so
-- this definition must never change; a new one gets a new prefix.
local P1, K1, P2, K2 = 2147483647, 1000003, 2147483629, 999983

function M.key(bytes: string, yield: (() -> ())?): string
	local n = #bytes
	local a, b = 1, 7
	local unpack = string.unpack
	local whole = n - n % 32
	local i = 1
	while i <= whole do
		local w1, w2, w3, w4, w5, w6, w7, w8 = unpack("<I4I4I4I4I4I4I4I4", bytes, i)
		a = (a * K1 + w1) % P1; b = (b * K2 + w1) % P2
		a = (a * K1 + w2) % P1; b = (b * K2 + w2) % P2
		a = (a * K1 + w3) % P1; b = (b * K2 + w3) % P2
		a = (a * K1 + w4) % P1; b = (b * K2 + w4) % P2
		a = (a * K1 + w5) % P1; b = (b * K2 + w5) % P2
		a = (a * K1 + w6) % P1; b = (b * K2 + w6) % P2
		a = (a * K1 + w7) % P1; b = (b * K2 + w7) % P2
		a = (a * K1 + w8) % P1; b = (b * K2 + w8) % P2
		i += 32
		if yield and i % 1048576 == 1 then
			yield()
		end
	end
	if i <= n then
		local tail = string.sub(bytes, i) .. string.rep("\0", (4 - (n - i + 1) % 4) % 4)
		for j = 1, #tail, 4 do
			local w = unpack("<I4", tail, j)
			a = (a * K1 + w) % P1
			b = (b * K2 + w) % P2
		end
	end
	return string.format("p1-%08x%08x%x", a, b, n)
end

-- ── what a picture is ───────────────────────────────────────────────────

-- mime, width, height from the bytes' header; nil when not a picture.
function M.sniff(b: string): (string?, number?, number?)
	if string.sub(b, 1, 8) == "\137PNG\r\n\26\n" and #b >= 24 then
		local w, h = string.unpack(">I4I4", b, 17)
		return "image/png", w, h
	end
	if string.sub(b, 1, 6) == "GIF87a" or string.sub(b, 1, 6) == "GIF89a" then
		local w, h = string.unpack("<I2I2", b, 7)
		return "image/gif", w, h
	end
	if string.sub(b, 1, 4) == "RIFF" and string.sub(b, 9, 12) == "WEBP" then
		local kind = string.sub(b, 13, 16)
		if kind == "VP8X" and #b >= 30 then
			local w = string.unpack("<I3", b, 25) + 1
			local h = string.unpack("<I3", b, 28) + 1
			return "image/webp", w, h
		elseif kind == "VP8 " and #b >= 30 then
			local w, h = string.unpack("<I2I2", b, 27)
			return "image/webp", band(w, 0x3fff), band(h, 0x3fff)
		elseif kind == "VP8L" and #b >= 25 then
			local v = string.unpack("<I4", b, 22)
			return "image/webp", band(v, 0x3fff) + 1, band(rshift(v, 14), 0x3fff) + 1
		end
		return "image/webp", nil, nil
	end
	if string.sub(b, 1, 2) == "\255\216" then
		-- JPEG: walk the segments to a start-of-frame
		local i = 3
		while i + 9 <= #b do
			if string.byte(b, i) ~= 0xFF then
				return "image/jpeg", nil, nil
			end
			local marker = string.byte(b, i + 1)
			local seglen = string.unpack(">I2", b, i + 2)
			if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
				local h, w = string.unpack(">I2I2", b, i + 5)
				return "image/jpeg", w, h
			end
			i += 2 + seglen
		end
		return "image/jpeg", nil, nil
	end
	return nil
end

-- The canonical form of base64 text: no whitespace or padding, the URL-safe
-- alphabet mapped to the standard one. Standard encoders give one text per
-- byte string, so this text names the bytes as well as the bytes do.
function M.canonical64(s: string): string
	-- (Plain finds and byte checks: Luau's patterns over a 7 MB string
	-- cost seconds.)
	if string.find(s, "\n", 1, true) or string.find(s, "\r", 1, true) or string.find(s, " ", 1, true) then
		s = string.gsub(s, "%s", "")
	end
	local n = #s
	while n > 0 and string.byte(s, n) == 61 do -- "="
		n -= 1
	end
	if n < #s then
		s = string.sub(s, 1, n)
	end
	if string.find(s, "-", 1, true) or string.find(s, "_", 1, true) then
		s = string.gsub(string.gsub(s, "%-", "+"), "_", "/")
	end
	return s
end

-- Keeps a picture (base64) once; its { key, mime, w, h, size }. The key is
-- M.key over the canonical base64 text, its length part the bytes' count:
-- no full decode (5 MB: ~1.6 s to decode in Luau; keying the text is fast).
function M.put(base64: string): any
	schema()
	local text = M.canonical64(base64)
	-- Only the head is checked (decoded to read the picture's type and size);
	-- a bad character further on makes a picture the window can't decode,
	-- drawn as a placeholder.
	if #text % 4 == 1 then
		error("bad_params: that isn't base64", 0)
	end
	local size = (#text * 3) // 4
	if size > M.MAX_BYTES then
		error("bad_params: a picture is at most 15 MB", 0)
	end
	local head = M.decode64(string.sub(text, 1, 4096))
	if not head then
		error("bad_params: that isn't base64", 0)
	end
	local mime, w, h = M.sniff(head)
	if not mime then
		error("bad_params: that isn't a PNG, JPEG, WebP or GIF", 0)
	end
	local hashed = M.key(text, function()
		zeron.sleep(0):await()
	end)
	local key = string.format("p1-%s%x", string.sub(hashed, 4, 19), size)
	local there = zeron.db.query("SELECT key FROM images WHERE key = ?", { key }):await()[1]
	if not there then
		zeron.db.exec("INSERT INTO images (key, mime, w, h, size, data, at) VALUES (?, ?, ?, ?, ?, ?, ?)", { key, mime, w or 0, h or 0, size, text, os.time() }):await()
	end
	return { key = key, mime = mime, w = w, h = h, size = size }
end

function M.get(key: string): any?
	schema()
	local r = zeron.db.query("SELECT key, mime, w, h, size, data FROM images WHERE key = ?", { key }):await()[1]
	if not r then
		return nil
	end
	-- stored canonical (no padding): padded again for decoders that want it
	local data = r.data .. string.rep("=", (4 - #r.data % 4) % 4)
	return { key = r.key, mime = r.mime, w = r.w, h = r.h, size = r.size, base64 = data }
end

function M.link(did: string, url: string, key: string)
	schema()
	zeron.db.exec("INSERT OR REPLACE INTO image_links (did, url, key) VALUES (?, ?, ?)", { did, url, key }):await()
end

-- url → "img:<key>" for a Design's linked pictures (the scene's `images`).
function M.links(did: string): { [string]: string }
	schema()
	local out = {}
	for _, r in zeron.db.query("SELECT url, key FROM image_links WHERE did = ?", { did }):await() do
		out[r.url] = "img:" .. r.key
	end
	return out
end

-- The image urls a Design names that aren't http(s) and have no picture yet.
function M.missing(doc: any, links: { [string]: string }): { string }
	local out, seen = {}, {}
	local function visit(v)
		if type(v) == "table" then
			if v.type == "image" and type(v.url) == "string" then
				local url = v.url
				if not string.match(string.lower(url), "^https?://") and not links[url] and not seen[url] then
					seen[url] = true
					table.insert(out, url)
				end
			end
			for _, x in v do
				if type(x) == "table" then
					visit(x)
				end
			end
		end
	end
	visit(doc.children)
	table.sort(out)
	return out
end

return M
