--!strict
-- The hand cursor on clickable controls (zgx's ui is read-only: see pointer.luau).
local ui = require("./pointer").ui
-- Binding a property to a variable (step 5, V5b; pure/anim/f5/PLAN.md), as
-- Figma's "Apply variable" does, for the properties panel (text content,
-- visibility, fill, numbers) and the Prototype panel's Variant rows:
--
--   - `Bind.button`: a 20 square braces button; a click opens the Design's
--     variables of the types the property takes (Picker.Vars) beside the
--     panel; picking one binds it. `shown()` (optional) hides it until its
--     field is hovered, as Figma's does, while keeping its place.
--   - `Bind.chip`: a bound value, as a 28 high field: the type icon and the
--     name in the accent, the value faint, and a detach mark (which keeps the
--     value as a literal). A click on the name opens the list to swap it.
--   - `Bind.vars(tokens answer)`: `{ { name, kind, value } }` (each Token's
--     first value), what the lists show.
--   - `Bind.ref(v)`: the name when `v` is exactly "$name", else nil.
--
-- Stored shapes (CONTRACT, V1): `content = "$name"`, `enabled = "$flag"`,
-- `fill = "$colour"`, a number key `= "$n"`, an Instance's
-- `props = { On = "$flag" }`.

local Kit = require("./kit")
local Look = require("./look")
local Picker = require("./picker")
local PV = require("./proto_vars")

local M = {}
local CLEAR = "#00000000"

M.vars = PV.bind_vars
M.ref = PV.bind_ref
M.kind_of = PV.kind_of
M.literal = PV.bind_literal

local function pop(L: any, open: any, label: string, anchor: Node, o: { vars: { any }, kinds: { string }, bound: string?, pick: (name: string) -> () }): Node
	return ui.popover {
		open = open,
		autofocus = false,
		label = label,
		placement = { side = "left", align = "start", offset = 18 },
		anchor = anchor,
		w = 240,
		p = 0,
		rounded = 12,
		bg = L.pop,
		border = 1,
		border_color = L.border,
		shadow = L.pop_shadow,
		build = function(): Node
			return Picker.Vars {
				L = L,
				vars = o.vars,
				kinds = o.kinds,
				bound = o.bound,
				pick = function(name: string)
					open:set(false)
					o.pick(name)
				end,
			}
		end,
	}
end

export type ButtonProps = {
	id: string,
	what: string, -- "text", "visibility", "width", …
	kinds: { string },
	vars: { any },
	bound: string?,
	pick: (name: string) -> (),
	shown: (() -> boolean)?,
	size: number?,
}

function M.button(L: any, o: ButtonProps): Node
	return ui.component(function(): Node
		local open = ui.use_state(false)
		local size = o.size or 20
		local btn = ui.button {
			id = o.id,
			label = `Apply variable to {o.what}`,
			tooltip = "Apply variable",
			w = size,
			h = size,
			p = 0,
			shrink = 0,
			rounded = 6,
			border = 0,
			items = "center",
			justify = "center",
			bg = function(): string
				return if open:get() then L.accent_soft else CLEAR
			end,
			hover = { bg = L.hover },
			focus = { outline = 0 },
			color = function(): string
				return if open:get() then L.accent_fg else L.faint
			end,
			opacity = function(): number
				return if open:get() or o.shown == nil or o.shown() then 1 else 0
			end,
			on_click = function()
				open:set(not open:peek())
			end,
			Kit.icon("braces", 13),
		}
		return pop(L, open, `Variables for {o.what}`, btn, o)
	end)({})
end

export type ChipProps = {
	id: string,
	what: string,
	name: string,
	kind: string?,
	value: any, -- the variable's value (first mode), shown faint
	detach: () -> (),
	vars: { any }?,
	kinds: { string }?,
	pick: ((name: string) -> ())?,
	label: string?, -- before the name ("Visible if")
}

function M.chip(L: any, o: ChipProps): Node
	return ui.component(function(): Node
		local open = ui.use_state(false)
		local missing = o.vars ~= nil and o.kind == nil
		local icon = Picker.VAR_ICON[o.kind or ""] or "braces"
		local mark: Node = if o.kind == "color" and type(o.value) == "string"
			then ui.div { w = 14, h = 14, min_w = 14, shrink = 0, rounded = 4, bg = o.value, border = 1, border_color = L.border }
			else ui.div { w = 14, shrink = 0, color = if missing then L.danger else L.accent_fg, Kit.icon(icon, 13) }
		local main: any = {
			id = o.id,
			label = `{o.what}: {o.name} = {Picker.var_text(o.kind, o.value)}`,
			tooltip = if missing then `No variable "{o.name}" in this Design` else `{o.what} is bound to {o.name}`,
			grow = 1,
			min_w = 0,
			h = 28,
			pl = 8,
			pr = 4,
			gap = 6,
			rounded = 8,
			border = 0,
			bg = CLEAR,
			hover = { bg = L.field_active },
			focus = { outline = 0 },
			items = "center",
			on_click = function()
				if o.pick then
					open:set(not open:peek())
				end
			end,
			mark,
		}
		if o.label then
			table.insert(main, ui.text { o.label, text_size = 12, color = L.muted, font = Look.UI, shrink = 0 })
		end
		-- (in a narrow field the value gives way first: the name stays)
		table.insert(main, ui.text { o.name, text_size = 12, weight = 500, color = if missing then L.danger else L.accent_fg, font = Look.UI, truncate = true, min_w = 28, grow = 1 })
		table.insert(main, ui.text { if missing then "missing" else Picker.var_text(o.kind, o.value), text_size = 12, color = L.faint, font = Look.UI, shrink = 1, min_w = 0, truncate = true })
		local main_node: Node = ui.button(main)
		if o.pick and o.vars then
			main_node = ui.div { grow = 1, min_w = 0, pop(L, open, `Variables for {o.what}`, main_node, { vars = o.vars, kinds = o.kinds or { o.kind or "string" }, bound = o.name, pick = o.pick }) }
		end
		return ui.row {
			w_full = true,
			min_w = 0,
			h = 28,
			rounded = 8,
			bg = L.accent_soft,
			items = "center",
			main_node,
			ui.button {
				id = o.id .. "-detach",
				label = "Detach variable",
				tooltip = `Detach {o.name}`,
				w = 22,
				h = 24,
				mr = 3,
				p = 0,
				shrink = 0,
				border = 0,
				rounded = 6,
				bg = CLEAR,
				hover = { bg = L.hover },
				items = "center",
				justify = "center",
				color = L.accent_fg,
				on_click = o.detach,
				Kit.icon("detach", 12),
			},
		}
	end)({})
end

return M
