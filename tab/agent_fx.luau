--!strict
-- N1 (live building, pure/anim/n1/README.md): an agent's changes animated
-- over the board, as Paper does (pure/research/paper/README.md §2). The board
-- canvas is drawn once with the result; this layer only puts small elements
-- over it, each animated in Rust (`anime`, `ui.loop`): no script per frame.
--
--   new     a cover in the colour behind the node, its top edge (an accent
--           line) sweeping down to show it; its first 5 children (8 px or
--           more) outlined one after another; a ring round it pulsing.
--   edit    a weaker tint over the node, fading.
--   delete  a tint at the node's last box sweeping down and fading.
--   read    a pale wash rising over the Screen the agent screenshot.
--   working dots above each node an agent marked `inProgress`, blinking at
--           their own speeds, until it clears it.
--
-- Only what's on screen is mounted (off screen: nothing runs). "Reduce agent
-- animations" (`reduce()`) keeps a still marker and lets the Canvas's own
-- flash outline show changes (canvas.luau), with nothing moving here.

local M = {}

M.MS = { new = 1200, edit = 900, delete = 800, read = 1400 }
-- "Reduce agent animations", one state for the window: the shell sets it
-- (from prefs and its palette), the Canvas reads it. (A named `ui.state` is
-- the module's own, so it's held here, where both require it.)
M.reduce = ui.state("design.reduce_agent_fx", false)
function M.reduced(): boolean
	if M.reduce:get() then
		return true
	end
	local ok, r = pcall(function(): boolean
		return (ui :: any).prefers.reduced_motion:get() == true
	end)
	return ok and r
end
M.DOTS_W = 33 -- the working dots' width (7 columns of 3 px, 2 px apart)
local EASE_OUT = "cubicBezier(0.16, 1, 0.3, 1)"

local function hex_alpha(c: string, a: number): string
	local base = string.sub(c, 1, 7)
	return base .. string.format("%02x", math.clamp(math.floor(a * 255 + 0.5), 0, 255))
end

local function animate(el: any, params: any)
	pcall(function()
		anime.animate(el, params)
	end)
end

-- The colour behind node `id`: the nearest ancestor's opaque solid fill, else
-- the board's.
function M.backdrop(ix: any, id: string, board: string): string
	local n = ix.by[id]
	local p = if n then n.parent else ""
	local guard = 0
	while p and p ~= "" and guard < 64 do
		guard += 1
		local pn = ix.by[p]
		if not pn then
			break
		end
		local fills = pn.it.fill
		if type(fills) == "table" then
			for k = #fills, 1, -1 do
				local f = fills[k]
				if type(f) == "table" and f.k == "solid" and type(f.color) == "string" and (f.op == nil or f.op >= 1) then
					local c = f.color
					if #c == 7 or string.lower(string.sub(c, 8, 9)) == "ff" then
						return string.sub(c, 1, 7)
					end
				end
			end
		end
		p = pn.parent
	end
	return board
end

-- o = {
--   id, fx: State<{ entry }>, ix: { get, peek }, view: State<{x,y,zoom}?>,
--   size: State<{w,h}>, look: () -> L (canvas_look), reduce: () -> boolean,
-- }
function M.Layer(o: any): Node
	local fx = o.fx
	-- Each entry goes when done (one timer an entry, not a frame clock).
	local timed: { [string]: boolean } = {}
	ui.effect(function()
		local list = fx:get()
		for _, e in list do
			if not timed[e.key] then
				timed[e.key] = true
				local left = (M.MS[e.kind] or 1000) + 500 - (ui.now() - (e.at or 0))
				ui.after(math.max(0, left), function()
					timed[e.key] = nil
					local keep = {}
					for _, x in fx:peek() do
						if x.key ~= e.key then
							table.insert(keep, x)
						end
					end
					fx:set(keep)
				end)
			end
		end
	end)

	-- Canvas box → tab points; nil when off screen (so it isn't mounted).
	local function screen(b: { number }, v: any, s: any, pad: number): { number }?
		local x, y, w, h = v.x + b[1] * v.zoom, v.y + b[2] * v.zoom, b[3] * v.zoom, b[4] * v.zoom
		if x + w < -pad or y + h < -pad or x > s.w + pad or y > s.h + pad or w < 1 or h < 1 then
			return nil
		end
		return { x, y, w, h }
	end
	local function bounds_of(e: any, i: any): { number }?
		if e.box then
			return e.box
		end
		local n = i.by[e.id]
		return if n then n.bounds else nil
	end

	-- What shows now: the entries on screen (keys), their boxes by key.
	local shown = ui.computed(function(): any
		local list = fx:get()
		local v = o.view:get()
		local s = o.size:get()
		local i = o.ix:get()
		local out, at = {}, {}
		if not v or #list == 0 then
			return { list = out, at = at }
		end
		local reduce = o.reduce()
		for _, e in list do
			if not (reduce and (e.kind ~= "delete")) then
				local b = bounds_of(e, i)
				local r = if b then screen(b, v, s, 8) else nil
				if r then
					table.insert(out, e)
					at[e.key] = r
				end
			end
		end
		return { list = out, at = at }
	end)
	local function rect(key: string): { number }
		local r = shown:get().at[key]
		return r or { -10000, -10000, 1, 1 }
	end
	-- (as a build reads it: untracked, so a pan doesn't build it again)
	local function rect0(key: string): { number }
		local r = shown:peek().at[key]
		return r or { -10000, -10000, 1, 1 }
	end
	local function place(key: string, inset: number?): any
		local d = inset or 0
		return {
			absolute = true,
			pointer_events = "none",
			left = function(): number
				return math.floor(rect(key)[1]) - d
			end,
			top = function(): number
				return math.floor(rect(key)[2]) - d
			end,
			w = function(): number
				return math.max(1, math.ceil(rect(key)[3]) + 2 * d)
			end,
			h = function(): number
				return math.max(1, math.ceil(rect(key)[4]) + 2 * d)
			end,
		}
	end
	local function with(t: any, kids: { any }): any
		for k, v in kids do
			t[k] = v
		end
		return t
	end

	local function build_new(e: any): Node
		local L = o.look()
		local dur = M.MS.new
		local i = o.ix:peek()
		local back = M.backdrop(i, e.id, L.board)
		local h0 = rect0(e.key)[4]
		-- the first 5 children 8 px or more, as fractions of the node's box
		local kids = {}
		local n = i.by[e.id]
		if n then
			local b = n.bounds
			local v = o.view:peek()
			local z = if v then v.zoom else 1
			for _, cid in i.kids[e.id] or {} do
				local c = i.by[cid]
				if c and c.bounds[3] * z >= 8 and c.bounds[4] * z >= 8 and b[3] > 0 and b[4] > 0 then
					table.insert(kids, {
						(c.bounds[1] - b[1]) / b[3],
						(c.bounds[2] - b[2]) / b[4],
						c.bounds[3] / b[3],
						c.bounds[4] / b[4],
					})
					if #kids >= 5 then
						break
					end
				end
			end
		end
		local outlines = {}
		local nk = #kids
		for k, q in kids do
			-- (Paper's: child k on at k·(dur/2)/n, in over dur/15, held until
			-- dur/2 + 2·dur/15, out over dur/5)
			local on_at = (k - 1) * (0.5 * dur / math.max(1, nk))
			local total = 0.5 * dur + dur * 2 / 15 + 0.2 * dur - on_at
			local fin = (dur / 15) / total * 100
			local hold = (0.5 * dur + dur * 2 / 15 - on_at) / total * 100
			table.insert(outlines, ui.div {
				absolute = true,
				pointer_events = "none",
				left = function(): number
					return q[1] * rect(e.key)[3]
				end,
				top = function(): number
					return q[2] * rect(e.key)[4]
				end,
				w = function(): number
					return math.max(1, q[3] * rect(e.key)[3])
				end,
				h = function(): number
					return math.max(1, q[4] * rect(e.key)[4])
				end,
				border = 1,
				border_color = L.accent,
				rounded = 4,
				opacity = 0,
				on_mount = function(el: any)
					animate(el, {
						keyframes = {
							["0%"] = { opacity = 0 },
							[`{math.floor(fin)}%`] = { opacity = 1 },
							[`{math.floor(hold)}%`] = { opacity = 1 },
							["100%"] = { opacity = 0 },
						},
						delay = on_at,
						duration = total,
						ease = "linear",
					})
				end,
			})
		end
		return ui.div(with(place(e.key), {
			-- the cover, cut to the node's box, its top edge sweeping down
			ui.div {
				absolute = true,
				left = 0,
				top = 0,
				right = 0,
				bottom = 0,
				overflow = "hidden",
				pointer_events = "none",
				ui.div {
					absolute = true,
					left = 0,
					top = 0,
					right = 0,
					bottom = 0,
					bg = back,
					on_mount = function(el: any)
						animate(el, { y = { 0, math.max(1, h0) }, duration = 0.62 * dur, delay = 0.12 * dur, ease = EASE_OUT })
					end,
					ui.div { absolute = true, left = 0, right = 0, top = 0, h = 1.5, bg = hex_alpha(L.accent, 0.9) },
				},
			},
			-- the ring
			ui.div {
				absolute = true,
				left = -3,
				top = -3,
				right = -3,
				bottom = -3,
				pointer_events = "none",
				border = 1.5,
				border_color = L.accent,
				rounded = 6,
				opacity = 0,
				on_mount = function(el: any)
					animate(el, {
						keyframes = {
							["0%"] = { opacity = 0 },
							["12%"] = { opacity = 1 },
							["40%"] = { opacity = 0.35 },
							["65%"] = { opacity = 0.9 },
							["100%"] = { opacity = 0 },
						},
						duration = dur + 400,
						ease = "linear",
					})
				end,
			},
			table.unpack(outlines),
		}))
	end

	local function build_edit(e: any): Node
		local L = o.look()
		return ui.div(with(place(e.key), {
			bg = hex_alpha(L.accent, 0.22),
			border = 1.5,
			border_color = L.accent,
			rounded = 2,
			opacity = 0,
			on_mount = function(el: any)
				animate(el, {
					keyframes = { ["0%"] = { opacity = 0 }, ["18%"] = { opacity = 1 }, ["100%"] = { opacity = 0 } },
					duration = M.MS.edit,
					ease = "linear",
				})
			end,
		}))
	end

	local function build_delete(e: any): Node
		local L = o.look()
		local dur = M.MS.delete
		local h0 = rect0(e.key)[4]
		if o.reduce() then
			return ui.div(with(place(e.key), {
				border = 1,
				border_color = hex_alpha(L.accent, 0.7),
				on_mount = function(el: any)
					animate(el, { opacity = { 1, 0 }, duration = dur, ease = "linear" })
				end,
			}))
		end
		return ui.div(with(place(e.key), {
			overflow = "hidden",
			ui.div {
				absolute = true,
				left = 0,
				top = 0,
				right = 0,
				bottom = 0,
				bg = hex_alpha(L.name_hover, 0.16),
				border = 1,
				border_color = hex_alpha(L.accent, 0.8),
				on_mount = function(el: any)
					animate(el, { y = { 0, math.max(1, h0) }, opacity = { 0.8, 0 }, duration = dur, ease = "inOutSine" })
				end,
			},
		}))
	end

	local function build_read(e: any): Node
		local L = o.look()
		local dur = M.MS.read
		local h0 = rect0(e.key)[4]
		return ui.div(with(place(e.key), {
			overflow = "hidden",
			ui.div {
				absolute = true,
				left = 0,
				top = 0,
				right = 0,
				bottom = 0,
				bg = hex_alpha(L.board, 0.55),
				opacity = 0,
				on_mount = function(el: any)
					animate(el, {
						keyframes = {
							["0%"] = { y = math.max(1, h0), opacity = 1 },
							["50%"] = { y = 0, opacity = 1 },
							["100%"] = { y = 0, opacity = 0 },
						},
						duration = dur,
						ease = "inOutSine",
					})
				end,
				ui.div { absolute = true, left = 0, right = 0, top = 0, h = 1.5, bg = hex_alpha(L.accent, 0.7) },
			},
		}))
	end

	local function item(e: any): Node
		if e.kind == "new" then
			return build_new(e)
		elseif e.kind == "edit" then
			return build_edit(e)
		elseif e.kind == "delete" then
			return build_delete(e)
		elseif e.kind == "read" then
			return build_read(e)
		end
		return ui.div {}
	end

	-- Working dots: over each node an agent marked inProgress, on screen.
	-- (the nodes marked: found once a scene change, not at every pan)
	local wip_ids = ui.computed(function(): { string }
		local i = o.ix:get()
		local out = {}
		for _, id in i.order do
			if i.by[id].it.wip then
				table.insert(out, id)
			end
		end
		return out
	end)
	local wip = ui.computed(function(): any
		local v = o.view:get()
		local s = o.size:get()
		local i = o.ix:peek()
		local ids = wip_ids:get()
		local _ = o.reduce() -- (the dots' look follows it: their keys carry it)
		local out, at = {}, {}
		if not v then
			return { list = out, at = at }
		end
		for _, id in ids do
			local n = i.by[id]
			if n then
				local b = n.bounds
				local x, y = v.x + (b[1] + b[3]) * v.zoom, v.y + b[2] * v.zoom
				if x > -40 and y > -40 and x - b[3] * v.zoom < s.w + 40 and y < s.h + 40 then
					table.insert(out, id)
					at[id] = { x, y }
				end
			end
		end
		return { list = out, at = at }
	end)
	local function dots(id: string): Node
		local L = o.look()
		local still = o.reduce()
		local cells = {}
		-- (fixed "random" speeds and phases: the same look each time)
		local speeds = { 0.92, 1.1, 0.85, 1.04, 0.97, 1.15, 0.88, 1.01, 0.9, 1.12, 0.95, 1.07, 0.86, 1.0 }
		for k = 1, 14 do
			local col, row = (k - 1) % 7, if k > 7 then 1 else 0
			table.insert(cells, ui.div {
				absolute = true,
				left = col * 5,
				top = row * 5,
				w = 3,
				h = 3,
				rounded = 1.5,
				bg = L.agent,
				opacity = if still then (if (k % 3) == 0 then 0.35 else 0.85) else (if (k % 2) == 0 then 0.15 else 1),
				-- (anime, in Rust: each dot back and forth at its own speed)
				on_mount = if still then nil else function(el: any)
					animate(el, {
						opacity = if (k % 2) == 0 then { 0.15, 1 } else { 1, 0.15 },
						duration = math.floor(400 * speeds[k] * (1 + (k % 4) * 0.35)),
						delay = (k * 37) % 300,
						ease = "inOutSine",
						loop = true,
						alternate = true,
						frame_rate = 30,
					})
				end,
			})
		end
		local function at(): { number }
			local q = wip:get().at[id]
			return q or { -1000, -1000 }
		end
		return ui.div(with({
			id = `{o.id}-working-{id}`,
			absolute = true,
			pointer_events = "none",
			w = M.DOTS_W,
			h = 8,
			left = function(): number
				return math.floor(at()[1]) - M.DOTS_W
			end,
			top = function(): number
				return math.floor(at()[2]) - 20
			end,
		}, cells))
	end

	return ui.div {
		id = `{o.id}-agent-fx`,
		absolute = true,
		left = 0,
		top = 0,
		right = 0,
		bottom = 0,
		overflow = "hidden",
		pointer_events = "none",
		ui.each(ui.computed(function(): { any }
			return shown:get().list
		end), item, {
			key = function(e: any): string
				return e.key
			end,
		}),
		ui.each(ui.computed(function(): { any }
			return wip:get().list
		end), dots, {
			key = function(id: any): string
				return `{id}|{o.reduce()}`
			end,
		}),
	}
end

return M
