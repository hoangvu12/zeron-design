--!strict
-- The hand cursor on clickable controls (zgx's ui is read-only: see pointer.luau).
local ui = require("./pointer").ui
-- The command palette (⋯ on the rail, Ctrl+P) and the keyboard shortcuts
-- sheet (?), as the redesign draws them (Board · Find and commands).
--
-- Palette: a 560 wide card (panel_solid, r14) centred near the top; a 44
-- high search row ("Search actions…", an Esc keycap); section heads 12/600
-- faint; rows 36 high r8, an icon (15) and the label 13, the keys as
-- keycaps at the right; an action that can't run now in faint with why
-- ("Nothing selected"); the current row accent_soft, its label accent_fg
-- 13/500. ↑ ↓ move, Enter runs, Escape closes.
--
-- Actions: { section, label, icon?, keys = { "Ctrl", "Z" }?, run, why? }
-- where `why()` answers a reason it can't run now, or nil.

local Kit = require("./kit")
local Look = require("./look")

local M = {}

export type Action = {
	section: string,
	label: string,
	icon: string?,
	keys: { string }?,
	run: () -> (),
	why: (() -> string?)?,
}

-- One key's cap (kept for callers; Kit.keycaps draws a row of them).
function M.keycap(L: any, k: string, _on: boolean?): Node
	return Kit.keycaps(L, { k })
end

function M.Palette(props: { L: any, open: any, actions: () -> { Action }, left: () -> number, on_close: (() -> ())? }): Node
	local L = props.L
	local q = ui.use_state("")
	local at = ui.use_state(1)
	-- What shows: the matching actions' indices (a state holds no functions),
	-- in their sections' order.
	local acts = props.actions()
	local shown = ui.computed(function(): { number }
		local s = string.lower(q:get())
		local out = {}
		for i, a in acts do
			if s == "" or string.find(string.lower(a.label), s, 1, true) or string.find(string.lower(a.section), s, 1, true) then
				table.insert(out, i)
			end
		end
		return out
	end)
	local function close()
		props.open:set(false)
		q:set("")
		at:set(1)
		if props.on_close then
			props.on_close()
		end
	end
	local function run(a: Action)
		if a.why and a.why() then
			return
		end
		close()
		a.run()
	end
	local function row(ai: number, pos: number): Node
		local a = acts[ai]
		local function on(): boolean
			return shown:get()[at:get()] == ai
		end
		local function reason(): string?
			return if a.why then a.why() else nil
		end
		local function tone(): string
			return if on() then L.accent_fg elseif reason() then L.faint else L.fg
		end
		return ui.row {
			id = `palette-{a.section}-{a.label}`,
			role = "option",
			label = a.label,
			w_full = true,
			h = 36,
			px = 10,
			gap = 10,
			rounded = 8,
			items = "center",
			bg = function(): string
				return if on() then L.accent_soft else "#00000000"
			end,
			on_hover = function(inside: boolean)
				if inside and at:peek() ~= pos then
					at:set(pos)
				end
			end,
			on_click = function()
				run(a)
			end,
			ui.div {
				w = 15,
				shrink = 0,
				color = function(): string
					return if on() then L.accent else L.faint
				end,
				Kit.icon(a.icon or "dots", 15),
			},
			ui.text {
				a.label,
				text_size = 13,
				weight = function(): number
					return if on() then 500 else 400
				end,
				font = Look.UI,
				grow = 1,
				min_w = 0,
				truncate = true,
				color = tone,
			},
			ui.text {
				function(): string
					return reason() or ""
				end,
				text_size = 12,
				color = L.faint,
				font = Look.UI,
				shrink = 0,
			},
			if a.keys and #a.keys > 0 then Kit.keycaps(L, a.keys) else ui.div {},
		}
	end
	local body = ui.presence(function(): string
		local parts = {}
		for _, ai in shown:get() do
			table.insert(parts, tostring(ai))
		end
		return table.concat(parts, ",")
	end, function(_: string): Node
		local col: any = { w_full = true, gap = 1 }
		local last = nil
		for pos, ai in shown:peek() do
			local a = acts[ai]
			if a.section ~= last then
				last = a.section
				table.insert(col, ui.div { w_full = true, pt = 8, pr = 10, pb = 4, pl = 10, ui.text { a.section, text_size = 12, weight = 600, color = L.faint, font = Look.UI } })
			end
			table.insert(col, row(ai, pos))
		end
		if #shown:peek() == 0 then
			table.insert(col, Kit.empty(L, { icon = "search", title = "No matching actions", body = "Try another word." }))
		end
		return ui.column(col)
	end, { w_full = true })
	return ui.column {
		id = "command-palette",
		role = "dialog",
		label = "Command palette",
		absolute = true,
		left = props.left,
		top = 96,
		w = 560,
		h = 448,
		rounded = 14,
		bg = L.panel_solid,
		border = 1,
		border_color = L.border,
		shadow = L.pop_shadow,
		overflow = "hidden",
		ui.row {
			w_full = true,
			h = 44,
			px = 14,
			gap = 10,
			items = "center",
			border_sides = { 0, 0, 1, 0 },
			border_color = L.border,
			ui.div { color = L.faint, Kit.icon("search", 15) },
			ui.input {
				id = "palette-search",
				label = "Search actions",
				value = function(): string
					return q:get()
				end,
				on_change = function(t: string)
					q:set(t)
					at:set(1)
				end,
				placeholder = "Search actions…",
				placeholder_color = L.faint,
				on_mount = function(el: any)
					el:focus()
				end,
				on_key = function(k: any): boolean?
					local list = shown:peek()
					if k.key == "Escape" then
						close()
						return true
					elseif k.key == "ArrowDown" then
						at:set(math.min(at:peek() + 1, math.max(#list, 1)))
						return true
					elseif k.key == "ArrowUp" then
						at:set(math.max(at:peek() - 1, 1))
						return true
					elseif k.key == "Enter" then
						local ai = list[at:peek()]
						if ai then
							run(acts[ai])
						end
						return true
					end
					return nil
				end,
				grow = 1,
				min_w = 0,
				h = 44,
				px = 0,
				border = 0,
				bg = "#00000000",
				focus = { outline = 0 },
				text_size = 13,
				font = Look.UI,
				color = L.fg,
			},
			Kit.keycaps(L, { "Esc" }),
		},
		ui.scroll { w_full = true, grow = 1, min_h = 0, p = 6, body },
	}
end

-- The keyboard shortcuts sheet: a title and ✕, a tab a group (App, Tools,
-- Edit, Arrange, Selection, Navigation; the current one field_active), then
-- the group's sections in two columns of name and keycaps.
export type Group = { name: string, sections: { { title: string, rows: { { label: string, keys: { string } } } } } }

function M.Shortcuts(props: { L: any, open: any, groups: { Group }, left: () -> number }): Node
	local L = props.L
	local tab = ui.use_state(1)
	local tabs: any = { w_full = true, pt = 14, pr = 20, pb = 12, pl = 20, gap = 2, items = "center" }
	for i, g in props.groups do
		local function on(): boolean
			return tab:get() == i
		end
		table.insert(
			tabs,
			ui.button {
				id = `shortcuts-tab-{g.name}`,
				label = g.name,
				role = "tab",
				px = 10,
				py = 5,
				rounded = 7,
				border = 0,
				items = "center",
				justify = "center",
				bg = function(): string
					return if on() then L.field_active else "#00000000"
				end,
				hover = { bg = L.field },
				focus = { outline = 0 },
				on_click = function()
					tab:set(i)
				end,
				ui.text {
					g.name,
					text_size = 12,
					weight = function(): number
						return if on() then 500 else 400
					end,
					color = function(): string
						return if on() then L.fg else L.muted
					end,
					font = Look.UI,
				},
			}
		)
	end
	local body = ui.presence(function(): string
		return tostring(tab:get())
	end, function(which: string): Node
		local g = props.groups[tonumber(which) or 1]
		local cols: any = { w_full = true, pt = 16, pr = 20, pb = 20, pl = 20, gap = 32, items = "start" }
		local left: any = { grow = 1, basis = 0, min_w = 0, gap = 16 }
		local right: any = { grow = 1, basis = 0, min_w = 0, gap = 16 }
		for si, sec in g.sections do
			local target = if si % 2 == 1 then left else right
			local group: any = { w_full = true, gap = 8 }
			if sec.title ~= "" then
				table.insert(group, ui.text { sec.title, text_size = 12, weight = 600, color = L.fg, font = Look.UI })
			end
			for _, r in sec.rows do
				table.insert(group, ui.row {
					w_full = true,
					gap = 8,
					items = "center",
					ui.text { r.label, text_size = 12, color = L.muted, font = Look.UI, grow = 1, min_w = 0, truncate = true },
					Kit.keycaps(L, r.keys),
				})
			end
			table.insert(target, ui.column(group))
		end
		table.insert(cols, ui.column(left))
		table.insert(cols, ui.column(right))
		return ui.row(cols)
	end, { w_full = true })
	return ui.column {
		id = "shortcuts-sheet",
		role = "dialog",
		label = "Keyboard shortcuts",
		absolute = true,
		left = props.left,
		top = 80,
		w = 600,
		rounded = 14,
		bg = L.panel_solid,
		border = 1,
		border_color = L.border,
		shadow = L.pop_shadow,
		overflow = "hidden",
		ui.row {
			w_full = true,
			pt = 14,
			pr = 16,
			pl = 20,
			gap = 6,
			items = "center",
			ui.text { "Keyboard shortcuts", text_size = 15, weight = 600, color = L.fg, font = Look.UI, grow = 1 },
			Kit.icon_btn(L, {
				id = "shortcuts-close",
				icon = "x",
				label = "Close",
				size = 24,
				icon_size = 15,
				color = L.faint,
				on_click = function()
					props.open:set(false)
				end,
			}),
		},
		ui.row(tabs),
		ui.div { w_full = true, h = 1, bg = L.border },
		body,
	}
end

return M
