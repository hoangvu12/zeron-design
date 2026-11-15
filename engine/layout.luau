--!nonstrict
-- The layout pass, ported line for line from native crates/design/src/layout.rs:
-- each node's box on the Canvas from its sizes and its parent's layout, and
-- the problems an agent should hear of. Runs on the resolved tree
-- (resolve.luau). Widths settle before heights, so text wraps at the width
-- it gets.

local Text = require("./text")

local M = {}

M.FILL_FALLBACK = 100
local EPSILON = 0.01

local FIT, FILL = "fit", "fill"

local function sizing_of(v: any, default: any): any
	if type(v) == "number" then
		if v >= 0 and v == v then
			return v
		end
		return default
	elseif v == "fit_content" then
		return FIT
	elseif v == "fill_container" then
		return FILL
	end
	return default
end

-- The text's growth: its textGrowth, or what its sizes imply.
local function growth(node: any): string
	local g = node.textGrowth
	if g == "auto" then
		return "auto"
	elseif g == "fixed_width" or g == "fixed-width" then
		return "fixed_width"
	elseif g == "fixed_width_height" or g == "fixed-width-height" then
		return "fixed_width_height"
	end
	if node.width ~= nil and node.height ~= nil then
		return "fixed_width_height"
	elseif node.width ~= nil then
		return "fixed_width"
	end
	return "auto"
end
M.growth = growth

-- A node's sizes as { w, h }: a number, FIT or FILL.
local function sizing(node: any): { any }
	local s = node.__sizing
	if s then
		return s
	end
	local t = node.type
	if t == "frame" and not node.__broken then
		s = { sizing_of(node.width, FIT), sizing_of(node.height, FIT) }
	elseif t == "text" then
		local g = growth(node)
		if g == "auto" then
			s = { FIT, FIT }
		elseif g == "fixed_width" then
			s = { sizing_of(node.width, FIT), FIT }
		else
			s = { sizing_of(node.width, FIT), sizing_of(node.height, FIT) }
		end
	elseif t == "rectangle" or t == "ellipse" or t == "polygon" or t == "path" or t == "icon" then
		s = { sizing_of(node.width, 0), sizing_of(node.height, 0) }
	else
		s = { 0, 0 }
	end
	node.__sizing = s
	return s
end
M.sizing = sizing

local function padding(node: any): { { number } }
	local p = node.padding
	local t, r, b, l = 0, 0, 0, 0
	if type(p) == "number" then
		t, r, b, l = p, p, p, p
	elseif type(p) == "table" then
		if #p == 1 then
			t, r, b, l = p[1], p[1], p[1], p[1]
		elseif #p == 2 then
			t, b, l, r = p[1], p[1], p[2], p[2]
		elseif #p == 4 then
			t, r, b, l = p[1], p[2], p[3], p[4]
		end
	end
	local n = function(v)
		return if type(v) == "number" then v else 0
	end
	return { { n(l), n(r) }, { n(t), n(b) } }
end

-- How the node lays its children out: the axis (1 row, 2 column) or nil.
local function main_axis(node: any): number?
	if node.type ~= "frame" then
		return nil
	end
	if node.layout == "horizontal" then
		return 1
	elseif node.layout == "vertical" then
		return 2
	end
	return nil
end

local function gap(node: any): number
	return if type(node.gap) == "number" then node.gap else 0
end

local function in_flow(child: any, main: number?): boolean
	return main ~= nil and child.absolute ~= true
end

local function kids(node: any): { any }
	return node.children or {}
end

local function num(v: any): number
	return if type(v) == "number" then v else 0
end

local function largest(list: { number }): number
	local m = 0
	for _, v in list do
		if v > m then
			m = v
		end
	end
	return m
end

local Pass = {}
Pass.__index = Pass

local function text_measure(node: any, width: number?): (number?, number?)
	if node.type ~= "text" then
		return nil, nil
	end
	local st = node.__style
	if not st then
		st = Text.style(node)
		node.__style = st
	end
	local wrap = nil
	if growth(node) ~= "auto" then
		wrap = width
	end
	return Text.measure(st, wrap)
end

function Pass:measure(node: any, width: number?): { number }
	local s = sizing(node)
	local w: number?
	if type(s[1]) == "number" then
		w = s[1]
	elseif s[1] == FIT then
		w = nil
	else
		w = width
	end
	local key = if w == nil then "n" else tostring(w)
	local per = self.measured[node]
	if per then
		local hit = per[key]
		if hit then
			return hit
		end
	else
		per = {}
		self.measured[node] = per
	end
	local content
	if w ~= nil and type(s[2]) == "number" then
		content = { 0, 0 }
	else
		content = self:content(node, s, w)
	end
	local h = if type(s[2]) == "number" then s[2] else content[2]
	local size = { if w ~= nil then w else content[1], h }
	per[key] = size
	return size
end

function Pass:content(node: any, own: { any }, width: number?): { number }
	local tw, th = text_measure(node, width)
	if tw then
		return { tw, th }
	end
	local main = main_axis(node)
	local flow = {}
	for _, c in kids(node) do
		if main == nil or in_flow(c, main) then
			table.insert(flow, c)
		end
	end
	local widths = self:widths(node, main, width, flow)
	local measured = table.create(#flow)
	for i, c in flow do
		measured[i] = self:measure(c, widths[i])
	end
	local size = { 0, 0 }
	local pad = padding(node)
	for axis = 1, 2 do
		local all_fill = #flow > 0
		for _, c in flow do
			if sizing(c)[axis] ~= FILL then
				all_fill = false
				break
			end
		end
		if all_fill and own[axis] == FIT then
			self.fit_around_fill[node] = true
		end
		local extents = table.create(#flow)
		for i, c in flow do
			local e = measured[i][axis]
			if all_fill and e <= 0 then
				e = M.FILL_FALLBACK
			end
			if main == nil then
				e += if axis == 1 then num(c.x) else num(c.y)
			end
			extents[i] = e
		end
		if main == nil then
			size[axis] = largest(extents)
		else
			local children
			if axis == main then
				local sum = 0
				for _, e in extents do
					sum += e
				end
				children = sum + gap(node) * math.max(#extents - 1, 0)
			else
				children = largest(extents)
			end
			size[axis] = children + pad[axis][1] + pad[axis][2]
		end
	end
	return size
end

function Pass:widths(node: any, main: number?, width: number?, children: { any }): { number? }
	local out = table.create(#children)
	if width == nil then
		return out
	end
	local pad = padding(node)
	local inner = math.max(width - pad[1][1] - pad[1][2], 0)
	if main == nil then
		for i, c in children do
			out[i] = math.max(width - num(c.x), 0)
		end
	elseif main == 2 then
		for i in children do
			out[i] = inner
		end
	else
		local fills = 0
		local taken = gap(node) * math.max(#children - 1, 0)
		for _, c in children do
			if sizing(c)[1] == FILL then
				fills += 1
			else
				taken += self:measure(c, nil)[1]
			end
		end
		local share = math.max(inner - taken, 0) / math.max(fills, 1)
		for i in children do
			out[i] = share
		end
	end
	return out
end

local function intersection(a: any, b: any): any
	local x, y = math.max(a.x, b.x), math.max(a.y, b.y)
	local r = math.min(a.x + a.w, b.x + b.w)
	local btm = math.min(a.y + a.h, b.y + b.h)
	return { x = x, y = y, w = math.max(r - x, 0), h = math.max(btm - y, 0) }
end

local function clipped(b: any, v: any): string?
	local right, bottom = b.x + b.w, b.y + b.h
	local vr, vb = v.x + v.w, v.y + v.h
	local outside
	if b.w <= 0 or b.h <= 0 then
		outside = right < v.x or b.x > vr or bottom < v.y or b.y > vb
	else
		outside = right <= v.x or b.x >= vr or bottom <= v.y or b.y >= vb
	end
	if v.w <= 0 or v.h <= 0 or outside then
		return "fully_clipped"
	elseif b.x < v.x - EPSILON or b.y < v.y - EPSILON or right > vr + EPSILON or bottom > vb + EPSILON then
		return "clipped"
	end
	return nil
end

function Pass:place(node: any, ox: number, oy: number, w: number, h: number, visible: any?)
	local b = { x = ox, y = oy, w = w, h = h }
	local problems = nil
	if visible then
		local c = clipped(b, visible)
		if c then
			problems = { c }
		end
	end
	if self.fit_around_fill[node] then
		problems = problems or {}
		table.insert(problems, "fit_around_fill")
	end
	if node.type == "text" then
		local _, th = text_measure(node, w)
		if th and th > h + EPSILON then
			problems = problems or {}
			table.insert(problems, "text_overflow")
		end
	end
	node.__box = b
	node.__prob = problems
	self.count += 1

	local vis = visible
	if node.type == "frame" and node.clip == true then
		vis = if visible then intersection(visible, b) else b
	end
	local main = main_axis(node)
	local flow = {}
	for _, c in kids(node) do
		if in_flow(c, main) then
			table.insert(flow, c)
		else
			local cx, cy = num(c.x), num(c.y)
			local cs = sizing(c)
			local cw = if cs[1] == FILL then math.max(w - cx, 0) else self:measure(c, nil)[1]
			local ch = if cs[2] == FILL then math.max(h - cy, 0) else self:measure(c, cw)[2]
			self:place(c, ox + cx, oy + cy, cw, ch, vis)
		end
	end
	if main then
		self:flow(node, main, ox, oy, w, h, flow, vis)
	end
end

function Pass:flow(node: any, main: number, ox: number, oy: number, w: number, h: number, children: { any }, visible: any?)
	local n = #children
	if n == 0 then
		return
	end
	local cross = 3 - main
	local pad = padding(node)
	local origin = { ox + pad[1][1], oy + pad[2][1] }
	local inner = { math.max(w - pad[1][1] - pad[1][2], 0), math.max(h - pad[2][1] - pad[2][2], 0) }
	local g = gap(node)
	local gaps = g * (n - 1)
	local sizes = table.create(n)
	for i = 1, n do
		sizes[i] = { 0, 0 }
	end
	for axis = 1, 2 do
		local fills = {}
		for i, c in children do
			local s = sizing(c)[axis]
			if s == FILL and axis == main then
				table.insert(fills, i)
				sizes[i][axis] = 0
			elseif s == FILL then
				sizes[i][axis] = inner[axis]
			elseif axis == 1 then
				sizes[i][1] = self:measure(c, nil)[1]
			else
				sizes[i][2] = self:measure(c, sizes[i][1])[2]
			end
		end
		if #fills > 0 then
			local taken = gaps
			for i = 1, n do
				taken += sizes[i][main]
			end
			local share = math.max(inner[main] - taken, 0) / #fills
			for _, i in fills do
				sizes[i][main] = share
			end
		end
	end
	local used = gaps
	for i = 1, n do
		used += sizes[i][main]
	end
	local left = inner[main] - used
	local at, between = 0, g
	local j = node.justifyContent
	if j == "center" then
		at = left / 2
	elseif j == "end" then
		at = left
	elseif j == "space_between" then
		if n > 1 and left > 0 then
			between = g + left / (n - 1)
		end
	elseif j == "space_around" then
		if left > 0 then
			at, between = left / n / 2, g + left / n
		else
			at = left / 2
		end
	end
	local a = node.alignItems
	for i, c in children do
		local cs = sizes[i]
		local free = inner[cross] - cs[cross]
		local pos = { origin[1], origin[2] }
		pos[main] += at
		if a == "center" then
			pos[cross] += free / 2
		elseif a == "end" then
			pos[cross] += free
		end
		self:place(c, pos[1], pos[2], cs[1], cs[2], visible)
		at += cs[main] + between
	end
end

-- Lays out resolved top-level nodes in place: each node gets `__box`
-- ({x,y,w,h}, Canvas) and `__prob`. Returns how many were placed.
function M.run(roots: { any }): number
	local pass = setmetatable({ measured = {}, fit_around_fill = {}, count = 0 }, Pass)
	for _, node in roots do
		local size = pass:measure(node, nil)
		pass:place(node, num(node.x), num(node.y), size[1], size[2], nil)
	end
	return pass.count
end

-- (step 6 P5, pure/anim/f6/PLAN.md) Responsive: top-level frames (Screens)
-- laid out at a window of `w` × `h` instead of their own size, as Figma's
-- Responsive scaling. The root takes the window's width; its height is the
-- window's, unless the Screen is taller (as designed, or its content once
-- re-wrapped at that width): then it keeps that and scrolls. Inside, auto
-- layout, fill and hug do the rest. The format has no constraints (pen.dev
-- has none), so a child outside auto layout keeps its x and y: Figma's
-- default constraints (Left, Top). The nodes are changed in place (resolved
-- copies) and laid out; anything else in `roots` is laid out as usual.
function M.responsive(roots: { any }, w: number, h: number): number
	w, h = math.max(1, w), math.max(1, h)
	local n = 0
	for _, node in roots do
		if node.type == "frame" and not node.__broken then
			node.width = w
			node.__sizing = nil
			n += M.run({ node })
			local b = node.__box
			if b and b.h < h - EPSILON then
				node.height = h
				node.__sizing = nil
				n += M.run({ node })
			end
		else
			n += M.run({ node })
		end
	end
	return n
end

return M
