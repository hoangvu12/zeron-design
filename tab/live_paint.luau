--!strict
-- A paint shown on the board while a colour picker's knob moves (D3), as a
-- drag shows boxes: beside the layer's root (`roots:set_live`, Draw's
-- `live.paints`), no edit sent. The service hears the colour once, on
-- release: one undo step, and the panel and the picker under the pointer
-- aren't built again at every move (they were: each move was an edit, its
-- answer rebuilt the panel, and the picker it held lost the drag).
--
-- The live state carries its root's `v`: when the edit's answer replaces
-- the root (a new v), Draw leaves the preview out by itself.
--
--   LivePaint.show(roots, id, "fill" | "stroke", file_paints, i, "#RRGGBB[AA]") -> boolean
--   LivePaint.clear(roots, id)

local M = {}

-- "#RGB", "#RRGGBB", "#RRGGBBAA" (any case) to the scene's "#rrggbbaa".
function M.scene_color(hex: string): string?
	if type(hex) ~= "string" or string.sub(hex, 1, 1) ~= "#" then
		return nil
	end
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

-- Where the file's paint `i` lands in the scene's list: the paints before it
-- that the scene draws (a hidden one, `enabled = false`, it leaves out).
function M.scene_index(file_paints: { any }, i: number): number
	local n = 1
	for k = 1, i - 1 do
		local p = file_paints[k]
		if not (type(p) == "table" and p.enabled == false) then
			n += 1
		end
	end
	return n
end

-- (Where a layer's root and item are: kept from the last look, as a drag
-- asks for the same layer at every move.)
local last: { id: string?, ri: number?, k: number?, root: any } = { id = nil, ri = nil, k = nil, root = nil }

local function locate(roots: any, id: string): (number?, number?, any)
	local list = roots:peek()
	if last.id == id and last.ri and list[last.ri] == last.root then
		return last.ri, last.k, last.root
	end
	for ri, r in list do
		for k, it in r.nodes or {} do
			if it.id == id then
				last.id, last.ri, last.k, last.root = id, ri, k, r
				return ri, k, r
			end
		end
	end
	return nil, nil, nil
end

local function with_paint(list: { any }?, at: number, color: string): { any }
	local out = table.clone(list or {})
	-- (the release's edit writes the paint as a plain colour: no opacity or
	-- blend of the old one)
	out[math.clamp(at, 1, #out + 1)] = { k = "solid", color = color }
	return out
end

-- Shows `hex` as paint `i` of layer `id`'s fill or stroke. False when the
-- layer isn't on the board, or the paint can't be shown this way.
function M.show(roots: any, id: string, key: string, file_paints: { any }, i: number, hex: string): boolean
	local color = M.scene_color(hex)
	if not color then
		return false
	end
	local ri, k, root = locate(roots, id)
	if not ri or not k or not root then
		return false
	end
	local it = root.nodes[k]
	local at = M.scene_index(file_paints, i)
	local patch: any = {}
	if key == "fill" then
		if it.icon then
			-- (an icon takes one colour, its fill's)
			local icon = table.clone(it.icon)
			icon.color = color
			patch.icon = icon
		else
			patch.fill = with_paint(it.fill, at, color)
		end
	elseif key == "stroke" then
		if type(it.stroke) ~= "table" then
			return false
		end
		local stroke = table.clone(it.stroke)
		stroke.fill = with_paint(it.stroke.fill, at, color)
		patch.stroke = stroke
	else
		return false
	end
	local held = roots:live_at(ri)
	local paints: { [string]: any } = {}
	if type(held) == "table" and held.paints and held.v == root.v then
		paints = table.clone(held.paints)
	end
	paints[id] = patch
	roots:set_live(ri, { paints = paints, v = root.v })
	return true
end

-- Takes layer `id`'s preview off the board (an edit that didn't land).
function M.clear(roots: any, id: string)
	local ri, _, root = locate(roots, id)
	if not ri then
		return
	end
	local held = roots:live_at(ri)
	if type(held) == "table" and held.paints and held.paints[id] then
		local paints = table.clone(held.paints)
		paints[id] = nil
		roots:set_live(ri, if next(paints) == nil then false else { paints = paints, v = root.v })
	end
end

return M
