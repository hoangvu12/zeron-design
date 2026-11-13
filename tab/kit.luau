--!strict
-- The hand cursor on clickable controls (zgx's ui is read-only: see pointer.luau).
local ui = require("./pointer").ui
-- The panels' small parts, in pen.dev's metrics (look.luau): icons, icon
-- buttons, 24px fields (a scrubbable prefix, a mono value, committed on
-- Enter or on leaving, so a Canvas click commits too), segmented controls,
-- checkboxes, sections, swatches, a tooltip-less label.
--
-- Every part takes `L`, the colours of the theme it's built in: the shell
-- builds the panels again when the theme flips (hover styles are plain).

local Look = require("./look")
local Paths = require("./icon_paths")

local M = {}
local M_UI = Look.UI

-- An icon from the panel set, `size` points, stroked `sw`, in `color`
-- ("currentColor": the text colour it inherits, a button's hover too).
function M.icon(name: string, size: number?, color: any?, sw: number?): Node
	local s = size or 16
	local body = Paths[name] or ""
	return ui.svg {
		code = `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#000000" stroke-width="{sw or 1.6}" stroke-linecap="round" stroke-linejoin="round">{body}</svg>`,
		w = s,
		h = s,
		tint = color or "currentColor",
		label = "",
	}
end

-- A 24px square button with an icon: `on` (a value or a function) for a
-- pressed look.
function M.icon_btn(L: any, o: { icon: string, label: string, on_click: () -> (), size: number?, icon_size: number?, on: any?, id: string?, color: any? }): Node
	local s = o.size or 24
	return ui.button {
		id = o.id,
		label = o.label,
		w = s,
		h = s,
		p = 0,
		rounded = 6,
		items = "center",
		justify = "center",
		color = o.color or L.fg_strong,
		bg = function(): string
			local on = o.on
			if type(on) == "function" then
				on = on()
			elseif type(on) == "table" and on.get then
				on = on:get()
			end
			return if on then L.tab_on else "#00000000"
		end,
		hover = { bg = L.hover },
		border = 0,
		on_click = o.on_click,
		M.icon(o.icon, o.icon_size or 14),
	}
end

-- Text in the panels' UI face.
function M.text(L: any, s: any, o: { size: number?, weight: number?, color: any?, mono: boolean?, truncate: boolean?, grow: number? }?): Node
	local oo = o or {}
	return ui.text {
		s,
		text_size = oo.size or 12,
		weight = oo.weight or 400,
		color = oo.color or L.fg,
		font = if oo.mono then Look.FIELD else Look.UI,
		truncate = oo.truncate,
		grow = oo.grow,
		min_w = 0,
	}
end

-- A section: a title (11/500), actions at its right, then its body.
function M.section(L: any, title: string, actions: { Node }?, body: { Node }?): Node
	-- pen's rhythm: a 1px line, 8, a 22 high title row (11/500), 6, the
	-- rows, 15 (8 when the section is its title alone).
	local has_body = body ~= nil and #body > 0
	local head = ui.row {
		w_full = true,
		items = "center",
		h = 22,
		mb = if has_body then 6 else 0,
		M.text(L, title, { weight = 500, color = L.title }),
		ui.div { grow = 1 },
		table.unpack(actions or {}),
	}
	-- (pl 15: +1 of the island's rim makes pen's 16)
	local col = { w_full = true, pt = 8, pr = 14, pb = if has_body then 15 else 8, pl = 15, border_sides = { 1, 0, 0, 0 }, border_color = L.line, head }
	for _, b in body or {} do
		table.insert(col, b)
	end
	return ui.column(col :: any)
end

-- Two fields a row (pen's 1fr 1fr, gap 6).
function M.pair(a: Node, b: Node?): Node
	return ui.row {
		w_full = true,
		gap = 6,
		ui.div { grow = 1, basis = 0, min_w = 0, a },
		ui.div { grow = 1, basis = 0, min_w = 0, b or ui.div {} },
	}
end

function M.row(children: { Node }, gap: number?): Node
	local r: any = { w_full = true, gap = gap or 6, items = "center" }
	for _, c in children do
		table.insert(r, c)
	end
	return ui.row(r)
end

-- A field: `value()` the text it shows (nil: Mixed), `commit(text)` on Enter
-- or leaving it changed. `label` (or `icon`) is its 24-wide prefix; dragging
-- it sideways scrubs a number (`scrub(dx)`). `unit` after the value.
export type FieldProps = {
	id: string?,
	label: string?,
	icon: string?,
	tip: string?,
	value: () -> string?,
	commit: (text: string) -> (),
	scrub: ((delta: number) -> ())?,
	unit: string?,
	read_only: boolean?,
	mono: boolean?,
	placeholder: string?,
	w: number?,
	trailing: Node?,
	leading: Node?,
	radius: any?,
	bg: string?, -- the field's fill (default: pen's field grey)
	fg: string?, -- the value's colour (default: pen's value grey)
	outline: string?, -- a 1px border in this colour (dashed with `dashed`)
	dashed: boolean?,
}
function M.field(L: any, o: FieldProps): Node
	return ui.component(function(): Node
		return M.field_body(L, o)
	end)({})
end
function M.field_body(L: any, o: FieldProps): Node
	local focused = ui.use_state(false)
	local scrub_from: number? = nil
	local scrubbed = 0
	local prefix: Node? = nil
	if o.icon or o.label then
		prefix = ui.div {
			w = 24,
			min_w = 24,
			shrink = 0,
			h_full = true,
			items = "center",
			justify = "center",
			cursor = if o.scrub then "ew_resize" else "default",
			color = L.pre,
			on_press = function(e: any)
				if o.scrub then
					scrub_from = e.x
					scrubbed = 0
				end
			end,
			on_pointer_move = function(e: any)
				local from = scrub_from
				if from and o.scrub then
					local d = math.floor((e.x - from) / 2)
					if d ~= scrubbed then
						o.scrub(d - scrubbed)
						scrubbed = d
					end
				end
			end,
			on_release = function()
				scrub_from = nil
			end,
			if o.icon then M.icon(o.icon, 13) else M.text(L, o.label :: string, { weight = 500, color = L.pre }),
		}
	end
	local input = ui.input {
		id = o.id,
		label = o.tip or o.label or "",
		value = function(): string
			return o.value() or ""
		end,
		placeholder = if o.value() == nil then "Mixed" else o.placeholder,
		placeholder_color = L.pre,
		on_commit = function(t: string)
			if not o.read_only then
				o.commit(t)
			end
		end,
		read_only = o.read_only,
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
		pl = if prefix or o.leading then 0 else 8,
		pr = 8,
		py = 0,
		bg = "#00000000",
		border = 0,
		rounded = 0,
		focus = { outline = 0 },
		color = o.fg or (if o.read_only then L.pre else L.val),
		text_size = 12,
		font = if o.mono == false then Look.UI else Look.FIELD,
		shrink = 1,
	}
	local r: any = {
		h = 28,
		w = o.w or "100%",
		min_w = 0,
		items = "center",
		rounded = if type(o.radius) == "number" then o.radius elseif o.radius == nil then 8 else nil,
		corners = if type(o.radius) == "table" then o.radius else nil,
		bg = function(): string
			return if focused:get() then L.field_active else (o.bg or L.field)
		end,
		outline = function(): number
			return if focused:get() then 1 else 0
		end,
		outline_color = L.accent,
		outline_offset = -1,
		opacity = 1, -- (pen greys a read-only value's text, not the field)
		border = if o.outline then 1 else 0,
		border_color = o.outline,
		border_dash = if o.dashed then { 3, 2 } else nil,
	}
	if o.leading then
		table.insert(r, o.leading)
	end
	if prefix then
		table.insert(r, prefix)
	end
	table.insert(r, input)
	if o.unit then
		table.insert(r, ui.div { pr = 8, M.text(L, o.unit, { weight = 500, color = L.pre }) })
	end
	if o.trailing then
		table.insert(r, o.trailing)
	end
	return ui.row(r)
end

-- A number field: `get()` a number (nil: Mixed), `set(n)`.
function M.num(L: any, o: { id: string?, label: string?, icon: string?, tip: string?, get: () -> number?, set: (n: number) -> (), unit: string?, min: number?, max: number?, read_only: boolean?, step: number?, trailing: Node?, fg: string? }): Node
	local function fmt(v: number?): string?
		if v == nil then
			return nil
		end
		local r = math.floor(v * 100 + 0.5) / 100
		if r == math.floor(r) then
			return tostring(math.floor(r))
		end
		return tostring(r)
	end
	local function clamp(n: number): number
		if o.min then
			n = math.max(o.min, n)
		end
		if o.max then
			n = math.min(o.max, n)
		end
		return n
	end
	return M.field(L, {
		id = o.id,
		fg = o.fg,
		label = o.label,
		icon = o.icon,
		tip = o.tip,
		unit = o.unit,
		read_only = o.read_only,
		trailing = o.trailing,
		value = function(): string?
			return fmt(o.get())
		end,
		commit = function(t: string)
			-- (Arithmetic, as pen's fields take it: "120+8".)
			local s = string.gsub(t, "[^%d%.%-%+%*/%(%) ]", "")
			local n = tonumber(s)
			if n == nil and s ~= "" and #s < 40 then
				local a, op, b = string.match(s, "^%s*([%d%.%-]+)%s*([%+%-%*/])%s*([%d%.]+)%s*$")
				local x, y = tonumber(a), tonumber(b)
				if x and y then
					n = if op == "+" then x + y elseif op == "-" then x - y elseif op == "*" then x * y else (if y ~= 0 then x / y else x)
				end
			end
			if n then
				o.set(clamp(n))
			end
		end,
		scrub = if o.read_only then nil else function(d: number)
			local v = o.get() or 0
			o.set(clamp(v + d * (o.step or 1)))
		end,
	})
end

-- The segmented control: a 28 high track (p2, r8) of segments h24 r6,
-- gap 2; the ones not chosen at 70%; icons or words.
function M.seg(L: any, o: { value: () -> any, options: { { value: any, icon: string?, label: string?, tip: string? } }, commit: (v: any) -> () }): Node
	local r: any = { w_full = true, h = 28, p = 2, gap = 2, rounded = 8, bg = L.field }
	for _, opt in o.options do
		table.insert(
			r,
			ui.button {
				label = opt.tip or opt.label or tostring(opt.value),
				grow = 1,
				basis = 0,
				h = 24,
				p = 0,
				rounded = 6,
				border = 0,
				items = "center",
				justify = "center",
				color = L.fg_strong,
				opacity = function(): number
					return if o.value() == opt.value then 1 else 0.7
				end,
				bg = function(): string
					return if o.value() == opt.value then L.tgl_on else "#00000000"
				end,
				shadow = function(): any
					return if o.value() == opt.value and L.tgl_on == "#ffffff" then { y = 1, blur = 2, color = "#00000014" } else false
				end,
				hover = { bg = L.hover },
				on_click = function()
					o.commit(opt.value)
				end,
				if opt.icon then M.icon(opt.icon, 14) else M.text(L, opt.label or "", { size = 10.5, color = L.fg_strong }),
			}
		)
	end
	return ui.row(r)
end

-- pen's checkbox: 16px, r4; on, filled.
function M.check(L: any, o: { label: string, get: () -> boolean?, set: (on: boolean) -> () }): Node
	return ui.row {
		h = 16,
		gap = 4,
		items = "center",
		on_click = function()
			o.set(not o.get())
		end,
		ui.div {
			w = 16,
			h = 16,
			rounded = 4,
			items = "center",
			justify = "center",
			border = 1,
			border_color = function(): string
				return if o.get() then L.chk_on else L.chk_br
			end,
			bg = function(): string
				return if o.get() then L.chk_on else L.chk_off
			end,
			ui.div {
				opacity = function(): number
					return if o.get() == true then 1 else 0
				end,
				M.icon("check", 12, L.chk_mark, 2.4),
			},
		},
		M.text(L, o.label, { size = 10, color = L.val }),
	}
end

-- A colour's swatch (16px r4 over a checkerboard).
function M.swatch(L: any, color: () -> string, on_click: (() -> ())?): Node
	return ui.div {
		w = 16,
		h = 16,
		min_w = 16,
		shrink = 0,
		rounded = 4,
		ml = 3,
		mr = 4,
		overflow = "hidden",
		bg = "#ffffff",
		border = 1,
		border_color = L.btn_br,
		on_click = on_click,
		ui.div { absolute = true, left = 0, top = 0, w = 8, h = 8, bg = "#cccccc" },
		ui.div { absolute = true, left = 8, top = 8, w = 8, h = 8, bg = "#cccccc" },
		ui.div {
			absolute = true,
			left = 0,
			top = 0,
			w = 16,
			h = 16,
			bg = function(): string
				return color()
			end,
		},
	}
end

-- A popover menu's row (pen's: h28, 12px, r6, neutral highlight).
-- pen's tooltip: a pill (inverted against the theme), r8, 6/12, the label
-- 12/400 and its key at 50%. `text` may carry the key after two spaces
-- ("Move  V").
function M.tip(L: any, text: string): Node
	local label, key = string.match(text, "^(.-)%s%s+(.+)$")
	return ui.row {
		h = 28,
		px = 12,
		gap = 8,
		rounded = 8,
		items = "center",
		bg = L.tip_bg,
		ui.text { label or text, text_size = 12, color = L.tip_fg, font = M_UI },
		if key then ui.text { key, text_size = 12, color = L.tip_fg, opacity = 0.5, font = M_UI } else ui.div {},
	}
end

-- pen's menu row: 28 high, label 12/400, its shortcut 11/400 grey at the end
-- (as pen writes them: "CtrlC", "⇧A"); `danger` in pen's red; `sub` a chevron.
function M.menu_item(L: any, o: { label: string, shortcut: string?, on_click: () -> (), disabled: boolean?, checked: boolean?, danger: boolean? }): Node
	return ui.menu_item {
		label = o.label,
		on_click = o.on_click,
		disabled = o.disabled,
		checked = o.checked,
		h = 28,
		px = 8,
		rounded = 6,
		hover = { bg = L.pop_hl },
		ui.row {
			w_full = true,
			h = 28,
			gap = 12,
			items = "center",
			opacity = if o.disabled then 0.45 else 1,
			ui.text { o.label, text_size = 12, color = if o.danger then L.danger else L.fg_strong, font = Look.UI, grow = 1 },
			if o.shortcut then ui.text { o.shortcut, text_size = 12, color = L.faint, font = Look.UI } else ui.div {},
		},
	}
end

function M.menu_head(L: any, label: string): Node
	return ui.div {
		px = 8,
		pt = 6,
		pb = 4,
		ui.text { string.upper(label), text_size = 10, weight = 500, color = L.pre, letter_spacing = 0.2, font = Look.UI },
	}
end

function M.menu_sep(L: any): Node
	return ui.div { h = 1, my = 4, w_full = true, bg = L.menu_line }
end

-- The style a popover or menu panel takes: solid, r10, p4, a 1px rim.
function M.pop_style(L: any): { [string]: any }
	return { bg = L.pop, rounded = 10, p = 4, shadow = L.pop_shadow, border = 1, border_color = L.rim, w = 200 }
end

-- An island: a floating card, r14, a 1px rim and a soft shadow.
function M.island(L: any, props: { [any]: any }): Node
	props.bg = L.card
	props.rounded = props.rounded or 14
	props.border = 1
	props.border_color = L.rim
	props.shadow = props.shadow or L.island_shadow
	if props.absolute == nil then
		props.absolute = true
	end
	return ui.column(props :: any)
end

-- A bar island: 40 high, r12 (the title pill, the rail's islands, the theme
-- bar, the zoom pill).
function M.bar(L: any, props: { [any]: any }): Node
	props.rounded = props.rounded or Look.BAR_R
	if props.h == nil and props.direction ~= "column" then
		props.h = Look.BAR_H
	end
	return M.island(L, props)
end

-- A button with a label (and an icon before it): h28 r8, 12/500.
-- `kind`: "secondary" (field grey, the default), "primary" (accent),
-- "ghost" (clear until hovered), "danger" (red text).
function M.button(L: any, o: { label: string, icon: string?, on_click: () -> (), kind: string?, w: any?, grow: number?, id: string?, disabled: boolean?, h: number? }): Node
	local kind = o.kind or "secondary"
	local bg = if kind == "primary" then L.accent elseif kind == "secondary" then L.field else "#00000000"
	local fg = if kind == "primary" then L.on_accent elseif kind == "danger" then L.danger else L.fg
	local r: any = {
		id = o.id,
		label = o.label,
		h = o.h or 28,
		w = o.w,
		grow = o.grow,
		px = 10,
		py = 0,
		gap = 6,
		rounded = 8,
		border = 0,
		items = "center",
		justify = "center",
		bg = bg,
		color = fg,
		opacity = if o.disabled then 0.45 else 1,
		hover = { bg = if kind == "primary" then L.accent else L.field_active, opacity = if kind == "primary" then 0.9 else nil },
		focus = { outline = 0 },
		on_click = if o.disabled then function() end else o.on_click,
	}
	if o.icon then
		table.insert(r, M.icon(o.icon, 14))
	end
	table.insert(r, ui.text { o.label, text_size = 12, weight = 500, color = fg, font = Look.UI, truncate = true, min_w = 0 })
	return ui.button(r)
end

-- A key's cap for shortcuts: each key a small field-grey box, 11px, muted
-- ("Ctrl", "⇧", "Z").
function M.keycaps(L: any, keys: { string }): Node
	local r: any = { gap = 3, items = "center", shrink = 0 }
	for _, k in keys do
		table.insert(
			r,
			ui.div {
				h = 18,
				min_w = 18,
				px = 5,
				rounded = 4,
				items = "center",
				justify = "center",
				bg = L.keycap,
				ui.text { k, text_size = 11, color = L.keycap_fg, font = Look.UI },
			}
		)
	end
	return ui.row(r)
end

-- An empty state: a 16px icon, a 12/600 title, a 12 muted line, an action.
function M.empty(L: any, o: { icon: string?, title: string, body: string?, action: Node? }): Node
	return ui.column {
		w_full = true,
		items = "center",
		gap = 6,
		px = 16,
		py = 20,
		if o.icon then ui.div { color = L.muted, mb = 2, M.icon(o.icon, 16) } else ui.div {},
		ui.text { o.title, text_size = 12, weight = 600, color = L.fg, font = Look.UI },
		if o.body then ui.text { o.body, text_size = 12, color = L.muted, font = Look.UI, align = "center", wrap = true, w_full = true } else ui.div {},
		if o.action then ui.div { mt = 6, o.action } else ui.div {},
	}
end

return M
