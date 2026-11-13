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

local M = {}

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

-- A length: calc(var(--token) * 1px) when written as one Token.
local function sized(written: any, key: string, length: number): string
	local name = Resolve.reference(written and written[key])
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

local function background(paints: any): { { string } }?
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
			if p.k == "linear" then
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
	elseif item.lay then
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
			set("padding", `{px(t)} {px(r)} {px(b)} {px(l)}`)
		end
		local J = { center = "center", ["end"] = "flex-end", space_between = "space-between", space_around = "space-around" }
		local A = { center = "center", ["end"] = "flex-end" }
		set("justify-content", J[node.justifyContent] or "flex-start")
		set("align-items", A[node.alignItems] or "flex-start")
	end
	if item.clip then
		set("overflow", "hidden")
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
			set("color", tokened(w, "fill", css_color(f.color, f.op)))
		elseif f then
			for _, x in (background(item.fill) or {}) do
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
		set("color", css_color(item.icon.color))
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
		if item.stroke and item.stroke.fill[1] and item.stroke.fill[1].k == "solid" then
			stroke = ` stroke="{css_color(item.stroke.fill[1].color)}" stroke-width="{num(item.stroke.w[1])}"`
		end
		svg_attrs = ` viewBox="{vb}" preserveAspectRatio="none"`
		inner = `<path d="{escape(d_path)}" fill="{fc}"{stroke}` .. (if item.shape.rule == "evenodd" then ' fill-rule="evenodd"' else "") .. "/>"
	else
		for _, x in (background(item.fill) or {}) do
			if x[1] == "background-color" then
				set(x[1], tokened(w, "fill", x[2]))
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
				if r[1] == r[2] and r[2] == r[3] and r[3] == r[4] then
					set("border-radius", sized(w, "cornerRadius", r[1]))
				else
					set("border-radius", `{px(r[1])} {px(r[2])} {px(r[3])} {px(r[4])}`)
				end
			end
		end
		-- a stroke: one width all round as a ring of box shadows, else borders
		local st = item.stroke
		local shadows = {}
		if st and st.fill[1] and st.fill[1].k == "solid" then
			local c = css_color(st.fill[1].color, st.fill[1].op)
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
	if item.op then
		set("opacity", num(item.op))
	end
	local tf = {}
	if item.rot then
		table.insert(tf, `rotate({num(-item.rot)}deg)`)
	end
	if node.flipX == true or node.flipY == true then
		table.insert(tf, `scale({if node.flipX then -1 else 1}, {if node.flipY then -1 else 1})`)
	end
	if #tf > 0 then
		set("transform-origin", if node.flipX or node.flipY then "center" else "0 0")
		set("transform", table.concat(tf, " "))
	end
	return { tag = tag, d = d, inner = inner, svg = svg_attrs }
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
local function arbitrary(v: string): string
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

-- The HTML of `ids` (or every top-level node that isn't a Component).
-- opts: { css = "css"|"tailwind", scaffold = bool, layerNames = bool, icons = fn }
function M.html(doc: any, ids: { string }?, opts: any?): string
	opts = opts or {}
	local tw = opts.css == "tailwind"
	local scaffold = opts.scaffold ~= false
	local r = Resolve.new(doc)
	local drawn = r:roots(doc)
	Layout.run(drawn)
	local wr = Resolve.new(doc)
	wr.keep_tokens = true
	local written_by = {}
	for _, root in wr:roots(doc) do
		Resolve.walk({ root }, function(n)
			written_by[n.id] = n
			return true
		end)
	end
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
	local rules, body = {}, {}
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
	for _, root in roots do
		local items = Scene.items(root, { icons = opts.icons })
		-- items in paint order with subtree sizes: walk them as a tree
		local by_id = {}
		local function attach(n)
			by_id[n.id] = n
			for _, c in (n.children or {}) do
				attach(c)
			end
		end
		attach(root)
		local i = 1
		local function emit(parent_kind, parent_box, depth)
			local item = items[i]
			i += 1
			item.__node = by_id[item.id]
			local el = element(item, written_by[item.id], parent_kind, parent_box)
			local indent = string.rep("  ", depth)
			local attrs
			if tw then
				attrs = ` class="{escape(tailwind(el.d))}"`
			else
				local c = class_of(item.id)
				attrs = ` class="{c}"`
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
			while i < stop do
				emit(kind, item.box, depth + 1)
			end
			table.insert(body, `{indent}</{el.tag}>`)
		end
		emit("page", { x = 0, y = 0 }, if scaffold then 2 else 0)
	end
	local tokens = tokens_css(doc)
	local css = tokens .. (if tw then "" else table.concat(rules, "\n") .. "\n")
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
	table.insert(head, "<body>")
	table.insert(head, '  <div style="display: flex; flex-direction: column; gap: 48px; padding: 48px; align-items: flex-start">')
	return table.concat(head, "\n") .. "\n" .. table.concat(body, "\n") .. "\n  </div>\n</body>\n</html>\n"
end

local _ = Text
return M
