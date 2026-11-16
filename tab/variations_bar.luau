--!nonstrict
-- The hand cursor on clickable controls (zgx's ui is read-only: see pointer.luau).
local ui = require("./pointer").ui
-- (N2) The Variations bar (pure/anim/n2/README.md) for a node an agent made
-- versions of: "2 of 5 · Tighter hierarchy  ‹ ›  Use this ×".
-- ‹ › (or ← → while the bar has focus) shows another version in the node's
-- place (no undo step); Use this keeps the shown one and drops the others
-- (one undo step; Enter too); × goes back to the original (one undo step).
-- The versions live in the service (engine/variations.luau); the bar sends
-- `variation` ops.
-- (N8) It sits at one spot, the bottom centre of the board (as Gui's bar),
-- never over the Screen's content; the node it's for has a thin outline,
-- and clicking the bar's name zooms to it. With several sets, the bar is
-- for the one most in view.
--
--   VariationsBar.Layer { id, sets = State<{ [id] = { current, count,
--     names, original } }>, ix = () -> index?, view = () -> {x,y,zoom}?,
--     size = () -> {w,h}, board = () -> { l, r } (the board's left and right
--     insets), hidden = () -> boolean, dark = () -> boolean,
--     edit = (ops, label) -> (), zoom_to = (id) -> () }

local Kit = require("./kit")
local Look = require("./look")

local M = {}

M.H = 32 -- the bar's height
M.BOTTOM = Look.EDGE -- from the window's bottom (the zoom pill's line)

-- "2 of 5 · Tighter hierarchy"
function M.label(s: any): string
	if type(s) ~= "table" then
		return ""
	end
	local name = s.names and s.names[s.current] or ""
	return `{s.current} of {s.count} · {name}`
end

-- The index after a step of `d` (wrapping round).
function M.step(s: any, d: number): number
	local n = math.max(1, s.count or 1)
	return ((s.current - 1 + d) % n) + 1
end

-- The node's box in tab points and how much of it is in the window (area).
function M.on_screen(b: { number }, v: any, s: any): ({ number }, number)
	local x, y = v.x + b[1] * v.zoom, v.y + b[2] * v.zoom
	local w, h = b[3] * v.zoom, b[4] * v.zoom
	local iw = math.max(0, math.min(x + w, s.w) - math.max(x, 0))
	local ih = math.max(0, math.min(y + h, s.h) - math.max(y, 0))
	return { x, y, w, h }, iw * ih
end

-- Which set the bar is for: the one whose node is most in view; else (none
-- in view) the first. `sets` keyed by node id. → id?, its box (nil if off
-- screen or not drawn), how many sets.
function M.pick(sets: any, i: any, v: any, s: any): (string?, { number }?, number)
	local ids = {}
	for id in sets do
		table.insert(ids, id)
	end
	table.sort(ids)
	local best, best_box, best_area = nil, nil, 0
	for _, id in ids do
		local n = i and i.by[id]
		if n and v then
			local box, area = M.on_screen(n.bounds, v, s)
			if area > best_area then
				best, best_box, best_area = id, box, area
			end
		end
	end
	if not best then
		return ids[1], nil, #ids
	end
	return best, best_box, #ids
end

-- Mounted by the shell over the Canvas (as the comment pins: inside the
-- Canvas, the board keeps the pointer from press to release and a button
-- there never gets its click). `view`, `ix`, `size`, `board` and `hidden`
-- are functions (the Canvas's api comes after the shell is built).
function M.Layer(o: any): Node
	local function L(): any
		return Look.of(o.dark())
	end
	-- the bar's set: { list = { id } (0 or 1), box = its node's box?, count }
	local shown = ui.computed(function(): any
		local sets = o.sets:get() or {}
		if next(sets) == nil or (o.hidden and o.hidden()) then
			return { list = {}, count = 0 }
		end
		local v = o.view()
		local s = o.size()
		local i = o.ix()
		if not i then
			return { list = {}, count = 0 }
		end
		local id, box, count = M.pick(sets, i, v, s)
		return { list = if id then { id } else {}, box = box, count = count }
	end)
	local function board(): any
		return if o.board then o.board() else { l = 0, r = 0 }
	end

	local function flip(id: string, to: number)
		local all = table.clone(o.sets:peek() or {})
		local s = all[id]
		if not s or to == s.current then
			return
		end
		-- (shown at once; the service's `changed` confirms it)
		local c = table.clone(s)
		c.current = to
		all[id] = c
		o.sets:set(all)
		o.edit({ { op = "variation", id = id, show = to } }, "Show variation")
	end
	local function keep(id: string)
		local s = (o.sets:peek() or {})[id]
		if not s then
			return
		end
		o.edit({ { op = "variation", id = id, keep = true } }, `Use this: {s.names and s.names[s.current] or "version"}`)
	end
	local function discard(id: string)
		if not (o.sets:peek() or {})[id] then
			return
		end
		o.edit({ { op = "variation", id = id, discard = true } }, "Discard variations")
	end

	local function bar(id: string): Node
		local P = `{o.id}-variations-{id}`
		local row_el: any = nil
		local function set(): any
			return (o.sets:get() or {})[id]
		end
		local function arrow(icon: string, label: string, d: number): Node
			return ui.button {
				id = `{P}-{if d < 0 then "prev" else "next"}`,
				label = label,
				w = 24,
				h = 24,
				p = 0,
				rounded = 6,
				items = "center",
				justify = "center",
				border = 0,
				bg = "#00000000",
				color = function(): string
					return L().fg
				end,
				hover = { bg = L().hover },
				focus = { outline = 0 },
				tooltip = Kit.tip(L(), if d < 0 then "Previous (←)" else "Next (→)"),
				on_click = function()
					local s = (o.sets:peek() or {})[id]
					if s then
						flip(id, M.step(s, d))
					end
				end,
				Kit.icon(icon, 14),
			}
		end
		return ui.row {
			id = P,
			role = "toolbar",
			label = "Variations",
			on_mount = function(el: any)
				row_el = el
			end,
			h = M.H,
			max_w = 520,
			shrink = 1,
			pl = 10,
			pr = 4,
			gap = 2,
			items = "center",
			rounded = 10,
			bg = function(): string
				return L().panel_solid
			end,
			border = 1,
			border_color = function(): string
				return L().border
			end,
			shadow = function(): any
				return L().island_shadow
			end,
			focusable = true,
			focus = { outline = 1, outline_color = L().accent },
			on_key = function(k: any): boolean?
				local s = (o.sets:peek() or {})[id]
				if not s then
					return nil
				end
				if k.key == "ArrowLeft" then
					flip(id, M.step(s, -1))
					return true
				elseif k.key == "ArrowRight" then
					flip(id, M.step(s, 1))
					return true
				elseif k.key == "Enter" then
					keep(id)
					return true
				end
				return nil
			end,
			-- (N8) the name: a click zooms to the node (the bar keeps focus for ← →)
			ui.button {
				id = `{P}-name`,
				label = "Show the layer with these versions",
				h = 24,
				pl = 0,
				pr = 6,
				ml = -4,
				gap = 6,
				rounded = 6,
				border = 0,
				items = "center",
				direction = "row",
				bg = "#00000000",
				hover = { bg = L().hover },
				focus = { outline = 0 },
				tooltip = Kit.tip(L(), "Zoom to this layer"),
				on_click = function()
					if o.zoom_to then
						o.zoom_to(id)
					end
					if row_el then
						pcall(function()
							row_el:focus()
						end)
					end
				end,
				ui.div { color = function(): string
					return L().agent
				end, shrink = 0, pl = 4, Kit.icon("sparkles", 13) },
				ui.text {
					function(): string
						return M.label(set())
					end,
					id = `{P}-label`,
					literal = true,
					text_size = 12,
					weight = 500,
					font = Look.UI,
					color = function(): string
						return L().fg
					end,
					truncate = true,
					max_w = 220,
					shrink = 0,
				},
				-- (several sets: which of them this is)
				ui.text {
					function(): string
						local c = shown:get().count or 0
						return if c > 1 then `· {c} sets` else ""
					end,
					literal = true,
					text_size = 11,
					font = Look.UI,
					color = function(): string
						return L().muted
					end,
					shrink = 0,
				},
			},
			arrow("chevLeft", "Previous version", -1),
			arrow("chevRight", "Next version", 1),
			ui.button {
				id = `{P}-use`,
				label = "Use this",
				h = 24,
				px = 9,
				ml = 4,
				rounded = 7,
				border = 0,
				items = "center",
				bg = function(): string
					return L().accent
				end,
				hover = { opacity = 0.9 },
				focus = { outline = 0 },
				tooltip = Kit.tip(L(), "Keep this version, remove the others (Enter)"),
				on_click = function()
					keep(id)
				end,
				ui.text { "Use this", text_size = 12, weight = 500, font = Look.UI, color = function(): string
					return L().on_accent
				end },
			},
			ui.button {
				id = `{P}-discard`,
				label = "Discard variations",
				w = 24,
				h = 24,
				p = 0,
				rounded = 6,
				items = "center",
				justify = "center",
				border = 0,
				bg = "#00000000",
				color = function(): string
					return L().muted
				end,
				hover = { bg = L().hover },
				focus = { outline = 0 },
				tooltip = Kit.tip(L(), "Discard all, back to the original"),
				on_click = function()
					discard(id)
				end,
				Kit.icon("x", 14),
			},
		}
	end

	-- the node's thin outline (on the board, under nothing that takes the pointer)
	local function box(): { number }
		return shown:get().box or { -1000, -1000, 1, 1 }
	end
	local outline = ui.div {
		id = `{o.id}-variations-outline`,
		absolute = true,
		pointer_events = "none",
		left = function(): number
			return math.floor(box()[1]) - 2
		end,
		top = function(): number
			return math.floor(box()[2]) - 2
		end,
		w = function(): number
			return math.max(1, math.ceil(box()[3]) + 4)
		end,
		h = function(): number
			return math.max(1, math.ceil(box()[4]) + 4)
		end,
		border = 1,
		border_color = function(): string
			return string.sub(L().agent, 1, 7) .. "8c"
		end,
		rounded = 4,
	}
	return ui.div {
		absolute = true,
		left = 0,
		top = 0,
		right = 0,
		bottom = 0,
		pointer_events = "none",
		ui.show(function(): boolean
			return shown:get().box ~= nil
		end, outline),
		-- the bar: bottom centre of the board (between the side panels)
		ui.row {
			absolute = true,
			left = function(): number
				return board().l
			end,
			right = function(): number
				return board().r
			end,
			bottom = M.BOTTOM,
			h = M.H,
			justify = "center",
			pointer_events = "none",
			ui.each(ui.computed(function(): { string }
				return shown:get().list
			end), bar, {
				key = function(id: any): string
					return id
				end,
			}),
		},
	}
end

return M
