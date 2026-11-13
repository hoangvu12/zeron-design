--!nonstrict
-- Icons (`icon = "set:name"`): Iconify SVGs fetched once by the service
-- (zeron.fetch, api.iconify.design), kept in zeron.db, and turned into what
-- the tab draws: a viewBox and path parts { d, sw?, nofill?, rule? } with
-- circles, rects, lines and polylines converted to path data.

local M = {}

local zeron: any = nil
local mem: { [string]: any } = {} -- name â†’ { vb, parts } or false (missing)
local failed: { [string]: boolean } = {}

local API = "https://api.iconify.design/"

local ready = false
function M.init(z: any)
	zeron = z
end
local function schema()
	if not ready then
		ready = true
		zeron.db.exec("CREATE TABLE IF NOT EXISTS icons (name TEXT PRIMARY KEY, svg TEXT, at INTEGER)"):await()
	end
end

local function attrs(s: string): { [string]: string }
	local a = {}
	for k, v in string.gmatch(s, '([%w%-:]+)%s*=%s*"([^"]*)"') do
		a[k] = v
	end
	for k, v in string.gmatch(s, "([%w%-:]+)%s*=%s*'([^']*)'") do
		a[k] = v
	end
	return a
end

local function n(v: string?, default: number?): number
	return tonumber(v or "") or default or 0
end

local function fmt(x: number): string
	if x == math.floor(x) then
		return string.format("%d", x)
	end
	return string.format("%.3f", x)
end

local function points(s: string): { number }
	local out = {}
	for x in string.gmatch(s, "[-+]?[%d%.]+[eE]?[-+]?%d*") do
		table.insert(out, tonumber(x) or 0)
	end
	return out
end

-- The path data an element draws, or nil.
local function shape_d(tag: string, a: any): string?
	if tag == "path" then
		return a.d
	elseif tag == "circle" or tag == "ellipse" then
		local cx, cy = n(a.cx), n(a.cy)
		local rx = if tag == "circle" then n(a.r) else n(a.rx)
		local ry = if tag == "circle" then n(a.r) else n(a.ry)
		if rx <= 0 or ry <= 0 then
			return nil
		end
		return `M{fmt(cx - rx)} {fmt(cy)}a{fmt(rx)} {fmt(ry)} 0 1 0 {fmt(2 * rx)} 0a{fmt(rx)} {fmt(ry)} 0 1 0 {fmt(-2 * rx)} 0Z`
	elseif tag == "rect" then
		local x, y, w, h = n(a.x), n(a.y), n(a.width), n(a.height)
		local rx = math.min(n(a.rx, n(a.ry)), w / 2)
		local ry = math.min(n(a.ry, rx), h / 2)
		if rx <= 0 then
			return `M{fmt(x)} {fmt(y)}h{fmt(w)}v{fmt(h)}h{fmt(-w)}Z`
		end
		return `M{fmt(x + rx)} {fmt(y)}h{fmt(w - 2 * rx)}a{fmt(rx)} {fmt(ry)} 0 0 1 {fmt(rx)} {fmt(ry)}v{fmt(h - 2 * ry)}a{fmt(rx)} {fmt(ry)} 0 0 1 {fmt(-rx)} {fmt(ry)}h{fmt(-(w - 2 * rx))}a{fmt(rx)} {fmt(ry)} 0 0 1 {fmt(-rx)} {fmt(-ry)}v{fmt(-(h - 2 * ry))}a{fmt(rx)} {fmt(ry)} 0 0 1 {fmt(rx)} {fmt(-ry)}Z`
	elseif tag == "line" then
		return `M{fmt(n(a.x1))} {fmt(n(a.y1))}L{fmt(n(a.x2))} {fmt(n(a.y2))}`
	elseif tag == "polyline" or tag == "polygon" then
		local p = points(a.points or "")
		if #p < 4 then
			return nil
		end
		local s = { `M{fmt(p[1])} {fmt(p[2])}` }
		for i = 3, #p - 1, 2 do
			table.insert(s, `L{fmt(p[i])} {fmt(p[i + 1])}`)
		end
		if tag == "polygon" then
			table.insert(s, "Z")
		end
		return table.concat(s)
	end
	return nil
end

-- { vb = {x,y,w,h}, parts = {â€¦} } of an SVG's text, or nil.
function M.parse(svg: string): any
	local root = string.match(svg, "<svg(.-)>")
	if not root then
		return nil
	end
	local ra = attrs(root)
	local vb = points(ra.viewBox or "")
	local box = if #vb == 4 then { x = vb[1], y = vb[2], w = vb[3], h = vb[4] } else { x = 0, y = 0, w = n(ra.width, 24), h = n(ra.height, 24) }
	local stack = { { fill = ra.fill or "currentColor", stroke = ra.stroke or "none", sw = n(ra["stroke-width"], 1), rule = ra["fill-rule"], cap = ra["stroke-linecap"], join = ra["stroke-linejoin"] } }
	local parts = {}
	local body = string.match(svg, "<svg.->(.*)</svg>") or ""
	for close, tag, rest, selfclose in string.gmatch(body, "<(/?)([%w]+)(.-)(/?)>") do
		if close == "/" then
			if tag == "g" and #stack > 1 then
				table.remove(stack)
			end
		else
			local a = attrs(rest)
			local top = stack[#stack]
			local st = {
				fill = a.fill or top.fill,
				stroke = a.stroke or top.stroke,
				sw = if a["stroke-width"] then n(a["stroke-width"], top.sw) else top.sw,
				rule = a["fill-rule"] or top.rule,
				cap = a["stroke-linecap"] or top.cap,
				join = a["stroke-linejoin"] or top.join,
			}
			if tag == "g" then
				if selfclose ~= "/" then
					table.insert(stack, st)
				end
			else
				local d = shape_d(tag, a)
				if d and d ~= "" then
					local part: any = { d = d }
					local stroked = st.stroke ~= "none" and st.stroke ~= nil
					local filled = st.fill ~= "none"
					if tag == "line" or tag == "polyline" then
						filled = false
					end
					if stroked then
						part.sw = st.sw
						if st.cap == "round" or st.cap == "square" then
							part.cap = st.cap
						end
						if st.join == "round" or st.join == "bevel" then
							part.join = st.join
						end
					end
					if not filled then
						part.nofill = true
					end
					if st.rule == "evenodd" then
						part.rule = "evenodd"
					end
					if stroked or filled then
						table.insert(parts, part)
					end
				end
			end
		end
	end
	return { vb = box, parts = parts }
end

local function split(name: string): (string?, string?)
	return string.match(name, "^([%w%-]+):([%w%-]+)$")
end

-- What's known of `name`: the drawing, false when it doesn't exist, nil
-- when not fetched yet.
function M.get(name: string, _weight: any?): any
	local m = mem[name]
	if m ~= nil then
		return m or nil
	end
	return nil
end

-- Loads from the database, then fetches what's missing. Returns names that
-- don't exist.
function M.need(names: { string }): { string }
	schema()
	local missing = {}
	local want = {}
	for _, name in names do
		if mem[name] == nil and not want[name] then
			want[name] = true
			local rows = zeron.db.query("SELECT svg FROM icons WHERE name = ?", { name }):await()
			if rows[1] then
				mem[name] = if rows[1].svg ~= "" then (M.parse(rows[1].svg) or false) else false
			end
		end
	end
	for name in want do
		if mem[name] == nil and not failed[name] then
			local set, icon = split(name)
			if not set then
				mem[name] = false
			elseif type(zeron.fetch) ~= "function" then
				failed[name] = true
			else
				local ok, r = pcall(function()
					return zeron.fetch(API .. set .. "/" .. icon .. ".svg", { timeout = 10 }):await()
				end)
				if ok and r and r.status == 200 and string.find(r.body or "", "<svg", 1, true) then
					zeron.db.exec("INSERT OR REPLACE INTO icons (name, svg, at) VALUES (?, ?, ?)", { name, r.body, os.time() }):await()
					mem[name] = M.parse(r.body) or false
				elseif ok and r and r.status == 404 then
					zeron.db.exec("INSERT OR REPLACE INTO icons (name, svg, at) VALUES (?, ?, ?)", { name, "", os.time() }):await()
					mem[name] = false
				else
					failed[name] = true
				end
			end
		end
	end
	-- Every name asked for that doesn't exist, known before or just now.
	local listed = {}
	for _, name in names do
		if mem[name] == false and not listed[name] then
			listed[name] = true
			table.insert(missing, name)
		end
	end
	return missing
end

-- The icon names used in resolved roots.
function M.used(roots: { any }): { string }
	local out, seen = {}, {}
	local function walk(n)
		if n.type == "icon" and type(n.icon) == "string" and not seen[n.icon] then
			seen[n.icon] = true
			table.insert(out, n.icon)
		end
		for _, c in (n.children or {}) do
			walk(c)
		end
	end
	for _, r in roots do
		walk(r)
	end
	return out
end

-- For tests: put an SVG in as if fetched.
function M.put(name: string, svg: string)
	mem[name] = M.parse(svg) or false
end

return M
