--!nonstrict
-- Text measured as native's Typesetter measures it (crates/design/src/skia.rs),
-- with zeron.measure_text (zgx's shaper) underneath:
--   - one line per paragraph without a wrap width: as wide as its widest
--     line, rounded up to a whole pixel; wrapped: exactly the width given;
--   - each line `lineHeight Ã— size` tall when set, else the font's own
--     (hhea ascent âˆ’ descent + line gap, as Skia reads a font without
--     USE_TYPO_METRICS; the typo metrics when it has it);
--   - families the engine doesn't have draw in Geist, as native's bundled
--     default (it disables font fallback).

local M = {}

M.DEFAULT_FAMILY = "Geist"
M.DEFAULT_SIZE = 14

-- The font's own line height, as a multiple of its size, by family (lower
-- case). From the font files (pure/tools/fontmetrics.py).
M.natural = {
	geist = 1.3,
	["geist mono"] = 1.3,
	["instrument serif"] = 1.3,
	georgia = 2327 / 2048,
	arial = 2355 / 2048,
	["segoe ui"] = 2724 / 2048,
}

-- Families measure_text can shape (system fonts by name, plus the app's
-- and the plugin's): others fall back to Geist. Filled by `known`.
M.families = {
	geist = "Geist",
	["geist mono"] = "Geist Mono",
	["instrument serif"] = "Instrument Serif",
	georgia = "Georgia",
	arial = "Arial",
	["segoe ui"] = "Segoe UI",
	["times new roman"] = "Times New Roman",
	["courier new"] = "Courier New",
	verdana = "Verdana",
	tahoma = "Tahoma",
	impact = "Impact",
}

function M.known(family: string, natural: number?)
	M.families[string.lower(family)] = family
	if natural then
		M.natural[string.lower(family)] = natural
	end
end

-- The family a text draws in, and whether it fell back.
function M.family(name: any): (string, boolean)
	if type(name) ~= "string" or name == "" then
		return M.DEFAULT_FAMILY, false
	end
	local f = M.families[string.lower(name)]
	if f then
		return f, false
	end
	return M.DEFAULT_FAMILY, true
end

function M.weight(w: any): number
	if type(w) == "number" then
		return math.clamp(math.floor(w + 0.5), 1, 1000)
	elseif w == "bold" then
		return 700
	elseif type(w) == "string" then
		return tonumber(w) or 400
	end
	return 400
end

-- A text node's style, resolved: { s, font, size, weight, italic, lh, ls, fell }.
function M.style(node: any): any
	local font, fell = M.family(node.fontFamily)
	local size = node.fontSize
	if type(size) ~= "number" or size <= 0 then
		size = M.DEFAULT_SIZE
	end
	local lh
	if type(node.lineHeight) == "number" and node.lineHeight > 0 then
		lh = node.lineHeight * size
	else
		lh = (M.natural[string.lower(font)] or 1.3) * size
	end
	-- Skia's paragraph rounds each line's height to a whole pixel
	-- (measured against native: 13 px Ã— 1.4 = 18.2 lays out as 18).
	lh = math.floor(lh + 0.5)
	return {
		s = if type(node.content) == "string" then node.content else tostring(node.content or ""),
		font = font,
		size = size,
		weight = M.weight(node.fontWeight),
		italic = node.fontStyle == "italic" or nil,
		lh = lh,
		ls = if type(node.letterSpacing) == "number" then node.letterSpacing else 0,
		fell = fell,
	}
end

local measure_text: any = nil
function M.use(fn: any)
	measure_text = fn
end

local cache: { [string]: { number } } = {}
local cached = 0

-- [w, h] of the style at `wrap` (nil: one line per paragraph).
function M.measure(st: any, wrap: number?): (number, number)
	local key = table.concat({ st.s, st.font, st.size, st.weight, tostring(st.italic), st.lh, st.ls, tostring(wrap) }, "\1")
	local hit = cache[key]
	if hit then
		return hit[1], hit[2]
	end
	local w, h
	if st.s == "" then
		w, h = if wrap then wrap else 0, st.lh
	else
		local opts = { font = st.font, size = st.size, weight = st.weight, italic = st.italic, line_height = st.lh, letter_spacing = if st.ls ~= 0 then st.ls else nil }
		if wrap then
			opts.width = math.max(wrap, 0.01)
		end
		-- (A trailing newline is a line of its own in both: zgx counts it as
		-- Skia does, measured on the Stress golden.)
		local mw, mh = measure_text(st.s, opts)
		if wrap then
			w, h = wrap, mh
		else
			-- Up to a whole pixel, as native; zgx's shaper lands a few
			-- thousandths off Skia's: 137.004 where Skia has 137, but 48.009 where Skia has over 48 (goldens: the edge lies between 0.004 and 0.008).
			w, h = math.ceil(mw - 0.006), mh
		end
	end
	if cached > 20000 then
		table.clear(cache)
		cached = 0
	end
	cache[key] = { w, h }
	cached += 1
	return w, h
end

return M
