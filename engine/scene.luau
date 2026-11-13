--!nonstrict
-- The laid-out scene the tab draws (pure/CONTRACT.md Â§4): a root's nodes in
-- paint order, each with its box, transform, shape, paints, stroke,
-- effects and text, all resolved. Built from a resolved, laid-out root.

local U = require("./util")
local Text = require("./text")
local Layout = require("./layout")

local M = {}

local function hexa(c: string, opacity: number?): string
	if not opacity or opacity >= 1 then
		return c
	end
	local a = tonumber(string.sub(c, 8, 9), 16) or 255
	return string.sub(c, 1, 7) .. string.format("%02X", math.floor(a * opacity + 0.5))
end

local BLEND_OK = {
	normal = true, darken = true, multiply = true, colorBurn = true, lighten = true, screen = true, colorDodge = true,
	linearDodge = true, overlay = true, softLight = true, hardLight = true, difference = true, exclusion = true,
	hue = true, saturation = true, color = true, luminosity = true,
}

local function paint(v: any, images: any?): any
	if type(v) == "string" then
		local c = U.color(v)
		return if c then { k = "solid", color = c } else nil
	end
	if type(v) ~= "table" then
		return nil
	end
	if v.enabled == false then
		return nil
	end
	local op = if type(v.opacity) == "number" and v.opacity < 1 then U.clamp(v.opacity, 0, 1) else nil
	local blend = if v.blendMode ~= nil and v.blendMode ~= "normal" and BLEND_OK[v.blendMode] then v.blendMode else nil
	if v.type == "color" then
		local c = U.color(v.color)
		return if c then { k = "solid", color = c, op = op, blend = blend } else nil
	elseif v.type == "gradient" then
		local kind = v.gradientType or "linear"
		if kind ~= "linear" and kind ~= "radial" and kind ~= "angular" then
			return nil
		end
		local raw = U.list(v.colors)
		if #raw < 2 then
			return nil
		end
		local stops = {}
		for i, s in raw do
			local even = (i - 1) / math.max(#raw - 1, 1)
			if type(s) == "string" then
				local c = U.color(s)
				if c then
					table.insert(stops, { color = c, pos = even })
				end
			elseif type(s) == "table" then
				local c = U.color(s.color)
				if c then
					table.insert(stops, { color = c, pos = U.clamp(U.num(s.position, even), 0, 1) })
				end
			end
		end
		table.sort(stops, function(a, b)
			return a.pos < b.pos
		end)
		local center = if type(v.center) == "table" then { x = U.num(v.center.x, 0.5), y = U.num(v.center.y, 0.5) } else { x = 0.5, y = 0.5 }
		local size = if type(v.size) == "table" then { w = U.num(v.size.width, 1), h = U.num(v.size.height, 1) } else { w = 1, h = 1 }
		return { k = kind, stops = stops, center = center, size = size, rot = U.num(v.rotation, 0), op = op, blend = blend }
	elseif v.type == "image" then
		local url = if type(v.url) == "string" then v.url else ""
		local src
		if string.match(string.lower(url), "^https?://") then
			src = url
		elseif images and images[url] then
			src = images[url]
		else
			src = "missing:" .. url
		end
		local mode = v.mode
		if mode ~= "contain" and mode ~= "stretch" then
			mode = "cover"
		end
		return { k = "image", src = src, mode = mode, op = op }
	end
	return nil
end

function M.paints(v: any, images: any?): { any }?
	if v == nil then
		return nil
	end
	local out = {}
	for _, p in U.list(v) do
		local x = paint(p, images)
		if x then
			table.insert(out, x)
		end
	end
	return if #out > 0 then out else nil
end

local function stroke(v: any, images: any?): any
	if type(v) ~= "table" then
		return nil
	end
	local fills = M.paints(v.fill, images)
	if not fills then
		return nil
	end
	local t = v.thickness
	local w
	if t == nil then
		w = { 1, 1, 1, 1 }
	elseif type(t) == "number" then
		local x = math.max(t, 0)
		w = { x, x, x, x }
	elseif type(t) == "table" then
		w = { math.max(U.num(t.top, 0), 0), math.max(U.num(t.right, 0), 0), math.max(U.num(t.bottom, 0), 0), math.max(U.num(t.left, 0), 0) }
	else
		return nil
	end
	if w[1] == 0 and w[2] == 0 and w[3] == 0 and w[4] == 0 then
		return nil
	end
	local align = v.align
	if align ~= "center" and align ~= "outside" then
		align = "inside"
	end
	local dash = nil
	if type(v.dashPattern) == "table" and #v.dashPattern > 0 then
		local sum = 0
		for _, d in v.dashPattern do
			sum += U.num(d, 0)
		end
		if sum > 0 then
			dash = v.dashPattern
		end
	end
	return {
		fill = fills,
		w = w,
		align = align,
		join = if v.join == "round" or v.join == "bevel" then v.join else nil,
		cap = if v.cap == "round" or v.cap == "square" then v.cap else nil,
		dash = dash,
	}
end

local function effects(v: any): { any }?
	if v == nil then
		return nil
	end
	local out = {}
	for _, e in U.list(v) do
		if type(e) == "table" and e.enabled ~= false then
			if e.type == "shadow" then
				local off = if type(e.offset) == "table" then e.offset else {}
				table.insert(out, {
					k = "shadow",
					inner = e.shadowType == "inner" or nil,
					x = U.num(off.x, 0),
					y = U.num(off.y, 0),
					blur = math.max(U.num(e.blur, 0), 0),
					spread = U.num(e.spread, 0),
					color = U.color(e.color) or "#00000040",
					blend = if e.blendMode ~= nil and e.blendMode ~= "normal" then e.blendMode else nil,
				})
			elseif e.type == "blur" then
				table.insert(out, { k = "blur", radius = math.max(U.num(e.radius, 0), 0) })
			elseif e.type == "background_blur" then
				table.insert(out, { k = "bgblur", radius = math.max(U.num(e.radius, 0), 0) })
			end
		end
	end
	return if #out > 0 then out else nil
end

local function radii(v: any): { number }
	if type(v) == "number" then
		local r = math.max(v, 0)
		return { r, r, r, r }
	elseif type(v) == "table" and #v == 4 then
		return { math.max(U.num(v[1], 0), 0), math.max(U.num(v[2], 0), 0), math.max(U.num(v[3], 0), 0), math.max(U.num(v[4], 0), 0) }
	end
	return { 0, 0, 0, 0 }
end

local function shape(node: any): any
	local t = node.type
	if t == "frame" or t == "rectangle" then
		return { k = "rect", r = radii(node.cornerRadius) }
	elseif t == "ellipse" then
		return { k = "ellipse", start = U.num(node.startAngle, 0), sweep = U.num(node.sweepAngle, 360), inner = U.num(node.innerRadius, 0) }
	elseif t == "polygon" then
		return { k = "polygon", sides = U.clamp(math.floor(U.num(node.polygonCount, 3)), 3, 64) }
	elseif t == "path" then
		local vb = nil
		if type(node.viewBox) == "table" and #node.viewBox == 4 then
			vb = { x = node.viewBox[1], y = node.viewBox[2], w = node.viewBox[3], h = node.viewBox[4] }
		end
		return { k = "path", d = if type(node.geometry) == "string" then node.geometry else "", vb = vb, rule = if node.fillRule == "evenodd" then "evenodd" else "nonzero" }
	end
	return nil
end

local function mul(m: { number }, n: { number }): { number }
	-- m âˆ˜ n, as {a,b,c,d,e,f}
	return {
		m[1] * n[1] + m[3] * n[2],
		m[2] * n[1] + m[4] * n[2],
		m[1] * n[3] + m[3] * n[4],
		m[2] * n[3] + m[4] * n[4],
		m[1] * n[5] + m[3] * n[6] + m[5],
		m[2] * n[5] + m[4] * n[6] + m[6],
	}
end

-- The node's own local transform (rotation about its top-left, flips).
local function own(node: any, w: number, h: number): { number }?
	local rot = U.num(node.rotation, 0)
	local fx, fy = node.flipX == true, node.flipY == true
	if rot == 0 and not fx and not fy then
		return nil
	end
	-- Skia's rotate(âˆ’rot): positive rot turns counter-clockwise on screen.
	local a = math.rad(-rot)
	local m = { math.cos(a), math.sin(a), -math.sin(a), math.cos(a), 0, 0 }
	if fx or fy then
		local sx, sy = if fx then -1 else 1, if fy then -1 else 1
		m = mul(m, { 1, 0, 0, 1, w / 2, h / 2 })
		m = mul(m, { sx, 0, 0, sy, 0, 0 })
		m = mul(m, { 1, 0, 0, 1, -w / 2, -h / 2 })
	end
	return m
end

local function icon_color(fill: any): string
	for _, p in U.list(fill) do
		local x = paint(p, nil)
		if x and x.k == "solid" then
			return hexa(x.color, x.op)
		end
	end
	return "#000000FF"
end

-- Items of a laid-out resolved root, in paint order. `opts.images`: image
-- url â†’ src; `opts.icons`: function(name, weight) â†’ {d, vb} or nil.
function M.items(root: any, opts: any?): { any }
	opts = opts or {}
	local out = {}
	local function visit(node: any, parent: any?, depth: number, pm: { number }?, pbox: any?)
		local b = node.__box
		if not b then
			return
		end
		local item: any = { id = node.id, p = if parent then parent.id else nil, d = depth, t = node.type, name = node.name, box = { x = b.x, y = b.y, w = b.w, h = b.h } }
		if node.__inst then
			item.inst = node.__inst
		end
		-- transform chain
		local m = nil
		local o = own(node, b.w, b.h)
		if pm or o then
			local base = pm
			local at
			if base then
				at = mul(base, { 1, 0, 0, 1, b.x - pbox.x, b.y - pbox.y })
			else
				at = { 1, 0, 0, 1, b.x, b.y }
			end
			m = if o then mul(at, o) else at
			item.xf = { a = m[1], b = m[2], c = m[3], d = m[4], e = m[5], f = m[6] }
		end
		if U.num(node.rotation, 0) ~= 0 then
			item.rot = node.rotation
		end
		local opacity = U.num(node.opacity, 1)
		if opacity < 1 then
			item.op = U.clamp(opacity, 0, 1)
		end
		local t = node.type
		if t == "frame" and node.clip == true then
			item.clip = true
		end
		if t == "frame" and (node.layout == "horizontal" or node.layout == "vertical") then
			item.lay = node.layout
		end
		if node.absolute == true then
			item.abs = true
		end
		local sh = shape(node)
		if sh then
			item.shape = sh
			item.fill = M.paints(node.fill, opts.images)
			item.stroke = stroke(node.stroke, opts.images)
			item.fx = effects(node.effect)
		end
		if t == "text" then
			local st = node.__style or Text.style(node)
			-- wrap at its box when its growth wraps
			local wrap = if Layout.growth(node) ~= "auto" then b.w else nil
			local _, th = Text.measure(st, wrap)
			item.text = {
				s = st.s, font = st.font, size = st.size, weight = st.weight, italic = st.italic,
				lh = st.lh, ls = st.ls, wrap = wrap,
				align = if node.textAlign == "center" or node.textAlign == "right" or node.textAlign == "justify" then node.textAlign else "left",
				valign = if node.textAlignVertical == "middle" or node.textAlignVertical == "bottom" then node.textAlignVertical else "top",
				under = node.underline == true or nil, strike = node.strikethrough == true or nil,
				th = th,
			}
			item.fill = M.paints(node.fill, opts.images)
		elseif t == "icon" then
			local name = if type(node.icon) == "string" then node.icon else ""
			item.icon = { name = name, weight = node.weight, color = icon_color(node.fill) }
			if opts.icons then
				local got = opts.icons(name, node.weight)
				if got then
					item.icon.vb = got.vb
					item.icon.parts = got.parts
				end
			end
		end
		if node.reusable == true then
			item.comp = true
		end
		if node.locked == true then
			item.lock = true
		end
		if node.inProgress == true then
			item.wip = true
			if type(node.inProgressBy) == "string" then
				item.by = node.inProgressBy
			end
		end
		item.prob = node.__prob
		table.insert(out, item)
		local at = #out
		for _, c in (node.children or {}) do
			visit(c, node, depth + 1, m, b)
		end
		item.n = #out - at
	end
	visit(root, nil, 0, nil, nil)
	return out
end

return M
