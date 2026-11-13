--!nonstrict
-- Google Fonts for families the engine doesn't have (as native's
-- crates/design/src/fonts.rs): the CSS asked with a user agent that gets
-- TTF files, each weight a Design uses fetched whole (`zeron.fetch` with
-- `binary = true`), kept in zeron.db, loaded with `zeron.load_font
-- { base64 }`, and its own line height read from its tables. The windows
-- load the same bytes (`font_get`), so both measure and draw alike.

local Text = require("./text")
local Images = require("./images")

local M = {}

local zeron: any = nil
local ready = false
local loaded: { [string]: boolean } = {} -- key → loaded in this VM
local failed: { [string]: boolean } = {} -- family:weight → no such font (this run)
M.loaded_keys = {} :: { any } -- { key, family, weight } in load order

-- Asked without a browser's user agent, Google names TrueType files (as
-- native does): a browser's (even an old one's) gets WOFF or WOFF2, which
-- zgx's shaper doesn't read. Measured: an old Firefox's agent got WOFF.
local function is_sfnt(bytes: string?): boolean
	if not bytes or #bytes < 4 then
		return false
	end
	local m = string.sub(bytes, 1, 4)
	return m == "\0\1\0\0" or m == "OTTO" or m == "true" or m == "ttcf"
end

function M.init(z: any)
	zeron = z
end

local function schema()
	if not ready then
		ready = true
		zeron.db.exec("CREATE TABLE IF NOT EXISTS fonts (key TEXT PRIMARY KEY, family TEXT, weight INTEGER, italic INTEGER, data TEXT, lh REAL, at INTEGER)"):await()
	end
end

local function snapped(w: number): number
	return math.clamp(math.floor(w / 100 + 0.5) * 100, 100, 900)
end

-- The font's own line height as a multiple of its size, from its bytes:
-- hhea ascent − descent + line gap, or the OS/2 typo metrics when it says
-- to use them (fsSelection bit 7), over unitsPerEm (as Skia reads it).
function M.natural(bytes: string): number?
	if #bytes < 12 then
		return nil
	end
	local n = string.unpack(">I2", bytes, 5)
	local tables = {}
	for i = 0, n - 1 do
		local at = 13 + i * 16
		if at + 15 > #bytes then
			return nil
		end
		local tag = string.sub(bytes, at, at + 3)
		local off = string.unpack(">I4", bytes, at + 8)
		tables[tag] = off + 1
	end
	local head, hhea, os2 = tables["head"], tables["hhea"], tables["OS/2"]
	if not head or not hhea then
		return nil
	end
	local upem = string.unpack(">I2", bytes, head + 18)
	if upem == 0 then
		return nil
	end
	local asc, desc, gap = string.unpack(">i2i2i2", bytes, hhea + 4)
	if os2 then
		local sel = string.unpack(">I2", bytes, os2 + 62)
		if bit32.band(sel, 128) ~= 0 then
			asc, desc, gap = string.unpack(">i2i2i2", bytes, os2 + 68)
		end
	end
	return (asc - desc + gap) / upem
end

local function use(key: string, family: string, weight: number, base64: string, lh: number?)
	if loaded[key] then
		return
	end
	local ok, families = pcall(zeron.load_font, { base64 = base64 })
	if not ok then
		print("font " .. key .. ": " .. tostring(families))
		return
	end
	loaded[key] = true
	for _, f in families do
		Text.known(f, lh)
	end
	Text.known(family, lh)
	table.insert(M.loaded_keys, { key = key, family = family, weight = weight })
end

-- Loads every font kept in the database (once per service run).
local started = false
function M.start()
	if started then
		return
	end
	started = true
	schema()
	-- (Rows that aren't TrueType/OpenType, from before that was checked, go.)
	zeron.db.exec("DELETE FROM fonts WHERE substr(data, 1, 4) NOT IN ('AAEA', 'T1RU', 'dHJ1', 'dHRj')"):await()
	for _, r in zeron.db.query("SELECT key, family, weight, data, lh FROM fonts"):await() do
		use(r.key, r.family, r.weight, r.data, r.lh)
	end
end

-- The @font-face blocks of Google's CSS: { weight, italic, url }.
local function faces(css: string): { any }
	local out = {}
	for block in string.gmatch(css, "@font%-face%s*(%b{})") do
		local weight = tonumber(string.match(block, "font%-weight:%s*(%d+)")) or 400
		local italic = string.match(block, "font%-style:%s*italic") ~= nil
		local url = string.match(block, "src:%s*url%(([^)]+)%)")
		if url then
			table.insert(out, { weight = weight, italic = italic, url = url })
		end
	end
	return out
end

-- Fetches what it doesn't have of `wanted` ({ family → { weights } }).
-- Returns the families it loaded now, and those Google doesn't have.
function M.need(wanted: { [string]: { number } }): ({ string }, { string })
	M.start()
	local now, missing = {}, {}
	for family, weights in wanted do
		local need = {}
		local seen = {}
		for _, w in weights do
			local s = snapped(w)
			local key = string.lower(family) .. ":" .. s
			if not seen[s] and not loaded[key] and not failed[key] then
				seen[s] = true
				table.insert(need, s)
			end
		end
		if #need > 0 then
			table.sort(need)
			local url = "https://fonts.googleapis.com/css2?family=" .. string.gsub(family, " ", "+") .. ":wght@" .. table.concat(need, ";")
			local ok, r = pcall(function()
				return zeron.fetch(url, { timeout = 15 }):await()
			end)
			if ok and r and r.status == 400 then
				-- Not every weight exists: ask for the family as it comes.
				ok, r = pcall(function()
					return zeron.fetch("https://fonts.googleapis.com/css2?family=" .. string.gsub(family, " ", "+"), { timeout = 15 }):await()
				end)
			end
			if not (ok and r and r.status == 200) then
				for _, s in need do
					failed[string.lower(family) .. ":" .. s] = true
				end
				table.insert(missing, family)
				continue
			end
			local any = false
			for _, face in faces(r.body or "") do
				if not face.italic then
					local key = string.lower(family) .. ":" .. face.weight
					if not loaded[key] then
						local okf, f = pcall(function()
							return zeron.fetch(face.url, { binary = true, timeout = 30 }):await()
						end)
						local bytes = if okf and f and f.status == 200 and type(f.body) == "string" then Images.decode64(f.body) else nil
						if is_sfnt(bytes) then
							local lh = bytes and M.natural(bytes)
							zeron.db.exec("INSERT OR REPLACE INTO fonts (key, family, weight, italic, data, lh, at) VALUES (?, ?, ?, 0, ?, ?, ?)", { key, family, face.weight, f.body, lh or 0, os.time() }):await()
							use(key, family, face.weight, f.body, lh)
							any = true
						end
					else
						any = true
					end
				end
			end
			for _, s in need do
				local key = string.lower(family) .. ":" .. s
				if not loaded[key] then
					failed[key] = true
				end
			end
			if any then
				table.insert(now, family)
			else
				table.insert(missing, family)
			end
		end
	end
	return now, missing
end

-- The families and weights resolved text nodes ask for that the engine
-- doesn't have.
function M.wanted(roots: { any }): { [string]: { number } }
	local out = {}
	local function walk(n)
		if n.type == "text" and type(n.fontFamily) == "string" then
			local _, fell = Text.family(n.fontFamily)
			if fell then
				out[n.fontFamily] = out[n.fontFamily] or {}
				table.insert(out[n.fontFamily], Text.weight(n.fontWeight))
			end
		end
		for _, c in (n.children or {}) do
			walk(c)
		end
	end
	for _, r in roots do
		walk(r)
	end
	return out
end

function M.get(key: string): any?
	schema()
	local r = zeron.db.query("SELECT key, family, weight, data FROM fonts WHERE key = ?", { key }):await()[1]
	return r and { key = r.key, family = r.family, weight = r.weight, base64 = r.data }
end

return M
