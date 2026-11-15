--!strict
-- The hand cursor on clickable controls (zgx's ui is read-only: see pointer.luau).
local Pointer = require("./pointer")
local ui = Pointer.ui
-- The Design editor, as the redesign lays it out (the Design "Design (pure)
-- — Editor UI", frames Editor dark / light / narrow): the Canvas under
-- floating islands, Look.EDGE (16) from the window and Look.INSET (8) from
-- each other; 40-high bars r12, panels r14, a 1px rim and a soft shadow:
--   - top left: the title pill (the Design's name, its save status, and an
--     agent's "is building" chip while a Screen is in progress);
--   - under it, the rail column: the sidebar island, the tools, the ⋯ island
--     (command palette); beside the rail, the left panel (Layers /
--     Components), resizable, hidden by the sidebar toggle;
--   - top right: the theme bar (the Design's Themes, segmented; the
--     properties toggle); under it the properties (272 wide) while something
--     is selected, and Find (Ctrl F) docked over them;
--   - bottom right, left of the properties: the zoom pill (− 50% +).
-- Right-click on the Canvas opens the menu for the selection.

local Canvas = require("./canvas")
local Components = require("./components")
local Variables = require("./variables")
local Toast = require("./toast")
local Draw = require("./draw")
local Kit = require("./kit")
local Layers = require("./layers")
local Look = require("./look")
local Picker = require("./picker")
local Palette = require("./palette")
local Props = require("./props")
local Play = require("./play")
local PlayPlace = require("./play_place")
local ProtoPanel = require("./proto_panel")
local IaClip = require("./ia_clip")

local M = {}

local TOOLS = {
	{ id = "move", icon = "move", tip = "Move  V" },
	{ id = "rectangle", icon = "rect", tip = "Rectangle  R" },
	{ id = "ellipse", icon = "ellipse", tip = "Ellipse  O" },
	{ id = "line", icon = "line", tip = "Line  L" },
	{ id = "pen", icon = "pen", tip = "Pen  P" },
	{ id = "text", icon = "text", tip = "Text  T" },
	{ id = "frame", icon = "frame", tip = "Frame  F" },
	{ id = "hand", icon = "hand", tip = "Hand  H" },
}

-- `prefs`: where the editor keeps what pen.dev keeps between sessions (the
-- left panel shown or hidden, and its width), plugin-wide: `get(key)` /
-- `set(key, value)`. init.luau hands zeron.store; the harness a ui.state.
-- What pen resets on reopening resets here too: the left tab, the
-- properties hidden, Variables, the tool, zoom and pan, the selection.
export type Prefs = { get: (key: string) -> any, set: (key: string, value: any) -> () }

function M.Shell(props: { source: any, dark: boolean?, id: string?, expose: ((api: any) -> ())?, expose_play: ((api: any) -> ())?, expose_preview: ((api: any) -> ())?, log: ((string) -> ())?, prefs: Prefs? }): Node
	local source = props.source
	-- (F6 C3) The selected interactions, shared by the Canvas (noodles) and
	-- the Prototype panel (a picked row): the service's, or the editor's own
	-- when the source has none (the harness's fixture).
	if type(source) == "table" and source.ia_sel == nil then
		source.ia_sel = ui.state(`shell.{props.id or "tab"}.ia_sel`, { key = "", list = {} } :: any)
	end
	local L = Look.of(props.dark)
	local tool = ui.use_state("move")
	local hover = ui.use_state(nil :: string?)
	local left_tab = ui.use_state("layers")
	-- The side panels show while the editor is wide enough (the left one at
	-- 1100 points, the properties at 760: pen.dev hides its left panel on a
	-- narrow window), unless the person showed or hid one themselves.
	local width = ui.use_state(0)
	local prefs = props.prefs
	local function auto_open(min_w: number, key: string?): any
		-- (a kept choice is there from the first build: no default flashes first)
		local kept = if key and prefs then prefs.get(key) else nil
		local pref = ui.use_state(if type(kept) == "boolean" then kept else nil :: boolean?)
		local function shown(p: boolean?, w: number): boolean
			if p ~= nil then
				return p
			end
			return w == 0 or w >= min_w
		end
		return {
			get = function(_self: any): boolean
				return shown(pref:get(), width:get())
			end,
			peek = function(_self: any): boolean
				return shown(pref:peek(), width:peek())
			end,
			set = function(_self: any, v: boolean)
				pref:set(v)
				if key and prefs then
					prefs.set(key, v)
				end
			end,
		}
	end
	local props_open = auto_open(760)
	local left_open = auto_open(1100, "left_open")
	-- The left panel's width: dragged at its right edge (pen's), kept.
	local LEFT_MIN, LEFT_MAX = 240, 640
	local kept_w = if prefs then prefs.get("left_w") else nil
	local left_w = ui.use_state(if type(kept_w) == "number" then math.clamp(kept_w, LEFT_MIN, LEFT_MAX) else Look.LEFT_W)
	local find_open = ui.use_state(false)
	local tokens = ui.use_state(nil :: any)
	local theme_pick = ui.use_state({} :: { [string]: string })
	local api: any = nil
	local api_ready = ui.use_state(false)

	local function load_tokens()
		if source.tokens then
			source.tokens(function(t: any)
				tokens:set(t)
			end)
		end
	end
	load_tokens()

	-- The selected nodes as their file has them, for the properties panel:
	-- asked again as the selection or what's drawn changes.
	local infos = ui.use_state({ key = "", list = {} :: { any } })
	local asked = 0
	-- (The panel is built again only when what it shows changed: an agent's
	-- edit elsewhere in the Design asks again and gets the same answer.)
	local shown_n = 0
	local function same(a: any, b: any): boolean
		if a == b then
			return true
		end
		if type(a) ~= "table" or type(b) ~= "table" then
			return false
		end
		for k, v in a do
			if not same(v, b[k]) then
				return false
			end
		end
		for k in b do
			if a[k] == nil then
				return false
			end
		end
		return true
	end
	ui.effect(function()
		local ids = source.selection:get() or {}
		local _ = source.roots:get()
		local ready = api_ready:get()
		asked += 1
		local mine = asked
		local got: { any } = {}
		local left = #ids
		if left == 0 then
			infos:set({ key = "none", list = {} })
			return
		end
		for k, id in ids do
			source.node(id, function(info: any?)
				if mine ~= asked then
					return
				end
				if info then
					local entry = table.clone(info)
					entry.id = id
					entry.node = table.clone(info.node or {})
					-- An Instance shows its Component's values where it doesn't
					-- override them (pen's Layout, Fill… on an Instance); edits
					-- still write overrides on the Instance.
					if entry.node.type == "instance" and type(info.resolved) == "table" then
						-- (Prototype keys stay as written: the Prototype tab shows the
						-- inherited ones greyed, from `resolved`.)
						local own = { id = true, type = true, ref = true, children = true, name = true, reusable = true, descendants = true, x = true, y = true, states = true, interactions = true }
						for k2, v2 in info.resolved do
							if entry.node[k2] == nil and not own[k2] then
								entry.node[k2] = v2
							end
						end
					end
					-- (Where its parent is, for alignment and laid-out x/y.)
					if ready and api and api.index then
						local ix = api.index:peek()
						local n = ix.by[id]
						local p = if n and n.parent ~= "" then ix.by[n.parent] else nil
						if p then
							entry.parent_box = { x = p.bounds[1], y = p.bounds[2], w = p.bounds[3], h = p.bounds[4] }
						end
					end
					got[k] = entry
				end
				left -= 1
				if left == 0 then
					local list = {}
					for i2 = 1, #ids do
						if got[i2] then
							table.insert(list, got[i2])
						end
					end
					local was = infos:peek()
					local ids_key = table.concat(ids, ",")
					if string.sub(was.key, 1, #ids_key + 1) == ids_key .. "#" and same(was.list, list) then
						return
					end
					shown_n += 1
					infos:set({ key = `{ids_key}#{shown_n}`, list = list })
				end
			end)
		end
	end)

	-- Right-click menu (pen-pop rows) ----------------------------------------------------
	local function edit(ops: { any }, label: string)
		source.edit(ops, label)
	end
	-- The right-click menu (Board · Menus): on a selection, Copy … Delete in
	-- its groups, Delete last in red; on the empty Canvas, Paste here and Zoom
	-- to fit. Shortcuts as the redesign writes them ("Ctrl ⇧ R", "Del").
	local copy_as_open = ui.use_state(false)
	local function context_menu(ids: { string }, _x: number, _y: number): { Node }?
		local items: { Node } = {}
		local any = #ids > 0
		local function item(label: string, shortcut: string?, fn: () -> (), o: { disabled: boolean?, danger: boolean? }?)
			table.insert(items, Kit.menu_item(L, { label = label, shortcut = shortcut, on_click = fn, disabled = o and o.disabled, danger = o and o.danger }))
		end
		local function sep()
			table.insert(items, Kit.menu_sep(L))
		end
		local function each(fn: (id: string) -> any, label: string)
			local ops = {}
			for _, id in ids do
				table.insert(ops, fn(id))
			end
			edit(ops, label)
		end
		local function paste(into: string?)
			-- (F6 C3) interactions copied last: appended to the selection
			if api and api.paste_interactions and api.paste_interactions() then
				return
			end
			edit({ { op = "paste", into = into } }, "Paste")
		end
		if any then
			item("Copy", "Ctrl C", function()
				if source.copy then
					source.copy(ids, false)
					IaClip.layers_copied()
				end
			end)
			if source.code then
				local sub: any = {
					open = copy_as_open,
					label = "Copy as",
					Kit.menu_item(L, {
						label = "HTML + Tailwind",
						on_click = function()
							source.code({ ids = ids, css = "tailwind" }, function(r: any)
								if type(r) == "table" and r.code then
									-- Guarded: without the clipboard grant, write throws and would kill the tab.
									pcall(ui.clipboard.write, r.code)
								end
							end)
						end,
					}),
					Kit.menu_item(L, {
						label = "HTML + CSS",
						on_click = function()
							source.code({ ids = ids, css = "css" }, function(r: any)
								if type(r) == "table" and r.code then
									pcall(ui.clipboard.write, r.code)
								end
							end)
						end,
					}),
				}
				for k, v in Kit.pop_style(L) do
					sub[k] = v
				end
				sub.w = 180
				sub.text_size = 12
				sub.font = Look.UI
				sub.color = L.fg
				table.insert(items, ui.submenu(sub))
			end
			item("Paste here", nil, function()
				paste(if #ids == 1 then ids[1] else nil)
			end)
			item("Paste to replace", "Ctrl ⇧ R", function()
				edit({ { op = "paste", into = ids[1] }, { op = "delete", ids = ids } }, "Paste to replace")
			end)
			sep()
			item("Bring to front", "]", function()
				each(function(id)
					return { op = "reorder", id = id, to = "front" }
				end, "Bring to front")
			end)
			item("Send to back", "[", function()
				each(function(id)
					return { op = "reorder", id = id, to = "back" }
				end, "Send to back")
			end)
			sep()
			item("Group selection", "Ctrl G", function()
				edit({ { op = "wrap", ids = ids, as = "group" } }, "Group")
			end)
			item("Frame selection", "Ctrl Alt G", function()
				edit({ { op = "wrap", ids = ids, as = "frame" } }, "Frame selection")
			end)
			item("Add flex layout", "⇧ A", function()
				edit({ { op = "wrap", ids = ids, as = "frame", layout = "vertical" } }, "Add flex layout")
			end)
			sep()
			item("Create component", "Ctrl Alt K", function()
				each(function(id)
					return { op = "update", id = id, props = { reusable = true } }
				end, "Create component")
			end)
			sep()
			item("Flip horizontal", "⇧ H", function()
				each(function(id)
					return { op = "update", id = id, props = { flipX = true } }
				end, "Flip")
			end)
			item("Flip vertical", "⇧ V", function()
				each(function(id)
					return { op = "update", id = id, props = { flipY = true } }
				end, "Flip")
			end)
			sep()
			item("Delete", "Del", function()
				edit({ { op = "delete", ids = ids } }, "Delete")
				source.selection:set({})
			end, { danger = true })
		else
			item("Paste here", nil, function()
				paste(nil)
			end)
			sep()
			item("Zoom to fit", "⇧ 1", function()
				if api then
					api.fit()
				end
			end)
		end
		return items
	end

	-- Islands ---------------------------------------------------------------------------------
	-- E from the window, I between islands; the second row (the rail column,
	-- the left panel, the properties) starts under the 40-high bars.
	local E, I, RW, BAR, RAIL = Look.EDGE, Look.INSET, Look.RIGHT_W, Look.BAR_H, Look.RAIL_W
	local ROW2 = E + BAR + I
	local PANEL_X = E + RAIL + I -- the left panel's left
	local CLEAR = "#00000000"
	local function LWf(): number
		return left_w:get()
	end

	-- Title pill: the name (13/600), the save status, and while an agent is
	-- building a Screen, its chip ("● Claude is building Activity", +N more).
	local function save_kind(): string
		local s = if source.save then source.save:get() else nil
		if type(s) ~= "string" or s == "saved" then
			return "saved"
		elseif s == "saving" then
			return "saving"
		end
		return "error"
	end
	local SAVE = {
		saved = { icon = "cloudCheck", text = "Saved" },
		saving = { icon = "loader", text = "Saving…" },
		error = { icon = "cloudOff", text = "Not saved · retrying" },
	}
	local building = ui.computed(function(): { label: string, more: number }?
		local seen: { [string]: boolean } = {}
		local list: { { by: any, screen: string } } = {}
		for _, r in source.roots:get() or {} do
			local top = r.nodes and r.nodes[1]
			for _, it in r.nodes or {} do
				if it.wip then
					local key = `{it.by or ""}|{r.id or (top and top.id) or ""}`
					if not seen[key] then
						seen[key] = true
						table.insert(list, { by = it.by, screen = (top and top.name) or "a Screen" })
					end
				end
			end
		end
		if #list == 0 then
			return nil
		end
		local first = list[1]
		local who = if source.chat_title and first.by then source.chat_title(first.by) else nil
		return { label = `{who or "An agent"} is building {first.screen}`, more = #list - 1 }
	end)
	local title = Kit.bar(L, {
		id = "titlebar",
		left = E,
		top = E,
		max_w = function(): number
			local w = width:get()
			return if w > 0 then math.max(200, w - E * 2 - I - 160) else 900
		end,
		px = 12,
		gap = 10,
		direction = "row",
		items = "center",
		ui.text { source.name or "Design", text_size = 13, weight = 600, color = L.fg, font = Look.UI, truncate = true, min_w = 0, shrink = 1 },
		ui.presence(save_kind, function(kind: string): Node
			local s = SAVE[kind]
			local c = if kind == "error" then L.danger else L.faint
			return ui.row {
				id = "save-status",
				gap = 5,
				items = "center",
				shrink = 0,
				ui.div { color = c, Kit.icon(s.icon, 14) },
				ui.text { s.text, text_size = 12, color = c, font = Look.UI },
			}
		end, { direction = "row", items = "center", shrink = 0 }),
		ui.presence(function(): string
			return if building:get() then "on" else "off"
		end, function(on: string): Node
			if on == "off" then
				return ui.div {}
			end
			return ui.row {
				gap = 10,
				items = "center",
				min_w = 0,
				shrink = 1,
				ui.div { w = 1, h = 16, bg = L.border, shrink = 0 },
				ui.row {
					id = "agent-status",
					h = 24,
					px = 8,
					gap = 6,
					rounded = 999,
					bg = L.agent_soft,
					items = "center",
					min_w = 0,
					shrink = 1,
					ui.div { w = 6, h = 6, rounded = 3, bg = L.agent, shrink = 0 },
					ui.text {
						function(): string
							local b = building:get()
							return if b then b.label else ""
						end,
						text_size = 12,
						weight = 500,
						color = L.agent_fg,
						font = Look.UI,
						truncate = true,
						min_w = 0,
					},
					ui.text {
						function(): string
							local b = building:get()
							return if b and b.more > 0 then `+{b.more}` else ""
						end,
						text_size = 12,
						weight = 500,
						color = L.agent_fg,
						font = Look.UI,
						shrink = 0,
					},
				},
			}
		end, { direction = "row", items = "center", min_w = 0, shrink = 1 }),
	})

	-- The left panel's tabs: 32px icon buttons at the head's right (active:
	-- accent_soft, the icon in accent).
	local TAB_NAMES = { layers = "Layers", components = "Components" }
	local function tab_btn(id: string, label: string, icon: string): Node
		return ui.button {
			id = `left-tab-{id}`,
			label = label,
			tooltip = Kit.tip(L, label),
			tooltip_placement = { side = "bottom", align = "center", offset = 6 },
			w = 32,
			h = 32,
			p = 0,
			rounded = 8,
			border = 0,
			items = "center",
			justify = "center",
			shrink = 0,
			bg = function(): string
				return if left_tab:get() == id then L.accent_soft else CLEAR
			end,
			focus = { outline = 0 },
			hover = { bg = L.hover },
			color = function(): string
				return if left_tab:get() == id then L.accent else L.muted
			end,
			on_click = function()
				left_tab:set(id)
			end,
			Kit.icon(icon, 16),
		}
	end

	-- The Components tab, as pen's: a search field, Create Component, a hint,
	-- then each Component on a 173 square card (two a row), its name under it.
	local comp_q = ui.use_state("")
	local function components(): Node
		local list = ui.computed(function(): { any }
			local q = string.lower(comp_q:get())
			local out = {}
			for _, r in source.roots:get() do
				for _, it in r.nodes do
					if it.comp and (q == "" or string.find(string.lower(it.name or ""), q, 1, true)) then
						table.insert(out, { id = it.id, name = it.name, root = r, it = it })
					end
				end
			end
			return out
		end)
		local can_make = ui.computed(function(): boolean
			return #(source.selection:get() or {}) > 0
		end)
		local function card_of(c: any): Node
			local b = c.it.box
			local inner = 157
			local zoom = math.min(inner / math.max(b.w, 1), inner / math.max(b.h, 1), 2)
			return ui.column {
				id = `comp-{c.id}`,
				w = 173,
				min_w = 173,
				shrink = 0,
				gap = 8,
				on_click = function()
					source.selection:set({ c.id })
					if api then
						api.zoom_to_selection()
					end
				end,
				ui.div {
					w = 173,
					h = 173,
					rounded = 4,
					bg = L.board,
					overflow = "hidden",
					ui.canvas {
						w = 173,
						h = 173,
						view = function(): any
							return { x = 86.5 - (b.x + b.w / 2) * zoom, y = 86.5 - (b.y + b.h / 2) * zoom, zoom = zoom }
						end,
						draw = function(cv: Canvas)
							Draw.draw_root(cv, { nodes = table.move(c.root.nodes, 1, #c.root.nodes, 1, {}) })
						end,
					},
				},
				ui.text { c.name or "Component", text_size = 13, color = L.fg, font = Look.UI, truncate = true },
			}
		end
		local pairs_ = ui.computed(function(): { any }
			local l = list:get()
			local out = {}
			for i = 1, #l, 2 do
				table.insert(out, { key = l[i].id .. ":" .. (if l[i + 1] then l[i + 1].id else ""), a = l[i], b = l[i + 1] })
			end
			return out
		end)
		return ui.scroll {
			w_full = true,
			grow = 1,
			min_h = 0,
			px = 11,
			pt = 15,
			pb = 12,
			ui.column {
				w_full = true,
				gap = 8,
				ui.row {
					w_full = true,
					h = 32,
					rounded = 8,
					bg = L.search_bg,
					border = 1,
					border_color = L.search_br,
					items = "center",
					ui.div { w = 24, h = 32, items = "center", justify = "center", pl = 4, color = L.pre, Kit.icon("search", 14) },
					ui.input {
						id = "components-search",
						label = "Search components",
						value = function(): string
							return comp_q:get()
						end,
						on_change = function(t: string)
							comp_q:set(t)
						end,
						placeholder = "Search components…",
						placeholder_color = L.pre,
						grow = 1,
						min_w = 0,
						h = 30,
						px = 4,
						border = 0,
						bg = "#00000000",
						focus = { outline = 0 },
						text_size = 13,
						font = Look.UI,
						color = L.fg,
					},
				},
				ui.button {
					id = "components-create",
					label = "Create Component",
					w_full = true,
					h = 32,
					px = 12,
					gap = 6,
					rounded = 8,
					border = 0,
					items = "center",
					justify = "center",
					bg = L.primary,
					opacity = function(): number
						return if can_make:get() then 1 else 0.5
					end,
					on_click = function()
						local ids = source.selection:peek() or {}
						if #ids == 0 then
							return
						end
						local ops = {}
						for _, id in ids do
							table.insert(ops, { op = "update", id = id, props = { reusable = true } })
						end
						edit(ops, "Create component")
					end,
					ui.div { color = L.primary_fg, Kit.icon("component", 14) },
					ui.text { "Create Component", text_size = 13, weight = 500, color = L.primary_fg, font = Look.UI },
				},
				ui.show(function(): boolean
					return not can_make:get()
				end, ui.div { w_full = true, px = 2, ui.text { "Select an element to create a component.", text_size = 13, color = L.pre, font = Look.UI } }),
				ui.column {
					w_full = true,
					mt = 3,
					gap = 8,
					ui.each(pairs_, function(pr: any): Node
						return ui.row { w_full = true, gap = 8, card_of(pr.a), if pr.b then card_of(pr.b) else ui.div {} }
					end, {
						key = function(pr: any): string
							return pr.key
						end,
					}),
				},
			},
		}
	end

	-- Variables, as pen's: a floating table beside the rail (640 wide, r20):
	-- the Theme axis as tabs, a dark header (Name | each Theme value, or
	-- Value), a row a variable (41 high: its name, then per column a colour's
	-- swatch, hex and opacity, or a number or text), "+ Add variable".
	local vars_open = ui.use_state(false)
	local function token_value(r: any, axis: any, col: string): any
		local value = nil
		for _, v in r.values do
			if not axis or (v.theme and v.theme[axis.axis] == col) or (not v.theme and value == nil) then
				value = v.value
			end
		end
		return value
	end
	local function set_token(r: any, axis: any, cols: { string }, col: string, v: any)
		local token: any = { type = r.type }
		if axis then
			local vals = {}
			for _, c2 in cols do
				table.insert(vals, { value = if c2 == col then v else token_value(r, axis, c2), theme = { [axis.axis] = c2 } })
			end
			token.value = vals
		else
			token.value = v
		end
		source.edit({ { op = "tokens", tokens = { [r.name] = token } } }, "Change variable")
		load_tokens()
	end
	local function var_cell(r: any, axis: any, cols: { string }, col: string): Node
		local value = token_value(r, axis, col)
		if r.type == "color" and type(value) == "string" then
			local c = Picker.parse(value)
			local hex = if c then string.upper(string.sub(Picker.hex({ r = c.r, g = c.g, b = c.b, a = 1 }), 2, 7)) else value
			local alpha = if c then math.floor(c.a * 100 + 0.5) else 100
			return ui.row {
				grow = 1,
				basis = 0,
				min_w = 0,
				gap = 1,
				items = "center",
				ui.div {
					grow = 1,
					min_w = 0,
					Kit.field(L, {
						tip = `{r.name} {col}`,
						radius = { tl = 6, bl = 6, tr = 0, br = 0 },
						leading = ui.div { w = 24, h = 24, shrink = 0, items = "center", justify = "center", ui.div { w = 16, h = 16, rounded = 4, bg = value, border = 1, border_color = "#7f7f7f33" } },
						value = function(): string?
							return hex
						end,
						commit = function(t: string)
							local h = Picker.parse("#" .. string.gsub(t, "#", ""))
							if h then
								h.a = if c then c.a else 1
								set_token(r, axis, cols, col, Picker.hex(h))
							end
						end,
					}),
				},
				ui.div {
					w = 56,
					shrink = 0,
					Kit.field(L, {
						tip = `{r.name} {col} opacity`,
						radius = { tl = 0, bl = 0, tr = 6, br = 6 },
						unit = "%",
						value = function(): string?
							return tostring(alpha)
						end,
						commit = function(t: string)
							local a = tonumber(t)
							if a and c then
								c.a = math.clamp(a, 0, 100) / 100
								set_token(r, axis, cols, col, Picker.hex(c))
							end
						end,
					}),
				},
			}
		end
		local shown = if type(value) == "table" then "…" else tostring(value or "")
		return ui.div {
			grow = 1,
			basis = 0,
			min_w = 0,
			Kit.field(L, {
				tip = `{r.name} {col}`,
				value = function(): string?
					return shown
				end,
				commit = function(text: string)
					local v: any = if r.type == "number" then tonumber(text) else text
					if v ~= nil then
						set_token(r, axis, cols, col, v)
					end
				end,
			}),
		}
	end
	-- A variable's ⋯: Duplicate, Delete.
	local function var_menu(r: any, axis: any, cols: { string }): Node
		return ui.component(function(): Node
			local open = ui.use_state(false)
			local function token_of(): any
				local token: any = { type = r.type }
				if axis then
					local vals = {}
					for _, c in cols do
						table.insert(vals, { value = token_value(r, axis, c), theme = { [axis.axis] = c } })
					end
					token.value = vals
				else
					token.value = token_value(r, nil, cols[1])
				end
				return token
			end
			local mp: any = {
				open = open,
				label = `{r.name} actions`,
				placement = { side = "bottom", align = "end", offset = 4 },
				anchor = Kit.icon_btn(L, { icon = "dots", label = `{r.name} actions`, size = 24, icon_size = 16, on_click = function()
					open:set(not open:peek())
				end }),
				Kit.menu_item(L, {
					label = "Duplicate",
					on_click = function()
						local name = r.name .. "-copy"
						source.edit({ { op = "tokens", tokens = { [name] = token_of() } } }, "Duplicate variable")
						load_tokens()
					end,
				}),
				Kit.menu_item(L, {
					label = "Delete",
					danger = true,
					on_click = function()
						source.edit({ { op = "tokens", tokens = { [r.name] = "__null" } } }, "Delete variable")
						load_tokens()
					end,
				}),
			}
			for k, v in Kit.pop_style(L) do
				mp[k] = v
			end
			mp.w = 160
			return ui.menu(mp)
		end)({})
	end
	local function variables_panel(): Node
		return ui.presence(function(): string
			local t = tokens:get()
			return if t then tostring(#(t.rows or {})) .. ":" .. tostring(t.axes and #t.axes or 0) else "loading"
		end, function(_: string): Node
			local t = tokens:peek() or { rows = {} }
			local axis = t.axes and t.axes[1]
			local cols = if axis then axis.values else { "Value" }
			local head: any = {
				w_full = true,
				h = 33,
				items = "center",
				bg = L.table_head,
				ui.div { w = 191, pl = 12, pr = 8, ui.text { "Name", text_size = 11, weight = 700, color = L.fg, font = Look.UI } },
			}
			for _, c in cols do
				table.insert(head, ui.div { grow = 1, basis = 0, px = 8, ui.text { tostring(c), text_size = 11, weight = 700, color = L.fg, font = Look.UI, truncate = true } })
			end
			table.insert(head, ui.div { w = 34 })
			local body: any = { w_full = true, gap = 0 }
			for _, r in t.rows or {} do
				local row: any = {
					w_full = true,
					h = 41,
					items = "center",
					border_sides = { 0, 0, 1, 0 },
					border_color = L.line,
					ui.div {
						w = 191,
						pl = 8,
						pr = 8,
						shrink = 0,
						Kit.field(L, {
							tip = "Variable name",
							fg = L.fg,
							mono = false,
							leading = ui.div { w = 24, h = 24, shrink = 0, items = "center", justify = "center", color = L.pre, Kit.icon(if r.type == "color" then "drop" else "braces", 12) },
							value = function(): string?
								return r.name
							end,
							-- (renames it and every reference to it)
							commit = function(text: string)
								if text ~= "" and text ~= r.name then
									source.edit({ { op = "renameToken", from = r.name, to = text } }, "Rename variable")
									load_tokens()
								end
							end,
						}),
					},
				}
				for _, c in cols do
					table.insert(row, ui.div { grow = 1, basis = 0, min_w = 0, px = 4, ui.row { w_full = true, var_cell(r, axis, cols, c) } })
				end
				table.insert(row, ui.div { w = 34, items = "center", justify = "center", var_menu(r, axis, cols) })
				table.insert(body, ui.row(row))
			end
			if #(t.rows or {}) == 0 then
				table.insert(body, ui.div { w_full = true, p = 16, ui.text { "No variables yet.", text_size = 13, color = L.pre, font = Look.UI } })
			end
			local tabs: any = { gap = 0, items = "center" }
			for k, v in (if axis then axis.values else { "Theme" }) do
				table.insert(
					tabs,
					ui.button {
						label = tostring(v),
						h = 24,
						px = 4,
						rounded = 6,
						border = 0,
						bg = if k == 1 then L.theme_tab else "#00000000",
						ui.text { tostring(v), text_size = 11, color = L.fg, font = Look.UI },
					}
				)
			end
			return ui.column {
				w_full = true,
				ui.row {
					w_full = true,
					h = 33,
					pl = 7,
					pr = 7,
					pb = 8,
					items = "center",
					ui.row(tabs),
					ui.div { grow = 1 },
					Kit.icon_btn(L, {
						icon = "x",
						label = "Close",
						size = 24,
						icon_size = 16,
						on_click = function()
							vars_open:set(false)
						end,
					}),
				},
				ui.row(head),
				ui.scroll { w_full = true, h = math.min(math.max(#(t.rows or {}), 1) * 41, 369), ui.column(body) },
				ui.button {
					label = "Add variable",
					h = 32,
					ml = 8,
					my = 6,
					px = 6,
					gap = 6,
					rounded = 6,
					border = 0,
					items = "center",
					bg = "#00000000",
					hover = { bg = L.hover },
					on_click = function()
						local name = "color/new"
						local n = 1
						local taken: { [string]: boolean } = {}
						for _, r in t.rows or {} do
							taken[r.name] = true
						end
						while taken[name] do
							n += 1
							name = `color/new-{n}`
						end
						source.edit({ { op = "tokens", tokens = { [name] = { type = "color", value = "#000000" } } } }, "Add variable")
						load_tokens()
					end,
					ui.div { color = L.fg, Kit.icon("plus", 12) },
					ui.text { "Add variable", text_size = 12, color = L.fg, font = Look.UI },
				},
			}
		end, { w_full = true })
	end
	local _ = variables_panel -- (the table before tab/variables.luau; kept unused)
	local vars_island = Variables.Panel {
		L = L,
		source = source,
		tokens = tokens,
		reload = load_tokens,
		theme_pick = theme_pick,
		close = function()
			vars_open:set(false)
		end,
		left = function(): number
			return if left_open:get() then PANEL_X + LWf() + I else PANEL_X
		end,
		top = ROW2,
	}

	-- The left panel (r14, p8, gap 6): its head (the tab's name 13/600, the
	-- Layers / Components tabs at the right), a line, then the tab's body.
	local left = Kit.island(L, {
		id = "left-panel",
		left = PANEL_X,
		top = ROW2,
		bottom = E + Look.COMPOSER_H,
		w = LWf,
		p = 8,
		gap = 6,
		overflow = "hidden",
		ui.row {
			w_full = true,
			h = 32,
			gap = 2,
			items = "center",
			shrink = 0,
			ui.text {
				function(): string
					return TAB_NAMES[left_tab:get()] or ""
				end,
				text_size = 13,
				weight = 600,
				color = L.fg,
				font = Look.UI,
				truncate = true,
				grow = 1,
				min_w = 0,
			},
			tab_btn("layers", "Layers", "layers"),
			tab_btn("components", "Components", "component"),
		},
		ui.div { w_full = true, h = 1, bg = L.border, shrink = 0 },
		ui.presence(left_tab, function(which: string): Node
			if which == "components" then
				return Components.Tab {
					L = L,
					source = source,
					api = function(): any
						return api
					end,
				}
			end
			return ui.column {
				w_full = true,
				grow = 1,
				min_h = 0,
				Layers.Layers { L = L, source = source, hover = hover },
			}
		end, { w_full = true, grow = 1, min_h = 0 }),
	})

	-- A rail button: 32 square, r8; on, accent_soft with the icon in accent
	-- (off, muted). Its tooltip at the right ("Move  V": the key greyed).
	local function rail_btn(o: { id: string, label: string, icon: string, on: (() -> boolean)?, on_click: () -> () }): Node
		local function on(): boolean
			return o.on ~= nil and o.on()
		end
		return ui.button {
			id = o.id,
			label = o.label,
			tooltip = Kit.tip(L, o.label),
			tooltip_placement = { side = "right", align = "center", offset = 8 },
			w = 32,
			h = 32,
			p = 0,
			rounded = 8,
			border = 0,
			items = "center",
			justify = "center",
			shrink = 0,
			focus = { outline = 0 },
			color = function(): string
				return if on() then L.accent else L.muted
			end,
			bg = function(): string
				return if on() then L.accent_soft else CLEAR
			end,
			hover = { bg = L.hover },
			on_click = o.on_click,
			Kit.icon(o.icon, 16),
		}
	end
	-- The shapes share one button (the last one picked) with a ▾ under it
	-- opening Primitives: Rectangle, Ellipse, Line, a check on the current.
	local SHAPES = { rectangle = true, ellipse = true, line = true }
	local shape = ui.use_state("rectangle")
	ui.effect(function()
		local t = tool:get()
		if SHAPES[t] and shape:peek() ~= t then
			shape:set(t)
		end
	end)
	local shapes_open = ui.use_state(false)
	local function tool_of(id: string): any
		for _, t in TOOLS do
			if t.id == id then
				return t
			end
		end
		return TOOLS[1]
	end
	local function shape_item(id: string): Node
		local t = tool_of(id)
		local name, key = string.match(t.tip, "^(.-)%s%s+(.+)$")
		return ui.menu_item {
			label = name or t.tip,
			on_click = function()
				tool:set(id)
			end,
			h = 28,
			px = 8,
			rounded = 6,
			hover = { bg = L.pop_hl },
			ui.row {
				w_full = true,
				h = 28,
				gap = 8,
				items = "center",
				ui.div {
					w = 13,
					color = L.fg,
					opacity = function(): number
						return if shape:get() == id then 1 else 0
					end,
					Kit.icon("check", 13),
				},
				ui.div { color = L.muted, Kit.icon(t.icon, 14) },
				ui.text { name or t.tip, text_size = 12, color = L.fg, font = Look.UI, grow = 1 },
				if key then ui.text { key, text_size = 12, color = L.faint, font = Look.UI } else ui.div {},
			},
		}
	end
	local shapes_menu: any = {
		open = shapes_open,
		label = "Primitives",
		placement = { side = "right", align = "start", offset = 12 },
		anchor = ui.button {
			id = "tool-primitives",
			label = "Primitives",
			tooltip = Kit.tip(L, "Primitives"),
			tooltip_placement = { side = "right", align = "center", offset = 8 },
			w = 32,
			h = 10,
			p = 0,
			rounded = 4,
			border = 0,
			items = "center",
			justify = "center",
			bg = CLEAR,
			hover = { bg = L.hover },
			color = L.faint,
			on_click = ui.toggle(shapes_open),
			Kit.icon("chevDown", 10),
		},
		shape_item("rectangle"),
		shape_item("ellipse"),
		shape_item("line"),
	}
	for k, v in Kit.pop_style(L) do
		shapes_menu[k] = v
	end
	shapes_menu.w = 200
	local rail_btns: any = { gap = 2, items = "center" }
	for _, t in TOOLS do
		if t.id == "rectangle" then
			-- the shape button: its icon and tip follow the shape picked
			table.insert(
				rail_btns,
				ui.column {
					w = 32,
					h = 42,
					shrink = 0,
					ui.presence(shape, function(which: string): Node
						local st = tool_of(which)
						return rail_btn {
							id = "tool-rectangle",
							label = st.tip,
							icon = st.icon,
							on = function(): boolean
								return tool:get() == which
							end,
							on_click = function()
								tool:set(which)
							end,
						}
					end),
					ui.menu(shapes_menu),
				}
			)
		elseif not SHAPES[t.id] then
			table.insert(
				rail_btns,
				rail_btn {
					id = `tool-{t.id}`,
					label = t.tip,
					icon = t.icon,
					on = function(): boolean
						return tool:get() == t.id
					end,
					on_click = function()
						tool:set(t.id)
					end,
				}
			)
		end
	end
	table.insert(rail_btns, ui.div { w = 20, h = 1, bg = L.border, shrink = 0 })
	table.insert(
		rail_btns,
		rail_btn {
			id = "tool-variables",
			label = "Variables",
			icon = "braces",
			on = function(): boolean
				return vars_open:get()
			end,
			on_click = function()
				vars_open:set(not vars_open:peek())
			end,
		}
	)
	table.insert(
		rail_btns,
		rail_btn {
			id = "layers-find-toggle",
			label = "Find layers  Ctrl F",
			icon = "search",
			on = function(): boolean
				return find_open:get()
			end,
			on_click = function()
				find_open:set(not find_open:peek())
			end,
		}
	)
	-- The rail column, under the title pill: the sidebar island (40 square),
	-- the tools island (p4, gap 2), the ⋯ island (the command palette).
	local function bar_square(id: string, child: Node): Node
		return Kit.bar(L, {
			id = id,
			absolute = false,
			w = RAIL,
			h = RAIL,
			p = 3, -- (+1 of the rim: the button 4 in)
			items = "center",
			justify = "center",
			child,
		})
	end
	local sidebar = ui.div {
		absolute = true,
		left = E,
		top = ROW2,
		bar_square(
			"sidebar-island",
			rail_btn {
				id = "sidebar-toggle",
				label = "Sidebar",
				icon = "panelLeft",
				on = function(): boolean
					return left_open:get()
				end,
				on_click = function()
					left_open:set(not left_open:peek())
				end,
			}
		),
	}
	local palette_open = ui.use_state(false)
	local shortcuts_open = ui.use_state(false)
	local rail = ui.column {
		absolute = true,
		left = E,
		top = ROW2 + RAIL + I,
		w = RAIL,
		gap = I,
		Kit.bar(L, {
			id = "rail",
			absolute = false,
			direction = "column",
			w = RAIL,
			p = 3,
			items = "center",
			ui.column(rail_btns),
		}),
		bar_square(
			"palette-island",
			rail_btn {
				id = "palette-toggle",
				label = "Command palette  Ctrl P",
				icon = "dots",
				on = function(): boolean
					return palette_open:get()
				end,
				on_click = function()
					palette_open:set(not palette_open:peek())
				end,
			}
		),
	}

	-- The properties show only while something is selected (pen hides them
	-- with nothing selected), and while the person hasn't hidden them.
	-- The properties' tab, Design | Prototype (Figma's), kept for the tab's
	-- session; the Prototype tab shows the Flows with nothing selected.
	local panel_tab = ui.state(`design.{props.id or "design"}.panel_tab`, "design")
	local show_all_links = ui.state(`design.{props.id or "design"}.show_all_links`, false)
	local props_shown = ui.computed(function(): boolean
		return props_open:get() and (#(source.selection:get() or {}) > 0 or panel_tab:get() == "prototype")
	end)

	-- Play (proto-step1-spec §6): from the selected Screen, else the flow
	-- (a menu when there are several), else the first Screen.
	local playing = ui.use_state(nil :: any)
	local play_menu = ui.use_state(false)
	local function screens_list(): { any }
		local out = {}
		for _, r in source.roots:peek() do
			local it = r.nodes and r.nodes[1]
			if it and it.t == "frame" and not it.comp then
				table.insert(out, { id = r.id, name = it.name or r.id })
			end
		end
		return out
	end
	local function flows_list(): { any }
		return if source.flows then source.flows:peek() or {} else {}
	end
	-- (step 6 P4) The inline Preview (Shift+Space, or the phone button by ▶):
	-- Play in `mode = "preview"` in an island left of the properties, resized
	-- by its left and bottom edges (Shift keeps the ratio), its size kept. A
	-- Screen clicked on the canvas plays there; Follow prototype selects the
	-- Screen it shows. One per tab, and full Play closes it (never two Plays).
	-- (`pre` holds its parts, as Play's `dev`: few new locals here)
	local pre: any = {
		on = ui.use_state(nil :: any), -- { start, flow, n } while open
		size = ui.state("design.preview_size", PlayPlace.PREVIEW_SIZE), -- zgx-lint: allow(state-in-component)
		live = ui.use_state(nil :: any), -- the size while an edge is dragged
		hgt = ui.use_state(0), -- the editor's height
		n = 0,
		api = nil,
		shown = nil, -- the Screen it shows
	}
	-- The Screen (top-level frame, not a component) holding layer `id`.
	function pre.screen_of(id: string?): string?
		if not (id and api and api.index) then
			return nil
		end
		local ix = api.index:peek()
		local n = ix.by[id]
		while n and n.parent ~= "" and ix.by[n.parent] do
			n = ix.by[n.parent]
		end
		return if n and n.it.t == "frame" and not n.it.comp then n.id else nil
	end
	function pre.close()
		if pre.on:peek() then
			pre.on:set(nil)
		end
		pre.api, pre.shown = nil, nil
		if props.expose_preview then
			props.expose_preview(nil)
		end
	end
	local function play_from(start: string, flow: string?)
		play_menu:set(false)
		pre.close() -- (step 6 P4: full Play closes the Preview)
		playing:set({ start = start, flow = flow, n = (playing:peek() and playing:peek().n or 0) + 1 })
	end
	local function start_play(from_menu: boolean?)
		local ids = source.selection:peek() or {}
		local sel_screen = pre.screen_of(ids[1])
		local flows = flows_list()
		if sel_screen and not from_menu then
			local fname = nil
			for _, f in flows do
				if f.start == sel_screen then
					fname = f.name
				end
			end
			play_from(sel_screen, fname)
		elseif #flows > 1 and not from_menu then
			play_menu:set(true)
		elseif #flows >= 1 then
			play_from(flows[1].start, flows[1].name)
		else
			local list = screens_list()
			if list[1] then
				play_from(list[1].id, nil)
			else
				Toast.show { icon = "play", title = "Nothing to play", body = "The Design has no Screen yet." }
			end
		end
	end
	-- (step 6 P4) Open the Preview at the selected Screen, else the first
	-- flow, else the first Screen; or close it.
	function pre.toggle()
		if pre.on:peek() then
			pre.close()
			if api and api.focus then
				api.focus()
			end
			return
		end
		local start = pre.screen_of((source.selection:peek() or {})[1])
		local flows = flows_list()
		if not start and flows[1] then
			start = flows[1].start
		end
		if not start then
			local list = screens_list()
			start = list[1] and list[1].id
		end
		if not start then
			Toast.show { icon = "play", title = "Nothing to preview", body = "The Design has no Screen yet." }
			return
		end
		local fname = nil
		for _, f in flows do
			if f.start == start then
				fname = f.name
			end
		end
		pre.n += 1
		pre.shown = start
		pre.on:set({ start = start, flow = fname, n = pre.n })
	end
	-- (a Screen clicked on the canvas: the Preview plays it, no transition)
	ui.effect(function()
		local ids = source.selection:get() or {}
		local s = pre.screen_of(ids[1])
		if s and pre.api and s ~= pre.shown then
			pre.shown = s
			ui.after(0, function()
				if pre.api then
					pre.api.jump(s)
				end
			end)
		end
	end)
	-- The island's size now (dragged, else kept), inside the editor.
	function pre.wh(): (number, number)
		local s = pre.live:get() or pre.size:get() or PlayPlace.PREVIEW_SIZE
		local maxh = math.max(PlayPlace.PREVIEW_MIN.h, pre.hgt:get() - ROW2 - E)
		return s.w, math.min(s.h, maxh)
	end

	-- Top right, the theme bar (h40 r12, p4 gap 6): the Design's Themes as a
	-- segmented control (the first axis's values: Light | Dark; the one in
	-- view on field_active), then the properties toggle.
	local function theme_seg(axis: any): Node
		local r: any = { h = 28, p = 2, gap = 2, rounded = 8, bg = L.field, items = "center", min_w = 0 }
		for k, value in axis.values do
			local function on(): boolean
				local cur = theme_pick:get()[axis.axis]
				return cur == value or (cur == nil and k == 1)
			end
			table.insert(
				r,
				ui.button {
					id = `theme-{axis.axis}-{value}`,
					label = `{axis.axis}: {value}`,
					h = 24,
					px = 10,
					rounded = 6,
					border = 0,
					items = "center",
					justify = "center",
					focus = { outline = 0 },
					bg = function(): string
						return if on() then L.field_active else CLEAR
					end,
					hover = { bg = L.hover },
					on_click = function()
						theme_pick:set_key({ axis.axis }, value)
						if source.view_theme then
							source.view_theme(axis.axis, value)
						end
					end,
					ui.text {
						tostring(value),
						text_size = 12,
						weight = 500,
						font = Look.UI,
						color = function(): string
							return if on() then L.fg else L.muted
						end,
					},
				}
			)
		end
		return ui.row(r)
	end
	local topright = Kit.bar(L, {
		id = "topright",
		right = E,
		top = E,
		px = 3, -- (+1 of the rim)
		gap = 6,
		direction = "row",
		items = "center",
		-- ▶ Play (Ctrl+Enter); several flows: which one.
		(function(): Node
			local mp: any = {
				open = play_menu,
				label = "Play a flow",
				anchor = ui.button {
					id = "play-toggle",
					label = "Play prototype",
					tooltip = Kit.tip(L, "Play  Ctrl Enter"),
					tooltip_placement = { side = "bottom", align = "end", offset = 8 },
					w = 32,
					h = 32,
					p = 0,
					rounded = 8,
					border = 0,
					items = "center",
					justify = "center",
					focus = { outline = 0 },
					color = L.muted,
					bg = CLEAR,
					hover = { bg = L.hover },
					on_click = function()
						start_play()
					end,
					Kit.icon("play", 15),
				},
				Kit.menu_head(L, "Play a flow"),
			}
			table.insert(
				mp,
				ui.each(ui.computed(function(): { any }
					return if source.flows then source.flows:get() or {} else {}
				end), function(f: any): Node
					return Kit.menu_item(L, { label = f.name or "Flow", on_click = function()
						play_from(f.start, f.name)
					end })
				end)
			)
			for k2, v2 in Kit.pop_style(L) do
				mp[k2] = v2
			end
			mp.w = 220
			return ui.menu(mp)
		end)(),
		-- (step 6 P4) the inline Preview (Shift+Space)
		ui.button {
			id = "preview-toggle",
			label = "Preview",
			tooltip = Kit.tip(L, "Preview  ⇧ Space"),
			tooltip_placement = { side = "bottom", align = "end", offset = 8 },
			w = 32,
			h = 32,
			p = 0,
			rounded = 8,
			border = 0,
			items = "center",
			justify = "center",
			focus = { outline = 0 },
			color = function(): string
				return if pre.on:get() then L.accent else L.muted
			end,
			bg = function(): string
				return if pre.on:get() then L.accent_soft else CLEAR
			end,
			hover = { bg = L.hover },
			on_click = function()
				pre.toggle()
			end,
			Kit.icon("smartphone", 15),
		},
		ui.presence(function(): string
			local t = tokens:get()
			return if t and t.axes and #t.axes > 0 then "themes" else "none"
		end, function(which: string): Node
			if which == "none" then
				return ui.div {}
			end
			return theme_seg(tokens:peek().axes[1])
		end, { direction = "row", items = "center" }),
		ui.button {
			id = "props-toggle",
			label = "Show properties",
			tooltip = Kit.tip(L, "Properties"),
			tooltip_placement = { side = "bottom", align = "end", offset = 8 },
			w = 32,
			h = 32,
			p = 0,
			rounded = 8,
			border = 0,
			items = "center",
			justify = "center",
			focus = { outline = 0 },
			color = function(): string
				return if props_shown:get() then L.accent else L.muted
			end,
			bg = function(): string
				return if props_shown:get() then L.accent_soft else CLEAR
			end,
			hover = { bg = L.hover },
			on_click = function()
				props_open:set(not props_open:peek())
			end,
			Kit.icon("panelRight", 16),
		},
	})

	local props_panel = Kit.island(L, {
		id = "properties",
		right = E,
		top = ROW2,
		bottom = E,
		w = RW,
		rounded = Look.RIGHT_R,
		overflow = "hidden",
		direction = "column",
		-- Design | Prototype, as Figma's (h40: two text tabs, the chosen one fg).
		ui.row {
			id = "panel-tabs",
			w_full = true,
			h = 40,
			shrink = 0,
			px = 6,
			gap = 2,
			items = "center",
			border_sides = { 0, 0, 1, 0 },
			border_color = L.border,
			(function(): Node
				local function tab(value: string, label: string): Node
					local function on(): boolean
						return panel_tab:get() == value
					end
					return ui.button {
						id = `panel-tab-{value}`,
						label = label,
						h = 28,
						px = 8,
						rounded = 8,
						border = 0,
						items = "center",
						focus = { outline = 0 },
						bg = function(): string
							return if on() then L.field else CLEAR
						end,
						hover = { bg = L.hover },
						on_click = function()
							panel_tab:set(value)
						end,
						ui.text {
							label,
							text_size = 12,
							weight = 500,
							font = Look.UI,
							color = function(): string
								return if on() then L.fg else L.muted
							end,
						},
					}
				end
				return ui.row { gap = 2, items = "center", grow = 1, tab("design", "Design"), tab("prototype", "Prototype") }
			end)(),
			ui.button {
				id = "props-hide",
				label = "Hide properties",
				tooltip = "Hide properties",
				w = 28,
				h = 28,
				p = 0,
				rounded = 8,
				border = 0,
				items = "center",
				justify = "center",
				bg = CLEAR,
				hover = { bg = L.hover },
				color = L.muted,
				focus = { outline = 0 },
				on_click = function()
					props_open:set(false)
				end,
				Kit.icon("panelRight", 14),
			},
		},
		ui.scroll {
			w_full = true,
			grow = 1,
			min_h = 0,
			ui.presence(function(): string
				return infos:get().key .. "|" .. panel_tab:get()
			end, function(_: string): Node
				if panel_tab:peek() == "prototype" then
					return ui.component(function(): Node
						return ProtoPanel.Panel {
							L = L,
							source = source,
							infos = infos:peek().list,
							tokens = tokens:peek(),
							show_all = show_all_links,
							eyedrop = function(done: any)
								if api then
									api.eyedrop(done)
								end
							end,
						}
					end)({})
				end
				return ui.component(function(): Node
					return Props.Props {
						L = L,
						source = source,
						infos = infos:peek().list,
						tokens = tokens:peek(),
						select = function(ids: { string })
							source.selection:set(ids)
						end,
						render_png = function(id: string, scale: number, done: any)
							if api then
								api.render_png(id, scale, done)
							end
						end,
						render_layer = function(id: string, scale: number, opts: any): (any, any)
							if api and api.render_layer then
								return api.render_layer(id, scale, opts)
							end
							return nil, "no canvas"
						end,
						eyedrop = function(done: any)
							if api then
								api.eyedrop(done)
							end
						end,
					}
				end)({})
			end, { w_full = true }),
		},
	})

	-- The zoom pill (h40 r12, p4 gap 2): -, the level (opens Zoom), +. Its
	-- menu: rows 32 high, keys as keycaps; 50 / 100 / 200% under a line.
	local zoom_menu = ui.use_state(false)
	local function zitem(label: string, keys: { string }?, fn: () -> ()): Node
		return ui.menu_item {
			label = label,
			on_click = fn,
			h = 32,
			px = 8,
			rounded = 6,
			hover = { bg = L.pop_hl },
			ui.row {
				w_full = true,
				h = 32,
				gap = 8,
				items = "center",
				ui.text { label, text_size = 12, color = L.fg, font = Look.UI, grow = 1 },
				if keys then Kit.keycaps(L, keys) else ui.div {},
			},
		}
	end
	local function zoom_to(z: number)
		if not api then
			return
		end
		-- (about the Canvas's middle, between the side panels)
		local w = width:peek()
		local l = if left_open:peek() then PANEL_X + left_w:peek() + I else PANEL_X
		local r = if props_shown:peek() then E + RW + I else 0
		api.zoom_at(z, if w > 0 then l + (w - l - r) / 2 else 600, 400)
	end
	local function zoom_btn(id: string, icon: string, label: string, fn: () -> ()): Node
		return ui.button {
			id = id,
			label = label,
			tooltip = Kit.tip(L, label),
			tooltip_placement = { side = "top", align = "center", offset = 8 },
			w = 32,
			h = 32,
			p = 0,
			rounded = 8,
			border = 0,
			items = "center",
			justify = "center",
			focus = { outline = 0 },
			color = L.muted,
			bg = CLEAR,
			hover = { bg = L.hover },
			on_click = fn,
			Kit.icon(icon, 16),
		}
	end
	local zoom_menu_props: any = {
		open = zoom_menu,
		label = "Zoom",
		placement = { side = "top", align = "end", offset = 8 },
		anchor = ui.button {
			id = "zoom-level",
			label = "Zoom",
			h = 24,
			min_w = 40,
			px = 6,
			rounded = 6,
			border = 0,
			items = "center",
			justify = "center",
			focus = { outline = 0 },
			bg = function(): string
				return if zoom_menu:get() then L.field_active else CLEAR
			end,
			hover = { bg = L.hover },
			on_click = ui.toggle(zoom_menu),
			ui.text {
				function(): string
					if not api_ready:get() or not api then
						return ""
					end
					local v = api.view:get()
					return if v then `{math.floor(v.zoom * 100 + 0.5)}%` else ""
				end,
				text_size = 12,
				weight = 500,
				font = Look.MONO,
				color = L.fg,
			},
		},
		zitem("Zoom in", { "Ctrl", "+" }, function()
			api.zoom_step(1)
		end),
		zitem("Zoom out", { "Ctrl", "−" }, function()
			api.zoom_step(-1)
		end),
		zitem("Zoom to fit", { "⇧", "1" }, function()
			api.fit()
		end),
		zitem("Zoom to selection", { "⇧", "2" }, function()
			api.zoom_to_selection()
		end),
		ui.div { w_full = true, py = 3, px = 4, ui.div { w_full = true, h = 1, bg = L.border } },
		zitem("Zoom to 50%", nil, function()
			zoom_to(0.5)
		end),
		zitem("Zoom to 100%", { "Ctrl", "0" }, function()
			zoom_to(1)
		end),
		zitem("Zoom to 200%", nil, function()
			zoom_to(2)
		end),
	}
	for k, v in Kit.pop_style(L) do
		zoom_menu_props[k] = v
	end
	zoom_menu_props.gap = 1
	zoom_menu_props.w = 220
	local zoom = Kit.bar(L, {
		id = "zoompill",
		right = function(): number
			return if props_shown:get() then E + RW + I else E
		end,
		bottom = E,
		px = 3, -- (+1 of the rim)
		gap = 2,
		direction = "row",
		items = "center",
		zoom_btn("zoom-out", "minus", "Zoom out  Ctrl −", function()
			api.zoom_step(-1)
		end),
		ui.menu(zoom_menu_props),
		zoom_btn("zoom-in", "plus", "Zoom in  Ctrl +", function()
			api.zoom_step(1)
		end),
	})

	-- Find (Board · Find and commands): a 300 wide island docked top right
	-- over the properties. The search row (44 high: icon, the query, "2 of 5"
	-- or "No results", the close button), a line, then the matching layers
	-- (32 high: the type icon, the name, its parent's name muted; the
	-- current one on accent_soft). Up / Down move, Enter selects the layer
	-- and zooms to it, Escape closes.
	local find_q = ui.use_state("")
	local find_at = ui.use_state(1)
	local find_hits = ui.computed(function(): { any }
		local q = string.lower(find_q:get())
		local out = {}
		if q == "" then
			return out
		end
		local tree = source.tree:get() or {}
		local names: { [string]: string } = {}
		for _, n in tree do
			names[n.id] = n.name or ""
		end
		for _, n in tree do
			if string.find(string.lower(n.name or ""), q, 1, true) or (n.txt and string.find(string.lower(n.txt), q, 1, true)) then
				local hit = table.clone(n)
				hit.ctx = if n.p and n.p ~= "" then names[n.p] else nil
				table.insert(out, hit)
				if #out >= 200 then
					break
				end
			end
		end
		return out
	end)
	local function find_close()
		find_open:set(false)
		find_q:set("")
		find_at:set(1)
		if api and api.focus then
			api.focus()
		end
	end
	-- (However it closes, from the rail too, it opens empty next time.)
	ui.effect(function()
		if not find_open:get() and find_q:peek() ~= "" then
			find_q:set("")
			find_at:set(1)
		end
	end)
	-- The current result is selected as it changes (the view stays); Enter or
	-- a click fits its Screen.
	local function find_show(n: any?)
		if not n then
			return
		end
		source.selection:set({ n.id })
		if source.select then
			source.select({ n.id })
		end
	end
	local function find_pick(n: any)
		find_show(n)
		find_close()
		if api then
			ui.after(0, function()
				api.zoom_to_root(n.id)
			end)
		end
	end
	ui.effect(function()
		local hits = find_hits:get()
		local at = find_at:get()
		if find_open:peek() and hits[at] then
			find_show(hits[at])
		end
	end)
	local function find_row(n: any): Node
		local on = function(): boolean
			local h = find_hits:get()[find_at:get()]
			return h ~= nil and h.id == n.id
		end
		return ui.row {
			id = `find-hit-{n.id}`,
			role = "option",
			label = n.name or "",
			w_full = true,
			h = 32,
			px = 10,
			gap = 8,
			rounded = 7,
			items = "center",
			bg = function(): string
				return if on() then L.accent_soft else CLEAR
			end,
			hover = { bg = L.hover },
			on_click = function()
				find_pick(n)
			end,
			ui.div {
				shrink = 0,
				color = function(): string
					return if on() then L.accent else L.faint
				end,
				Kit.icon(Layers.type_icon(n), 14),
			},
			ui.text {
				n.name or "",
				text_size = 12,
				font = Look.UI,
				truncate = true,
				min_w = 0,
				shrink = 1,
				weight = function(): number
					return if on() then 500 else 400
				end,
				color = function(): string
					return if on() then L.accent_fg else L.fg
				end,
			},
			ui.text { n.ctx or "", text_size = 12, color = L.faint, font = Look.UI, truncate = true, grow = 1, min_w = 0 },
		}
	end
	local find = Kit.island(L, {
		id = "find",
		right = E,
		top = ROW2,
		w = 300,
		rounded = 12,
		overflow = "hidden",
		-- (solid: the properties under it mustn't show through)
		ui.column {
			w_full = true,
			bg = L.panel_solid,
			ui.row {
				w_full = true,
				h = 44,
				pl = 13, -- (+1 of the rim)
				pr = 9,
				gap = 10,
				items = "center",
				ui.div { color = L.faint, shrink = 0, Kit.icon("search", 15) },
				ui.input {
					id = "layers-find",
					label = "Find layers",
					value = function(): string
						return find_q:get()
					end,
					placeholder = "Find layers…",
					placeholder_color = L.faint,
					on_change = function(t: string)
						find_q:set(t)
						find_at:set(1)
					end,
					on_mount = function(el: any)
						el:focus()
					end,
					on_key = function(k: any): boolean?
						local hits = find_hits:peek()
						if k.key == "Escape" then
							find_close()
							return true
						elseif k.key == "ArrowDown" then
							find_at:set(math.min(find_at:peek() + 1, math.max(#hits, 1)))
							return true
						elseif k.key == "ArrowUp" then
							find_at:set(math.max(find_at:peek() - 1, 1))
							return true
						elseif k.key == "Enter" then
							local n = hits[find_at:peek()]
							if n then
								find_pick(n)
							end
							return true
						end
						return nil
					end,
					grow = 1,
					min_w = 0,
					h = 42,
					px = 0,
					border = 0,
					bg = CLEAR,
					focus = { outline = 0 },
					text_size = 13,
					font = Look.UI,
					color = L.fg,
				},
				ui.text {
					function(): string
						local n = #find_hits:get()
						if find_q:get() == "" then
							return ""
						end
						return if n == 0 then "No results" else `{math.min(find_at:get(), n)} of {n}`
					end,
					text_size = 12,
					color = L.faint,
					font = Look.UI,
					shrink = 0,
				},
				ui.div { shrink = 0, Kit.icon_btn(L, { icon = "x", label = "Close", size = 24, icon_size = 14, color = L.faint, on_click = find_close }) },
			},
			ui.show(function(): boolean
				return #find_hits:get() > 0
			end, ui.column {
				w_full = true,
				ui.div { w_full = true, h = 1, bg = L.border },
				ui.scroll {
					w_full = true,
					max_h = 332,
					p = 4,
					ui.column {
						w_full = true,
						gap = 1,
						ui.each(find_hits, find_row, {
							key = function(n: any): string
								return n.id
							end,
						}),
					},
				},
			}),
		},
	})

	-- The command palette's actions, and the shortcuts sheet's groups (what
	-- this editor does, in pen's sections).
	local function has_sel(): string?
		return if #(source.selection:get() or {}) == 0 then "Nothing selected" else nil
	end
	local function sel_ids(): { string }
		return source.selection:peek() or {}
	end
	local function palette_actions(): { any }
		local acts: { any } = {
			{ section = "Edit", label = "Undo", icon = "undo", keys = { "Ctrl", "Z" }, run = function()
				source.undo()
			end },
			{ section = "Edit", label = "Redo", icon = "redo", keys = { "Ctrl", "⇧", "Z" }, run = function()
				source.redo()
			end },
			{ section = "Edit", label = "Duplicate", icon = "copy", keys = { "Ctrl", "D" }, why = has_sel, run = function()
				edit({ { op = "duplicate", ids = sel_ids() } }, "Duplicate")
			end },
			{ section = "Edit", label = "Delete", icon = "minus", keys = { "Del" }, why = has_sel, run = function()
				edit({ { op = "delete", ids = sel_ids() } }, "Delete")
				source.selection:set({})
			end },
			{ section = "Edit", label = "Copy", icon = "copy", keys = { "Ctrl", "C" }, why = has_sel, run = function()
				if source.copy then
					source.copy(sel_ids(), false)
					IaClip.layers_copied()
				end
			end },
			{ section = "Edit", label = "Cut", icon = "copy", keys = { "Ctrl", "X" }, why = has_sel, run = function()
				if source.copy then
					source.copy(sel_ids(), true)
					IaClip.layers_copied()
					source.selection:set({})
				end
			end },
			{ section = "Edit", label = "Paste", icon = "copy", keys = { "Ctrl", "V" }, run = function()
				-- (F6 C3) interactions copied last: appended to the selection
				if api and api.paste_interactions and api.paste_interactions() then
					return
				end
				local ids = sel_ids()
				edit({ { op = "paste", into = if #ids == 1 then ids[1] else nil } }, "Paste")
			end },
			{ section = "Arrange", label = "Group selection", icon = "group", keys = { "Ctrl", "G" }, why = has_sel, run = function()
				edit({ { op = "wrap", ids = sel_ids(), as = "group" } }, "Group")
			end },
			{ section = "Arrange", label = "Frame selection", icon = "frame", keys = { "Ctrl", "Alt", "G" }, why = has_sel, run = function()
				edit({ { op = "wrap", ids = sel_ids(), as = "frame" } }, "Frame selection")
			end },
			{ section = "Arrange", label = "Add flex layout", icon = "layV", keys = { "⇧", "A" }, why = has_sel, run = function()
				edit({ { op = "wrap", ids = sel_ids(), as = "frame", layout = "vertical" } }, "Add flex layout")
			end },
			{ section = "Arrange", label = "Bring to front", icon = "arrowDown", keys = { "]" }, why = has_sel, run = function()
				local ops = {}
				for _, id in sel_ids() do
					table.insert(ops, { op = "reorder", id = id, to = "front" })
				end
				edit(ops, "Bring to front")
			end },
			{ section = "Arrange", label = "Send to back", icon = "arrowDown", keys = { "[" }, why = has_sel, run = function()
				local ops = {}
				for _, id in sel_ids() do
					table.insert(ops, { op = "reorder", id = id, to = "back" })
				end
				edit(ops, "Send to back")
			end },
			{ section = "Component", label = "Create component", icon = "component", keys = { "Ctrl", "Alt", "K" }, why = has_sel, run = function()
				local ops = {}
				for _, id in sel_ids() do
					table.insert(ops, { op = "update", id = id, props = { reusable = true } })
				end
				edit(ops, "Create component")
			end },
			{ section = "View", label = "Zoom in", icon = "plus", keys = { "Ctrl", "+" }, run = function()
				api.zoom_step(1)
			end },
			{ section = "View", label = "Zoom out", icon = "minus", keys = { "Ctrl", "−" }, run = function()
				api.zoom_step(-1)
			end },
			{ section = "View", label = "Zoom to fit", icon = "corners", keys = { "⇧", "1" }, run = function()
				api.fit()
			end },
			{ section = "View", label = "Zoom to selection", icon = "target", keys = { "⇧", "2" }, why = has_sel, run = function()
				api.zoom_to_selection()
			end },
			{ section = "View", label = "Find layers", icon = "search", keys = { "Ctrl", "F" }, run = function()
				find_open:set(true)
			end },
			{ section = "View", label = "Show or hide layers", icon = "panelLeft", run = function()
				left_open:set(not left_open:peek())
			end },
			{ section = "View", label = "Show or hide properties", icon = "panelRight", run = function()
				props_open:set(not props_open:peek())
			end },
			{ section = "View", label = "Variables", icon = "braces", run = function()
				vars_open:set(not vars_open:peek())
			end },
			{ section = "Prototype", label = "Play prototype", icon = "play", keys = { "Ctrl", "Enter" }, run = function()
				start_play()
			end },
			{ section = "Prototype", label = "Preview", icon = "smartphone", keys = { "⇧", "Space" }, run = function()
				pre.toggle()
			end },
			{ section = "Prototype", label = "Show prototype panel", icon = "click", run = function()
				panel_tab:set("prototype")
				props_open:set(true)
			end },
			{ section = "Help", label = "Keyboard shortcuts", icon = "keyboard", keys = { "?" }, run = function()
				shortcuts_open:set(true)
			end },
		}
		for _, t in TOOLS do
			local name, key = string.match(t.tip, "^(.-)%s%s+(.+)$")
			table.insert(acts, { section = "Tools", label = name or t.tip, icon = t.icon, keys = if key then { key } else nil, run = function()
				tool:set(t.id)
			end })
		end
		return acts
	end
	local SHORTCUTS = {
		{ name = "App", sections = {
			{ title = "General", rows = { { label = "Command palette", keys = { "Ctrl", "P" } }, { label = "Keyboard shortcuts", keys = { "?" } }, { label = "Find layers", keys = { "Ctrl", "F" } } } },
			{ title = "History", rows = { { label = "Undo", keys = { "Ctrl", "Z" } }, { label = "Redo", keys = { "Ctrl", "⇧", "Z" } } } },
			{ title = "Prototype", rows = { { label = "Play", keys = { "Ctrl", "Enter" } }, { label = "Preview", keys = { "⇧", "Space" } }, { label = "Back (playing)", keys = { "←" } }, { label = "Restart (playing)", keys = { "R" } }, { label = "Close (playing)", keys = { "Esc" } } } },
		} },
		{ name = "Tools", sections = {
			{ title = "Tools", rows = { { label = "Move", keys = { "V" } }, { label = "Rectangle", keys = { "R" } }, { label = "Ellipse", keys = { "O" } }, { label = "Line", keys = { "L" } }, { label = "Pen", keys = { "P" } } } },
			{ title = "", rows = { { label = "Text", keys = { "T" } }, { label = "Frame", keys = { "F" } }, { label = "Hand", keys = { "H" } }, { label = "Pan", keys = { "Space" } } } },
		} },
		{ name = "Edit", sections = {
			{ title = "Clipboard", rows = { { label = "Copy", keys = { "Ctrl", "C" } }, { label = "Cut", keys = { "Ctrl", "X" } }, { label = "Paste", keys = { "Ctrl", "V" } }, { label = "Duplicate", keys = { "Ctrl", "D" } } } },
			{ title = "Layers", rows = { { label = "Delete", keys = { "Del" } }, { label = "Rename", keys = { "Double-click" } } } },
		} },
		{ name = "Arrange", sections = {
			{ title = "Order", rows = { { label = "Bring to front", keys = { "]" } }, { label = "Send to back", keys = { "[" } } } },
			{ title = "Grouping", rows = { { label = "Group selection", keys = { "Ctrl", "G" } }, { label = "Frame selection", keys = { "Ctrl", "Alt", "G" } }, { label = "Add flex layout", keys = { "⇧", "A" } } } },
		} },
		{ name = "Selection", sections = {
			{ title = "Select", rows = { { label = "Select all", keys = { "Ctrl", "A" } }, { label = "Add to selection", keys = { "⇧", "Click" } }, { label = "Deep select", keys = { "Ctrl", "Click" } } } },
			{ title = "Move", rows = { { label = "Nudge", keys = { "↑↓←→" } }, { label = "Nudge 10", keys = { "⇧", "↑↓←→" } }, { label = "Measure", keys = { "Alt" } } } },
		} },
		{ name = "Navigation", sections = {
			{ title = "Zoom", rows = { { label = "Zoom in", keys = { "Ctrl", "+" } }, { label = "Zoom out", keys = { "Ctrl", "−" } }, { label = "Zoom to 100%", keys = { "Ctrl", "0" } } } },
			{ title = "", rows = { { label = "Zoom to fit", keys = { "⇧", "1" } }, { label = "Zoom to selection", keys = { "⇧", "2" } } } },
		} },
	}
	local function centred(w: number): () -> number
		return function(): number
			return math.max(8, math.floor((width:get() - w) / 2))
		end
	end
	local palette = Palette.Palette {
		L = L,
		open = palette_open,
		actions = palette_actions,
		left = centred(560),
		on_close = function()
			if api and api.focus then
				api.focus()
			end
		end,
	}
	local shortcuts = Palette.Shortcuts { L = L, open = shortcuts_open, groups = SHORTCUTS, left = centred(600) }

	-- The resize handle: 8 wide, over the left panel's right edge.
	local drag_from: { x: number, w: number }? = nil
	local left_handle = ui.div {
		id = "left-resize",
		label = "Resize layers panel",
		absolute = true,
		left = function(): number
			return PANEL_X + left_w:get() - 4
		end,
		top = ROW2,
		bottom = E + Look.COMPOSER_H,
		w = 8,
		cursor = "ew_resize",
		on_press = function(e: any)
			drag_from = { x = e.x, w = left_w:peek() }
		end,
		on_pointer_move = function(e: any)
			local d = drag_from
			if d then
				local w = math.clamp(math.floor(d.w + e.x - d.x + 0.5), LEFT_MIN, LEFT_MAX)
				if w ~= left_w:peek() then
					left_w:set(w)
				end
			end
		end,
		on_release = function()
			if drag_from then
				drag_from = nil
				if prefs then
					prefs.set("left_w", left_w:peek())
				end
			end
		end,
	}

	-- (step 6 P4) The Preview's island: left of the properties (at the edge
	-- without them), under the top bar; Play inside, remade per opening. Its
	-- left edge, bottom edge and bottom-left corner resize it (Shift keeps
	-- the ratio); the size is kept on release.
	function pre.cursor(edge: string?): string
		return if edge == "l" then "ew_resize" elseif edge == "b" then "ns_resize" else "nesw_resize"
	end
	pre.dragging = ui.use_state(nil :: string?) -- the edge being dragged
	function pre.drag_move(e: any)
		local d = pre.drag
		if d then
			local maxw = math.max(PlayPlace.PREVIEW_MIN.w, width:peek() - (if props_shown:peek() then E + RW + I else E) - 320)
			local maxh = math.max(PlayPlace.PREVIEW_MIN.h, pre.hgt:peek() - ROW2 - E)
			pre.live:set(PlayPlace.preview_resize(d, d.edge, e.x - d.x, e.y - d.y, e.shift == true, { w = maxw, h = maxh }))
		end
	end
	function pre.drag_end()
		if pre.drag then
			pre.drag = nil
			pre.dragging:set(nil)
			local s = pre.live:peek()
			if s then
				pre.size:set(s)
				pre.live:set(nil)
			end
		end
	end
	function pre.edge(edge: string): Node
		-- (l: the left edge; b: the bottom; lb: the corner, over both)
		local at: any = if edge == "l"
			then { left = -4, w = 8, top = 12, bottom = 12 }
			elseif edge == "b" then { left = 12, right = 0, bottom = -4, h = 8 }
			else { left = -4, bottom = -4, w = 14, h = 14 }
		return ui.div {
			id = `preview-resize-{edge}`,
			label = "Resize preview",
			absolute = true,
			left = at.left,
			right = at.right,
			top = at.top,
			bottom = at.bottom,
			w = at.w,
			h = at.h,
			z = 60,
			cursor = pre.cursor(edge),
			on_press = function(e: any)
				local w, h = pre.wh()
				pre.drag = { x = e.x, y = e.y, w = w, h = h, edge = edge }
				pre.dragging:set(edge)
			end,
			on_pointer_move = pre.drag_move,
			on_release = pre.drag_end,
		}
	end
	-- While an edge is dragged: the whole window takes the pointer (a move
	-- past the thin edge still resizes; the release anywhere ends it).
	function pre.shield(): Node
		return ui.div {
			id = "preview-resize-shield",
			absolute = true,
			left = 0,
			top = 0,
			right = 0,
			bottom = 0,
			z = 100,
			cursor = function(): string
				return pre.cursor(pre.dragging:get())
			end,
			on_pointer_move = pre.drag_move,
			on_release = pre.drag_end,
		}
	end
	function pre.island(): Node
		return Kit.island(L, {
			id = "preview",
			right = function(): number
				return if props_shown:get() then E + RW + I else E
			end,
			top = ROW2,
			w = function(): number
				return (pre.wh())
			end,
			h = function(): number
				local _, h = pre.wh()
				return h
			end,
			rounded = 12,
			direction = "column",
			ui.div {
				id = "preview-body",
				w_full = true,
				h_full = true,
				-- (step 6 P6) a square clip: a rounded one is a mask composited
				-- every frame (about 1-1.5 ms a frame in pure/anim/f6/p4/film).
				-- Play rounds its own background instead, and its Screen keeps
				-- 8 pt in, clear of the 12 pt corners.
				overflow = "hidden",
				ui.presence(function(): string
					local p = pre.on:get()
					return if p then `preview{p.n}` else "none"
				end, function(which: string): Node
					local p = pre.on:peek()
					if which == "none" or not p then
						return ui.div {}
					end
					return ui.component(function(): Node
						return Play.Play {
							L = L,
							source = source,
							start = p.start,
							flow = p.flow,
							id = props.id,
							log = props.log,
							mode = "preview",
							expose = function(a: any)
								pre.api = a
								if props.expose_preview then
									props.expose_preview(a)
								end
							end,
							on_shown = function(id: string, follow: boolean)
								pre.shown = id
								if follow and api and pre.screen_of((source.selection:peek() or {})[1]) ~= id then
									-- (Follow prototype: the canvas selects and shows it)
									ui.after(0, function()
										if api then
											api.select({ id })
											api.zoom_to_root(id)
										end
									end)
								end
							end,
							on_play = function(id: string)
								local fname = nil
								for _, f in flows_list() do
									if f.start == id then
										fname = f.name
									end
								end
								play_from(id, fname)
							end,
							on_100 = function(w: number, h: number)
								-- (+2: the island's rim)
								local maxh = math.max(PlayPlace.PREVIEW_MIN.h, pre.hgt:peek() - ROW2 - E)
								pre.size:set({ w = math.max(PlayPlace.PREVIEW_MIN.w, w + 2), h = math.clamp(h + 2, PlayPlace.PREVIEW_MIN.h, maxh) })
							end,
							on_escape = function()
								if api and api.focus then
									api.focus()
								end
							end,
							on_close = function()
								pre.close()
								if api and api.focus then
									api.focus()
								end
							end,
						}
					end)({})
				end, { absolute = true, left = 0, top = 0, right = 0, bottom = 0 }),
			},
			pre.edge("l"),
			pre.edge("b"),
			pre.edge("lb"),
		})
	end

	return ui.overlay {
		id = `design-editor-{props.id or "design"}`,
		w_full = true,
		h_full = true,
		bg = L.board,
		color = L.fg,
		font = Look.UI,
		-- The editor's own keys wherever focus is in it (a panel's button, say),
		-- as pen's: ? shortcuts, Ctrl+P palette, Ctrl+F Find. (Fields keep theirs.)
		on_key = function(k: any): boolean?
			if k.editing then
				return nil
			end
			local key = k.key
			if key == "?" then
				shortcuts_open:set(not shortcuts_open:peek())
				return true
			elseif k.cmd and not k.shift and (key == "p" or key == "P") then
				palette_open:set(true)
				return true
			elseif k.cmd and not k.shift and (key == "f" or key == "F") then
				find_open:set(true)
				return true
			elseif key == "Escape" and shortcuts_open:peek() then
				shortcuts_open:set(false)
				return true
			elseif k.shift and not k.cmd and (key == " " or key == "Space") then
				-- (step 6 P4) the inline Preview, as Figma's
				pre.toggle()
				return true
			elseif k.cmd and key == "Enter" then
				-- Play (pen.dev's start-presentation key; Figma's is Ctrl+Alt+Enter).
				if playing:peek() then
					playing:set(nil)
				else
					start_play()
				end
				return true
			end
			-- Enter or Space on a focused panel button presses it (the Canvas's
			-- Enter would select children and rebuild the panel instead).
			if (key == "Enter" or key == " ") and not k.cmd and not k.alt and Pointer.button_focused() then
				return nil
			end
			-- anything else: the Canvas's shortcuts (Shift+1, Delete, V, …)
			if api and api.key then
				return api.key(k)
			end
			return nil
		end,
		on_resize = function(sz: { w: number, h: number })
			if math.abs(width:peek() - sz.w) >= 1 then
				width:set(sz.w)
			end
			if math.abs(pre.hgt:peek() - sz.h) >= 1 then
				pre.hgt:set(sz.h)
			end
		end,
		Canvas {
			source = source,
			id = props.id,
			hover = hover,
			tool = tool,
			chrome = false,
			log = props.log,
			proto = function(): boolean
				return panel_tab:get() == "prototype" and props_open:get()
			end,
			-- Shift+Space (F6 P4): the inline Preview (before Space's pan).
			on_preview = function()
				pre.toggle()
			end,
			-- Shift+E (F6 C1): Design ⇄ Prototype, opening the properties.
			on_panel_tab = function()
				panel_tab:set(if panel_tab:peek() == "prototype" then "design" else "prototype")
				props_open:set(true)
			end,
			show_all = show_all_links,
			context_menu = context_menu,
			menu_style = (function(): any
				local st = Kit.pop_style(L)
				st.w = 236
				return st
			end)(),
			on_find = function()
				find_open:set(true)
			end,
			on_palette = function()
				palette_open:set(true)
			end,
			on_shortcuts = function()
				shortcuts_open:set(not shortcuts_open:peek())
			end,
			insets = function(): any
				return {
					l = if left_open:peek() then PANEL_X + left_w:peek() + I else PANEL_X,
					t = 0,
					r = (if props_shown:peek() then E + RW + I else 0) + (if pre.on:peek() then (pre.wh()) + I + (if props_shown:peek() then 0 else E) else 0),
					b = 0,
				}
			end,
			expose = function(a: any)
				api = a
				-- (step 6 P4: the Preview's toggle, for tests and the film)
				a.toggle_preview = function()
					pre.toggle()
				end
				if props.expose then
					props.expose(a)
				end
				ui.after(0, function()
					api_ready:set(true)
				end)
			end,
		},
		title,
		ui.show(function(): boolean
			return left_open:get()
		end, left),
		ui.show(function(): boolean
			return left_open:get()
		end, left_handle),
		sidebar,
		rail,
		topright,
		ui.show(function(): boolean
			return props_shown:get()
		end, props_panel),
		ui.show(function(): boolean
			return find_open:get()
		end, find),
		ui.show(function(): boolean
			return vars_open:get()
		end, vars_island),
		ui.show(function(): boolean
			return palette_open:get()
		end, palette),
		ui.show(function(): boolean
			return shortcuts_open:get()
		end, shortcuts),
		zoom,
		-- Play: over the editor, which stays mounted under it (closing is
		-- instant and keeps the selection).
		ui.show(function(): boolean
			return playing:get() ~= nil
		end, ui.presence(function(): string
			local p = playing:get()
			return if p then `play{p.n}` else "none"
		end, function(which: string): Node
			if which == "none" then
				return ui.div {}
			end
			local p = playing:peek()
			return ui.component(function(): Node
				return Play.Play {
					L = L,
					source = source,
					start = p.start,
					flow = p.flow,
					id = props.id, -- (step 6 P1: Play keeps its scaling choice per Design)
					log = props.log,
					expose = function(a: any)
						if props.expose_play then
							props.expose_play(a)
						end
					end,
					on_close = function()
						playing:set(nil)
						if props.expose_play then
							props.expose_play(nil)
						end
						if api and api.focus then
							api.focus()
						end
					end,
				}
			end)({})
		end, { absolute = true, left = 0, top = 0, right = 0, bottom = 0 })),
		-- (step 6 P4) the inline Preview's island
		ui.show(function(): boolean
			return pre.on:get() ~= nil
		end, pre.island()),
		ui.show(function(): boolean
			return pre.dragging:get() ~= nil
		end, pre.shield()),
		Toast.Stack { L = L },
	}
end

return M
