--!nonstrict
-- The hand cursor on clickable controls (zgx's ui is read-only: see pointer.luau).
local ui = require("./pointer").ui
-- (N2) The Variations bar (pure/anim/n2/README.md): under a node an agent
-- made versions of, on the board: "2 of 5 · Tighter hierarchy  ‹ ›  Use this ×".
-- ‹ › (or ← → while the bar has focus) shows another version in the node's
-- place (no undo step); Use this keeps the shown one and drops the others
-- (one undo step; Enter too); × goes back to the original (one undo step).
-- The versions live in the service (engine/variations.luau); the bar sends
-- `variation` ops.
--
--   VariationsBar.Layer { id, sets = State<{ [id] = { current, count,
--     names, original } }>, ix = () -> index?, view = () -> {x,y,zoom}?,
--     size = () -> {w,h}, hidden = () -> boolean, dark = () -> boolean,
--     edit = (ops, label) -> () }

local Kit = require("./kit")
local Look = require("./look")

local M = {}

M.H = 32 -- the bar's height
M.W_EST = 380 -- its width at most, for keeping it on screen
M.GAP = 36 -- under the node (below the selection's W×H pill)

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

-- Where a set's bar goes: under the node's box, kept on screen; nil when
-- the node is off screen (or not drawn). `b` = { x, y, w, h } in the Design.
function M.place(b: { number }, v: any, s: any): { number }?
	local x, y = v.x + b[1] * v.zoom, v.y + b[2] * v.zoom
	local w, h = b[3] * v.zoom, b[4] * v.zoom
	if x + w < 0 or y + h < 0 or x > s.w or y > s.h then
		return nil
	end
	local bx = math.clamp(x, 8, math.max(8, s.w - M.W_EST - 8))
	local by = y + h + M.GAP
	-- (a node running past the bottom: the bar sits at the bottom, over it)
	by = math.clamp(by, 8, math.max(8, s.h - M.H - 14))
	return { math.floor(bx), math.floor(by) }
end

-- Mounted by the shell over the Canvas (as the comment pins: inside the
-- Canvas, the board keeps the pointer from press to release and a button
-- there never gets its click). `view`, `ix`, `size` and `hidden` are
-- functions (the Canvas's api comes after the shell is built).
function M.Layer(o: any): Node
	local function L(): any
		return Look.of(o.dark())
	end
	-- the bars on screen: { list = { id }, at = { [id] = { x, y } } }
	local shown = ui.computed(function(): any
		local sets = o.sets:get() or {}
		local list, at = {}, {}
		if next(sets) == nil or (o.hidden and o.hidden()) then
			return { list = list, at = at }
		end
		local v = o.view()
		local s = o.size()
		local i = o.ix()
		if not v or not i then
			return { list = list, at = at }
		end
		for id in sets do
			local n = i.by[id]
			local p = if n then M.place(n.bounds, v, s) else nil
			if p then
				table.insert(list, id)
				at[id] = p
			end
		end
		table.sort(list)
		return { list = list, at = at }
	end)

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
		local function set(): any
			return (o.sets:get() or {})[id]
		end
		local function at(): { number }
			return shown:get().at[id] or { -1000, -1000 }
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
			absolute = true,
			left = function(): number
				return at()[1]
			end,
			top = function(): number
				return at()[2]
			end,
			h = M.H,
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
			ui.div { color = function(): string
				return L().agent
			end, shrink = 0, mr = 6, Kit.icon("sparkles", 13) },
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
				mr = 4,
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

	return ui.each(ui.computed(function(): { string }
		return shown:get().list
	end), bar, {
		key = function(id: any): string
			return id
		end,
	})
end

return M
