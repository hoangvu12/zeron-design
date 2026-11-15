--!nonstrict
-- Screens as one HTML file (native crates/design/src/export*.rs): a Frame
-- with a layout is a flexbox, any other child sits absolutely where it's
-- placed; fills, strokes, effects and text become their CSS; shapes other
-- than rounded rectangles and plain ellipses, and icons, are inline SVG.
-- Tokens are CSS custom properties per Theme. Plain CSS or Tailwind.

local U = require("./util")
local Resolve = require("./resolve")
local Layout = require("./layout")
local Scene = require("./scene")
local Text = require("./text")
local Proto = require("./proto")
local DeviceFrame = require("./device_frame")
local Smart = require("../tab/smart")
local Variants = require("../tab/variants")
local Expr = require("./expr")
local Vars = require("./vars")

local M = {}
-- (step 4) A Screen's variant states the export writes out, at most.
M.VARIANT_STATES = 32
-- (step 5) Members written for Instances bound to variables, per Screen
-- section (each is a sibling the page shows by the variables' values).
M.BOUND_MEMBERS = 48

local function num(n: number): string
	if n == math.floor(n) then
		return string.format("%d", n)
	end
	local s = string.format("%.2f", n)
	s = string.gsub(s, "0+$", "")
	return (string.gsub(s, "%.$", ""))
end
local function px(n: number): string
	return if n == 0 then "0" else num(n) .. "px"
end
local function ident(name: string): string
	return (string.gsub(name, "[^%w%-_]", "-"))
end
local function quote(s: string): string
	return '"' .. string.gsub(s, '["\\]', "\\%0") .. '"'
end
local function escape(s: string): string
	return (string.gsub(s, "[<>&\"]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;", ['"'] = "&quot;" }))
end

-- `#RRGGBBAA` as CSS: hex when opaque, else rgba.
local function css_color(c: string, opacity: number?): string
	local r, g, b = tonumber(string.sub(c, 2, 3), 16), tonumber(string.sub(c, 4, 5), 16), tonumber(string.sub(c, 6, 7), 16)
	local a = (tonumber(string.sub(c, 8, 9), 16) or 255) / 255 * (opacity or 1)
	if a >= 0.999 then
		return string.sub(c, 1, 7)
	end
	return `rgba({r}, {g}, {b}, {num(math.floor(a * 1000 + 0.5) / 1000)})`
end

-- A property's value: var(--token) when written as one Token, else `literal`.
local function tokened(written: any, key: string, literal: string): string
	local w = written and written[key]
	local name = Resolve.reference(w)
	if name then
		return `var(--{ident(name)})`
	end
	return literal
end

-- (V7) The Token a written paint is: `"$x"`, `{ type = "color", color = "$x" }`
-- (no opacity below 1), or a list whose first paint is one of those.
local function paint_ref(v: any): string?
	if type(v) == "table" and v.type == nil and v[1] ~= nil then
		v = v[1]
	end
	if type(v) == "table" and v.type == "color" and v.enabled ~= false and not (type(v.opacity) == "number" and v.opacity < 1) then
		v = v.color
	end
	return Resolve.reference(v)
end

-- (V7) A paint's colour: var(--token) when written as one Token, else
-- `literal`. Strokes, SVG shapes and icons use it, so they follow a mode or a
-- set in the export as fills do.
local function painted(written_paint: any, literal: string): string
	local name = paint_ref(written_paint)
	return if name then `var(--{ident(name)})` else literal
end

-- The written stroke's paint (its `fill`), or nil.
local function stroke_paint(written: any): any
	local st = written and written.stroke
	return if type(st) == "table" then st.fill else nil
end

-- A length: calc(var(--token) * 1px) when written as one Token.
local function sized(written: any, key: string, length: number): string
	local name = Resolve.reference(written and written[key])
	if name then
		return `calc(var(--{ident(name)}) * 1px)`
	end
	return px(length)
end

-- (V7) One entry of a written list (padding sides, corners) as a length:
-- calc(var(--token) * 1px) when that entry is a Token.
local function sized_at(written_list: any, i: number, length: number): string
	local v = if type(written_list) == "table" then written_list[i] else written_list
	local name = Resolve.reference(v)
	if name then
		return `calc(var(--{ident(name)}) * 1px)`
	end
	return px(length)
end

local function tokens_css(doc: any): string
	local toks = {}
	local names = {}
	for name, tok in (doc.tokens or {}) do
		local t = Resolve.read_token(name, tok)
		if t then
			toks[name] = t
			table.insert(names, name)
		end
	end
	table.sort(names)
	if #names == 0 then
		return ""
	end
	local function value_css(v)
		if type(v) == "string" then
			return if string.sub(v, 1, 1) == "#" then v else quote(v)
		end
		return tostring(v)
	end
	local out = { ":root {" }
	local default = Resolve.default_theme(doc.themes)
	for _, name in names do
		table.insert(out, `  --{ident(name)}: {value_css(Resolve.value_in(toks[name], default))};`)
	end
	table.insert(out, "}")
	local seen, themes = {}, {}
	for _, name in names do
		for _, v in toks[name].values do
			if next(v.theme) then
				local keys = {}
				for axis, val in v.theme do
					table.insert(keys, `[data-{ident(axis)}={quote(tostring(val))}]`)
				end
				table.sort(keys)
				local sel = table.concat(keys)
				if not seen[sel] then
					seen[sel] = v.theme
					table.insert(themes, sel)
				end
			end
		end
	end
	for _, sel in themes do
		table.insert(out, sel .. " {")
		for _, name in names do
			for i = #toks[name].values, 1, -1 do
				local v = toks[name].values[i]
				if U.equal(v.theme, seen[sel]) then
					table.insert(out, `  --{ident(name)}: {value_css(v.value)};`)
					break
				end
			end
		end
		table.insert(out, "}")
	end
	return table.concat(out, "\n") .. "\n"
end

-- (step 5) The variables runtime's data (M.VARS_JS's TOK, RULES, DEF, AX,
-- MA) as JS `var` declarations: the same Tokens and rules tokens_css writes,
-- each rule's entries naming the candidate (by sig) its value comes from.
-- `json` is json_text (defined below this).
local function vars_data(doc: any, json: (any) -> string): string
	local toks = Vars.tokens(doc)
	local names = {}
	for name in toks do
		table.insert(names, name)
	end
	table.sort(names)
	local tok_js, axes = {}, {}
	for _, name in names do
		local c = {}
		for _, v in toks[name].values do
			table.insert(c, { v = v.value, t = v.theme, s = Resolve.sig(v.theme) })
			for a in v.theme do
				axes[a] = true
			end
		end
		tok_js[name] = { k = toks[name].kind, c = c }
	end
	local default = Resolve.default_theme(doc.themes)
	local root = {}
	for _, name in names do
		local _, cand = Resolve.value_in(toks[name], default)
		table.insert(root, { ident(name), name, Resolve.sig(cand.theme) })
	end
	local rules = { { ":root", root } }
	local seen, order = {}, {}
	for _, name in names do
		for _, v in toks[name].values do
			if next(v.theme) then
				local keys = {}
				for a, val in v.theme do
					table.insert(keys, `[data-{ident(a)}={quote(tostring(val))}]`)
				end
				table.sort(keys)
				local sel = table.concat(keys)
				if not seen[sel] then
					seen[sel] = v.theme
					table.insert(order, sel)
				end
			end
		end
	end
	for _, sel in order do
		local entries = {}
		for _, name in names do
			local vals = toks[name].values
			for i = #vals, 1, -1 do
				if U.equal(vals[i].theme, seen[sel]) then
					table.insert(entries, { ident(name), name, Resolve.sig(vals[i].theme) })
					break
				end
			end
		end
		table.insert(rules, { sel, entries })
	end
	local ax, ma, dup = {}, {}, {}
	for a, vals in (doc.themes or {}) do
		axes[a] = true
		for _, m in U.list(vals) do
			local k = tostring(m)
			if ma[k] and ma[k] ~= a then
				dup[k] = true
			end
			ma[k] = a
		end
	end
	for k in dup do
		ma[k] = nil
	end
	for a in axes do
		ax[a] = ident(a)
	end
	local function obj(t)
		return if next(t) == nil then "{}" else json(t)
	end
	return `  var TOK = {obj(tok_js)}, RULES = {json(rules)}, DEF = {obj(default)}, AX = {obj(ax)}, MA = {obj(ma)};\n`
end

-- (B1) A linear gradient as the Canvas draws it (tab/draw.luau `brush`):
-- its ends sit in the box's own 0..1 space, `center` ± the turned direction
-- × `size.h` / 2 (Figma's handles), and the colour runs straight between
-- them in pixels. CSS's angle is in pixels with its line through the
-- corners, so the angle and the stops are worked out from those ends.
local function linear_css(p: any, stops_of: ((number) -> number) -> { string }, w: number, h: number): string?
	local r = math.rad(p.rot or 0)
	local dx, dy = -math.sin(r), -math.cos(r)
	local len = (p.size and (p.size.h or p.size.height)) or 1
	local cx, cy = (p.center and p.center.x) or 0.5, (p.center and p.center.y) or 0.5
	local x1, y1 = (cx - dx * len / 2) * w, (cy - dy * len / 2) * h
	local vx, vy = dx * len * w, dy * len * h
	local L = math.sqrt(vx * vx + vy * vy)
	if L < 1e-9 then
		return nil
	end
	local ux, uy = vx / L, vy / L
	local lc = math.abs(w * ux) + math.abs(h * uy)
	if lc < 1e-9 then
		return nil
	end
	local deg = math.deg(math.atan2(ux, -uy)) % 360
	local base = ((x1 - w / 2) * ux + (y1 - h / 2) * uy) / lc + 0.5
	local k = L / lc
	return `linear-gradient({num(deg)}deg, {table.concat(stops_of(function(s)
		return base + s * k
	end), ", ")})`
end

local function background(paints: any, box: any?): { { string } }?
	if not paints then
		return nil
	end
	if #paints == 1 and paints[1].k == "solid" then
		return { { "background-color", css_color(paints[1].color, paints[1].op) } }
	end
	local layers = {}
	for i = #paints, 1, -1 do
		local p = paints[i]
		if p.k == "solid" then
			local c = css_color(p.color, p.op)
			table.insert(layers, `linear-gradient({c}, {c})`)
		elseif p.k == "image" then
			local size = if p.mode == "contain" then "contain" elseif p.mode == "stretch" then "100% 100%" else "cover"
			local url = if string.sub(p.src, 1, 8) == "missing:" then string.sub(p.src, 9) else p.src
			table.insert(layers, `url({quote(url)}) center / {size} no-repeat`)
		else
			local stops = {}
			for _, s in p.stops do
				table.insert(stops, `{css_color(s.color, p.op)} {num(s.pos * 100)}%`)
			end
			local at = `{num(p.center.x * 100)}% {num(p.center.y * 100)}%`
			local lin = if p.k == "linear" and box and box.w > 0 and box.h > 0
				then linear_css(p, function(at)
					local out = {}
					for _, s in p.stops do
						table.insert(out, `{css_color(s.color, p.op)} {num(at(s.pos) * 100)}%`)
					end
					return out
				end, box.w, box.h)
				else nil
			if lin then
				table.insert(layers, lin)
			elseif p.k == "linear" then
				table.insert(layers, `linear-gradient({num((-p.rot) % 360)}deg, {table.concat(stops, ", ")})`)
			elseif p.k == "radial" then
				table.insert(layers, `radial-gradient({num(p.size.w * 50)}% {num(p.size.h * 50)}% at {at}, {table.concat(stops, ", ")})`)
			else
				table.insert(layers, `conic-gradient(from {num((-p.rot) % 360)}deg at {at}, {table.concat(stops, ", ")})`)
			end
		end
	end
	return { { "background", table.concat(layers, ", ") } }
end

local function svg_path_of(item: any): (string?, string?)
	local sh = item.shape
	local w, h = item.box.w, item.box.h
	if not sh then
		return nil
	end
	if sh.k == "polygon" then
		local pts = {}
		local raw = {}
		for i = 0, sh.sides - 1 do
			local a = i * 2 * math.pi / sh.sides - math.pi / 2
			table.insert(raw, { math.cos(a), math.sin(a) })
		end
		local l, t, r, b = math.huge, math.huge, -math.huge, -math.huge
		for _, p in raw do
			l, t, r, b = math.min(l, p[1]), math.min(t, p[2]), math.max(r, p[1]), math.max(b, p[2])
		end
		for i, p in raw do
			table.insert(pts, (if i == 1 then "M" else "L") .. num((p[1] - l) / (r - l) * w) .. " " .. num((p[2] - t) / (b - t) * h))
		end
		return table.concat(pts, " ") .. " Z", `0 0 {num(w)} {num(h)}`
	elseif sh.k == "path" then
		local vb = if sh.vb then `{num(sh.vb.x)} {num(sh.vb.y)} {num(sh.vb.w)} {num(sh.vb.h)}` else `0 0 {num(w)} {num(h)}`
		return sh.d, vb
	elseif sh.k == "ellipse" then
		local rx, ry = w / 2, h / 2
		if (sh.sweep or 360) >= 360 and (sh.inner or 0) <= 0 then
			return nil
		end
		local function at(deg, f)
			local a = math.rad(deg)
			return rx + rx * f * math.cos(a), ry + ry * f * math.sin(a)
		end
		local sweep = math.min(sh.sweep or 360, 359.99)
		local x0, y0 = at(sh.start or 0, 1)
		local x1, y1 = at((sh.start or 0) + sweep, 1)
		local large = if sweep > 180 then 1 else 0
		local d = `M{num(x0)} {num(y0)} A{num(rx)} {num(ry)} 0 {large} 1 {num(x1)} {num(y1)}`
		local inner = sh.inner or 0
		if inner > 0 then
			local ix1, iy1 = at((sh.start or 0) + sweep, inner)
			local ix0, iy0 = at(sh.start or 0, inner)
			d ..= ` L{num(ix1)} {num(iy1)} A{num(rx * inner)} {num(ry * inner)} 0 {large} 0 {num(ix0)} {num(iy0)} Z`
		else
			d ..= ` L{num(rx)} {num(ry)} Z`
		end
		return d, `0 0 {num(w)} {num(h)}`
	end
	return nil
end

-- The element for one scene item: tag, declarations, inner HTML.
local function element(item: any, written: any, parent_kind: string, parent_box: any): any
	local d = {}
	local function set(k, v)
		table.insert(d, { k, v })
	end
	local w = written or {}
	-- where it sits
	if parent_kind == "page" then
		set("position", "relative")
	elseif parent_kind == "free" or item.abs then
		set("position", "absolute")
		set("left", px(item.box.x - parent_box.x))
		set("top", px(item.box.y - parent_box.y))
	elseif item.lay or (item.n or 0) > 0 then
		-- (in the flow: anything holding children is their containing block,
		-- so a frame without a layout keeps its absolutely placed children)
		set("position", "relative")
	end
	-- how big
	local in_flex = if (parent_kind == "row" or parent_kind == "column") and not item.abs then parent_kind else nil
	local sizing = Layout.sizing(item.__node)
	for i, prop in { "width", "height" } do
		local s = sizing[i]
		local laid = if i == 1 then item.box.w else item.box.h
		local main = (in_flex == "row" and i == 1) or (in_flex == "column" and i == 2)
		if type(s) == "number" then
			set(prop, sized(w, prop, s))
			if in_flex then
				set("flex-shrink", "0")
			end
		elseif s == "fill" and in_flex and main then
			set("flex", "1 1 0")
			set(if i == 1 then "min-width" else "min-height", "0")
		elseif s == "fill" and in_flex then
			set("align-self", "stretch")
		elseif s == "fill" and (parent_kind == "free" or item.abs) and parent_box and parent_box.w then
			-- (step 6 P5: the rest of its parent from where it sits, as the
			-- layout gives it, so it follows a Responsive Screen's width)
			local off = if i == 1 then item.box.x - parent_box.x else item.box.y - parent_box.y
			set(prop, if math.abs(off) < 0.005 then "100%" else `calc(100% - {px(off)})`)
		elseif s == "fill" then
			set(prop, px(laid))
		elseif not ((item.t == "text" or item.lay) and parent_kind ~= "page") then
			set(prop, px(laid))
		end
	end
	local node = item.__node
	if item.lay then
		set("display", "flex")
		set("flex-direction", if item.lay == "horizontal" then "row" else "column")
		if U.num(node.gap, 0) ~= 0 or Resolve.reference(w.gap) then
			set("gap", sized(w, "gap", U.num(node.gap, 0)))
		end
		local p = node.padding
		if p ~= nil and p ~= 0 then
			local t, r, b, l = 0, 0, 0, 0
			if type(p) == "number" then
				t, r, b, l = p, p, p, p
			elseif #p == 2 then
				t, b, l, r = p[1], p[1], p[2], p[2]
			elseif #p == 4 then
				t, r, b, l = p[1], p[2], p[3], p[4]
			end
			-- (a side written as a number Token follows it, V7)
			local wp = w.padding
			local it, ir, ib, il = 1, 1, 1, 1
			if type(wp) == "table" and #wp == 2 then
				it, ir, ib, il = 1, 2, 1, 2
			elseif type(wp) == "table" and #wp == 4 then
				it, ir, ib, il = 1, 2, 3, 4
			elseif type(wp) == "table" then
				wp = nil
			end
			set("padding", `{sized_at(wp, it, t)} {sized_at(wp, ir, r)} {sized_at(wp, ib, b)} {sized_at(wp, il, l)}`)
			-- (a set size includes the padding, as in the Design)
			set("box-sizing", "border-box")
		end
		local J = { center = "center", ["end"] = "flex-end", space_between = "space-between", space_around = "space-around" }
		local A = { center = "center", ["end"] = "flex-end" }
		set("justify-content", J[node.justifyContent] or "flex-start")
		set("align-items", A[node.alignItems] or "flex-start")
	end
	if item.clip then
		set("overflow", "hidden")
	end
	-- scrolling (step 2): a scrolling frame scrolls its overflow (and always
	-- clips the other way); a sticky layer sticks at its scroller's top, in
	-- the flow at its own place (CSS sticky can't be absolute)
	if item.ovf then
		local sx = item.ovf == "horizontal" or item.ovf == "both"
		local sy = item.ovf == "vertical" or item.ovf == "both"
		set("overflow-x", if sx then "auto" else "hidden")
		set("overflow-y", if sy then "auto" else "hidden")
		set("overscroll-behavior", "contain")
		local positioned = false
		for _, x in d do
			if x[1] == "position" then
				positioned = true
			end
		end
		if not positioned then
			set("position", "relative")
		end
	end
	local sticky_at: { string }? = nil
	if item.scr == "sticky" then
		local keep, left, top = {}, nil, nil
		for _, x in d do
			if x[1] == "left" then
				left = x[2]
			elseif x[1] == "top" then
				top = x[2]
			elseif x[1] ~= "position" then
				table.insert(keep, x)
			end
		end
		table.clear(d)
		set("position", "sticky")
		set("top", "0")
		set("z-index", "1")
		if left or top then
			sticky_at = { left or "0", top or "0" }
		end
		for _, x in keep do
			table.insert(d, x)
		end
	end
	local tag, inner, svg_attrs = "div", nil, nil
	local d_path, vb = svg_path_of(item)
	if item.t == "text" then
		tag = "p"
		local tx = item.text
		set("margin", "0")
		set("font-family", tokened(w, "fontFamily", quote(tx.font)))
		set("font-size", sized(w, "fontSize", tx.size))
		if tx.weight ~= 400 then
			set("font-weight", tostring(tx.weight))
		end
		set("line-height", px(tx.lh))
		if tx.ls ~= 0 then
			set("letter-spacing", px(tx.ls))
		end
		if tx.align ~= "left" then
			set("text-align", tx.align)
		end
		if tx.under then
			set("text-decoration", "underline")
		elseif tx.strike then
			set("text-decoration", "line-through")
		end
		set("white-space", if tx.wrap then "pre-wrap" else "pre")
		local f = item.fill and item.fill[1]
		if f and f.k == "solid" then
			set("color", painted(w.fill, css_color(f.color, f.op)))
		elseif f then
			for _, x in (background(item.fill, item.box) or {}) do
				set(x[1], x[2])
			end
			set("-webkit-background-clip", "text")
			set("background-clip", "text")
			set("color", "transparent")
		else
			set("color", "transparent")
		end
		inner = escape(tx.s)
	elseif item.t == "icon" then
		set("color", painted(w.fill, css_color(item.icon.color)))
		local ic = item.icon
		if ic.parts then
			local parts = {}
			for _, p in ic.parts do
				local attrs = { `d="{escape(p.d)}"` }
				table.insert(attrs, if p.nofill then 'fill="none"' else 'fill="currentColor"')
				if p.sw then
					table.insert(attrs, `stroke="currentColor" stroke-width="{num(p.sw)}"`)
					if p.cap then
						table.insert(attrs, `stroke-linecap="{p.cap}"`)
					end
					if p.join then
						table.insert(attrs, `stroke-linejoin="{p.join}"`)
					end
				end
				if p.rule then
					table.insert(attrs, `fill-rule="{p.rule}"`)
				end
				table.insert(parts, "<path " .. table.concat(attrs, " ") .. "/>")
			end
			inner = `<svg width="100%" height="100%" viewBox="{num(ic.vb.x)} {num(ic.vb.y)} {num(ic.vb.w)} {num(ic.vb.h)}">` .. table.concat(parts) .. "</svg>"
		else
			inner = ""
		end
	elseif d_path then
		tag = "svg"
		local fill = item.fill and item.fill[1]
		local fc = if fill and fill.k == "solid" then css_color(fill.color, fill.op) else "none"
		local stroke = ""
		-- (a Token paint goes in `style`: presentation attributes can't read
		-- var(); the attribute stays as the value without CSS variables, V7)
		local style = {}
		if fill and fill.k == "solid" and paint_ref(w.fill) then
			table.insert(style, `fill:{painted(w.fill, fc)}`)
		end
		if item.stroke and item.stroke.fill[1] and item.stroke.fill[1].k == "solid" then
			local sc = css_color(item.stroke.fill[1].color)
			stroke = ` stroke="{sc}" stroke-width="{num(item.stroke.w[1])}"`
			if paint_ref(stroke_paint(w)) then
				table.insert(style, `stroke:{painted(stroke_paint(w), sc)}`)
			end
		end
		local sty = if #style > 0 then ` style="{table.concat(style, ";")}"` else ""
		svg_attrs = ` viewBox="{vb}" preserveAspectRatio="none"`
		inner = `<path d="{escape(d_path)}" fill="{fc}"{stroke}{sty}` .. (if item.shape.rule == "evenodd" then ' fill-rule="evenodd"' else "") .. "/>"
	else
		for _, x in (background(item.fill, item.box) or {}) do
			if x[1] == "background-color" then
				set(x[1], painted(w.fill, x[2]))
			else
				set(x[1], x[2])
			end
		end
		local sh = item.shape
		if sh and sh.k == "ellipse" then
			set("border-radius", "50%")
		elseif sh and sh.k == "rect" then
			local r = sh.r
			if r[1] ~= 0 or r[2] ~= 0 or r[3] ~= 0 or r[4] ~= 0 then
				local wr = w.cornerRadius
				if r[1] == r[2] and r[2] == r[3] and r[3] == r[4] and type(wr) ~= "table" then
					set("border-radius", sized(w, "cornerRadius", r[1]))
				else
					if type(wr) ~= "table" or #wr ~= 4 then
						wr = if type(wr) == "table" then nil else wr
					end
					set("border-radius", `{sized_at(wr, 1, r[1])} {sized_at(wr, 2, r[2])} {sized_at(wr, 3, r[3])} {sized_at(wr, 4, r[4])}`)
				end
			end
		end
		-- a stroke: one width all round as a ring of box shadows, else borders
		local st = item.stroke
		local shadows = {}
		if st and st.fill[1] and st.fill[1].k == "solid" then
			-- (a Token stroke follows modes and sets, as fills do; V7)
			local c = painted(stroke_paint(w), css_color(st.fill[1].color, st.fill[1].op))
			local t = st.w
			if t[1] == t[2] and t[2] == t[3] and t[3] == t[4] then
				local width = t[1]
				if st.dash then
					local off = if st.align == "inside" then -width elseif st.align == "center" then -width / 2 else 0
					set("outline", `{px(width)} dashed {c}`)
					set("outline-offset", px(off))
				elseif st.align == "inside" then
					table.insert(shadows, `inset 0 0 0 {px(width)} {c}`)
				elseif st.align == "outside" then
					table.insert(shadows, `0 0 0 {px(width)} {c}`)
				else
					table.insert(shadows, `inset 0 0 0 {px(width / 2)} {c}`)
					table.insert(shadows, `0 0 0 {px(width / 2)} {c}`)
				end
			else
				set("box-sizing", "border-box")
				for i, side in { "top", "right", "bottom", "left" } do
					if t[i] > 0 then
						set("border-" .. side, `{px(t[i])} solid {c}`)
					end
				end
			end
		end
		for _, e in (item.fx or {}) do
			if e.k == "shadow" then
				table.insert(shadows, (if e.inner then "inset " else "") .. `{px(e.x)} {px(e.y)} {px(e.blur)} {px(e.spread)} {css_color(e.color)}`)
			end
		end
		if #shadows > 0 then
			set("box-shadow", table.concat(shadows, ", "))
		end
	end
	local filters = {}
	for _, e in (item.fx or {}) do
		if e.k == "blur" then
			table.insert(filters, `blur({px(e.radius / 2)})`)
		elseif e.k == "bgblur" then
			set("backdrop-filter", `blur({px(e.radius / 2)})`)
		end
	end
	if #filters > 0 then
		set("filter", table.concat(filters, " "))
	end
	if Resolve.reference(w.opacity) then
		-- (a number Token, 0–1; V7)
		set("opacity", `var(--{ident(Resolve.reference(w.opacity) :: string)})`)
	elseif item.op then
		set("opacity", num(item.op))
	end
	local tf = {}
	if item.rot then
		table.insert(tf, `rotate({num(-item.rot)}deg)`)
	end
	if node.flipX == true or node.flipY == true then
		-- (flipped about its centre, then turned about its top-left: the
		-- Canvas's order, engine/scene.luau `own`)
		local cx, cy = px(item.box.w / 2), px(item.box.h / 2)
		table.insert(tf, `translate({cx}, {cy}) scale({if node.flipX then -1 else 1}, {if node.flipY then -1 else 1}) translate(-{cx}, -{cy})`)
	end
	if #tf > 0 then
		set("transform-origin", "0 0")
		set("transform", table.concat(tf, " "))
	end
	if sticky_at then
		-- (last: a text's own `margin: 0` comes before)
		set("margin-left", sticky_at[1])
		set("margin-top", sticky_at[2])
	end
	return { tag = tag, d = d, inner = inner, svg = svg_attrs }
end

-- ── prototypes: states as CSS, links, the transition script ─────────────

local arbitrary: (string) -> string

-- Whether any node of the doc (or override) has interactions.
function M.has_interactions(doc: any): boolean
	local found = false
	local function scan(v, depth)
		if found or type(v) ~= "table" or depth > 64 then
			return
		end
		if type(v.interactions) == "table" and next(v.interactions) ~= nil then
			found = true
			return
		end
		for k, x in v do
			if k ~= "interactions" and type(x) == "table" then
				scan(x, depth + 1)
			end
		end
	end
	scan(doc.children, 0)
	return found
end

local function bezier_css(e: { number }): string
	return `cubic-bezier({num(e[1])}, {num(e[2])}, {num(e[3])}, {num(e[4])})`
end

-- A played spring (`sp = { m, k, c, v }`, its `ms` the settle time) as the
-- values of CSS linear(): evenly spaced samples, finer for long ones.
local function spring_values(sp: any, ms: number): { string }
	local n = math.clamp(math.floor((ms or 300) / 12), 30, 120)
	local pts = Proto.spring_points({ mass = sp.m, stiffness = sp.k, damping = sp.c, velocity = sp.v }, n)
	local out = {}
	for k, v in pts do
		out[k] = string.format("%.4g", v)
	end
	return out
end

-- A played transition's (or `sttr`'s) timing function for CSS: a spring as
-- linear(…), else its bézier.
local function ease_css(tr: any): string
	if tr and type(tr.sp) == "table" then
		return "linear(" .. table.concat(spring_values(tr.sp, tr.ms), ", ") .. ")"
	end
	return bezier_css(tr and tr.ease or { 0, 0, 0.58, 1 })
end

-- A stroke ring and shadows as one box-shadow value (or nil).
-- `wpaint`: the stroke's written paint, so a Token stroke stays var() (V7).
local function box_shadow(st: any, fx: any, wpaint: any?): string?
	local shadows = {}
	if st and st.fill and st.fill[1] and st.fill[1].k == "solid" and st.w[1] == st.w[2] and st.w[2] == st.w[3] and st.w[3] == st.w[4] and not st.dash then
		local c = painted(wpaint, css_color(st.fill[1].color, st.fill[1].op))
		local width = st.w[1]
		if st.align == "inside" then
			table.insert(shadows, `inset 0 0 0 {px(width)} {c}`)
		elseif st.align == "outside" then
			table.insert(shadows, `0 0 0 {px(width)} {c}`)
		else
			table.insert(shadows, `inset 0 0 0 {px(width / 2)} {c}`)
			table.insert(shadows, `0 0 0 {px(width / 2)} {c}`)
		end
	end
	for _, e in (fx or {}) do
		if e.k == "shadow" then
			table.insert(shadows, (if e.inner then "inset " else "") .. `{px(e.x)} {px(e.y)} {px(e.blur)} {px(e.spread)} {css_color(e.color)}`)
		end
	end
	return if #shadows > 0 then table.concat(shadows, ", ") else nil
end

-- One state entry (scene `st`) of `item` as declarations { k, v, sub? }
-- (`sub`: a selector inside the element, as " path" for an SVG's shape).
-- `written`: the state's props as written (Tokens kept), when it has them.
-- `wnode`: the item's own node as written (its base stroke's Token, V7).
local function state_decls(item: any, e: any, written: any?, wnode: any?): { any }
	local d = {}
	local is_svg = item.shape and (item.shape.k == "path" or item.shape.k == "polygon" or (item.shape.k == "ellipse" and ((item.shape.sweep or 360) < 360 or (item.shape.inner or 0) > 0)))
	if e.fill then
		local f = e.fill[1]
		local tok = written and paint_ref(written.fill)
		if item.t == "text" or item.t == "icon" then
			local c = if f and f.k == "solid" then css_color(f.color, f.op) else "transparent"
			table.insert(d, { "color", if tok and f and f.k == "solid" then `var(--{ident(tok)})` else c })
		elseif is_svg then
			table.insert(d, { "fill", if tok and f and f.k == "solid" then `var(--{ident(tok)})` elseif f and f.k == "solid" then css_color(f.color, f.op) else "none", " path" })
		elseif #e.fill == 0 then
			table.insert(d, { "background", "none" })
		else
			for _, x in (background(e.fill, item.box) or {}) do
				local v = x[2]
				if x[1] == "background-color" and tok then
					v = `var(--{ident(tok)})`
				end
				table.insert(d, { x[1], v })
			end
		end
	end
	if (e.stroke ~= nil or e.fx ~= nil) and not is_svg and item.t ~= "text" and item.t ~= "icon" then
		local st = if e.stroke ~= nil then (e.stroke or nil) else item.stroke
		local fx = if e.fx ~= nil then e.fx else item.fx
		-- (the state's own stroke as written, else the layer's)
		local wpaint = if e.stroke ~= nil then stroke_paint(written) else stroke_paint(wnode)
		table.insert(d, { "box-shadow", box_shadow(st, fx, wpaint) or "none" })
	end
	if e.op then
		table.insert(d, { "opacity", num(e.op) })
	end
	if e.r and not is_svg then
		local r = e.r
		if r[1] == r[2] and r[2] == r[3] and r[3] == r[4] then
			table.insert(d, { "border-radius", px(r[1]) })
		else
			table.insert(d, { "border-radius", `{px(r[1])} {px(r[2])} {px(r[3])} {px(r[4])}` })
		end
	end
	if e.sc then
		table.insert(d, { "transform", (if item.rot then `rotate({num(-item.rot)}deg) ` else "") .. `scale({num(e.sc)})` })
	end
	return d
end

-- Hover/press CSS for one exported root's items. `cls(id)` → the class of
-- an item; `written_of(id)` → its states as written. Returns CSS rules
-- (plain mode), or adds Tailwind classes to `tw_extra[id]`.
local function states_css(items: { any }, cls: (string) -> string?, written_of: (string) -> any, tw_extra: { [string]: { string } }?): { string }
	local by_id = {}
	for _, it in items do
		by_id[it.id] = it
	end
	local hover, active, base = {}, {}, {}
	for _, it in items do
		if it.st then
			local props = {}
			local driver = nil
			-- hover and press per driver, press over hover for :active
			local per = {}
			for _, e in it.st do
				driver = driver or by_id[e.of]
				per[e.of] = per[e.of] or {}
				local ws = written_of(e.of)
				local wprops = nil
				if type(ws) == "table" and type(ws[e.s]) == "table" then
					wprops = if e.of == it.id then ws[e.s] else nil
				end
				local _, wnode = written_of(it.id)
				per[e.of][e.s] = state_decls(it, e, wprops, wnode)
			end
			for of, s in per do
				local dv = by_id[of]
				local dc, ic = cls(of), cls(it.id)
				local h = s.hover or {}
				local merged, at = {}, {}
				for _, x in h do
					at[x[1] .. (x[3] or "")] = #merged + 1
					table.insert(merged, x)
				end
				for _, x in (s.press or {}) do
					local key = x[1] .. (x[3] or "")
					if at[key] then
						merged[at[key]] = x
					else
						table.insert(merged, x)
					end
				end
				for _, x in merged do
					if not x[3] then
						props[x[1]] = true
					else
						props[x[1]] = true
					end
				end
				if tw_extra then
					local mine = tw_extra[it.id] or {}
					tw_extra[it.id] = mine
					local self_ = of == it.id
					if self_ then
						table.insert(mine, "group")
					elseif tw_extra[of] == nil or not table.find(tw_extra[of], "group") then
						tw_extra[of] = tw_extra[of] or {}
						table.insert(tw_extra[of], "group")
					end
					local function add(variant, list)
						for _, x in list do
							local sub = if x[3] then "[&_path]:" else ""
							table.insert(mine, `{variant}:{sub}[{x[1]}:{arbitrary(x[2])}]`)
						end
					end
					add(if self_ then "hover" else "group-hover", h)
					add(if self_ then "active" else "group-active", merged)
				elseif dc and ic then
					local function sel(pseudo, x)
						local s0 = if of == it.id then `.{dc}:{pseudo}` else `.{dc}:{pseudo} .{ic}`
						return s0 .. (x[3] or "")
					end
					local function rules(pseudo, list, into)
						local groups, order = {}, {}
						for _, x in list do
							local s1 = sel(pseudo, x)
							if not groups[s1] then
								groups[s1] = {}
								table.insert(order, s1)
							end
							table.insert(groups[s1], `{x[1]}: {x[2]};`)
						end
						for _, s1 in order do
							table.insert(into, `{s1} \{ {table.concat(groups[s1], " ")} \}`)
						end
					end
					rules("hover", h, hover)
					rules("active", merged, active)
				end
				local _ = dv
			end
			-- the transition, timed by the (first) driver
			local tr = driver and driver.sttr or { ms = 150, ease = { 0, 0, 0.58, 1 } }
			local names = {}
			for k in props do
				table.insert(names, k)
			end
			table.sort(names)
			if #names > 0 then
				local parts = {}
				local tf = ease_css(tr)
				for _, k in names do
					table.insert(parts, `{k} {num(tr.ms)}ms {tf}`)
				end
				local value = table.concat(parts, ", ")
				if tw_extra then
					table.insert(tw_extra[it.id], `[transition:{arbitrary(value)}]`)
					if props.transform and not it.rot then
						table.insert(tw_extra[it.id], "origin-center")
					end
				else
					local c = cls(it.id)
					if c then
						local subs = ""
						if props.fill then
							subs = ` .{c} path \{ transition: fill {num(tr.ms)}ms {tf}; \}`
						end
						table.insert(base, `.{c} \{ transition: {value};` .. (if props.transform and not it.rot then " transform-origin: center;" else "") .. ` \}` .. subs)
					end
				end
			end
		end
	end
	local out = {}
	for _, r in base do
		table.insert(out, r)
	end
	if #hover > 0 then
		table.insert(out, "@media (hover: hover) {\n  " .. table.concat(hover, "\n  ") .. "\n}")
	end
	for _, r in active do
		table.insert(out, r)
	end
	return out
end

local REDUCED = "@media (prefers-reduced-motion: reduce) {\n  *, *::before, *::after { transition-duration: 0s !important; animation-duration: 0s !important; }\n}"

local PROTO_CSS = [[
html, body { margin: 0; }
body.proto { background: #18181b; min-height: 100vh; }
.screen { display: none; position: absolute; inset: 0; overflow: auto; background: #18181b; }
.screen > * { margin: 0 auto; }
html:not(.js) .screen.start, html:not(.js) .screen:target { display: block; }
html:not(.js) body:has(.screen:target) .screen.start:not(:target) { display: none; }
html.js .screen.on { display: block; }
:where(a.link) { text-decoration: none; color: inherit; }
[data-go], [data-back], [data-url] { cursor: pointer; }
[data-off] { display: none !important; }
.flows { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
body.proto.responsive .screen:not([role=dialog]) > * { width: 100% !important; height: auto !important; min-height: max(100%, var(--rh, 0px)) !important; box-sizing: border-box; }]]

-- The prototype's router: links are URL hashes, so the browser's Back works;
-- with JS, both Screens show while element.animate() moves them.
M.PROTO_JS = [[
(function () {
  var d = document, html = d.documentElement;
  var screens = [].slice.call(d.querySelectorAll('section.screen'));
  if (!screens.length) return;
  html.classList.add('js');
  var reduce = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
  var start = d.querySelector('section.screen.start') || screens[0];
  var cur = null, stack = [], pending = null, pendingBack = null, busy = [];
  // (step 2) then_: what runs once the Screen being shown is in place (the
  // next action of a list); shown(): a Screen shown starts its timers
  var then_ = null, shown = function () {};
  var OPP = { left: 'right', right: 'left', up: 'down', down: 'up' };
  var REV = { moveIn: 'moveOut', moveOut: 'moveIn', slideIn: 'slideOut', slideOut: 'slideIn' };
  function screen(id) { var s = id && d.getElementById(id); return s && s.classList.contains('screen') ? s : null; }
  // "k dir ms ease": ease is "x1,y1,x2,y2", or "L" and a spring's linear() values
  function parse(s) {
    if (!s) return null;
    var p = s.split(' '), e = p[3] || '0,0,0.58,1';
    return { k: p[0], dir: p[1] === '-' ? '' : p[1], ms: +p[2] || 0, ease: e.charAt(0) === 'L' ? 'linear(' + e.slice(1) + ')' : 'cubic-bezier(' + e + ')', ml: p[4] === 'ml' };
  }
  function done() { var f = then_; then_ = null; if (f) setTimeout(f, 0); }
  function reverse(t) { return t && { k: REV[t.k] || t.k, dir: OPP[t.dir] || '', ms: t.ms, ease: t.ease, ml: t.ml }; }
  function settle() {
    busy.forEach(function (a) { a.cancel(); });
    busy = [];
    screens.forEach(function (s) { if (s !== cur) s.classList.remove('on'); s.style.zIndex = ''; });
  }
  // (step 4) interactive components: a Screen's variant states are sections
  // of their own (data-vof = the Screen; data-vs = "key=member;…", the
  // member each Instance shows, keyed by set and name path). `mem` is
  // Figma's component memory, shared by key across Screens and overlays: a
  // link or Back opens the Screen's section that agrees with it best.
  var mem = {}, vsc = {};
  function vof(s) { return s.getAttribute('data-vof') || s.id; }
  function vs(s) {
    if (vsc[s.id]) return vsc[s.id];
    var o = {};
    (s.getAttribute('data-vs') || '').split(';').forEach(function (p) { var i = p.lastIndexOf('='); if (i > 0) o[p.slice(0, i)] = p.slice(i + 1); });
    return (vsc[s.id] = o);
  }
  function remember(s) { var o = vs(s); for (var k in o) mem[k] = o[k]; }
  function forget(s) { var o = vs(s); for (var k in o) delete mem[k]; }
  function at_(id) {
    var s = screen(id);
    if (!s || !s.hasAttribute('data-vs')) return id;
    var base = vof(s), best = id, bs = 1e9;
    [].slice.call(d.querySelectorAll('section.screen')).forEach(function (c) {
      if (vof(c) !== base) return;
      var o = vs(c), n = 0;
      for (var k in o) if (k in mem && mem[k] !== o[k]) n++;
      if (n < bs || (n === bs && c.id === id)) { bs = n; best = c.id; }
    });
    return best;
  }
  // (L1) the last overlay closed: the Screen shows its section that agrees
  // with the memory, which the overlay may have changed (Figma's rule)
  function refresh() {
    if (!cur || !cur.hasAttribute('data-vs')) return;
    var m = screen(at_(cur.id));
    if (!m || m === cur) return;
    history.replaceState(null, '', '#' + m.id);
    if (stack.length) stack[stack.length - 1].s = m;
    // (instant, and not the end of anyone's action)
    var f = then_; then_ = null;
    show(m, null, true, null);
    then_ = f;
  }
  window.__protoVS = { at: function (id) { return at_(id); }, vof: vof, refresh: function () { refresh(); } };
  // (keep: a Change to, in place; ti: the Instance it changed, whose
  // afterDelay timers restart, Figma's rule: the Screen's keep running.
  // ti null: none start, as when memory refreshes the Screen)
  function show(next, t, keep, ti) {
    if (!next || next === cur) { done(); return; }
    // (F4-int: a Change to over one still moving starts where its layers are
    // on screen, CSS's rule, not from the end it was heading to)
    var snap = keep && busy.length && cur && window.__protoSnap ? window.__protoSnap(cur) : null;
    settle();
    // (overlays: a Screen change closes them all, as Figma; a Change to keeps them)
    if (window.__protoOverlay && !keep) window.__protoOverlay.closeAll();
    var prev = cur;
    cur = next;
    next.classList.add('on');
    next.scrollTop = keep && prev ? prev.scrollTop : 0;
    shown(next, keep ? ti : undefined);
    if (!prev) { done(); return; }
    if (!t || t.k === 'instant' || !t.ms || reduce || !next.animate) { prev.classList.remove('on'); done(); return; }
    // (the Screen's own box: one device width with a device viewport)
    var W = next.clientWidth || innerWidth, H = next.clientHeight || innerHeight;
    var v = { left: [-1, 0], right: [1, 0], up: [0, -1], down: [0, 1] }[t.dir] || [0, 0];
    function at(f) { return 'translate(' + (v[0] * W * f) + 'px, ' + (v[1] * H * f) + 'px)'; }
    var o = { duration: t.ms, easing: t.ease, fill: 'both' };
    function anim(el, a, b) { busy.push(el.animate([a, b], o)); }
    var k = t.k;
    // (step 3) Smart Animate, or a move with "Smart animate matching layers"
    if ((k === 'smart' || t.ml) && window.__protoSmart) { window.__protoSmart(prev, next, t, busy, function () { settle(); done(); }, snap); return; }
    if (k === 'smart') k = 'dissolve';
    (k === 'moveOut' || k === 'slideOut' ? prev : next).style.zIndex = 2;
    if (k === 'dissolve') anim(next, { opacity: 0 }, { opacity: 1 });
    if (k === 'moveIn' || k === 'push' || k === 'slideIn') anim(next, { transform: at(-1) }, { transform: at(0) });
    if (k === 'push' || k === 'moveOut' || k === 'slideOut') anim(prev, { transform: at(0) }, { transform: at(1) });
    // (slides: the Screen under moves 30% and dims to 40%, as Play and Figma)
    if (k === 'slideIn') anim(prev, { transform: at(0), opacity: 1 }, { transform: at(0.3), opacity: 0.4 });
    if (k === 'slideOut') anim(next, { transform: at(-0.3), opacity: 0.4 }, { transform: at(0), opacity: 1 });
    if (busy.length) busy[busy.length - 1].onfinish = function () { settle(); done(); }; else { prev.classList.remove('on'); done(); }
  }
  function here() { return decodeURIComponent(location.hash.slice(1)); }
  function route() {
    var id = here(), next = id ? screen(id) : start;
    if (!next) return;
    var t, j = -1;
    // (back: the nearest Screen down the stack; a hover or press undone may go back several)
    if (!pending) for (var q = stack.length - 2; q >= 0; q--) if (stack[q].s === next || vof(stack[q].s) === vof(next)) { j = q; break; }
    // (step 4: Back opens the Screen in the variants the memory holds now)
    if (j >= 0) {
      var m = screen(at_(next.id));
      if (m && m !== next) { next = m; stack[j].s = m; history.replaceState(null, '', '#' + m.id); }
    }
    if (j >= 0) {
      t = pendingBack || reverse(stack[stack.length - 1].t);
      stack.length = j + 1;
    } else {
      t = pending;
      stack.push({ s: next, t: t });
    }
    pending = pendingBack = null;
    show(next, t);
  }
  d.addEventListener('click', function (e) {
    var el = e.target.closest && e.target.closest('a[href^="#"], [data-go], [data-back], [data-url]');
    // (step 2: a drag isn't a click; a click with a list of actions runs them all)
    if (skipClick) { skipClick = false; e.preventDefault(); e.stopImmediatePropagation(); return; }
    var m = find(e.target, 'click');
    if (m && !(el && el !== m.el && m.el.contains(el))) { e.preventDefault(); e.stopImmediatePropagation(); run(m.r, 0, m.el); return; }
    if (!el) return;
    if (el.hasAttribute('data-back')) {
      e.preventDefault();
      // (Back closes the top overlay first)
      if (window.__protoOverlay && window.__protoOverlay.depth()) { window.__protoOverlay.act({ k: 'close', tr: el.getAttribute('data-tr') }, function () {}); return; }
      pendingBack = parse(el.getAttribute('data-tr'));
      if (stack.length > 1) history.back();
      return;
    }
    if (el.hasAttribute('data-url')) { e.preventDefault(); window.open(el.getAttribute('data-url'), '_blank', 'noopener'); return; }
    var id = el.getAttribute('data-go') || (el.getAttribute('href') || '').slice(1);
    if (!screen(id)) return;
    id = at_(id);
    e.preventDefault();
    if (cur && cur.id === id) return;
    pending = parse(el.getAttribute('data-tr'));
    location.hash = id;
  });
  d.addEventListener('keydown', function (e) {
    var el = e.target;
    if (cur && !e.repeat) {
      // (the top overlay's keys first, then the Screen's)
      var top = window.__protoOverlay && window.__protoOverlay.top();
      var ks = (top ? [].slice.call(top.querySelectorAll('[data-ia]')) : []).concat([].slice.call(cur.querySelectorAll('[data-ia]')));
      for (var i = 0; i < ks.length; i++) {
        var l = ia(ks[i]);
        for (var k = 0; k < l.length; k++) if (l[k].on === 'key' && keyMatch(l[k].keys, e)) { e.preventDefault(); run(l[k], 0, ks[i]); return; }
      }
      if ((e.key === 'r' || e.key === 'R') && !e.ctrlKey && !e.metaKey && !e.altKey && !(el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName || ''))) { e.preventDefault(); restart(); return; }
    }
    if ((e.key === 'Enter' || e.key === ' ') && el.getAttribute && el.getAttribute('role') === 'link' && !/^A$/.test(el.tagName)) { e.preventDefault(); el.click(); }
  });

  // ── step 2: triggers and action lists (`data-ia`, Figma's semantics) ──
  // hover / press run while they last and go back when they end; mouseEnter
  // / mouseLeave / mouseDown / mouseUp fire once (after `ms` if the pointer
  // stayed); drag after 4 px; afterDelay `ms` after its Screen shows; key on
  // its combo. A reaction's actions run in order, each after the last ends.
  var gen = 0, held = null, drag = null, skipClick = false, under = [], lastX = 0, lastY = 0;
  function ia(el) { try { return JSON.parse(el.getAttribute('data-ia')) || []; } catch (x) { return []; } }
  function up_(el) { return el.parentElement && el.parentElement.closest('[data-ia]'); }
  function find(t, on) {
    for (var el = t && t.closest ? t.closest('[data-ia]') : null; el; el = up_(el)) {
      var l = ia(el);
      for (var i = 0; i < l.length; i++) if (l[i].on === on) return { el: el, r: l[i] };
    }
    return null;
  }
  function keyMatch(keys, e) {
    if (!keys || !keys.length) return false;
    var want = { Shift: false, Ctrl: false, Alt: false, Meta: false }, main = null;
    keys.forEach(function (k) { if (k in want) want[k] = true; else main = k; });
    var key = e.key === ' ' ? 'Space' : e.key;
    if (!main || (main.length === 1 ? key.toLowerCase() !== main.toLowerCase() : key !== main)) return false;
    return e.shiftKey === want.Shift && e.ctrlKey === want.Ctrl && e.altKey === want.Alt && e.metaKey === want.Meta;
  }
  function idle(f) { if (busy.length) setTimeout(function () { idle(f); }, 30); else f(); }
  // (V7) A bound Instance's members are siblings (data-vg): write the
  // variables, then animate the shown member from the old one's look. Each
  // named layer moves from its old place in its parent, and takes its old
  // size and colours; one only in the new member fades in.
  function vswap(a, el, tv, next) {
    var g = el && el.closest ? el.closest('[data-vg]') : null;
    var look = function (root) {
      var m = {}, rr = root.getBoundingClientRect(), Z = window.__protoZ || 1;
      [root].concat([].slice.call(root.querySelectorAll('[data-name]'))).forEach(function (e, i) {
        var k = i === 0 ? '' : e.getAttribute('data-name');
        if (k in m) return;
        var r = e.getBoundingClientRect(), p = i === 0 ? rr : e.parentElement.getBoundingClientRect(), cs = getComputedStyle(e);
        m[k] = { e: e, x: (r.left - p.left) / Z, y: (r.top - p.top) / Z, w: r.width / Z, h: r.height / Z, bg: cs.backgroundColor, c: cs.color, o: cs.opacity };
      });
      return m;
    };
    var before = g ? look(g) : null;
    window.__protoV.act(a, el);
    var now = g && [].slice.call(g.parentNode.children).filter(function (s) { return s.getAttribute('data-vg') === g.getAttribute('data-vg') && !s.hasAttribute('data-off'); })[0];
    var hold = function () { setTimeout(next, tv.ms); };
    if (!before || !now || now === g) return hold();
    var after = look(now), opts = { duration: tv.ms, easing: tv.ease };
    for (var k in after) {
      var n = after[k], o = before[k], an;
      if (!o) { an = n.e.animate([{ opacity: 0 }, { opacity: n.o }], opts); }
      else {
        var f = {}, t = {};
        if (k !== '' && (o.x !== n.x || o.y !== n.y)) { f.transform = 'translate(' + (o.x - n.x) + 'px,' + (o.y - n.y) + 'px)'; t.transform = 'none'; }
        if (o.w !== n.w || o.h !== n.h) { f.width = o.w + 'px'; t.width = n.w + 'px'; f.height = o.h + 'px'; t.height = n.h + 'px'; }
        if (o.bg !== n.bg) { f.backgroundColor = o.bg; t.backgroundColor = n.bg; }
        if (o.c !== n.c) { f.color = o.c; t.color = n.c; }
        if (o.o !== n.o) { f.opacity = o.o; t.opacity = n.o; }
        if (!Object.keys(f).length) continue;
        an = n.e.animate([f, t], opts);
      }
      busy.push(an);
      an.onfinish = an.oncancel = (function (x) { return function () { busy = busy.filter(function (y) { return y !== x; }); }; })(an);
    }
    hold();
  }
  function act(a, next, el) {
    var O = window.__protoOverlay;
    if (a.k === 'overlay' || a.k === 'swap' || a.k === 'close') return O ? O.act(a, next, el) : next();
    // (Back closes the top overlay first)
    if (a.k === 'back' && O && O.depth()) return O.act({ k: 'close', tr: a.tr }, next);
    if (a.k === 'navigate') {
      if (a.broken || !screen(a.go)) return next();
      // (step 4: it opens in the variants it last showed; "Reset component state" forgets them)
      if (a.rc) forget(screen(a.go));
      var go = at_(a.go);
      if (cur && (cur.id === go || vof(cur) === a.go)) return next();
      then_ = next;
      // (the hash is that Screen's already: no hashchange comes)
      if (here() === go) { var t = parse(a.tr); stack.push({ s: screen(go), t: t }); show(screen(go), t); return; }
      pending = parse(a.tr); location.hash = go; return;
    }
    // (step 4) Change to: the Screen's section for the new variants, in place
    if (a.k === 'changeTo') {
      var nx = screen(a.go);
      // (L1) inside an open overlay: the overlay's own look swaps in place
      if (nx && !a.broken && nx.hasAttribute('data-overlay')) {
        if (!O || !O.find(nx)) return next();
        remember(nx);
        return O.change(nx, a.tr, next, a.ti);
      }
      if (a.broken || !nx || !cur || nx === cur) return next();
      remember(nx);
      // (one taken over mid-way: what its list does next goes on)
      if (then_) done();
      then_ = next;
      history.replaceState(null, '', '#' + nx.id);
      if (stack.length) stack[stack.length - 1].s = nx;
      show(nx, parse(a.tr), true, a.ti);
      return;
    }
    if (a.k === 'back') {
      if (stack.length < 2) return next();
      pendingBack = parse(a.tr); then_ = next; history.back(); return;
    }
    if (a.k === 'url') { window.open(a.url, a.nt === false ? '_self' : '_blank', 'noopener'); return next(); }
    if (a.k === 'scrollTo' && window.__protoScrollTo) return window.__protoScrollTo(a, next);
    // (step 5) variables: a set, a mode or a variant's binding written snaps
    // at once (Figma animates none); an if runs one branch as a list
    var P = window.__protoV;
    // (V7) a bound Instance's Change to (vset) with an animation: the members
    // swap smart-animate style (named layers move, resize and recolour from
    // the old member's look), and the next action waits for it, as Figma's
    if (a.k === 'vset' && P && !a.broken && a.tr) {
      var tv = parse(a.tr);
      if (tv && tv.ms > 0 && tv.k !== 'instant') return vswap(a, el, tv, next);
    }
    if (a.k === 'set' || a.k === 'mode' || a.k === 'vset') { if (P && !a.broken) P.act(a, el); return next(); }
    if (a.k === 'if') {
      var l = !P || a.broken ? null : P.test(a.c, el) ? a.th : a.el, j = 0;
      var step = function () {
        if (!l || j >= l.length) return next();
        var x = l[j++], go2 = function () { act(x, step, el); };
        if (x.k === 'changeTo') go2(); else idle(go2);
      };
      return step();
    }
    next(); // (motion: reserved, not played yet)
  }
  // (step 5) Restart (R, Figma's key): variables, modes and the component
  // memory back to the Design's, overlays closed, the flow's first Screen.
  // Nothing else resets them: navigate, Back and overlays keep them.
  function restart() {
    if (window.__protoV) window.__protoV.reset();
    mem = {};
    var O = window.__protoOverlay;
    if (O) O.closeAll();
    then_ = null; pending = pendingBack = null; held = null;
    cur = null;
    settle();
    stack.length = 0;
    stack.push({ s: start, t: null });
    history.replaceState(null, '', '#' + start.id);
    show(start, null);
  }
  window.__protoRestart = restart;
  // (el: the layer whose reaction runs; a manual overlay is placed from it)
  function run(r, i, el) {
    i = i || 0;
    if (!r.acts || i >= r.acts.length) return;
    // (F4-int: a Change to doesn't wait for a motion still playing: it takes
    // it over from where it is, `show`'s snap)
    var go = function () { act(r.acts[i], function () { run(r, i + 1, el); }, el); };
    if (r.acts[i].k === 'changeTo') go(); else idle(go);
  }
  window.__protoRun = run;
  function fire(el, on, still) {
    ia(el).forEach(function (r) {
      if (r.on !== on) return;
      if (!r.ms) return run(r, 0, el);
      var g = gen;
      setTimeout(function () { if (g === gen && (!still || still())) run(r, 0, el); }, r.ms);
    });
  }
  function hold(kind, el, r) {
    if (held) return;
    var O = window.__protoOverlay;
    held = { kind: kind, origin: cur, depth: stack.length, rect: el.getBoundingClientRect(), ov: O ? O.depth() : 0, ovs: O ? O.top() : null };
    (r.acts || []).forEach(function (a) { if (a.k === 'changeTo' && !held.vt) { held.vt = parse(a.tr) || { k: 'instant' }; held.ti = a.ti; } });
    run(r, 0, el);
  }
  function revert() {
    var h = held;
    if (!h) return;
    if (busy.length || then_) { setTimeout(revert, 40); return; }
    held = null;
    // (overlays it opened close)
    var O = window.__protoOverlay;
    if (O && O.depth() > h.ov) O.closeTo(h.ov);
    var n = stack.length - h.depth;
    if (n > 0 && cur !== h.origin) { pendingBack = null; history.go(-n); }
    // (step 4: while hovering / pressing → Change to goes back)
    else if (h.vt && cur !== h.origin && vof(cur) === vof(h.origin)) {
      remember(h.origin);
      history.replaceState(null, '', '#' + h.origin.id);
      if (stack.length) stack[stack.length - 1].s = h.origin;
      show(h.origin, h.vt, true, h.ti);
    }
    // (L1: and inside the overlay it was over)
    else if (h.vt && O && h.ovs && O.find(h.ovs) && O.find(h.ovs).s !== h.ovs) {
      remember(h.ovs);
      O.change(h.ovs, h.vt, function () {}, h.ti);
    }
  }
  // ── afterDelay timers. A timer fires its reaction on the same layer in the
  // section shown by then (`data-ix`), so a Change to elsewhere doesn't stop
  // it; a Change to on its Instance restarts it (Play's rule).
  var armed = [];
  function arm(el, r, j, ok, home) {
    var tm = { ix: el.getAttribute('data-ix') };
    armed.push(tm);
    function off() { var i = armed.indexOf(tm); if (i >= 0) armed.splice(i, 1); }
    setTimeout(function () {
      if (tm.dead || !ok()) return off();
      idle(function () {
        off();
        if (tm.dead || !ok()) return;
        var h = home(), e2 = el;
        if (!h) return;
        if (!h.contains(el)) e2 = tm.ix ? h.querySelector('[data-ix="' + CSS.escape(tm.ix) + '"]') : null;
        var r2 = e2 === el ? r : e2 && ia(e2)[j];
        if (r2 && r2.on === 'afterDelay') run(r2, 0, e2);
      });
    }, r.ms || 0);
  }
  function inside_(ix, ti) { return !!ix && (ix === ti || ix.indexOf(ti + '/') === 0); }
  // (only: an Instance's id, its timers alone restart; undefined: all start)
  function armIn(s, ok, home, only) {
    if (only != null) armed.forEach(function (tm) { if (inside_(tm.ix, only)) tm.dead = true; });
    [].slice.call(s.querySelectorAll('[data-ia]')).forEach(function (el) {
      if (only != null && !inside_(el.getAttribute('data-ix'), only)) return;
      ia(el).forEach(function (r, j) { if (r.on === 'afterDelay') arm(el, r, j, ok, home); });
    });
  }
  window.__protoArm = armIn;
  // (ti: see show)
  shown = function (s, ti) {
    if (ti === undefined) gen++;
    under = [];
    var g = gen;
    if (ti === null) return;
    armIn(s, function () { return g === gen; }, function () { return cur; }, ti);
  };
  d.addEventListener('pointermove', function (e) {
    if (held && held.kind === 'hover') {
      var b = held.rect;
      var outside = function (x, y) { return x < b.left || x > b.right || y < b.top || y > b.bottom; };
      // (an overlay it opened keeps it while the pointer is in it; 100 ms to get there)
      var O = window.__protoOverlay;
      if (outside(e.clientX, e.clientY)) {
        if (O && O.depth() > held.ov) {
          var px = e.clientX, py = e.clientY, h0 = held;
          clearTimeout(h0.grace);
          h0.grace = setTimeout(function () { if (held === h0 && outside(lastX, lastY) && !O.inside(lastX, lastY, h0.ov)) revert(); }, 100);
        } else revert();
      }
    }
    lastX = e.clientX; lastY = e.clientY;
    if (drag && !drag.done) {
      var dx = e.clientX - drag.x, dy = e.clientY - drag.y;
      if (dx * dx + dy * dy >= 16) { drag.done = true; skipClick = true; run(drag.r); }
    }
    var now = [];
    for (var el = e.target.closest && e.target.closest('[data-ia]'); el; el = up_(el)) now.push(el);
    var was = under;
    under = now;
    was.forEach(function (x) { if (now.indexOf(x) < 0) fire(x, 'mouseLeave', function () { return under.indexOf(x) < 0; }); });
    now.forEach(function (x) {
      if (was.indexOf(x) >= 0) return;
      fire(x, 'mouseEnter', function () { return under.indexOf(x) >= 0; });
      ia(x).forEach(function (r) { if (r.on === 'hover') hold('hover', x, r); });
    });
  }, true);
  d.addEventListener('pointerdown', function (e) {
    skipClick = false;
    var p = find(e.target, 'press');
    if (p) hold('press', p.el, p.r);
    var dn = find(e.target, 'mouseDown');
    if (dn) fire(dn.el, 'mouseDown');
    var dg = find(e.target, 'drag');
    drag = dg ? { r: dg.r, x: e.clientX, y: e.clientY } : null;
  }, true);
  d.addEventListener('pointerup', function (e) {
    if (held && held.kind === 'press') revert();
    var u = find(e.target, 'mouseUp');
    if (u) fire(u.el, 'mouseUp');
    drag = null;
  }, true);
  addEventListener('hashchange', route);
  stack.push({ s: screen(here()) || start, t: null });
  show(stack[0].s, null);
})();
]]

-- (step 5) Variables in the page (engine/vars.luau's model, in JS). The
-- page's data comes first (vars_head): TOK = { name: { k: kind, c: [{ v,
-- t: theme, s: sig }] } }, RULES = the Token CSS as [selector, [[ident,
-- name, sig]]], DEF / AX / MA (default modes, axes' attribute names, a mode
-- value's axis), X = the expressions as functions of V. State: `o` = { name:
-- { sig: value } } overrides, `mode` = { axis: value } (as `data-<axis>` on
-- <html>, which the Token CSS already keys on). A layer's theme is the
-- nearest `data-<axis>` above it, so a pinned layer keeps its own mode and a
-- set writes only the candidate the clicked layer's theme picks (Figma's
-- per-mode write). After each change: the Token CSS is rebuilt (colours and
-- numbers are custom properties), then `data-bind` text, `data-show`
-- visibility (`data-off`, display none: an auto layout closes up) and bound
-- variant groups (`data-vg`, one member shown) follow. Restart resets.
M.VARS_JS = [[
  var d = document, html = d.documentElement, o = {}, mode = {}, sheet = null, problems = [];
  function $warn(c, m) { problems.push([c, m]); if (window.console) console.warn('prototype: ' + m); }
]] .. Expr.JS_HELPERS .. [[
  function ax(a) { return AX[a] || String(a).replace(/[^A-Za-z0-9_-]/g, '-'); }
  function themeAt(el) {
    var t = {}, seen = {}, a;
    for (a in DEF) t[a] = DEF[a];
    for (var e = el; e && e.getAttribute; e = e.parentElement)
      for (a in AX) if (!seen[a] && e.hasAttribute('data-' + AX[a])) { seen[a] = 1; t[a] = e.getAttribute('data-' + AX[a]); }
    return t;
  }
  function pick(tok, th) {
    var best = null, bn = -1;
    tok.c.forEach(function (c) {
      var ok = true, n = 0;
      for (var a in c.t) { n++; if (String(th[a]) !== String(c.t[a])) { ok = false; break; } }
      if (ok && n >= bn) { best = c; bn = n; }
    });
    return best || tok.c[0];
  }
  function read(name, th) {
    var tok = TOK[name];
    if (!tok) { $warn('var-unknown', 'the Design has no variable "' + name + '"'); return undefined; }
    var c = pick(tok, th), ov = o[name];
    return ov && (c.s in ov) ? ov[c.s] : c.v;
  }
  function getter(th) {
    return function (name, axis, m) {
      var t = th;
      if (m != null) { t = {}; for (var k in th) t[k] = th[k]; var a = axis || MA[m]; if (a) t[a] = m; }
      return read(name, t);
    };
  }
  function coerce(k, v) {
    if (k === 'number') return typeof v === 'number' && v === v ? v : undefined;
    if (k === 'string') return typeof v === 'string' ? v : typeof v === 'number' ? $fmt(v) : undefined;
    if (k === 'boolean') return typeof v === 'boolean' ? v : undefined;
    if (k === 'color') return typeof v === 'string' && /^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(v) ? v : undefined;
  }
  function write(name, v, th) {
    var tok = TOK[name];
    if (!tok) return $warn('var-unknown', 'the Design has no variable "' + name + '"');
    var x = coerce(tok.k, v);
    if (x === undefined) return $warn('var-type', 'a ' + tok.k + ' variable "' + name + '" can\'t hold ' + $fmt(v));
    (o[name] = o[name] || {})[pick(tok, th).s] = x;
  }
  function val(name, s) {
    var ov = o[name];
    if (ov && s in ov) return ov[s];
    var c = TOK[name].c;
    for (var i = c.length - 1; i >= 0; i--) if (c[i].s === s) return c[i].v;
  }
  function css(v) { return typeof v === 'string' ? (v.charAt(0) === '#' ? v : '"' + v.replace(/["\\]/g, '\\$&') + '"') : String(v); }
  function pv(v) { return typeof v === 'string' ? (v === '' ? null : v) : typeof v === 'boolean' || typeof v === 'number' ? String(v) : null; }
  function vis(el, on) { if (on) el.removeAttribute('data-off'); else if (!el.hasAttribute('data-off')) el.setAttribute('data-off', ''); }
  function all(sel, f) { [].forEach.call(d.querySelectorAll(sel), f); }
  function refresh() {
    if (!sheet) { sheet = d.createElement('style'); d.head.appendChild(sheet); }
    sheet.textContent = RULES.map(function (r) {
      return r[0] + ' { ' + r[1].map(function (e) { return '--' + e[0] + ': ' + css(val(e[1], e[2])) + ';'; }).join(' ') + ' }';
    }).join('\n');
    all('[data-bind]', function (el) { var t = $fmt(read(el.getAttribute('data-bind'), themeAt(el))); if (el.textContent !== t) el.textContent = t; });
    all('[data-show]', function (el) { vis(el, read(el.getAttribute('data-show'), themeAt(el)) === true); });
    // (a bound Instance's members are siblings: the one whose values match shows)
    var groups = new Map();
    all('[data-vg]', function (el) {
      var g = groups.get(el.parentNode);
      if (!g) groups.set(el.parentNode, g = {});
      (g[el.getAttribute('data-vg')] = g[el.getAttribute('data-vg')] || []).push(el);
    });
    groups.forEach(function (g) {
      for (var id in g) {
        var els = g[id], vb = JSON.parse(els[0].getAttribute('data-vb') || '{}'), th = themeAt(els[0]), want = {}, hit = null;
        for (var p in vb) want[p] = pv(read(vb[p], th));
        els.forEach(function (el) {
          if (!hit && JSON.parse(el.getAttribute('data-when') || '[]').some(function (w) { for (var p in w) if (w[p] !== want[p]) return false; return true; })) hit = el;
        });
        if (hit) els.forEach(function (el) { vis(el, el === hit); });
      }
    });
  }
  window.__protoV = {
    act: function (a, el) {
      var th = themeAt(el);
      if (a.k === 'set') { var v = a.x != null ? X[a.x](getter(th)) : a.to; if (v !== undefined) write(a.var, v, th); }
      else if (a.k === 'vset') (a.sets || []).forEach(function (p) { write(p[0], p[1], th); });
      else if (a.k === 'mode') { if (mode[a.axis] === a.value) return; mode[a.axis] = a.value; html.setAttribute('data-' + ax(a.axis), a.value); }
      refresh();
    },
    test: function (c, el) {
      var v = X[c](getter(themeAt(el)));
      if (typeof v !== 'boolean') { if (v !== undefined) $warn('var-type', 'a condition gave ' + $fmt(v) + ', not true or false'); return false; }
      return v;
    },
    reset: function () { for (var a in mode) html.removeAttribute('data-' + ax(a)); o = {}; mode = {}; refresh(); },
    read: function (name, el) { return read(name, themeAt(el || html)); },
    vars: function () { return o; },
    mode: function () { return mode; },
    problems: problems,
  };
})();
]]

-- A played transition as the router's `data-tr` text: "k dir ms ease",
-- ease = "x1,y1,x2,y2" or "L" .. linear() values (a spring).
local function tr_text(t: any): string
	local ease = if type(t.sp) == "table"
		then "L" .. table.concat(spring_values(t.sp, t.ms), ",")
		else `{num(t.ease[1])},{num(t.ease[2])},{num(t.ease[3])},{num(t.ease[4])}`
	return `{t.k} {t.dir or "-"} {num(t.ms)} {ease}` .. (if t.ml then " ml" else "")
end

-- Smart Animate (step 3, figma-parity.md §3.1) in the page: the pairs are
-- the elements with the same `data-mk` (the name path, as Play pairs them)
-- in the two Screens. Each frame (the transition's own ease, a spring's
-- linear() points included) moves and scales every pair from where it was
-- to where it is, nested pairs compensated for their parents; colours,
-- radius and opacity tween; changed words crossfade; layers only the new
-- Screen has fade in (where they are in their parent), those only the old
-- one has fade out; the Screen behind dissolves (or moves, with "Smart
-- animate matching layers"). Reduced motion is a cut (the router's).
M.SMART_JS = [[
(function () {
  function easer(s) {
    var m = /^linear\((.*)\)$/.exec(s || '');
    if (m) {
      var v = m[1].split(',').map(Number), n = v.length - 1;
      return function (x) { if (x <= 0) return v[0]; if (x >= 1) return v[n]; var f = x * n, i = Math.floor(f); return v[i] + (v[i + 1] - v[i]) * (f - i); };
    }
    m = /cubic-bezier\(([^)]*)\)/.exec(s || '');
    var b = m ? m[1].split(',').map(Number) : [0, 0, 0.58, 1];
    function cb(t, a1, a2) { return 3 * a1 * t * (1 - t) * (1 - t) + 3 * a2 * t * t * (1 - t) + t * t * t; }
    return function (x) {
      if (x <= 0) return 0; if (x >= 1) return 1;
      var lo = 0, hi = 1, t = x;
      for (var i = 0; i < 32; i++) { t = (lo + hi) / 2; if (cb(t, b[0], b[2]) < x) lo = t; else hi = t; }
      return cb(t, b[1], b[3]);
    };
  }
  function rgba(s) {
    var m = /rgba?\(([^)]*)\)/.exec(s || '');
    if (!m) return null;
    var p = m[1].split(/[\s,\/]+/).filter(Boolean).map(parseFloat);
    return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1];
  }
  function mix(a, b, q) {
    return 'rgba(' + Math.round(a[0] + (b[0] - a[0]) * q) + ',' + Math.round(a[1] + (b[1] - a[1]) * q) + ',' + Math.round(a[2] + (b[2] - a[2]) * q) + ',' + (a[3] + (b[3] - a[3]) * q).toFixed(3) + ')';
  }
  // (in CSS px of the page, which may be scaled: window.__protoZ. The ghosts
  // are fixed in <body>, outside the scale, so they take Z back on.)
  function zoom() { return window.__protoZ || 1; }
  function rect(el) { var r = el.getBoundingClientRect(), Z = zoom(); return { x: r.left / Z, y: r.top / Z, w: r.width / Z, h: r.height / Z }; }
  // an element's own turn in CSS degrees (clockwise), from its computed transform
  function turnOf(el) { var m = /matrix\(([^,]+),\s*([^,]+)/.exec(getComputedStyle(el).transform || ''); return m ? Math.atan2(parseFloat(m[2]), parseFloat(m[1])) * 180 / Math.PI : 0; }
  function look(el) {
    var c = getComputedStyle(el);
    return { bg: rgba(c.backgroundColor), fg: rgba(c.color), r: parseFloat(c.borderTopLeftRadius) || 0, op: parseFloat(c.opacity), fs: c.fontSize };
  }
  // (F4-int) where a section's layers are on screen now, mid-motion
  window.__protoSnap = function (sec) {
    var o = {};
    [].slice.call(sec.querySelectorAll('[data-mk]')).forEach(function (el) { o[el.getAttribute('data-mk')] = { F: rect(el), a: look(el) }; });
    return o;
  };
  window.__protoSmart = function (prev, next, t, busy, finish, snap) {
    var ml = !!t.ml && t.k !== 'smart', E = easer(t.ease), k = t.k;
    var W = next.clientWidth || innerWidth, H = next.clientHeight || innerHeight;
    var v = { left: [-1, 0], right: [1, 0], up: [0, -1], down: [0, 1] }[t.dir] || [0, 0];
    var saved = [];
    function keep(el) { saved.push([el, el.getAttribute('style')]); }
    var from = {};
    [].slice.call(prev.querySelectorAll('[data-mk]')).forEach(function (el) { from[el.getAttribute('data-mk')] = el; });
    var nodes = [], used = {}, olds = [];
    function walk(el, pi, root) {
      var mk = el.getAttribute('data-mk'), src = mk && from[mk];
      var n = { el: el, p: pi, L: rect(el), root: root };
      if (src) {
        used[mk] = true;
        var sn = snap && snap[mk];
        n.src = src; n.F = sn ? sn.F : rect(src); n.a = sn ? sn.a : look(src); n.b = look(el);
        // (other words, or another size: the two crossfade)
        n.x = el.children.length === 0 && (src.textContent !== el.textContent || n.a.fs !== n.b.fs);
        // (a leaf whose turn changes: tweened about its centre, frame below)
        var ta = turnOf(src), tb = turnOf(el);
        n.turn = el.children.length === 0 && Math.abs(ta - tb) > 0.01 ? [ta, tb] : null;
      } else if (pi > 0 && (nodes[pi].src || (!ml && nodes[pi].root))) {
        n.fade = true; n.op = parseFloat(getComputedStyle(el).opacity) || 1;
      }
      nodes.push(n);
      var me = nodes.length - 1;
      if (!n.fade) for (var c = el.firstElementChild; c; c = c.nextElementSibling) walk(c, me, false);
    }
    nodes.push({ el: next, p: -1, L: rect(next), sec: true });
    if (next.firstElementChild) walk(next.firstElementChild, 0, true);
    // (the old Screen's pairs step aside; what only it has fades out)
    function ghost(c, mk) {
      var r0 = rect(c), gc = c.cloneNode(true), Z = zoom();
      gc.removeAttribute('data-mk');
      gc.style.cssText += ';position:fixed;left:' + r0.x * Z + 'px;top:' + r0.y * Z + 'px;margin:0;width:' + r0.w + 'px;height:' + r0.h + 'px;pointer-events:none;z-index:2147483000;visibility:visible;transform-origin:0 0;transform:' + (Z === 1 ? 'none' : 'scale(' + Z + ')');
      document.body.appendChild(gc);
      olds.push({ g: gc, mk: mk, z: Z });
    }
    var inner = [];
    for (var mk in from) {
      if (!used[mk]) continue;
      var s = from[mk];
      keep(s);
      s.style.visibility = 'hidden';
      // (as ghosts over the new Screen, following their parent at their own
      // offset, unscaled: Figma's, filmed)
      // (inside the new pair when it has a plate, so they stay at its place
      // in the paint order, under the layers after it: the list row's body
      // under the rows below as they slide up (Figma's, filmed, f3c))
      var before = null;
      for (var c = s.firstElementChild; c; c = c.nextElementSibling) {
        if (used[c.getAttribute('data-mk')]) before = c.getAttribute('data-mk'); else inner.push([c, mk, before]);
      }
    }
    // (a layer only the old Screen has, above a pair there, is drawn over the
    // new Screen while it fades: "Figma will animate them above the destination")
    var top0 = prev.firstElementChild, seen = false;
    if (top0) for (var c = top0.firstElementChild; c; c = c.nextElementSibling) {
      var cm = c.getAttribute('data-mk');
      if (used[cm] || (c.querySelector && [].some.call(c.querySelectorAll('[data-mk]'), function (e) { return used[e.getAttribute('data-mk')]; }))) { seen = true; continue; }
      if (seen && getComputedStyle(c).visibility !== 'hidden') { keep(c); ghost(c, null); c.style.visibility = 'hidden'; }
    }
    var ghosts = [], byMk = {};
    nodes.forEach(function (n) {
      keep(n.el);
      if (n.src) byMk[n.el.getAttribute('data-mk')] = n;
      // text: both looks scale by the box's height (Figma's, filmed)
      n.t = n.src && n.el.children.length === 0 && /\S/.test(n.el.textContent || '');
      if (n.t) { var ta = getComputedStyle(n.el).textAlign; n.ax = ta === 'center' ? 0.5 : (ta === 'right' || ta === 'end') ? 1 : 0; }
      if (n.x) {
        var g = n.src.cloneNode(true);
        g.removeAttribute('data-mk');
        g.style.cssText += ';position:fixed;left:0;top:0;margin:0;width:' + n.F.w + 'px;height:' + n.F.h + 'px;transform-origin:0 0;pointer-events:none;z-index:2147483000;visibility:visible';
        document.body.appendChild(g);
        ghosts.push(g); n.g = g;
      }
      // a pair with layers inside isn't scaled (that would stretch what's
      // inside): it keeps its size, its look (fill, radius, outline, shadow)
      // goes on a plate under its layers at the tweened size, and its layers
      // keep their offsets from its top-left
      if (n.src && n.el.children.length > 0) {
        var cs = getComputedStyle(n.el), pl = document.createElement('div');
        pl.style.cssText = 'position:absolute;left:0;top:0;z-index:-1;pointer-events:none;box-sizing:border-box;margin:0;background:' + cs.background + ';border:' + cs.border + ';box-shadow:' + cs.boxShadow + ';border-radius:' + cs.borderRadius;
        n.el.insertBefore(pl, n.el.firstChild);
        ghosts.push(pl); n.pl = pl;
        n.el.style.background = 'transparent'; n.el.style.borderColor = 'transparent'; n.el.style.boxShadow = 'none';
        if (cs.position === 'static') n.el.style.position = 'relative';
        n.clip = cs.overflow === 'hidden' || cs.overflowX === 'hidden';
      }
      if (n.src || n.sec) n.el.style.transformOrigin = '0 0';
    });
    inner.forEach(function (e) {
      var c = e[0], pm = e[1], n = byMk[pm];
      if (!n || !n.pl) return ghost(c, e[1]);
      var r0 = rect(c), gc = c.cloneNode(true), bw = parseFloat(getComputedStyle(n.el).borderLeftWidth) || 0, bt = parseFloat(getComputedStyle(n.el).borderTopWidth) || 0;
      [gc].concat([].slice.call(gc.querySelectorAll('[data-mk]'))).forEach(function (x) { x.removeAttribute('data-mk'); });
      gc.style.cssText += ';position:absolute;left:' + (r0.x - n.F.x - bw) + 'px;top:' + (r0.y - n.F.y - bt) + 'px;margin:0;width:' + r0.w + 'px;height:' + r0.h + 'px;pointer-events:none;visibility:visible;transform:none';
      // (its place among its siblings: after the paired one before it)
      var ref = null;
      if (e[2]) for (var k = n.el.firstElementChild; k; k = k.nextElementSibling) if (k.getAttribute('data-mk') === e[2]) ref = k;
      if (!ref) ref = n.pl;
      n.el.insertBefore(gc, ref.nextSibling);
      olds.push({ g: gc, mk: null });
    });
    var rootN = nodes[1], rootBg = rootN ? look(rootN.el).bg : null;
    var nsec = next.style.background;
    if (!ml) next.style.background = 'transparent';
    keep(prev);
    function at(f) { return [v[0] * W * f, v[1] * H * f]; }
    function lerp2(a, b, p) { return [a[0] + (b[0] - a[0]) * p, a[1] + (b[1] - a[1]) * p]; }
    function frame(p) {
      var q = Math.max(0, Math.min(1, p));
      var nx = [0, 0], px = [0, 0];
      if (ml) {
        if (k === 'push' || k === 'moveIn' || k === 'slideIn') nx = lerp2(at(-1), at(0), p);
        if (k === 'slideOut') { nx = lerp2(at(-0.3), at(0), p); next.style.opacity = 0.4 + 0.6 * q; }
        if (k === 'push' || k === 'moveOut' || k === 'slideOut') px = lerp2(at(0), at(1), p);
        if (k === 'slideIn') { px = lerp2(at(0), at(0.3), p); prev.style.opacity = 1 - 0.6 * q; }
        prev.style.transform = 'translate(' + px[0] + 'px,' + px[1] + 'px)';
      } else if (rootBg) {
        rootN.el.style.backgroundColor = mix([rootBg[0], rootBg[1], rootBg[2], 0], rootBg, q);
      }
      var maps = [];
      nodes.forEach(function (n, i) {
        if (n.sec) {
          n.el.style.transform = 'translate(' + nx[0] + 'px,' + nx[1] + 'px)';
          maps[i] = { ax: 1, bx: n.L.x + nx[0], ay: 1, by: n.L.y + nx[1] };
          return;
        }
        var P = maps[n.p], up = nodes[n.p], ox = n.L.x - up.L.x, oy = n.L.y - up.L.y;
        if (!n.src) {
          maps[i] = { ax: P.ax, bx: P.bx + P.ax * ox, ay: P.ay, by: P.by + P.ay * oy };
          if (n.fade) n.el.style.opacity = n.op * q;
          return;
        }
        var R = { x: n.F.x + (n.L.x - n.F.x) * p, y: n.F.y + (n.L.y - n.F.y) * p, w: Math.max(0, n.F.w + (n.L.w - n.F.w) * p), h: Math.max(0, n.F.h + (n.L.h - n.F.h) * p) };
        n.R = R;
        var sx, sy, X = R.x;
        if (n.pl) { sx = 1 / P.ax; sy = 1 / P.ay; }
        else if (n.t) { sx = n.L.h ? R.h / (P.ax * n.L.h) : 1 / P.ax; sy = n.L.h ? R.h / (P.ay * n.L.h) : 1 / P.ay; X = R.x + (R.w - n.L.w * sx * P.ax) * n.ax; }
        else { sx = !n.L.w ? 1 / P.ax : R.w / (P.ax * n.L.w); sy = !n.L.h ? 1 / P.ay : R.h / (P.ay * n.L.h); }
        var tx = (X - P.bx) / P.ax - ox, ty = (R.y - P.by) / P.ay - oy;
        n.el.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + sx + ',' + sy + ')';
        // (a turn: about its centre, as Figma plays it; a box's centre is its
        // turned layer's, so the centre goes straight from one end's to the other's)
        if (n.turn && P.ax === 1 && P.ay === 1) {
          var th = n.turn[0] + (n.turn[1] - n.turn[0]) * p, wb = n.el.offsetWidth, hb = n.el.offsetHeight;
          var wa = n.src.offsetWidth, ha = n.src.offsetHeight, rb = n.turn[1] * Math.PI / 180;
          // its own box's centre: the laid-out box, before its own turn (about 0 0)
          var ux = n.L.x + n.L.w / 2 - (wb / 2 * Math.cos(rb) - hb / 2 * Math.sin(rb) - wb / 2);
          var uy = n.L.y + n.L.h / 2 - (wb / 2 * Math.sin(rb) + hb / 2 * Math.cos(rb) - hb / 2);
          var ksx = wb ? (wa + (wb - wa) * p) / wb : 1, ksy = hb ? (ha + (hb - ha) * p) / hb : 1;
          n.el.style.transformOrigin = '50% 50%';
          // (less where its parent is now against where it ends)
          ux += P.bx - up.L.x; uy += P.by - up.L.y;
          n.el.style.transform = 'translate(' + (R.x + R.w / 2 - ux) + 'px,' + (R.y + R.h / 2 - uy) + 'px) rotate(' + th + 'deg) scale(' + ksx + ',' + ksy + ')';
        }
        maps[i] = { ax: P.ax * sx, bx: X, ay: P.ay * sy, by: R.y };
        var a = n.a, b = n.b, box = n.pl ? n.pl.style : n.el.style;
        if (n.pl) {
          box.width = (R.w / (P.ax * sx)) + 'px'; box.height = (R.h / (P.ay * sy)) + 'px';
          // (what it clips is cut at its tweened size)
          if (n.clip) { n.el.style.overflow = 'visible'; n.el.style.clipPath = 'inset(0 ' + (n.L.w - R.w) + 'px ' + (n.L.h - R.h) + 'px 0 round ' + (a.r + (b.r - a.r) * q) + 'px)'; }
        }
        if (a.bg && b.bg && (a.bg + '') !== (b.bg + '')) box.backgroundColor = mix(a.bg, b.bg, q);
        if (a.fg && b.fg && (a.fg + '') !== (b.fg + '') && !n.x) n.el.style.color = mix(a.fg, b.fg, q);
        var r = a.r + (b.r - a.r) * q, ex = n.pl ? 1 : maps[i].ax, ey = n.pl ? 1 : maps[i].ay;
        if (r > 0 || b.r > 0) box.borderRadius = (r / (ex || 1)) + 'px / ' + (r / (ey || 1)) + 'px';
        var op = a.op + (b.op - a.op) * q;
        n.el.style.opacity = n.x ? op * q : op;
        if (n.g) {
          var gs = n.F.h ? R.h / n.F.h : 1, gx = n.t ? R.x + (R.w - n.F.w * gs) * n.ax : R.x, gz = zoom();
          n.g.style.transform = 'translate(' + gx * gz + 'px,' + R.y * gz + 'px) scale(' + gs * gz + ')'; n.g.style.opacity = a.op * (1 - q);
        }
      });
      olds.forEach(function (o) {
        o.g.style.opacity = 1 - q;
        var n = o.mk && byMk[o.mk];
        var oz = o.z || 1;
        if (n && n.R) o.g.style.transform = 'translate(' + (n.R.x - n.F.x) * oz + 'px,' + (n.R.y - n.F.y) * oz + 'px)' + (oz === 1 ? '' : ' scale(' + oz + ')');
      });
    }
    var stop = false;
    function restore() {
      stop = true;
      ghosts.concat(olds.map(function (o) { return o.g; })).forEach(function (g) { if (g.parentNode) g.parentNode.removeChild(g); });
      for (var i = saved.length - 1; i >= 0; i--) { var s = saved[i]; if (s[1] == null) s[0].removeAttribute('style'); else s[0].setAttribute('style', s[1]); }
      next.style.background = nsec;
    }
    busy.push({ cancel: restore });
    // (the new Screen over the old whatever their order in the page: going
    // back to an earlier Screen, the old one's background hid everything)
    if (k === 'moveOut' || k === 'slideOut') next.style.zIndex = 1; else next.style.zIndex = 2;
    frame(0);
    var t0 = null;
    function tick(now) {
      if (stop) return;
      if (t0 === null) t0 = now;
      var x = Math.min(1, (now - t0) / Math.max(1, t.ms));
      frame(E(x));
      if (x < 1) requestAnimationFrame(tick); else finish();
    }
    requestAnimationFrame(tick);
  };
})();
]]

-- JSON for data-ia (strings, numbers, booleans, lists, records; keys sorted).
local function json_text(v: any): string
	local t = type(v)
	if t == "string" then
		return '"' .. string.gsub(v, '[%c"\\]', function(c)
			return string.format("\\u%04x", string.byte(c))
		end) .. '"'
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			return "0"
		end
		-- (step 5: variables' values exactly, when 2 decimals would round them)
		local s = num(v)
		if tonumber(s) ~= v then
			s = string.format("%.17g", v)
			local short = string.format("%.15g", v)
			if tonumber(short) == v then
				s = short
			end
		end
		return s
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "table" then
		local parts = {}
		if #v > 0 or next(v) == nil then
			for _, x in v do
				table.insert(parts, json_text(x))
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for k in v do
			table.insert(keys, tostring(k))
		end
		table.sort(keys)
		for _, k in keys do
			table.insert(parts, json_text(k) .. ":" .. json_text(v[k]))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "null"
end

-- (step 5) Every act of a list, an if's branches included.
local function each_act(list: any, visit: (any) -> ())
	for _, a in list or {} do
		visit(a)
		if a.k == "if" then
			each_act(a.th, visit)
			each_act(a.el, visit)
		end
	end
end

-- (step 5) The page's expressions while M.html runs: { list = { js }, by =
-- { [js] = index } }. Each is printed once by Expr.js (V1's compiler, the
-- same AST Play's closures come from) and called as X[i](V).
local XREG: any = nil
local function x_index(src: any): number?
	if not XREG or type(src) ~= "string" then
		return nil
	end
	local ast = Expr.parse(src)
	if not ast then
		return nil
	end
	local js = Expr.js(ast)
	local i = XREG.by[js]
	if not i then
		table.insert(XREG.list, js)
		i = #XREG.list - 1
		XREG.by[js] = i
	end
	return i
end

local VAR_ACTS = { set = true, mode = true, ["if"] = true, vset = true }

-- One played act as the router's JSON (an if's branches inside it).
local function act_json(a: any): any
	local x: any = { k = a.k }
	if VAR_ACTS[a.k] and XREG then
		XREG.used = true
	end
	for _, key in { "go", "url", "nt", "to", "ox", "oy", "rs", "rc", "play", "broken", "pos", "ti", "var", "axis", "value", "sets" } do
		if a[key] ~= nil then
			x[key] = a[key]
		end
	end
	if a.tr then
		x.tr = tr_text(a.tr)
	end
	if a.k == "set" and a.ex then
		local i = x_index(a.ex)
		if i then
			x.x = i
		else
			x.broken = true
		end
	elseif a.k == "if" then
		local i = x_index(a.cond)
		if i then
			x.c = i
		else
			x.broken = true
		end
		x.th, x.el = {}, {}
		for _, b in a.th or {} do
			table.insert(x.th, act_json(b))
		end
		for _, b in a.el or {} do
			table.insert(x.el, act_json(b))
		end
	end
	return x
end

-- Reactions the plain link can't carry (another trigger, or several
-- actions) as JSON for the router (`data-ia`); "" when the link says it all.
local function ia_attr(item: any): string
	local need = false
	for _, e in item.ia or {} do
		if (e.on or "click") ~= "click" or #(e.acts or {}) > 1 or (e.acts and e.acts[1] and e.acts[1].k == "motion") then
			need = true
		end
		-- (overlays, step 2: the router opens, swaps and closes them; step 5:
		-- and runs variables' acts)
		for _, a in e.acts or {} do
			if a.k == "overlay" or a.k == "swap" or a.k == "close" or a.k == "changeTo" or a.rc or VAR_ACTS[a.k] then
				need = true
			end
		end
	end
	if not need then
		return ""
	end
	local list = {}
	for _, e in item.ia do
		local r: any = { on = e.on or "click", acts = {} }
		if e.ms then
			r.ms = e.ms
		end
		if e.keys then
			r.keys = e.keys
		end
		for _, a in e.acts or {} do
			table.insert(r.acts, act_json(a))
		end
		table.insert(list, r)
	end
	return ` data-ia="{escape(json_text(list))}"`
end

-- A link item's first move as attributes: tag ("a" or nil) and attrs, then
-- its `data-ia` (step 2's triggers and action lists).
local function link_attrs(item: any, nested: boolean, is_svg: boolean): (string?, string, string)
	-- (the link is the first click reaction's first move)
	local e = nil
	for _, x in item.ia or {} do
		if (x.on or "click") == "click" and (x.go or x.url) then
			e = x
			break
		end
	end
	local ia = ia_attr(item)
	if not e then
		return nil, "", ia
	end
	local tr = ""
	if e.tr then
		tr = ` data-tr="{tr_text(e.tr)}"`
	end
	local plain = nested or is_svg
	if e.go == "back" then
		if plain then
			return nil, ` data-back role="link" tabindex="0"{tr}`, ia
		end
		return "a", ` href="#" data-back{tr}`, ia
	elseif e.go then
		if plain then
			return nil, ` data-go="{escape(e.go)}" role="link" tabindex="0"{tr}`, ia
		end
		return "a", ` href="#{escape(e.go)}"{tr}`, ia
	elseif e.url then
		if plain then
			return nil, ` data-url="{escape(e.url)}" role="link" tabindex="0"`, ia
		end
		return "a", ` href="{escape(e.url)}"` .. (if e.nt == false then "" else ' target="_blank" rel="noopener"'), ia
	end
	return nil, "", ia
end

local EXACT = {
	["display:flex"] = "flex", ["flex-direction:row"] = "flex-row", ["flex-direction:column"] = "flex-col",
	["position:relative"] = "relative", ["position:absolute"] = "absolute", ["overflow:hidden"] = "overflow-hidden",
	["flex:1 1 0"] = "flex-1", ["flex-shrink:0"] = "shrink-0", ["align-self:stretch"] = "self-stretch",
	["min-width:0"] = "min-w-0", ["min-height:0"] = "min-h-0", ["justify-content:flex-start"] = "justify-start",
	["justify-content:center"] = "justify-center", ["justify-content:flex-end"] = "justify-end",
	["justify-content:space-between"] = "justify-between", ["justify-content:space-around"] = "justify-around",
	["align-items:flex-start"] = "items-start", ["align-items:center"] = "items-center", ["align-items:flex-end"] = "items-end",
	["white-space:pre"] = "whitespace-pre", ["white-space:pre-wrap"] = "whitespace-pre-wrap", ["text-align:center"] = "text-center",
	["text-align:right"] = "text-right", ["text-align:justify"] = "text-justify", ["text-decoration:underline"] = "underline",
	["text-decoration:line-through"] = "line-through", ["border-radius:50%"] = "rounded-full", ["margin:0"] = "m-0",
}
local PREFIX = {
	width = "w", height = "h", left = "left", top = "top", gap = "gap", padding = "p", ["border-radius"] = "rounded",
	opacity = "opacity", ["font-size"] = "text", ["font-weight"] = "font", ["line-height"] = "leading", ["letter-spacing"] = "tracking",
}
function arbitrary(v: string): string
	return (string.gsub(string.gsub(v, "_", "\\_"), " ", "_"))
end
local function tailwind(d: { { string } }): string
	local out = {}
	for _, x in d do
		local k, v = x[1], x[2]
		local exact = EXACT[k .. ":" .. v]
		if exact then
			table.insert(out, exact)
		elseif k == "background-color" then
			table.insert(out, `bg-[color:{arbitrary(v)}]`)
		elseif k == "color" then
			table.insert(out, `text-[color:{arbitrary(v)}]`)
		elseif PREFIX[k] then
			table.insert(out, `{PREFIX[k]}-[{arbitrary(v)}]`)
		else
			table.insert(out, `[{k}:{arbitrary(v)}]`)
		end
	end
	return table.concat(out, " ")
end

-- ── scrolling and the device (step 2, figma-parity.md §3.2) ────────────────

EXACT["overflow-x:auto"] = "overflow-x-auto"
EXACT["overflow-y:auto"] = "overflow-y-auto"
EXACT["overflow-x:hidden"] = "overflow-x-hidden"
EXACT["overflow-y:hidden"] = "overflow-y-hidden"
EXACT["overscroll-behavior:contain"] = "overscroll-contain"
EXACT["position:sticky"] = "sticky"
EXACT["top:0"] = "top-0"
EXACT["z-index:1"] = "z-[1]"

-- A Screen's scroll key: Figma shares scroll positions between Screens of
-- the same name, or the same name before a "/" ("Checkout / 1" and
-- "Checkout / 2").
local function screen_key(name: any): string
	local s = tostring(name or "")
	s = string.match(s, "^(.-)%s*/") or s
	return (string.gsub(string.lower(s), "^%s*(.-)%s*$", "%1"))
end
M.screen_key = screen_key

-- The fixed layer of a scroller: a zero-size box that sticks to the
-- scrollport's top-left, holding the fixed layers at their places. (In a
-- flex scroller a negative margin takes back the gap it would add.)
local function fixed_layer_open(scroller: any, node: any, indent: string): string
	-- (flow-root: an empty box's margins would collapse through it, and a
	-- sticky sibling's margin would carry it down)
	-- (F2c fix: a padded scroller's sticky box starts at its content edge, so
	-- the layer came out `padding` too far in: take the padding back, as
	-- margin for where it rests and as top/left for where it sticks, and
	-- give the flow it back after it)
	local pt, pl = 0, 0
	if node and (node.layout == "horizontal" or node.layout == "vertical") then
		local p = node.padding
		if type(p) == "number" then
			pt, pl = p, p
		elseif type(p) == "table" then
			if #p == 1 then
				pt, pl = U.num(p[1], 0), U.num(p[1], 0)
			elseif #p == 2 then
				pt, pl = U.num(p[1], 0), U.num(p[2], 0)
			elseif #p == 4 then
				pt, pl = U.num(p[1], 0), U.num(p[4], 0)
			end
		end
	end
	local st = `position: sticky; top: {px(-pt)}; left: {px(-pl)}; display: flow-root; width: 0; height: 0; overflow: visible; z-index: 3; flex-shrink: 0`
	local g = U.num(node and node.gap, 0)
	if scroller.lay == "horizontal" then
		st ..= `; margin-left: {px(-pl)}; margin-top: {px(-pt)}`
		if pl - g ~= 0 then
			st ..= `; margin-right: {px(pl - g)}`
		end
	else
		st ..= `; margin-top: {px(-pt)}; margin-left: {px(-pl)}`
		local after = pt - (if scroller.lay == "vertical" then g else 0)
		if after ~= 0 then
			st ..= `; margin-bottom: {px(after)}`
		end
	end
	return `{indent}<div class="fixed-layer" aria-hidden="false" style="{st}">`
end

-- What an item's actions add for scrolling: a scrollTo (`data-scroll-to`,
-- its offset and animation) and a navigate that resets the scroll.
local function scroll_attrs(item: any, is_link: boolean): (string, { string })
	local out, targets = "", {}
	-- (reactions the router runs from `data-ia`, as ia_attr decides: then
	-- it calls window.__protoScrollTo itself)
	local routed = false
	for _, e in item.ia or {} do
		if (e.on or "click") ~= "click" or #(e.acts or {}) > 1 or (e.acts and e.acts[1] and e.acts[1].k == "motion") then
			routed = true
		end
	end
	for _, e in item.ia or {} do
		if e.on ~= nil and e.on ~= "click" then
			continue
		end
		for _, a in e.acts or {} do
			if a.k == "scrollTo" and type(a.to) == "string" and routed then
				table.insert(targets, a.to)
			elseif a.k == "scrollTo" and type(a.to) == "string" and not string.find(out, "data-scroll-to", 1, true) then
				out ..= ` data-scroll-to="{escape(a.to)}"`
				if (a.ox or 0) ~= 0 or (a.oy or 0) ~= 0 then
					out ..= ` data-scroll-off="{num(a.ox or 0)} {num(a.oy or 0)}"`
				end
				if a.tr then
					local b = a.tr.ease or { 0, 0, 0.58, 1 }
					local ease = if type(a.tr.sp) == "table"
						then "L" .. table.concat(spring_values(a.tr.sp, a.tr.ms), ",")
						else `{num(b[1])},{num(b[2])},{num(b[3])},{num(b[4])}`
					out ..= ` data-scroll-tr="{num(a.tr.ms)} {ease}"`
				end
				if not is_link then
					out ..= ` role="button" tabindex="0"`
				end
				table.insert(targets, a.to)
			elseif a.k == "navigate" and a.rs and not string.find(out, "data-reset-scroll", 1, true) then
				out ..= " data-reset-scroll"
			end
		end
	end
	return out, targets
end

local SCROLL_CSS = [[
body.proto.device main { position: absolute; left: max(0px, calc(50% - var(--device-w) / 2)); top: max(0px, calc(50% - var(--device-h) / 2)); width: var(--device-w); height: var(--device-h); overflow: hidden; }
.screen { background: var(--proto-bg, #18181b); }
[data-scroll-to] { cursor: pointer; }
.device-stage { display: contents; }
.device-frame { display: none; }
html.framed .device-stage { display: block; position: absolute; left: 0; top: 0; width: var(--df-w); height: var(--df-h); transform-origin: 0 0; }
html.framed body.proto.device main { left: var(--df-l); top: var(--df-t); }
html.framed .device-frame { display: block; position: absolute; left: 0; top: 0; pointer-events: none; }
html.framed .device-frame.over { z-index: 2; }
html.fill-screen, html.fill-screen body { overflow: hidden; }]]

-- The device frame and the scaling (step 6, pure/anim/f6/PLAN.md E1). With
-- a framed preset, the frame shows when the window is at least 1.2 × the
-- device's width and the URL has no `frame=0`; then the device is scaled
-- by `data-dfit`: "fit" (whole, at most 100%), "fill" (the screen fills
-- the window) or "actual". Without the frame, `data-fit` "width" scales
-- the screen to the window's width and "fill" covers the window (cropped);
-- the others stay at 100%, centred, as before.
M.FRAME_JS = [[
(function () {
  var d = document, de = d.documentElement, b = d.body, st = d.querySelector('.device-stage');
  if (!st) return;
  var main = st.querySelector('main'), framed = !!st.querySelector('.device-frame');
  var no = /[?&]frame=0(&|$)/.test(location.search);
  var dw = +st.getAttribute('data-w'), dh = +st.getAttribute('data-h');
  var ins = (st.getAttribute('data-inset') || '0 0 0 0').split(' ').map(Number);
  var fit = b.getAttribute('data-fit') || 'fit', dfit = b.getAttribute('data-dfit') || 'fit';
  function lay() {
    var W = de.clientWidth || innerWidth, H = innerHeight;
    var on = framed && !no && W >= 1.2 * dw;
    de.classList.toggle('framed', on);
    de.classList.remove('fill-screen');
    st.style.left = st.style.top = st.style.transform = '';
    main.style.left = main.style.top = main.style.transform = main.style.transformOrigin = '';
    // (G) the page's scale: the overlay, scroll-to and Smart Animate scripts
    // divide what getBoundingClientRect measures by it, so they work in CSS px
    window.__protoZ = 1;
    if (on) {
      var fw = dw + ins[0] + ins[2], fh = dh + ins[1] + ins[3], s = 1;
      if (dfit === 'fit') s = Math.min(1, W / fw, H / fh);
      else if (dfit === 'fill') s = Math.min(W / dw, H / dh);
      var x = dfit === 'fill' ? (W - dw * s) / 2 - ins[0] * s : Math.max(0, (W - fw * s) / 2);
      var y = dfit === 'fill' ? (H - dh * s) / 2 - ins[1] * s : Math.max(0, (H - fh * s) / 2);
      if (dfit === 'fill') de.classList.add('fill-screen');
      st.style.left = x + 'px'; st.style.top = y + 'px';
      if (s !== 1) st.style.transform = 'scale(' + s + ')';
      window.__protoZ = s;
    } else if (fit === 'width' || fit === 'fill') {
      var k = fit === 'width' ? W / dw : Math.max(W / dw, H / dh);
      main.style.transformOrigin = '0 0';
      main.style.transform = 'scale(' + k + ')';
      window.__protoZ = k;
      main.style.left = (fit === 'width' ? 0 : (W - dw * k) / 2) + 'px';
      main.style.top = (fit === 'width' ? Math.max(0, (H - dh * k) / 2) : (H - dh * k) / 2) + 'px';
      if (fit === 'fill') de.classList.add('fill-screen');
    }
    b.setAttribute('data-framed', on ? '1' : '0');
  }
  lay();
  addEventListener('resize', lay);
  window.__protoLayout = lay;
})();
]]

-- Scroll memory and scroll-to (works beside the router, whatever it does
-- with a Screen's own scroll): a Screen that shows takes back where its
-- scrollers were, by `data-sk`, unless the link that brought it had
-- data-reset-scroll; a [data-scroll-to] scrolls the nearest scroller around
-- its target ([data-node]) to it, animated with its own time and curve.
M.SCROLL_JS = [[
(function () {
  var d = document, mem = {}, reset = false;
  function key(el) { return el.getAttribute('data-sk'); }
  d.addEventListener('scroll', function (e) {
    var el = e.target; if (!el.getAttribute) return;
    var k = key(el); if (k) mem[k] = [el.scrollLeft, el.scrollTop];
  }, true);
  d.addEventListener('click', function (e) {
    var el = e.target.closest && e.target.closest('[data-reset-scroll]');
    if (el) reset = true;
  }, true);
  function restore(s) {
    var all = [s].concat([].slice.call(s.querySelectorAll('[data-sk]')));
    all.forEach(function (el) {
      var k = key(el); if (!k) return;
      var m = !reset && mem[k];
      el.scrollLeft = m ? m[0] : 0; el.scrollTop = m ? m[1] : 0;
    });
    reset = false;
  }
  var seen = new WeakMap();
  new MutationObserver(function (list) {
    list.forEach(function (r) {
      var s = r.target, on = s.classList.contains('on');
      if (on && !seen.get(s)) restore(s);
      seen.set(s, on);
    });
  }).observe(d.body, { subtree: true, attributes: true, attributeFilter: ['class'] });
  function bez(x1, y1, x2, y2) {
    function a(p1, p2) { return 1 - 3 * p2 + 3 * p1; } function b(p1, p2) { return 3 * p2 - 6 * p1; } function c(p1) { return 3 * p1; }
    function at(t, p1, p2) { return ((a(p1, p2) * t + b(p1, p2)) * t + c(p1)) * t; }
    function slope(t, p1, p2) { return 3 * a(p1, p2) * t * t + 2 * b(p1, p2) * t + c(p1); }
    return function (x) {
      var t = x; for (var i = 0; i < 8; i++) { var s = slope(t, x1, x2); if (!s) break; t -= (at(t, x1, x2) - x) / s; }
      return at(Math.min(1, Math.max(0, t)), y1, y2);
    };
  }
  function scroller(el) {
    for (var p = el.parentElement; p; p = p.parentElement) {
      if (p.hasAttribute('data-sk')) {
        var cs = getComputedStyle(p);
        if (/(auto|scroll)/.test(cs.overflowY + cs.overflowX)) return p;
      }
    }
    return null;
  }
  // an ease from its text: "x1,y1,x2,y2", or "L" and linear() values (a spring)
  function easeOf(s) {
    if (s && s.charAt(0) === 'L') {
      var v = s.slice(1).split(',').map(Number), n = v.length - 1;
      return function (k) { var i = Math.min(n - 1, Math.floor(k * n)), f = k * n - i; return n < 1 ? 1 : v[i] + (v[i + 1] - v[i]) * f; };
    }
    return bez.apply(null, (s || '0,0,0.58,1').split(',').map(Number));
  }
  // Scroll the nearest scroller around layer `id` (in `screen`) to it, less
  // (ox, oy); over `ms` with `ease` text, or at once. `done` when it lands.
  function scrollTo(screen, id, ox, oy, ms, ease, done) {
    done = done || function () {};
    var t = screen && screen.querySelector('[data-node="' + id + '"]');
    var box = t && scroller(t);
    if (!box) return done();
    var a = box.getBoundingClientRect(), r = t.getBoundingClientRect(), Z = window.__protoZ || 1;
    var x = Math.max(0, Math.min(box.scrollWidth - box.clientWidth, box.scrollLeft + (r.left - a.left) / Z - (ox || 0)));
    var y = Math.max(0, Math.min(box.scrollHeight - box.clientHeight, box.scrollTop + (r.top - a.top) / Z - (oy || 0)));
    var reduce = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (!ms || reduce) { box.scrollLeft = x; box.scrollTop = y; return done(); }
    var f = easeOf(ease), x0 = box.scrollLeft, y0 = box.scrollTop, t0 = performance.now();
    (function step(now) {
      var k = Math.min(1, (now - t0) / ms), v = f(k);
      box.scrollLeft = x0 + (x - x0) * v; box.scrollTop = y0 + (y - y0) * v;
      if (k < 1) requestAnimationFrame(step); else done();
    })(t0);
  }
  // a click whose one action is a scroll-to (the router runs longer lists)
  d.addEventListener('click', function (e) {
    var el = e.target.closest && e.target.closest('[data-scroll-to]');
    if (!el) return;
    var off = (el.getAttribute('data-scroll-off') || '0 0').split(' ');
    var tr = (el.getAttribute('data-scroll-tr') || '').split(' ');
    scrollTo(el.closest('section.screen'), el.getAttribute('data-scroll-to'), +off[0] || 0, +off[1] || 0, +tr[0] || 0, tr[1]);
  });
  // the router's hook, for a scroll-to in a list or on another trigger:
  // act = { to, ox, oy, tr = "k dir ms ease" }
  window.__protoScrollTo = function (act, done) {
    var on = [].slice.call(d.querySelectorAll('section.screen.on'));
    var s = null;
    for (var i = on.length - 1; i >= 0; i--) if (on[i].querySelector('[data-node="' + act.to + '"]')) { s = on[i]; break; }
    var p = (act.tr || '').split(' ');
    scrollTo(s, act.to, act.ox, act.oy, act.tr ? +p[2] || 0 : 0, p[3], done);
  };
})();
]]

-- Overlays (step 2): a `section.screen[role=dialog]` shows over the Screen
-- (class `ov`), its frame placed in the viewport by `data-overlay` ("pos bg
-- co") or the action's manual offset from the layer clicked; its backdrop is
-- a sibling div (a click on it closes the overlay when `co`). They stack;
-- Esc, Back and `close` close the top one; a Screen change closes them all.
-- Without JS they stay hidden.
local OVERLAY_CSS = [[
html.js .screen.ov { display: block; background: transparent; overflow: hidden; pointer-events: none; }
html.js .screen.ov > * { position: absolute; margin: 0; pointer-events: auto; overflow: auto; }
.ov-bg { position: absolute; inset: 0; }]]

M.OVERLAY_JS = [[
(function () {
  var d = document, stack = [];
  var reduce = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
  var OPP = { left: 'right', right: 'left', up: 'down', down: 'up' };
  var REV = { moveIn: 'moveOut', slideIn: 'slideOut', moveOut: 'moveIn', slideOut: 'slideIn' };
  function sec(id) { var s = id && d.getElementById(id); return s && s.classList.contains('screen') ? s : null; }
  function parse(s) {
    if (!s || typeof s !== 'string') return s || null;
    var p = s.split(' '), e = p[3] || '0,0,0.58,1';
    return { k: p[0], dir: p[1] === '-' ? '' : p[1], ms: +p[2] || 0, ease: e.charAt(0) === 'L' ? 'linear(' + e.slice(1) + ')' : 'cubic-bezier(' + e + ')', ml: p[4] === 'ml' };
  }
  function info(s) { var p = (s.getAttribute('data-overlay') || 'center - 1').split(' '); return { pos: p[0], bg: p[1] === '-' ? null : p[1], co: p[2] !== '0' }; }
  function css(c) { return '#' + c.slice(1, 7) + (c.length > 7 ? c.slice(7, 9) : ''); }
  function ia(el) { try { return JSON.parse(el.getAttribute('data-ia')) || []; } catch (x) { return []; } }
  // where the frame goes in the viewport (engine/proto.luau overlay_place)
  function place(o) {
    // (in CSS px: the page may be scaled, window.__protoZ)
    var B = o.s.getBoundingClientRect(), Z = window.__protoZ || 1, f = o.f;
    var V = { width: B.width / Z, height: B.height / Z };
    var w = Math.min(f.offsetWidth, V.width), h = Math.min(f.offsetHeight, V.height), x, y, p = o.pos;
    if (f.offsetHeight > V.height) f.style.maxHeight = V.height + 'px';
    if (f.offsetWidth > V.width) f.style.maxWidth = V.width + 'px';
    if (p === 'manual') { var r = o.at || B; x = (r.left - B.left) / Z + o.ox; y = (r.top - B.top) / Z + o.oy; }
    else {
      x = /left/.test(p) ? 0 : /right/.test(p) ? V.width - w : (V.width - w) / 2;
      y = /^top/.test(p) ? 0 : /^bottom/.test(p) ? V.height - h : (V.height - h) / 2;
    }
    f.style.left = x + 'px'; f.style.top = y + 'px';
    return { x: x, y: y, w: w, h: h, W: V.width, H: V.height };
  }
  // away from rest: where an opening starts, or a closing ends (tab/proto.luau overlay_off)
  function off(t, g, leaving) {
    var k = t && t.k, dir = (t && t.dir) || 'up', dx = 0, dy = 0;
    if (k === 'dissolve' || k === 'smart') return { transform: 'none', opacity: 0 };
    if (!/^(moveIn|slideIn|moveOut|slideOut|push)$/.test(k || '')) return null;
    if (leaving) dir = OPP[dir];
    if (dir === 'up') dy = g.H - g.y; else if (dir === 'down') dy = -(g.y + g.h); else if (dir === 'left') dx = g.W - g.x; else dx = -(g.x + g.w);
    return { transform: 'translate(' + dx + 'px, ' + dy + 'px)', opacity: 1 };
  }
  function anim(el, a, b, t, done) {
    if (!a || !t || !t.ms || reduce || !el.animate) { done && done(); return null; }
    var x = el.animate([a, b], { duration: t.ms, easing: t.ease, fill: 'both' });
    x.onfinish = function () { x.cancel(); done && done(); };
    return x;
  }
  function z() { stack.forEach(function (o, i) { if (o.bg) o.bg.style.zIndex = 10 + 2 * i; o.s.style.zIndex = 11 + 2 * i; }); }
  // (step 4) a section's frame: its variant states share it (data-vof)
  function vof(s) { return s.getAttribute('data-vof') || s.id; }
  // the section of `id`'s frame that agrees with the component memory
  function at(id) { return sec(window.__protoVS ? window.__protoVS.at(id) : id); }
  // (only: see mount's timers; undefined when it opens)
  function mount(o, only) {
    o.s.classList.add('ov');
    if (!o.bg && (o.inf.bg || o.inf.co)) {
      var bg = o.bg = d.createElement('div');
      bg.className = 'ov-bg';
      if (o.inf.bg) bg.style.background = css(o.inf.bg);
      bg.addEventListener('click', function () { var t = stack[stack.length - 1]; if (t && t.bg === bg && t.inf.co) close(null, function () {}); });
      o.s.parentNode.insertBefore(bg, o.s);
    }
    // (afterDelay inside it counts from when it opens; a Change to inside it
    // restarts only its Instance's, the rest keep running in the new look)
    if (only === undefined) o.life = { on: true };
    var L = o.life;
    if (only !== null && window.__protoArm) window.__protoArm(o.s, function () { return L.on; }, function () { for (var i = 0; i < stack.length; i++) if (stack[i].life === L) return stack[i].s; return null; }, only);
  }
  // (keep: the frame lives on in another look, its timers too)
  function unmount(o, keep) {
    if (!keep && o.life) o.life.on = false;
    o.s.classList.remove('ov'); o.s.style.zIndex = '';
    o.f.style.left = o.f.style.top = o.f.style.maxHeight = o.f.style.maxWidth = '';
    if (o.bg && o.bg.parentNode) o.bg.parentNode.removeChild(o.bg);
  }
  // (one still swapping ends where it is going, at once)
  function drop(o) { if (o.stop) o.stop(); unmount(o); }
  function open(a, done, el) {
    var s = at(a.go);
    if (!s || a.broken) return done();
    for (var i = 0; i < stack.length; i++) if (vof(stack[i].s) === vof(s)) return done();
    var inf = info(s);
    var o = { s: s, f: s.firstElementChild, inf: inf, pos: a.pos || inf.pos, ox: a.ox || 0, oy: a.oy || 0, at: el && el.getBoundingClientRect(), t: parse(a.tr) };
    stack.push(o);
    mount(o); z();
    var g = place(o), from = off(o.t, g, false);
    if (o.bg && from) anim(o.bg, { opacity: 0 }, { opacity: 1 }, o.t);
    anim(o.f, from, { transform: 'none', opacity: 1 }, o.t, done);
  }
  // (L1) the last one closed: the Screen under it picks up the memory
  function closed() { if (!stack.length && window.__protoVS) window.__protoVS.refresh(); }
  function close(t, done) {
    var o = stack.pop();
    if (!o) return done();
    if (o.stop) o.stop();
    t = parse(t) || (o.t && { k: REV[o.t.k] || o.t.k, dir: OPP[o.t.dir] || o.t.dir, ms: o.t.ms, ease: o.t.ease });
    var g = place(o), to = off(t, g, true);
    if (o.bg && to) anim(o.bg, { opacity: 1 }, { opacity: 0 }, t);
    anim(o.f, { transform: 'none', opacity: 1 }, to, t, function () { unmount(o); closed(); done(); });
  }
  // The overlay at stack[i] replaced by section s, in its place: a Swap
  // overlay (vc false) or a Change to inside it (vc true: the same frame in
  // another look, its backdrop and timers kept; ti the Instance changed).
  // Smart Animate is the Screens' FLIP between the two (Figma applies it to
  // Swap overlay and to a Change to); one still playing is taken over from
  // where its layers are (F4-int's snap).
  function replace(i, s, t, done, vc, ti) {
    var old = stack[i], snap = null;
    if (old.stop) { if (old.smart && window.__protoSnap) snap = window.__protoSnap(old.s); old.stop(); }
    var o = { s: s, f: s.firstElementChild, inf: info(s), pos: old.pos, ox: old.ox, oy: old.oy, at: old.at, t: old.t };
    if (vc) { o.life = old.life; o.bg = old.bg; old.bg = null; }
    stack[i] = o;
    mount(o, vc ? (ti || null) : undefined); z();
    if (old.bg && o.bg) { old.bg.parentNode.removeChild(old.bg); old.bg = null; }
    var g = place(o), k = t && t.k;
    var v = { left: [-1, 0], right: [1, 0], up: [0, -1], down: [0, 1] }[t && t.dir] || [0, 0];
    function by(f) { return 'translate(' + (v[0] * g.w * f) + 'px, ' + (v[1] * g.h * f) + 'px)'; }
    var zo = +old.s.style.zIndex + 1;
    o.s.style.zIndex = zo;
    var stops = [], ended = false;
    function finish() {
      if (ended) return;
      ended = true; o.stop = null; o.smart = false;
      stops.forEach(function (f) { f(); });
      unmount(old, vc); z(); done();
    }
    o.stop = finish;
    function keep(x) { if (x) stops.push(function () { x.cancel(); }); }
    if (!t || k === 'instant' || !t.ms || reduce) return finish();
    if (k === 'smart' && window.__protoSmart) {
      var b = [];
      o.smart = true;
      window.__protoSmart(old.s, o.s, t, b, finish, snap);
      stops.push(function () { b.forEach(function (x) { x.cancel(); }); });
      // (its place in the overlays' stack, not a Screen's)
      o.s.style.zIndex = zo;
      return;
    }
    if (k === 'dissolve' || k === 'smart') { keep(anim(o.f, { opacity: 0 }, { opacity: 1 }, t, finish)); return; }
    if (k === 'moveIn' || k === 'push' || k === 'slideIn') keep(anim(o.f, { transform: by(-1) }, { transform: by(0) }, t, k === 'moveIn' || k === 'slideIn' ? finish : null));
    if (k === 'push' || k === 'moveOut' || k === 'slideOut') { o.s.style.zIndex = zo - 2; keep(anim(old.f, { transform: by(0) }, { transform: by(1) }, t, finish)); }
  }
  function swap(a, done) {
    var old = stack[stack.length - 1], s = at(a.go);
    if (!s || a.broken) return done();
    // (no overlay open: a navigate with no history entry)
    if (!old) { location.replace('#' + a.go); return done(); }
    replace(stack.length - 1, s, parse(a.tr), done, false);
  }
  // the open overlay that is a look of s's frame
  function find(s) { for (var i = stack.length - 1; i >= 0; i--) if (vof(stack[i].s) === vof(s)) return i; return -1; }
  window.__protoOverlay = {
    act: function (a, done, el) {
      done = done || function () {};
      if (a.k === 'overlay') return open(a, done, el);
      if (a.k === 'swap') return swap(a, done);
      return close(a.tr, done);
    },
    // (step 4) a Change to inside an open overlay: s is its new look
    find: function (s) { var i = find(s); return i < 0 ? null : stack[i]; },
    change: function (s, t, done, ti) {
      done = done || function () {};
      var i = find(s);
      if (i < 0 || stack[i].s === s) return done();
      replace(i, s, parse(t), done, true, ti);
    },
    depth: function () { return stack.length; },
    top: function () { var o = stack[stack.length - 1]; return o ? o.s : null; },
    closeTo: function (n) { var any = stack.length > n; while (stack.length > n) drop(stack.pop()); if (any) closed(); },
    closeAll: function () { while (stack.length) drop(stack.pop()); },
    // is (x, y) inside an overlay above depth n
    inside: function (x, y, n) {
      for (var i = n; i < stack.length; i++) { var r = stack[i].f.getBoundingClientRect(); if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return true; }
      return false;
    }
  };
  d.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && stack.length) { e.preventDefault(); close(null, function () {}); }
  });
})();
]]

-- The HTML of `ids` (or every top-level node that isn't a Component).
-- opts: { css = "css"|"tailwind", scaffold = bool, layerNames = bool, icons = fn }
function M.html(doc: any, ids: { string }?, opts: any?): string
	opts = opts or {}
	XREG = nil
	local tw = opts.css == "tailwind"
	local proto = opts.prototype == true
	local scaffold = opts.scaffold ~= false or proto
	-- (step 6 P5) Responsive: each Screen takes the window's (or the
	-- device's) width, and at least its height (PROTO_CSS)
	local responsive = proto and (Proto.played_prototype(doc.prototype) or {}).fit == "responsive"
	local screens = {}
	for _, n in U.list(doc.children) do
		if type(n) == "table" and n.type == "frame" and n.reusable ~= true then
			screens[n.id] = n.name or n.id
		end
	end
	-- The drawn roots (laid out) and the written nodes by id, with Play's
	-- variant state `swap` and forced variable values `force` (step 5). In a
	-- prototype a layer whose visibility is bound (`enabled = "$x"`) stays
	-- in when hidden now, marked `__off` (its element carries `data-off`).
	local function resolve(ids: { string }?, swap: any?, force: any?): ({ any }, { [string]: any })
		local ropts = if force then { vars = force } else nil
		local wr = Resolve.new(doc, nil, ropts)
		wr.keep_tokens = true
		wr.swap = swap
		local wmap = {}
		for _, root in wr:roots(doc, ids) do
			Resolve.walk({ root }, function(n)
				wmap[n.id] = n
				return true
			end)
		end
		local rr = Resolve.new(doc, nil, ropts)
		rr.swap = swap
		rr.keep_disabled = proto
		local rts = rr:roots(doc, ids)
		if proto then
			local function prune(n)
				if type(n.children) ~= "table" then
					return
				end
				local out = {}
				for _, c in n.children do
					if c.enabled == false then
						local w = wmap[c.id]
						if w and Resolve.reference(w.enabled) then
							c.enabled = nil
							c.__off = true
							table.insert(out, c)
						end
					else
						table.insert(out, c)
					end
				end
				n.children = out
				for _, c in out do
					prune(c)
				end
			end
			local keep = {}
			for _, rt in rts do
				if rt.enabled ~= false then
					prune(rt)
					table.insert(keep, rt)
				end
			end
			rts = keep
		end
		Layout.run(rts)
		return rts, wmap
	end
	XREG = if proto then { list = {}, by = {} } else nil
	local drawn, written_by = resolve(nil, nil, nil)
	local nodes_by = {}
	for _, root in drawn do
		Resolve.walk({ root }, function(n)
			nodes_by[n.id] = n
			return true
		end)
	end
	local roots = {}
	if ids and #ids > 0 then
		for _, id in ids do
			if not nodes_by[id] then
				error({ draft_error = `no node has the id "{id}" to export` }, 0)
			end
			table.insert(roots, nodes_by[id])
		end
	else
		for _, n in drawn do
			if n.reusable ~= true then
				table.insert(roots, n)
			end
		end
	end
	if proto then
		-- only Screens become sections
		local some = {}
		for _, n in roots do
			if screens[n.id] then
				table.insert(some, n)
			end
		end
		roots = some
	end
	local rules, body = {}, {}
	local state_rules = {}
	local any_states = false
	local start_id = nil
	if proto then
		local exported = {}
		for _, n in roots do
			exported[n.id] = true
		end
		for _, f in U.list(doc.flows) do
			if type(f) == "table" and exported[f.start] and not start_id then
				start_id = f.start
			end
		end
		start_id = start_id or (roots[1] and roots[1].id)
	end
	-- (overlays, step 2) the frames something opens over a Screen
	local overlay_of: { [string]: boolean } = {}
	if proto then
		for _, n in nodes_by do
			for _, id in Proto.overlay_targets(n) or {} do
				overlay_of[id] = true
			end
			-- (step 5: and the ones an if's branch opens)
			for _, r in U.list(type(n) == "table" and n.interactions or nil) do
				Proto.each_action(type(r) == "table" and r.actions or nil, function(a, depth)
					if depth > 0 and (a.action == "overlay" or a.action == "swap") and type(a.to) == "string" then
						overlay_of[a.to] = true
					end
				end)
			end
		end
	end
	-- (step 3) Smart Animate: elements carry their match key (`data-mk`)
	-- when a link smart-animates
	local uses_smart = false
	if proto then
		for _, n in nodes_by do
			for _, r in U.list(type(n) == "table" and n.interactions or nil) do
				-- (an if's branches too)
				Proto.each_action(type(r) == "table" and r.actions or nil, function(a)
					local t = a.transition
					if type(t) == "table" and (t.type == "smart" or t.matchLayers == true) then
						uses_smart = true
					end
				end)
			end
		end
	end
	local families = {}
	local classes = {}
	local function class_of(id: string): string
		local base = "n-" .. ident(string.gsub(id, "/", "-"))
		local c, k = base, 1
		while classes[c] do
			k += 1
			c = base .. "-" .. k
		end
		classes[c] = true
		return c
	end
	-- (step 4) Interactive components: each Screen's variant states that
	-- Change to links reach from its own (at most VARIANT_STATES each) are
	-- sections of their own (`data-vof` = the Screen), the Screen resolved
	-- with those members; a changeTo's `go` is the section it leads to.
	local vs_all = Proto.variant_sets(doc)
	local vsets = vs_all.of
	local toks = Vars.tokens(doc)
	-- (step 5) a prop's text value typed for the Token it's bound to
	local function typed(name: string, v: any): any
		local kind = toks[name] and toks[name].kind
		if kind == "boolean" then
			return v == "true"
		elseif kind == "number" then
			return tonumber(v)
		end
		return v
	end
	-- (step 5) two-way binding: a Change to on an Instance whose variant
	-- properties are bound to variables writes them instead (`vset`), and
	-- the binding then shows the member. (V7: Figma's filmed bound switch
	-- still plays its Change to's animation, 0–283 ms, and the next action
	-- waits for it; so the `vset` keeps the transition, and the router
	-- animates the member swap. A Set variable stays instant.)
	local function bind_changes(items: { any })
		for i, it in items do
			for _, x in it.ia or {} do
				each_act(x.acts, function(a)
					if a.k ~= "changeTo" or a.broken or not a.set then
						return
					end
					local t = Variants.target(items, i, a.set)
					local tv = t and items[t].vb
					if not tv then
						return
					end
					local props = vs_all.sets[a.set] and vs_all.sets[a.set].props[a.to] or {}
					local sets = {}
					local names = {}
					for prop in tv do
						table.insert(names, prop)
					end
					table.sort(names)
					for _, prop in names do
						local v = props[prop]
						if v ~= nil then
							table.insert(sets, { tv[prop], typed(tv[prop], v) })
						end
					end
					a.k = "vset"
					a.sets = sets
				end)
			end
		end
	end
	local function scene_items(rt: any): { any }
		local its = Scene.items(rt, { icons = opts.icons, screens = screens, vsets = vsets })
		if proto then
			bind_changes(its)
		end
		return its
	end
	local entries = {}
	local base_written = written_by
	for _, root in roots do
		table.insert(entries, { root = root, sid = root.id, written = base_written })
	end
	if proto then
		local more = {}
		-- (L1: overlays too, so a Change to inside an open overlay swaps its
		-- look; and a frame with no Change to of its own still carries its
		-- `data-vs`, so Reset component state forgets its keys)
		for _, e in entries do
			local items0 = scene_items(e.root)
			e.items = items0
			local any = false
			for _, it in items0 do
				for _, x in it.ia or {} do
					each_act(x.acts, function(a)
						if a.k == "changeTo" and not a.broken then
							any = true
						end
					end)
				end
			end
			if not any then
				continue
			end
			local by_sig = { [""] = e }
			local queue = { { e = e, vmap = {} } }
			local n = 0
			while #queue > 0 do
				local q = table.remove(queue, 1)
				for i, it in q.e.items do
					for _, x in it.ia or {} do
						each_act(x.acts, function(a)
							if a.k ~= "changeTo" or a.broken then
								return
							end
							local vmap, ti = Variants.change(q.e.items, q.vmap, i, a)
							if not vmap then
								return
							end
							-- (the Instance it changes: only its afterDelay timers restart)
							a.ti = if ti then q.e.items[ti].id else nil
							local sig = Variants.signature(vmap)
							local to = by_sig[sig]
							if not to and n < M.VARIANT_STATES then
								n += 1
								local rts, wmap = resolve({ e.root.id }, vmap, nil)
								local rt = rts[1]
								if rt then
									to = { root = rt, sid = `{e.root.id}~{n}`, vof = e.root.id, written = wmap, vmap = vmap }
									to.items = scene_items(rt)
									by_sig[sig] = to
									table.insert(more, to)
									table.insert(queue, { e = to, vmap = vmap })
								end
							end
							if to then
								a.go = to.sid
							else
								a.broken = true
							end
						end)
					end
				end
			end
		end
		for _, x in more do
			table.insert(entries, x)
		end
	end
	for _, entry in entries do
		local root = entry.root
		written_by = entry.written
		local items = entry.items or Scene.items(root, { icons = opts.icons, screens = screens, vsets = vsets })
		local class_by, tw_extra = {}, if tw then {} else nil
		for _, it in items do
			if it.st then
				any_states = true
				if tw_extra then
					-- the state classes first: each item's own list is added as it's emitted
					break
				end
			end
		end
		if tw_extra and any_states then
			states_css(items, function(id)
				return id
			end, function(id)
				local w = written_by[id]
				return w and w.states, w
			end, tw_extra)
		end
		-- items in paint order with subtree sizes: walk them as a tree
		local by_id = {}
		local function attach(n)
			by_id[n.id] = n
			for _, c in (n.children or {}) do
				attach(c)
			end
		end
		attach(root)
		-- scrolling (step 2): scrollers' memory keys (`data-sk`: the Screen's
		-- key, then the name path) and the layers a scrollTo goes to
		local scroll_targets, sk_of = {}, {}
		local root_sk = screen_key(root.name or root.id) .. "|"
		if proto then
			local path = {}
			for _, it in items do
				path[it.id] = if it.p and path[it.p] then path[it.p] .. "/" .. tostring(it.name or "") else ""
				if it.ovf and it.p then
					sk_of[it.id] = root_sk .. path[it.id]
				end
				for _, e in it.ia or {} do
					each_act(e.acts, function(a)
						if a.k == "scrollTo" and type(a.to) == "string" then
							scroll_targets[a.to] = true
						end
					end)
				end
			end
		end
		local mkeys = if uses_smart then Smart.keys(items) else nil
		local i = 1
		-- (step 5) An Instance whose variant properties are bound to variables
		-- is written once per member its bound values can pick, as siblings
		-- (`data-vg` = its id, `data-vb` = { prop: token }, `data-when` = the
		-- values that pick it); the one the Design's values pick shows, the
		-- others carry `data-off`. Each other member is the Screen resolved
		-- with those values forced (`cur_force`), its Instance's items cut out.
		local cur_force: any = nil
		local alt_depth = 0
		local alts_total = 0
		local alts_done = {}
		local pending: any = nil
		local function alternatives(item: any): any
			local s = vs_all.sets[item.vset]
			if not s or alts_total >= M.BOUND_MEMBERS then
				return nil
			end
			local base = s.props[item.vdef or item.inst] or {}
			local props = {}
			for p in item.vb do
				table.insert(props, p)
			end
			table.sort(props)
			local by_member, order, seen = {}, {}, {}
			for _, m in s.members do
				local want, ok, key = {}, true, {}
				for _, p in props do
					local v = s.props[m][p]
					if v == nil then
						ok = false
						break
					end
					want[p] = v
					table.insert(key, p .. "=" .. v)
				end
				local k = table.concat(key, ";")
				if ok and not seen[k] then
					seen[k] = true
					local c = Proto.variant_find(vs_all, item.vset, want, base)
					if c then
						if not by_member[c] then
							by_member[c] = {}
							table.insert(order, c)
						end
						table.insert(by_member[c], want)
					end
				end
			end
			local list = {}
			for _, c in order do
				if c == item.inst or alts_total >= M.BOUND_MEMBERS then
					continue
				end
				local force = table.clone(cur_force or {})
				for _, p in props do
					force[item.vb[p]] = typed(item.vb[p], by_member[c][1][p])
				end
				local rts, wmap = resolve({ root.id }, entry.vmap, force)
				local rt = rts[1]
				if not rt then
					continue
				end
				local its = scene_items(rt)
				for k, it in its do
					if it.id == item.id and it.inst == c then
						local slice = table.move(its, k, k + (it.n or 0), 1, {})
						local by = {}
						Resolve.walk({ rt }, function(nd)
							by[nd.id] = nd
							return true
						end)
						alts_total += 1
						table.insert(list, { items = slice, by_id = by, written = wmap, force = force, when = by_member[c] })
						break
					end
				end
			end
			return { when = by_member[item.inst] or {}, list = list }
		end
		local emit_one
		local function emit(parent_kind, parent_box, depth, in_link)
			local item = items[i]
			local alts = if proto and item.vb and item.vset and alt_depth < 3 then alternatives(item) else nil
			if not alts then
				emit_one(parent_kind, parent_box, depth, in_link)
				return
			end
			XREG.used = true
			local group = ` data-vg="{escape(item.id)}" data-vb="{escape(json_text(item.vb))}"`
			pending = { attrs = group .. ` data-when="{escape(json_text(alts.when))}"` }
			emit_one(parent_kind, parent_box, depth, in_link)
			for _, a in alts.list do
				local s_items, s_i, s_by, s_wr, s_mk, s_cls, s_force = items, i, by_id, written_by, mkeys, class_by, cur_force
				items, i, by_id, written_by, mkeys, class_by, cur_force = a.items, 1, a.by_id, a.written, nil, {}, a.force
				alt_depth += 1
				pending = { attrs = group .. ` data-when="{escape(json_text(a.when))}"`, off = true }
				emit_one(parent_kind, parent_box, depth, in_link)
				alt_depth -= 1
				table.insert(alts_done, { items = items, class_by = class_by, written = written_by })
				items, i, by_id, written_by, mkeys, class_by, cur_force = s_items, s_i, s_by, s_wr, s_mk, s_cls, s_force
			end
		end
		emit_one = function(parent_kind, parent_box, depth, in_link)
			local item = items[i]
			local mk = mkeys and mkeys[i]
			local xa = pending
			pending = nil
			i += 1
			item.__node = by_id[item.id]
			local el = element(item, written_by[item.id], parent_kind, parent_box)
			-- (a frame without a layout holding a sticky layer: its own
			-- formatting context, so the layer's place-margins stay inside it)
			if not item.lay and (item.n or 0) > 0 and not el.inner then
				local j = i
				while j < i + item.n do
					if items[j].scr == "sticky" then
						table.insert(el.d, { "display", "flow-root" })
						break
					end
					j += (items[j].n or 0) + 1
				end
			end
			local indent = string.rep("  ", depth)
			-- a link: a real <a> in prototype mode (a data- link inside another)
			local link_tag, link, ia_data = nil, "", ""
			if proto and item.ia then
				link_tag, link, ia_data = link_attrs(item, in_link == true, el.tag == "svg")
				if link_tag then
					el.tag = link_tag
					local has_display = false
					for _, x in el.d do
						if x[1] == "display" then
							has_display = true
						end
					end
					if not has_display then
						table.insert(el.d, { "display", "block" })
					end
				end
			end
			local attrs
			if tw then
				local extra = tw_extra and tw_extra[item.id]
				attrs = ` class="{escape(tailwind(el.d) .. (if extra then " " .. table.concat(extra, " ") else "") .. (if link_tag then " link" else ""))}"`
			else
				local c = class_of(item.id)
				class_by[item.id] = c
				local link_cls = if link_tag then " link" else ""
				attrs = ` class="{c}{link_cls}"`
				local lines = { "." .. c .. " {" }
				for _, x in el.d do
					table.insert(lines, `  {x[1]}: {x[2]};`)
				end
				table.insert(lines, "}")
				table.insert(rules, table.concat(lines, "\n"))
			end
			if opts.layerNames and item.name and item.name ~= "" then
				attrs ..= ` data-name="{escape(item.name)}"`
			end
			for axis, v in (item.__node.theme or {}) do
				attrs ..= ` data-{ident(axis)}="{escape(tostring(v))}"`
			end
			attrs ..= link .. ia_data
			if proto then
				attrs ..= (scroll_attrs(item, link_tag ~= nil))
				if sk_of[item.id] then
					attrs ..= ` data-sk="{escape(sk_of[item.id])}"`
				end
				if scroll_targets[item.id] then
					attrs ..= ` data-node="{escape(item.id)}"`
				end
				if mk then
					attrs ..= ` data-mk="{escape(mk)}"`
				end
				-- (L1) an afterDelay's layer by id: its timer lives on in the
				-- section a Change to swaps in (the same layer there)
				for _, e in item.ia or {} do
					if e.on == "afterDelay" and ia_data ~= "" then
						attrs ..= ` data-ix="{escape(item.id)}"`
						break
					end
				end
				-- (step 5) bindings: text shows a variable, visibility follows a
				-- boolean (hidden now: `data-off`); a bound Instance's member group
				local w = written_by[item.id]
				local bind = w and item.t == "text" and Resolve.reference(w.content)
				if bind then
					attrs ..= ` data-bind="{escape(bind)}"`
					XREG.used = true
				end
				local show = w and Resolve.reference(w.enabled)
				if show then
					attrs ..= ` data-show="{escape(show)}"`
					XREG.used = true
				end
				if xa then
					attrs ..= xa.attrs
				end
				if (xa and xa.off) or item.__node.__off then
					attrs ..= " data-off"
				end
			end
			local inside = in_link or (proto and item.ia ~= nil and link ~= "")
			if item.text then
				families[item.text.font .. ":" .. item.text.weight] = { item.text.font, item.text.weight }
			end
			if el.tag == "svg" then
				table.insert(body, `{indent}<svg{attrs}{el.svg}>{el.inner}</svg>`)
				return
			end
			if el.inner then
				table.insert(body, `{indent}<{el.tag}{attrs}>{el.inner}</{el.tag}>`)
				i += item.n
				return
			end
			if item.n == 0 then
				table.insert(body, `{indent}<{el.tag}{attrs}></{el.tag}>`)
				return
			end
			table.insert(body, `{indent}<{el.tag}{attrs}>`)
			local kind = if item.lay == "horizontal" then "row" elseif item.lay == "vertical" then "column" else "free"
			local stop = i + item.n
			-- a scroller's fixed layers go first, in a layer that sticks to its
			-- scrollport (a Screen scrolls in its section, a frame in itself)
			if item.ovf or (proto and item.p == nil) then
				local starts, j, any = {}, i, false
				while j < stop do
					table.insert(starts, j)
					any = any or items[j].scr == "fixed"
					j += (items[j].n or 0) + 1
				end
				if any then
					table.insert(body, fixed_layer_open(item, item.__node, indent .. "  "))
					for _, s in starts do
						if items[s].scr == "fixed" then
							i = s
							emit("free", item.box, depth + 2, inside)
						end
					end
					table.insert(body, indent .. "  </div>")
					for _, s in starts do
						if items[s].scr ~= "fixed" then
							i = s
							emit(kind, item.box, depth + 1, inside)
						end
					end
					i = stop
				end
			end
			while i < stop do
				emit(kind, item.box, depth + 1, inside)
			end
			table.insert(body, `{indent}</{el.tag}>`)
		end
		local first = #body + 1
		emit("page", { x = 0, y = 0 }, if proto then 3 elseif scaffold then 2 else 0, false)
		if proto then
			local cls = if root.id == start_id and not entry.vof then "screen start" else "screen"
			-- an overlay: a dialog the router places in the viewport, with its
			-- settings ("pos bg|- co", bg as #RRGGBBAA)
			local dialog = ""
			if overlay_of[root.id] or type(root.overlay) == "table" then
				local ov = Proto.played_overlay(root.overlay)
				dialog = ` role="dialog" data-overlay="{ov.pos} {ov.bg or "-"} {if ov.co then 1 else 0}"`
			end
			local vof = if entry.vof then ` data-vof="{escape(entry.vof)}"` else ""
			-- (step 4) the member each Instance shows, by memory key
			if entry.items then
				local parts = {}
				for i, it in entry.items do
					if it.vset and it.inst then
						table.insert(parts, (string.gsub(Variants.key(entry.items, i), ";", ",")) .. "=" .. it.inst)
					end
				end
				if #parts > 0 then
					vof ..= ` data-vs="{escape(table.concat(parts, ";"))}"`
				end
			end
			-- (step 6 P5) Responsive: the Screen's designed height, the least it
			-- gets (PROTO_CSS's responsive rule; an overlay keeps its size)
			local rh = ""
			if responsive and dialog == "" and items[1] and items[1].box then
				rh = ` style="--rh: {px(items[1].box.h)}"`
			end
			table.insert(body, first, `    <section class="{cls}" id="{escape(entry.sid)}" aria-label="{escape(tostring(root.name or root.id))}" data-sk="{escape(root_sk)}"{vof}{dialog}{rh}>`)
			table.insert(body, "    </section>")
		end
		if not tw and any_states then
			for _, r in states_css(items, function(id)
				return class_by[id]
			end, function(id)
				local w = written_by[id]
				return w and w.states, w
			end, nil) do
				table.insert(state_rules, r)
			end
		end
		-- (step 5) a bound Instance's other members' hover and press looks
		for _, a in (if tw then {} else alts_done) do
			for _, it in a.items do
				if it.st then
					any_states = true
				end
			end
			for _, r in states_css(a.items, function(id)
				return a.class_by[id]
			end, function(id)
				local w = a.written[id]
				return w and w.states, w
			end, nil) do
				table.insert(state_rules, r)
			end
		end
	end
	if any_states or proto then
		table.insert(state_rules, REDUCED)
	end
	local tokens = tokens_css(doc)
	local css = tokens .. (if tw then "" else table.concat(rules, "\n") .. "\n")
	if proto then
		css ..= PROTO_CSS .. "\n"
		css ..= SCROLL_CSS .. "\n"
		css ..= OVERLAY_CSS .. "\n"
	end
	if #state_rules > 0 then
		css ..= table.concat(state_rules, "\n") .. "\n"
	end
	if not scaffold then
		return (if css ~= "" then "<style>\n" .. css .. "</style>\n" else "") .. table.concat(body, "\n") .. "\n"
	end
	-- Google Fonts for the families that aren't system or app fonts
	local fams = {}
	local by_family = {}
	for _, fw in families do
		by_family[fw[1]] = by_family[fw[1]] or {}
		table.insert(by_family[fw[1]], fw[2])
	end
	for fam, ws in by_family do
		if fam ~= "Georgia" and fam ~= "Arial" and fam ~= "Segoe UI" and fam ~= "Times New Roman" and fam ~= "Courier New" and fam ~= "Verdana" and fam ~= "Tahoma" and fam ~= "Impact" then
			table.sort(ws)
			local uniq = {}
			for _, w in ws do
				if uniq[#uniq] ~= w then
					table.insert(uniq, w)
				end
			end
			table.insert(fams, "family=" .. string.gsub(fam, " ", "+") .. ":wght@" .. table.concat(uniq, ";"))
		end
	end
	table.sort(fams)
	local head = { '<!doctype html>', '<html lang="en">', "<head>", '  <meta charset="utf-8">', '  <meta name="viewport" content="width=device-width, initial-scale=1">' }
	if #fams > 0 then
		table.insert(head, '  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>')
		table.insert(head, '  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?' .. table.concat(fams, "&") .. '&display=swap">')
	end
	if tw then
		table.insert(head, '  <script src="https://cdn.tailwindcss.com"></script>')
	end
	if css ~= "" then
		table.insert(head, "  <style>\n" .. css .. "  </style>")
	end
	table.insert(head, "</head>")
	if proto then
		-- the device (step 2): Screens show in a viewport of its size
		local pp = Proto.played_prototype(doc.prototype)
		local vars = {}
		if pp and pp.w then
			table.insert(vars, `--device-w: {px(pp.w)}; --device-h: {px(pp.h)}`)
		end
		if pp and pp.bg then
			table.insert(vars, `--proto-bg: {css_color(pp.bg)}; background: {css_color(pp.bg)}`)
		end
		local style = if #vars > 0 then ` style="{table.concat(vars, "; ")}"` else ""
		local fits = if pp and pp.w then ` data-fit="{pp.fit}" data-dfit="{pp.device_fit}"` else ""
		table.insert(head, `<body class="proto{if responsive then " responsive" else ""}{if pp and pp.w then " device" else ""}"{fits}{style}>`)
		local nav = {}
		for _, fl in U.list(doc.flows) do
			if type(fl) == "table" and type(fl.start) == "string" and screens[fl.start] then
				table.insert(nav, `<a href="#{escape(fl.start)}">{escape(tostring(fl.name))}</a>`)
			end
		end
		if #nav > 0 then
			table.insert(head, "  <nav class=\"flows\" aria-label=\"Flows\">" .. table.concat(nav) .. "</nav>")
		end
		-- (step 6) the device stage: the frame's SVGs around <main> (drawn
		-- when FRAME_JS turns it on), and the scaling
		local stage_end = ""
		if pp and pp.w then
			local f = if pp.frame and pp.show_frame then DeviceFrame.shapes(pp.frame, pp.w, pp.h, pp.rotate, pp.model) else nil
			local ins = if f then f.inset else { 0, 0, 0, 0 }
			local fw, fh = pp.w + ins[1] + ins[3], pp.h + ins[2] + ins[4]
			local sv = `--df-l: {px(ins[1])}; --df-t: {px(ins[2])}; --df-w: {px(fw)}; --df-h: {px(fh)}`
			table.insert(head, `  <div class="device-stage" data-w="{num(pp.w)}" data-h="{num(pp.h)}" data-inset="{num(ins[1])} {num(ins[2])} {num(ins[3])} {num(ins[4])}"{if f then ` data-frame="{f.kind}"` else ""} style="{sv}">`)
			if f then
				local under, over = DeviceFrame.svg(f, nil, "var(--proto-bg, #18181b)")
				table.insert(head, "  " .. under)
				stage_end = "\n  " .. over .. "\n  </div>"
			else
				stage_end = "\n  </div>"
			end
		end
		table.insert(head, "  <main>")
		-- (step 5) the variables runtime, when anything sets or binds one
		local vars_js = ""
		if XREG and XREG.used then
			local xs = {}
			for _, js in XREG.list do
				table.insert(xs, "function (V) { return " .. js .. "; }")
			end
			local data = vars_data(doc, json_text) .. "  var X = [" .. table.concat(xs, ", ") .. "];\n"
			vars_js = "\n(function () {\n" .. string.gsub(data, "</", "<\\/") .. M.VARS_JS
		end
		XREG = nil
		return table.concat(head, "\n") .. "\n" .. table.concat(body, "\n") .. "\n  </main>" .. stage_end .. "\n  <script>" .. (if stage_end ~= "" then M.FRAME_JS else "") .. M.PROTO_JS .. M.SCROLL_JS .. M.OVERLAY_JS .. (if uses_smart then M.SMART_JS else "") .. vars_js .. "  </script>\n</body>\n</html>\n"
	end
	table.insert(head, "<body>")
	table.insert(head, '  <div style="display: flex; flex-direction: column; gap: 48px; padding: 48px; align-items: flex-start">')
	return table.concat(head, "\n") .. "\n" .. table.concat(body, "\n") .. "\n  </div>\n</body>\n</html>\n"
end

local _ = Text
return M
