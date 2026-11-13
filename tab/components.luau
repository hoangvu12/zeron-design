--!strict
-- The hand cursor on clickable controls (zgx's ui is read-only: see pointer.luau).
local ui = require("./pointer").ui
-- The left panel's Components tab, its body (the head with the title and the
-- tabs is the shell's), as the redesign's Board · Left panel draws it: a
-- search field, "Create component" (accent while something is selected: it
-- makes the selection reusable), then each Component on a card two a row (a
-- live preview on the field grey, r8, its name under it, 12px). A click
-- selects the Component and zooms to it. With none yet: "No components yet".
--
--   Components.Tab { L = L, source = source, api = function() return api end }

local Draw = require("./draw")
local Kit = require("./kit")
local Look = require("./look")

local M = {}

local THUMB_H = 104

-- A card: the Component drawn to fit its thumb (at most 2x), its name under it.
local function card(L: any, source: any, api: () -> any, c: any): Node
	return ui.component(function(): Node
		local size = ui.use_state({ w = 0, h = THUMB_H })
		local b = c.it.box
		local function view(): any
			local s = size:get()
			local w = math.max(s.w, 1)
			local inner_w, inner_h = math.max(w - 16, 1), THUMB_H - 16
			local zoom = math.min(inner_w / math.max(b.w, 1), inner_h / math.max(b.h, 1), 2)
			return { x = w / 2 - (b.x + b.w / 2) * zoom, y = THUMB_H / 2 - (b.y + b.h / 2) * zoom, zoom = zoom }
		end
		return ui.column {
			id = `comp-{c.id}`,
			grow = 1,
			basis = 0,
			min_w = 0,
			gap = 6,
			cursor = "pointer",
			on_click = function()
				source.selection:set({ c.id })
				local a = api()
				if a and a.zoom_to_selection then
					a.zoom_to_selection()
				end
			end,
			ui.div {
				w_full = true,
				h = THUMB_H,
				rounded = 8,
				bg = L.field,
				overflow = "hidden",
				hover = { bg = L.field_active },
				on_resize = function(s: { w: number, h: number })
					local now = size:peek()
					if math.abs(now.w - s.w) >= 1 then
						size:set({ w = s.w, h = THUMB_H })
					end
				end,
				ui.show(function(): boolean
					return size:get().w > 0
				end, ui.canvas {
					w_full = true,
					h = THUMB_H,
					view = view,
					draw = function(cv: Canvas)
						Draw.draw_root(cv, { nodes = table.move(c.root.nodes, 1, #c.root.nodes, 1, {}) })
					end,
				}),
			},
			ui.text { c.name or "Component", text_size = 12, color = L.fg, font = Look.UI, truncate = true, min_w = 0 },
		}
	end)({})
end

function M.Tab(props: { L: any, source: any, api: () -> any }): Node
	local L, source, api = props.L, props.source, props.api
	local q = ui.use_state("")
	local all = ui.computed(function(): { any }
		local out = {}
		for _, r in source.roots:get() do
			for _, it in r.nodes do
				if it.comp then
					table.insert(out, { id = it.id, name = it.name, root = r, it = it })
				end
			end
		end
		return out
	end)
	local list = ui.computed(function(): { any }
		local s = string.lower(q:get())
		local out = {}
		for _, c in all:get() do
			if s == "" or string.find(string.lower(c.name or ""), s, 1, true) then
				table.insert(out, c)
			end
		end
		return out
	end)
	local can_make = ui.computed(function(): boolean
		return #(source.selection:get() or {}) > 0
	end)
	local function make()
		local ids = source.selection:peek() or {}
		if #ids == 0 then
			return
		end
		local ops = {}
		for _, id in ids do
			table.insert(ops, { op = "update", id = id, props = { reusable = true } })
		end
		source.edit(ops, "Create component")
	end

	-- (accent while something is selected, else the field-grey one, greyed)
	local create = ui.presence(function(): string
		return if can_make:get() then "on" elseif #all:get() == 0 then "none" else "off"
	end, function(which: string): Node
		if which == "on" then
			return Kit.button(L, { id = "components-create", label = "Create component", icon = "component", kind = "primary", w = "100%", on_click = make })
		end
		return ui.div {
			w_full = true,
			opacity = if which == "off" then 0.6 else 1,
			Kit.button(L, { id = "components-create", label = "Create component", icon = "component", kind = "secondary", w = "100%", on_click = make }),
		}
	end, { w_full = true })

	local search = ui.row {
		w_full = true,
		h = 28,
		px = 8,
		gap = 6,
		rounded = 8,
		bg = L.field,
		items = "center",
		ui.div { color = L.faint, shrink = 0, Kit.icon("search", 13) },
		ui.input {
			id = "components-search",
			label = "Search components",
			value = function(): string
				return q:get()
			end,
			on_change = function(t: string)
				q:set(t)
			end,
			placeholder = "Search components…",
			placeholder_color = L.faint,
			grow = 1,
			min_w = 0,
			h = 26,
			px = 0,
			border = 0,
			bg = "#00000000",
			focus = { outline = 0 },
			text_size = 12,
			font = Look.UI,
			color = L.fg,
		},
	}

	local rows = ui.computed(function(): { any }
		local l = list:get()
		local out = {}
		for i = 1, #l, 2 do
			table.insert(out, { key = l[i].id .. ":" .. (if l[i + 1] then l[i + 1].id else ""), a = l[i], b = l[i + 1] })
		end
		return out
	end)

	local body = ui.presence(function(): string
		return if #all:get() == 0 then "empty" elseif #list:get() == 0 then "nomatch" else "grid"
	end, function(which: string): Node
		if which == "empty" then
			return Kit.empty(L, { title = "No components yet", body = "Select an element to create a component." })
		elseif which == "nomatch" then
			return Kit.empty(L, { icon = "search", title = "No matches", body = "No component's name has that in it." })
		end
		return ui.column {
			w_full = true,
			gap = 8,
			ui.each(rows, function(pr: any): Node
				return ui.row {
					w_full = true,
					gap = 8,
					card(L, source, api, pr.a),
					if pr.b then card(L, source, api, pr.b) else ui.div { grow = 1, basis = 0, min_w = 0 },
				}
			end, {
				key = function(pr: any): string
					return pr.key
				end,
			}),
		}
	end, { w_full = true })

	return ui.scroll {
		w_full = true,
		grow = 1,
		min_h = 0,
		px = 8,
		pt = 8,
		pb = 8,
		ui.column {
			w_full = true,
			gap = 6,
			-- (the search only once there's something to search)
			ui.show(function(): boolean
				return #all:get() > 0
			end, search),
			create,
			ui.div { h = 2 },
			body,
		},
	}
end

return M
