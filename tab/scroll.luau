--!strict
-- Scrolling in Play (figma-parity.md §3.2), the pure part: how a Screen
-- splits into layers that move on their own, what each layer's canvas
-- hides, where each item is as shown, sticky offsets, which scroller a wheel
-- or a drag moves, scroll memory keys, and momentum. No state, no ui.
--
-- A Screen's items (scene order) split into layers, each drawn once into its
-- own canvas element and moved on the compositor (M0):
--   content  what a scroller holds (the Screen's own: every item but its
--            fixed layers; a scrolling frame's: its children), moved by the
--            scroller's offset. A frame that scrolls is drawn by the layer
--            around it (its fill, its stroke); what it holds is not.
--   fixed    a fixed child of a scroller, over its content, not moved.
--   sticky   a sticky item, in its scroller's content, pushed down to stay
--            at the scroller's top while its own parent is in view.
-- The scene's keys: `ovf` = "vertical" | "horizontal" | "both" and
-- `cx = { w, h }` on a scrolling frame, `scr` = "fixed" | "sticky".

local M = {}

M.DRAG_SLOP = 5 -- points the pointer moves before a press becomes a drag
M.TAU = 325 -- ms: momentum's decay, v·e^(−t/τ) (iOS's)
M.MIN_FLING = 0.08 -- points per ms: slower than this, a release just stops

export type Layer = {
	k: string, -- "content" | "fixed" | "sticky"
	i: number, -- the item the layer starts at (a scroller, for content)
	host: number?, -- the layer it sits in (nil: the slot)
	s: number?, -- content: its scroller; fixed: the scroller it stays over; sticky: the scroller it sticks in
	inside: boolean?, -- fixed: in the scroller's element, over its content (false for the Screen's: in the slot)
}

export type Plan = {
	root: any,
	at: { [string]: number },
	parent: { [number]: number },
	owner: { [number]: number }, -- item → its layer
	layers: { Layer },
	content_of: { [number]: number }, -- scroller item → its content layer
	scrollers: { number }, -- scroller items, in order (the Screen first)
	hide: { [number]: { [string]: boolean } }, -- per layer, what its canvas leaves out
	drivers: { [string]: boolean }, -- drivers that can be lifted (none hold a layer)
	path: { [number]: string }, -- name path from the Screen
}

local cache = setmetatable({}, { __mode = "k" }) :: any

-- Does a scroller move along x / y? The Screen moves up and down always,
-- and sideways when it says so (Figma's top-level frame).
function M.axes(it: any, is_root: boolean): (boolean, boolean)
	local o = it.ovf
	if is_root then
		return o == "horizontal" or o == "both", true
	end
	return o == "horizontal" or o == "both", o == "vertical" or o == "both"
end

-- `drivers`: the ids of the drivers Play would lift (tab/proto.luau's
-- of_root), so the plan can hide them and keep them in their layers.
function M.plan(root: any, drivers: { any }?): Plan
	local hit = cache[root]
	if hit then
		return hit
	end
	local nodes = root.nodes
	local at: { [string]: number } = {}
	for i, it in nodes do
		at[it.id] = i
	end
	local parent: { [number]: number } = {}
	for i, it in nodes do
		if it.p and at[it.p] then
			parent[i] = at[it.p]
		end
	end
	local layers: { Layer } = { { k = "content", i = 1, s = 1 } }
	local owner: { [number]: number } = { [1] = 1 }
	local content_of: { [number]: number } = { [1] = 1 }
	local scrollers = { 1 }
	local scroller_of: { [number]: number } = { [1] = 1 } -- item → the nearest scroller around it (or itself for the Screen)
	local path: { [number]: string } = { [1] = "" }
	for i = 2, #nodes do
		local it = nodes[i]
		local p = parent[i] or 1
		local pit = nodes[p]
		path[i] = (if p == 1 then "" else path[p] .. "/") .. tostring(it.name or "")
		local p_scrolls = p == 1 or pit.ovf ~= nil
		-- the scroller this item scrolls in: its parent, if that scrolls, else the parent's
		local s = if p_scrolls then p else scroller_of[p]
		scroller_of[i] = s
		if it.scr == "fixed" and p_scrolls then
			table.insert(layers, { k = "fixed", i = i, host = if p == 1 then nil else owner[p], s = p, inside = p ~= 1 })
			owner[i] = #layers
		elseif it.scr == "sticky" then
			table.insert(layers, { k = "sticky", i = i, host = content_of[s], s = s })
			owner[i] = #layers
		elseif p_scrolls then
			owner[i] = content_of[p]
		else
			owner[i] = owner[p]
		end
		if it.ovf then
			table.insert(layers, { k = "content", i = i, host = owner[i], s = i })
			content_of[i] = #layers
			table.insert(scrollers, i)
		end
	end
	-- Drivers lift whole: one that holds a layer of its own stays in its
	-- Screen (drawn, not lifted).
	local liftable: { [string]: boolean } = {}
	for _, d in drivers or {} do
		local ok = true
		for j = d.i + 1, d.i + (d.n or 0) do
			if nodes[j] and (nodes[j].ovf or nodes[j].scr) then
				ok = false
				break
			end
		end
		if ok and nodes[d.i] and nodes[d.i].ovf then
			ok = false
		end
		liftable[d.id] = ok
	end
	-- What each layer's canvas leaves out: items that start another layer
	-- (a layer's root, a scroller's children), and the lifted drivers.
	local starts: { [number]: number } = {}
	for i = 2, #nodes do
		local p = parent[i] or 1
		if owner[i] ~= owner[p] then
			starts[i] = owner[i]
		end
	end
	local hide: { [number]: { [string]: boolean } } = {}
	for li in layers do
		local h: { [string]: boolean } = {}
		for i, l in starts do
			if l ~= li then
				h[nodes[i].id] = true
			end
		end
		for id, ok in liftable do
			if ok then
				h[id] = true
			end
		end
		hide[li] = h
	end
	local out: Plan = {
		root = root,
		at = at,
		parent = parent,
		owner = owner,
		layers = layers,
		content_of = content_of,
		scrollers = scrollers,
		hide = hide,
		drivers = liftable,
		path = path,
	}
	;(out :: any).scroller_of = scroller_of
	cache[root] = out
	return out
end

-- A layer's items as a root of its own, for Draw.draw_root: a content
-- layer of a scrolling frame starts with a ghost of the frame (no paint:
-- the layer around draws it), so depths and ranges stay as they are.
function M.layer_root(plan: Plan, li: number): any
	local cached = (plan :: any).roots
	if not cached then
		cached = {}
		;(plan :: any).roots = cached
	end
	if cached[li] then
		return cached[li]
	end
	local l = plan.layers[li]
	local nodes = plan.root.nodes
	local first = nodes[l.i]
	local out = table.move(nodes, l.i, l.i + (first.n or 0), 1, {})
	if l.k == "content" and l.i ~= 1 then
		local g = { id = first.id, p = nil, d = first.d, n = first.n, t = "frame", name = first.name, box = first.box, xf = first.xf, op = first.op }
		out[1] = g
	end
	local r = { id = `{plan.root.id}#layer{li}`, nodes = out, v = plan.root.v }
	cached[li] = r
	return r
end

-- How far a scroller can move: its content less its viewport (Canvas
-- units). `vw`, `vh`: the Screen's viewport (the device), for the Screen.
function M.room(plan: Plan, s: number, vw: number?, vh: number?): (number, number)
	local it = plan.root.nodes[s]
	local ax, ay = M.axes(it, s == 1)
	local cw, ch, w, h
	if s == 1 then
		cw, ch = it.box.w, it.box.h
		w, h = vw or it.box.w, vh or it.box.h
	else
		cw, ch = (it.cx and it.cx.w) or it.box.w, (it.cx and it.cx.h) or it.box.h
		w, h = it.box.w, it.box.h
	end
	return if ax then math.max(0, cw - w) else 0, if ay then math.max(0, ch - h) else 0
end

-- A sticky item's push down (Canvas units) when its scroller is at `sy`:
-- it stays at the scroller's top, but not past its own parent's end
-- (Figma's: it stays inside its direct parent).
function M.sticky_push(plan: Plan, i: number, sy: number): number
	local nodes = plan.root.nodes
	local l = plan.layers[plan.owner[i]]
	local s = l.s or 1
	local _, ay = M.axes(nodes[s], s == 1)
	if not ay then
		return 0
	end
	local sb = nodes[s].box
	local it = nodes[i]
	local y0, h = it.box.y, it.box.h
	local p = plan.parent[i] or 1
	local bottom
	if p == s then
		bottom = sb.y + (if s == 1 then sb.h else ((nodes[s].cx and nodes[s].cx.h) or sb.h))
	else
		bottom = nodes[p].box.y + nodes[p].box.h
	end
	local d = math.max(y0, sb.y + sy)
	d = math.min(d, math.max(y0, bottom - h))
	return d - y0
end

-- Where item i is shown, against where the scene has it: (dx, dy, rank),
-- `pos(s)` → the scroller's offset (x, y). rank: how many lifted layers
-- (fixed, sticky) it's in, over content at the same place.
function M.shift(plan: Plan, i: number, pos: (number) -> (number, number)): (number, number, number)
	local dx, dy, rank = 0, 0, 0
	local li: number? = plan.owner[i]
	while li do
		local l = plan.layers[li]
		if l.k == "content" then
			local x, y = pos(l.s :: number)
			dx -= x
			dy -= y
			li = l.host
		elseif l.k == "sticky" then
			local _, y = pos(l.s :: number)
			dy += M.sticky_push(plan, l.i, y)
			rank += 1
			li = l.host
		else
			rank += 2
			li = l.host
		end
	end
	return dx, dy, rank
end

-- The scrollers around item i (`i` itself first if it scrolls), innermost
-- first, out to the Screen. A wheel or a drag tries them in that order.
function M.chain(plan: Plan, i: number): { number }
	local out = {}
	local j: number? = i
	while j and j > 0 do
		if j == 1 or plan.root.nodes[j].ovf then
			table.insert(out, j)
		end
		j = plan.parent[j]
	end
	if out[#out] ~= 1 then
		table.insert(out, 1)
	end
	return out
end

-- A delta (Canvas units) given to the chain: each scroller takes what it
-- can on each axis, innermost first, as browsers do. `pos(s)`, `room(s)`.
-- Returns { [s] = { x, y } } of new offsets.
function M.route(chain: { number }, dx: number, dy: number, pos: (number) -> (number, number), room: (number) -> (number, number)): { [number]: { number } }
	local out: { [number]: { number } } = {}
	for _, s in chain do
		if dx == 0 and dy == 0 then
			break
		end
		local x, y = pos(s)
		local mx, my = room(s)
		local nx, ny = math.clamp(x + dx, 0, mx), math.clamp(y + dy, 0, my)
		if nx ~= x or ny ~= y then
			out[s] = { nx, ny }
		end
		dx -= nx - x
		dy -= ny - y
	end
	return out
end

-- Scroll to (F2a): the nearest scroller around item i that can move (the
-- Screen when none), and the offset that brings i to its top-left less
-- (ox, oy); an axis it doesn't scroll keeps its offset. Nested scrollers'
-- offsets between them count. Play and Simulate (engine/sim.luau) share it.
-- Returns s, x, y (not clamped).
function M.scroll_target(plan: Plan, i: number, ox: number, oy: number, pos: (number) -> (number, number), room: (number) -> (number, number)): (number, number, number)
	local nodes = plan.root.nodes
	local s = 1
	local j = plan.parent[i]
	while j do
		if nodes[j].ovf then
			local mx, my = room(j)
			if mx > 0 or my > 0 then
				s = j
				break
			end
		end
		j = plan.parent[j]
	end
	local dx, dy = 0, 0
	local k = plan.parent[i]
	while k and k ~= s do
		if nodes[k].ovf then
			local x, y = pos(k)
			dx -= x
			dy -= y
		end
		k = plan.parent[k]
	end
	local sb, tb = nodes[s].box, nodes[i].box
	local tx = tb.x + dx - sb.x - ox
	local ty = tb.y + dy - sb.y - oy
	local ax, ay = M.axes(nodes[s], s == 1)
	local cx, cy = pos(s)
	return s, if ax then tx else cx, if ay then ty else cy
end

-- Scroll memory, as Figma's: a Screen's key is its name, or its name
-- before a "/" ("Checkout / 1" and "Checkout / 2" share it); a scroller's
-- is the Screen's and its name path.
function M.screen_key(name: any): string
	local s = tostring(name or "")
	s = string.match(s, "^(.-)%s*/") or s
	return (string.gsub(string.lower(s), "^%s*(.-)%s*$", "%1"))
end
function M.memory_key(plan: Plan, s: number): string
	return M.screen_key(plan.root.nodes[1].name) .. "|" .. (plan.path[s] or "")
end

-- Momentum: from velocity v (points per ms), how far it glides and for
-- how long (v·τ, and until it's within half a point), and its ease
-- (exactly the decay's shape over that time).
function M.fling(v: number): (number, number, (number) -> number)
	local dist = v * M.TAU
	local ms = math.clamp(M.TAU * math.log(math.max(1, math.abs(dist) / 0.5)), 1, 2500)
	local k = ms / M.TAU
	local norm = 1 - math.exp(-k)
	return dist * norm, ms, function(t: number): number
		return (1 - math.exp(-k * t)) / norm
	end
end

-- The device presets (engine/proto.luau's M.DEVICES, the same: a test
-- checks), for the panel and a fixture's Play. Step 6: `group`, `frame`
-- (tab/device_frame.luau's kind) and `models` (first = default).
local ISLAND_16 = { "Black", "White", "Pink", "Teal", "Ultramarine" }
local ISLAND_PRO = { "Black Titanium", "White Titanium", "Natural Titanium", "Desert Titanium" }
local ISLAND_17 = { "Black", "White", "Mist Blue", "Sage", "Lavender" }
local ISLAND_17_PRO = { "Silver", "Cosmic Orange", "Deep Blue" }
local IPAD = { "Space Gray", "Silver" }
local MAC = { "Space Gray", "Silver", "Starlight", "Midnight" }
local WATCH = { "Midnight", "Starlight", "Silver", "Red" }
M.DEVICES = {
	["iphone-17"] = { w = 402, h = 874, label = "iPhone 17", group = "Phones", frame = "phone-island", models = ISLAND_17 },
	["iphone-17-pro"] = { w = 402, h = 874, label = "iPhone 17 Pro", group = "Phones", frame = "phone-island", models = ISLAND_17_PRO },
	["iphone-17-pro-max"] = { w = 440, h = 956, label = "iPhone 17 Pro Max", group = "Phones", frame = "phone-island", models = ISLAND_17_PRO },
	["iphone-air"] = { w = 420, h = 912, label = "iPhone Air", group = "Phones", frame = "phone-island", models = { "Space Black", "Cloud White", "Light Gold", "Sky Blue" } },
	["iphone-16"] = { w = 393, h = 852, label = "iPhone 16", group = "Phones", frame = "phone-island", models = ISLAND_16 },
	["iphone-16-pro"] = { w = 402, h = 874, label = "iPhone 16 Pro", group = "Phones", frame = "phone-island", models = ISLAND_PRO },
	["iphone-16-pro-max"] = { w = 440, h = 956, label = "iPhone 16 Pro Max", group = "Phones", frame = "phone-island", models = ISLAND_PRO },
	["iphone-se"] = { w = 375, h = 667, label = "iPhone SE", group = "Phones", frame = "phone-home", models = { "Midnight", "Starlight", "Red" } },
	["android-compact"] = { w = 412, h = 917, label = "Android Compact", group = "Phones", frame = "android", models = { "Obsidian", "Porcelain", "Hazel", "Rose" } },
	["android-medium"] = { w = 700, h = 840, label = "Android Medium", group = "Phones", frame = "android", models = { "Obsidian", "Porcelain" } },
	["ipad-mini"] = { w = 744, h = 1133, label = "iPad mini", group = "Tablets", frame = "tablet", models = { "Space Gray", "Starlight", "Purple", "Blue" } },
	["ipad-pro-11"] = { w = 834, h = 1194, label = "iPad Pro 11\"", group = "Tablets", frame = "tablet", models = IPAD },
	["ipad-pro-12-9"] = { w = 1024, h = 1366, label = "iPad Pro 12.9\"", group = "Tablets", frame = "tablet", models = IPAD },
	["ipad-pro-13"] = { w = 1032, h = 1376, label = "iPad Pro 13\"", group = "Tablets", frame = "tablet", models = IPAD },
	["android-expanded"] = { w = 1280, h = 800, label = "Android Expanded", group = "Tablets", frame = "tablet", models = { "Space Gray", "Silver" } },
	["surface-pro-8"] = { w = 1440, h = 960, label = "Surface Pro 8", group = "Tablets", frame = "tablet", models = { "Platinum", "Graphite" } },
	["apple-watch-41"] = { w = 176, h = 215, label = "Apple Watch 41mm", group = "Watches", frame = "watch", models = WATCH },
	["apple-watch"] = { w = 198, h = 242, label = "Apple Watch 45mm", group = "Watches", frame = "watch", models = WATCH },
	["macbook-air"] = { w = 1280, h = 832, label = "MacBook Air", group = "Computers", frame = "laptop", models = MAC },
	["macbook-pro-14"] = { w = 1512, h = 982, label = "MacBook Pro 14\"", group = "Computers", frame = "laptop", models = { "Space Black", "Silver" } },
	["macbook-pro-16"] = { w = 1728, h = 1117, label = "MacBook Pro 16\"", group = "Computers", frame = "laptop", models = { "Space Black", "Silver" } },
	desktop = { w = 1440, h = 1024, label = "Desktop", group = "Computers", frame = "desktop", models = { "Silver", "Black" } },
	tv = { w = 1280, h = 720, label = "TV", group = "TV", frame = "tv", models = { "Black" } },
}
M.DEVICE_ORDER = {
	"iphone-17", "iphone-17-pro", "iphone-17-pro-max", "iphone-air", "iphone-16", "iphone-16-pro", "iphone-16-pro-max",
	"iphone-se", "android-compact", "android-medium",
	"ipad-mini", "ipad-pro-11", "ipad-pro-12-9", "ipad-pro-13", "android-expanded", "surface-pro-8",
	"apple-watch-41", "apple-watch",
	"macbook-air", "macbook-pro-14", "macbook-pro-16", "desktop",
	"tv",
}
-- Scaling, with Figma's labels (engine/proto.luau M.FITS). The panel's
-- dropdown lists these. "responsive" (step 6 P5): the Screen laid out again
-- at the window's size (or the device's), tab/play_place.luau.
M.FITS = {
	{ name = "fit", label = "Fit width and height" },
	{ name = "width", label = "Fit width" },
	{ name = "actual", label = "Actual size (100%)" },
	{ name = "fill", label = "Fill screen" },
	{ name = "responsive", label = "Responsive" },
}
-- The device switcher (a framed device; engine/proto.luau M.DEVICE_FITS).
M.DEVICE_FITS = {
	{ name = "fit", label = "Fit device on screen" },
	{ name = "fill", label = "Zoom device to fill screen" },
	{ name = "actual", label = "Show device at 100%" },
}

local function has_model(d: any, m: any): boolean
	if type(m) ~= "string" or type(d) ~= "table" or type(d.models) ~= "table" then
		return false
	end
	for _, x in d.models do
		if x == m then
			return true
		end
	end
	return false
end
M.has_model = has_model

-- A stored `prototype` as Play plays it (engine/proto.luau's
-- played_prototype), for a source without the engine.
function M.played(p: any): any?
	if type(p) ~= "table" then
		return nil
	end
	local d = p.device
	local w, h
	if type(d) == "string" and M.DEVICES[d] then
		w, h = M.DEVICES[d].w, M.DEVICES[d].h
	elseif type(d) == "table" then
		w, h = d.w or d.width or d[1], d.h or d.height or d[2]
	end
	if type(w) ~= "number" or type(h) ~= "number" then
		w, h = nil, nil
	elseif p.rotate == true then
		w, h = h, w
	end
	local bg = nil
	if type(p.background) == "string" and string.match(p.background, "^#%x+$") then
		local hex = string.upper(string.sub(p.background, 2))
		if #hex == 3 then
			hex = string.gsub(hex, "(%x)", "%1%1")
		end
		bg = "#" .. (if #hex == 6 then hex .. "FF" else hex)
	end
	local fit = p.fit
	if fit ~= "fit" and fit ~= "width" and fit ~= "actual" and fit ~= "fill" and fit ~= "responsive" then
		fit = "fit"
	end
	local dfit = p.deviceFit
	if dfit ~= "fit" and dfit ~= "fill" and dfit ~= "actual" then
		dfit = "fit"
	end
	local pre = if type(d) == "string" then M.DEVICES[d] else nil
	return {
		w = w,
		h = h,
		device = if type(d) == "string" then d elseif w then "custom" else nil,
		fit = fit,
		bg = bg,
		rotate = p.rotate == true or nil,
		frame = if pre then pre.frame else nil,
		model = if pre then (if has_model(pre, p.model) then p.model else pre.models[1]) else nil,
		device_fit = dfit,
		show_frame = p.showFrame ~= false,
	}
end

-- A pointer's recent moves → its velocity (points per ms), from the
-- samples in the last 100 ms: { { t, x, y } }.
function M.velocity(samples: { { number } }, now: number): (number, number)
	local first = nil
	for _, s in samples do
		if now - s[1] <= 100 then
			first = s
			break
		end
	end
	local last = samples[#samples]
	if not first or not last or last[1] - first[1] < 8 or now - last[1] > 60 then
		return 0, 0
	end
	local dt = last[1] - first[1]
	return (last[2] - first[2]) / dt, (last[3] - first[3]) / dt
end

return M
