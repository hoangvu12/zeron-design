--!nonstrict
-- The laid-out scene the tab draws (pure/CONTRACT.md Â§4): a root's nodes in
-- paint order, each with its box, transform, shape, paints, stroke,
-- effects and text, all resolved. Built from a resolved, laid-out root.

local U = require("./util")
local Text = require("./text")
local Layout = require("./layout")
local Proto = require("./proto")
local Resolve = require("./resolve")
local Expr = require("./expr")

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
		-- (GIF layers, pure/anim/f7/gif: Play plays a `gif` paint; the board
		-- shows its first frame. Known from the stored picture's type, or a
		-- web url's `.gif`; "\0gif\0" is engine/images.luau's M.GIF.)
		local gif = (images and images["\0gif\0" .. url] == true)
			or (string.sub(src, 1, 4) ~= "img:" and string.match(string.lower(url), "%.gif$") ~= nil)
			or (string.sub(src, 1, 4) ~= "img:" and string.match(string.lower(url), "%.gif[%?#]") ~= nil)
		return { k = "image", src = src, mode = mode, op = op, gif = if gif then true else nil }
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
	local drivers = {}
	local function visit(node: any, parent: any?, depth: number, pm: { number }?, pbox: any?)
		local b = node.__box
		if not b then
			return
		end
		local item: any = { id = node.id, p = if parent then parent.id else nil, d = depth, t = node.type, name = node.name, box = { x = b.x, y = b.y, w = b.w, h = b.h } }
		if node.__inst then
			item.inst = node.__inst
			-- (step 4) the variant set it shows a member of
			local set = opts.vsets and opts.vsets[node.__inst]
			if set then
				item.vset = set
				-- (shown by Play's variant state: the member the Design has)
				if node.__ref0 then
					item.vdef = node.__ref0
				end
			end
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
			-- (N7) `flow`: what the Canvas's spacing handles show and change:
			-- gap `g`, padding `p` {t, r, b, l}, `j` justify, `a` align, `hug`
			-- bits (1 width, 2 height hug their children).
			local p = node.padding
			local t, r, bb, l = 0, 0, 0, 0
			if type(p) == "number" then
				t, r, bb, l = p, p, p, p
			elseif type(p) == "table" then
				if #p == 2 then
					t, bb, l, r = p[1], p[1], p[2], p[2]
				elseif #p == 4 then
					t, r, bb, l = p[1], p[2], p[3], p[4]
				elseif #p >= 1 then
					t, r, bb, l = p[1], p[1], p[1], p[1]
				end
			end
			local function nz(v: any): number
				return if type(v) == "number" then v else 0
			end
			local sz = Layout.sizing(node)
			local hug = (if sz[1] == "fit" then 1 else 0) + (if sz[2] == "fit" then 2 else 0)
			item.flow = {
				g = nz(node.gap),
				p = { nz(t), nz(r), nz(bb), nz(l) },
				j = if type(node.justifyContent) == "string" then node.justifyContent else nil,
				a = if type(node.alignItems) == "string" then node.alignItems else nil,
				hug = if hug > 0 then hug else nil,
			}
		end
		-- (N7) in a flow: which axes it fills (1 width, 2 height)
		if parent and node.absolute ~= true and (parent.layout == "horizontal" or parent.layout == "vertical") and parent.type == "frame" then
			local sz = Layout.sizing(node)
			local fl = (if sz[1] == "fill" then 1 else 0) + (if sz[2] == "fill" then 2 else 0)
			if fl > 0 then
				item.fl = fl
			end
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
		if type(node.interactions) == "table" then
			item.ia = M.ia(node, opts.screens, opts.vsets)
			-- (step 5, V3) a Change to carries its target member's props
			-- (`vp`, text): on an Instance bound to variables, Play writes
			-- them (two-way). `opts.vprops` = { [member id] = props }.
			if item.ia and opts.vprops then
				local function mark(list: any)
					for _, a in list or {} do
						if a.k == "changeTo" and a.to and opts.vprops[a.to] then
							a.vp = opts.vprops[a.to]
						elseif a.k == "if" then
							mark(a.th)
							mark(a.el)
						end
					end
				end
				for _, e in item.ia do
					mark(e.acts)
				end
			end
			-- (step 5) the modes pinned on it or a parent: a set writes the
			-- variable's value for those modes (engine/vars.luau)
			if item.ia and type(node.__pin) == "table" and next(node.__pin) ~= nil then
				item.th = node.__pin
			end
		end
		-- (step 5) an Instance whose variant properties are bound to variables:
		-- { [prop] = token name } (a Change to on it writes them, two-way)
		if node.__vb then
			item.vb = node.__vb
			if not item.th and type(node.__pin) == "table" and next(node.__pin) ~= nil then
				item.th = node.__pin
			end
		end
		-- overlays (step 2): a top-level frame's overlay settings
		if depth == 0 and t == "frame" and type(node.overlay) == "table" then
			item.ovl = Proto.played_overlay(node.overlay)
		end
		table.insert(out, item)
		if type(node.states) == "table" then
			table.insert(drivers, { at = #out, node = node })
		end
		local at = #out
		for _, c in (node.children or {}) do
			visit(c, node, depth + 1, m, b)
		end
		item.n = #out - at
		-- scrolling (step 2): how it scrolls, and how big its content is
		if t == "frame" and Proto.OVERFLOW[node.overflow] then
			item.ovf = node.overflow
			local cw, ch = Proto.content_extent(node)
			item.cx = { w = cw, h = ch }
		end
		if node.scroll == "fixed" or node.scroll == "sticky" then
			item.scr = node.scroll
		end
		-- Smart Animate (step 3): a match key over the name path
		if type(node.match) == "string" and node.match ~= "" then
			item.mt = node.match
		elseif node.match == false then
			item.mt = false
		end
	end
	visit(root, nil, 0, nil, nil)
	for _, dv in drivers do
		M.states_of(out, dv.at, dv.node, opts.images)
	end
	return out
end

-- ── prototypes (CONTRACT Changes 2026-11-14) ─────────────────────────────

-- One action as the tab plays it: { k = <action kind>, … } (CONTRACT
-- Changes, step 2). nil for what the tab can't run.
function M.act_of(a: any, screens: any?, vsets: any?): any?
	if type(a) ~= "table" then
		return nil
	end
	local kind = a.action
	if kind == "navigate" then
		local e: any = { k = "navigate", go = a.to, tr = Proto.played(a.transition) }
		if screens and not screens[a.to] then
			e.broken = true
		end
		if a.resetScroll == true then
			e.rs = true
		end
		if a.resetComponents == true then
			e.rc = true
		end
		return e
	elseif kind == "changeTo" then
		-- (step 4) { k, to = member id, set, tr }; broken when `to` is in no set
		local e: any = { k = "changeTo", to = a.to, tr = Proto.played(a.transition) }
		e.set = vsets and vsets[a.to]
		if not e.set then
			e.broken = true
		end
		return e
	elseif kind == "scrollTo" then
		return Proto.played_scroll(a)
	elseif kind == "back" then
		local e: any = { k = "back" }
		if type(a.transition) == "table" then
			e.tr = Proto.played(a.transition)
		end
		return e
	elseif kind == "url" then
		local e: any = { k = "url", url = a.url }
		if a.newTab == false then
			e.nt = false
		end
		return e
	elseif kind == "motion" then
		return { k = "motion", play = a.play }
	elseif kind == "overlay" or kind == "swap" or kind == "close" then
		-- (overlays, step 2: frame settings come on the overlay's root item, `ovl`)
		local e = Proto.played_overlay_act(a)
		if e.go and screens and not screens[e.go] then
			e.broken = true
		end
		return e
	elseif kind == "set" or kind == "toggle" then
		-- (step 5) { k = "set", var, to = literal } or { k = "set", var, ex =
		-- expression source } (Vars.run_set runs either); a toggle is a set of
		-- `not var` marked tg
		if type(a.var) ~= "string" then
			return nil
		end
		if kind == "toggle" then
			return { k = "set", var = a.var, ex = "not " .. Expr.var_src(a.var), tg = true }
		end
		local inner = Expr.inner(a.to)
		if inner then
			return { k = "set", var = a.var, ex = inner }
		end
		local ref = Resolve.reference(a.to)
		if ref then
			return { k = "set", var = a.var, ex = Expr.var_src(ref) }
		end
		return { k = "set", var = a.var, to = a.to }
	elseif kind == "mode" then
		if type(a.axis) ~= "string" or a.value == nil then
			return nil
		end
		return { k = "mode", axis = a.axis, value = tostring(a.value) }
	elseif kind == "if" then
		-- { k = "if", cond = expression source, th = { acts }, el = { acts } }
		local cond = if type(a.cond) == "string" then (Expr.inner(a.cond) or a.cond) else nil
		if not cond then
			return nil
		end
		local function acts(list)
			local out = {}
			for _, x in U.list(list) do
				local e = M.act_of(x, screens, vsets)
				if e then
					table.insert(out, e)
				end
			end
			return out
		end
		return { k = "if", cond = cond, th = acts(a["then"]), el = acts(a["else"]) }
	end
	return nil
end

-- A node's reactions as the tab plays them, one per reaction: its trigger
-- (`on`, with `ms` for a delay and `keys` for a key combo), every action
-- in order (`acts`), and its first navigate/back/url action spelled out on
-- the entry itself (go/url/nt/tr/broken, as in step 1: noodles, hotspots).
-- screens: id → name (broken links).
function M.ia(node: any, screens: any?, vsets: any?): { any }?
	local out = {}
	for _, r in U.list(node.interactions) do
		if type(r) ~= "table" then
			continue
		end
		local t = r.trigger
		local e: any = { on = Proto.trigger_name(t), acts = {} }
		if type(t) == "table" then
			if e.on == "afterDelay" then
				e.ms = U.num(t.ms, 0)
			elseif Proto.MOUSE_DELAY[e.on] and type(t.delay) == "number" and t.delay > 0 then
				e.ms = t.delay
			elseif e.on == "key" then
				e.keys = if type(t.keys) == "string" then { t.keys } else table.clone(t.keys or {})
			end
		end
		local first = nil
		for _, a in U.list(r.actions) do
			local act = M.act_of(a, screens, vsets)
			if act then
				table.insert(e.acts, act)
				if not first and Proto.MOVES[act.k] then
					first = act
				end
			end
		end
		if #e.acts == 0 then
			continue
		end
		if first then
			if first.k == "url" then
				e.url, e.nt = first.url, first.nt
			else
				e.go = if first.k == "back" then "back" else first.go
				e.tr, e.broken = first.tr, first.broken
			end
		end
		if node.__inh_ia then
			e.inh = true
		end
		table.insert(out, e)
	end
	return if #out > 0 then out else nil
end

-- One state's properties as scene values.
local function state_entry(props: any, of: string, s: string, images: any?): any
	local e: any = { of = of, s = s }
	if props.fill ~= nil then
		e.fill = M.paints(props.fill, images) or {}
	end
	if props.stroke ~= nil then
		e.stroke = stroke(props.stroke, images) or false
	end
	if props.effect ~= nil then
		e.fx = effects(props.effect) or {}
	end
	if type(props.opacity) == "number" then
		e.op = U.clamp(props.opacity, 0, 1)
	end
	if props.cornerRadius ~= nil then
		e.r = radii(props.cornerRadius)
	end
	if type(props.scale) == "number" then
		e.sc = U.clamp(props.scale, 0.5, 2)
	end
	return e
end

-- The `st` entries a driver (items[at], `node`) puts on itself and on the
-- items its `descendants` reach, and its `sttr`.
function M.states_of(items: { any }, at: number, node: any, images: any?)
	local driver = items[at]
	local states = node.states
	local tr = if type(states.transition) == "table" then states.transition else {}
	local ease, sp, sp_ms = Proto.played_ease(tr.easing)
	driver.sttr = { ms = sp_ms or U.num(tr.duration, Proto.DEFAULT_STATE_MS), ease = ease, sp = sp }
	if node.__inh_st then
		driver.stinh = true
	end
	local within = table.move(items, at + 1, at + (driver.n or 0), 1, {})
	for _, s in { "hover", "press" } do
		local props = states[s]
		if type(props) == "table" then
			driver.st = driver.st or {}
			table.insert(driver.st, state_entry(props, driver.id, s, images))
			if type(props.descendants) == "table" then
				local keys = {}
				for k in props.descendants do
					table.insert(keys, k)
				end
				table.sort(keys)
				for _, key in keys do
					local sub = props.descendants[key]
					if type(sub) == "table" then
						for _, id in Proto.reach(key, driver.id, within) do
							for _, it in within do
								if it.id == id then
									it.st = it.st or {}
									table.insert(it.st, state_entry(sub, driver.id, s, images))
								end
							end
						end
					end
				end
			end
		end
	end
end

-- The items with driver id's state s applied (press over hover): what
-- a screenshot of that state draws. Changes items in place.
function M.apply_state(items: { any }, id: string, s: string)
	local at = nil
	for i, it in items do
		if it.id == id then
			at = i
			break
		end
	end
	if not at then
		return false
	end
	local driver = items[at]
	local scale = nil
	local order = if s == "press" then { "hover", "press" } else { "hover" }
	for i = at, at + (driver.n or 0) do
		local it = items[i]
		for _, want in order do
			for _, e in (it.st or {}) do
				if e.of == id and e.s == want then
					if e.fill then
						it.fill = if #e.fill > 0 then e.fill else nil
					end
					if e.stroke ~= nil then
						it.stroke = e.stroke or nil
					end
					if e.fx then
						it.fx = if #e.fx > 0 then e.fx else nil
					end
					if e.op then
						it.op = if e.op < 1 then e.op else nil
					end
					if e.r and it.shape and it.shape.k == "rect" then
						it.shape = table.clone(it.shape)
						it.shape.r = e.r
					end
					if e.sc and i == at then
						scale = e.sc
					end
				end
			end
		end
	end
	if scale and scale ~= 1 then
		local b = driver.box
		local cx, cy = b.x + b.w / 2, b.y + b.h / 2
		local S = { scale, 0, 0, scale, cx - scale * cx, cy - scale * cy }
		for i = at, at + (driver.n or 0) do
			local it = items[i]
			local m = if it.xf then { it.xf.a, it.xf.b, it.xf.c, it.xf.d, it.xf.e, it.xf.f } else { 1, 0, 0, 1, it.box.x, it.box.y }
			local r = mul(S, m)
			it.xf = { a = r[1], b = r[2], c = r[3], d = r[4], e = r[5], f = r[6] }
		end
	end
	return true
end

return M
