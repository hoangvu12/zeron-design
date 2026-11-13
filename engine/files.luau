--!nonstrict
-- `.zdesign` text in and out: pretty JSON (two-space indent, a node's id,
-- name and type first, its children last) so a Design diffs well in Git.

local U = require("./util")

local M = {}

local FIRST = { "id", "name", "type", "x", "y", "rotation", "opacity", "enabled", "theme" }
local FIRST_SET = {}
for i, k in FIRST do
	FIRST_SET[k] = i
end
local TOP = { "version", "children", "themes", "tokens" }

local function escape(s: string): string
	s = string.gsub(s, '[%c"\\]', function(c)
		if c == '"' then
			return '\\"'
		elseif c == "\\" then
			return "\\\\"
		elseif c == "\n" then
			return "\\n"
		elseif c == "\r" then
			return "\\r"
		elseif c == "\t" then
			return "\\t"
		end
		return string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. s .. '"'
end

local function number(n: number): string
	if n ~= n or n == math.huge or n == -math.huge then
		return "null"
	end
	if n == math.floor(n) and math.abs(n) < 1e15 then
		-- (Whole numbers bare: native reads 390 as an f32 and 3 as a u32.)
		return string.format("%d", n)
	end
	local s = string.format("%.17g", n)
	-- shortest that reads back the same
	for p = 1, 17 do
		local t = string.format("%." .. p .. "g", n)
		if tonumber(t) == n then
			s = t
			break
		end
	end
	return s
end

local function keys_of(t: any, top: boolean): { string }
	local ks = {}
	for k in t do
		table.insert(ks, tostring(k))
	end
	table.sort(ks, function(a, b)
		if top then
			local ia, ib = table.find(TOP, a) or 99, table.find(TOP, b) or 99
			if ia ~= ib then
				return ia < ib
			end
			return a < b
		end
		if a == "children" then
			return false
		elseif b == "children" then
			return true
		end
		local ia, ib = FIRST_SET[a] or 99, FIRST_SET[b] or 99
		if ia ~= ib then
			return ia < ib
		end
		return a < b
	end)
	return ks
end

local LIST_KEYS = { children = true }

local function write(v: any, indent: string, out: { string }, top: boolean, key: string?)
	local t = type(v)
	if t == "string" then
		table.insert(out, escape(v))
	elseif t == "number" then
		table.insert(out, number(v))
	elseif t == "boolean" then
		table.insert(out, tostring(v))
	elseif v == nil or v == U.NULL then
		table.insert(out, "null")
	elseif t == "table" then
		local inner = indent .. "  "
		if next(v) == nil then
			table.insert(out, if key and LIST_KEYS[key] then "[]" else "{}")
		elseif v[1] ~= nil then
			table.insert(out, "[\n")
			for i, x in v do
				table.insert(out, inner)
				write(x, inner, out, false, nil)
				table.insert(out, if i < #v then ",\n" else "\n")
			end
			table.insert(out, indent .. "]")
		else
			table.insert(out, "{\n")
			local ks = keys_of(v, top)
			for i, k in ks do
				table.insert(out, inner .. escape(k) .. ": ")
				write(v[k], inner, out, false, k)
				table.insert(out, if i < #ks then ",\n" else "\n")
			end
			table.insert(out, indent .. "}")
		end
	else
		table.insert(out, "null")
	end
end

function M.write(doc: any): string
	local out = {}
	local d = table.clone(doc)
	d.children = U.list(d.children)
	if d.version == nil then
		d.version = "1.0"
	end
	write(d, "", out, true, nil)
	table.insert(out, "\n")
	return table.concat(out)
end

-- A doc from `.zdesign` text, and warnings; nil and why when it isn't one.
function M.read(zeron: any, text: string): (any?, { string })
	local ok, doc = pcall(zeron.json.decode, text)
	if not ok or type(doc) ~= "table" then
		return nil, { "that isn't JSON: " .. tostring(doc) }
	end
	if doc.children ~= nil and type(doc.children) ~= "table" then
		return nil, { "a Design's children are a list" }
	end
	local warnings = {}
	doc.children = U.list(doc.children)
	doc.version = doc.version or "1.0"
	local seen = {}
	local bad = 0
	local function walk(list)
		for _, n in list do
			if type(n) ~= "table" or type(n.id) ~= "string" or type(n.type) ~= "string" then
				bad += 1
			else
				if seen[n.id] then
					table.insert(warnings, `two nodes have the id "{n.id}"`)
				end
				seen[n.id] = true
				if type(n.children) == "table" then
					walk(n.children)
				end
			end
		end
	end
	walk(doc.children)
	if bad > 0 then
		table.insert(warnings, `{bad} nodes have no id or type`)
	end
	return doc, warnings
end

return M
