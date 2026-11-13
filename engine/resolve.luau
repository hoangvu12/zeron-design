--!nonstrict
-- The Design as drawn (native crates/design/src/resolve.rs): each Instance
-- expanded from its Component, each "$token" given its value in the node's
-- Theme, nodes not enabled left out. Instance internals get slash ids
-- (`card/title`). Works on decoded JSON tables and never changes them.

local U = require("./util")

local M = {}

local MAX_NESTING = 16
local COMMON = { id = true, name = true, x = true, y = true, absolute = true, rotation = true, flipX = true, flipY = true, opacity = true, inProgress = true, enabled = true, theme = true }
M.COMMON = COMMON
local NOT_REFS = { id = true, type = true, name = true, children = true, descendants = true, ref = true }

local function name_char_ok(s: string): boolean
	return string.match(s, "^[%w%-_%./]+$") ~= nil
end

-- The Token `text` refers to, when it's `$name`.
function M.reference(text: any): string?
	if type(text) ~= "string" or string.sub(text, 1, 1) ~= "$" then
		return nil
	end
	local name = string.sub(text, 2)
	if name ~= "" and name_char_ok(name) then
		return name
	end
	return nil
end

function M.refers(v: any): boolean
	if type(v) == "string" then
		return M.reference(v) ~= nil
	elseif type(v) == "table" then
		for _, x in v do
			if M.refers(x) then
				return true
			end
		end
	end
	return false
end

-- A Token's values as { {value, theme} }, or nil and why.
function M.read_token(name: string, token: any): (any, string?)
	if type(token) ~= "table" then
		return nil, `Token "{name}" has a type and a value`
	end
	local kind = token.type
	if kind ~= "color" and kind ~= "number" and kind ~= "string" then
		return nil, `Token "{name}" needs a type, color, number or string`
	end
	local v = token.value
	if v == nil then
		return nil, `Token "{name}": it has no value`
	end
	if type(v) == "table" then
		local values = {}
		for _, themed in v do
			if type(themed) ~= "table" or type(themed.theme) ~= "table" then
				return nil, `Token "{name}": each of its themed values is \{ value, theme = \{ axis = "value" \} \}`
			end
			table.insert(values, { value = themed.value, theme = themed.theme })
		end
		if #values == 0 then
			return nil, `Token "{name}": it has no value`
		end
		return { kind = kind, values = values }
	end
	return { kind = kind, values = { { value = v, theme = {} } } }
end

local function count(t: any): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

function M.value_in(token: any, theme: any): any
	local best, best_n = nil, -1
	for _, cand in token.values do
		local ok = true
		for axis, val in cand.theme do
			if theme[axis] ~= val then
				ok = false
				break
			end
		end
		if ok then
			local n = count(cand.theme)
			if n >= best_n then
				best, best_n = cand, n
			end
		end
	end
	return (best or token.values[1]).value
end

function M.default_theme(themes: any): any
	local t = {}
	for axis, values in (themes or {}) do
		if type(values) == "table" and values[1] ~= nil then
			t[axis] = values[1]
		end
	end
	return t
end

local function merged(a: any, b: any): any
	local t = table.clone(a)
	if type(b) == "table" then
		for k, v in b do
			t[k] = v
		end
	end
	return t
end

-- Every node, depth first, parents first.
function M.walk(nodes: any, visit: (any, any?, number) -> boolean?, parent: any?, depth: number?)
	for _, n in U.list(nodes) do
		if type(n) == "table" then
			if visit(n, parent, depth or 0) ~= false then
				M.walk(n.children, visit, n, (depth or 0) + 1)
			end
		end
	end
end

local function prefix(node: any, with: string)
	node.id = with .. "/" .. tostring(node.id)
	for _, c in U.list(node.children) do
		prefix(c, with)
	end
end

local function find(node: any, id: string): any
	if node.id == id then
		return node
	end
	for _, c in U.list(node.children) do
		local f = find(c, id)
		if f then
			return f
		end
	end
	return nil
end

local function named(node: any, name: string, out: { string })
	for _, c in U.list(node.children) do
		if c.name == name then
			table.insert(out, c.id)
		end
		named(c, name, out)
	end
end

local function set_props(node: any, props: any)
	for k, v in props do
		if k ~= "children" and k ~= "id" then
			if U.is_null(v) then
				node[k] = nil
			else
				node[k] = U.deep_copy(v)
			end
		end
	end
end

local function apply(target: any, value: any): string?
	if type(value) ~= "table" then
		return "an override is an object of properties or a node"
	end
	if value.type ~= nil then
		local id = target.id
		for k in table.clone(target) do
			target[k] = nil
		end
		for k, v in U.deep_copy(value) do
			target[k] = v
		end
		target.id = id
		for _, c in U.list(target.children) do
			prefix(c, id)
		end
		return nil
	end
	set_props(target, value)
	return nil
end

function M.merge_override(descendants: any, key: string, value: any)
	local there = descendants[key]
	if type(there) == "table" and type(value) == "table" and value.type == nil then
		for p, v in value do
			if U.is_null(v) then
				there[p] = nil
			else
				there[p] = v
			end
		end
	else
		descendants[key] = value
	end
end

-- A resolver over one Design.
local R = {}
R.__index = R

function M.new(doc: any, view_theme: any?)
	local self = setmetatable({ components = {}, tokens = {}, problems = {}, seen = {} }, R)
	M.walk(doc.children, function(n)
		if n.type == "frame" and n.reusable == true then
			self.components[n.id] = n
		end
		return true
	end)
	for name, tok in (doc.tokens or {}) do
		local t = M.read_token(name, tok)
		if t then
			self.tokens[name] = t
		end
	end
	local theme = M.default_theme(doc.themes)
	for k, v in (view_theme or {}) do
		theme[k] = v
	end
	self.theme = theme
	return self
end

function R:problem(node: string, message: string)
	local key = node .. "\0" .. message
	if not self.seen[key] then
		self.seen[key] = true
		table.insert(self.problems, { node = node, message = message })
	end
end

function R:value(v: any, theme: any, node: string, literal: boolean): any
	if type(v) == "string" then
		local name = M.reference(v)
		if name then
			local tok = self.tokens[name]
			if tok then
				return U.deep_copy(M.value_in(tok, theme))
			end
			if not literal then
				self:problem(node, `"{v}" refers to a Token the Design doesn't have`)
			end
		end
		return v
	elseif type(v) == "table" then
		local out = table.create(#v)
		for k, x in v do
			out[k] = self:value(x, theme, node, literal)
		end
		return out
	end
	return v
end

function R:substitute(node: any, theme: any)
	for k, v in node do
		if not NOT_REFS[k] and M.refers(v) then
			local literal = node.type == "text" and k == "content"
			node[k] = self:value(v, theme, node.id, literal)
		end
	end
end

function R:override_descendant(copy: any, key: string, value: any)
	local inst = copy.id
	local target = find(copy, inst .. "/" .. key)
	if target then
		local e = apply(target, value)
		if e then
			self:problem(target.id, e)
		end
		return
	end
	local head, rest = string.match(key, "^([^/]+)/(.+)$")
	if head then
		local nested = find(copy, inst .. "/" .. head)
		if nested and nested.type == "instance" then
			nested.descendants = nested.descendants or {}
			M.merge_override(nested.descendants, rest, value)
			return
		end
	end
	local ids = {}
	named(copy, key, ids)
	if #ids == 1 then
		local e = apply(find(copy, ids[1]), value)
		if e then
			self:problem(ids[1], e)
		end
	elseif #ids == 0 then
		self:problem(inst, `no node inside it has the id or name "{key}" to override`)
	else
		self:problem(inst, `{#ids} nodes inside it are named "{key}": override one by its id`)
	end
end

-- The Instance `node` (already a copy) as its Component, with overrides.
function R:expand(node: any, nesting: { string }): (any, string?)
	local comp_id = node.ref
	local comp = self.components[comp_id]
	if not comp then
		self:problem(node.id, `its Component "{tostring(comp_id)}" isn't in the Design`)
		return node, nil
	end
	if table.find(nesting, comp_id) then
		self:problem(node.id, `its Component "{comp_id}" holds an Instance of itself`)
		return node, nil
	end
	if #nesting >= MAX_NESTING then
		self:problem(node.id, `Instances nest at most {MAX_NESTING} deep inside their Components`)
		return node, nil
	end
	local copy = U.deep_copy(comp)
	for _, c in U.list(copy.children) do
		prefix(c, node.id)
	end
	copy.reusable = nil
	copy.id = node.id
	if type(node.name) == "string" and node.name ~= "" then
		copy.name = node.name
	end
	for _, k in { "x", "y", "rotation", "flipX", "flipY", "opacity", "absolute", "inProgress", "enabled" } do
		copy[k] = node[k]
	end
	if type(node.theme) == "table" then
		copy.theme = merged(copy.theme or {}, node.theme)
	end
	-- Its own overrides of the Component's properties.
	for k, v in node do
		if not COMMON[k] and k ~= "type" and k ~= "ref" and k ~= "descendants" and k ~= "children" then
			if U.is_null(v) then
				copy[k] = nil
			else
				copy[k] = U.deep_copy(v)
			end
		end
	end
	local desc = node.descendants
	if type(desc) == "table" then
		local by_name, by_id = {}, {}
		for key, value in desc do
			if string.find(key, "/", 1, true) or find(copy, node.id .. "/" .. key) then
				table.insert(by_id, key)
			else
				table.insert(by_name, key)
			end
		end
		table.sort(by_name)
		table.sort(by_id)
		for _, key in by_name do
			self:override_descendant(copy, key, desc[key])
		end
		for _, key in by_id do
			self:override_descendant(copy, key, desc[key])
		end
	end
	return copy, comp_id
end

-- `node` resolved in `theme` (its parent's); nil when left out. The node
-- returned is a fresh table (children too); `inst` marks an Instance's root.
function R:node(src: any, theme: any, nesting: { string }): any
	if type(src) ~= "table" or (src.enabled == false and not self.keep_disabled) then
		return nil
	end
	local node = U.props(src)
	node.children = src.children
	local expanded = nil
	if node.type == "instance" and not self.no_instances then
		local copy
		copy, expanded = self:expand(node, nesting)
		if expanded then
			node = copy
			node.__inst = expanded
		else
			node.__broken = true
		end
		if node.enabled == false and not self.keep_disabled then
			return nil
		end
	elseif node.type == "frame" and node.reusable == true then
		expanded = node.id
	end
	local t = theme
	if type(node.theme) == "table" and next(node.theme) ~= nil then
		t = merged(theme, node.theme)
	end
	if not self.keep_tokens then
		self:substitute(node, t)
	end
	local kids = node.children
	if kids ~= nil then
		local out = {}
		if expanded then
			table.insert(nesting, expanded)
		end
		for _, c in U.list(kids) do
			local r = self:node(c, t, nesting)
			if r then
				table.insert(out, r)
			end
		end
		if expanded then
			table.remove(nesting)
		end
		node.children = out
	end
	return node
end

-- The drawn tree of each top-level node (`roots`: ids, or all).
function R:roots(doc: any, ids: { string }?): { any }
	local want = nil
	if ids then
		want = {}
		for _, id in ids do
			want[id] = true
		end
	end
	local out = {}
	for _, n in U.list(doc.children) do
		if type(n) == "table" and (not want or want[n.id]) then
			local r = self:node(n, self.theme, {})
			if r then
				table.insert(out, r)
			end
		end
	end
	return out
end

return M
