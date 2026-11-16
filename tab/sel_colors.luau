--!strict
-- (N5) Selection colors, as Figma's: every colour the selection and what's
-- inside it uses (fills, strokes, text and icon colours, gradient stops,
-- shadows), a Token by its name, with how many layers use it, most used
-- first. Changing one changes it on every layer that uses it.
--
-- Pure: no ui. The layers come from the service's `paints` (each layer's
-- `fill`, `stroke`, `effect` as written, Tokens kept, an Instance's insides
-- under their `inst/child` ids).
--
--   SelColors.key(v) -> string?          "$name" or "#rrggbbaa" (nil: not a colour)
--   SelColors.collect(layers) -> { Entry } sorted by count, then key
--   SelColors.swap(layer, key, new) -> props?   what to `update` (nil: unused)
--   SelColors.live_uses(layer, key) -> { { key = "fill"|"stroke", i, paints } }

local M = {}

export type Entry = {
	key: string, -- "$name" or "#rrggbbaa"
	value: string, -- what to show and pick from: "$name" or "#RRGGBB[AA]"
	token: string?, -- the Token's name
	count: number, -- layers that use it
	ids: { string },
}

local function norm_hex(hex: string): string?
	local h = string.lower(string.sub(hex, 2))
	if #h == 3 or #h == 4 then
		h = string.gsub(h, ".", "%0%0")
	end
	if #h == 6 then
		h ..= "ff"
	end
	if #h ~= 8 or string.find(h, "[^0-9a-f]") then
		return nil
	end
	return "#" .. h
end

-- A colour value's key: "$name" for a Token, "#rrggbbaa" for a hex.
function M.key(v: any): string?
	if type(v) ~= "string" then
		return nil
	end
	local c = string.sub(v, 1, 1)
	if c == "$" and #v > 1 then
		return v
	elseif c == "#" then
		return norm_hex(v)
	end
	return nil
end

-- What the panel shows for a key: "$name", or "#RRGGBB" ("#RRGGBBAA" when
-- it isn't opaque).
function M.shown(key: string): string
	if string.sub(key, 1, 1) == "$" then
		return key
	end
	local h = string.upper(string.sub(key, 2))
	return "#" .. (if string.sub(h, 7, 8) == "FF" then string.sub(h, 1, 6) else h)
end

local function list(v: any): { any }
	if v == nil then
		return {}
	end
	if type(v) == "table" and v[1] ~= nil then
		return v
	end
	if type(v) == "table" and next(v) == nil then
		return {}
	end
	return { v }
end

local function hidden(p: any): boolean
	return type(p) == "table" and p.enabled == false
end

-- Every colour a paint list holds: visit(value) for each, hidden paints left out.
local function each_in_paints(paints: any, visit: (v: any) -> ())
	for _, p in list(paints) do
		if type(p) == "string" then
			visit(p)
		elseif type(p) == "table" and not hidden(p) then
			if p.type == "color" or (p.type == nil and p.color ~= nil) then
				visit(p.color)
			elseif p.type == "gradient" then
				for _, s in list(p.colors) do
					if type(s) == "table" then
						visit(s.color)
					end
				end
			end
		end
	end
end

local function each_color(layer: any, visit: (v: any) -> ())
	each_in_paints(layer.fill, visit)
	if type(layer.stroke) == "table" then
		each_in_paints(layer.stroke.fill, visit)
	end
	for _, e in list(layer.effect) do
		if type(e) == "table" and e.type == "shadow" and e.enabled ~= false then
			visit(e.color or "#00000040")
		end
	end
end

-- The selection's colours, most used first (by layers, then by key).
function M.collect(layers: { any }): { Entry }
	local by: { [string]: Entry } = {}
	local out: { Entry } = {}
	for _, layer in layers do
		local here: { [string]: boolean } = {}
		each_color(layer, function(v: any)
			local k = M.key(v)
			if not k or here[k] then
				return
			end
			here[k] = true
			local e = by[k]
			if not e then
				local tok = if string.sub(k, 1, 1) == "$" then string.sub(k, 2) else nil
				e = { key = k, value = M.shown(k), token = tok, count = 0, ids = {} }
				by[k] = e
				table.insert(out, e)
			end
			e.count += 1
			table.insert(e.ids, layer.id)
		end)
	end
	table.sort(out, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.key < b.key
	end)
	return out
end

-- A paint list with `key` swapped for `new`: (the list, whether it changed).
local function swap_paints(paints: any, key: string, new: string): (any, boolean)
	local changed = false
	local l = list(paints)
	local out = table.clone(l)
	for i, p in l do
		if type(p) == "string" then
			if M.key(p) == key then
				out[i] = new
				changed = true
			end
		elseif type(p) == "table" and not hidden(p) then
			if (p.type == "color" or (p.type == nil and p.color ~= nil)) and M.key(p.color) == key then
				local np = table.clone(p)
				np.color = new
				out[i] = np
				changed = true
			elseif p.type == "gradient" and type(p.colors) == "table" then
				local stops = table.clone(list(p.colors))
				local any = false
				for si, s in stops do
					if type(s) == "table" and M.key(s.color) == key then
						local ns = table.clone(s)
						ns.color = new
						stops[si] = ns
						any = true
					end
				end
				if any then
					local np = table.clone(p)
					np.colors = stops
					out[i] = np
					changed = true
				end
			end
		end
	end
	if not changed then
		return paints, false
	end
	-- (written back as it was: one paint not in a list stays one)
	if type(paints) ~= "table" or paints[1] == nil then
		return out[1], true
	end
	return out, true
end

-- The props to `update` on `layer` so `key` reads `new`; nil when it
-- doesn't use `key`.
function M.swap(layer: any, key: string, new: string): { [string]: any }?
	local props: { [string]: any } = {}
	local f, fc = swap_paints(layer.fill, key, new)
	if fc then
		props.fill = f
	end
	if type(layer.stroke) == "table" then
		local s, sc = swap_paints(layer.stroke.fill, key, new)
		if sc then
			local st = table.clone(layer.stroke)
			st.fill = s
			props.stroke = st
		end
	end
	if layer.effect ~= nil then
		local l = list(layer.effect)
		local out = table.clone(l)
		local any = false
		for i, e in l do
			if type(e) == "table" and e.type == "shadow" and e.enabled ~= false and M.key(e.color or "#00000040") == key then
				local ne = table.clone(e)
				ne.color = new
				out[i] = ne
				any = true
			end
		end
		if any then
			props.effect = if type(layer.effect) == "table" and layer.effect[1] ~= nil then out else out[1]
		end
	end
	return if next(props) ~= nil then props else nil
end

-- Where `key` is a solid paint the board can show live (live_paint.luau):
-- the fill or stroke list and the paint's index in it. (Gradient stops and
-- shadows change on release only.)
function M.live_uses(layer: any, key: string): { { key: string, i: number, paints: { any } } }
	local out = {}
	local function scan(k: string, paints: any)
		local l = list(paints)
		for i, p in l do
			local v = if type(p) == "string" then p elseif type(p) == "table" and not hidden(p) and (p.type == "color" or (p.type == nil and p.color ~= nil)) then p.color else nil
			if v ~= nil and M.key(v) == key then
				table.insert(out, { key = k, i = i, paints = l })
			end
		end
	end
	scan("fill", layer.fill)
	if type(layer.stroke) == "table" then
		scan("stroke", layer.stroke.fill)
	end
	return out
end

return M
