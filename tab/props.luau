--!strict
-- The hand cursor on clickable controls (zgx's ui is read-only: see pointer.luau).
local ui = require("./pointer").ui
-- The properties panel, as the redesign's Inspector draws it (Board ·
-- Inspector): a header (the name in a field with its type icon, the panel
-- toggle; Create component / Go to component / Detach), Context,
-- Alignment, Position (X Y, rotation, rotate 90 and flips), Layout
-- (direction, the 3×3 grid beside Gap | Between | Around, padding, a
-- Fixed | Hug | Fill row an axis; text: its Resizing), Appearance, Fill and
-- Stroke (a row a paint: swatch, hex or variable, %), Typography, Effects
-- (a type dropdown, X Y B S, the colour), Code, Export. Sections: 12 all
-- round, a 16 high head (12/500) with its actions, rows 28 apart by 8.
--
-- It shows the selection's nodes as the file has them (`source.node`), what
-- they share or "Mixed", and is built again when the selection or a
-- selected node changes. A field commits on Enter or on leaving it (a
-- Canvas click included); every change is one `edit` call for the whole
-- selection: one undo step.

local Kit = require("./kit")
local Look = require("./look")
local Layers = require("./layers")
local Picker = require("./picker")
local Bind = require("./bind")

local Pdf = require("./pdf")

-- What the running zgx can export besides PNG, checked once a window: a 1×1
-- picture asked for as JPEG and as WEBP (zgx #2116), its bytes looked at (an
-- older zgx draws a PNG whatever it's asked). PDF pages are JPEGs.
-- The most a picture zgx draws holds (`ui.render_canvas`: "canvas raster
-- exceeds 32 MiB", 4 bytes a pixel), and the largest scale (to 0.01, at most
-- `want`) a w×h layer can be drawn at within it.
local RASTER_MAX = 32 * 1024 * 1024
local function fit_scale(w: number, h: number, want: number): number
	local function bytes(s: number): number
		return math.ceil(w * s) * math.ceil(h * s) * 4
	end
	if bytes(want) <= RASTER_MAX then
		return want
	end
	local s = math.floor(math.sqrt(RASTER_MAX / (4 * w * h)) * 100) / 100
	while s > 0.01 and bytes(s) > RASTER_MAX do
		s -= 0.01
	end
	return math.max(0.01, s)
end
local function fmt_scale(s: number): string
	return if s == math.floor(s) then `{s}x` else `{string.format("%.2f", s)}x`
end
local SEVERAL = "Several layers export as one .zip with the next Zeron update. For now, select one layer and export it."
local caps_state: any = nil
local function export_caps(): any
	if caps_state then
		return caps_state
	end
	caps_state = ui.state("design-pure.export.caps", { jpeg = false, webp = false })
	ui.after(0, function()
		ui.task(function()
			for fmt, magic in { jpeg = "/9j/", webp = "UklGR" } do
				local ok, promise = pcall(ui.render_canvas, function(c: Canvas)
					c:fill(ui.path():rect(0, 0, 1, 1), "#ffffffff")
				end, { width = 1, height = 1, scale = 1, format = fmt } :: any)
				if ok and promise then
					local got, b64 = pcall(function(): any
						return promise:await()
					end)
					if got and type(b64) == "string" and string.sub(b64, 1, #magic) == magic then
						caps_state:set_key({ fmt }, true)
					end
				end
			end
		end)
	end)
	return caps_state
end

local picker_st: any = nil
local function picker_state(): any
	if not picker_st then
		picker_st = ui.state("design-pure.props.picker", "")
	end
	return picker_st
end

-- Where each open picker lines up beside its row ("<ids>|<swatch id>" to
-- "start" / "center" / "end"), and the tallest the picker gets.
local picker_align: { [string]: string } = {}
local PICKER_H = 430

local M = {}

-- Base64 to its bytes (a PNG for `ui.write_file`).
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_AT: { [number]: number } = {}
for i = 1, 64 do
	B64_AT[string.byte(B64, i)] = i - 1
end
function M.unbase64(s: string): string
	local out = table.create(math.floor(#s * 3 / 4))
	local bits, n = 0, 0
	for i = 1, #s do
		local v = B64_AT[string.byte(s, i)]
		if v then
			bits = bit32.bor(bit32.lshift(bits, 6), v)
			n += 6
			if n >= 8 then
				n -= 8
				table.insert(out, string.char(bit32.band(bit32.rshift(bits, n), 255)))
			end
		end
	end
	return table.concat(out)
end

local TYPE = { frame = "Frame", text = "Text", rectangle = "Rectangle", ellipse = "Ellipse", instance = "Instance", icon = "Icon", path = "Path", polygon = "Polygon", line = "Line" }

local function eq(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not eq(v, b[k]) then
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

local function paints_of(f: any): { any }
	if f == nil then
		return {}
	end
	if type(f) == "table" and f[1] ~= nil then
		return f
	end
	if type(f) == "table" and next(f) == nil then
		return {}
	end
	return { f }
end

local function pack_paints(list: { any }): any
	if #list == 0 then
		return "__null"
	end
	if #list == 1 and type(list[1]) == "string" then
		return list[1]
	end
	return list
end

local function padding4(p: any): { any }
	if p == nil then
		return { 0, 0, 0, 0 }
	end
	if type(p) ~= "table" then
		return { p, p, p, p }
	end
	if #p == 2 then
		return { p[1], p[2], p[1], p[2] }
	end
	if #p == 4 then
		return table.clone(p)
	end
	return { p[1] or 0, p[1] or 0, p[1] or 0, p[1] or 0 }
end

local function pack_padding(p: { any }): any
	if eq(p[1], p[2]) and eq(p[2], p[3]) and eq(p[3], p[4]) then
		return if p[1] == 0 then "__null" else p[1]
	end
	if eq(p[1], p[3]) and eq(p[2], p[4]) then
		return { p[1], p[2] }
	end
	return p
end

export type PropsProps = {
	L: any,
	source: any,
	infos: { any }, -- { id, node, box, resolved, parent }
	tokens: any?, -- the `tokens` answer
	on_toggle: (() -> ())?,
	select: ((ids: { string }) -> ())?,
	-- A node drawn as a PNG (base64) at a scale, as the Canvas draws it.
	render_png: ((id: string, scale: number, done: (b64: string?, err: string?) -> ()) -> ())?,
	render_layer: ((id: string, scale: number, opts: any) -> (any, any))?,
	eyedrop: ((done: (hex: string) -> ()) -> ())?,
}

function M.Props(props: PropsProps): Node
	local L = props.L
	local source = props.source
	local CLEAR = "#00000000"
	-- (A copy of its own: state's values are read-only, and a change shows
	-- in the panel at once.)
	local function deep(v: any): any
		if type(v) ~= "table" then
			return v
		end
		local out = {}
		for k, x in v do
			out[k] = deep(x)
		end
		return out
	end
	local sel = deep(props.infos)
	local expanded = ui.use_state({ padding = false, radius = false })
	-- The open paint picker, "<ids>|<swatch id>" (one a window, outside the
	-- panel so it outlives the panel's rebuilds); another selection closes it.
	local picker_open = picker_state()
	local ids_l = {}
	for _, s in sel do
		table.insert(ids_l, s.id)
	end
	local sel_key = table.concat(ids_l, ",")
	do
		local held = picker_open:peek()
		if held ~= "" and string.sub(held, 1, #sel_key + 1) ~= sel_key .. "|" then
			ui.after(0, function()
				if picker_open:peek() == held then
					picker_open:set("")
				end
			end)
		end
	end

	-- The redesign's parts ---------------------------------------------------------------
	-- A section: 12 all round, 8 between its rows, a 1px line above; its head
	-- 16 high (12/500, muted while it's empty) with its actions at the right.
	local function sec(title: string, actions: { Node }?, body: { Node }?, o: { id: string?, on_head: (() -> ())?, dim: boolean? }?): Node
		local oo = o or {}
		local has = body ~= nil and #body > 0
		local head: any = {
			id = oo.id,
			w_full = true,
			h = 16,
			gap = 6,
			items = "center",
			on_click = oo.on_head,
			cursor = if oo.on_head then "pointer" else nil,
			Kit.text(L, title, { weight = 500, color = if oo.dim or (oo.dim == nil and not has) then L.muted else L.fg, grow = 1 }),
		}
		for _, a in actions or {} do
			table.insert(head, a)
		end
		local col: any = { w_full = true, p = 12, gap = 8, border_sides = { 1, 0, 0, 0 }, border_color = L.border, ui.row(head) }
		for _, b in body or {} do
			table.insert(col, b)
		end
		return ui.column(col)
	end
	-- A head's action (+, ⋯, the eye): a 14px icon in a 20px target.
	local function act(icon: string, label: string, fn: () -> (), color: string?, id: string?): Node
		return ui.button {
			id = id,
			label = label,
			tooltip = label,
			w = 20,
			h = 20,
			my = -2,
			mr = -3,
			p = 0,
			shrink = 0,
			rounded = 6,
			border = 0,
			items = "center",
			justify = "center",
			bg = CLEAR,
			hover = { bg = L.hover },
			color = color or L.faint,
			on_click = fn,
			Kit.icon(icon, 14),
		}
	end
	-- A row's small action (eye, −): 20 square, icon 14, faint.
	local function mini(icon: string, label: string, fn: () -> (), color: string?): Node
		return ui.button {
			label = label,
			tooltip = label,
			w = 20,
			h = 20,
			p = 0,
			shrink = 0,
			rounded = 6,
			border = 0,
			items = "center",
			justify = "center",
			bg = CLEAR,
			hover = { bg = L.hover },
			color = color or L.faint,
			on_click = fn,
			Kit.icon(icon, 14),
		}
	end
	-- A 28 square icon button (the panel toggle, per side, corners);
	-- `filled`: on the field grey; `on`: pressed (accent).
	local function sq(icon: string, label: string, fn: () -> (), o: { filled: boolean?, on: boolean?, id: string? }?): Node
		local oo = o or {}
		return ui.button {
			id = oo.id,
			label = label,
			tooltip = label,
			w = 28,
			h = 28,
			p = 0,
			shrink = 0,
			rounded = 8,
			border = 0,
			items = "center",
			justify = "center",
			bg = if oo.on then L.accent_soft elseif oo.filled then L.field else CLEAR,
			hover = { bg = if oo.on then L.accent_soft else L.field_active },
			color = if oo.on then L.accent_fg else L.muted,
			on_click = fn,
			Kit.icon(icon, 14),
		}
	end
	-- A group of icon buttons on one field-grey track (p2, gap 2, h24 r6).
	local function group(btns: { Node }): Node
		local r: any = { grow = 1, basis = 0, min_w = 0, h = 28, p = 2, gap = 2, rounded = 8, bg = L.field }
		for _, b in btns do
			table.insert(r, b)
		end
		return ui.row(r)
	end
	local function gbtn(icon: string, label: string, fn: () -> (), dim: boolean?): Node
		return ui.button {
			-- (no tooltip: one wraps the button, and the wrapper wouldn't grow)
			label = label,
			opacity = if dim then 0.5 else 1,
			grow = 1,
			basis = 0,
			min_w = 0,
			h = 24,
			p = 0,
			rounded = 6,
			border = 0,
			bg = CLEAR,
			hover = { bg = L.hover },
			color = L.muted,
			items = "center",
			justify = "center",
			on_click = fn,
			Kit.icon(icon, 14),
		}
	end
	-- The segmented control: a 28 track (p2, gap 2), segments h24 r6; the
	-- chosen one raised (field_active, 12/500 fg), the others faint.
	local raised = L.field_active == "#ffffff"
	local function seg(o: { id: string?, value: () -> any, options: { { value: any, icon: string?, label: string?, tip: string? } }, commit: (v: any) -> () }): Node
		local r: any = { id = o.id, w_full = true, min_w = 0, h = 28, p = 2, gap = 2, rounded = 8, bg = L.field }
		local now = o.value()
		for _, opt in o.options do
			local function on(): boolean
				return o.value() == opt.value
			end
			table.insert(
				r,
				ui.button {
					label = opt.tip or opt.label or tostring(opt.value),
					grow = 1,
					basis = 0,
					min_w = 0,
					h = 24,
					p = 0,
					rounded = 6,
					border = 0,
					items = "center",
					justify = "center",
					color = function(): string
						return if on() then L.fg else L.faint
					end,
					bg = function(): string
						return if on() then L.field_active else CLEAR
					end,
					shadow = function(): any
						return if raised and on() then { y = 1, blur = 2, color = "#00000014" } else false
					end,
					hover = { bg = L.hover },
					on_click = function()
						o.commit(opt.value)
					end,
					if opt.icon
						then Kit.icon(opt.icon, 14)
						else ui.text {
							opt.label or "",
							text_size = 12,
							weight = if now == opt.value then 500 else 400,
							color = function(): string
								return if on() then L.fg else L.faint
							end,
							font = Look.UI,
							truncate = true,
							min_w = 0,
						},
				}
			)
		end
		return ui.row(r)
	end
	-- A checkbox: 14 r4, its label 12 muted, 8 between.
	local function check(label: string, get: () -> boolean, set: (on: boolean) -> ()): Node
		return ui.row {
			h = 16,
			gap = 8,
			items = "center",
			cursor = "pointer",
			on_click = function()
				set(not get())
			end,
			ui.div {
				w = 14,
				h = 14,
				shrink = 0,
				rounded = 4,
				items = "center",
				justify = "center",
				border = 1,
				border_color = function(): string
					return if get() then L.accent else L.chk_br
				end,
				bg = function(): string
					return if get() then L.accent else CLEAR
				end,
				ui.div {
					opacity = function(): number
						return if get() then 1 else 0
					end,
					Kit.icon("check", 10, L.on_accent, 2.6),
				},
			},
			Kit.text(L, label, { color = L.muted }),
		}
	end
	-- A small label over a group of rows (12 faint).
	local function sub(text: string): Node
		return ui.div { w_full = true, h = 16, Kit.text(L, text, { color = L.faint }) }
	end
	-- A dropdown: a field (h28 r8) with its value and a chevron, a Kit menu.
	local function dropdown(o: { id: string, label: string, value: () -> string, items: { { label: string, checked: boolean?, on_click: () -> () } }, leading: Node?, extra: Node?, menu_w: number? }): Node
		local open = ui.use_state(false)
		local anchor: any = {
			id = o.id,
			label = o.label,
			w_full = true,
			h = 28,
			pl = if o.leading then 0 else 8,
			pr = 8,
			gap = 6,
			rounded = 8,
			border = 0,
			bg = L.field,
			hover = { bg = L.field_active },
			focus = { outline = 0 },
			items = "center",
			on_click = ui.toggle(open),
		}
		if o.leading then
			table.insert(anchor, o.leading)
		end
		table.insert(anchor, ui.text { o.value, text_size = 12, color = L.fg, font = Look.UI, grow = 1, truncate = true, min_w = 0 })
		if o.extra then
			table.insert(anchor, o.extra)
		end
		table.insert(anchor, ui.div { shrink = 0, color = L.faint, Kit.icon("chevDown", 13) })
		local mp: any = { open = open, label = o.label, anchor = ui.button(anchor) }
		for _, it in o.items do
			table.insert(mp, Kit.menu_item(L, { label = it.label, checked = it.checked, on_click = it.on_click }))
		end
		for k2, v2 in Kit.pop_style(L) do
			mp[k2] = v2
		end
		mp.w = o.menu_w or 200
		return ui.menu(mp)
	end
	-- A secondary button (Kit.button's look) whose label may change.
	local function wide_btn(id: string, label: any, icon: string?, fn: () -> (), w_full: boolean?): Node
		local r: any = {
			id = id,
			label = if type(label) == "string" then label else id,
			grow = if w_full then nil else 1,
			basis = if w_full then nil else 0,
			w_full = w_full,
			min_w = 0,
			h = 28,
			px = 10,
			gap = 6,
			rounded = 8,
			border = 0,
			bg = L.field,
			hover = { bg = L.field_active },
			focus = { outline = 0 },
			items = "center",
			justify = "center",
			color = L.muted,
			on_click = fn,
		}
		if icon then
			table.insert(r, Kit.icon(icon, 14))
		end
		table.insert(r, ui.text { label, text_size = 12, weight = 500, color = L.fg, font = Look.UI, truncate = true, min_w = 0 })
		return ui.button(r)
	end
	-- A field's leading icon (13, faint) where a letter would be.
	local function lead_icon(icon: string, color: string?): Node
		return ui.div { w = 24, min_w = 24, shrink = 0, h_full = true, pl = 2, items = "center", justify = "center", color = color or L.faint, Kit.icon(icon, 13) }
	end

	if #sel == 0 then
		return ui.column {
			w_full = true,
			ui.row {
				w_full = true,
				p = 12,
				gap = 6,
				items = "center",
				Kit.text(L, "Design", { weight = 500, color = L.fg, grow = 1 }),
				if props.on_toggle then sq("panelRight", "Hide properties", props.on_toggle :: any) else ui.div {},
			},
			ui.div { px = 12, pb = 16, Kit.text(L, "Select a layer to see its properties.", { color = L.muted }) },
		}
	end

	-- Token values (the first value of each), for chips and the picker.
	local tokens = (props.tokens and props.tokens.tokens) or {}
	local function resolve(v: any, depth: number?): any
		local d = depth or 0
		if type(v) == "string" and string.sub(v, 1, 1) == "$" and d < 8 then
			local t = tokens[string.sub(v, 2)]
			if not t then
				return v
			end
			local val = t.value
			if type(val) == "table" and val[1] ~= nil then
				val = val[1].value
			end
			return resolve(val, d + 1)
		end
		return v
	end
	local color_tokens = {}
	for name, t in tokens do
		if t.type == "color" then
			table.insert(color_tokens, { name = name, value = resolve("$" .. name) })
		end
	end
	table.sort(color_tokens, function(a, b)
		return a.name < b.name
	end)
	-- (step 5, V5b) every variable, for the Apply variable lists
	local bind_vars = Bind.vars(props.tokens)

	-- What the selection shares: `value`, or nil and `mixed`.
	local function shared(fn: (s: any) -> any): (any, boolean)
		local first = fn(sel[1])
		for i = 2, #sel do
			if not eq(fn(sel[i]), first) then
				return nil, true
			end
		end
		return first, false
	end
	local function prop(k: string): (any, boolean)
		return shared(function(s)
			return s.node[k]
		end)
	end
	local function all(pred: (s: any) -> boolean): boolean
		for _, s in sel do
			if not pred(s) then
				return false
			end
		end
		return true
	end
	local function laid(s: any): boolean
		local p = s.parent
		return p ~= nil and (p.layout == "horizontal" or p.layout == "vertical") and not s.node.absolute
	end
	local function n(v: any): number?
		local r = resolve(v)
		return if type(r) == "number" then r else tonumber(r)
	end

	-- Edits: one call, every selected node.
	local function update(make: { [string]: any } | (s: any) -> { [string]: any }, label: string, live: boolean?)
		local ops = {}
		for _, s in sel do
			local p = if type(make) == "function" then make(s) else make
			if next(p) ~= nil then
				-- (a rotation turns about the layer's centre, as Figma's field does)
				table.insert(ops, { op = "update", id = s.id, props = p, turn = if p.rotation ~= nil then true else nil })
				-- (Shown at once: the next scene confirms it.)
				for k, v in p do
					s.node[k] = if v == "__null" then nil else v
				end
			end
		end
		if #ops > 0 then
			source.edit(ops, label, { join = live })
		end
	end

	local function fmt_num(x: number): string
		local r = math.floor(x * 100 + 0.5) / 100
		return if r == math.floor(r) then tostring(math.floor(r)) else tostring(r)
	end
	-- (step 5, V5b) A field with an Apply variable button at its end, shown
	-- while the field is hovered (or its list is open), as Figma's.
	local function with_bind(id: string, what: string, kinds: { string }, pick: (name: string) -> (), build: (trailing: Node) -> Node): Node
		return ui.component(function(): Node
			local hov = ui.use_state(false)
			local btn = Bind.button(L, {
				id = id,
				what = what,
				kinds = kinds,
				vars = bind_vars,
				pick = pick,
				shown = function(): boolean
					return hov:get()
				end,
			})
			return ui.div {
				w_full = true,
				min_w = 0,
				on_hover = function(on: boolean)
					hov:set(on)
				end,
				build(ui.div { shrink = 0, mr = 4, btn }),
			}
		end)({})
	end
	local function bind_id(tip: string): string
		return "bind-" .. string.lower((string.gsub(tip, "[^%w]+", "-")))
	end

	local function value_num(o: { empty: string?, label: string?, icon: string?, tip: string?, key: string, get: ((s: any) -> any)?, set: ((s: any, v: number) -> any)?, unit: string?, min: number?, max: number?, read_only: boolean?, scale: number?, show: ((x: number) -> number)?, fg: string?, bind: boolean?, bind_set: ((s: any, ref: string) -> any)? }): Node
		local get = o.get or function(s: any): any
			return s.node[o.key]
		end
		local v, mixed = shared(get)
		local what = o.tip or o.label or o.key
		-- (step 5, V5b) binding it: `bind_set(s, "$name")`, else `set(s, "$name")`
		-- (the setters only place the value), else the key itself.
		local function bind_to(name: string)
			local ref = "$" .. name
			update(function(s: any): { [string]: any }
				if o.bind_set then
					return { [o.key] = o.bind_set(s, ref) }
				elseif o.set then
					return { [o.key] = o.set(s, ref :: any) }
				end
				return { [o.key] = ref }
			end, "Apply variable")
		end
		if o.bind and not o.read_only and not mixed and Bind.ref(v) then
			local name = Bind.ref(v) :: string
			local x = n(resolve(v))
			local shown = if x and o.show then o.show(x) elseif x then x * (o.scale or 1) else nil
			return Bind.chip(L, {
				id = bind_id(what) .. "-chip",
				what = what,
				name = name,
				kind = Bind.kind_of(bind_vars, name),
				value = shown,
				vars = bind_vars,
				kinds = { "number" },
				pick = bind_to,
				detach = function()
					local keep = shown or 0
					update(function(s: any): { [string]: any }
						return { [o.key] = if o.set then o.set(s, keep) else keep / (o.scale or 1) }
					end, "Detach variable")
				end,
			})
		end
		-- Unset, with a word for it ("Auto"): that word, greyed.
		if not mixed and v == nil and o.empty then
			return Kit.field(L, {
				label = o.label,
				icon = o.icon,
				tip = o.tip,
				unit = o.unit,
				placeholder = o.empty,
				value = function(): string?
					return ""
				end,
				commit = function(t: string)
					local x = tonumber(t)
					if x then
						update(function(s: any): { [string]: any }
							return { [o.key] = if o.set then o.set(s, x) else x / (o.scale or 1) }
						end, "Change " .. (o.tip or o.key))
					end
				end,
			})
		end
		-- A variable bound to it: its value in the accent, and the variable
		-- mark (detaches it, keeping the value).
		if not mixed and type(v) == "string" and string.sub(v, 1, 1) == "$" then
			local x = n(resolve(v))
			local shown = if x and o.show then o.show(x) elseif x then x * (o.scale or 1) else nil
			return Kit.field(L, {
				label = o.label,
				icon = o.icon,
				tip = `{o.tip or o.key} ({string.sub(v, 2)})`,
				fg = L.accent_fg,
				value = function(): string?
					return if shown then fmt_num(shown) else string.sub(v, 2)
				end,
				unit = o.unit,
				commit = function(t: string)
					local y = tonumber(t)
					if y then
						update(function(s: any): { [string]: any }
							return { [o.key] = if o.set then o.set(s, y) else y / (o.scale or 1) }
						end, "Change " .. (o.tip or o.key))
					elseif t ~= "" then
						update({ [o.key] = "$" .. t }, "Change " .. (o.tip or o.key))
					end
				end,
				trailing = ui.button {
					label = "Detach variable",
					tooltip = `Detach {string.sub(v, 2)}`,
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
					on_click = function()
						update({ [o.key] = x or 0 }, "Detach variable")
					end,
					Kit.icon("detach", 12),
				},
			})
		end
		local scale = o.scale or 1
		local function num(trailing: Node?): Node
			return Kit.num(L, {
			label = o.label,
			icon = o.icon,
			tip = o.tip,
			unit = o.unit,
			min = o.min,
			max = o.max,
			read_only = o.read_only,
			fg = o.fg,
			trailing = trailing,
			get = function(): number?
				if mixed then
					return nil
				end
				local x = n(v)
				return if x then x * scale else 0
			end,
			set = function(x: number)
				update(function(s: any): { [string]: any }
					if o.set then
						return { [o.key] = o.set(s, x) }
					end
					return { [o.key] = x / scale }
				end, "Change " .. (o.tip or o.label or o.key))
			end,
			})
		end
		if o.bind and not o.read_only then
			return with_bind(bind_id(what), string.lower(what), { "number" }, bind_to, num)
		end
		return num(nil)
	end

	local sections: { Node } = {}
	local function add(node: Node?)
		if node then
			table.insert(sections, node)
		end
	end

	-- Header ------------------------------------------------------------------------------
	do
		local one = if #sel == 1 then sel[1] else nil
		local t = if one then one.node.type else nil
		local comp = one and one.node.reusable
		local inst = one and (t == "instance" or string.find(one.id, "/", 1, true) ~= nil)
		local icon = if one then Layers.type_icon({ t = t, comp = comp, inst = if inst then true else nil, lay = one.node.layout }) else "group"
		-- The name in a field with the type icon (a Component's on its soft
		-- violet, an Instance's in a dashed outline), the panel toggle; then
		-- the Component actions, full width (an Instance's Go to and Detach
		-- as 28px squares before them).
		local tint = if comp then L.component elseif inst then L.instance else L.faint
		local acts: { Node } = {}
		if one and t == "instance" then
			table.insert(acts, sq("target", "Go to component", function()
				if props.select and one.node.ref then
					props.select({ one.node.ref })
				end
			end, { filled = true }))
			table.insert(acts, sq("detach", "Detach instance", function()
				source.edit({ { op = "detach", id = one.id } }, "Detach instance")
			end, { filled = true }))
			table.insert(acts, Kit.button(L, { label = "Create component", icon = "component", grow = 1, on_click = function()
				source.edit({ { op = "detach", id = one.id } }, "Detach instance")
				update({ reusable = true }, "Create component")
			end }))
		elseif one and comp then
			table.insert(acts, Kit.button(L, { label = "Detach component", icon = "detach", grow = 1, on_click = function()
				update({ reusable = "__null" }, "Detach component")
			end }))
		elseif one and not inst then
			table.insert(acts, Kit.button(L, { label = "Create component", icon = "component", grow = 1, on_click = function()
				update({ reusable = true }, "Create component")
			end }))
		end
		local head: Node
		if one then
			head = Kit.field(L, {
				id = "props-name",
				tip = "Layer name",
				value = function(): string?
					return one.node.name or TYPE[t] or "Layer"
				end,
				commit = function(text: string)
					if text ~= "" and text ~= one.node.name then
						update({ name = text }, "Rename")
					end
				end,
				mono = false,
				leading = lead_icon(icon, tint),
				bg = if comp then L.component_soft else nil,
				fg = if comp then L.component elseif inst then L.instance else nil,
				outline = if inst and not comp then L.instance else nil,
				dashed = inst and not comp,
			})
		else
			head = ui.row {
				h = 28,
				w_full = true,
				min_w = 0,
				rounded = 8,
				bg = L.field,
				items = "center",
				lead_icon(icon),
				Kit.text(L, `{#sel} selected`, { color = L.fg }),
			}
		end
		add(ui.column {
			w_full = true,
			p = 12,
			gap = 8,
			ui.row {
				w_full = true,
				gap = 6,
				items = "center",
				ui.div { grow = 1, min_w = 0, head },
				if props.on_toggle then sq("panelRight", "Hide properties", props.on_toggle :: any) else ui.div {},
			},
			if #acts > 0 then ui.row({ w_full = true, gap = 6, items = "center", table.unpack(acts) } :: any) else ui.div {},
		})
	end

	-- Context: what agents should know about it, kept on the node as
	-- `context`; collapsed until it holds something.
	do
		local note, mixed = prop("context")
		local has = mixed or (type(note) == "string" and note ~= "")
		local open = ui.use_state(has)
		add(ui.column {
			w_full = true,
			p = 12,
			gap = 8,
			border_sides = { 1, 0, 0, 0 },
			border_color = L.border,
			ui.row {
				id = "context-head",
				w_full = true,
				items = "center",
				h = 16,
				gap = 6,
				cursor = "pointer",
				on_click = function()
					open:set(not open:peek())
				end,
				ui.text {
					"Context",
					text_size = 12,
					weight = 500,
					font = Look.UI,
					grow = 1,
					color = function(): string
						return if open:get() or has then L.fg else L.muted
					end,
				},
				ui.div {
					color = L.faint,
					rotate = function(): number
						return if open:get() then 90 else 0
					end,
					Kit.icon("chev", 14),
				},
			},
			ui.show(
				open,
				ui.column {
					w_full = true,
					gap = 8,
					ui.textarea {
						id = "context-note",
						label = "Context for agents",
						w_full = true,
						h = 72,
						value = function(): string
							return if mixed then "" else (note or "")
						end,
						placeholder = if mixed then "Mixed" else "What agents should know about this layer…",
						placeholder_color = L.faint,
						on_commit = function(t: string)
							update({ context = if t == "" then "__null" else t }, "Context")
						end,
						wrap = true,
						px = 10,
						py = 8,
						rounded = 8,
						border = 0,
						bg = L.field,
						focus = { outline = 1, outline_color = L.accent, bg = L.field_active },
						text_size = 12,
						font = Look.UI,
						color = L.fg,
					},
					ui.row {
						w_full = true,
						h = 16,
						gap = 6,
						items = "center",
						ui.div { color = L.faint, Kit.icon("sticky", 12) },
						Kit.text(L, "Agents read this first", { color = L.faint }),
					},
				}
			),
		})
	end

	-- Alignment ---------------------------------------------------------------------------
	do
		local function align(kind: string)
			-- To the union of many, or to the parent for one.
			local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
			if #sel == 1 then
				local p = sel[1].parent_box
				if not p then
					return
				end
				x0, y0, x1, y1 = p.x, p.y, p.x + p.w, p.y + p.h
			else
				for _, s in sel do
					x0, y0 = math.min(x0, s.box.x), math.min(y0, s.box.y)
					x1, y1 = math.max(x1, s.box.x + s.box.w), math.max(y1, s.box.y + s.box.h)
				end
			end
			local ops = {}
			for _, s in sel do
				if not laid(s) then
					local b = s.box
					local dx, dy = 0, 0
					if kind == "left" then
						dx = x0 - b.x
					elseif kind == "hcenter" then
						dx = (x0 + x1) / 2 - (b.x + b.w / 2)
					elseif kind == "right" then
						dx = x1 - (b.x + b.w)
					elseif kind == "top" then
						dy = y0 - b.y
					elseif kind == "vcenter" then
						dy = (y0 + y1) / 2 - (b.y + b.h / 2)
					elseif kind == "bottom" then
						dy = y1 - (b.y + b.h)
					end
					dx, dy = math.floor(dx + 0.5), math.floor(dy + 0.5)
					if dx ~= 0 or dy ~= 0 then
						table.insert(ops, { op = "move", id = s.id, dx = dx, dy = dy })
					end
				end
			end
			if #ops > 0 then
				source.edit(ops, "Align")
			end
		end
		-- (Dimmed where they can't apply: one layer on the Canvas.)
		local dim = not (#sel > 1 or (sel[1] ~= nil and sel[1].parent_box ~= nil))
		local function b(icon: string, kind: string, tip: string): Node
			return gbtn(icon, tip, function()
				align(kind)
			end, dim)
		end
		add(sec("Alignment", nil, {
			ui.row {
				w_full = true,
				gap = 6,
				group { b("alignL", "left", "Align left"), b("alignHC", "hcenter", "Align horizontal centres"), b("alignR", "right", "Align right") },
				group { b("alignT", "top", "Align top"), b("alignVC", "vcenter", "Align vertical centres"), b("alignB", "bottom", "Align bottom") },
			},
		}))
	end

	-- Position ----------------------------------------------------------------------------
	do
		local in_layout = all(laid)
		local body: { Node } = {
			Kit.pair(
				value_num({
					label = "X",
					key = "x",
					read_only = in_layout,
					get = if in_layout then function(s: any): any
						return if s.parent_box then math.floor(s.box.x - s.parent_box.x + 0.5) else s.box.x
					end else nil,
				}),
				value_num({
					label = "Y",
					key = "y",
					read_only = in_layout,
					get = if in_layout then function(s: any): any
						return if s.parent_box then math.floor(s.box.y - s.parent_box.y + 0.5) else s.box.y
					end else nil,
				})
			),
			ui.row {
				w_full = true,
				gap = 6,
				ui.div {
					grow = 1,
					basis = 0,
					min_w = 0,
					value_num({ icon = "angle", tip = "Rotation", key = "rotation", unit = "°", set = function(_s: any, v: number): any
						return if v == 0 then "__null" else v
					end }),
				},
				group {
					gbtn("rotate", "Rotate 90°", function()
						update(function(s: any): { [string]: any }
							local r = ((n(s.node.rotation) or 0) + 90) % 360
							return { rotation = if r == 0 then "__null" else r }
						end, "Rotate")
					end),
					gbtn("flipH", "Flip horizontal", function()
						update(function(s: any): { [string]: any }
							return { flipX = if s.node.flipX then "__null" else true }
						end, "Flip")
					end),
					gbtn("flipV", "Flip vertical", function()
						update(function(s: any): { [string]: any }
							return { flipY = if s.node.flipY then "__null" else true }
						end, "Flip")
					end),
				},
			},
		}
		local any_in = false
		for _, s in sel do
			if s.parent and (s.parent.layout == "horizontal" or s.parent.layout == "vertical") then
				any_in = true
			end
		end
		if any_in then
			table.insert(
				body,
				check("Absolute position", function(): boolean
					return (prop("absolute")) == true
				end, function(on: boolean)
					update({ absolute = if on then true else "__null" }, "Absolute position")
				end)
			)
		end
		add(sec("Position", nil, body))
	end

	-- Layout (and Dimensions) ---------------------------------------------------------------
	do
		local frames = all(function(s)
			return s.node.type == "frame" or s.node.type == "instance"
		end)
		local body: { Node } = {}
		local lay, lay_mixed = "none", false
		if frames then
			lay, lay_mixed = shared(function(s)
				local l = s.node.layout
				return if l == "horizontal" or l == "vertical" then l else "none"
			end)
			table.insert(
				body,
				seg({
					id = "layout-direction",
					value = function(): any
						return if lay_mixed then nil else lay
					end,
					options = { { value = "none", icon = "layFree", tip = "Freeform" }, { value = "vertical", icon = "arrowDown", tip = "Vertical" }, { value = "horizontal", icon = "arrowRight", tip = "Horizontal" } },
					commit = function(v: any)
						update({ layout = v }, "Layout")
					end,
				})
			)
			if not lay_mixed and lay ~= "none" then
				local vert = lay == "vertical"
				local just = shared(function(s)
					return s.node.justifyContent or "start"
				end)
				local alig = shared(function(s)
					return s.node.alignItems or "start"
				end)
				local spaced = type(just) == "string" and string.sub(just, 1, 5) == "space"
				-- Alignment: a 3×3 grid of dots, the chosen cell an accent square.
				local pos = { "start", "center", "end" }
				local grid: any = { w = 84, h = 84, shrink = 0, rounded = 8, bg = L.field, p = 4, gap = 2 }
				for r = 1, 3 do
					local grid_row: any = { w_full = true, h = 24, gap = 2 }
					for c = 1, 3 do
						local j = if vert then pos[r] else pos[c]
						local a = if vert then pos[c] else pos[r]
						local on = (just == j or (spaced and (if vert then r == 2 else c == 2))) and alig == a
						table.insert(
							grid_row,
							ui.button {
								label = `{j}, {a}`,
								w = 24,
								h = 24,
								p = 0,
								border = 0,
								rounded = 6,
								bg = CLEAR,
								hover = { bg = L.hover },
								items = "center",
								justify = "center",
								on_click = function()
									local patch: { [string]: any } = { alignItems = if a == "start" then "__null" else a }
									if not spaced then
										patch.justifyContent = if j == "start" then "__null" else j
									end
									update(patch, "Align children")
								end,
								if on then ui.div { w = 10, h = 10, rounded = 2, bg = L.accent } else ui.div { w = 3, h = 3, rounded = 2, bg = L.faint },
							}
						)
					end
					table.insert(grid, ui.row(grid_row))
				end
				local gap_field = value_num({ icon = "gap", tip = "Gap", key = "gap", min = 0, bind = true, set = function(_s: any, v: number): any
					return if v == 0 then "__null" else v
				end })
				table.insert(
					body,
					ui.row {
						w_full = true,
						gap = 8,
						items = "center",
						ui.column(grid),
						ui.column {
							grow = 1,
							min_w = 0,
							gap = 6,
							gap_field,
							seg({
								id = "layout-spread",
								value = function(): any
									return if just == "space_between" then "between" elseif just == "space_around" then "around" else "gap"
								end,
								options = { { value = "gap", label = "Gap" }, { value = "between", label = "Between" }, { value = "around", label = "Around" } },
								commit = function(v: any)
									update({ justifyContent = if v == "between" then "space_between" elseif v == "around" then "space_around" else "__null" }, if v == "gap" then "Gap" else "Spread")
								end,
							}),
						},
					}
				)
				-- Padding: vertical and horizontal, or each side.
				local pad, pad_mixed = shared(function(s)
					return padding4(s.node.padding)
				end)
				local pairs_same = not pad_mixed and eq(pad[1], pad[3]) and eq(pad[2], pad[4])
				local per_side = expanded:get().padding or not pairs_same
				local fields: { Node } = {}
				if per_side then
					-- (left, right, then top, bottom)
					for _, side in { { 4, "L" }, { 2, "R" }, { 1, "T" }, { 3, "B" } } do
						local i, lbl = side[1], side[2]
						table.insert(
							fields,
							value_num({
								label = lbl,
								tip = "Padding " .. lbl,
								key = "padding",
								min = 0,
								bind = true,
								get = function(s: any): any
									return padding4(s.node.padding)[i]
								end,
								set = function(s: any, v: number): any
									local p = padding4(s.node.padding)
									p[i] = v
									return pack_padding(p)
								end,
							})
						)
					end
				else
					for i, ic in { "padV", "padH" } do
						table.insert(
							fields,
							value_num({
								icon = ic,
								tip = if i == 1 then "Vertical padding" else "Horizontal padding",
								key = "padding",
								min = 0,
								bind = true,
								get = function(s: any): any
									return padding4(s.node.padding)[i]
								end,
								set = function(s: any, v: number): any
									local p = padding4(s.node.padding)
									p[i], p[i + 2] = v, v
									return pack_padding(p)
								end,
							})
						)
					end
				end
				local toggle = sq("padding", "Padding per side", function()
					expanded:set_key({ "padding" }, not per_side)
				end, { on = per_side })
				table.insert(body, sub("Padding"))
				if per_side then
					table.insert(body, ui.row { w_full = true, gap = 6, items = "start", ui.column { grow = 1, min_w = 0, gap = 6, Kit.pair(fields[1], fields[2]), Kit.pair(fields[3], fields[4]) }, toggle })
				else
					table.insert(body, ui.row { w_full = true, gap = 6, items = "center", ui.div { grow = 1, basis = 0, min_w = 0, fields[1] }, ui.div { grow = 1, basis = 0, min_w = 0, fields[2] }, toggle })
				end
			end
		end
		-- Dimensions: a row an axis, Fixed | Hug | Fill then its size; for
		-- text, the Resizing modes then W and H.
		local text = all(function(s)
			return s.node.type == "text"
		end)
		local function axis(k: string, bk: string, lbl: string?): Node
			local tip = if k == "width" then "Width" else "Height"
			-- (step 5, V5b) bound to a number variable: its chip (detach keeps
			-- the size drawn); else the field, with Apply variable on hover
			local now, now_mixed = prop(k)
			local name = if now_mixed then nil else Bind.ref(now)
			local function bind_to(v: string)
				update({ [k] = "$" .. v }, "Apply variable")
			end
			if name then
				local x = n(resolve(now))
				return Bind.chip(L, {
					id = `bind-{k}-chip`,
					what = tip,
					name = name,
					kind = Bind.kind_of(bind_vars, name),
					value = x,
					vars = bind_vars,
					kinds = { "number" },
					pick = bind_to,
					detach = function()
						update(function(s: any): { [string]: any }
							return { [k] = math.floor(s.box[bk] + 0.5) }
						end, "Detach variable")
					end,
				})
			end
			return with_bind(`bind-{k}`, string.lower(tip), { "number" }, bind_to, function(trailing: Node): Node
				return Kit.num(L, {
				id = `size-{k}`,
				label = lbl,
				tip = tip,
				trailing = trailing,
				min = 0,
				get = function(): number?
					local v, mixed = shared(function(s)
						return math.floor(s.box[bk] * 100 + 0.5) / 100
					end)
					return if mixed then nil else v
				end,
				set = function(v: number)
					update(function(s: any): { [string]: any }
						local p: { [string]: any } = { [k] = v }
						if s.node.type == "text" then
							p.textGrowth = if k == "height" then "fixed_width_height" elseif s.node.textGrowth == "fixed_width_height" then "fixed_width_height" else "fixed_width"
						end
						return p
					end, "Resize")
				end,
				})
			end)
		end
		local function mode_of(s: any, k: string): string
			local v = s.node[k]
			if v == "fill_container" then
				return "fill"
			elseif v == "fit_content" or (v == nil and (s.node.type == "frame" or s.node.type == "instance")) then
				return "hug"
			end
			return "fixed"
		end
		local function size_row(k: string, bk: string, lbl: string, hug: boolean): Node
			local mode, mmixed = shared(function(s)
				return mode_of(s, k)
			end)
			local opts = { { value = "fixed", label = "Fixed" } }
			if hug then
				table.insert(opts, { value = "hug", label = "Hug" })
			end
			table.insert(opts, { value = "fill", label = "Fill" })
			return ui.row {
				w_full = true,
				h = 28,
				gap = 6,
				items = "center",
				ui.div { w = 14, shrink = 0, Kit.text(L, lbl, { weight = 500, color = L.faint }) },
				ui.div {
					grow = 1,
					min_w = 0,
					seg({
						id = `size-mode-{k}`,
						value = function(): any
							return if mmixed then nil else mode
						end,
						options = opts,
						commit = function(v: any)
							update(function(s: any): { [string]: any }
								if v == "fill" then
									return { [k] = "fill_container" }
								elseif v == "hug" then
									return { [k] = "fit_content" }
								end
								local p: { [string]: any } = { [k] = math.floor(s.box[bk] + 0.5) }
								if s.node.type == "text" then
									p.textGrowth = if k == "height" then "fixed_width_height" elseif s.node.textGrowth == "fixed_width_height" then "fixed_width_height" else "fixed_width"
								end
								return p
							end, if v == "fill" then "Fill" elseif v == "hug" then "Hug" else "Fixed size")
						end,
					}),
				},
				-- (wide enough for the Apply variable mark, or a bound chip)
				ui.div { w = 80, shrink = 0, axis(k, bk, nil) },
			}
		end
		if text then
			local grow_mode = shared(function(s)
				local g = s.node.textGrowth
				if g == "fixed-width" then
					g = "fixed_width"
				elseif g == "fixed-width-height" then
					g = "fixed_width_height"
				end
				return g or (if s.node.width ~= nil and s.node.height ~= nil then "fixed_width_height" elseif s.node.width ~= nil then "fixed_width" else "auto")
			end)
			table.insert(body, sub("Resizing"))
			table.insert(
				body,
				seg({
					id = "text-resizing",
					value = function(): any
						return grow_mode
					end,
					options = { { value = "auto", label = "Auto width", tip = "Auto width" }, { value = "fixed_width", label = "Auto height", tip = "Auto height" }, { value = "fixed_width_height", label = "Fixed", tip = "Fixed size" } },
					commit = function(v: any)
						update(function(s: any): { [string]: any }
							if v == "auto" then
								return { textGrowth = "auto", width = "__null", height = "__null" }
							elseif v == "fixed_width" then
								return { textGrowth = "fixed_width", width = math.floor(s.box.w + 0.5), height = "__null" }
							end
							return { textGrowth = "fixed_width_height", width = math.floor(s.box.w + 0.5), height = math.floor(s.box.h + 0.5) }
						end, "Resizing")
					end,
				})
			)
			-- (In a flex layout, a text can fill its parent: the axis rows.)
			local any_laid = false
			for _, s in sel do
				if laid(s) then
					any_laid = true
				end
			end
			if any_laid then
				table.insert(body, size_row("width", "w", "W", false))
				table.insert(body, size_row("height", "h", "H", false))
			else
				table.insert(body, Kit.pair(axis("width", "w", "W"), axis("height", "h", "H")))
			end
		else
			table.insert(body, sub("Dimensions"))
			table.insert(body, size_row("width", "w", "W", frames))
			table.insert(body, size_row("height", "h", "H", frames))
		end
		-- The title: "Flex layout" with its mark in the accent (taking it
		-- off), or "Layout" (putting it on, vertical).
		local flex = frames and not lay_mixed and lay ~= "none"
		local layout_action: { Node }? = nil
		if frames then
			layout_action = {
				act("rows", if flex then "Remove flex layout" else "Add flex layout", function()
					update({ layout = if flex then "none" else "vertical" }, "Layout")
				end, if flex then L.accent else nil),
			}
		end
		add(sec(if flex then "Flex layout" else "Layout", layout_action, body))
	end

	-- Appearance ---------------------------------------------------------------------------
	do
		local has_radius = all(function(s)
			return s.node.type == "frame" or s.node.type == "rectangle" or s.node.type == "instance"
		end)
		local opacity = value_num({
			icon = "opacity",
			tip = "Opacity",
			key = "opacity",
			unit = "%",
			min = 0,
			max = 100,
			bind = true,
			-- (a bound opacity holds the variable's 0–1, shown as a %)
			show = function(x: number): number
				return x * 100
			end,
			bind_set = function(_s: any, ref: string): any
				return ref
			end,
			get = function(s: any): any
				local o = s.node.opacity
				if type(o) == "string" then
					return o
				end
				return math.floor(((o or 1) :: number) * 100 + 0.5)
			end,
			set = function(_s: any, v: number): any
				return if v >= 100 then "__null" else v / 100
			end,
		})
		local body: { Node } = {}
		if has_radius then
			local four = shared(function(s)
				return type(s.node.cornerRadius) == "table"
			end)
			local radius = value_num({
				icon = "radius",
				tip = "Corner radius",
				key = "cornerRadius",
				min = 0,
				bind = true,
				get = function(s: any): any
					local r = s.node.cornerRadius
					if type(r) == "table" then
						return if eq(r[1], r[2]) and eq(r[2], r[3]) and eq(r[3], r[4]) then r[1] else nil
					end
					return r or 0
				end,
				set = function(_s: any, v: number): any
					return if v == 0 then "__null" else v
				end,
			})
			local each = expanded:get().radius or four
			table.insert(
				body,
				ui.row {
					w_full = true,
					gap = 6,
					items = "center",
					ui.div { grow = 1, basis = 0, min_w = 0, opacity },
					ui.div { grow = 1, basis = 0, min_w = 0, radius },
					sq("corners", "Individual corners", function()
						expanded:set_key({ "radius" }, not expanded:peek().radius)
					end, { on = each == true }),
				}
			)
			if each then
				local corners = {}
				for i, lbl in { "↖", "↗", "↘", "↙" } do
					table.insert(
						corners,
						value_num({
							label = lbl,
							tip = "Corner " .. i,
							key = "cornerRadius",
							min = 0,
							bind = true,
							get = function(s: any): any
								local r = s.node.cornerRadius
								return if type(r) == "table" then r[i] else (r or 0)
							end,
							set = function(s: any, v: number): any
								local r = s.node.cornerRadius
								local r4 = if type(r) == "table" then table.clone(r) else { r or 0, r or 0, r or 0, r or 0 }
								r4[i] = v
								return if eq(r4[1], r4[2]) and eq(r4[2], r4[3]) and eq(r4[3], r4[4]) then (if r4[1] == 0 then "__null" else r4[1]) else r4
							end,
						})
					)
				end
				table.insert(body, Kit.pair(corners[1], corners[2]))
				table.insert(body, Kit.pair(corners[3], corners[4]))
			end
		else
			-- (The radius greyed where it doesn't apply.)
			table.insert(
				body,
				ui.row {
					w_full = true,
					gap = 6,
					items = "center",
					ui.div { grow = 1, basis = 0, min_w = 0, opacity },
					ui.div {
						grow = 1,
						basis = 0,
						min_w = 0,
						opacity = 0.5,
						Kit.field(L, { icon = "radius", tip = "Corner radius", read_only = true, value = function(): string?
							return "0"
						end, commit = function() end }),
					},
					ui.div { w = 28, shrink = 0, opacity = 0.5, sq("corners", "Individual corners", function() end) },
				}
			)
		end
		if all(function(s)
			return s.node.type == "frame" or s.node.type == "instance"
		end) then
			table.insert(
				body,
				check("Clip content", function(): boolean
					return (prop("clip")) == true
				end, function(on: boolean)
					update({ clip = if on then true else "__null" }, "Clip content")
				end)
			)
		end
		-- (step 5, V5b) Mode: a frame's own pick of each theme axis (Figma's
		-- "explicit mode", the node's `theme` key; its layers inherit it).
		-- Auto follows the page.
		local axes_list = (props.tokens and props.tokens.axes) or {}
		if #axes_list > 0 and all(function(s)
			return s.node.type == "frame" or s.node.type == "instance"
		end) then
			for _, a in axes_list do
				local axis = a.axis
				local cur, cur_mixed = shared(function(s)
					return if type(s.node.theme) == "table" then s.node.theme[axis] else nil
				end)
				local function put(v: string?)
					update(function(s: any): { [string]: any }
						local th = if type(s.node.theme) == "table" then table.clone(s.node.theme) else {}
						th[axis] = v
						return { theme = if next(th) == nil then "__null" else th }
					end, "Mode")
				end
				local items = { { label = "Auto (from the page)", checked = not cur_mixed and cur == nil, on_click = function()
					put(nil)
				end } }
				for _, v in a.values or {} do
					table.insert(items, { label = tostring(v), checked = cur == v, on_click = function()
						put(v)
					end })
				end
				table.insert(body, dropdown({
					id = `mode-{axis}`,
					label = `Mode: {axis}`,
					leading = lead_icon("moon"),
					value = function(): string
						return if cur_mixed then `{axis}: Mixed` elseif cur then `{axis}: {cur}` else `{axis}: Auto`
					end,
					items = items,
				}))
			end
		end
		local hidden = all(function(s)
			return s.node.enabled == false
		end)
		-- (step 5, V5b) visibility bound to a boolean variable (`enabled =
		-- "$flag"`): a chip over the rows, "Visible if flag", whose detach
		-- keeps what it shows now; Apply variable beside the eye
		local en, en_mixed = prop("enabled")
		local vis_name = if en_mixed then nil else Bind.ref(en)
		local function bind_vis(v: string)
			update({ enabled = "$" .. v }, "Apply variable")
		end
		if vis_name then
			local val = resolve(en)
			table.insert(body, 1, Bind.chip(L, {
				id = "bind-visible-chip",
				what = "Visibility",
				label = "Visible if",
				name = vis_name,
				kind = Bind.kind_of(bind_vars, vis_name),
				value = val,
				vars = bind_vars,
				kinds = { "boolean" },
				pick = bind_vis,
				detach = function()
					update({ enabled = if val == false then false else "__null" }, "Detach variable")
				end,
			}))
		end
		local head_acts: { Node } = {
			ui.div { my = -2, mr = -3, Bind.button(L, { id = "bind-visible", what = "visibility", kinds = { "boolean" }, vars = bind_vars, bound = vis_name, pick = bind_vis }) },
		}
		if not vis_name then
			table.insert(head_acts, act(if hidden then "eyeOff" else "eye", if hidden then "Show" else "Hide", function()
				update({ enabled = if hidden then "__null" else false }, if hidden then "Show" else "Hide")
			end))
		end
		add(sec("Appearance", head_acts, body))
	end

	-- A colour's field: its swatch (opening the picker beside the panel),
	-- the hex or the variable's name (in the accent, with its detach mark),
	-- the alpha as a % at its end.
	local function color_field(o: { id: string, title: string, paint: any, commit: (np: any, live: boolean) -> (), solid_only: boolean? }): Node
		local p = o.paint
		local rp = resolve(p)
		local label, swatch
		if type(rp) == "string" then
			swatch = rp
			label = if type(p) == "string" and string.sub(p, 1, 1) == "$" then string.sub(p, 2) else string.upper(string.sub(rp, 2, 7))
		elseif type(rp) == "table" and rp.type == "color" and type(resolve(rp.color)) == "string" then
			swatch = resolve(rp.color)
			label = string.upper(string.sub(swatch, 2, 7))
		elseif type(rp) == "table" and rp.type == "gradient" then
			local c1 = rp.colors and rp.colors[1] and resolve(rp.colors[1].color) or "#000000"
			swatch = c1
			label = string.upper(string.sub(rp.gradientType or "linear", 1, 1)) .. string.sub(rp.gradientType or "linear", 2) .. " gradient"
		elseif type(rp) == "table" and rp.type == "image" then
			swatch = "#a1a1aa"
			label = "Image"
		else
			swatch = CLEAR
			label = "Paint"
		end
		local c = Picker.parse(swatch)
		local alpha = if c then math.floor(c.a * 100 + 0.5) else 100
		local bound = type(p) == "string" and string.sub(p, 1, 1) == "$"
		local plain = type(rp) == "string"
		-- Which picker is open is held outside the panel (`picker_open`): an
		-- edit builds the whole panel again (a gradient's stop, the paint's
		-- kind), and the picker stays open across it, built from the new paint.
		local key = `{sel_key}|{o.id}`
		local open = ui.use_state(picker_open:peek() == key)
		ui.effect(function()
			local on = open:get()
			local held = picker_open:peek()
			if on and held ~= key then
				picker_open:set(key)
			elseif not on and held == key then
				picker_open:set("")
			end
		end)
		-- Beside the panel, lined up so all of it stays in the window (zgx
		-- doesn't clamp a side-placed panel along the side): from the row's
		-- top down when there's room below, from its bottom up when there's
		-- room above, else centred. Chosen as it opens, kept across rebuilds.
		local align = ui.use_state(picker_align[key] or "center")
		local anchor_ref = ui.ref()
		local function choose_align(): string
			local el = anchor_ref:peek()
			local ok, size = pcall(function(): any
				return ui.window.size:peek()
			end)
			local wh = if ok and type(size) == "table" then size.height else nil
			if not el or el.y == nil or not wh then
				return "center"
			end
			if el.y + PICKER_H <= wh - 8 then
				return "start"
			elseif el.y + (el.height or 16) - PICKER_H >= 8 then
				return "end"
			end
			return "center"
		end
		local function pop_for(a: string): Node
			return ui.popover {
				open = open,
				-- (kept off: a rebuild mid-edit would move focus to its first control)
				autofocus = false,
				label = o.title .. " paint",
				placement = { side = "left", align = a, offset = 18 },
				anchor = ui.div {
					id = o.id,
					ref = anchor_ref,
					shrink = 0,
					pl = 3,
					pr = 4,
					cursor = "pointer",
					Kit.swatch(L, function(): string
						return swatch
					end, function()
						local a2 = choose_align()
						picker_align[key] = a2
						align:set(a2)
						open:set(true)
					end),
				},
				-- The picker's own size (262, r12, p12) and its 1px rim: no
				-- padding or height of the host's.
				w = 264,
				p = 0,
				rounded = 12,
				bg = L.pop,
				border = 1,
				border_color = L.border,
				shadow = L.pop_shadow,
				build = function(): Node
					return Picker.Picker {
						L = L,
						paint = p,
						resolve = resolve,
						tokens = color_tokens,
						commit = function(np: any, live: boolean)
							if o.solid_only and type(np) ~= "string" then
								return
							end
							o.commit(np, live)
						end,
						eyedrop = props.eyedrop,
						close = function()
							open:set(false)
						end,
					}
				end,
			}
		end
		local pop = ui.presence(function(): string
			return align:get()
		end, pop_for, { shrink = 0 })
		local trailing: Node? = nil
		if bound then
			trailing = ui.button {
				label = "Detach variable",
				tooltip = `Detach {string.sub(p, 2)}`,
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
				on_click = function()
					if type(rp) == "string" then
						o.commit(rp, false)
					end
				end,
				Kit.icon("detach", 12),
			}
		elseif c and plain then
			trailing = ui.row {
				shrink = 0,
				pr = 8,
				items = "center",
				ui.input {
					label = o.title .. " opacity",
					value = function(): string
						return tostring(alpha)
					end,
					on_commit = function(t: string)
						local a = tonumber((string.gsub(t, "%%", "")))
						if a and c then
							c.a = math.clamp(a, 0, 100) / 100
							o.commit(Picker.hex(c), false)
						end
					end,
					select_on_focus = true,
					-- (as wide as its digits, so "100%" reads as one word)
					w = 7 * #tostring(alpha) + 1,
					h = 26,
					px = 0,
					py = 0,
					bg = CLEAR,
					border = 0,
					rounded = 0,
					focus = { outline = 0 },
					color = L.muted,
					text_size = 12,
					font = Look.UI,
				},
				Kit.text(L, "%", { color = L.muted }),
			}
		end
		return Kit.field(L, {
			tip = o.title .. " colour",
			leading = ui.div { shrink = 0, h = 16, items = "center", pop },
			value = function(): string?
				return label
			end,
			fg = if bound then L.accent_fg else nil,
			-- (step 5, V5b) a bound colour reads as the other bound chips
			bg = if bound then L.accent_soft else nil,
			mono = false,
			read_only = not plain,
			trailing = trailing,
			commit = function(t: string)
				local h = Picker.parse("#" .. string.gsub(t, "#", ""))
				if h then
					h.a = if c then c.a else 1
					o.commit(Picker.hex(h), false)
				elseif string.sub(t, 1, 1) == "$" then
					o.commit(t, false)
				end
			end,
		})
	end

	-- Paints: Fill and Stroke ------------------------------------------------------------------
	local function paint_rows(title: string, key: string, get: (s: any) -> any, put: (s: any, v: any) -> { [string]: any }): ({ Node }, boolean)
		local list, mixed = shared(function(s)
			return paints_of(get(s))
		end)
		local rows: { Node } = {}
		if not mixed and list then
			for i, p in list do
				local function set_paint(np: any, live: boolean)
					update(function(s: any): { [string]: any }
						local l = table.clone(paints_of(get(s)))
						l[i] = np
						return put(s, pack_paints(l))
					end, "Change " .. string.lower(title), live)
				end
				local enabled = not (type(p) == "table" and p.enabled == false)
				table.insert(
					rows,
					ui.row {
						w_full = true,
						h = 28,
						items = "center",
						gap = 6,
						ui.div {
							grow = 1,
							min_w = 0,
							opacity = if enabled then 1 else 0.5,
							color_field({ id = `paint-{key}-{i}`, title = title, paint = p, commit = set_paint }),
						},
						-- (step 5, V5b) Apply variable: the colour variables
						Bind.button(L, {
							id = `bind-{key}-{i}`,
							what = string.lower(title),
							kinds = { "color" },
							vars = bind_vars,
							bound = Bind.ref(p),
							pick = function(name: string)
								set_paint("$" .. name, false)
							end,
						}),
						mini(if enabled then "eye" else "eyeOff", if enabled then "Hide paint" else "Show paint", function()
							local np: any = p
							if type(np) == "string" then
								np = { type = "color", color = np, enabled = false }
							else
								np = table.clone(np)
								np.enabled = if np.enabled == false then nil else false
							end
							set_paint(np, false)
						end),
						mini("minus", "Remove " .. string.lower(title), function()
							update(function(s: any): { [string]: any }
								local l = table.clone(paints_of(get(s)))
								table.remove(l, i)
								return put(s, pack_paints(l))
							end, "Remove " .. string.lower(title))
						end),
					}
				)
			end
		elseif mixed then
			table.insert(rows, Kit.text(L, "Mixed " .. string.lower(title) .. "s", { color = L.faint }))
		end
		return rows, mixed
	end
	local function add_paint(title: string, get: (s: any) -> any, put: (s: any, v: any) -> { [string]: any }, default: any): Node
		return act("plus", "Add " .. string.lower(title), function()
			update(function(s: any): { [string]: any }
				local l = table.clone(paints_of(get(s)))
				table.insert(l, default)
				return put(s, pack_paints(l))
			end, "Add " .. string.lower(title))
		end)
	end

	do
		local get = function(s: any): any
			return s.node.fill
		end
		local put = function(_s: any, v: any): { [string]: any }
			return { fill = v }
		end
		local rows = paint_rows("Fill", "fill", get, put)
		add(sec("Fill", {
			add_paint("Fill", get, put, if all(function(s)
				return s.node.type == "text"
			end) then "#000000" else "#D9D9D9"),
		}, rows))
	end

	-- Stroke: its paint, then weight and where it sits. (None for text.)
	if not all(function(s)
		return s.node.type == "text"
	end) then
		local st, mixed = prop("stroke")
		local get = function(s: any): any
			return if type(s.node.stroke) == "table" then s.node.stroke.fill else nil
		end
		local put = function(s: any, v: any): { [string]: any }
			if v == "__null" then
				return { stroke = "__null" }
			end
			local old = if type(s.node.stroke) == "table" then table.clone(s.node.stroke) else { thickness = 1, align = "inside" }
			old.fill = v
			return { stroke = old }
		end
		local rows = paint_rows("Stroke", "stroke", get, put)
		if not mixed and type(st) == "table" and st.fill ~= nil then
			table.insert(
				rows,
				ui.row {
					w_full = true,
					gap = 6,
					ui.div {
						w = 80,
						shrink = 0,
						value_num({
							icon = "minus",
							tip = "Stroke weight",
							key = "stroke",
							min = 0,
							get = function(s: any): any
								local t = s.node.stroke and s.node.stroke.thickness
								return if type(t) == "table" then (t.top or 0) else (t or 1)
							end,
							set = function(s: any, v: number): any
								local o = table.clone(s.node.stroke)
								o.thickness = v
								return o
							end,
						}),
					},
					ui.div {
						grow = 1,
						min_w = 0,
						seg({
							id = "stroke-align",
							value = function(): any
								return st.align or "inside"
							end,
							options = { { value = "inside", label = "In", tip = "Inside" }, { value = "center", label = "Mid", tip = "Centre" }, { value = "outside", label = "Out", tip = "Outside" } },
							commit = function(v: any)
								update(function(s: any): { [string]: any }
									local o = table.clone(s.node.stroke)
									o.align = v
									return { stroke = o }
								end, "Stroke position")
							end,
						}),
					},
				}
			)
		end
		add(sec("Stroke", { add_paint("Stroke", get, put, "#000000") }, rows))
	end

	-- Typography -------------------------------------------------------------------------------
	if all(function(s)
		return s.node.type == "text"
	end) then
		local fam, fam_mixed = prop("fontFamily")
		local weight, w_mixed = prop("fontWeight")
		local talign = prop("textAlign")
		local fam_bound = type(fam) == "string" and string.sub(fam, 1, 1) == "$"
		local w_bound = type(weight) == "string" and string.sub(weight, 1, 1) == "$"
		local function mark(bound: boolean): Node
			return if bound then ui.div { shrink = 0, color = L.accent_fg, Kit.icon("instance", 12) } else ui.div {}
		end
		local NAMES = { [100] = "Thin", [200] = "Extra Light", [300] = "Light", [400] = "Regular", [500] = "Medium", [600] = "Semi Bold", [700] = "Bold", [800] = "Extra Bold", [900] = "Black" }
		local wv = n(resolve(weight)) or 400
		local weights = {}
		for _, k in { 100, 200, 300, 400, 500, 600, 700, 800, 900 } do
			table.insert(weights, {
				label = NAMES[k],
				checked = not w_mixed and wv == k,
				on_click = function()
					update({ fontWeight = k }, "Weight")
				end,
			})
		end
		-- (step 5, V5b) the text itself: bound to a text or number variable
		-- (`content = "$name"`) it's a chip, whose detach keeps the words it
		-- shows; else a field, with Apply variable on hover
		local content, c_mixed = prop("content")
		local c_name = if c_mixed then nil else Bind.ref(content)
		local function bind_text(v: string)
			update({ content = "$" .. v }, "Apply variable")
		end
		local content_row: Node
		if c_name then
			local kind = Bind.kind_of(bind_vars, c_name)
			local val = resolve(content)
			content_row = Bind.chip(L, {
				id = "bind-text-chip",
				what = "Text",
				name = c_name,
				kind = kind,
				value = val,
				vars = bind_vars,
				kinds = { "string", "number" },
				pick = bind_text,
				detach = function()
					update({ content = Bind.literal(kind, if val == content then "" else val, "text") }, "Detach variable")
				end,
			})
		else
			content_row = with_bind("bind-text", "text", { "string", "number" }, bind_text, function(trailing: Node): Node
				return Kit.field(L, {
					id = "text-content",
					tip = "Text",
					mono = false,
					leading = lead_icon("pencil"),
					value = function(): string?
						if c_mixed then
							return nil
						end
						return if type(content) == "string" then content else ""
					end,
					commit = function(t: string)
						if t ~= content then
							update({ content = t }, "Text")
						end
					end,
					trailing = trailing,
				})
			end)
		end
		local body: { Node } = {
			content_row,
			Kit.field(L, {
				id = "font-family",
				tip = if fam_bound then `Font ({string.sub(fam, 2)})` else "Font",
				mono = false,
				leading = lead_icon("text"),
				fg = if fam_bound then L.accent_fg else nil,
				value = function(): string?
					if fam_mixed then
						return nil
					end
					local f = resolve(fam or "Geist")
					return if type(f) == "string" then f else "Geist"
				end,
				commit = function(t: string)
					update({ fontFamily = t }, "Font")
				end,
				trailing = ui.row { h = 28, pr = 8, gap = 4, shrink = 0, items = "center", mark(fam_bound), ui.div { color = L.faint, Kit.icon("chevDown", 13) } },
			}),
			ui.row {
				w_full = true,
				gap = 6,
				ui.div {
					grow = 1,
					min_w = 0,
					dropdown({
						id = "font-weight",
						label = "Weight",
						value = function(): string
							if w_mixed then
								return "Mixed"
							end
							return NAMES[wv] or tostring(wv)
						end,
						items = weights,
						extra = mark(w_bound),
						menu_w = 160,
					}),
				},
				ui.div { w = 80, shrink = 0, value_num({ tip = "Size", icon = "text", key = "fontSize", min = 1 }) },
			},
			ui.row { w_full = true, gap = 6, ui.div { grow = 1, basis = 0, sub("Line height") }, ui.div { grow = 1, basis = 0, sub("Letter spacing") } },
			Kit.pair(
				value_num({
					icon = "rows",
					tip = "Line height",
					key = "lineHeight",
					unit = "%",
					empty = "Auto",
					show = function(x: number): number
						return x * 100
					end,
					get = function(s: any): any
						local v = s.node.lineHeight
						if type(v) == "string" then
							return v
						end
						return if v then math.floor(v * 100 + 0.5) else nil
					end,
					set = function(_s: any, v: number): any
						return if v <= 0 then "__null" else v / 100
					end,
				}),
				value_num({ icon = "cols", tip = "Letter spacing", key = "letterSpacing" })
			),
			seg({
				id = "text-align",
				value = function(): any
					return talign or "left"
				end,
				options = { { value = "left", icon = "alignL", tip = "Align left" }, { value = "center", icon = "alignHC", tip = "Align centre" }, { value = "right", icon = "alignR", tip = "Align right" } },
				commit = function(v: any)
					update({ textAlign = if v == "left" then "__null" else v }, "Text align")
				end,
			}),
		}
		add(sec("Typography", nil, body))
	end

	-- Effects: shadows and blurs ------------------------------------------------------------
	do
		local list, mixed = shared(function(s)
			return paints_of(s.node.effect)
		end)
		local rows: { Node } = {}
		local function put_list(l: { any }): any
			return if #l == 0 then "__null" elseif #l == 1 then l[1] else l
		end
		if not mixed and list then
			for i, e in list do
				local function set_effect(make: (ne: any) -> any, label: string)
					update(function(s: any): { [string]: any }
						local l = table.clone(paints_of(s.node.effect))
						l[i] = make(table.clone(l[i]))
						return { effect = put_list(l) }
					end, label)
				end
				local function set_fx(k: string, v: any)
					set_effect(function(ne: any): any
						if k == "x" or k == "y" then
							ne.offset = table.clone(ne.offset or {})
							ne.offset[k] = v
						else
							ne[k] = v
						end
						return ne
					end, "Change effect")
				end
				local kind = if e.type == "shadow" then (if e.shadowType == "inner" then "inner" else "drop") elseif e.type == "blur" then "layer" else "background"
				local NAMES = { drop = "Drop shadow", inner = "Inner shadow", layer = "Layer blur", background = "Background blur" }
				local enabled = e.enabled ~= false
				local items = {}
				for _, k in { "drop", "inner", "layer", "background" } do
					table.insert(items, {
						label = NAMES[k],
						checked = k == kind,
						on_click = function()
							if k == kind then
								return
							end
							set_effect(function(old: any): any
								local ne: any
								if k == "drop" or k == "inner" then
									ne = {
										type = "shadow",
										shadowType = if k == "inner" then "inner" else "outer",
										offset = old.offset or { x = 0, y = 4 },
										blur = old.blur or old.radius or 12,
										spread = old.spread or 0,
										color = old.color or "#00000026",
									}
								else
									ne = { type = if k == "layer" then "blur" else "background_blur", radius = old.radius or old.blur or 8 }
								end
								ne.enabled = old.enabled
								return ne
							end, "Effect type")
						end,
					})
				end
				local block: any = {
					w_full = true,
					gap = 8,
					ui.row {
						w_full = true,
						h = 28,
						items = "center",
						gap = 6,
						ui.div {
							grow = 1,
							min_w = 0,
							opacity = if enabled then 1 else 0.5,
							dropdown({ id = `effect-type-{i}`, label = "Effect type", value = function(): string
								return NAMES[kind]
							end, items = items }),
						},
						mini(if enabled then "eye" else "eyeOff", if enabled then "Hide effect" else "Show effect", function()
							set_effect(function(ne: any): any
								ne.enabled = if enabled then false else nil
								return ne
							end, if enabled then "Hide effect" else "Show effect")
						end),
						mini("minus", "Remove effect", function()
							update(function(s: any): { [string]: any }
								local l = table.clone(paints_of(s.node.effect))
								table.remove(l, i)
								return { effect = put_list(l) }
							end, "Remove effect")
						end),
					},
				}
				if e.type == "shadow" then
					local function f(lbl: string, tip: string, get: () -> number, k: string, min: number?): Node
						return ui.div {
							grow = 1,
							basis = 0,
							min_w = 0,
							Kit.num(L, { label = lbl, tip = tip, min = min, get = get, set = function(v: number)
								set_fx(k, v)
							end }),
						}
					end
					table.insert(
						block,
						ui.row {
							w_full = true,
							gap = 6,
							f("X", "Shadow X", function(): number
								return n(e.offset and e.offset.x) or 0
							end, "x"),
							f("Y", "Shadow Y", function(): number
								return n(e.offset and e.offset.y) or 0
							end, "y"),
							f("B", "Blur", function(): number
								return n(e.blur) or 0
							end, "blur", 0),
							f("S", "Spread", function(): number
								return n(e.spread) or 0
							end, "spread"),
						}
					)
					table.insert(
						block,
						color_field({
							id = `effect-color-{i}`,
							title = "Shadow",
							paint = e.color or "#00000040",
							solid_only = true,
							commit = function(np: any, _live: boolean)
								set_fx("color", np)
							end,
						})
					)
				else
					table.insert(
						block,
						Kit.pair(Kit.num(L, { label = "B", tip = "Blur radius", min = 0, get = function(): number?
							return n(e.radius) or 0
						end, set = function(v: number)
							set_fx("radius", v)
						end }))
					)
				end
				table.insert(rows, ui.column(block))
			end
		elseif mixed then
			table.insert(rows, Kit.text(L, "Mixed effects", { color = L.faint }))
		end
		add(sec("Effects", {
			act("plus", "Add effect", function()
				update(function(s: any): { [string]: any }
					local l = table.clone(paints_of(s.node.effect))
					table.insert(l, { type = "shadow", shadowType = "outer", offset = { x = 0, y = 4 }, blur = 12, spread = 0, color = "#00000026" })
					return { effect = put_list(l) }
				end, "Add effect")
			end),
		}, rows))
	end

	-- Code and Export are built a frame later, in a call of their own: the
	-- panel was one call (20 to 58 ms in a debug build), and these two are
	-- its largest parts after Layout. They show a frame after the rest.
	local function late(add: (node: Node?) -> ())
		-- Code: the selection as HTML (Tailwind or CSS classes), from the
		-- service's `code`; copy it, or export a whole page to a file.
		do
			local css = ui.use_state("tailwind")
			local code = ui.use_state(nil :: string?)
			local ids = {}
			for _, s in sel do
				table.insert(ids, s.id)
			end
			local function load(c: string)
				code:set(nil)
				if source.code then
					source.code({ ids = ids, css = c }, function(r: any)
						code:set(if type(r) == "table" then r.code else tostring(r))
					end)
				end
			end
			load(css:peek())
			local fmt_menu = dropdown({
				id = "code-format",
				label = "Code format",
				value = function(): string
					return if css:get() == "tailwind" then "HTML + Tailwind" else "HTML + CSS"
				end,
				items = {
					{
						label = "HTML + Tailwind",
						checked = css:peek() == "tailwind",
						on_click = function()
							css:set("tailwind")
							load("tailwind")
						end,
					},
					{
						label = "HTML + CSS",
						checked = css:peek() == "css",
						on_click = function()
							css:set("css")
							load("css")
						end,
					},
				},
			})
			local copied = ui.use_state(false)
			add(sec("Code", nil, {
				fmt_menu,
				ui.row {
					w_full = true,
					gap = 6,
					wide_btn("code-copy", function(): string
						return if copied:get() then "Copied" else "Copy HTML"
					end, "copy", function()
						local c = code:peek()
						-- Guarded: without the clipboard grant, write throws and would kill the tab.
						if c and pcall(ui.clipboard.write, c) then
							copied:set(true)
							ui.after(1400, function()
								copied:set(false)
							end)
						end
					end),
					wide_btn("code-export", "Export HTML", "download", function()
						if not source.code then
							return
						end
						source.code({ ids = ids, css = css:peek(), scaffold = true }, function(r: any)
							local page = if type(r) == "table" then r.code else nil
							if not page then
								return
							end
							ui.save_file({ title = "Export HTML", name = ((sel[1].node.name or "design") .. ".html") } :: any):after(function(file: any)
								if file then
									ui.write_file(file, page)
								end
							end, function() end)
						end)
					end),
				},
			}))
		end

		-- Export, as pen.dev's: a scale (1x/2x/3x), a format, "Export layer" for
		-- the selection. One layer: the Save dialog, its file. Several: one
		-- .zip (pen's export.zip), each layer drawn and added in turn so the
		-- window never holds more than one picture (its memory is capped).
		-- HTML is the Code section's, as in pen.
		if props.render_png then
			local scale = ui.use_state(1)
			local format = ui.use_state("PNG")
			local function drop(id: string, value: () -> string, options: { string }, pick: (v: string) -> ()): Node
				local items = {}
				local now = value()
				for _, o2 in options do
					table.insert(items, {
						label = o2,
						checked = o2 == now,
						on_click = function()
							pick(o2)
						end,
					})
				end
				return dropdown({ id = id, label = id, value = value, items = items, menu_w = 120 })
			end
			local status = ui.use_state("")
			-- What's said after an export, scrolled into view as it shows (the
			-- section ends the panel: a line below the fold is never seen).
			local status_ref = ui.ref()
			local function say(msg: string)
				status:set(msg)
				if msg ~= "" then
					ui.after(0, function()
						local el = status_ref:peek()
						if el then
							el:focus()
						end
					end)
				end
			end
			-- A file name from a layer's name (no path characters).
			local function file_name(n: string?): string
				local base = string.gsub(n or "layer", "[\\/:%*%?\"<>|]", "_")
				base = string.gsub(base, "^%s+", "")
				return if base == "" then "layer" else base
			end
			-- What the running zgx can make, checked once a window (a 1×1
			-- picture asked for as JPEG and WEBP, its bytes looked at: an
			-- older zgx draws a PNG whatever it's asked).
			local caps = export_caps()
			local function formats(): { string }
				local c = caps:get()
				local list = { "PNG" }
				if c.jpeg then
					table.insert(list, "JPEG")
				end
				if c.webp then
					table.insert(list, "WEBP")
				end
				if c.jpeg then
					table.insert(list, "PDF")
				end
				return list
			end
			local function filters(ext: string): any
				return { { string.upper(ext), { ext } } }
			end
			-- Each layer drawn and written in turn: one picture held at a time
			-- (the window's memory is capped).
			local function export_now()
				local ids, names = {}, {}
				for _, s2 in sel do
					table.insert(ids, s2.id)
					table.insert(names, file_name(s2.node.name))
				end
				status:set("")
				local fmt = string.lower(format:peek())
				local ext = if fmt == "jpeg" then "jpg" else fmt
				local sc = scale:peek()
				-- zgx draws a picture of at most 32 MiB (4 bytes a pixel, about
				-- 8.4 million pixels): a layer too big at the scale asked for
				-- goes at the largest scale that fits, and the status says so.
				-- (Full size needs zgx to draw straight to the file.)
				local function fit(id: string): number
					if not props.render_layer then
						return sc
					end
					local ok2, size = props.render_layer(id, sc, { measure = true })
					if ok2 ~= true or type(size) ~= "table" then
						return sc
					end
					return fit_scale(size.w, size.h, sc)
				end
				local fell: { string } = {}
				local function draw(id: string, as: string?, k: number): (string, any, number)
					if not props.render_layer then
						error("no canvas to draw it")
					end
					local s = fit(id)
					if s < sc then
						table.insert(fell, `{names[k]} at {fmt_scale(s)}`)
					end
					local promise, size = props.render_layer(id, s, if as then { format = as, quality = 90 } else nil)
					if not promise then
						error(tostring(size))
					end
					return promise:await(), size, s
				end
				-- zgx makes the pixels and writes them itself, at full size
				-- with none through the window (`z:add_canvas`,
				-- `ui.render_canvas { file, append }`), when the Canvas gives
				-- a layer's drawing (`measure` + `draw`: `{ w, h, x, y,
				-- draw }`). Nil otherwise: the picture comes back as above.
				local function drawing(id: string): any
					if not props.render_layer then
						return nil
					end
					local ok2, measured, d = pcall(props.render_layer, id, sc, { measure = true, draw = true })
					if ok2 and measured == true and type(d) == "table" and type(d.draw) == "function" then
						return d
					end
					return nil
				end
				local function made_opts(d: any, as: string?): any
					local o: any = { width = d.w, height = d.h, scale = sc, x = d.x or 0, y = d.y or 0 }
					if as then
						o.format = as
						o.quality = 90
					end
					return o
				end
				-- A zgx that appends a picture to a file refuses `append`
				-- with no `file`; an older one ignores it (and would write
				-- over the PDF), so it's asked first.
				local function appends(): boolean
					local ok2, why = pcall(ui.render_canvas, function(_: Canvas) end, { width = 1, height = 1, append = true } :: any)
					return not ok2 and string.find(tostring(why), "append", 1, true) ~= nil
				end
				local function fell_note(): string
					if #fell == 0 then
						return ""
					end
					local too = if #ids == 1 then `Too big for {fmt_scale(sc)}: exported at {fmt_scale(fit(ids[1]))}` else `Too big for {fmt_scale(sc)}: {table.concat(fell, ", ")}`
					return `{too} (one picture holds at most 8.4 million pixels).`
				end
				local ok, why = pcall(function()
					if fmt == "pdf" then
						-- One page a layer, in selection order (pen's PDF).
						local file = ui.save_file({ title = "Export layers", name = `{if #ids == 1 then names[1] else "export"}.pdf`, filters = filters("pdf") } :: any):await()
						if not file then
							return
						end
						local pdf = Pdf.new(function(data: any, first: boolean): any
							return ui.write_file(file, data, if first then nil else { append = true } :: any)
						end)
						local direct = appends()
						for k, id in ids do
							status:set(`Exporting {k} of {#ids}…`)
							local d = if direct then drawing(id) else nil
							if d then
								local o = made_opts(d, "jpeg")
								o.file = file
								o.append = true
								pdf:page_appended(function(): any
									return ui.render_canvas(d.draw, o):await()
								end, Pdf.pixels(d.w, sc), Pdf.pixels(d.h, sc), d.w, d.h)
							else
								local jpg, size, s = draw(id, "jpeg", k)
								pdf:page(jpg, math.ceil(size.w * s), math.ceil(size.h * s), size.w, size.h)
							end
						end
						pdf:finish()
					elseif #ids == 1 then
						local file = ui.save_file({ title = "Export layer", name = `{names[1]}.{ext}`, filters = filters(ext) } :: any):await()
						if not file then
							return
						end
						status:set("Exporting…")
						-- Straight to the file at the scale asked for (zgx#2118:
						-- drawn and written in Rust, up to 256 MiB of pixels). An
						-- older zgx gives the picture back (written here) or
						-- refuses it as too big: then the fitted scale, said.
						local as = if fmt == "png" then nil else fmt
						local direct, got = false, nil
						if props.render_layer then
							local opts: any = { file = file }
							if as then
								opts.format = as
								opts.quality = 90
							end
							local promise = props.render_layer(ids[1], sc, opts)
							if promise then
								direct, got = pcall(function()
									return promise:await()
								end)
							end
						end
						if direct and got == nil then
							return
						elseif direct and type(got) == "string" then
							ui.write_file(file, { base64 = got }):await()
						else
							local b64 = draw(ids[1], as, 1)
							ui.write_file(file, { base64 = b64 }):await()
						end
					else
						if not ui.zip then
							say(SEVERAL)
							return
						end
						local file = ui.save_file({ title = "Export layers", name = "export.zip", filters = filters("zip") } :: any):await()
						if not file then
							return
						end
						local z: any = ui.zip(file)
						-- (zgx draws each entry on the zip's thread: `add_canvas`)
						local got_add, add_canvas = pcall(function(): any
							return z.add_canvas
						end)
						local direct = got_add and type(add_canvas) == "function"
						-- (two layers of one name: "Card", "Card-2"; a zip
						-- refuses a name twice)
						local taken: { [string]: number } = {}
						for k, id in ids do
							status:set(`Exporting {k} of {#ids}…`)
							local nm = names[k]
							taken[nm] = (taken[nm] or 0) + 1
							if taken[nm] > 1 then
								nm = `{nm}-{taken[nm]}`
							end
							local as = if fmt == "png" then nil else fmt
							local d = if direct then drawing(id) else nil
							if d then
								z:add_canvas(`{nm}.{ext}`, d.draw, made_opts(d, as)):await()
							else
								z:add(`{nm}.{ext}`, { base64 = (draw(id, as, k)) })
							end
						end
						z:close():await()
					end
				end)
				if ok then
					if status:peek() ~= SEVERAL then
						say(fell_note())
					end
				else
					local msg = if type(why) == "table" and why.message then why.message else tostring(why)
					say(`Couldn't export: {msg}`)
				end
			end
			local function export()
				ui.task(export_now)
			end
			add(sec("Export", nil, {
				ui.row {
					w_full = true,
					gap = 6,
					ui.div {
						grow = 1,
						basis = 0,
						drop("export-scale", function(): string
							return `{scale:get()}x`
						end, { "1x", "2x", "3x" }, function(v: string)
							scale:set(tonumber((string.gsub(v, "x", ""))) or 1)
						end),
					},
					ui.presence(function(): string
						return table.concat(formats(), ",")
					end, function(_: string): Node
						return drop("export-format", function(): string
							return format:get()
						end, formats(), function(v: string)
							format:set(v)
						end)
					end, { grow = 1, basis = 0 }),
				},
				wide_btn("export-layer", if #sel == 1 then "Export layer" else `Export {#sel} layers`, "image", export, true),
				-- What happened, right under the button where the eye is: a
				-- box of its own, the panel's text size, red for a failure.
				ui.show(function(): boolean
					return status:get() ~= ""
				end, ui.div {
					id = "export-status",
					role = "status",
					ref = status_ref,
					focusable = true,
					focus = { outline = 0 },
					w_full = true,
					px = 10,
					py = 8,
					rounded = 8,
					bg = L.field,
					border = 1,
					border_color = function(): string
						return if string.sub(status:get(), 1, 8) == "Couldn't" then L.danger else L.field
					end,
					ui.text {
						status,
						text_size = 12,
						color = function(): string
							return if string.sub(status:get(), 1, 8) == "Couldn't" then L.danger else L.fg
						end,
						font = Look.UI,
						wrap = true,
					},
				}),
			}))
		end
	end
	local late_ready = ui.use_state(false)
	ui.after(0, function()
		late_ready:set(true)
	end)
	add(ui.presence(function(): string
		return if late_ready:get() then "on" else "off"
	end, function(which: string): Node
		if which ~= "on" then
			return ui.div {}
		end
		local col: any = { w_full = true }
		late(function(node: Node?)
			if node then
				table.insert(col, node)
			end
		end)
		return ui.column(col)
	end, { w_full = true }))

	local col: any = { w_full = true, pb = 12 }
	for _, s in sections do
		table.insert(col, s)
	end
	return ui.column(col)
end

return M
