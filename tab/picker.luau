--!strict
-- The hand cursor on clickable controls (zgx's ui is read-only: see pointer.luau).
local ui = require("./pointer").ui
-- The paint picker (the redesign's Board · Paint picker): a solid popover
-- 264 wide (p12, r12, gap 10); a top strip of three icon tabs (Solid /
-- Gradient / Image) and a close button; Solid: a 180-high spectrum, 12-high
-- hue and alpha strips with ring knobs, the eyedropper and a format dropdown
-- (Hex / RGBA), its fields, then the Design's colour variables; Gradient: a
-- preview, its type, rotation and stops; Image: a preview, URL and mode.
-- A paint is the file's (`"#RRGGBBAA"`, `"$token"`,
-- `{ type = "gradient" | "image", … }`); `commit(paint, live)` sends it, live
-- while a knob moves (joined into one undo step by the caller).

local Kit = require("./kit")
local Look = require("./look")

local M = {}

-- Colours ------------------------------------------------------------------------------

export type RGBA = { r: number, g: number, b: number, a: number }

function M.parse(c: any): RGBA?
	if type(c) ~= "string" or string.sub(c, 1, 1) ~= "#" then
		return nil
	end
	local h = string.sub(c, 2)
	if #h == 3 or #h == 4 then
		h = string.gsub(h, ".", "%0%0")
	end
	if #h == 6 then
		h ..= "ff"
	end
	if #h ~= 8 then
		return nil
	end
	local r, g, b, a = tonumber(string.sub(h, 1, 2), 16), tonumber(string.sub(h, 3, 4), 16), tonumber(string.sub(h, 5, 6), 16), tonumber(string.sub(h, 7, 8), 16)
	if not (r and g and b and a) then
		return nil
	end
	return { r = r, g = g, b = b, a = a / 255 }
end

function M.hex(c: RGBA, alpha: boolean?): string
	local s = string.format("#%02X%02X%02X", math.floor(c.r + 0.5), math.floor(c.g + 0.5), math.floor(c.b + 0.5))
	if alpha ~= false and c.a < 0.999 then
		s ..= string.format("%02X", math.floor(c.a * 255 + 0.5))
	end
	return s
end

local function to_hsv(c: RGBA): (number, number, number)
	local r, g, b = c.r / 255, c.g / 255, c.b / 255
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	local d = mx - mn
	local h = 0
	if d > 0 then
		if mx == r then
			h = ((g - b) / d) % 6
		elseif mx == g then
			h = (b - r) / d + 2
		else
			h = (r - g) / d + 4
		end
		h *= 60
	end
	return h, if mx == 0 then 0 else d / mx, mx
end

local function from_hsv(h: number, s: number, v: number, a: number): RGBA
	local c = v * s
	local x = c * (1 - math.abs((h / 60) % 2 - 1))
	local m = v - c
	local r, g, b = 0, 0, 0
	if h < 60 then
		r, g, b = c, x, 0
	elseif h < 120 then
		r, g, b = x, c, 0
	elseif h < 180 then
		r, g, b = 0, c, x
	elseif h < 240 then
		r, g, b = 0, x, c
	elseif h < 300 then
		r, g, b = x, 0, c
	else
		r, g, b = c, 0, x
	end
	return { r = (r + m) * 255, g = (g + m) * 255, b = (b + m) * 255, a = a }
end

-- A drag area: `move(fx, fy)` with the pointer's place as fractions of it.
local function drag_area(props: { [any]: any }, move: (fx: number, fy: number, done: boolean) -> ()): Node
	local down = false
	local w, h = 1, 1
	props.on_resize = function(s: any)
		w, h = math.max(1, s.w), math.max(1, s.h)
	end
	props.on_press = function(e: any)
		down = true
		move(math.clamp(e.local_x / w, 0, 1), math.clamp(e.local_y / h, 0, 1), false)
	end
	props.on_pointer_move = function(e: any)
		if down then
			move(math.clamp(e.local_x / w, 0, 1), math.clamp(e.local_y / h, 0, 1), false)
		end
	end
	props.on_release = function(e: any)
		if down then
			down = false
			move(math.clamp(e.local_x / w, 0, 1), math.clamp(e.local_y / h, 0, 1), true)
		end
	end
	return ui.div(props :: any)
end

-- A ring knob: 14px, a 2px white ring (the colour shows through).
local function knob(left: () -> any, top: any): Node
	return ui.div {
		absolute = true,
		w = 14,
		h = 14,
		ml = -7,
		mt = -7,
		rounded = 7,
		border = 2,
		border_color = "#ffffff",
		shadow = { blur = 2, color = "#00000073" },
		left = left,
		top = top,
		pointer_events = "none",
	}
end

local CHECKER = { size = 8, a = "#cccccc", b = "#ffffff" }

local function checker(w: any, h: number, rounded: number): Node
	-- (Two squares a cell, drawn by a canvas: no image needed.)
	return ui.canvas {
		absolute = true,
		left = 0,
		top = 0,
		w = w,
		h = h,
		draw = function(c: Canvas, cw: number, ch: number)
			c:rect(0, 0, cw, ch, CHECKER.b, rounded)
			local s = CHECKER.size
			for y = 0, math.ceil(ch / s) - 1 do
				for x = 0, math.ceil(cw / s) - 1 do
					if (x + y) % 2 == 0 then
						c:rect(x * s, y * s, math.min(s, cw - x * s), math.min(s, ch - y * s), CHECKER.a)
					end
				end
			end
		end,
	}
end

-- A segmented control as the board draws it: a 28 track (p2, r8, field),
-- segments h24 r6; the chosen one field_active, 12/500 fg; the rest 12/400
-- faint. `icon` options show an icon (14) instead of a word.
local function seg(L: any, o: { id: string?, value: () -> any, options: { { value: any, icon: string?, label: string?, tip: string? } }, commit: (v: any) -> (), grow: number? }): Node
	local r: any = { id = o.id, w_full = o.grow == nil, grow = o.grow, min_w = 0, h = 28, p = 2, gap = 2, rounded = 8, bg = L.field }
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
					return if on() then L.field_active else "#00000000"
				end,
				hover = { color = L.fg },
				focus = { outline = 0 },
				on_click = function()
					o.commit(opt.value)
				end,
				if opt.icon
					then Kit.icon(opt.icon, 14)
					else ui.text {
						opt.label or "",
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
	return ui.row(r)
end

-- A 28px square button on the field grey, its icon muted (close, eyedropper,
-- remove a stop).
local function square_btn(L: any, o: { id: string?, icon: string, label: string, on_click: () -> () }): Node
	return ui.button {
		id = o.id,
		label = o.label,
		w = 28,
		h = 28,
		min_w = 28,
		shrink = 0,
		p = 0,
		rounded = 8,
		border = 0,
		items = "center",
		justify = "center",
		bg = L.field,
		color = L.muted,
		hover = { bg = L.field_active, color = L.fg },
		focus = { outline = 0 },
		on_click = o.on_click,
		Kit.icon(o.icon, 14),
	}
end

-- A thin strip (hue, alpha): 12 high, r6, a 1px rim; the knob rides over
-- it unclipped.
local function strip(L: any, fill: { Node }, knob_node: Node, move: (fx: number, fy: number, done: boolean) -> ()): Node
	local inner: any = { absolute = true, left = 0, top = 0, right = 0, bottom = 0, rounded = 6, overflow = "hidden", pointer_events = "none" }
	for _, f in fill do
		table.insert(inner, f)
	end
	return drag_area({
		w_full = true,
		h = 12,
		my = 1,
		ui.div(inner),
		ui.div { absolute = true, left = 0, top = 0, right = 0, bottom = 0, rounded = 6, border = 1, border_color = L.border, pointer_events = "none" },
		knob_node,
	}, move)
end

-- The solid colour editor, on `color` (an RGBA state).
local function solid(L: any, color: any, commit: (c: RGBA, live: boolean) -> (), eyedrop: ((done: (hex: string) -> ()) -> ())?, close: (() -> ())?): Node
	local hsv = ui.use_state({ to_hsv(color:peek()) })
	local function set_hsv(h: number, s: number, v: number, live: boolean)
		hsv:set({ h, s, v })
		local c = from_hsv(h % 360, s, v, color:peek().a)
		color:set(c)
		commit(c, live)
	end
	local format = ui.use_state("RGBA")
	local format_open = ui.use_state(false)
	-- The format dropdown (Board · Menus, Dropdowns): a field with the value
	-- and a chevron; a solid menu under it, the chosen one checked.
	local format_menu: any = {
		open = format_open,
		label = "Colour format",
		anchor = ui.button {
			id = "picker-format",
			label = "Colour format",
			w_full = true,
			h = 28,
			px = 8,
			gap = 6,
			rounded = 8,
			border = 0,
			bg = function(): string
				return if format_open:get() then L.field_active else L.field
			end,
			hover = { bg = L.field_active },
			focus = { outline = 0 },
			items = "center",
			on_click = ui.toggle(format_open),
			ui.text { format, text_size = 12, color = L.fg, font = Look.UI, grow = 1 },
			Kit.icon("chevDown", 13, L.faint),
		},
	}
	-- (a row: a check before the chosen one, then its name)
	local function format_item(name: string): Node
		return ui.menu_item {
			label = name,
			on_click = function()
				format:set(name)
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
					w = 14,
					h = 14,
					shrink = 0,
					opacity = function(): number
						return if format:get() == name then 1 else 0
					end,
					Kit.icon("check", 14, L.fg),
				},
				ui.text { name, text_size = 12, color = L.fg, font = Look.UI, grow = 1 },
			},
		}
	end
	table.insert(format_menu, format_item("Hex"))
	table.insert(format_menu, format_item("RGBA"))
	for k2, v2 in Kit.pop_style(L) do
		format_menu[k2] = v2
	end
	format_menu.w = 120
	local function hex_row(): Node
		return ui.row {
			w_full = true,
			gap = 6,
			ui.div {
				grow = 1,
				min_w = 0,
				Kit.field(L, {
					id = "picker-hex",
					label = "#",
					tip = "Hex",
					value = function(): string?
						return string.sub(M.hex(color:get(), false), 2)
					end,
					commit = function(t: string)
						local c = M.parse("#" .. string.gsub(t, "#", ""))
						if c then
							c.a = color:peek().a
							color:set(c)
							hsv:set({ to_hsv(c) })
							commit(c, false)
						end
					end,
				}),
			},
			ui.div {
				w = 72,
				min_w = 72,
				shrink = 0,
				Kit.num(L, {
					id = "picker-opacity",
					tip = "Opacity",
					unit = "%",
					min = 0,
					max = 100,
					get = function(): number?
						return math.floor(color:get().a * 100 + 0.5)
					end,
					set = function(n: number)
						color:set_key({ "a" }, n / 100)
						local c = color:peek()
						commit(c, false)
					end,
				}),
			},
		}
	end
	return ui.column {
		w_full = true,
		gap = 10,
		-- the spectrum: saturation across, value down
		drag_area({
			id = "picker-spectrum",
			w_full = true,
			h = 180,
			cursor = "crosshair",
			ui.div {
				absolute = true,
				left = 0,
				top = 0,
				right = 0,
				bottom = 0,
				rounded = 8,
				overflow = "hidden",
				pointer_events = "none",
				bg = function(): string
					return M.hex(from_hsv(hsv:get()[1] % 360, 1, 1, 1), false)
				end,
				ui.div { absolute = true, left = 0, top = 0, w_full = true, h_full = true, gradient = { angle = 90, stops = { "#ffffffff", "#ffffff00" } } },
				ui.div { absolute = true, left = 0, top = 0, w_full = true, h_full = true, gradient = { angle = 180, stops = { "#00000000", "#000000ff" } } },
			},
			ui.div { absolute = true, left = 0, top = 0, right = 0, bottom = 0, rounded = 8, border = 1, border_color = L.border, pointer_events = "none" },
			knob(function(): any
				return `{hsv:get()[2] * 100}%`
			end, function(): any
				return `{(1 - hsv:get()[3]) * 100}%`
			end),
		}, function(fx: number, fy: number, done: boolean)
			local v = hsv:peek()
			set_hsv(v[1], fx, 1 - fy, not done)
		end),
		ui.column {
			w_full = true,
			gap = 8,
			strip(L, {
				ui.div { w_full = true, h_full = true, gradient = { angle = 90, stops = { "#ff0000", "#ffff00", "#00ff00", "#00ffff", "#0000ff", "#ff00ff", "#ff0000" } } },
			}, knob(function(): any
				return `{hsv:get()[1] / 360 * 100}%`
			end, "50%"), function(fx: number, _fy: number, done: boolean)
				local v = hsv:peek()
				set_hsv(fx * 359.9, v[2], v[3], not done)
			end),
			strip(L, {
				checker("100%", 12, 6),
				ui.div {
					absolute = true,
					left = 0,
					top = 0,
					w_full = true,
					h_full = true,
					gradient = function(): any
						local c = color:get()
						return { angle = 90, stops = { M.hex({ r = c.r, g = c.g, b = c.b, a = 0 }), M.hex({ r = c.r, g = c.g, b = c.b, a = 1 }, false) } }
					end,
				},
			}, knob(function(): any
				return `{color:get().a * 100}%`
			end, "50%"), function(fx: number, _fy: number, done: boolean)
				color:set_key({ "a" }, math.floor(fx * 100 + 0.5) / 100)
				local c = color:peek()
				commit(c, not done)
			end),
		},
		ui.row {
			w_full = true,
			gap = 6,
			items = "center",
			if eyedrop
				then square_btn(L, {
					id = "picker-eyedropper",
					icon = "pipette",
					label = "Pick a colour from the Canvas",
					on_click = function()
						if close then
							close()
						end
						(eyedrop :: any)(function(hex: string)
							local c = M.parse(hex)
							if c then
								color:set(c)
								hsv:set({ to_hsv(c) })
								commit(c, false)
							end
						end)
					end,
				})
				else ui.div {},
			ui.div { grow = 1, min_w = 0, ui.menu(format_menu) },
		},
		ui.presence(format, function(which: string): Node
			if which == "RGBA" then
				local function chan(k: string, label: string, max: number): Node
					return ui.div {
						grow = 1,
						basis = 0,
						min_w = 0,
						Kit.num(L, {
							id = `picker-{k}`,
							label = label,
							tip = label,
							min = 0,
							max = max,
							step = if k == "a" then 0.01 else 1,
							get = function(): number?
								local c = color:get()
								return if k == "a" then math.floor(c.a * 100 + 0.5) / 100 else math.floor(c[k] + 0.5)
							end,
							set = function(n: number)
								color:set_key({ k }, n)
								local c = color:peek()
								hsv:set({ to_hsv(c) })
								commit(c, false)
							end,
						}),
					}
				end
				return ui.row { w_full = true, gap = 4, chan("r", "R", 255), chan("g", "G", 255), chan("b", "B", 255), chan("a", "A", 1) }
			end
			return hex_row()
		end, { w_full = true }),
	}
end

export type PickerProps = {
	L: any,
	paint: any, -- the file's paint, as written
	resolve: (v: any) -> any, -- a Token's value
	tokens: { { name: string, value: string } }, -- colour variables
	commit: (paint: any, live: boolean) -> (),
	-- Picks a colour off the Canvas (no screen sampling in zgx: the Design's
	-- own colour under the pointer).
	eyedrop: ((done: (hex: string) -> ()) -> ())?,
	-- Closes the picker (the eyedropper does, so the Canvas takes the click;
	-- and the ✕).
	close: (() -> ())?,
}

function M.Picker(props: PickerProps): Node
	local L = props.L
	local p = props.paint
	local kind0 = if type(p) == "table" and p.type == "gradient" then "gradient" elseif type(p) == "table" and p.type == "image" then "image" else "solid"
	local tab = ui.use_state(kind0)
	local function first_color(): RGBA
		local c = props.resolve(p)
		if type(c) == "table" and c.type == "gradient" and c.colors and c.colors[1] then
			c = props.resolve(c.colors[1].color)
		elseif type(c) == "table" and c.type == "color" then
			c = props.resolve(c.color)
		end
		return M.parse(c) or { r = 0, g = 0, b = 0, a = 1 }
	end
	local color = ui.use_state(first_color())
	local grad = ui.use_state(if type(p) == "table" and p.type == "gradient" then p else {
		type = "gradient",
		gradientType = "linear",
		rotation = 0,
		colors = { { color = M.hex(first_color()), position = 0 }, { color = M.hex({ r = 255, g = 255, b = 255, a = 1 }), position = 1 } },
	})
	local image = ui.use_state(if type(p) == "table" and p.type == "image" then p else { type = "image", url = "", mode = "cover" })

	local function switch_tab(value: any)
		tab:set(value)
		if value == "gradient" then
			props.commit(grad:peek(), false)
		elseif value == "solid" then
			props.commit(M.hex(color:peek()), false)
		elseif value == "image" and image:peek().url ~= "" then
			props.commit(image:peek(), false)
		end
	end

	local function sub_title(s: string): Node
		return ui.text { s, text_size = 12, weight = 500, color = L.faint, font = Look.UI }
	end

	local function gradient_editor(): Node
		return ui.column {
			w_full = true,
			gap = 10,
			-- a preview of it
			ui.div {
				w_full = true,
				h = 24,
				rounded = 6,
				ui.div { absolute = true, left = 0, top = 0, right = 0, bottom = 0, rounded = 6, border = 1, border_color = L.border },
				gradient = function(): any
					-- (zgx spaces a gradient's stops evenly: sample the stops at
					-- 17 even places so their positions show.)
					local g = grad:get()
					local pts = {}
					for _, s in g.colors or {} do
						local c = M.parse(props.resolve(s.color))
						if c then
							table.insert(pts, { at = tonumber(props.resolve(s.position)) or 0, c = c })
						end
					end
					table.sort(pts, function(a: any, b: any): boolean
						return a.at < b.at
					end)
					if #pts == 0 then
						return { angle = 90, stops = { "#00000000", "#00000000" } }
					end
					local stops = {}
					local N = 16
					for k = 0, N do
						local t = k / N
						local a, b = pts[1], pts[#pts]
						for j = 1, #pts - 1 do
							if t >= pts[j].at and t <= pts[j + 1].at then
								a, b = pts[j], pts[j + 1]
								break
							end
						end
						local f = if t <= a.at then 0 elseif t >= b.at then 1 elseif b.at > a.at then (t - a.at) / (b.at - a.at) else 0
						if t < pts[1].at then
							a, b, f = pts[1], pts[1], 0
						elseif t > pts[#pts].at then
							a, b, f = pts[#pts], pts[#pts], 0
						end
						local function mix(x: number, y: number): number
							return x + (y - x) * f
						end
						table.insert(stops, M.hex({ r = mix(a.c.r, b.c.r), g = mix(a.c.g, b.c.g), b = mix(a.c.b, b.c.b), a = mix(a.c.a, b.c.a) }))
					end
					return { angle = 90, stops = stops }
				end,
			},
			seg(L, {
				id = "picker-gradient-type",
				value = function(): any
					return grad:get().gradientType or "linear"
				end,
				options = { { value = "linear", label = "Linear" }, { value = "radial", label = "Radial" }, { value = "angular", label = "Angular" } },
				commit = function(v: any)
					grad:set_key({ "gradientType" }, v)
					local g = grad:peek()
					props.commit(g, false)
				end,
			}),
			Kit.num(L, {
				id = "picker-rotation",
				label = "R",
				tip = "Rotation",
				unit = "°",
				get = function(): number?
					return props.resolve(grad:get().rotation) or 0
				end,
				set = function(n: number)
					grad:set_key({ "rotation" }, n % 360)
					local g = grad:peek()
					props.commit(g, false)
				end,
			}),
			ui.column {
				w_full = true,
				gap = 6,
				sub_title("Stops"),
				ui.each(ui.computed(function(): { any }
					local out = {}
					for i, s in grad:get().colors or {} do
						table.insert(out, { i = i, s = s })
					end
					return out
				end), function(row: any): Node
					local i = row.i
					local function set_stop(k: string, v: any)
						local g = table.clone(grad:peek())
						local colors = table.clone(g.colors)
						local s = table.clone(colors[i])
						s[k] = v
						colors[i] = s
						g.colors = colors
						grad:set(g)
						props.commit(g, false)
					end
					return ui.row {
						w_full = true,
						gap = 4,
						items = "center",
						ui.div {
							w = 64,
							min_w = 64,
							shrink = 0,
							Kit.num(L, {
								tip = "Position",
								unit = "%",
								min = 0,
								max = 100,
								get = function(): number?
									return math.floor((props.resolve(row.s.position) or 0) * 100 + 0.5)
								end,
								set = function(n: number)
									set_stop("position", n / 100)
								end,
							}),
						},
						ui.div {
							grow = 1,
							min_w = 0,
							Kit.field(L, {
								tip = "Stop colour",
								leading = ui.div {
									pl = 8,
									pr = 6,
									shrink = 0,
									ui.div {
										w = 16,
										h = 16,
										rounded = 4,
										border = 1,
										border_color = L.border,
										bg = props.resolve(row.s.color) or "#000000",
									},
								},
								value = function(): string?
									local c = M.parse(props.resolve(row.s.color))
									return if c then string.sub(M.hex(c), 2) else tostring(row.s.color)
								end,
								commit = function(t: string)
									local c = M.parse("#" .. string.gsub(t, "#", ""))
									if c then
										set_stop("color", M.hex(c))
									end
								end,
							}),
						},
						square_btn(L, {
							icon = "minus",
							label = "Remove stop",
							on_click = function()
								local g = table.clone(grad:peek())
								if #g.colors <= 2 then
									return
								end
								local colors = table.clone(g.colors)
								table.remove(colors, i)
								g.colors = colors
								grad:set(g)
								props.commit(g, false)
							end,
						}),
					}
				end, {
					key = function(r: any): string
						return `{r.i}:{r.s.color}:{r.s.position}`
					end,
				}),
			},
			Kit.button(L, {
				id = "picker-add-stop",
				label = "Add stop",
				icon = "plus",
				w = "100%",
				on_click = function()
					local g = table.clone(grad:peek())
					local colors = table.clone(g.colors)
					table.insert(colors, { color = "#808080", position = 0.5 })
					table.sort(colors, function(a: any, b: any): boolean
						return (props.resolve(a.position) or 0) < (props.resolve(b.position) or 0)
					end)
					g.colors = colors
					grad:set(g)
					props.commit(g, false)
				end,
			}),
		}
	end

	local function image_editor(): Node
		return ui.column {
			w_full = true,
			gap = 10,
			ui.div {
				w_full = true,
				h = 120,
				rounded = 8,
				overflow = "hidden",
				bg = L.field,
				items = "center",
				justify = "center",
				ui.presence(function(): string
					return image:get().url or ""
				end, function(url: string): Node
					if url == "" or string.sub(url, 1, 4) ~= "http" then
						return ui.column {
							items = "center",
							justify = "center",
							gap = 6,
							w_full = true,
							h_full = true,
							Kit.icon("image", 24, L.faint),
							ui.text { "Paste an image URL", text_size = 12, color = L.faint, font = Look.UI },
						}
					end
					return ui.image { src = url, w_full = true, h_full = true, fit = "cover" }
				end, { w_full = true, h_full = true }),
			},
			Kit.field(L, {
				id = "picker-url",
				icon = "link",
				tip = "Image URL",
				mono = false,
				placeholder = "https://…",
				value = function(): string?
					return image:get().url or ""
				end,
				commit = function(t: string)
					image:set_key({ "url" }, t)
					local im = image:peek()
					if t ~= "" then
						props.commit(im, false)
					end
				end,
			}),
			seg(L, {
				id = "picker-image-mode",
				value = function(): any
					return image:get().mode or "cover"
				end,
				options = { { value = "cover", label = "Fill" }, { value = "contain", label = "Fit" }, { value = "stretch", label = "Stretch" } },
				commit = function(v: any)
					image:set_key({ "mode" }, v)
					local im = image:peek()
					if im.url ~= "" then
						props.commit(im, false)
					end
				end,
			}),
		}
	end

	-- The Design's colour variables: a swatch, the name, the hex (faint);
	-- the one this paint is bound to on accent_soft, its name accent_fg.
	local function variables(): Node
		if #props.tokens == 0 then
			return ui.div {}
		end
		local rows: any = { w_full = true, gap = 1, max_h = 146, overflow_y = "auto" }
		for _, t in props.tokens do
			local bound = p == "$" .. t.name
			local hex = tostring(t.value)
			local c = M.parse(hex)
			if c then
				hex = string.sub(M.hex(c), 2)
			end
			table.insert(
				rows,
				ui.button {
					label = t.name,
					w_full = true,
					h = 28,
					min_h = 28,
					px = 8,
					gap = 8,
					rounded = 7,
					border = 0,
					items = "center",
					bg = if bound then L.accent_soft else "#00000000",
					hover = { bg = if bound then L.accent_soft else L.hover },
					focus = { outline = 0 },
					on_click = function()
						props.commit("$" .. t.name, false)
					end,
					ui.div { w = 14, h = 14, min_w = 14, shrink = 0, rounded = 4, bg = t.value, border = 1, border_color = L.border },
					Kit.text(L, t.name, { color = if bound then L.accent_fg else L.fg, weight = if bound then 500 else 400, grow = 1, truncate = true }),
					Kit.text(L, hex, { color = L.faint }),
				}
			)
		end
		return ui.column {
			w_full = true,
			gap = 10,
			ui.div { w_full = true, h = 1, bg = L.border },
			sub_title("Variables"),
			ui.scroll(rows),
		}
	end

	return ui.column {
		id = "picker",
		-- (264 with the popover's 1px rim, which the host draws)
		w = 262,
		p = 12,
		gap = 10,
		bg = L.panel_solid,
		rounded = 12,
		-- the top strip: the kinds, and close
		ui.row {
			w_full = true,
			gap = 6,
			items = "center",
			seg(L, {
				id = "picker-kind",
				grow = 1,
				value = function(): any
					return tab:get()
				end,
				options = { { value = "solid", icon = "rect", tip = "Solid" }, { value = "gradient", icon = "pGradient", tip = "Gradient" }, { value = "image", icon = "image", tip = "Image" } },
				commit = switch_tab,
			}),
			if props.close
				then square_btn(L, {
					id = "picker-close",
					icon = "x",
					label = "Close",
					on_click = props.close :: () -> (),
				})
				else ui.div {},
		},
		ui.presence(tab, function(which: string): Node
			if which == "gradient" then
				return gradient_editor()
			elseif which == "image" then
				return image_editor()
			end
			return ui.column {
				w_full = true,
				gap = 10,
				solid(L, color, function(c: RGBA, live: boolean)
					props.commit(M.hex(c), live)
				end, props.eyedrop, props.close),
				variables(),
			}
		end, { w_full = true }),
	}
end

M.Look = Look
return M
