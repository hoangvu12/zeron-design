--!strict
-- The hand cursor on clickable controls (zgx's ui is read-only: see pointer.luau).
local ui = require("./pointer").ui
-- Variables: the floating table the braces tool opens, as the redesign's
-- Board · Variables draws it (640 wide, an island r14):
--   - the top row: the theme axis ("mode ⌄", a menu of the Design's axes), its
--     values as tabs (a click shows that theme on the Canvas), "+" (a new
--     value for the axis, or a first axis), ✕;
--   - column heads: Name | one per value of the axis (Value without themes);
--   - the rows, grouped by their name's path ("brand/forest" under "brand"):
--     a type icon and the name (Enter renames it and what points to it), a
--     cell per value (a colour: swatch, opening the paint picker, hex and %;
--     a number or text: a field), ⋯ (Rename, Duplicate, Delete);
--   - "+ Add variable ⌄": Colour, Number or Text.
-- With no variables: "No variables yet" and a primary "+ Add variable".
--
-- Edits go out as `tokens` / `renameToken` / `themes` ops through
-- `source.edit`; `reload()` asks the source for the tokens again.
--
--   Variables.Panel {
--     L = L, source = source,
--     tokens = tokens,          -- a ui state: what source.tokens answers
--     reload = load_tokens,
--     theme_pick = theme_pick,  -- a ui state { [axis] = value }
--     close = function() vars_open:set(false) end,
--     left = function() return … end, top = I * 2 + BAR,
--     max_h = function() return window_h - … end, -- optional (default 520)
--   }

local Kit = require("./kit")
local Look = require("./look")
local Picker = require("./picker")

local M = {}

local NAME_W = 200
local ROW_H = 40
local CLEAR = "#00000000"

local KINDS = {
	{ type = "color", label = "Colour", icon = "drop", base = "color/new", value = "#000000" },
	-- (a "hash" icon would be the board's; braces is the nearest there is)
	{ type = "number", label = "Number", icon = "braces", base = "number/new", value = 0 },
	{ type = "string", label = "Text", icon = "text", base = "text/new", value = "Text" },
}
local function kind_icon(t: string): string
	return if t == "color" then "drop" elseif t == "string" then "text" else "braces"
end

-- A token row's value for a column of the axis (the unthemed value where it
-- has none for that column).
local function token_value(r: any, axis: string?, col: string?): any
	local value = nil
	for _, v in r.values or {} do
		local th = v.theme
		if not axis or (th and th[axis] == col) or ((th == nil or next(th) == nil) and value == nil) then
			value = v.value
		end
	end
	-- (no value for that column: the first one, as the Canvas resolves it)
	if value == nil and r.values and r.values[1] then
		value = r.values[1].value
	end
	return value
end

-- The token as the file writes it, from a row (every themed value kept).
local function token_of(r: any): any
	local vals = r.values or {}
	if #vals == 1 and (vals[1].theme == nil or next(vals[1].theme) == nil) then
		return { type = r.type, value = vals[1].value }
	end
	local out = {}
	for _, v in vals do
		table.insert(out, { value = v.value, theme = v.theme or {} })
	end
	return { type = r.type, value = out }
end

-- The token with `col` of `axis` set to `v`.
local function token_with(r: any, axis: string?, cols: { string }, col: string, v: any): any
	if not axis then
		return { type = r.type, value = v }
	end
	local vals = r.values or {}
	local themed = false
	for _, e in vals do
		if e.theme and next(e.theme) ~= nil then
			themed = true
		end
	end
	if not themed then
		-- (an unthemed value becomes one a column, the others keeping it)
		local out = {}
		for _, c in cols do
			table.insert(out, { value = if c == col then v else token_value(r, axis, c), theme = { [axis] = c } })
		end
		return { type = r.type, value = out }
	end
	local out = {}
	local found = false
	for _, e in vals do
		local th = e.theme or {}
		if th[axis] == col then
			table.insert(out, { value = v, theme = th })
			found = true
		else
			table.insert(out, { value = e.value, theme = th })
		end
	end
	if not found then
		table.insert(out, { value = v, theme = { [axis] = col } })
	end
	return { type = r.type, value = out }
end

local function unique(taken: { [string]: boolean }, base: string): string
	local name, n = base, 1
	while taken[name] do
		n += 1
		name = `{base}-{n}`
	end
	return name
end

-- The group a name is in: its path up to the last "/" ("" for none).
local function group_of(name: string): string
	return string.match(name, "^(.*)/[^/]*$") or ""
end

local function resolve(v: any): any
	return v
end

export type PanelProps = {
	L: any,
	source: any,
	tokens: any,
	reload: () -> (),
	theme_pick: any,
	close: () -> (),
	left: any,
	top: any,
	max_h: any?,
}

function M.Panel(props: PanelProps): Node
	local L, source = props.L, props.source
	local tokens = props.tokens
	local theme_pick = props.theme_pick
	local axis_pick = ui.use_state(nil :: string?)
	-- (a variable just added: its name field takes the focus as it shows)
	local focus_next = ui.use_state(nil :: string?)

	local function edit(ops: { any }, label: string, live: boolean?)
		source.edit(ops, label, { join = live == true })
		props.reload()
	end

	local function data(): any
		return tokens:get() or { rows = {}, axes = {} }
	end
	-- The axis shown: the one picked, else the first.
	local function axis_of(t: any): any
		local want = axis_pick:get()
		local first = nil
		for _, a in t.axes or {} do
			first = first or a
			if a.axis == want then
				return a
			end
		end
		return first
	end
	local by_name = ui.computed(function(): { [string]: any }
		local m = {}
		for _, r in data().rows or {} do
			m[r.name] = r
		end
		return m
	end)
	local function taken(): { [string]: boolean }
		local m = {}
		for name in by_name:peek() do
			m[name] = true
		end
		return m
	end

	-- Small parts ----------------------------------------------------------------------

	local function menu_row(o: { label: string, icon: string?, on_click: () -> (), danger: boolean?, checked: boolean? }): Node
		local fg = if o.danger then L.danger else L.fg
		return ui.menu_item {
			label = o.label,
			on_click = o.on_click,
			h = 28,
			px = 8,
			rounded = 6,
			hover = { bg = L.pop_hl },
			ui.row {
				w_full = true,
				h = 28,
				gap = 8,
				items = "center",
				if o.icon then ui.div { color = if o.danger then L.danger else L.muted, shrink = 0, Kit.icon(o.icon, 14) } else ui.div {},
				ui.text { o.label, text_size = 12, color = fg, font = Look.UI, grow = 1 },
				if o.checked then ui.div { color = L.accent, Kit.icon("check", 14) } else ui.div {},
			},
		}
	end
	local function menu(open: any, label: string, anchor: Node, items: { Node }, w: number, placement: any?): Node
		local mp: any = {
			open = open,
			label = label,
			placement = placement or { side = "bottom", align = "start", offset = 4 },
			anchor = anchor,
		}
		for _, it in items do
			table.insert(mp, it)
		end
		for k, v in Kit.pop_style(L) do
			mp[k] = v
		end
		mp.w = w
		mp.gap = 2
		return ui.menu(mp)
	end

	-- A cell's input: 28 high, r8, the field grey (lighter and outlined while
	-- typing in it); `leading` / `trailing` nodes beside the text.
	local function cell(o: { tip: string, value: () -> string, commit: (t: string) -> (), weight: number?, leading: Node?, trailing: { Node }?, w: any?, ref: any?, on_mount: ((el: any) -> ())? }): Node
		return ui.component(function(): Node
			local focused = ui.use_state(false)
			local r: any = {
				w = o.w or "100%",
				min_w = 0,
				h = 28,
				px = 8,
				gap = 6,
				rounded = 8,
				items = "center",
				bg = function(): string
					return if focused:get() then L.field_active else L.field
				end,
				outline = function(): number
					return if focused:get() then 1 else 0
				end,
				outline_color = L.accent,
				outline_offset = -1,
			}
			if o.leading then
				table.insert(r, o.leading)
			end
			table.insert(
				r,
				ui.input {
					label = o.tip,
					ref = o.ref,
					on_mount = o.on_mount,
					value = o.value,
					on_commit = o.commit,
					select_on_focus = true,
					on_focus = function()
						focused:set(true)
					end,
					on_blur = function()
						focused:set(false)
					end,
					grow = 1,
					min_w = 0,
					w = "auto",
					h = 26,
					px = 0,
					py = 0,
					bg = CLEAR,
					border = 0,
					rounded = 0,
					focus = { outline = 0 },
					color = L.fg,
					text_size = 12,
					weight = o.weight or 400,
					font = Look.UI,
				}
			)
			for _, n in o.trailing or {} do
				table.insert(r, n)
			end
			return ui.row(r)
		end)({})
	end

	-- A colour's cell: the swatch (the paint picker), its hex, its %.
	local function colour_cell(name: string, axis: string?, cols: { string }, col: string): Node
		return ui.component(function(): Node
			local open = ui.use_state(false)
			local function value(): string?
				local r = by_name:get()[name]
				local v = r and token_value(r, axis, col)
				return if type(v) == "string" then v else nil
			end
			local function set(v: string, live: boolean?)
				local r = by_name:peek()[name]
				if r then
					edit({ { op = "tokens", tokens = { [name] = token_with(r, axis, cols, col, v) } } }, "Change variable", live)
				end
			end
			local swatch = ui.div {
				w = 14,
				h = 14,
				shrink = 0,
				rounded = 4,
				overflow = "hidden",
				bg = "#ffffff",
				border = 1,
				border_color = L.border,
				cursor = "pointer",
				on_click = function()
					open:set(not open:peek())
				end,
				ui.div { absolute = true, left = 0, top = 0, w = 7, h = 7, bg = "#cccccc" },
				ui.div { absolute = true, left = 7, top = 7, w = 7, h = 7, bg = "#cccccc" },
				ui.div {
					absolute = true,
					left = 0,
					top = 0,
					w = 14,
					h = 14,
					bg = function(): string
						return value() or CLEAR
					end,
				},
			}
			local pop = ui.popover {
				open = open,
				label = `{name} {col} colour`,
				placement = { side = "bottom", align = "start", offset = 8 },
				anchor = swatch,
				w = 266, -- (the picker's 264 inside the rim)
				p = 0,
				rounded = 10,
				bg = L.pop,
				border = 1,
				border_color = L.border,
				shadow = L.pop_shadow,
				build = function(): Node
					return Picker.Picker {
						L = L,
						paint = value() or "#000000",
						resolve = resolve,
						tokens = {},
						commit = function(p: any, live: boolean)
							-- (a variable holds a plain colour: no gradient, no image)
							if type(p) == "string" then
								set(p, live)
							end
						end,
						close = function()
							open:set(false)
						end,
					}
				end,
			}
			local pct = ui.input {
				label = `{name} {col} opacity`,
				value = function(): string
					local c = Picker.parse(value() or "")
					return tostring(if c then math.floor(c.a * 100 + 0.5) else 100)
				end,
				on_commit = function(t: string)
					local a = tonumber((string.gsub(t, "[^%d%.]", "")))
					local c = Picker.parse(value() or "")
					if a and c then
						c.a = math.clamp(a, 0, 100) / 100
						set(Picker.hex(c))
					end
				end,
				select_on_focus = true,
				align = "right",
				w = 28,
				h = 26,
				px = 0,
				py = 0,
				bg = CLEAR,
				border = 0,
				focus = { outline = 0 },
				color = L.faint,
				text_size = 12,
				font = Look.UI,
				shrink = 0,
			}
			return ui.div {
				grow = 1,
				basis = 0,
				min_w = 0,
				cell {
					tip = `{name} {col}`,
					leading = ui.div { w = 14, h = 14, shrink = 0, pop },
					value = function(): string
						local c = Picker.parse(value() or "")
						return if c then string.upper(string.sub(Picker.hex({ r = c.r, g = c.g, b = c.b, a = 1 }), 2, 7)) else (value() or "")
					end,
					commit = function(t: string)
						local h = Picker.parse("#" .. string.gsub(t, "[#%s]", ""))
						if h then
							local c = Picker.parse(value() or "")
							h.a = if c then c.a else 1
							set(Picker.hex(h))
						end
					end,
					trailing = { ui.row { shrink = 0, gap = 0, ml = -4, items = "center", pct, ui.text { "%", text_size = 12, color = L.faint, font = Look.UI } } },
				},
			}
		end)({})
	end

	-- A number's or a text's cell.
	local function value_cell(name: string, kind: string, axis: string?, cols: { string }, col: string): Node
		return ui.div {
			grow = 1,
			basis = 0,
			min_w = 0,
			cell {
				tip = `{name} {col}`,
				value = function(): string
					local r = by_name:get()[name]
					local v = r and token_value(r, axis, col)
					return if type(v) == "table" then "…" else tostring(if v == nil then "" else v)
				end,
				commit = function(t: string)
					local r = by_name:peek()[name]
					local v: any = if kind == "number" then tonumber(t) else t
					if r and v ~= nil then
						edit({ { op = "tokens", tokens = { [name] = token_with(r, axis, cols, col, v) } } }, "Change variable")
					end
				end,
			},
		}
	end

	-- A variable's row.
	local function var_row(name: string, kind: string, axis: string?, cols: { string }): Node
		return ui.component(function(): Node
			local menu_open = ui.use_state(false)
			local name_ref = ui.ref()
			local function rename_now()
				ui.after(50, function()
					local el = name_ref:peek()
					if el then
						el:focus()
						el:select_all()
					end
				end)
			end
			local r: any = {
				id = `var-{name}`,
				w_full = true,
				h = ROW_H,
				px = 12,
				gap = 8,
				items = "center",
				bg = function(): string
					return if menu_open:get() then L.hover else CLEAR
				end,
				hover = { bg = L.hover },
				ui.div {
					w = NAME_W,
					shrink = 0,
					cell {
						tip = "Variable name",
						weight = 500,
						ref = name_ref,
						on_mount = function(el: any)
							if focus_next:peek() == name then
								focus_next:set(nil)
								-- (after the menu that asked for it gives the focus back)
								ui.after(50, function()
									el:focus()
									el:select_all()
								end)
							end
						end,
						leading = ui.div { color = L.faint, shrink = 0, Kit.icon(kind_icon(kind), 13) },
						value = function(): string
							return name
						end,
						-- (renames it and every reference to it)
						commit = function(t: string)
							t = string.gsub(t, "^%s*(.-)%s*$", "%1")
							if t ~= "" and t ~= name and not by_name:peek()[t] then
								edit({ { op = "renameToken", from = name, to = t } }, "Rename variable")
							end
						end,
					},
				},
			}
			for _, c in cols do
				table.insert(r, if kind == "color" then colour_cell(name, axis, cols, c) else value_cell(name, kind, axis, cols, c))
			end
			table.insert(
				r,
				menu(
					menu_open,
					`{name} actions`,
					Kit.icon_btn(L, {
						icon = "dots",
						label = `{name} actions`,
						size = 28,
						icon_size = 14,
						color = L.faint,
						on = function(): boolean
							return menu_open:get()
						end,
						on_click = function()
							menu_open:set(not menu_open:peek())
						end,
					}),
					{
						menu_row { label = "Rename", icon = "pen", on_click = rename_now },
						menu_row {
							label = "Duplicate",
							icon = "copy",
							on_click = function()
								local row = by_name:peek()[name]
								if row then
									local to = unique(taken(), name .. "-copy")
									focus_next:set(to)
									edit({ { op = "tokens", tokens = { [to] = token_of(row) } } }, "Duplicate variable")
								end
							end,
						},
						Kit.menu_sep(L),
						menu_row {
							label = "Delete",
							icon = "x",
							danger = true,
							on_click = function()
								edit({ { op = "tokens", tokens = { [name] = "__null" } } }, "Delete variable")
							end,
						},
					},
					160,
					{ side = "bottom", align = "end", offset = 4 }
				)
			)
			return ui.row(r)
		end)({})
	end

	-- "+ Add variable": Colour, Number or Text.
	local function add(kind: any)
		local name = unique(taken(), kind.base)
		focus_next:set(name)
		edit({ { op = "tokens", tokens = { [name] = { type = kind.type, value = kind.value } } } }, "Add variable")
	end
	local function add_menu(primary: boolean): Node
		return ui.component(function(): Node
			local open = ui.use_state(false)
			local fg = if primary then L.on_accent else L.fg
			local anchor = ui.button {
				id = if primary then "variables-add-first" else "variables-add",
				label = "Add variable",
				h = 28,
				px = 10,
				gap = 6,
				rounded = 8,
				border = 0,
				items = "center",
				bg = if primary then L.accent else L.field,
				color = fg,
				hover = if primary then { opacity = 0.9 } else { bg = L.field_active },
				focus = { outline = 0 },
				on_click = function()
					open:set(not open:peek())
				end,
				ui.div { color = if primary then L.on_accent else L.muted, Kit.icon("plus", 14) },
				ui.text { "Add variable", text_size = 12, weight = if primary then 600 else 500, color = fg, font = Look.UI },
				if primary then ui.div {} else ui.div { color = L.faint, Kit.icon("chevDown", 12) },
			}
			local items = {}
			for _, k in KINDS do
				table.insert(
					items,
					menu_row {
						label = k.label,
						icon = k.icon,
						on_click = function()
							add(k)
						end,
					}
				)
			end
			return menu(open, "Add variable", anchor, items, 180, { side = if primary then "bottom" else "top", align = "start", offset = 4 })
		end)({})
	end

	-- "+": a new value for the axis (named in a small field), or a first axis.
	local function add_theme(axis: any): Node
		return ui.component(function(): Node
			local open = ui.use_state(false)
			local axis_name = if axis then axis.axis else "mode"
			local values = if axis then axis.values else {}
			local function put(t: string)
				t = string.gsub(t, "^%s*(.-)%s*$", "%1")
				if t == "" or table.find(values, t) then
					return
				end
				local now = table.clone(values)
				if #now == 0 then
					-- (a first axis: what the variables hold now stays its first value)
					table.insert(now, "Default")
					if t == "Default" then
						t = "Theme 2"
					end
				end
				table.insert(now, t)
				open:set(false)
				axis_pick:set(axis_name)
				edit({ { op = "themes", axis = axis_name, values = now } }, "Add theme")
			end
			return ui.popover {
				open = open,
				label = "Add theme",
				placement = { side = "bottom", align = "start", offset = 4 },
				anchor = Kit.icon_btn(L, {
					icon = "plus",
					label = "Add theme",
					size = 28,
					icon_size = 14,
					color = L.faint,
					on = function(): boolean
						return open:get()
					end,
					on_click = function()
						open:set(not open:peek())
					end,
				}),
				w = 220,
				p = 8,
				gap = 6,
				rounded = 10,
				bg = L.pop,
				border = 1,
				border_color = L.border,
				shadow = L.pop_shadow,
				build = function(): Node
					return ui.column {
						w_full = true,
						gap = 6,
						ui.text { if axis then `New {axis_name} value` else "New theme", text_size = 12, weight = 500, color = L.muted, font = Look.UI },
						cell {
							tip = "Theme name",
							on_mount = function(el: any)
								ui.after(50, function()
									el:focus()
								end)
							end,
							value = function(): string
								return ""
							end,
							commit = put,
						},
					}
				end,
			}
		end)({})
	end

	-- The top row: axis, theme tabs, +, ✕.
	local function top(t: any): Node
		local axis = axis_of(t)
		local r: any = { w_full = true, px = 12, py = 10, gap = 6, items = "center" }
		if axis then
			local axes = t.axes or {}
			table.insert(
				r,
				ui.component(function(): Node
					local open = ui.use_state(false)
					local items = {}
					for _, a in axes do
						table.insert(
							items,
							menu_row {
								label = tostring(a.axis),
								checked = a.axis == axis.axis,
								on_click = function()
									axis_pick:set(a.axis)
								end,
							}
						)
					end
					return menu(
						open,
						"Theme axis",
						ui.button {
							id = "variables-axis",
							label = "Theme axis",
							h = 28,
							px = 8,
							gap = 4,
							rounded = 6,
							border = 0,
							items = "center",
							bg = CLEAR,
							hover = { bg = L.hover },
							focus = { outline = 0 },
							on_click = function()
								open:set(not open:peek())
							end,
							ui.text { tostring(axis.axis), text_size = 12, weight = 500, color = L.muted, font = Look.UI },
							ui.div { color = L.faint, Kit.icon("chevDown", 12) },
						},
						items,
						180
					)
				end)({})
			)
		end
		local tabs: any = { gap = 2, p = 2, rounded = 8, bg = L.field, items = "center", min_w = 0 }
		local values = if axis then axis.values else { "Theme" }
		for k, v in values do
			local function on(): boolean
				if not axis then
					return true
				end
				local cur = theme_pick:get()[axis.axis]
				return cur == v or ((cur == nil or not table.find(axis.values, cur)) and k == 1)
			end
			table.insert(
				tabs,
				ui.button {
					id = `variables-theme-{v}`,
					label = tostring(v),
					h = 24,
					px = 12,
					rounded = 6,
					border = 0,
					items = "center",
					bg = function(): string
						return if on() then L.field_active else CLEAR
					end,
					hover = { bg = L.hover },
					focus = { outline = 0 },
					on_click = function()
						if axis then
							theme_pick:set_key({ axis.axis }, v)
							if source.view_theme then
								source.view_theme(axis.axis, v)
							end
						end
					end,
					ui.text {
						tostring(v),
						text_size = 12,
						font = Look.UI,
						weight = function(): number
							return if on() then 500 else 400
						end,
						color = function(): string
							return if on() then L.fg else L.faint
						end,
					},
				}
			)
		end
		table.insert(r, ui.row(tabs))
		table.insert(r, add_theme(axis))
		table.insert(r, ui.div { grow = 1 })
		table.insert(r, Kit.icon_btn(L, { id = "variables-close", icon = "x", label = "Close", size = 28, icon_size = 14, color = L.faint, on_click = props.close }))
		return ui.row(r)
	end

	local function head(cols: { string }): Node
		local r: any = { w_full = true, px = 20, py = 6, gap = 8, items = "center" }
		table.insert(r, ui.div { w = NAME_W - 8, shrink = 0, ui.text { "Name", text_size = 12, weight = 600, color = L.faint, font = Look.UI } })
		for _, c in cols do
			table.insert(r, ui.div { grow = 1, basis = 0, min_w = 0, ui.text { tostring(c), text_size = 12, weight = 600, color = L.faint, font = Look.UI, truncate = true } })
		end
		table.insert(r, ui.div { w = 28 - 8, shrink = 0 })
		return ui.row(r)
	end

	-- The rows and group labels, in order: names without a path first, then
	-- each path's names under its label.
	local items = ui.computed(function(): { any }
		local rows = data().rows or {}
		local loose, groups, order = {}, {}, {}
		for _, r in rows do
			local g = group_of(r.name)
			if g == "" then
				table.insert(loose, r)
			else
				if not groups[g] then
					groups[g] = {}
					table.insert(order, g)
				end
				table.insert(groups[g], r)
			end
		end
		local out = {}
		for _, r in loose do
			table.insert(out, { key = `r:{r.name}:{r.type}`, row = r })
		end
		for _, g in order do
			table.insert(out, { key = `g:{g}`, group = g })
			for _, r in groups[g] do
				table.insert(out, { key = `r:{r.name}:{r.type}`, row = r })
			end
		end
		return out
	end)

	local function max_h(): number
		local m = props.max_h
		if type(m) == "function" then
			return m()
		end
		return if type(m) == "number" then m else 520
	end

	local body = ui.presence(function(): string
		local t = tokens:get()
		if not t then
			return "loading"
		end
		local axis = axis_of(t)
		local shape = if axis then axis.axis .. "=" .. table.concat(axis.values, "|") else "-"
		local axes = {}
		for _, a in t.axes or {} do
			table.insert(axes, a.axis)
		end
		return (if #(t.rows or {}) == 0 then "empty:" else "rows:") .. shape .. "/" .. table.concat(axes, ",")
	end, function(key: string): Node
		if key == "loading" then
			return ui.div { w_full = true, h = 120 }
		end
		local t = tokens:peek() or { rows = {} }
		local axis = axis_of(t)
		local axis_name = if axis then axis.axis else nil
		local cols = if axis then axis.values else { "Value" }
		if string.sub(key, 1, 6) == "empty:" then
			return ui.column {
				w_full = true,
				top(t),
				Kit.empty(L, {
					icon = "braces",
					title = "No variables yet",
					body = "Variables hold colours, numbers and text that layers point to. Add one, or ask an agent to set up a palette.",
					action = add_menu(true),
				}),
				ui.div { h = 12 },
			}
		end
		return ui.column {
			w_full = true,
			top(t),
			head(cols),
			ui.scroll {
				w_full = true,
				h = function(): number
					-- (as high as its rows, up to the island's height less the
					-- top row, the heads and the footer: about 140)
					local h = 0
					for _, it in items:get() do
						h += if it.group then 30 else ROW_H
					end
					return math.min(h + 4, math.max(max_h() - 140, ROW_H * 2))
				end,
				ui.column {
					w_full = true,
					ui.each(items, function(it: any): Node
						if it.group then
							return ui.div {
								w_full = true,
								px = 12,
								pt = 10,
								pb = 4,
								ui.text { it.group, text_size = 12, weight = 600, color = L.faint, font = Look.UI, truncate = true },
							}
						end
						return var_row(it.row.name, it.row.type, axis_name, cols)
					end, {
						key = function(it: any): string
							return it.key
						end,
					}),
				},
			},
			ui.row {
				w_full = true,
				px = 12,
				py = 8,
				items = "center",
				add_menu(false),
			},
		}
	end, { w_full = true })

	return Kit.island(L, {
		id = "variables",
		left = props.left,
		top = props.top,
		-- (640; the empty state's 420)
		w = function(): number
			local t = tokens:get()
			return if t and #(t.rows or {}) == 0 then 420 else 640
		end,
		max_h = max_h,
		overflow = "hidden",
		body,
	})
end

-- (for tests)
M._token_with = token_with
M._token_value = token_value
M._group_of = group_of

return M
