--!strict
local ui = require("./pointer").ui
-- The properties island's Prototype tab (proto-step1-spec §6, Figma's):
--
-- - a layer selected: its Interactions (On click → Navigate to [Screen],
--   the transition, its direction, duration and ease; Back; Open link) and
--   its States (Hover, Pressed: fill, stroke, opacity, scale, radius, and
--   layers inside it; the transition between looks). An Instance's inherited
--   ones show greyed, "from Component"; editing one makes an override, Reset
--   drops it.
-- - nothing selected: the Design's Flows (name, starting Screen; the first
--   plays by default) and "Show all links on canvas".
--
-- Every change is one `edit` op: `update { id, props = { interactions | states } }`
-- with the shapes as stored, or `flows { flows }`, so undo works as for any edit.

local Kit = require("./kit")
local Look = require("./look")
local Picker = require("./picker")
local Proto = require("./proto")
local Curve = require("./curve")
local Scroll = require("./scroll")
local PV = require("./proto_vars")
local Bind = require("./bind")
local DeviceFrame = require("./device_frame")
local Match = require("./proto_match")
local Toast = require("./toast")
local IaClip = require("./ia_clip")

local M = {}
local CLEAR = "#00000000"
local MIXED = Match.MIXED

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

export type PanelProps = {
	L: any,
	source: any,
	infos: { any },
	tokens: any?,
	show_all: any, -- State<boolean>
	select: ((ids: { string }) -> ())?,
	on_toggle: (() -> ())?,
	eyedrop: any?,
}

local panel: (props: PanelProps) -> Node

-- (step 6) The panel is rebuilt on a flows or prototype edit: the shell
-- remounts it only when the selection or tab changes, and neither edit
-- changes those (each edit stores a new table, so its address is the key).
function M.Panel(props: PanelProps): Node
	local source = props.source
	return ui.presence(function(): string
		local f = if source.flows then source.flows:get() else nil
		local p = if source.prototype then source.prototype:get() else nil
		return tostring(f) .. "|" .. tostring(p)
	end, function(_: string): Node
		return ui.component(function(): Node
			return panel(props)
		end)({})
	end, { w_full = true })
end

function panel(props: PanelProps): Node
	local L = props.L
	local source = props.source
	local sel = deep(props.infos)

	-- Parts in the Design tab's metrics (props.luau's) ---------------------------------
	local function sec(title: string, actions: { Node }?, body: { Node }?, o: { id: string?, note: string? }?): Node
		local oo = o or {}
		local has = body ~= nil and #body > 0
		local head: any = {
			id = oo.id,
			w_full = true,
			h = 16,
			gap = 6,
			items = "center",
			Kit.text(L, title, { weight = 500, color = if has then L.fg else L.muted }),
		}
		if oo.note then
			table.insert(head, Kit.text(L, oo.note, { color = L.faint, truncate = true }))
		end
		table.insert(head, ui.div { grow = 1 })
		for _, a in actions or {} do
			table.insert(head, a)
		end
		local col: any = { w_full = true, p = 12, gap = 8, border_sides = { 1, 0, 0, 0 }, border_color = L.border, ui.row(head) }
		for _, b in body or {} do
			table.insert(col, b)
		end
		return ui.column(col)
	end
	local function act(icon: string, label: string, fn: () -> (), id: string?, color: string?): Node
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
	-- (step 6) an item `{ head = "Phones" }` is a group heading; `max_h` scrolls a long list.
	local function dropdown(o: { id: string, label: string, value: () -> string, items: { any }, leading: Node?, fg: string?, menu_w: number?, max_h: number? }): Node
		local open = ui.use_state(false)
		local anchor: any = {
			id = o.id,
			label = o.label,
			w_full = true,
			min_w = 0,
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
		table.insert(anchor, ui.text { o.value, text_size = 12, color = o.fg or L.fg, font = Look.UI, grow = 1, truncate = true, min_w = 0 })
		table.insert(anchor, ui.div { shrink = 0, color = L.faint, Kit.icon("chevDown", 13) })
		local mp: any = { open = open, label = o.label, anchor = ui.button(anchor) }
		local list: any = mp
		if o.max_h then
			list = { w_full = true, max_h = o.max_h, overflow_y = "auto" }
		end
		for _, it in o.items do
			if it.head then
				table.insert(list, Kit.menu_head(L, it.head))
			elseif it.icon or it.note then
				-- (step 5) a row with a type icon and a grey note (a variable's type)
				table.insert(list, ui.menu_item {
					label = it.label,
					on_click = it.on_click,
					checked = it.checked,
					h = 28,
					px = 8,
					rounded = 6,
					hover = { bg = L.pop_hl },
					ui.row {
						w_full = true,
						h = 28,
						gap = 8,
						items = "center",
						if it.icon then ui.div { shrink = 0, color = L.faint, Kit.icon(it.icon, 13) } else ui.div {},
						ui.text { it.label, text_size = 12, color = if it.danger then L.danger else L.fg_strong, font = Look.UI, grow = 1, truncate = true, min_w = 0 },
						if it.note then ui.text { it.note, text_size = 12, color = L.faint, font = Look.UI } else ui.div {},
					},
				})
			else
				table.insert(list, Kit.menu_item(L, { label = it.label, checked = it.checked, on_click = it.on_click, danger = it.danger }))
			end
		end
		if o.max_h then
			table.insert(mp, ui.column(list))
		end
		for k2, v2 in Kit.pop_style(L) do
			mp[k2] = v2
		end
		mp.w = o.menu_w or 220
		return ui.menu(mp)
	end
	local function lead_icon(icon: string, color: string?): Node
		return ui.div { w = 24, min_w = 24, shrink = 0, h_full = true, pl = 2, items = "center", justify = "center", color = color or L.faint, Kit.icon(icon, 13) }
	end
	local function dim(n: Node, on: boolean): Node
		return if on then ui.div { w_full = true, opacity = 0.6, n } else n
	end
	-- (F6 C2) a faint line that wraps (what multi-select can't edit, and why)
	local function note(s: string, nid: string?): Node
		return ui.div { id = nid, w_full = true, ui.text { s, text_size = 11, color = L.faint, font = Look.UI, wrap = true, grow = 1, min_w = 0 } }
	end
	-- (step 6) a flow's description: plain text, several lines, saved on blur
	-- (an unchanged one sends nothing). Play shows `- ` / `1. ` lines as lists.
	local function desc_box(bid: string, value: any, commit: (t: string) -> ()): Node
		local was = if type(value) == "string" then value else ""
		return ui.textarea {
			id = bid,
			label = "Flow description",
			w_full = true,
			h = 56,
			value = function(): string
				return was
			end,
			placeholder = "Description",
			placeholder_color = L.faint,
			on_commit = function(t: string)
				t = string.gsub(string.gsub(t, "^%s+", ""), "%s+$", "")
				local n = utf8.len(t)
				if n and n > 2000 then -- (engine/proto.luau check_flows' limit)
					t = string.sub(t, 1, (utf8.offset(t, 2001) or (#t + 1)) - 1)
				end
				if t ~= was then
					commit(t)
				end
			end,
			wrap = true,
			px = 10,
			py = 7,
			rounded = 8,
			border = 0,
			bg = L.field,
			focus = { outline = 1, outline_color = L.accent, bg = L.field_active },
			text_size = 12,
			font = Look.UI,
			color = L.fg,
		}
	end

	-- The Design's Screens (top-level frames that aren't Components).
	local screens: { { id: string, name: string } } = {}
	local screen_name: { [string]: string } = {}
	for _, r in source.roots:peek() do
		local it = r.nodes and r.nodes[1]
		if it and it.t == "frame" and not it.comp then
			table.insert(screens, { id = r.id, name = it.name or r.id })
			screen_name[r.id] = it.name or r.id
		end
	end
	-- A node's subtree's named layers (for a state's "layer inside").
	local function inside(id: string): { { id: string, name: string } }
		for _, r in source.roots:peek() do
			for i, it in r.nodes or {} do
				if it.id == id then
					local out = {}
					for k = i + 1, i + (it.n or 0) do
						local d = r.nodes[k]
						table.insert(out, { id = d.id, name = d.name or d.id })
					end
					return out
				end
			end
		end
		return {}
	end

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
	-- (step 5) the variables and modes the Set variable / mode / if rows offer
	local T = PV.read(props.tokens)
	local color_tokens = {}
	for name, t in tokens do
		if t.type == "color" then
			table.insert(color_tokens, { name = name, value = resolve("$" .. name) })
		end
	end
	table.sort(color_tokens, function(a, b)
		return a.name < b.name
	end)

	-- A colour (solid, a token, or nothing): swatch (the paint picker), hex.
	local function color_field(o: { id: string, title: string, paint: any, commit: (np: any) -> () }): Node
		local p = o.paint
		local rp = resolve(p)
		if type(rp) == "table" and rp.type == "color" then
			rp = resolve(rp.color)
		end
		local swatch = if type(rp) == "string" then rp else CLEAR
		local bound = type(p) == "string" and string.sub(p, 1, 1) == "$"
		local label = if bound then string.sub(p, 2) elseif type(rp) == "string" then string.upper(string.sub(rp, 2, 7)) else "None"
		local open = ui.use_state(false)
		local pop = ui.popover {
			open = open,
			autofocus = false,
			label = o.title .. " paint",
			placement = { side = "left", align = "center", offset = 18 },
			anchor = ui.div {
				id = o.id,
				shrink = 0,
				pl = 3,
				pr = 4,
				cursor = "pointer",
				Kit.swatch(L, function(): string
					return swatch
				end, function()
					open:set(true)
				end),
			},
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
					paint = if type(p) == "string" then p else (if type(rp) == "string" then rp else "#000000"),
					resolve = resolve,
					tokens = color_tokens,
					commit = function(np: any, live: boolean)
						if not live and type(np) == "string" then
							o.commit(np)
						end
					end,
					eyedrop = props.eyedrop,
					close = function()
						open:set(false)
					end,
				}
			end,
		}
		return Kit.field(L, {
			tip = o.title,
			leading = ui.div { shrink = 0, h = 16, items = "center", pop },
			value = function(): string?
				return label
			end,
			fg = if bound then L.accent_fg else nil,
			mono = false,
			commit = function(t: string)
				local h = Picker.parse("#" .. string.gsub(t, "#", ""))
				if h then
					o.commit(Picker.hex(h))
				elseif string.sub(t, 1, 1) == "$" then
					o.commit(t)
				end
			end,
		})
	end

	-- The device (F2a; step 6 as Figma's Prototype settings): the size Play
	-- shows each Screen in (a taller one scrolls inside it) from presets in
	-- groups, the Model (body colour), Portrait / Landscape, a small drawn
	-- thumbnail (tab/device_frame.luau), Show device frame, the Scaling, and the
	-- colour around it. One `prototype` op each.
	local function device_section(): Node
		local p = deep(source.prototype and source.prototype:peek() or nil)
		if type(p) ~= "table" then
			p = {}
		end
		local function put(changes: { [string]: any }, label: string)
			source.edit({ { op = "prototype", prototype = changes, merge = true } }, label)
		end
		local cur = p.device
		local pre = if type(cur) == "string" then Scroll.DEVICES[cur] else nil
		local items: { any } = {
			{ label = "No device", note = "each Screen's own size", checked = cur == nil, on_click = function()
				put({ device = "__null", model = "__null" }, "Device")
			end },
		}
		local group = nil
		for _, k in Scroll.DEVICE_ORDER do
			local d = Scroll.DEVICES[k]
			if d.group ~= group then
				group = d.group
				table.insert(items, { head = d.group })
			end
			table.insert(items, { label = d.label, note = `{d.w}×{d.h}`, checked = cur == k, on_click = function()
				-- (a model the new device doesn't offer is dropped, as the engine's merge_prototype)
				put({ device = k, model = if Scroll.has_model(d, p.model) then p.model else "__null" }, "Device")
			end })
		end
		local function label(): string
			if pre then
				return `{pre.label}  {pre.w} × {pre.h}`
			elseif type(cur) == "table" then
				return `Custom  {cur.w or cur[1]} × {cur.h or cur[2]}`
			end
			return "No device"
		end
		local rows: { Node } = {
			dropdown {
				id = "device-preset",
				label = "Device",
				leading = lead_icon("frame"),
				value = label,
				items = items,
				menu_w = 248,
				max_h = 300,
			},
		}
		if pre and type(pre.models) == "table" and #pre.models > 0 then
			local model = if Scroll.has_model(pre, p.model) then p.model else pre.models[1]
			local mitems = {}
			for _, m in pre.models do
				table.insert(mitems, { label = m, checked = m == model, on_click = function()
					put({ model = m }, "Device model")
				end })
			end
			table.insert(rows, dropdown {
				id = "device-model",
				label = "Model",
				leading = ui.div {
					w = 24, min_w = 24, shrink = 0, h_full = true, pl = 2, items = "center", justify = "center",
					ui.div { w = 12, h = 12, rounded = 6, border = 1, border_color = L.border, bg = DeviceFrame.color(pre.frame, model) .. "ff" },
				},
				value = function(): string
					return model
				end,
				items = mitems,
			})
		end
		if cur ~= nil then
			local land = p.rotate == true
			local function radio(rid: string, text: string, on: boolean, fn: () -> ()): Node
				return ui.row {
					id = rid,
					label = text,
					h = 20,
					gap = 6,
					items = "center",
					cursor = "pointer",
					on_click = fn,
					ui.div {
						w = 14, h = 14, rounded = 7, shrink = 0, items = "center", justify = "center",
						border = if on then 4 else 1,
						border_color = if on then L.accent else L.chk_br,
						bg = L.chk_off,
					},
					Kit.text(L, text, { color = if on then L.fg else L.muted }),
				}
			end
			local orient = ui.column {
				gap = 6,
				grow = 1,
				radio("device-portrait", "Portrait", not land, function()
					if land then
						put({ rotate = "__null" }, "Device rotation")
					end
				end),
				radio("device-landscape", "Landscape", land, function()
					if not land then
						put({ rotate = true }, "Device rotation")
					end
				end),
			}
			local thumb: Node = ui.div {}
			if pre and pre.frame then
				-- the frame drawn small (64 px, the frame's box scaled to fit)
				local w, h = pre.w, pre.h
				if land then
					w, h = h, w
				end
				local f = DeviceFrame.shapes(pre.frame, w, h, land, p.model)
				local T = 64
				thumb = ui.div {
					id = "device-thumb",
					w = T + 8, h = T + 8, shrink = 0, rounded = 8, bg = L.field, items = "center", justify = "center",
					ui.canvas {
						w = T, h = T,
						pointer_events = "none",
						draw = function(c: Canvas)
							if not f then
								return
							end
							local bx, by, bw, bh = DeviceFrame.bounds(f)
							local s = math.min(T / bw, T / bh)
							local ox, oy = (T - bw * s) / 2 - bx * s, (T - bh * s) / 2 - by * s
							local function rr(path: any, x: number, y: number, ww: number, hh: number, r: any): any
								local r1 = if type(r) == "table" then math.max(r[1], r[2], r[3], r[4]) else (r or 0)
								return path:rect(ox + x * s, oy + y * s, ww * s, hh * s, math.min(r1 * s, ww * s / 2, hh * s / 2))
							end
							local function draw(list: { any })
								for _, sh in list do
									local fill = if sh.bg then L.field else sh.fill
									if sh.kind == "rect" then
										c:fill(rr(ui.path(), sh.x, sh.y, sh.w, sh.h, sh.r), fill)
									elseif sh.kind == "circle" then
										c:circle(ox + sh.x * s, oy + sh.y * s, sh.r * s, fill)
									elseif sh.kind == "corners" then
										local ro = if type(sh.ro) == "table" then sh.ro else sh.ro
										local path = rr(ui.path(), sh.x - sh.o, sh.y - sh.o, sh.w + 2 * sh.o, sh.h + 2 * sh.o, ro)
										c:fill(rr(path, sh.x, sh.y, sh.w, sh.h, sh.r), fill, "evenodd")
									elseif sh.kind == "poly" then
										local pts = sh.pts
										local path = ui.path():move(ox + pts[1] * s, oy + pts[2] * s)
										for i = 3, #pts - 1, 2 do
											path = path:line(ox + pts[i] * s, oy + pts[i + 1] * s)
										end
										c:fill(path:close(), fill)
									end
								end
							end
							draw(f.body)
							c:rect(ox, oy, f.w * s, f.h * s, L.panel_solid)
							draw(f.over)
						end,
					},
				}
			end
			table.insert(rows, ui.row {
				id = "device-orient",
				w_full = true,
				gap = 8,
				items = "center",
				orient,
				thumb,
			})
			if pre and pre.frame then
				table.insert(rows, Kit.check(L, {
					id = "device-show-frame",
					label = "Show device frame",
					get = function(): boolean?
						return p.showFrame ~= false
					end,
					set = function(on: boolean)
						put({ showFrame = if on then "__null" else false }, "Device frame")
					end,
				}))
			end
		end
		-- (Scaling: the Design's default; Play's menu overrides it for a session.
		-- "Responsive" joins Scroll.FITS with step 6 P5.)
		local fits = {}
		for _, f in Scroll.FITS do
			table.insert(fits, { label = f.label, checked = (p.fit or "fit") == f.name, on_click = function()
				put({ fit = f.name }, "Scaling")
			end })
		end
		table.insert(rows, dropdown {
			id = "device-fit",
			label = "Scaling",
			leading = lead_icon("corners"),
			value = function(): string
				for _, f in Scroll.FITS do
					if f.name == (p.fit or "fit") then
						return f.label
					end
				end
				return "Fit width and height"
			end,
			items = fits,
		})
		table.insert(rows, ui.row {
			w_full = true,
			gap = 8,
			items = "center",
			ui.div { w = 76, shrink = 0, Kit.text(L, "Background", { color = L.muted }) },
			ui.div { grow = 1 },
			color_field {
				id = "device-bg",
				title = "Background",
				paint = p.background,
				commit = function(np: any)
					put({ background = if type(np) == "string" and string.sub(np, 1, 1) == "#" then np else "__null" }, "Prototype background")
				end,
			},
		})
		return sec("Device", nil, rows, { id = "device-head", note = if cur == nil then "Screens play at their own size" else nil })
	end

	-- A layer's scrolling (F2a, Figma's "Scroll behaviour"): a frame's
	-- overflow (it scrolls its content that way), and how a layer moves when
	-- what's around it scrolls (with it, fixed, sticky).
	local function scroll_section(s: any): Node
		local node = s.node or {}
		local id = s.id
		local function edit(props2: { [string]: any }, label: string)
			source.edit({ { op = "update", id = id, props = props2 } }, label)
		end
		local rows: { Node } = {}
		local is_frame = node.type == "frame" or node.type == "instance"
		if is_frame then
			local OV = { { nil, "No scrolling" }, { "vertical", "Vertical" }, { "horizontal", "Horizontal" }, { "both", "Both" } }
			local items = {}
			for _, o in OV do
				table.insert(items, { label = o[2], checked = node.overflow == o[1], on_click = function()
					edit({ overflow = o[1] or "__null" }, "Overflow")
				end })
			end
			table.insert(rows, dropdown {
				id = "scroll-overflow",
				label = "Overflow",
				leading = lead_icon("rows"),
				value = function(): string
					for _, o in OV do
						if o[1] == node.overflow then
							return o[2]
						end
					end
					return "No scrolling"
				end,
				items = items,
			})
		end
		if s.parent_box ~= nil then
			local PO = { { nil, "Scroll with parent" }, { "fixed", "Fixed (stays in place)" }, { "sticky", "Sticky (stops at the top)" } }
			local items = {}
			for _, o in PO do
				table.insert(items, { label = o[2], checked = node.scroll == o[1], on_click = function()
					edit({ scroll = o[1] or "__null" }, "Scroll position")
				end })
			end
			table.insert(rows, dropdown {
				id = "scroll-position",
				label = "Position when scrolling",
				leading = lead_icon("sticky"),
				value = function(): string
					for _, o in PO do
						if o[1] == node.scroll then
							return o[2]
						end
					end
					return "Scroll with parent"
				end,
				items = items,
			})
		end
		if #rows == 0 then
			return ui.div {}
		end
		return sec("Scrolling", nil, rows, { id = "scroll-head" })
	end

	-- A top-level frame's overlay settings (step 2, Figma's "Overlay" on the
	-- frame): where it opens, whether a click outside closes it, and the
	-- background behind it. Every action that opens it uses them.
	local OV_POS = {
		{ "center", "Center" },
		{ "top-left", "Top left" },
		{ "top", "Top center" },
		{ "top-right", "Top right" },
		{ "bottom-left", "Bottom left" },
		{ "bottom", "Bottom center" },
		{ "bottom-right", "Bottom right" },
	}
	local OV_ALIAS = { ["top-center"] = "top", ["bottom-center"] = "bottom" }
	local function ov_pos_label(p: string?): string
		local k = OV_ALIAS[p or ""] or p or "center"
		for _, o in OV_POS do
			if o[1] == k then
				return o[2]
			end
		end
		return "Center"
	end
	local function overlay_section(s: any): Node
		local node = s.node or {}
		if s.parent_box ~= nil or node.type ~= "frame" or node.reusable == true then
			return ui.div {}
		end
		local id = s.id
		local o = if type(node.overlay) == "table" then deep(node.overlay) else {}
		local function put(fn: (o2: any) -> (), label: string)
			local o2 = deep(o)
			fn(o2)
			source.edit({ { op = "update", id = id, props = { overlay = if next(o2) == nil then "__null" else o2 } } }, label)
		end
		local items = {}
		for _, p in OV_POS do
			table.insert(items, { label = p[2], checked = (OV_ALIAS[o.position or ""] or o.position or "center") == p[1], on_click = function()
				put(function(o2: any)
					o2.position = if p[1] == "center" then nil else p[1]
				end, "Overlay position")
			end })
		end
		local rows: { Node } = {
			dropdown {
				id = "overlay-position",
				label = "Overlay position",
				leading = lead_icon("frame"),
				value = function(): string
					return ov_pos_label(o.position)
				end,
				items = items,
			},
			Kit.check(L, {
				label = "Close when clicking outside",
				get = function(): boolean?
					return o.closeOutside ~= false
				end,
				set = function(on: boolean)
					put(function(o2: any)
						o2.closeOutside = if on then nil else false
					end, "Close when clicking outside")
				end,
			}),
			Kit.check(L, {
				label = "Add background behind overlay",
				get = function(): boolean?
					return type(o.background) == "table"
				end,
				set = function(on: boolean)
					put(function(o2: any)
						o2.background = if on then { color = "#000000", opacity = 0.4 } else nil
					end, "Overlay background")
				end,
			}),
		}
		if type(o.background) == "table" then
			local bg = o.background
			table.insert(rows, Kit.pair(
				color_field {
					id = "overlay-bg",
					title = "Overlay background",
					paint = bg.color or "#000000",
					commit = function(np: any)
						put(function(o2: any)
							o2.background.color = np
						end, "Overlay background")
					end,
				},
				Kit.num(L, {
					id = "overlay-bg-opacity",
					tip = "Background opacity",
					icon = "opacity",
					unit = "%",
					min = 0,
					max = 100,
					step = 5,
					get = function(): number?
						return math.floor((tonumber(bg.opacity) or 0.4) * 100 + 0.5)
					end,
					set = function(v: number)
						put(function(o2: any)
							o2.background.opacity = math.clamp(math.floor(v + 0.5), 0, 100) / 100
						end, "Overlay background")
					end,
				})
			))
		end
		return sec("Overlay", nil, rows, { id = "overlay-head", note = "when opened as an overlay" })
	end

	-- Nothing selected: the Flows ---------------------------------------------------------
	if #sel == 0 then
		local head = ui.row {
			w_full = true,
			p = 12,
			gap = 6,
			items = "center",
			Kit.text(L, "Prototype", { weight = 500, color = L.fg, grow = 1 }),
		}
		local flows = deep(source.flows and source.flows:peek() or {})
		local function put(list: { any }, label: string)
			source.edit({ { op = "flows", flows = if #list > 0 then list else "__null" } }, label)
		end
		local rows: { Node } = {}
		for i, f in flows do
			table.insert(
				rows,
				ui.column {
					id = `flow-{i}`,
					w_full = true,
					gap = 6,
					ui.row {
						w_full = true,
						gap = 6,
						items = "center",
						ui.div { grow = 1, min_w = 0, Kit.field(L, {
							id = `flow-name-{i}`,
							tip = "Flow name",
							leading = lead_icon(if i == 1 then "play" else "flow", if i == 1 then L.accent_fg else nil),
							value = function(): string?
								return f.name
							end,
							mono = false,
							commit = function(t: string)
								if t ~= "" and t ~= f.name then
									local l = deep(flows)
									l[i].name = t
									put(l, "Rename flow")
								end
							end,
						}) },
						if i > 1 then act("arrowLeft", "Make it the first (default)", function()
							local l = deep(flows)
							local x = table.remove(l, i)
							table.insert(l, 1, x)
							put(l, "Reorder flows")
						end, `flow-first-{i}`) else ui.div {},
						act("minus", "Remove flow", function()
							local l = deep(flows)
							table.remove(l, i)
							put(l, "Remove flow")
						end, `flow-remove-{i}`),
					},
					(function(): Node
						local items = {}
						for _, s in screens do
							table.insert(items, { label = s.name, checked = s.id == f.start, on_click = function()
								local l = deep(flows)
								l[i].start = s.id
								put(l, "Flow start")
							end })
						end
						local missing = not screen_name[f.start]
						return dropdown {
							id = `flow-start-{i}`,
							label = "Starting Screen",
							leading = lead_icon("frame"),
							value = function(): string
								return if missing then "Missing Screen" else screen_name[f.start]
							end,
							fg = if missing then L.danger else nil,
							items = items,
						}
					end)(),
					desc_box(`flow-desc-{i}`, f.description, function(t: string)
						local l = deep(flows)
						l[i].description = if t == "" then nil else t
						put(l, "Flow description")
					end),
				}
			)
		end
		if #flows == 0 then
			table.insert(rows, Kit.text(L, "Add a flow to choose where Play starts.", { color = L.muted }))
		end
		local add = act("plus", "Add flow", function()
			local l = deep(flows)
			local used: { [string]: boolean } = {}
			for _, f in l do
				used[f.start] = true
			end
			local start = nil
			for _, s in screens do
				if not used[s.id] then
					start = s.id
					break
				end
			end
			start = start or (screens[1] and screens[1].id)
			if not start then
				return
			end
			table.insert(l, { name = `Flow {#l + 1}`, start = start })
			put(l, "Add flow")
		end, "flow-add")
		return ui.column {
			w_full = true,
			head,
			sec("Flows", { add }, rows, { id = "flows-head" }),
			device_section(),
			sec("Canvas", nil, {
				Kit.check(L, {
					label = "Show all links on canvas",
					get = function(): boolean?
						return props.show_all:get()
					end,
					set = function(on: boolean)
						props.show_all:set(on)
					end,
				}),
			}),
		}
	end

	-- A layer selected ------------------------------------------------------------------------
	local s = sel[1]
	local id = s.id
	local node = s.node or {}
	local resolved = s.resolved or {}
	local is_inst = node.type == "instance" or string.find(id, "/", 1, true) ~= nil
	local function edit(props2: { [string]: any }, label: string)
		source.edit({ { op = "update", id = id, props = props2 } }, label)
	end

	-- Interactions
	-- (F6 C2) several layers selected: one row per trigger across them
	-- (proto_match.luau), a value they don't share shown as Mixed, and every
	-- change written to each layer that has the row, in one edit.
	local multi = #sel > 1
	local function list_of(si: any): ({ any }, boolean)
		local nd = si.node or {}
		local rs = si.resolved or {}
		local inst = nd.type == "instance" or string.find(si.id, "/", 1, true) ~= nil
		local own = nd.interactions
		local inh = own == nil and inst and type(rs.interactions) == "table" and #rs.interactions > 0
		local l = deep(if own ~= nil then own elseif inh then rs.interactions else {})
		return (if type(l) == "table" then l else {}), inh == true
	end
	local own_ia = node.interactions
	local list, inh_ia = list_of(s)
	local lists: { [string]: { any } } = {}
	local mrows: { any } = {}
	if multi then
		local layers = {}
		for _, si in sel do
			lists[si.id] = (list_of(si))
			table.insert(layers, { id = si.id, list = lists[si.id] })
		end
		mrows = Match.merge(layers)
		list = {}
		for _, r in mrows do
			table.insert(list, r.rec)
		end
		inh_ia = false
	end
	local function put_ia(l: { any }, label: string)
		edit({ interactions = if #l > 0 then l else "__null" }, label)
	end
	local function ia_value(l: { any }): any
		return if #l > 0 then l else "__null"
	end
	-- Change interaction i: fn gets the stored record (a copy) and returns
	-- false when it has nothing to change. With several layers, each that
	-- has the row gets fn on its own record (so only the field edited
	-- changes), all in one edit (one undo).
	local function mod(i: number, fn: (r: any) -> boolean?, label: string)
		if not multi then
			local l = deep(list)
			if fn(l[i]) == false then
				return
			end
			put_ia(l, label)
			return
		end
		local ops = {}
		for _, m in (mrows[i] and mrows[i].layers) or {} do
			local l = deep(lists[m.id])
			if l[m.i] and fn(l[m.i]) ~= false then
				table.insert(ops, { op = "update", id = m.id, props = { interactions = ia_value(l) } })
			end
		end
		if #ops > 0 then
			source.edit(ops, label)
		end
	end
	local function remove_ia(i: number)
		if not multi then
			local l = deep(list)
			table.remove(l, i)
			put_ia(l, "Remove interaction")
			return
		end
		local ops = {}
		for _, m in (mrows[i] and mrows[i].layers) or {} do
			local l = deep(lists[m.id])
			table.remove(l, m.i)
			table.insert(ops, { op = "update", id = m.id, props = { interactions = ia_value(l) } })
		end
		if #ops > 0 then
			source.edit(ops, "Remove interaction")
		end
	end
	-- (F6 C2) select those layers and those interactions (`ia_sel`, as the
	-- Canvas keeps it: keyed by the selection), with a toast whose Undo
	-- brings the selection back.
	local function set_selection(ids: { string })
		source.selection:set(ids)
		if source.select then
			source.select(ids)
		end
	end
	local function select_matching(found: { any })
		local was = deep(source.selection:peek() or {})
		local was_ia = if source.ia_sel then deep(source.ia_sel:peek()) else nil
		local ids, seen = {}, {}
		for _, f in found do
			if not seen[f.id] then
				seen[f.id] = true
				table.insert(ids, f.id)
			end
		end
		set_selection(ids)
		if source.ia_sel then
			source.ia_sel:set({ key = table.concat(ids, ","), list = deep(found) })
		end
		Toast.show {
			icon = "target",
			title = `Selected {#found} matching interactions`,
			action = { label = "Undo", run = function()
				set_selection(was)
				if source.ia_sel and was_ia then
					source.ia_sel:set(was_ia)
				end
			end },
		}
	end
	-- (F6 C3) A row picked (its trigger icon clicked) is a selected
	-- interaction, as a noodle is (`ia_sel`, keyed by the layer selection), so
	-- the Canvas's Ctrl+C / X / Delete act on it. Its `{ id, k }` on every
	-- layer that has the row.
	local function row_keys(i: number): { any }
		local out = {}
		if not multi then
			local k = Match.scene_k(list, i)
			if k then
				table.insert(out, { id = id, k = k })
			end
			return out
		end
		for _, m in (mrows[i] and mrows[i].layers) or {} do
			local k = Match.scene_k(lists[m.id], m.i)
			if k then
				table.insert(out, { id = m.id, k = k })
			end
		end
		return out
	end
	local sel_key = table.concat(source.selection:peek() or {}, ",")
	-- (read inside a presence key, so only the pick button redraws)
	local function picked(i: number): boolean
		local picked_now = if source.ia_sel then source.ia_sel:get() else nil
		if type(picked_now) ~= "table" or picked_now.key ~= sel_key then
			return false
		end
		local keys = row_keys(i)
		if #keys == 0 then
			return false
		end
		for _, a in keys do
			local found = false
			for _, b in picked_now.list or {} do
				if b.id == a.id and b.k == a.k then
					found = true
				end
			end
			if not found then
				return false
			end
		end
		return true
	end
	local function pick(i: number, on: boolean)
		if source.ia_sel then
			source.ia_sel:set({ key = sel_key, list = if on then row_keys(i) else {} })
		end
	end
	-- The row's record to copy: this layer's, or (several) the first that has it.
	local function row_record(i: number): any?
		if not multi then
			return deep(list[i])
		end
		local m = mrows[i] and mrows[i].layers[1]
		return if m then deep(lists[m.id][m.i]) else nil
	end
	local function paste_here()
		local ids = {}
		for _, si in sel do
			table.insert(ids, si.id)
		end
		IaClip.paste(source, ids, {
			say = function(title: string, body: string?)
				Toast.show { icon = "alert", title = title, body = body }
			end,
		})
	end
	-- (step 4, F4b) the variant set around the layer (the service's
	-- `variant`): Change to is offered inside an Instance or Component of one
	local vctx = if multi then nil else sel[1] and sel[1].variant
	local vlabel: { [string]: string } = {}
	for _, m in (vctx and vctx.members) or {} do
		vlabel[m.id] = m.label
	end
	local function action_items(items: { any }, set_action: any, kind: string?): { any }
		if vctx or kind == "changeTo" then
			table.insert(items, { label = "Change to", checked = kind == "changeTo", on_click = function()
				set_action(function(a2: any)
					local to = nil
					for _, m in (vctx and vctx.members) or {} do
						if m.id ~= vctx.member and not to then
							to = m.id
						end
					end
					for k in a2 do
						a2[k] = nil
					end
					a2.action = "changeTo"
					a2.to = to or (vctx and vctx.member)
					a2.transition = { type = "smart", duration = 300, easing = "ease-out" }
				end)
			end })
		end
		return items
	end
	local ia_rows: { Node } = {}
	for i, x in list do
		local body: { Node } = {}
		-- (step 5) an action's place: `{ j }` at the top, `{ j, "then", k, … }`
		-- inside a Conditional's branches. The list holding it and its index.
		local function dig(acts: { any }, path: { any }): ({ any }, number)
			local cur = acts
			local p = 1
			while p < #path do
				local a2 = cur[path[p]]
				local br = path[p + 1]
				if type(a2[br]) ~= "table" then
					a2[br] = {}
				end
				cur = a2[br]
				p += 2
			end
			return cur, path[#path]
		end
		local function path_set(path: { any }, fn: (a: any) -> (), label: string?)
			mod(i, function(r: any): boolean?
				r.actions = r.actions or {}
				-- (several layers: one without this action is left alone; a
				-- nested path is only offered when the branches are equal)
				if multi and type(r.actions[path[1]]) ~= "table" then
					return false
				end
				local lst, k = dig(r.actions, path)
				local a2 = lst[k] or { action = "navigate" }
				fn(a2)
				lst[k] = a2
				return nil
			end, label or "Change interaction")
		end
		-- (an emptied branch is dropped, as an agent would write it)
		local function path_remove(path: { any })
			mod(i, function(r: any): boolean?
				r.actions = r.actions or {}
				if multi and type(r.actions[path[1]]) ~= "table" then
					return false
				end
				local lst, k = dig(r.actions, path)
				table.remove(lst, k)
				if #path > 1 and #lst == 0 then
					local plist, pk = dig(r.actions, table.move(path, 1, #path - 2, 1, {}))
					plist[pk][path[#path - 1]] = nil
				end
				return nil
			end, "Remove action")
		end
		local function clear_vars(a2: any)
			if PV.KINDS[a2.action] then
				for k in a2 do
					a2[k] = nil
				end
			end
		end
		local function action_block(body: { Node }, a: any, sfx: string, set_action: (fn: (a: any) -> ()) -> (), path: { any }, depth: number)
		local kind = a.action
		table.insert(
			body,
			dropdown {
				id = `ia-action-{sfx}`,
				label = "Action",
				leading = lead_icon(if kind == "back" then "arrowLeft" elseif kind == "url" then "external" elseif kind == "overlay" or kind == "swap" then "layers" elseif kind == "close" then "x" elseif kind == "changeTo" then "component" elseif PV.KINDS[kind] then PV.ICON[kind] else "arrowRight"),
				value = function(): string
					return if kind == MIXED then "Mixed" elseif kind == "back" then "Back" elseif kind == "url" then "Open link" elseif kind == "motion" then "Play motion (not played yet)" elseif kind == "overlay" then "Open overlay" elseif kind == "swap" then "Swap overlay" elseif kind == "close" then "Close overlay" elseif kind == "changeTo" then "Change to" elseif PV.KINDS[kind] then PV.LABEL[kind] else "Navigate to"
				end,
				items = action_items({
					{ label = "Navigate to", checked = kind == "navigate", on_click = function()
						set_action(function(a2: any)
							clear_vars(a2)
							a2.action, a2.url, a2.newTab = "navigate", nil, nil
							a2.to = a2.to or (screens[1] and screens[1].id)
							a2.transition = a2.transition or { type = "dissolve", duration = 300, easing = "ease-out" }
						end)
					end },
					{ label = "Back", checked = kind == "back", on_click = function()
						set_action(function(a2: any)
							clear_vars(a2)
							a2.action, a2.to, a2.url, a2.newTab, a2.transition = "back", nil, nil, nil, nil
						end)
					end },
					{ label = "Open link", checked = kind == "url", on_click = function()
						set_action(function(a2: any)
							clear_vars(a2)
							a2.action, a2.to, a2.transition = "url", nil, nil
							a2.url = a2.url or "https://"
						end)
					end },
					-- overlays (step 2)
					{ label = "Open overlay", checked = kind == "overlay", on_click = function()
						set_action(function(a2: any)
							local to = if a2.action == "navigate" or a2.action == "swap" then a2.to else nil
							for k in a2 do
								a2[k] = nil
							end
							a2.action = "overlay"
							a2.to = to or (screens[1] and screens[1].id)
							a2.transition = { type = "dissolve", duration = 300, easing = "ease-out" }
						end)
					end },
					{ label = "Swap overlay", checked = kind == "swap", on_click = function()
						set_action(function(a2: any)
							local to = if a2.action == "navigate" or a2.action == "overlay" then a2.to else nil
							for k in a2 do
								a2[k] = nil
							end
							a2.action = "swap"
							a2.to = to or (screens[1] and screens[1].id)
							a2.transition = { type = "dissolve", duration = 300, easing = "ease-out" }
						end)
					end },
					{ label = "Close overlay", checked = kind == "close", on_click = function()
						set_action(function(a2: any)
							for k in a2 do
								a2[k] = nil
							end
							a2.action = "close"
						end)
					end },
					-- (step 5) variables: Set variable, Toggle, Set variable mode,
					-- Conditional (the current action goes inside its Then)
					{ label = PV.LABEL.set, checked = kind == "set", on_click = function()
						if kind == "set" then
							return
						end
						set_action(function(a2: any)
							local keep = if (a2.action == "set" or a2.action == "toggle") and T.kinds[a2.var] then a2.var else nil
							local f = PV.fresh(T, "set")
							if keep then
								f.var, f.to = keep, PV.default_to(T, keep)
							end
							for k in a2 do
								a2[k] = nil
							end
							for k, v in f do
								a2[k] = v
							end
						end)
					end },
					{ label = PV.LABEL.toggle, checked = kind == "toggle", on_click = function()
						if kind == "toggle" then
							return
						end
						set_action(function(a2: any)
							local keep = if T.kinds[a2.var] == "boolean" then a2.var else nil
							local f = PV.fresh(T, "toggle")
							for k in a2 do
								a2[k] = nil
							end
							a2.action, a2.var = "toggle", keep or f.var
						end)
					end },
					{ label = PV.LABEL.mode, checked = kind == "mode", on_click = function()
						if kind == "mode" then
							return
						end
						set_action(function(a2: any)
							local f = PV.fresh(T, "mode")
							for k in a2 do
								a2[k] = nil
							end
							for k, v in f do
								a2[k] = v
							end
						end)
					end },
					{ label = PV.LABEL["if"], checked = kind == "if", on_click = function()
						if kind == "if" then
							return
						end
						set_action(function(a2: any)
							local f = PV.fresh(T, "if")
							if a2.action ~= "if" and a2.action ~= nil then
								f["then"] = { deep(a2) }
							end
							for k in a2 do
								a2[k] = nil
							end
							for k, v in f do
								a2[k] = v
							end
						end)
					end },
				}, set_action, kind),
			}
		)
		-- (F6 C2) the layers' actions differ: only the kind can be set (for all)
		if kind == MIXED then
			table.insert(body, note("The layers do different things here. Pick an action to set it on all of them.", `ia-mixed-{sfx}`))
			return
		end
		-- an overlay's place: the frame's own (its Overlay settings), one of
		-- the seven, or manual (from this layer's top-left, an offset)
		if kind == "overlay" then
			local cur = a.position
			local own = nil
			for _, r in source.roots:peek() do
				if r.id == a.to then
					local ovl = r.nodes and r.nodes[1] and r.nodes[1].ovl
					own = ov_pos_label(ovl and ovl.pos)
				end
			end
			local pitems = {
				{ label = `As the frame's: {own or "Center"}`, checked = cur == nil, on_click = function()
					set_action(function(a2: any)
						a2.position, a2.offset = nil, nil
					end)
				end },
			}
			for _, p in OV_POS do
				table.insert(pitems, { label = p[2], checked = (OV_ALIAS[cur or ""] or cur) == p[1], on_click = function()
					set_action(function(a2: any)
						a2.position, a2.offset = p[1], nil
					end)
				end })
			end
			table.insert(pitems, { label = "Manual (from this layer)", checked = cur == "manual", on_click = function()
				set_action(function(a2: any)
					a2.position = "manual"
					a2.offset = a2.offset or { x = 0, y = 0 }
				end)
			end })
			table.insert(
				body,
				dropdown {
					id = `ia-pos-{sfx}`,
					label = "Overlay position",
					leading = lead_icon("frame"),
					value = function(): string
						return if cur == MIXED then "Mixed" elseif cur == nil then `As the frame's: {own or "Center"}` elseif cur == "manual" then "Manual" else ov_pos_label(cur)
					end,
					items = pitems,
				}
			)
			if cur == "manual" then
				local off = if type(a.offset) == "table" then a.offset else {}
				local function off_num(axis: string, label: string): Node
					return Kit.num(L, {
						id = `ia-off-{axis}-{sfx}`,
						label = label,
						tip = `Offset {axis} from this layer's top-left`,
						get = function(): number?
							if a.offset == MIXED or off[axis] == MIXED then
								return nil -- (Mixed)
							end
							return tonumber(off[axis]) or 0
						end,
						set = function(v: number)
							set_action(function(a2: any)
								a2.offset = if type(a2.offset) == "table" then a2.offset else {}
								a2.offset[axis] = math.floor(v + 0.5)
							end)
						end,
					})
				end
				table.insert(body, Kit.pair(off_num("x", "X"), off_num("y", "Y")))
			end
		end
		if kind == "url" then
			table.insert(
				body,
				Kit.field(L, {
					id = `ia-url-{sfx}`,
					tip = "Link",
					leading = lead_icon("link"),
					value = function(): string?
						return if a.url == MIXED then nil else a.url
					end,
					mono = false,
					commit = function(t: string)
						set_action(function(a2: any)
							a2.url = t
						end)
					end,
				})
			)
		end
		if kind == "navigate" or kind == nil or kind == "overlay" or kind == "swap" then
			local items = {}
			for _, sc in screens do
				table.insert(items, { label = sc.name, checked = sc.id == a.to, on_click = function()
					set_action(function(a2: any)
						a2.to = sc.id
					end)
				end })
			end
			local missing = a.to ~= nil and a.to ~= MIXED and not screen_name[a.to]
			table.insert(
				body,
				dropdown {
					id = `ia-to-{sfx}`,
					label = "Destination",
					leading = lead_icon("frame", if missing then L.danger else nil),
					value = function(): string
						return if a.to == MIXED then "Mixed" elseif missing then "Missing Screen" elseif a.to then screen_name[a.to] else "Choose a Screen"
					end,
					fg = if missing then L.danger else nil,
					items = items,
				}
			)
			-- (step 4) Figma's "Reset component state": the Screen's
			-- interactive components start at their own variants
			if kind == "navigate" or kind == nil then
				table.insert(
					body,
					ui.div {
						w_full = true,
						Kit.check(L, {
							id = `ia-rc-{sfx}`,
							label = "Reset component state",
							get = function(): boolean?
								return a.resetComponents == true
							end,
							set = function(on: boolean)
								set_action(function(a2: any)
									a2.resetComponents = if on then true else nil
								end)
							end,
						}),
					}
				)
			end
		end
		-- (step 4) Change to: the member, by its props ("On=true")
		if kind == "changeTo" then
			local items = {}
			for _, m in (vctx and vctx.members) or {} do
				table.insert(items, { label = m.label ~= "" and m.label or m.id, checked = m.id == a.to, on_click = function()
					set_action(function(a2: any)
						a2.to = m.id
					end)
				end })
			end
			local missing = a.to ~= nil and vctx ~= nil and not vlabel[a.to]
			table.insert(
				body,
				dropdown {
					id = `ia-to-{sfx}`,
					label = "Variant",
					leading = lead_icon("component", if missing then L.danger else nil),
					value = function(): string
						return if a.to == MIXED then "Mixed" elseif missing then "Not in this set" elseif a.to and vlabel[a.to] then vlabel[a.to] elseif a.to then tostring(a.to) else "Choose a variant"
					end,
					fg = if missing then L.danger else nil,
					items = items,
				}
			)
		end
		if kind == "navigate" or kind == "back" or kind == nil or kind == "overlay" or kind == "swap" or kind == "close" or kind == "changeTo" then
			local t = a.transition
			local tk = if t == MIXED then MIXED elseif type(t) == "table" then t.type or "instant" else (if kind == "back" or kind == "close" then "reverse" else "instant")
			local kitems = {}
			-- (an overlay arrives or leaves: Figma's animations for each)
			local allowed: { [string]: boolean }? = if kind == "overlay"
				then { instant = true, dissolve = true, moveIn = true, slideIn = true }
				elseif kind == "close" then { instant = true, dissolve = true, moveOut = true, slideOut = true }
				elseif kind == "changeTo" then { instant = true, dissolve = true, smart = true }
				else nil
			if kind == "back" or kind == "close" then
				table.insert(kitems, { label = "Reverse of the way in", checked = tk == "reverse", on_click = function()
					set_action(function(a2: any)
						a2.transition = nil
					end)
				end })
			end
			for _, k in Proto.KINDS do
				if allowed and not allowed[k] then
					continue
				end
				table.insert(kitems, { label = Proto.KIND_LABEL[k], checked = tk == k, on_click = function()
					set_action(function(a2: any)
						local was = if type(a2.transition) == "table" then a2.transition else {}
						a2.transition = {
							type = k,
							direction = if Proto.DIRECTIONAL[k] then (was.direction or "left") else nil,
							matchLayers = if Proto.DIRECTIONAL[k] and kind ~= "overlay" and kind ~= "close" then was.matchLayers else nil,
							duration = if k == "instant" then nil else (was.duration or 300),
							easing = if k == "instant" then nil else (was.easing or "ease-out"),
						}
					end)
				end })
			end
			table.insert(
				body,
				dropdown {
					id = `ia-tr-{sfx}`,
					label = "Animation",
					leading = lead_icon("swap"),
					value = function(): string
						return if tk == MIXED then "Mixed" elseif tk == "reverse" then "Reverse of the way in" else (Proto.KIND_LABEL[tk] or tk)
					end,
					items = kitems,
				}
			)
			if type(t) == "table" and Proto.DIRECTIONAL[tk] then
				local dirs = { { "left", "←" }, { "right", "→" }, { "up", "↑" }, { "down", "↓" } }
				local r: any = { id = `ia-dir-{sfx}`, w_full = true, h = 28, p = 2, gap = 2, rounded = 8, bg = L.field }
				for _, d in dirs do
					local on = (t.direction or "left") == d[1]
					table.insert(
						r,
						ui.button {
							id = `ia-dir-{sfx}-{d[1]}`,
							label = `Direction {d[1]}`,
							grow = 1,
							basis = 0,
							h = 24,
							p = 0,
							rounded = 6,
							border = 0,
							items = "center",
							justify = "center",
							bg = if on then L.field_active else CLEAR,
							hover = { bg = L.hover },
							on_click = function()
								set_action(function(a2: any)
									a2.transition.direction = d[1]
								end)
							end,
							ui.text { d[2], text_size = 13, color = if on then L.fg else L.faint, font = Look.UI },
						}
					)
				end
				table.insert(body, ui.row(r))
				-- (step 3) Figma's "Smart animate matching layers": the layers
				-- both Screens have tween while the rest moves this way
				if kind ~= "overlay" and kind ~= "close" then
					table.insert(
						body,
						ui.div {
							w_full = true,
							Kit.check(L, {
								id = `ia-ml-{sfx}`,
								label = "Smart animate matching layers",
								get = function(): boolean?
									return t.matchLayers == true
								end,
								set = function(on: boolean)
									set_action(function(a2: any)
										a2.transition.matchLayers = if on then true else nil
									end)
								end,
							}),
						}
					)
				end
			end
			if type(t) == "table" and tk ~= "instant" then
				local eitems = {}
				local now_label = if Match.has_mixed(t.easing) then "Mixed" else Proto.easing_label(t.easing or "ease-out")
				for _, e in Proto.EASINGS do
					table.insert(eitems, { label = e.label, checked = now_label == e.label, on_click = function()
						set_action(function(a2: any)
							a2.transition.easing = e.name
						end)
					end })
				end
				table.insert(eitems, { label = "Custom bézier", checked = now_label == "Custom bézier", on_click = function()
					set_action(function(a2: any)
						local e0 = a2.transition.easing
						a2.transition.easing = table.clone(Proto.bezier_of(if Proto.spring_of(e0) then "ease-out" else e0 or "ease-out"))
					end)
				end })
				for _, sp in Proto.SPRINGS do
					table.insert(eitems, { label = `Spring: {sp.label}`, checked = now_label == sp.label, on_click = function()
						set_action(function(a2: any)
							a2.transition.easing = sp.name
						end)
					end })
				end
				table.insert(eitems, { label = "Custom spring", checked = now_label == "Custom spring", on_click = function()
					set_action(function(a2: any)
						local was = Proto.spring_of(a2.transition.easing) or { mass = 1, stiffness = 100, damping = 15 }
						a2.transition.easing = { spring = table.clone(was) }
					end)
				end })
				local spring = Proto.spring_of(t.easing)
				local settle_ms = if spring then math.floor(select(2, Proto.spring(spring)) * 1000 + 0.5) else nil
				-- (follows a custom spring's drag live, before it commits)
				local live_ms = ui.use_state(settle_ms)
				table.insert(
					body,
					Kit.pair(
						Kit.num(L, {
							id = `ia-ms-{sfx}`,
							tip = "Duration (ms)",
							icon = "clock",
							unit = "ms",
							min = 0,
							max = 10000,
							step = 10,
							get = function(): number?
								-- (a spring takes its own time: shown, not set)
								if t.duration == MIXED and not live_ms:get() then
									return nil -- (Mixed)
								end
								return live_ms:get() or tonumber(t.duration) or 300
							end,
							set = function(v: number)
								set_action(function(a2: any)
									a2.transition.duration = math.clamp(math.floor(v + 0.5), 0, 10000)
								end)
							end,
						}),
						dropdown {
							id = `ia-ease-{sfx}`,
							label = "Easing",
							value = function(): string
								return now_label
							end,
							items = eitems,
							menu_w = 200,
						}
					)
				)
				-- the curve: a custom bézier's handles, a spring's shape
				if now_label == "Custom bézier" then
					table.insert(body, ui.component(Curve.Bezier)({
						L = L,
						id = `ia-curve-{sfx}`,
						value = table.clone(Proto.bezier_of(t.easing)),
						commit = function(b: { number })
							set_action(function(a2: any)
								a2.transition.easing = { b[1], b[2], b[3], b[4] }
							end)
						end,
					}))
				elseif spring then
					table.insert(body, ui.component(Curve.Spring)({
						L = L,
						id = `ia-spring-{sfx}`,
						value = table.clone(spring),
						live_ms = live_ms,
						commit = if type(t.easing) == "table" then function(sp: any)
							set_action(function(a2: any)
								a2.transition.easing = { spring = sp }
							end)
						end else nil,
					}))
				end
			end
		end
		-- (step 5, V5a) the variable actions: Figma's Set variable, Set
		-- variable mode and Conditional, and our Toggle. A wrong value or
		-- condition is outlined red, V1's message under it (and as its tooltip).
		if PV.KINDS[kind] then
			local function checked(n: Node, err: string?): Node
				if not err then
					return n
				end
				return ui.column {
					w_full = true,
					gap = 4,
					ui.div { w_full = true, tooltip = err, n },
					ui.row {
						id = `ia-err-{sfx}`,
						w_full = true,
						gap = 4,
						items = "start",
						ui.div { shrink = 0, pt = 1, color = L.danger, Kit.icon("alert", 12) },
						ui.text { err, text_size = 11, color = L.danger, font = Look.UI, grow = 1, min_w = 0, wrap = true },
					},
				}
			end
			local function var_picker(only: string?, err: string?): Node
				local items = {}
				for _, n in T.names do
					local k = T.kinds[n]
					if only and k ~= only then
						continue
					end
					table.insert(items, { label = n, icon = PV.type_icon(k), note = PV.TYPE_LABEL[k], checked = n == a.var, on_click = function()
						set_action(function(a2: any)
							if a2.var ~= n then
								a2.var = n
								if a2.action == "set" then
									a2.to = PV.default_to(T, n)
								end
							end
						end)
					end })
				end
				if #items == 0 then
					table.insert(items, { label = if only == "boolean" then "No true/false variables yet" else "No variables yet: add one in Variables", on_click = function() end })
				end
				local missing = a.var ~= nil and a.var ~= MIXED and T.loaded and T.kinds[a.var] == nil
				local bad = err ~= nil and (missing or a.var == nil or (only ~= nil and T.kinds[a.var] ~= only))
				return dropdown {
					id = `ia-var-{sfx}`,
					label = "Variable",
					leading = lead_icon(PV.type_icon(T.kinds[a.var]), if bad then L.danger else L.accent_fg),
					value = function(): string
						return if a.var == MIXED then "Mixed" elseif a.var == nil then "Choose a variable" elseif missing then `Missing: {a.var}` else a.var
					end,
					fg = if bad then L.danger else nil,
					items = items,
					menu_w = 240,
				}
			end
			-- (F6 C2) several layers: a Mixed variable shows only its picker; a
			-- Mixed value is an empty box ("Mixed") whose text goes to all
			if (kind == "set" or kind == "toggle") and a.var == MIXED then
				table.insert(body, var_picker(if kind == "toggle" then "boolean" else nil, nil))
			elseif kind == "set" and a.to == MIXED then
				table.insert(body, var_picker(nil, nil))
				table.insert(body, Kit.field(L, {
					id = `ia-to-{sfx}`,
					tip = "Value: a value, $other, or an expression in { }, as {count + 1}",
					leading = lead_icon(PV.type_icon(T.kinds[a.var])),
					value = function(): string?
						return nil -- (Mixed)
					end,
					mono = false,
					commit = function(t: string)
						set_action(function(a2: any)
							a2.to = PV.parse_value(T.kinds[a2.var], t)
						end)
					end,
				}))
			elseif kind == "set" then
				local err = PV.check_set(T, a.var, a.to)
				local want = T.kinds[a.var]
				local var_err = if a.var == nil or (T.loaded and want == nil) then err else nil
				table.insert(body, checked(var_picker(nil, var_err), var_err))
				local val_err = if var_err then nil else err
				local value: Node
				if want == "color" and (a.to == nil or (type(a.to) == "string" and string.sub(a.to, 1, 1) ~= "{")) then
					value = color_field {
						id = `ia-to-{sfx}`,
						title = "Value",
						paint = a.to,
						commit = function(np: any)
							set_action(function(a2: any)
								a2.to = np
							end)
						end,
					}
				elseif want == "boolean" and type(a.to) == "boolean" then
					local items = {}
					for _, b in { true, false } do
						table.insert(items, { label = tostring(b), checked = a.to == b, on_click = function()
							set_action(function(a2: any)
								a2.to = b
							end)
						end })
					end
					table.insert(items, { label = "Expression…", checked = false, on_click = function()
						set_action(function(a2: any)
							a2.to = `\{not {PV.ref(a2.var or "x")}\}`
						end)
					end })
					value = dropdown {
						id = `ia-to-{sfx}`,
						label = "Value",
						leading = lead_icon("check"),
						value = function(): string
							return tostring(a.to)
						end,
						items = items,
					}
				else
					local expr = type(a.to) == "string" and (string.sub(a.to, 1, 1) == "{" or string.sub(a.to, 1, 1) == "$")
					value = Kit.field(L, {
						id = `ia-to-{sfx}`,
						tip = "Value: a value, $other, or an expression in { }, as {count + 1}",
						leading = lead_icon(if expr then "code" else PV.type_icon(want), if val_err then L.danger else nil),
						value = function(): string?
							return PV.value_text(a.to)
						end,
						placeholder = "Value or {expression}",
						mono = expr,
						fg = if val_err then L.danger else nil,
						outline = if val_err then L.danger else nil,
						commit = function(t: string)
							set_action(function(a2: any)
								a2.to = PV.parse_value(T.kinds[a2.var], t)
							end)
						end,
					})
				end
				table.insert(body, checked(value, val_err))
			elseif kind == "toggle" then
				local err = PV.check_toggle(T, a.var)
				table.insert(body, checked(var_picker("boolean", err), err))
			elseif kind == "mode" then
				local mixed_mode = a.axis == MIXED or a.value == MIXED
				local err = if mixed_mode then nil else PV.check_mode(T, a.axis, a.value)
				local aitems, vitems = {}, {}
				for _, ax in T.axes do
					table.insert(aitems, { label = ax, checked = ax == a.axis, on_click = function()
						set_action(function(a2: any)
							if a2.axis ~= ax then
								a2.axis = ax
								local vals = T.themes[ax]
								a2.value = if type(vals) == "table" then (vals[2] or vals[1]) else nil
							end
						end)
					end })
				end
				local vals = T.themes[a.axis]
				for _, v in (if type(vals) == "table" then vals else {}) do
					table.insert(vitems, { label = v, checked = v == a.value, on_click = function()
						set_action(function(a2: any)
							a2.value = v
						end)
					end })
				end
				if #aitems == 0 then
					table.insert(aitems, { label = "No modes yet: add a Theme in Variables", on_click = function() end })
				end
				local bad_axis = err ~= nil and type(vals) ~= "table"
				table.insert(
					body,
					checked(
						Kit.pair(
							dropdown {
								id = `ia-axis-{sfx}`,
								label = "Mode axis",
								leading = lead_icon("layers", if bad_axis then L.danger else nil),
								value = function(): string
									return if a.axis == MIXED then "Mixed" else a.axis or "Axis"
								end,
								fg = if bad_axis then L.danger else nil,
								items = aitems,
								menu_w = 180,
							},
							dropdown {
								id = `ia-mode-{sfx}`,
								label = "Mode",
								leading = lead_icon(if a.value == "dark" then "moon" else "sun", if err and not bad_axis then L.danger else nil),
								value = function(): string
									return if a.value == MIXED then "Mixed" else a.value or "Mode"
								end,
								fg = if err and not bad_axis then L.danger else nil,
								items = if #vitems > 0 then vitems else { { label = "Choose an axis first", on_click = function() end } },
								menu_w = 180,
							}
						),
						err
					)
				)
			elseif kind == "if" then
				local err = if a.cond == MIXED then nil else PV.check_cond(T, a.cond)
				table.insert(
					body,
					checked(
						Kit.field(L, {
							id = `ia-cond-{sfx}`,
							tip = "If: a true/false expression, as count > 0 and agree",
							leading = ui.div { w = 28, min_w = 28, shrink = 0, h_full = true, pl = 8, justify = "center", ui.text { "if", text_size = 12, weight = 500, color = if err then L.danger else L.accent_fg, font = Look.UI } },
							value = function(): string?
								return if a.cond == MIXED then nil else PV.cond_text(a.cond)
							end,
							placeholder = "count > 0",
							mono = true,
							fg = if err then L.danger else nil,
							outline = if err then L.danger else nil,
							commit = function(t: string)
								set_action(function(a2: any)
									a2.cond = PV.parse_cond(t)
								end)
							end,
						}),
						err
					)
				)
				-- Then / Else: each its own list, its own "+", the same rows
				-- inside (at most 3 levels shown; deeper ones fold to a line)
				for _, br in { "then", "else" } do
					local sub = if type(a[br]) == "table" then a[br] else {}
					local bsfx = `{sfx}-{string.sub(br, 1, 1)}`
					local bpath = table.clone(path)
					table.insert(bpath, br)
					-- (F6 C2) the layers' branches differ: read-only, said in a line
					if a[br] == MIXED then
						table.insert(body, ui.row {
							id = `ia-br-{bsfx}`,
							w_full = true,
							h = 20,
							gap = 6,
							items = "center",
							Kit.text(L, if br == "then" then "Then" else "Else", { weight = 500, color = L.muted }),
							Kit.text(L, "Mixed", { color = L.faint }),
						})
						table.insert(body, note("These actions differ between the layers. Select one layer to edit them.", `ia-br-mixed-{bsfx}`))
						continue
					end
					local function add()
						local f = if #T.names > 0 then PV.fresh(T, "set") else { action = "navigate", to = screens[1] and screens[1].id, transition = { type = "dissolve", duration = 300, easing = "ease-out" } }
						mod(i, function(r: any): boolean?
							r.actions = r.actions or {}
							if multi and type(r.actions[path[1]]) ~= "table" then
								return false
							end
							local lst, k = dig(r.actions, path)
							local me = lst[k]
							me[br] = if type(me[br]) == "table" then me[br] else {}
							table.insert(me[br], deep(f))
							return nil
						end, "Add action")
					end
					local head = ui.row {
						id = `ia-br-{bsfx}`,
						w_full = true,
						h = 20,
						gap = 6,
						items = "center",
						Kit.text(L, if br == "then" then "Then" else "Else", { weight = 500, color = L.muted }),
						if #sub == 0 then Kit.text(L, "nothing", { color = L.faint }) else ui.div {},
						ui.div { grow = 1 },
						if inh_ia then ui.div {} else act("plus", if br == "then" then "Add an action when it's true" else "Add an action when it's false", add, `ia-br-add-{bsfx}`),
					}
					local inner: { Node } = {}
					-- the branch's rows: each action with its remove, the same rows inside
					local items: { Node } = {}
					for k, sa in sub do
						local npath = table.clone(bpath)
						table.insert(npath, k)
						local nsfx = `{bsfx}{k}`
						if k > 1 or not inh_ia then
							table.insert(
								items,
								ui.row {
									id = `ia-then-{nsfx}`,
									w_full = true,
									h = 16,
									gap = 6,
									items = "center",
									if k > 1 then Kit.text(L, "Then", { color = L.faint }) else ui.div {},
									ui.div { grow = 1 },
									if inh_ia then ui.div {} else act("minus", "Remove this action", function()
										path_remove(npath)
									end, `ia-act-remove-{nsfx}`),
								}
							)
						end
						action_block(items, sa, nsfx, function(fn: (a: any) -> ())
							path_set(npath, fn)
						end, npath, depth + 1)
					end
					if depth + 1 >= 3 and #sub > 0 then
						-- (deeper than 3 levels: one line, unfolded on click)
						local open = ui.use_state(false)
						local c2: any = { w_full = true, gap = 6 }
						for _, n in items do
							table.insert(c2, n)
						end
						table.insert(inner, ui.show(function(): boolean
							return not open:get()
						end, ui.button {
							id = `ia-fold-{bsfx}`,
							label = "Show these actions",
							w_full = true,
							h = 24,
							px = 8,
							rounded = 6,
							border = 0,
							bg = L.field,
							hover = { bg = L.field_active },
							items = "center",
							on_click = function()
								open:set(true)
							end,
							ui.text { PV.summary(sub), text_size = 11, color = L.muted, font = Look.UI, grow = 1, truncate = true, min_w = 0 },
							ui.div { shrink = 0, color = L.faint, Kit.icon("chev", 12) },
						}))
						table.insert(inner, ui.show(function(): boolean
							return open:get()
						end, ui.column(c2)))
					else
						inner = items
					end
					table.insert(body, head)
					if #inner > 0 then
						local c: any = { id = `ia-list-{bsfx}`, w_full = true, gap = 6, pl = 8, border_sides = { 0, 0, 0, 2 }, border_color = L.border }
						for _, n in inner do
							table.insert(c, n)
						end
						table.insert(body, ui.column(c))
					end
				end
			end
		end
		end -- (action_block)
		-- (step 2: every action, in order; each runs after the one before it)
		for j = 1, math.max(1, #(x.actions or {})) do
			local a = (x.actions or {})[j] or { action = "navigate" }
			local sfx = if j == 1 then tostring(i) else `{i}-{j}`
			if j > 1 then
				table.insert(
					body,
					ui.row {
						id = `ia-then-{sfx}`,
						w_full = true,
						h = 20,
						gap = 6,
						items = "center",
						Kit.text(L, "Then", { color = L.muted }),
						ui.div { grow = 1 },
						if inh_ia then ui.div {} else act("minus", "Remove this action", function()
							mod(i, function(r: any): boolean?
								if type(r.actions) ~= "table" or r.actions[j] == nil then
									return false
								end
								table.remove(r.actions, j)
								return nil
							end, "Remove action")
						end, `ia-act-remove-{sfx}`),
					}
				)
			end
			action_block(body, a, sfx, function(fn: (a: any) -> ())
				path_set({ j }, fn)
			end, { j }, 0)
		end
		-- the trigger (step 2: Figma's), and its delay or key
		local TRIG = {
			{ "click", "On click", "click" },
			{ "hover", "While hovering", "move" },
			{ "press", "While pressing", "click" },
			{ "mouseEnter", "Mouse enter", "move" },
			{ "mouseLeave", "Mouse leave", "move" },
			{ "mouseDown", "Mouse down", "click" },
			{ "mouseUp", "Mouse up", "click" },
			{ "afterDelay", "After delay", "clock" },
			{ "key", "Key", "keyboard" },
			{ "drag", "On drag", "swap" },
		}
		local tname = if type(x.trigger) == "table" then x.trigger.type else (x.trigger or "click")
		local function set_trigger(fn: (r: any) -> ())
			mod(i, function(r: any): boolean?
				fn(r)
				return nil
			end, "Change trigger")
		end
		local titems = {}
		local tlabel, ticon = "On click", "click"
		for _, o in TRIG do
			if o[1] == tname then
				tlabel, ticon = o[2], o[3]
			end
			table.insert(titems, { label = o[2], checked = o[1] == tname, on_click = function()
				set_trigger(function(r: any)
					r.trigger = if o[1] == "afterDelay" then { type = "afterDelay", ms = 800 } elseif o[1] == "key" then { type = "key", keys = "ArrowRight" } else o[1]
				end)
			end })
		end
		local tfield: Node? = nil
		local mouse = tname == "mouseEnter" or tname == "mouseLeave" or tname == "mouseDown" or tname == "mouseUp"
		if tname == "afterDelay" or mouse then
			local after = tname == "afterDelay"
			tfield = Kit.num(L, {
				id = `ia-delay-{i}`,
				tip = if after then "Delay (ms)" else "Delay: the pointer stays (ms)",
				icon = "clock",
				unit = "ms",
				min = 0,
				max = 60000,
				step = 100,
				get = function(): number?
					if type(x.trigger) ~= "table" then
						return 0
					end
					return tonumber(if after then x.trigger.ms else x.trigger.delay) or 0
				end,
				set = function(v: number)
					local ms = math.clamp(math.floor(v + 0.5), 0, 60000)
					set_trigger(function(r: any)
						if after then
							r.trigger = { type = "afterDelay", ms = ms }
						else
							r.trigger = if ms > 0 then { type = tname, delay = ms } else tname
						end
					end)
				end,
			})
		elseif tname == "key" then
			local keys = if type(x.trigger) == "table" then x.trigger.keys else nil
			local ktext = if type(keys) == "table" then table.concat(keys, "+") else tostring(keys or "")
			tfield = Kit.field(L, {
				id = `ia-key-{i}`,
				tip = "Key, as Enter, ArrowRight, k or Shift+D",
				leading = lead_icon("keyboard"),
				value = function(): string?
					return ktext
				end,
				mono = false,
				commit = function(text: string)
					local parts = {}
					for part in string.gmatch(text, "[^+%s]+") do
						table.insert(parts, part)
					end
					if #parts == 0 then
						return
					end
					set_trigger(function(r: any)
						r.trigger = { type = "key", keys = if #parts == 1 then parts[1] else parts }
					end)
				end,
			})
		end
		-- (F6 C3) the trigger icon picks the row (a selected interaction, for
		-- Ctrl+C / X / Delete); its menu has Copy, Cut and Paste
		local pick_btn = ui.presence(function(): string
			return if picked(i) then "on" else "off"
		end, function(st: string): Node
			local on = st == "on"
			return ui.button {
				id = `ia-pick-{i}`,
				label = if on then "Deselect interaction" else "Select interaction",
				tooltip = "Select (then Ctrl+C to copy)",
				w = 24,
				h = 28,
				p = 0,
				shrink = 0,
				rounded = 6,
				border = if on then 1 else 0,
				border_color = L.accent,
				items = "center",
				justify = "center",
				bg = if on then L.accent_soft else L.field,
				hover = { bg = if on then L.accent_soft else L.field_active },
				color = if on then L.accent_fg else L.faint,
				on_click = function()
					pick(i, not on)
				end,
				Kit.icon(ticon, 13),
			}
		end, { shrink = 0 })
		local menu_open = ui.use_state(false)
		local mitems: { Node } = {
			Kit.menu_item(L, { label = "Copy", shortcut = "Ctrl C", on_click = function()
				local r = row_record(i)
				if r then
					IaClip.put({ r })
					pick(i, true)
				end
			end }),
		}
		if not inh_ia then
			table.insert(mitems, Kit.menu_item(L, { label = "Cut", shortcut = "Ctrl X", on_click = function()
				local r = row_record(i)
				if r then
					IaClip.put({ r })
					remove_ia(i)
				end
			end }))
		end
		table.insert(mitems, Kit.menu_item(L, { label = "Paste", shortcut = "Ctrl V", disabled = not IaClip.has(), on_click = paste_here }))
		local mp: any = {
			open = menu_open,
			label = "Interaction menu",
			anchor = act("dots", "Interaction menu: Copy, Cut, Paste", function()
				menu_open:set(not menu_open:peek())
			end, `ia-more-{i}`),
		}
		for _, it in mitems do
			table.insert(mp, it)
		end
		for k2, v2 in Kit.pop_style(L) do
			mp[k2] = v2
		end
		mp.w = 180
		local trig = ui.row {
			w_full = true,
			h = 28,
			gap = 6,
			items = "center",
			pick_btn,
			ui.div { grow = 1, min_w = 0, dropdown {
				id = `ia-trigger-{i}`,
				label = "Trigger",
				value = function(): string
					return tlabel
				end,
				items = titems,
				menu_w = 180,
			} },
			ui.menu(mp),
			if inh_ia then ui.div {} else act("plus", "Add an action (it runs after the ones before it)", function()
				mod(i, function(r: any): boolean?
					r.actions = r.actions or {}
					local last = r.actions[#r.actions]
					local to = if last and last.action == "navigate" then last.to else (screens[1] and screens[1].id)
					table.insert(r.actions, { action = "navigate", to = to, transition = { type = "dissolve", duration = 300, easing = "ease-out" } })
					return nil
				end, "Add action")
			end, `ia-act-add-{i}`),
			if inh_ia then ui.div {} else act("minus", "Remove interaction", function()
				remove_ia(i)
			end, `ia-remove-{i}`),
		}
		local col: any = { id = `ia-{i}`, w_full = true, gap = 6, trig }
		-- (F6 C2) a row only some of the layers have says how many
		if multi and mrows[i] and not mrows[i].all then
			table.insert(col, note(`On {#mrows[i].layers} of {#sel} layers`, `ia-some-{i}`))
		end
		-- (F6 C2) Figma's "Select N matching interactions": the same
		-- interaction on layers with the same name path in the other Screens
		if not multi then
			local k = Match.scene_k(list, i)
			local found = if k then Match.matching(source.roots:peek(), id, k) else {}
			if #found >= 2 then
				table.insert(col, ui.button {
					id = `ia-match-{i}`,
					label = `Select {#found} matching interactions`,
					w_full = true,
					h = 24,
					px = 8,
					gap = 6,
					rounded = 6,
					border = 0,
					bg = L.field,
					hover = { bg = L.field_active },
					items = "center",
					on_click = function()
						select_matching(found)
					end,
					ui.div { shrink = 0, color = L.accent_fg, Kit.icon("target", 12) },
					ui.text { `Select {#found} matching interactions`, text_size = 11, color = L.accent_fg, font = Look.UI, grow = 1, truncate = true, min_w = 0 },
				})
			end
		end
		if tfield then
			table.insert(col, tfield)
		end
		for _, b in body do
			table.insert(col, b)
		end
		table.insert(ia_rows, dim(ui.column(col), inh_ia))
	end
	local ia_actions: { Node } = {
		act("plus", "Add interaction", function()
			-- (the next Screen after the one holding it, as Figma's default)
			local function fresh(lid: string): any
				local target = nil
				local mine = nil
				for _, r in source.roots:peek() do
					for _, it in r.nodes or {} do
						if it.id == lid then
							mine = r.id
						end
					end
				end
				for k, sc in screens do
					if sc.id == mine then
						target = screens[k + 1] or screens[1]
					end
				end
				target = target or screens[1]
				return { trigger = "click", actions = { { action = "navigate", to = target and target.id, transition = { type = "dissolve", duration = 300, easing = "ease-out" } } } }
			end
			if not multi then
				local l = deep(list)
				table.insert(l, fresh(id))
				put_ia(l, "Add interaction")
				return
			end
			-- (several layers: each gets one, so it's a new row on all of them)
			local ops = {}
			for _, si in sel do
				local l = deep(lists[si.id])
				table.insert(l, fresh(si.id))
				table.insert(ops, { op = "update", id = si.id, props = { interactions = l } })
			end
			source.edit(ops, "Add interaction")
		end, "ia-add"),
	}
	if not multi and own_ia ~= nil and is_inst and type(resolved.interactions) == "table" then
		table.insert(ia_actions, 1, act("undo", "Reset to Component", function()
			edit({ interactions = "__null" }, "Reset interactions")
		end, "ia-reset"))
	end
	if #list == 0 then
		table.insert(ia_rows, Kit.text(L, if multi then "Click + to add one to every selected layer." else "Click + to make it go to another Screen.", { color = L.faint }))
	end
	-- (F6 C2) several layers: their interactions only (States, scrolling and
	-- the overlay settings are one layer's; select one to see them)
	if multi then
		return ui.column {
			w_full = true,
			ui.row {
				id = "multi-head",
				w_full = true,
				p = 12,
				gap = 6,
				items = "center",
				Kit.text(L, `{#sel} layers`, { weight = 500, color = L.fg, grow = 1, truncate = true }),
			},
			sec("Interactions", ia_actions, ia_rows, { id = "ia-head", note = "edits apply to all" }),
			ui.div { w_full = true, px = 12, pb = 12, note("States, scrolling and overlay settings show for one layer at a time.") },
		}
	end

	-- States
	local own_st = node.states
	local inh_st = own_st == nil and is_inst and type(resolved.states) == "table"
	local states = deep(if own_st ~= nil then own_st elseif inh_st then resolved.states else {})
	if type(states) ~= "table" then
		states = {}
	end
	local function put_st(st: any, label: string)
		local any = st.hover ~= nil or st.press ~= nil
		edit({ states = if any then st else "__null" }, label)
	end
	local function look_rows(which: string, get: () -> any, set: (fn: (t: any) -> ()) -> (), prefix: string, with_scale: boolean): { Node }
		local t = get() or {}
		local rows: { Node } = {}
		table.insert(
			rows,
			color_field {
				id = `{prefix}-fill`,
				title = "Fill",
				paint = t.fill,
				commit = function(np: any)
					set(function(x: any)
						x.fill = np
					end)
				end,
			}
		)
		local stroke_paint = if type(t.stroke) == "table" then t.stroke.fill else nil
		table.insert(
			rows,
			color_field {
				id = `{prefix}-stroke`,
				title = "Stroke",
				paint = stroke_paint,
				commit = function(np: any)
					set(function(x: any)
						local st = if type(x.stroke) == "table" then x.stroke else { thickness = 1, align = "inside" }
						st.fill = np
						x.stroke = st
					end)
				end,
			}
		)
		local function num(key: string, tip: string, icon: string, unit: string?, scale: number, min: number, max: number): Node
			-- Unset: the field empty, its name greyed (not "Mixed").
			if tonumber(resolve(t[key])) == nil then
				return Kit.field(L, {
					id = `{prefix}-{key}`,
					tip = tip,
					icon = icon,
					unit = unit,
					placeholder = tip,
					value = function(): string?
						return ""
					end,
					commit = function(text: string)
						local v = tonumber(text)
						if v then
							set(function(x: any)
								x[key] = math.clamp(v / scale, min, max)
							end)
						end
					end,
				})
			end
			return Kit.num(L, {
				id = `{prefix}-{key}`,
				tip = tip,
				icon = icon,
				unit = unit,
				min = min * scale,
				max = max * scale,
				get = function(): number?
					local v = tonumber(resolve(t[key]))
					return if v then math.floor(v * scale * 100 + 0.5) / 100 else nil
				end,
				set = function(v: number)
					set(function(x: any)
						x[key] = math.clamp(v / scale, min, max)
					end)
				end,
			})
		end
		table.insert(rows, Kit.pair(num("opacity", "Opacity", "opacity", "%", 100, 0, 1), if with_scale then num("scale", "Scale", "corners", nil, 1, 0.5, 2) else num("cornerRadius", "Corner radius", "radius", nil, 1, 0, 1000)))
		if with_scale then
			table.insert(rows, num("cornerRadius", "Corner radius", "radius", nil, 1, 0, 1000))
		end
		return rows
	end
	local st_rows: { Node } = {}
	local open_state = ui.use_state({ hover = true, press = true } :: { [string]: boolean })
	for _, pair in { { "hover", "Hover" }, { "press", "Pressed" } } do
		local which, title = pair[1], pair[2]
		local st = states[which]
		local function set(fn: (x: any) -> ())
			local s2 = deep(states)
			s2[which] = s2[which] or {}
			fn(s2[which])
			put_st(s2, `Change {string.lower(title)} state`)
		end
		local head = ui.row {
			id = `state-{which}`,
			w_full = true,
			h = 20,
			gap = 6,
			items = "center",
			cursor = if st then "pointer" else nil,
			on_click = if st then function()
				open_state:set_key({ which }, not open_state:peek()[which])
			end else nil,
			ui.div { color = L.faint, Kit.icon(if st and open_state:peek()[which] then "chevDown" else "chev", 12) },
			Kit.text(L, title, { color = if st then L.fg else L.muted, weight = 500 }),
			ui.div { grow = 1 },
			if st
				then act("minus", `Remove {string.lower(title)} state`, function()
					local s2 = deep(states)
					s2[which] = nil
					put_st(s2, `Remove {string.lower(title)} state`)
				end, `state-{which}-remove`)
				else act("plus", `Add {string.lower(title)} state`, function()
					local s2 = deep(states)
					-- (a start that reads as a state: a little darker, pressed smaller)
					s2[which] = if which == "press" then { scale = 0.97 } else { opacity = 0.9 }
					put_st(s2, `Add {string.lower(title)} state`)
				end, `state-{which}-add`),
		}
		local col: any = { w_full = true, gap = 6, head }
		if st and open_state:peek()[which] then
			for _, r in look_rows(which, function(): any
				return st
			end, set, `state-{which}`, true) do
				table.insert(col, r)
			end
			-- Layers inside, recoloured with it (`descendants`).
			for name, dst in st.descendants or {} do
				table.insert(
					col,
					ui.row {
						w_full = true,
						h = 20,
						gap = 6,
						items = "center",
						pl = 8,
						ui.div { color = L.faint, Kit.icon("text", 12) },
						Kit.text(L, tostring(name), { color = L.muted, truncate = true }),
						ui.div { grow = 1 },
						act("minus", `Stop changing {name}`, function()
							set(function(x: any)
								x.descendants[name] = nil
								if next(x.descendants) == nil then
									x.descendants = nil
								end
							end)
						end),
					}
				)
				local sub = look_rows(which, function(): any
					return dst
				end, function(fn: (x: any) -> ())
					set(function(x: any)
						x.descendants = x.descendants or {}
						x.descendants[name] = x.descendants[name] or {}
						fn(x.descendants[name])
					end)
				end, `state-{which}-d-{name}`, false)
				table.insert(col, ui.column { w_full = true, gap = 6, pl = 8, sub[1] })
			end
			local kids = inside(id)
			if #kids > 0 then
				local items = {}
				for _, k in kids do
					local key = k.name
					if not (st.descendants and st.descendants[key]) then
						table.insert(items, { label = key, on_click = function()
							set(function(x: any)
								x.descendants = x.descendants or {}
								x.descendants[key] = { fill = "#FFFFFF" }
							end)
						end })
					end
					if #items >= 30 then
						break
					end
				end
				if #items > 0 then
					table.insert(
						col,
						dropdown {
							id = `state-{which}-inside`,
							label = "Change a layer inside",
							leading = lead_icon("plus"),
							value = function(): string
								return "Layer inside"
							end,
							items = items,
						}
					)
				end
			end
		end
		table.insert(st_rows, dim(ui.column(col), inh_st))
	end
	if states.hover or states.press then
		local t = states.transition or {}
		local eitems = {}
		for _, e in Proto.EASINGS do
			table.insert(eitems, { label = e.label, checked = Proto.ease_label(t.easing or "ease-out") == e.label, on_click = function()
				local s2 = deep(states)
				s2.transition = s2.transition or {}
				s2.transition.easing = e.name
				put_st(s2, "Change state transition")
			end })
		end
		table.insert(
			st_rows,
			dim(
				ui.column {
					w_full = true,
					gap = 6,
					Kit.text(L, "Transition", { color = L.muted }),
					Kit.pair(
						Kit.num(L, {
							id = "state-ms",
							tip = "State transition (ms)",
							icon = "clock",
							unit = "ms",
							min = 0,
							max = 5000,
							step = 10,
							get = function(): number?
								return tonumber(t.duration) or 150
							end,
							set = function(v: number)
								local s2 = deep(states)
								s2.transition = s2.transition or {}
								s2.transition.duration = math.clamp(math.floor(v + 0.5), 0, 5000)
								put_st(s2, "Change state transition")
							end,
						}),
						dropdown {
							id = "state-ease",
							label = "State easing",
							value = function(): string
								return Proto.ease_label(t.easing or "ease-out")
							end,
							items = eitems,
						}
					),
				},
				inh_st
			)
		)
	end
	local st_actions: { Node } = {}
	if own_st ~= nil and is_inst and type(resolved.states) == "table" then
		table.insert(st_actions, act("undo", "Reset to Component", function()
			edit({ states = "__null" }, "Reset states")
		end, "state-reset"))
	end

	-- (step 4, F4b) an Instance of a variant set: its member, by property
	-- (Update(inst, { props }) picks the member that matches best)
	local var_rows: { Node } = {}
	if vctx and vctx.own then
		local names, values, cur = {}, {}, {}
		for _, m in vctx.members do
			for k, v in m.props or {} do
				if not values[k] then
					values[k] = {}
					table.insert(names, k)
				end
				if not table.find(values[k], v) then
					table.insert(values[k], v)
				end
				if m.id == vctx.member then
					cur[k] = v
				end
			end
		end
		table.sort(names)
		-- (step 5, V5b) a property bound to a variable (the Instance's
		-- `props = { On = "$isOn" }`, two-way in Play): a chip, whose detach
		-- keeps the member shown; else Apply variable beside the dropdown
		-- (text and true/false variables, as Figma's)
		local own_props = if is_inst and vctx.instance == id and type(node.props) == "table" then node.props else {}
		local bvars = Bind.vars(props.tokens)
		local function put_prop(k: string, v: any, label: string)
			local p2 = table.clone(own_props)
			p2[k] = v
			edit({ props = p2 }, label)
		end
		for _, k in names do
			local items = {}
			for _, v in values[k] do
				table.insert(items, { label = tostring(v), checked = cur[k] == v, on_click = function()
					if vctx.instance then
						put_prop(k, v, "Change variant")
					end
				end })
			end
			local bound = Bind.ref(own_props[k])
			local function bind_to(name: string)
				put_prop(k, "$" .. name, "Apply variable")
			end
			if bound and vctx.instance then
				local kind = Bind.kind_of(bvars, bound)
				table.insert(var_rows, Bind.chip(L, {
					id = `var-prop-{k}-chip`,
					what = k,
					label = k,
					name = bound,
					kind = kind,
					value = T.first[bound],
					vars = bvars,
					kinds = { "string", "boolean" },
					pick = bind_to,
					detach = function()
						put_prop(k, tostring(if cur[k] ~= nil then cur[k] else T.first[bound]), "Detach variable")
					end,
				}))
			else
				local dd = dropdown {
					id = `var-prop-{k}`,
					label = k,
					leading = lead_icon("component"),
					value = function(): string
						return `{k}: {tostring(cur[k] or "")}`
					end,
					items = if vctx.instance then items else {},
				}
				table.insert(var_rows, dim(
					if vctx.instance
						then ui.row {
							w_full = true,
							gap = 4,
							items = "center",
							ui.div { grow = 1, min_w = 0, dd },
							Bind.button(L, { id = `var-prop-{k}-bind`, what = k, kinds = { "string", "boolean" }, vars = bvars, pick = bind_to }),
						}
						else dd,
					vctx.instance == nil
				))
			end
		end
	end

	local col: any = {
		w_full = true,
		ui.row {
			w_full = true,
			p = 12,
			gap = 6,
			items = "center",
			Kit.text(L, node.name or id, { weight = 500, color = L.fg, grow = 1, truncate = true }),
		},
	}
	if #var_rows > 0 then
		table.insert(col, sec("Variant", nil, var_rows, { id = "variant-head", note = vctx.set }))
	end
	-- (step 6) a Screen selected: Figma's "Flow starting point": the flows that
	-- start here (title, description, remove), or + to start one here.
	if screen_name[id] then
		local flows = deep(source.flows and source.flows:peek() or {})
		local function put_flows(l: { any }, label: string)
			source.edit({ { op = "flows", flows = if #l > 0 then l else "__null" } }, label)
		end
		local fs_rows: { Node } = {}
		for i, f in flows do
			if f.start == id then
				table.insert(fs_rows, ui.column {
					id = `fsp-{i}`,
					w_full = true,
					gap = 6,
					ui.row {
						w_full = true,
						gap = 6,
						items = "center",
						ui.div { grow = 1, min_w = 0, Kit.field(L, {
							id = `fsp-name-{i}`,
							tip = "Flow name",
							leading = lead_icon(if i == 1 then "play" else "flow", if i == 1 then L.accent_fg else nil),
							value = function(): string?
								return f.name
							end,
							mono = false,
							commit = function(t: string)
								if t ~= "" and t ~= f.name then
									local l = deep(flows)
									l[i].name = t
									put_flows(l, "Rename flow")
								end
							end,
						}) },
						act("minus", "Remove flow", function()
							local l = deep(flows)
							table.remove(l, i)
							put_flows(l, "Remove flow")
						end, `fsp-remove-{i}`),
					},
					desc_box(`fsp-desc-{i}`, f.description, function(t: string)
						local l = deep(flows)
						l[i].description = if t == "" then nil else t
						put_flows(l, "Flow description")
					end),
				})
			end
		end
		local add = act("plus", "Add flow starting point", function()
			local l = deep(flows)
			table.insert(l, { name = `Flow {#l + 1}`, start = id })
			put_flows(l, "Add flow")
		end, "fsp-add")
		table.insert(col, sec("Flow starting point", { add }, fs_rows, { id = "fsp-head" }))
	end
	table.insert(col, sec("Interactions", ia_actions, ia_rows, { id = "ia-head", note = if inh_ia then "from Component" else nil }))
	table.insert(col, sec("States", st_actions, st_rows, { id = "states-head", note = if inh_st then "from Component" else nil }))
	table.insert(col, scroll_section(s))
	table.insert(col, overlay_section(s))
	return ui.column(col)
end

return M
