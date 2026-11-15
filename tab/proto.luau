--!strict
-- Prototyping (pure/anim/proto-step1-spec.md), the parts Play, the panel and
-- the noodles share. Pure: no state, no ui.
--
-- The scene carries (CONTRACT §4, items that have the keys only):
--   ia   = { { on = "click", go = <screen id> | "back" | nil, url?, nt?, tr?, inh?, broken? } }
--          tr = { k, dir?, ms, ease = { x1, y1, x2, y2 } }; a `back` without tr
--          plays the reverse of the way in
--   st   = { { of = <driver id>, s = "hover" | "press", fill?, stroke?, fx?, op?, r?, sc? } }
--          on the item that changes; `of` is the node whose hover/press drives it
--   sttr = { ms, ease } on every driver; stinh = true when inherited
-- and the Design's `flows = { { name, start } }` (scene reply / changed).

local Draw = require("./draw")

local M = {}

M.KINDS = { "instant", "dissolve", "smart", "moveIn", "moveOut", "push", "slideIn", "slideOut" }
M.KIND_LABEL = {
	instant = "Instant",
	dissolve = "Dissolve",
	moveIn = "Move in",
	moveOut = "Move out",
	push = "Push",
	slideIn = "Slide in",
	slideOut = "Slide out",
	smart = "Smart animate",
}
M.DIRECTIONAL = { moveIn = true, moveOut = true, push = true, slideIn = true, slideOut = true }
M.EASINGS = {
	{ name = "linear", label = "Linear", b = { 0, 0, 1, 1 } },
	{ name = "ease-in", label = "Ease in", b = { 0.42, 0, 1, 1 } },
	{ name = "ease-out", label = "Ease out", b = { 0, 0, 0.58, 1 } },
	{ name = "ease-in-out", label = "Ease in and out", b = { 0.42, 0, 0.58, 1 } },
	{ name = "ease-in-back", label = "Ease in back", b = { 0.36, 0, 0.66, -0.56 } },
	{ name = "ease-out-back", label = "Ease out back", b = { 0.34, 1.56, 0.64, 1 } },
	{ name = "ease-in-out-back", label = "Ease in and out back", b = { 0.68, -0.6, 0.32, 1.6 } },
}
M.OPPOSITE = { left = "right", right = "left", up = "down", down = "up" }

-- An easing as stored (a name or { x1, y1, x2, y2 }) as bézier numbers, and
-- the name it has, if any.
function M.bezier_of(e: any): { number }
	if type(e) == "table" and #e == 4 then
		return e
	end
	for _, x in M.EASINGS do
		if x.name == e then
			return x.b
		end
	end
	return { 0, 0, 0.58, 1 }
end
function M.ease_label(e: any): string
	local b = M.bezier_of(e)
	for _, x in M.EASINGS do
		local same = true
		for k = 1, 4 do
			if math.abs(x.b[k] - (b[k] or 0)) > 1e-3 then
				same = false
			end
		end
		if same then
			return x.label
		end
	end
	return "Custom"
end

-- The ease anime and ui.tween take: "cubicBezier(x1, y1, x2, y2)".
function M.ease(b: any): string
	local e = M.bezier_of(b)
	return string.format("cubicBezier(%.4g, %.4g, %.4g, %.4g)", e[1], e[2], e[3], e[4])
end

-- A played transition's (or a driver's `sttr`) ease: its spring as anime's
-- "spring(mass, stiffness, damping, velocity)" (the engine's solver is the
-- same, and `ms` is its settle time, so a tween of `ms` plays it exactly),
-- else its bézier.
function M.ease_of(tr: any?): string
	local sp = tr and tr.sp
	if type(sp) == "table" then
		return string.format("spring(%.6g, %.6g, %.6g, %.6g)", sp.m or 1, sp.k or 100, sp.c or 10, sp.v or 0)
	end
	return M.ease(tr and tr.ease)
end

-- Spring presets and the solver, for the panel's curve (the engine's
-- engine/proto.luau `M.spring`, the same closed form).
M.SPRINGS = {
	{ name = "gentle", label = "Gentle", sp = { mass = 1, stiffness = 100, damping = 15 } },
	{ name = "quick", label = "Quick", sp = { mass = 1, stiffness = 300, damping = 20 } },
	{ name = "bouncy", label = "Bouncy", sp = { mass = 1, stiffness = 600, damping = 15 } },
	{ name = "slow", label = "Slow", sp = { mass = 1, stiffness = 80, damping = 20 } },
}
function M.spring_of(e: any): any?
	if type(e) == "string" then
		for _, s in M.SPRINGS do
			if s.name == e then
				return s.sp
			end
		end
		return nil
	end
	if type(e) == "table" and type(e.spring) == "table" then
		return e.spring
	end
	return nil
end
function M.spring(sp: any): ((number) -> number, number)
	local mass = math.clamp(sp.mass or 1, 1e-3, 1e4)
	local k = math.clamp(sp.stiffness or 100, 1e-3, 1e5)
	local c = math.clamp(sp.damping or 10, 1e-3, 1e4)
	local v = sp.velocity or 0
	local w0 = math.sqrt(k / mass)
	local zeta = c / (2 * math.sqrt(k * mass))
	local wd = if zeta < 1 then w0 * math.sqrt(1 - zeta * zeta) else 0
	local b = if zeta < 1 then (zeta * w0 - v) / wd else -v + w0
	local function x(t: number): number
		if zeta < 1 then
			return 1 - math.exp(-t * zeta * w0) * (math.cos(wd * t) + b * math.sin(wd * t))
		end
		return 1 - (1 + b * t) * math.exp(-t * w0)
	end
	local step, hold = 1 / 120, 20
	local time, still = 0, 0
	while still < hold and time < 60 do
		time += step
		if math.abs(1 - x(time)) < 1e-3 then
			still += 1
		else
			still = 0
		end
	end
	return x, math.max(step, time - step * hold)
end
-- A spring as SwiftUI's `Spring(duration:bounce:)` and Framer's time and
-- bounce put it (the curve editor drags these): `duration` = 2π√(m/k), the
-- undamped period in seconds; `bounce` = 1 − ζ (ζ the damping ratio), or
-- 1/ζ − 1 when overdamped (negative, no overshoot).
function M.spring_feel(sp: any): (number, number)
	local m = math.max(sp.mass or 1, 1e-3)
	local k = math.max(sp.stiffness or 100, 1e-3)
	local c = math.max(sp.damping or 10, 0)
	local zeta = c / (2 * math.sqrt(k * m))
	return (if zeta <= 1 then 1 - zeta else 1 / zeta - 1), 2 * math.pi * math.sqrt(m / k)
end
-- The way back: stiffness = m(2π/d)², damping = 2ζ√(km) (with m = 1,
-- SwiftUI's 4π(1 − bounce)/d), keeping the spring's mass and velocity.
function M.spring_from_feel(bounce: number, duration: number, base: any?): any
	local out = table.clone(base or {})
	local m = math.max(out.mass or 1, 1e-3)
	local d = math.max(duration, 1e-3)
	local k = m * (2 * math.pi / d) ^ 2
	local zeta = if bounce >= 0 then 1 - bounce else 1 / (1 + math.max(bounce, -0.99))
	out.mass = m
	out.stiffness = math.floor(k * 10 + 0.5) / 10
	out.damping = math.floor(zeta * 2 * math.sqrt(k * m) * 100 + 0.5) / 100
	return out
end
-- An easing as stored, its label in the panel.
function M.easing_label(e: any): string
	local sp = M.spring_of(e)
	if sp then
		if type(e) == "string" then
			for _, s in M.SPRINGS do
				if s.name == e then
					return s.label
				end
			end
		end
		return "Custom spring"
	end
	-- (numbers as stored are a custom bézier, even a preset's)
	if type(e) == "table" and #e == 4 then
		return "Custom bézier"
	end
	return M.ease_label(e)
end

-- The way back from a transition: the reverse motion, the same time and ease.
function M.reverse(tr: any?): any?
	if not tr then
		return nil
	end
	local k = tr.k
	local out = table.clone(tr)
	local back = { moveIn = "moveOut", moveOut = "moveIn", slideIn = "slideOut", slideOut = "slideIn" }
	out.k = back[k] or k
	if tr.dir then
		out.dir = M.OPPOSITE[tr.dir] or tr.dir
	end
	return out
end

-- Where each of the two Screens starts and ends, as element { x, y, opacity }
-- in points, and which is on top. `w`, `h`: the prototype's viewport (the
-- Screen's own size as shown, which clips both, as Figma's frame does), so a
-- push moves each Screen exactly its width. `from` is the Screen leaving,
-- `to` the one arriving. Slide in/out: the Screen underneath moves 30% of
-- the way and fades as it goes (Figma: "slowly offset the frame as it
-- dissolves").
function M.motion(tr: any?, w: number, h: number): any
	local k = if tr then tr.k else "instant"
	if k == "smart" then
		k = "dissolve"
	end
	local dir = if tr then tr.dir or "left" else "left"
	-- the unit vector the motion travels
	local ux, uy = 0, 0
	if dir == "left" then
		ux = -1
	elseif dir == "right" then
		ux = 1
	elseif dir == "up" then
		uy = -1
	else
		uy = 1
	end
	local dx, dy = ux * w, uy * h
	local P = 0.3 -- what a slide moves the Screen under it
	local SLIDE_FADE = 0.4 -- (and how far it fades: dimmed, not gone)
	local rest = { x = 0, y = 0, opacity = 1 }
	if k == "dissolve" then
		return { from = { a = rest, b = rest }, to = { a = { x = 0, y = 0, opacity = 0 }, b = rest }, top = "to" }
	elseif k == "push" then
		return { from = { a = rest, b = { x = dx, y = dy, opacity = 1 } }, to = { a = { x = -dx, y = -dy, opacity = 1 }, b = rest }, top = "to" }
	elseif k == "moveIn" then
		return { from = { a = rest, b = rest }, to = { a = { x = -dx, y = -dy, opacity = 1 }, b = rest }, top = "to" }
	elseif k == "moveOut" then
		return { from = { a = rest, b = { x = dx, y = dy, opacity = 1 } }, to = { a = rest, b = rest }, top = "from" }
	elseif k == "slideIn" then
		return { from = { a = rest, b = { x = dx * P, y = dy * P, opacity = SLIDE_FADE } }, to = { a = { x = -dx, y = -dy, opacity = 1 }, b = rest }, top = "to" }
	elseif k == "slideOut" then
		return { from = { a = rest, b = { x = dx, y = dy, opacity = 1 } }, to = { a = { x = -dx * P, y = -dy * P, opacity = SLIDE_FADE }, b = rest }, top = "from" }
	end
	return { from = { a = rest, b = rest }, to = { a = rest, b = rest }, top = "to", instant = true }
end

-- A root's prototype: its drivers (outermost only: one inside another
-- draws with it), each with its subtree's range and what each state does;
-- its links. Kept by the root's table.
local cache = setmetatable({}, { __mode = "k" }) :: any
function M.of_root(root: any): any
	local hit = cache[root]
	if hit then
		return hit
	end
	local nodes = root.nodes or {}
	local at: { [string]: number } = {}
	for i, it in nodes do
		at[it.id] = i
	end
	local drivers: { any } = {}
	local by_driver: { [string]: any } = {}
	local links: { any } = {}
	local entries: { [string]: { any } } = {}
	for i, it in nodes do
		if it.st then
			for _, e in it.st do
				local l = entries[e.of]
				if not l then
					l = {}
					entries[e.of] = l
				end
				table.insert(l, { i = i, e = e })
			end
		end
		if it.ia then
			for _, a in it.ia do
				table.insert(links, { i = i, id = it.id, a = a })
			end
		end
	end
	-- Drivers, outermost first: one inside a driver taken already is left
	-- to it (its subtree is lifted whole).
	local covered_to = 0
	for i, it in nodes do
		if (it.sttr or entries[it.id]) and i > 1 and i > covered_to and entries[it.id] then
			local d = { id = it.id, i = i, n = it.n or 0, tr = it.sttr or { ms = 150, ease = { 0, 0, 0.58, 1 } }, entries = entries[it.id], inh = it.stinh }
			local sc_h, sc_p = 1, nil
			for _, x in d.entries do
				if x.e.sc then
					if x.e.s == "hover" then
						sc_h = x.e.sc
					else
						sc_p = x.e.sc
					end
				end
			end
			d.scale = { hover = sc_h, press = sc_p or sc_h }
			local has = { hover = false, press = false }
			for _, x in d.entries do
				has[x.e.s] = true
			end
			d.has = has
			table.insert(drivers, d)
			by_driver[it.id] = d
			covered_to = i + (it.n or 0)
		end
	end
	local out = { at = at, drivers = drivers, by_driver = by_driver, links = links, nodes = nodes }
	cache[root] = out
	return out
end

-- One state's look on an item: a copy with the entry's properties.
local function with_entry(it: any, e: any): any
	local o = table.clone(it)
	if e.fill ~= nil then
		o.fill = e.fill
	end
	-- (`fill = {}` / `fx = {}`: the state takes it away; `stroke = false`: no stroke)
	if e.stroke ~= nil then
		o.stroke = if e.stroke == false then nil else e.stroke
	end
	if e.fx ~= nil then
		o.fx = if #e.fx > 0 then e.fx else nil
	end
	if type(o.fill) == "table" and #o.fill == 0 then
		o.fill = nil
	end
	if e.op ~= nil then
		o.op = if e.op < 1 then e.op else nil
	end
	if e.r ~= nil and o.shape and o.shape.k == "rect" then
		o.shape = table.clone(o.shape)
		o.shape.r = e.r
	end
	return o
end

-- The driver's subtree as a root of its own, as it looks at rest, hovered
-- ("hover") or pressed ("press": hover, then press over it).
function M.subtree(root: any, d: any, look: string?): any
	local nodes = root.nodes
	local out = table.move(nodes, d.i, d.i + d.n, 1, {})
	if look == "hover" or look == "press" then
		for _, x in d.entries do
			if x.e.s == "hover" then
				local k = x.i - d.i + 1
				if out[k] then
					out[k] = with_entry(out[k], x.e)
				end
			end
		end
		if look == "press" then
			-- (press after hover: its entries win where both set a key)
			for _, x in d.entries do
				if x.e.s == "press" then
					local k = x.i - d.i + 1
					if out[k] then
						out[k] = with_entry(out[k], x.e)
					end
				end
			end
		end
	end
	return { id = d.id .. "#" .. (look or "rest"), nodes = out }
end

-- The driver's subtree's bounds (shadows and strokes outside included,
-- roughly), Canvas units: { x, y, w, h }.
function M.extent(root: any, d: any): { number }
	local nodes = root.nodes
	local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
	local pad = 2
	local function fx_pad(fx: any)
		for _, f in fx or {} do
			if not f.inner then
				pad = math.max(pad, (f.blur or 0) + (f.spread or 0) + math.max(math.abs(f.x or 0), math.abs(f.y or 0)))
			end
		end
	end
	for k = d.i, d.i + d.n do
		local it = nodes[k]
		local x, y, w, h = Draw.canvas_bounds(it, Draw.local_map(it))
		x0, y0 = math.min(x0, x), math.min(y0, y)
		x1, y1 = math.max(x1, x + w), math.max(y1, y + h)
		fx_pad(it.fx)
		if it.stroke then
			local sw = it.stroke.w or { 1 }
			pad = math.max(pad, math.max(sw[1] or 0, sw[2] or 0, sw[3] or 0, sw[4] or 0) + 1)
		end
	end
	for _, x in d.entries do
		fx_pad(x.e.fx)
	end
	pad = math.ceil(pad)
	return { x0 - pad, y0 - pad, x1 - x0 + 2 * pad, y1 - y0 + 2 * pad }
end

-- The deepest visible item under Canvas point (x, y) (paint order: the last
-- drawn wins), as its index, or 0. `shift(i) → dx, dy, rank` (scrolling,
-- tab/scroll.luau): where item i is moved to as shown, and the layer it's
-- lifted into (a fixed or sticky layer, rank > 0, is over the content under
-- it); a scrolling frame clips what it holds.
function M.deepest(root: any, x: number, y: number, shift: ((number) -> (number, number, number))?): number
	local nodes = root.nodes
	local best, best_rank = 0, -1
	local skip_to = 0
	for i, it in nodes do
		if i <= skip_to then
			continue
		end
		if it.hidden then
			skip_to = i + (it.n or 0)
			continue
		end
		local px, py, rank = x, y, 0
		if shift then
			local dx, dy, r = shift(i)
			px, py, rank = x - dx, y - dy, r or 0
		end
		local inside
		if it.xf then
			local lx, ly = Draw.apply(Draw.invert(Draw.local_map(it)), px, py)
			inside = lx >= 0 and ly >= 0 and lx <= it.box.w and ly <= it.box.h
		else
			local b = it.box
			inside = px >= b.x and py >= b.y and px <= b.x + b.w and py <= b.y + b.h
		end
		if inside then
			if rank >= best_rank then
				best, best_rank = i, rank
			end
		elseif it.clip or (it.ovf and shift) then
			skip_to = i + (it.n or 0)
		end
	end
	return best
end

-- A reaction can run: it has an action, and its first move isn't broken.
function M.live(a: any): boolean
	return not a.broken and (a.go ~= nil or a.url ~= nil or (a.acts ~= nil and #a.acts > 0))
end

-- Every reaction under (x, y), innermost layer first: { { id, i, a } … }
-- (a = the scene's `ia` entry). Per trigger, Play takes the innermost.
function M.reactions_at(root: any, x: number, y: number, shift: ((number) -> (number, number, number))?): { any }
	local p = M.of_root(root)
	local nodes = root.nodes
	local out = {}
	local i: number? = M.deepest(root, x, y, shift)
	if i == 0 then
		return out
	end
	while i do
		local it = nodes[i]
		if it.ia then
			for _, a in it.ia do
				if M.live(a) then
					table.insert(out, { id = it.id, i = i, a = a })
				end
			end
		end
		i = if it.p then p.at[it.p] else nil
	end
	return out
end

-- A key trigger's combo (`keys`, as the scene sends it) against a zgx
-- KeyEvent: the key itself (letters any case; Space is " "), and exactly
-- the modifiers it names (Shift, Ctrl, Alt, Meta).
function M.key_match(keys: { string }?, k: any): boolean
	if not keys or #keys == 0 then
		return false
	end
	local want = { Shift = false, Ctrl = false, Alt = false, Meta = false }
	local main = nil
	for _, name in keys do
		if want[name] ~= nil then
			want[name] = true
		else
			main = name
		end
	end
	if not main then
		return false
	end
	local key = k.key or ""
	if key == " " then
		key = "Space"
	end
	local same = if #main == 1 then string.lower(key) == string.lower(main) else key == main
	if not same then
		return false
	end
	-- (a letter typed with Shift reports Shift; a combo without Shift still matches an upper case letter's Shift only when named)
	return (k.shift == true) == want.Shift and (k.ctrl == true) == want.Ctrl and (k.alt == true) == want.Alt and (k.meta == true) == want.Meta
end

-- The innermost reaction with trigger `on` in a reactions_at list.
function M.first_on(list: { any }, on: string): any?
	for _, l in list do
		if l.a.on == on then
			return l
		end
	end
	return nil
end

-- What's under Canvas point (x, y) in one root: the deepest visible item
-- (paint order: the last drawn wins), then up its parents, the first link
-- and the first (outermost-lifted) driver.
function M.hit(root: any, x: number, y: number, shift: ((number) -> (number, number, number))?): (any?, any?)
	local p = M.of_root(root)
	local nodes = root.nodes
	-- (what a clipping frame cuts can't be hit outside it)
	local best = M.deepest(root, x, y, shift)
	if best == 0 then
		return nil, nil
	end
	local link, driver = nil, nil
	local i: number? = best
	while i do
		local it = nodes[i]
		if not link and it.ia then
			for _, a in it.ia do
				if a.on == "click" and M.live(a) then
					link = { id = it.id, a = a, i = i }
					break
				end
			end
		end
		if p.by_driver[it.id] then
			driver = p.by_driver[it.id]
		end
		i = if it.p then p.at[it.p] else nil
	end
	return link, driver
end

-- Every link's spot in a root (for the "where can I click" flash).
function M.hotspots(root: any, shift: ((number) -> (number, number, number))?): { { number } }
	local p = M.of_root(root)
	local out = {}
	for _, l in p.links do
		local it = root.nodes[l.i]
		if not l.a.broken and (l.a.go or l.a.url) and not it.hidden then
			local x, y, w, h = Draw.canvas_bounds(it, Draw.local_map(it))
			if shift then
				local dx, dy = shift(l.i)
				x, y = x + dx, y + dy
			end
			table.insert(out, { x, y, w, h })
		end
	end
	return out
end

-- ── overlays (step 2) ─────────────────────────────────────────────────────
-- The scene: an overlay frame's root item carries `ovl = { pos, bg?, co }`;
-- acts `{ k = "overlay", go, tr, pos?, ox?, oy? }`, `{ k = "swap", go, tr }`,
-- `{ k = "close", tr? }`.
M.OVERLAY_DEFAULT = { pos = "center", co = true }

-- Where an overlay sits in the viewport (points from its top-left): flush to
-- the edges for the 7 positions, the trigger's top-left (tx, ty) plus
-- (ox, oy) for "manual"; cut to the viewport. The engine's
-- engine/proto.luau `overlay_place`, the same (a test keeps them equal).
function M.overlay_place(pos: string?, ox: number?, oy: number?, vw: number, vh: number, ow: number, oh: number, tx: number?, ty: number?): (number, number, number, number)
	local w, h = math.min(ow, vw), math.min(oh, vh)
	local p = pos or "center"
	if p == "manual" then
		return (tx or 0) + (ox or 0), (ty or 0) + (oy or 0), w, h
	end
	local x = (vw - w) / 2
	local y = (vh - h) / 2
	if string.find(p, "left", 1, true) then
		x = 0
	elseif string.find(p, "right", 1, true) then
		x = vw - w
	end
	if string.sub(p, 1, 3) == "top" then
		y = 0
	elseif string.sub(p, 1, 6) == "bottom" then
		y = vh - h
	end
	return x, y, w, h
end

-- An overlay's state away from rest, as element { x, y, opacity } offsets:
-- where an opening starts (`leaving` false) or a closing ends. A move or a
-- slide travels from (to) the viewport's edge: a bottom sheet moving up
-- travels its own height, a centred modal from the bottom edge (Figma's).
-- (x, y, w, h): the overlay in the viewport, (vw, vh) the viewport, any unit.
function M.overlay_off(tr: any?, vw: number, vh: number, x: number, y: number, w: number, h: number, leaving: boolean): any
	local k = if tr then tr.k else "instant"
	if k == "dissolve" or k == "smart" then
		return { x = 0, y = 0, opacity = 0 }
	end
	if k == "moveIn" or k == "slideIn" or k == "moveOut" or k == "slideOut" or k == "push" then
		local dir = tr and tr.dir or "up"
		-- arriving travels `dir` from the far edge; leaving travels `dir` out
		local dx, dy = 0, 0
		if not leaving then
			if dir == "up" then
				dy = vh - y
			elseif dir == "down" then
				dy = -(y + h)
			elseif dir == "left" then
				dx = vw - x
			else
				dx = -(x + w)
			end
		else
			if dir == "down" then
				dy = vh - y
			elseif dir == "up" then
				dy = -(y + h)
			elseif dir == "right" then
				dx = vw - x
			else
				dx = -(x + w)
			end
		end
		return { x = dx, y = dy, opacity = 1 }
	end
	return { x = 0, y = 0, opacity = 1, instant = true }
end

-- A short transition string ("push-left") as the stored table, and back.
function M.tr_label(tr: any?): string
	if not tr or tr.k == "instant" or tr.type == "instant" then
		return "Instant"
	end
	local k = tr.k or tr.type
	return M.KIND_LABEL[k] or tostring(k)
end

return M
