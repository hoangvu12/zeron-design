--!nonstrict
-- Small helpers the engine shares: copies, ids, value checks.

local M = {}

-- What a Luau table can't hold: a key set to "unset it". Agents' snippets
-- get it as `null`; a window sends "__null" (or JSON null, which arrives as
-- a missing key and so can't unset: use "__null").
M.NULL = setmetatable({}, { __tostring = function() return "null" end })
M.NULL_TEXT = "__null"

function M.is_null(v: any): boolean
	return v == M.NULL or v == M.NULL_TEXT
end

function M.deep_copy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	if v == M.NULL then
		return v
	end
	local out = table.create(#v)
	for k, x in v do
		out[k] = M.deep_copy(x)
	end
	return out
end

-- A shallow copy without `children`.
function M.props(node: any): any
	local out = {}
	for k, v in node do
		if k ~= "children" then
			out[k] = v
		end
	end
	return out
end

function M.is_array(t: any): boolean
	if type(t) ~= "table" then
		return false
	end
	if next(t) == nil then
		return true
	end
	return t[1] ~= nil
end

-- A table that's empty or a list: children, fills, effects as lists.
function M.list(v: any): { any }
	if v == nil then
		return {}
	end
	if type(v) == "table" and (next(v) == nil or v[1] ~= nil) then
		return v
	end
	return { v }
end

local ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"
local seed = os.clock() * 1e6 + os.time()
local function rnd(n: number): number
	-- xorshift-ish over a float: good enough for ids
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed % n
end

-- A fresh id not in `taken` (a set).
function M.new_id(taken: { [string]: any }): string
	for len = 5, 8 do
		for _ = 1, 20 do
			local s = table.create(len)
			for i = 1, len do
				local c = rnd(#ALPHABET) + 1
				s[i] = string.sub(ALPHABET, c, c)
			end
			local id = table.concat(s)
			if not taken[id] then
				return id
			end
		end
	end
	error("couldn't make a fresh id")
end

function M.num(v: any, default: number): number
	if type(v) == "number" and v == v then
		return v
	end
	return default
end

function M.clamp(v: number, lo: number, hi: number): number
	if v < lo then
		return lo
	elseif v > hi then
		return hi
	end
	return v
end

function M.equal(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not M.equal(v, b[k]) then
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

-- `#RGB`, `#RRGGBB`, `#RRGGBBAA` as `#RRGGBBAA`, or nil.
function M.color(hex: any): string?
	if type(hex) ~= "string" or string.sub(hex, 1, 1) ~= "#" then
		return nil
	end
	local d = string.sub(hex, 2)
	if not string.match(d, "^%x+$") then
		return nil
	end
	if #d == 3 then
		local r, g, b = string.sub(d, 1, 1), string.sub(d, 2, 2), string.sub(d, 3, 3)
		return string.upper("#" .. r .. r .. g .. g .. b .. b .. "FF")
	elseif #d == 6 then
		return string.upper("#" .. d .. "FF")
	elseif #d == 8 then
		return string.upper("#" .. d)
	end
	return nil
end

return M
