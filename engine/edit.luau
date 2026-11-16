--!nonstrict
-- Editing a Design's doc in place (native crates/design/src/edit*.rs): the
-- operations agents' snippets and the person's hand edits share. A Draft
-- notes what it made and changed and the warnings an agent should fix; the
-- caller commits (Designs.commit) or rolls back on an error.

local U = require("./util")
local Resolve = require("./resolve")
local Layout = require("./layout")
local Text = require("./text")
local Proto = require("./proto")
local Variations = require("./variations")

local M = {}

local MAX_DEPTH = 48
local TYPES = { frame = true, instance = true, rectangle = true, text = true, ellipse = true, polygon = true, path = true, icon = true }
local TYPE_LIST = "frame, instance, rectangle, text, ellipse, polygon, path, icon"
local FIXED = { id = true, type = true, ref = true }

local SHAPE = { width = true, height = true, fill = true, stroke = true, effect = true }
local KNOWN = {
	frame = { layout = true, gap = true, padding = true, justifyContent = true, alignItems = true, cornerRadius = true, clip = true, reusable = true, children = true, overflow = true, overlay = true, variant = true },
	rectangle = { cornerRadius = true },
	ellipse = { startAngle = true, sweepAngle = true, innerRadius = true },
	polygon = { polygonCount = true },
	path = { geometry = true, viewBox = true, fillRule = true },
	text = { content = true, fontFamily = true, fontSize = true, fontWeight = true, lineHeight = true, letterSpacing = true, textAlign = true, textAlignVertical = true, textGrowth = true, underline = true, strikethrough = true, stroke = false, effect = false },
	icon = { icon = true, weight = true, stroke = false, effect = false },
}
local ALWAYS = { type = true, locked = true, inProgressBy = true, lint = true, lintIgnore = true, states = true, interactions = true, scroll = true, match = true }

local function known(t: string, key: string): boolean
	if Resolve.COMMON[key] or ALWAYS[key] then
		return true
	end
	if t == "instance" then
		return true
	end
	local own = KNOWN[t]
	if own and own[key] ~= nil then
		return own[key]
	end
	return SHAPE[key] == true and t ~= nil
end

local function capitalised(s: string): string
	return string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2)
end

local function is_inside(id: string): boolean
	return string.find(id, "/", 1, true) ~= nil
end
M.is_inside = is_inside

local D = {}
D.__index = D

-- A draft over the held Design `d` (designs.luau).
function M.draft(d: any): any
	local self = setmetatable({ d = d, created = {}, changed = {}, changed_list = {}, warnings = {}, printed = {}, screenshots = {}, exported = {}, ids = {}, index = nil, deleted = {}, returned = {}, linked = {} }, D)
	Resolve.walk(d.doc.children, function(n)
		if type(n.id) == "string" then
			self.ids[n.id] = true
		end
		-- ids links already name (a link kept to a deleted Screen stays legal)
		if n.interactions ~= nil or n.descendants ~= nil then
			Proto.targets_in(n.interactions, self.linked)
			Proto.targets_in(n.descendants, self.linked)
		end
		return true
	end)
	Proto.targets_in(d.doc.flows, self.linked)
	-- (N2) versions waiting in a Variations set keep their ids taken
	Variations.walk_stored(d.doc, function(n)
		if type(n.id) == "string" then
			self.ids[n.id] = true
		end
	end)
	return self
end

function D:fail(msg: string)
	error({ draft_error = msg }, 0)
end

function D:new_id(): string
	local id = U.new_id(self.ids)
	self.ids[id] = true
	return id
end

-- id â†’ { node, parent, list, index, depth }
function D:find(id: string): any
	if not self.index then
		local idx = {}
		local function walk(list, parent, depth)
			for i, n in list do
				if type(n) == "table" and type(n.id) == "string" then
					idx[n.id] = { node = n, parent = parent, list = list, index = i, depth = depth }
					if type(n.children) == "table" then
						walk(n.children, n, depth + 1)
					end
				end
			end
		end
		walk(self.d.doc.children, nil, 1)
		self.index = idx
	end
	return self.index[id]
end

function D:stale()
	self.index = nil
end

-- The names from the Canvas down to `id` ("Home › Header › Title"), or nil.
-- A slash id gives the Instance's path and the inner node's drawn name.
function D:path(id: string): string?
	local top = string.match(id, "^([^/]+)") or id
	local f = self:find(top)
	if not f then
		return nil
	end
	local names = {}
	local p = f
	while p do
		table.insert(names, 1, tostring(p.node.name or p.node.type))
		p = if p.parent then self:find(p.parent.id) else nil
	end
	if top ~= id then
		local ok, r = pcall(self.resolved_find, self, id, { keep_disabled = true, keep_tokens = true })
		table.insert(names, if ok and r then tostring(r.name) else "?")
	end
	return table.concat(names, " › ")
end

-- Fails for an id that isn't there, saying why as far as the draft knows.
function D:missing(id: any)
	id = tostring(id)
	local gone = self.deleted[id]
	if gone then
		self:fail(`no node has the id "{id}": "{gone}" was deleted or replaced earlier in this call (it, or a node holding it)`)
	end
	local top = string.match(id, "^([^/]+)/")
	if top then
		local f = self:find(top)
		if f then
			self:fail(`no node has the id "{id}": the Instance "{tostring(f.node.name)}" ({top}) draws nothing with the id "{string.sub(id, #top + 2)}"`)
		end
		if self.deleted[top] then
			self:fail(`no node has the id "{id}": its Instance "{self.deleted[top]}" was deleted or replaced earlier in this call`)
		end
	end
	self:fail(`no node has the id "{id}"`)
end

function D:changed_id(id: string)
	if not self.changed[id] then
		self.changed[id] = true
		table.insert(self.changed_list, id)
	end
end

function D:warn(node: string?, property: string?, message: string)
	for _, w in self.warnings do
		if w.node == node and w.property == property and w.message == message then
			return
		end
	end
	table.insert(self.warnings, { node = node, property = property, message = message })
end

function D:print(line: string)
	table.insert(self.printed, line)
end

function D:children_of(parent: string?): any
	if parent == nil then
		return self.d.doc.children, 0
	end
	if is_inside(parent) then
		self:fail(`"{parent}" is inside an Instance: change its Component, or Copy the Instance's node out first`)
	end
	local f = self:find(parent)
	if not f then
		self:missing(parent)
	end
	local n = f.node
	if n.type ~= "frame" then
		self:fail(`"{parent}" is a {tostring(n.type)}, which holds no children`)
	end
	if type(n.children) ~= "table" then
		n.children = {}
	end
	return n.children, f.depth
end

local function height_of(n: any): number
	local h = 0
	for _, c in U.list(n.children) do
		h = math.max(h, height_of(c))
	end
	return h + 1
end

-- Turns a snippet's node (a Luau table) into stored JSON: ids, names,
-- nulls dropped, children as a list, warnings for unknown keys.
function D:prepare(node: any, verb: string, made: { any }): any
	if type(node) ~= "table" then
		self:fail(`{verb} takes a node table, not {typeof(node)}`)
	end
	local t = node.type
	if not TYPES[t] then
		self:fail(`{verb} needs a node whose "type" is one of {TYPE_LIST}` .. (if t ~= nil then ` (not "{tostring(t)}")` else ""))
	end
	local out = {}
	for k, v in node do
		if type(k) ~= "string" then
			self:fail(`{verb}: a node's keys are names, not {tostring(k)} (did you mean children = \{ â€¦ \}?)`)
		end
		if not U.is_null(v) and k ~= "id" then
			out[k] = v
		end
	end
	local name = if type(node.name) == "string" then string.gsub(node.name, "^%s*(.-)%s*$", "%1") else ""
	if name == "" then
		name = capitalised(t)
	end
	out.name = name
	out.id = self:new_id()
	if t == "instance" and (type(out.ref) ~= "string" or out.ref == "") then
		self:fail(`{verb}: an instance needs a "ref": its Component's id`)
	end
	-- (step 5) variant properties bound to variables
	if t == "instance" and type(out.props) == "table" and Resolve.refers(out.props) then
		out.props = self:bound_props(out.ref, out.props, verb)
		self.proto_touched = true
	end
	table.insert(made, { name = name, id = out.id })
	if out.children ~= nil then
		if t ~= "frame" then
			self:fail(`{verb}: a {t} holds no children`)
		end
		local kids = {}
		for _, c in U.list(out.children) do
			table.insert(kids, self:prepare(c, verb, made))
		end
		out.children = if #kids > 0 then kids else nil
	end
	if Proto.has(out) then
		self.proto_touched = true
	end
	for k in out do
		if not known(t, k) then
			self:warn(out.id, k, `"{name}" ({t}) has a property "{k}" Zeron doesn't know; it's kept, but does nothing`)
		end
	end
	self:check_values(out, verb)
	return out
end

function D:check_values(n: any, verb: string)
	local function size_ok(v)
		return v == nil or (type(v) == "number" and v >= 0) or v == "fit_content" or v == "fill_container" or Resolve.refers(v)
	end
	if not size_ok(n.width) then
		self:fail(`{verb}: a size is a number of pixels, "fit_content" or "fill_container", not {tostring(n.width)}`)
	end
	if not size_ok(n.height) then
		self:fail(`{verb}: a size is a number of pixels, "fit_content" or "fill_container", not {tostring(n.height)}`)
	end
	if n.type == "polygon" and n.polygonCount ~= nil and not Resolve.refers(n.polygonCount) then
		local c = n.polygonCount
		if type(c) ~= "number" or c < 3 or c > 64 then
			self:fail(`{verb}: a polygon has 3 to 64 sides (polygonCount), not {tostring(c)}`)
		end
	end
	if n.layout ~= nil and n.layout ~= "none" and n.layout ~= "horizontal" and n.layout ~= "vertical" and not Resolve.refers(n.layout) then
		self:fail(`{verb}: layout is "none", "horizontal" or "vertical", not {tostring(n.layout)}`)
	end
	self:check_proto(n)
	local dead = M.inert(n)
	if dead then
		self:warn(n.id, dead[1], `"{tostring(n.name)}": {table.concat(dead, ", ")} do nothing on a Frame without a layout: set layout = "vertical" or "horizontal", or drop them`)
	end
	if n.type == "text" and n.fontFamily ~= nil and not Resolve.refers(n.fontFamily) then
		local _, fell = Text.family(n.fontFamily)
		if fell then
			self:warn(n.id, "fontFamily", `"{n.name}": the font "{tostring(n.fontFamily)}" isn't available to Design (pure); its text draws in {Text.DEFAULT_FAMILY}`)
		end
	end
end

-- Why `id` can't be a link's target, or nil: a Screen (a top-level frame
-- that isn't a Component), or an id a link already named (kept dangling,
-- so undoing the delete brings the link back).
function D:link_target(id: string, kind: string?): string?
	local f = self:find(id)
	if kind == "variant" then
		-- (step 4) a Change to's target: a Component in a variant set
		if f then
			local n = f.node
			if n.type ~= "frame" or n.reusable ~= true or f.parent ~= nil then
				return ` (it's a {if n.reusable == true then "Component inside another node" else tostring(n.type)}; change to a Component of a set: MakeVariants makes one)`
			elseif type(n.variant) ~= "table" then
				return ` (the Component "{tostring(n.name)}" is in no variant set: MakeVariants, or Update(id, \{ variant = \{ set, props \} \}))`
			end
			return nil
		end
		if self.linked[id] or self.lenient_links then
			return nil
		end
		return if self.deleted[id] then ` ("{self.deleted[id]}" was deleted earlier in this call)` else ": no node has that id"
	end
	if f then
		local n = f.node
		if f.parent ~= nil then
			return ` (it's a {tostring(n.type)} inside "{tostring(f.parent.name)}"; link to a top-level frame)`
		elseif n.type ~= "frame" then
			return ` (it's a {tostring(n.type)}; link to a top-level frame)`
		elseif n.reusable == true then
			return " (it's a Component; link to a Screen)"
		end
		return nil
	end
	if self.linked[id] or self.lenient_links then
		return nil
	end
	if self.deleted[id] then
		return ` ("{self.deleted[id]}" was deleted earlier in this call)`
	end
	return ": no node has that id"
end

-- (step 5) What actions' variables are checked against: { kinds = { [token]
-- = kind }, themes }. Cached until the Tokens or Themes change.
function D:var_ctx(): any
	if not self.var_ctx_ then
		local kinds = {}
		for name, tok in (self.d.doc.tokens or {}) do
			local t = Resolve.read_token(name, tok)
			if t then
				kinds[name] = t.kind
			end
		end
		self.var_ctx_ = { kinds = kinds, themes = self.d.doc.themes or {} }
	end
	return self.var_ctx_
end

-- (step 5) An Instance's variant properties bound to variables (`props =
-- { On = "$isOn" }`, literal values allowed beside them): its set must have
-- those properties. Returns the props to store.
function D:bound_props(ref: string, props: any, verb: string): any
	local vs = Proto.variant_sets(self.d.doc)
	local set = vs.of[ref]
	if not set then
		local f = self:find(ref)
		self:fail(`{verb}: the Instance's Component "{tostring(f and f.node.name or ref)}" is in no variant set, so it has no props to bind (MakeVariants makes a set)`)
	end
	local names = {}
	for _, m in vs.sets[set].members do
		for k in vs.sets[set].props[m] do
			names[k] = true
		end
	end
	local out = {}
	for k, v in props do
		if type(k) ~= "string" or not names[k] then
			local have = {}
			for n in names do
				table.insert(have, n)
			end
			table.sort(have)
			self:fail(`{verb}: the set "{set}" has no property "{tostring(k)}" (it has {table.concat(have, ", ")})`)
		end
		if not Resolve.reference(v) and not Proto.prop_value(v) then
			self:fail(`{verb}: props.{k} is a value ("true", "Default") or a variable "$name", not {tostring(v)}`)
		end
		out[k] = if Resolve.reference(v) then v else Proto.prop_value(v)
	end
	return out
end

-- The prototype keys of a stored node (or an override table), checked.
function D:check_proto(n: any, prefix: string?)
	if type(n) ~= "table" then
		return
	end
	local pre = prefix or ""
	local fail = function(msg)
		self:fail(msg)
	end
	local target = function(id, kind)
		return self:link_target(id, kind)
	end
	-- (step 4) a Component's variant: its set and property values
	if n.variant ~= nil and not U.is_null(n.variant) then
		if prefix ~= nil or (n.type ~= nil and n.type ~= "frame") then
			self:fail(`{pre}variant goes on a Component (a top-level frame with reusable = true)`)
		end
		Proto.check_variant(n.variant, pre .. "variant", fail)
		if n.reusable ~= true then
			self:warn(n.id, "variant", `"{tostring(n.name)}" has a variant but isn't a Component (reusable = true): it's in no set`)
		end
		self.proto_touched = true
	end
	if n.states ~= nil and not U.is_null(n.states) then
		Proto.check_states(n.states, pre .. "states", fail)
	end
	if n.interactions ~= nil and not U.is_null(n.interactions) then
		Proto.check_interactions(n.interactions, pre .. "interactions", fail, target, self:var_ctx())
	end
	-- (step 5) visibility bound to a variable: true, false or "$name"
	if n.enabled ~= nil and not U.is_null(n.enabled) and type(n.enabled) ~= "boolean" and not Resolve.reference(n.enabled) then
		self:fail(`{pre}enabled is true, false or a boolean variable "$name", not {tostring(n.enabled)}`)
	end
	-- scrolling (step 2): overflow on frames, scroll on any layer
	if n.overflow ~= nil then
		if n.type ~= nil and n.type ~= "frame" and n.type ~= "instance" and not U.is_null(n.overflow) then
			self:fail(`{pre}overflow scrolls a frame's content: "{tostring(n.name)}" is a {tostring(n.type)}; wrap its content in a frame and give that the overflow`)
		end
		Proto.check_overflow(n.overflow, pre .. "overflow", fail)
	end
	if n.scroll ~= nil then
		Proto.check_scroll(n.scroll, pre .. "scroll", fail)
	end
	-- Smart Animate (step 3): a match key that overrides the name path
	if n.match ~= nil and not U.is_null(n.match) then
		Proto.check_match(n.match, pre .. "match", fail)
	end
	-- overlays (step 2): a frame's overlay settings
	if n.overlay ~= nil and not U.is_null(n.overlay) then
		if n.type ~= nil and n.type ~= "frame" then
			self:fail(`{pre}overlay settings go on a top-level frame: "{tostring(n.name)}" is a {tostring(n.type)}`)
		end
		Proto.check_overlay(n.overlay, pre .. "overlay", fail)
		self.proto_touched = true
	end
	if n.type == "instance" and type(n.descendants) == "table" and prefix == nil then
		for key, ov in n.descendants do
			if type(ov) == "table" then
				self:check_proto(ov, `descendants.{tostring(key)}.`)
			end
		end
	end
end

-- The Design's flows ({ {name, start} }; nil or {} clears).
function D:set_flows(list: any)
	if list == nil or U.is_null(list) or (type(list) == "table" and next(list) == nil) then
		self.d.doc.flows = nil
	else
		Proto.check_flows(list, function(msg)
			self:fail(msg)
		end, function(id)
			return self:link_target(id)
		end)
		local clean = {}
		for _, f in list do
			-- (step 6) a flow's description, plain text
			local desc = if type(f.description) == "string" and f.description ~= "" then f.description else nil
			table.insert(clean, { name = f.name, start = f.start, description = desc })
		end
		self.d.doc.flows = clean
	end
	self.proto_touched = true
	self.flows_changed = true
end

-- The Design's prototype settings ({ device, rotate, fit, background };
-- nil, "__null" or {} clears). `merge`: keys given replace those kept.
function D:set_prototype(p: any, merge: boolean?)
	if p == nil or U.is_null(p) or (type(p) == "table" and next(p) == nil) then
		self.d.doc.prototype = nil
		self.proto_touched = true
		return
	end
	if type(p) == "table" and merge and type(self.d.doc.prototype) == "table" then
		p = Proto.merge_prototype(self.d.doc.prototype, p)
	end
	Proto.check_prototype(p, function(msg)
		self:fail(msg)
	end)
	local clean = {}
	for k, v in p do
		if not U.is_null(v) then
			clean[k] = U.deep_copy(v)
		end
	end
	self.d.doc.prototype = if next(clean) ~= nil then clean else nil
	self.proto_touched = true
end

-- (N4) The Design's brief: a short text (palette, type, spacing, mood) the
-- person and agents keep; "" or null clears it. Saved and undone with the doc.
M.BRIEF_MAX = 4000
function D:set_brief(text: any)
	if text == nil or U.is_null(text) then
		text = ""
	end
	if type(text) ~= "string" then
		self:fail(`the brief is text, not {typeof(text)}`)
	end
	text = string.gsub(text, "^%s+", "")
	text = string.gsub(text, "%s+$", "")
	if #text > M.BRIEF_MAX then
		self:fail(`the brief is at most {M.BRIEF_MAX} characters ({#text} given): keep it short (palette, type, spacing, mood)`)
	end
	self.d.doc.brief = if text ~= "" then text else nil
	self.brief_changed = true
end

function D:attach(list: any, index: number?, node: any, made: { any })
	local i = if index then math.clamp(math.floor(index) + 1, 1, #list + 1) else #list + 1
	table.insert(list, i, node)
	self:stale()
	for _, m in made do
		self:changed_id(m.id)
		table.insert(self.created, m)
	end
end

function D:insert(parent: string?, node: any): string
	local list, depth = self:children_of(parent)
	if depth + height_of(node) > MAX_DEPTH then
		self:fail(`Insert: nodes nest at most {MAX_DEPTH} deep`)
	end
	local made = {}
	local built = self:prepare(node, "Insert", made)
	self:attach(list, nil, built, made)
	self:no_effect_tree(built, if parent then self:find(parent).node else nil)
	return built.id
end

-- An Instance's `descendants` merged with `more`, key by key: a key set to
-- null drops that override, a table of properties merges into the one there
-- (null props unset), a full node (with a type) replaces it.
local function merge_descendants(node: any, more: any)
	if type(node.descendants) ~= "table" then
		node.descendants = {}
	end
	local desc = node.descendants
	for key, val in more do
		if U.is_null(val) then
			desc[key] = nil
		else
			Resolve.merge_override(desc, key, U.deep_copy(val))
			local there = desc[key]
			if type(there) == "table" and there.type == nil then
				for p, x in there do
					if U.is_null(x) then
						there[p] = nil
					end
				end
			end
		end
	end
	if next(desc) == nil then
		node.descendants = nil
	end
end

-- Sets props on a stored node (no id/type/ref/children changes). An
-- Instance's `descendants` merge into the ones it has unless `replace`.
-- (step 4) The member of `ref`'s set an Instance switches to: `props`
-- (some property values, the rest kept as far as a member has them) or a
-- new `ref` in the same set. Fails when there's none.
function D:variant_member(ref: string, props: any, new_ref: any, verb: string): string
	local vs = Proto.variant_sets(self.d.doc)
	local set = vs.of[ref]
	if not set then
		local f = self:find(ref)
		self:fail(`{verb}: the Instance's Component "{tostring(f and f.node.name or ref)}" is in no variant set, so it has no props to switch (MakeVariants makes a set)`)
	end
	if new_ref ~= nil then
		if vs.of[new_ref] ~= set then
			self:fail(`{verb} can change an Instance's "ref" only to another variant of its set "{set}" (Replace puts a new node in its place)`)
		end
		return new_ref
	end
	if type(props) ~= "table" or next(props) == nil then
		self:fail(`{verb}: props is \{ Name = "value" \}, the variant's property values`)
	end
	local id = Proto.variant_find(vs, set, props, vs.sets[set].props[ref])
	if not id then
		local have = {}
		for _, m in vs.sets[set].members do
			local parts = {}
			for k, v in vs.sets[set].props[m] do
				table.insert(parts, `{k}={v}`)
			end
			table.sort(parts)
			table.insert(have, table.concat(parts, " "))
		end
		self:fail(`{verb}: the set "{set}" has no variant with those props; it has: {table.concat(have, "; ")}`)
	end
	return id :: string
end

function D:set(node: any, props: any, verb: string, replace: boolean?)
	-- (step 5) variant properties bound to variables stay on the Instance
	-- (`props = { On = "$isOn" }`); null drops the binding
	if node.type == "instance" and props.props ~= nil and (U.is_null(props.props) or Resolve.refers(props.props)) then
		node.props = if U.is_null(props.props) then nil else self:bound_props(node.ref, props.props, verb)
		props = table.clone(props)
		props.props = nil
		self.proto_touched = true
	elseif node.type == "instance" and type(props.props) == "table" and type(node.props) == "table" then
		-- (a literal value given for a bound property replaces the binding)
		for k in props.props do
			node.props[k] = nil
		end
		if next(node.props) == nil then
			node.props = nil
		end
	end
	if node.type == "instance" and (props.props ~= nil or (props.ref ~= nil and props.ref ~= node.ref)) then
		local to = self:variant_member(node.ref, props.props, if props.ref ~= node.ref then props.ref else nil, verb)
		props = table.clone(props)
		props.props, props.ref = nil, nil
		if to ~= node.ref then
			local old, new = self:find(node.ref), self:find(to)
			if type(node.descendants) == "table" and old and new then
				node.descendants = Resolve.rekey(node.descendants, old.node, new.node)
			end
			node.ref = to
			self.proto_touched = true
		end
	end
	if props.states ~= nil or props.interactions ~= nil or (type(props.descendants) == "table" and next(props.descendants) ~= nil) then
		self.proto_touched = true
	end
	for k, v in props do
		if k == "descendants" and node.type == "instance" and not replace and type(v) == "table" and v ~= U.NULL then
			merge_descendants(node, v)
		elseif FIXED[k] then
			if v ~= node[k] then
				self:fail(`{verb} can't change a node's "{k}" (Replace puts a new node in its place)`)
			end
		elseif k == "children" then
			-- What Get read may come back with its children: fine when unchanged.
		elseif U.is_null(v) then
			node[k] = nil
		else
			node[k] = U.deep_copy(v)
			if not known(node.type, k) then
				self:warn(node.id, k, `"{tostring(node.name)}" ({tostring(node.type)}) has a property "{k}" Zeron doesn't know; it's kept, but does nothing`)
			end
		end
	end
	self:check_values(node, verb)
end

function D:update(id: string, props: any, replace: boolean?)
	if type(props) ~= "table" then
		self:fail("Update takes the properties to set as a table")
	end
	if is_inside(id) then
		return self:update_inside(id, props)
	end
	local f = self:find(id)
	if not f then
		self:missing(id)
	end
	self:set(f.node, props, "Update", replace)
	self:changed_id(id)
	self:no_effect(f.node, f.parent, props)
end

-- `card/title`: the override on the Instance `card`.
function D:update_inside(id: string, props: any)
	local top, rest = string.match(id, "^([^/]+)/(.+)$")
	local f = self:find(top)
	if not f or f.node.type ~= "instance" then
		self:missing(id)
	end
	-- it must exist as drawn
	local drawn = self:resolved_find(id, { keep_disabled = true, keep_tokens = true })
	if not drawn then
		self:missing(id)
	end
	local inst = f.node
	if type(inst.descendants) ~= "table" then
		inst.descendants = {}
	end
	-- (step 4) a nested Instance switched to another variant: its `ref`
	-- (step 5) bound variant properties stay in the override as `props`
	if drawn.__inst and props.props ~= nil and Resolve.refers(props.props) then
		props = table.clone(props)
		props.props = self:bound_props(drawn.__inst, props.props, "Update")
		self.proto_touched = true
	elseif drawn.__inst and (props.props ~= nil or (props.ref ~= nil and props.ref ~= drawn.__inst)) then
		local to = self:variant_member(drawn.__inst, props.props, if props.ref ~= drawn.__inst then props.ref else nil, "Update")
		props = table.clone(props)
		props.props = nil
		props.ref = to
	end
	local clean, unset = {}, {}
	self:check_proto(props)
	if props.states ~= nil or props.interactions ~= nil then
		self.proto_touched = true
	end
	for k, v in props do
		if k ~= "id" and k ~= "children" then
			clean[k] = if U.is_null(v) then U.NULL_TEXT else U.deep_copy(v)
			if U.is_null(v) then
				table.insert(unset, k)
			end
		end
	end
	-- A null drops that property from every override that reaches this node
	-- (one keyed by its name, as Copy's descendants often are, or by its
	-- id), so it falls back to the Component's value.
	if #unset > 0 then
		local names = { [rest] = true }
		if type(drawn.name) == "string" then
			names[drawn.name] = true
		end
		local cf = self:find(inst.ref)
		if cf then
			local inner = string.match(rest, "([^/]+)$")
			Resolve.walk(cf.node.children, function(n)
				if n.id == inner and type(n.name) == "string" then
					names[n.name] = true
				end
				return true
			end)
		end
		for key, ov in inst.descendants do
			if names[key] and key ~= rest and type(ov) == "table" then
				for _, k in unset do
					ov[k] = nil
				end
				if next(ov) == nil then
					inst.descendants[key] = nil
				end
			end
		end
	end
	Resolve.merge_override(inst.descendants, rest, clean)
	-- nulls unset: drop them after merging
	local there = inst.descendants[rest]
	if type(there) == "table" then
		for k, v in there do
			if U.is_null(v) then
				there[k] = nil
			end
		end
		if next(there) == nil then
			inst.descendants[rest] = nil
		end
	end
	if next(inst.descendants) == nil then
		inst.descendants = nil
	end
	self:changed_id(id)
	self:changed_id(top)
end

-- The resolved (drawn) node `id`, and its resolved root.
function D:resolved_find(id: string, how: any?): any
	local top = string.match(id, "^([^/]+)") or id
	-- find the root that holds `top`
	local f = self:find(top)
	if not f then
		return nil
	end
	local root = f.node
	local pf = f
	while pf.parent do
		root = pf.parent
		pf = self:find(root.id)
	end
	local r = Resolve.new(self.d.doc, self.d.view_theme)
	for k, v in (how or {}) do
		r[k] = v
	end
	local roots = r:roots(self.d.doc, { root.id })
	local found = nil
	local function walk(n)
		if n.id == id then
			found = n
			return
		end
		for _, c in (n.children or {}) do
			if found then
				return
			end
			walk(c)
		end
	end
	for _, rr in roots do
		walk(rr)
	end
	return found, roots
end

local function renew(self: any, node: any, made: { any }, renamed: any)
	local id = self:new_id()
	renamed[node.id] = id
	node.id = id
	table.insert(made, { name = node.name or capitalised(tostring(node.type)), id = id })
	for _, c in U.list(node.children) do
		renew(self, c, made, renamed)
	end
end

local function clean_resolved(n: any): any
	local out = {}
	for k, v in n do
		if type(k) == "string" and string.sub(k, 1, 2) == "__" then
			continue
		end
		if k == "children" then
			local kids = {}
			for _, c in v do
				table.insert(kids, clean_resolved(c))
			end
			out.children = if #kids > 0 then kids else nil
		else
			out[k] = U.deep_copy(v)
		end
	end
	return out
end
M.clean_resolved = clean_resolved

function D:copy(id: string, parent: string?, props: any?): string
	props = props or {}
	if type(props) ~= "table" then
		self:fail("Copy takes the properties to set as a table")
	end
	local descendants = props.descendants
	local p2 = {}
	for k, v in props do
		if k ~= "descendants" then
			p2[k] = v
		end
	end
	local src
	if is_inside(id) then
		local r = self:resolved_find(id)
		src = if r then clean_resolved(r) else nil
	else
		local f = self:find(id)
		src = if f then U.deep_copy(f.node) else nil
	end
	if not src then
		self:missing(id)
	end
	local list, depth = self:children_of(parent)
	if src.type == "frame" and src.reusable == true and not is_inside(id) then
		local inst = { type = "instance", ref = src.id, name = src.name, x = src.x, y = src.y }
		for k, v in p2 do
			inst[k] = v
		end
		if type(descendants) == "table" and next(descendants) ~= nil then
			inst.descendants = descendants
		end
		local made = {}
		local built = self:prepare(inst, "Copy", made)
		self:attach(list, nil, built, made)
		self:no_effect(built, if parent then self:find(parent).node else nil, p2)
		return built.id, { [id] = built.id }
	end
	if depth + height_of(src) > MAX_DEPTH then
		self:fail(`Copy: nodes nest at most {MAX_DEPTH} deep`)
	end
	if src.type == "instance" and type(descendants) == "table" then
		src.descendants = src.descendants or {}
		for k, v in descendants do
			Resolve.merge_override(src.descendants, k, v)
		end
	elseif type(descendants) == "table" then
		for did, dprops in descendants do
			local target = nil
			Resolve.walk(src.children, function(n)
				if n.id == did then
					target = n
					return false
				end
				return true
			end)
			if not target then
				self:fail(`Copy: no node inside "{id}" has the id "{did}"`)
			end
			self:set(target, dprops, "Copy")
		end
	end
	self:set(src, p2, "Copy")
	src.reusable = if is_inside(id) then nil else src.reusable
	local made = {}
	-- (N4) old id → new id for every node copied (Duplicate returns it;
	-- inside an Instance the old ids are the slash ids it's read by)
	local renamed = {}
	renew(self, src, made, renamed)
	self:attach(list, nil, src, made)
	self:no_effect(src, if parent then self:find(parent).node else nil, p2)
	return src.id, renamed
end

function D:replace(id: string, node: any): string
	if is_inside(id) then
		self:fail(`"{id}" is inside an Instance: override it with Update(id, \{ type = â€¦, â€¦ \}) instead`)
	end
	local f = self:find(id)
	if not f then
		self:missing(id)
	end
	local made = {}
	local built = self:prepare(node, "Replace", made)
	local list, i = f.list, f.index
	Resolve.walk({ f.node }, function(n)
		if type(n.id) == "string" then
			self.deleted[n.id] = tostring(n.name or n.type)
		end
		return true
	end)
	table.remove(list, i)
	self:stale()
	self:attach(list, i - 1, built, made)
	self:changed_id(id)
	return built.id
end

function D:move(id: string, parent: string?, index: number?)
	if is_inside(id) then
		self:fail(`Move: "{id}" is inside an Instance`)
	end
	local f = self:find(id)
	if not f then
		self:missing(id)
	end
	-- not into itself
	if parent then
		local p = self:find(parent)
		while p do
			if p.node.id == id then
				self:fail(`Move: "{id}" can't go inside itself`)
			end
			p = if p.parent then self:find(p.parent.id) else nil
		end
	end
	local list = self:children_of(parent)
	local node = table.remove(f.list, f.index)
	self:stale()
	local i = if index then math.clamp(math.floor(index) + 1, 1, #list + 1) else #list + 1
	table.insert(list, i, node)
	self:stale()
	self:changed_id(id)
	if f.parent then
		self:changed_id(f.parent.id)
	end
end

function D:delete(ids: any)
	if type(ids) ~= "table" then
		ids = { ids }
	end
	for _, id in ids do
		if type(id) ~= "string" then
			self:fail("Delete takes ids (strings)")
		end
		if is_inside(id) then
			self:fail(`Delete: "{id}" is inside an Instance: hide it with Update(id, \{ enabled = false \})`)
		end
		if not self:find(id) then
			self:missing(id)
		end
	end
	for _, id in ids do
		local f = self:find(id)
		if f then
			Resolve.walk({ f.node }, function(n)
				if type(n.id) == "string" then
					self.deleted[n.id] = tostring(n.name or n.type)
				end
				return true
			end)
			table.remove(f.list, f.index)
			if f.parent then
				self:changed_id(f.parent.id)
			end
			self.changed[id] = true
			self:stale()
		end
	end
end

-- â”€â”€ reading â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local function cut(n: any, depth: number): any
	local out = {}
	for k, v in n do
		if k ~= "children" then
			out[k] = U.deep_copy(v)
		end
	end
	if type(n.children) == "table" and depth > 0 then
		local kids = {}
		for _, c in n.children do
			table.insert(kids, cut(c, depth - 1))
		end
		out.children = kids
	end
	return out
end

function D:get(id: string?, opts: any?): any
	opts = opts or {}
	local depth = if type(opts.depth) == "number" then opts.depth else 1
	local resolved = opts.resolveTokens == true or opts.expandInstances == true
	-- As Get reads: hidden nodes kept; only what it asks resolved (a node
	-- inside an Instance is read as the Instance draws it).
	local how = {
		keep_disabled = true,
		keep_tokens = opts.resolveTokens ~= true,
		no_instances = opts.expandInstances ~= true and not (id and is_inside(id)),
	}
	if id == nil then
		local list = {}
		if resolved then
			local r = Resolve.new(self.d.doc, self.d.view_theme)
			for k, v in how do
				r[k] = v
			end
			for _, n in r:roots(self.d.doc) do
				table.insert(list, cut(clean_resolved(n), depth - 1))
			end
		else
			for _, n in self.d.doc.children do
				table.insert(list, cut(n, depth - 1))
			end
		end
		return list
	end
	if is_inside(id) or resolved then
		local r = self:resolved_find(id, how)
		if not r then
			self:missing(id)
		end
		return cut(clean_resolved(r), depth)
	end
	local f = self:find(id)
	if not f then
		self:missing(id)
	end
	return cut(f.node, depth)
end

local PROBLEM_TEXT = {
	clipped = "partially clipped",
	fully_clipped = "fully clipped",
	text_overflow = "text taller than its height, overflowing it",
	fit_around_fill = "fit content around children that all fill container: sized from their own content, or 100 px each without any",
}

-- The resolved, laid-out roots (all, or the one holding `id`). `run`
-- (step 5, Simulate): { vars, mode }, the prototype's variables at run time.
function D:laid_out(id: string?, swap: any?, run: any?): { any }
	local r = Resolve.new(self.d.doc, self.d.view_theme, run)
	-- (step 4) Play's variant state: { [instance id] = member id }
	r.swap = swap
	local ids = nil
	if id then
		local top = string.match(id, "^([^/]+)") or id
		local f = self:find(top)
		if not f then
			self:missing(id)
		end
		while f.parent do
			f = self:find(f.parent.id)
		end
		ids = { f.node.id }
	end
	local roots = r:roots(self.d.doc, ids)
	Layout.run(roots)
	self.problems = r.problems
	return roots
end

-- (B1) A rotation set by an agent turns the layer about its centre, as
-- Figma's rotation field and the Canvas's rotate handle do. The file keeps
-- Figma's (and pen's) form: x, y are the turned layer's top-left corner, so
-- that corner moves. `turns` = { { id, old rotation } }. A layer its
-- parent's layout places has no x, y of its own and is left as it is.
function D:turn_about_centre(turns: { any })
	local laid: { [string]: any } = {}
	for _, t in turns do
		local f = self:find(t.id)
		if not f then
			continue
		end
		local node = f.node
		local parent = f.parent
		local new = U.num(node.rotation, 0)
		if new == t.old or (parent and (parent.layout == "horizontal" or parent.layout == "vertical") and node.absolute ~= true) then
			continue
		end
		local box = laid[t.id]
		if box == nil then
			local ok, roots = pcall(self.laid_out, self, t.id)
			Resolve.walk(if ok then roots else {}, function(n)
				if n.__box then
					laid[n.id] = n.__box
				end
				return true
			end)
			box = laid[t.id]
		end
		if box then
			local function turned(deg: number): (number, number)
				local a = math.rad(-deg)
				local px, py = box.w / 2, box.h / 2
				return math.cos(a) * px - math.sin(a) * py, math.sin(a) * px + math.cos(a) * py
			end
			local ox, oy = turned(t.old)
			local nx, ny = turned(new)
			local function r2(v: number): number
				return math.floor(v * 100 + 0.5) / 100
			end
			node.x = r2(U.num(node.x, 0) + ox - nx)
			node.y = r2(U.num(node.y, 0) + oy - ny)
			self:stale()
			self:changed_id(t.id)
		end
	end
end

function D:visit(id: string?, visitor: any)
	local roots = self:laid_out(id)
	local start = nil
	if id then
		local function find(n)
			if n.id == id then
				return n
			end
			for _, c in (n.children or {}) do
				local f = find(c)
				if f then
					return f
				end
			end
			return nil
		end
		for _, r in roots do
			start = find(r)
			if start then
				break
			end
		end
		if not start then
			self:fail(`no node has the id "{id}" (or it isn't drawn: enabled = false)`)
		end
	end
	local parents = {}
	if start then
		-- the parent of where the visit starts, for "outside parent"
		local function up(n, p)
			if n == start then
				parents[start] = p
				return true
			end
			for _, c in (n.children or {}) do
				if up(c, n) then
					return true
				end
			end
			return false
		end
		for _, r in roots do
			if up(r, nil) then
				break
			end
		end
	end
	local function go(n, depth, index, parent, pnode)
		local b = n.__box
		local probs = M.problems_of(n, pnode)
		local info = { bounds = { x = b.x, y = b.y, width = b.w, height = b.h }, depth = depth, index = index, parent = parent, problems = probs, component = n.__inst, links = Proto.links(n) }
		local plain = cut(clean_resolved(n), 0)
		if visitor(plain, info) == false then
			return
		end
		for i, c in (n.children or {}) do
			go(c, depth + 1, i - 1, n.id, n)
		end
	end
	if start then
		local p = parents[start]
		go(start, 0, 0, p and p.id, p)
	else
		for i, r in roots do
			go(r, 0, i - 1, nil, nil)
		end
	end
end

-- The ids of nodes named `name` (as drawn: inside Instances too, as slash
-- ids; hidden ones included), depth first, under `root` or the Canvas.
function D:find_by_name(name: string, root: string?): { string }
	local r = Resolve.new(self.d.doc, self.d.view_theme)
	r.keep_disabled = true
	r.keep_tokens = true
	local ids = nil
	if root then
		local top = string.match(root, "^([^/]+)") or root
		local f = self:find(top)
		if not f then
			self:missing(root)
		end
		while f.parent do
			f = self:find(f.parent.id)
		end
		ids = { f.node.id }
	end
	local out = {}
	local function walk(n, inside)
		inside = inside or n.id == root
		if inside and n.name == name and n.id ~= root then
			table.insert(out, n.id)
		end
		for _, c in (n.children or {}) do
			walk(c, inside)
		end
	end
	local found_root = root == nil
	for _, n in r:roots(self.d.doc, ids) do
		if root then
			local function has(x)
				if x.id == root then
					return true
				end
				for _, c in (x.children or {}) do
					if has(c) then
						return true
					end
				end
				return false
			end
			found_root = found_root or has(n)
		end
		walk(n, root == nil)
	end
	if not found_root then
		self:missing(root)
	end
	return out
end

-- Props that do nothing on a Frame without a layout.
local LAYOUT_ONLY = { "padding", "gap", "justifyContent", "alignItems" }
local function inert(n: any): { string }?
	if n.type ~= "frame" or n.layout == "horizontal" or n.layout == "vertical" then
		return nil
	end
	local out = nil
	for _, k in LAYOUT_ONLY do
		local v = n[k]
		if v ~= nil and v ~= 0 and v ~= "start" then
			out = out or {}
			table.insert(out, k)
		end
	end
	return out
end
M.inert = inert

-- (N4) Props a call set that do nothing where the node sits, as warnings
-- ("… had no effect"): `keys` are the props the call gave, `parent` the
-- node's parent (nil on the Canvas). Layout props on a Frame without a
-- layout are check_values's (inert above).
function D:no_effect(n: any, parent: any?, keys: any)
	local function given(k: string): boolean
		return keys[k] ~= nil and not U.is_null(keys[k])
	end
	local name = tostring(n.name)
	local laid = parent and (parent.layout == "horizontal" or parent.layout == "vertical")
	if laid and n.absolute ~= true then
		local xy = {}
		for _, k in { "x", "y" } do
			if given(k) and keys[k] ~= 0 then
				table.insert(xy, k)
			end
		end
		if #xy > 0 then
			self:warn(n.id, xy[1], `"{name}": {table.concat(xy, ", ")} had no effect: its parent "{tostring(parent.name)}" (layout = "{parent.layout}") places it. Set absolute = true to place it yourself, or drop them`)
		end
	elseif given("absolute") and keys.absolute == true and not laid then
		self:warn(n.id, "absolute", `"{name}": absolute had no effect: {if parent then `its parent "{tostring(parent.name)}" has no layout` else "it's on the Canvas"}, so it's placed by x, y already`)
	end
	if n.type == "text" then
		local g = n.textGrowth
		if g == "auto" and (given("width") or given("height")) then
			self:warn(n.id, "width", `"{name}": width/height had no effect with textGrowth = "auto" (the text sizes itself): use textGrowth = "fixed_width" to wrap at a width`)
		elseif (g == "fixed_width" or g == "fixed-width") and given("height") then
			self:warn(n.id, "height", `"{name}": height had no effect with textGrowth = "fixed_width" (the height follows the text): use "fixed_width_height" to fix it`)
		end
	end
	if parent == nil and (n.type == "frame" or n.type == "instance") then
		for _, k in { "width", "height" } do
			if given(k) and keys[k] == "fill_container" then
				self:warn(n.id, k, `"{name}": {k} = "fill_container" had no effect on the Canvas (no container): it sizes as fit_content; give a number`)
			end
		end
	end
end

-- no_effect over a node just put in `parent` and what it holds (Insert).
function D:no_effect_tree(n: any, parent: any?, depth: number?)
	if (depth or 0) > MAX_DEPTH then
		return
	end
	self:no_effect(n, parent, n)
	for _, c in U.list(n.children) do
		self:no_effect_tree(c, n, (depth or 0) + 1)
	end
end

-- A laid-out node's problems as words: layout's, a box past a parent that
-- doesn't clip, and layout props on a Frame without a layout.
function M.problems_of(n: any, parent: any?): { string }
	local probs = {}
	for _, p in (n.__prob or {}) do
		table.insert(probs, PROBLEM_TEXT[p] or p)
	end
	local b = n.__box
	if parent and parent.__box and parent.clip ~= true and b and b.w > 0 and b.h > 0 and n.rotation == nil and parent.rotation == nil then
		local pb = parent.__box
		local e = 0.5
		if b.x < pb.x - e or b.y < pb.y - e or b.x + b.w > pb.x + pb.w + e or b.y + b.h > pb.y + pb.h + e then
			table.insert(probs, "outside parent")
		end
	end
	local dead = inert(n)
	if dead then
		table.insert(probs, `{table.concat(dead, ", ")} do nothing without a layout`)
	end
	return probs
end

-- Each node's box past the viewport `w` × `h` from the root `id`'s top left
-- (h optional): the "fits a viewport" check for Screens.
function D:fits(id: string, w: number, h: number?): (boolean, { string })
	local roots = self:laid_out(id)
	local start = nil
	local function find(n)
		if n.id == id then
			start = n
			return
		end
		for _, c in (n.children or {}) do
			if not start then
				find(c)
			end
		end
	end
	for _, r in roots do
		find(r)
	end
	if not start then
		self:fail(`no node has the id "{id}" (or it isn't drawn: enabled = false)`)
	end
	local ox, oy = start.__box.x, start.__box.y
	local issues = {}
	local function walk(n, clipped_at)
		local b = n.__box
		local right, bottom = b.x + b.w - ox, b.y + b.h - oy
		if b.w > 0 and b.h > 0 and clipped_at == nil then
			if right > w + 0.5 then
				table.insert(issues, `{tostring(n.name)} ({n.id}) ends at x {math.floor(right + 0.5)}, {math.floor(right - w + 0.5)} past {w}`)
			elseif h and bottom > h + 0.5 then
				table.insert(issues, `{tostring(n.name)} ({n.id}) ends at y {math.floor(bottom + 0.5)}, {math.floor(bottom - h + 0.5)} past {h}`)
			end
		end
		if #issues >= 20 then
			return
		end
		-- a clipping node inside the viewport hides what's past it
		local inner = clipped_at
		if n ~= start and n.clip == true and right <= w + 0.5 and (h == nil or bottom <= h + 0.5) then
			inner = n
		end
		if right > w + 0.5 or (h and bottom > h + 0.5) then
			-- report the outermost only
			return
		end
		for _, c in (n.children or {}) do
			walk(c, inner)
		end
	end
	walk(start, nil)
	return #issues == 0, issues
end

function D:empty_space(w: any): any
	w = w or {}
	local width, height = U.num(w.width, 0), U.num(w.height, 0)
	local pad = U.num(w.padding, 100)
	local dir = w.direction or "right"
	local roots = self:laid_out(nil)
	local boxes = {}
	for _, r in roots do
		table.insert(boxes, r.__box)
	end
	if #boxes == 0 then
		return { x = 0, y = 0 }
	end
	local from = nil
	if w.from then
		for _, r in roots do
			if r.id == w.from then
				from = r.__box
			end
		end
		if not from then
			self:fail(`FindEmptySpace: no Canvas node has the id "{tostring(w.from)}"`)
		end
	end
	local function overlaps(x, y)
		for _, b in boxes do
			if x < b.x + b.w + pad and b.x < x + width + pad and y < b.y + b.h + pad and b.y < y + height + pad then
				return b
			end
		end
		return nil
	end
	local x, y
	if from then
		if dir == "left" then
			x, y = from.x - pad - width, from.y
		elseif dir == "top" then
			x, y = from.x, from.y - pad - height
		elseif dir == "bottom" then
			x, y = from.x, from.y + from.h + pad
		else
			x, y = from.x + from.w + pad, from.y
		end
	else
		local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
		for _, b in boxes do
			minx, miny = math.min(minx, b.x), math.min(miny, b.y)
			maxx, maxy = math.max(maxx, b.x + b.w), math.max(maxy, b.y + b.h)
		end
		if dir == "left" then
			x, y = minx - pad - width, miny
		elseif dir == "top" then
			x, y = minx, miny - pad - height
		elseif dir == "bottom" then
			x, y = minx, maxy + pad
		else
			x, y = maxx + pad, miny
		end
	end
	-- step on past anything in the way
	for _ = 1, 200 do
		local b = overlaps(x, y)
		if not b then
			break
		end
		if dir == "left" then
			x = b.x - pad - width
		elseif dir == "top" then
			y = b.y - pad - height
		elseif dir == "bottom" then
			y = b.y + b.h + pad
		else
			x = b.x + b.w + pad
		end
	end
	return { x = x, y = y }
end

-- â”€â”€ tokens â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

function D:set_tokens(tokens: any, replace: boolean?)
	if type(tokens) ~= "table" then
		self:fail("SetTokens takes a table of Tokens by name")
	end
	local doc = self.d.doc
	local now = if replace then {} else U.deep_copy(doc.tokens or {})
	for name, tok in tokens do
		if type(name) ~= "string" or string.sub(name, 1, 1) == "$" or not string.match(name, "^[%w%-_%./]+$") then
			self:fail(`"{tostring(name)}" can't name a Token: use letters, digits, "-", "_", "." and "/" (no "$")`)
		end
		if U.is_null(tok) then
			now[name] = nil
		else
			local _, why = Resolve.read_token(name, tok)
			if why then
				self:fail(why)
			end
			now[name] = U.deep_copy(tok)
			-- a themed value's axes and values join the Design's Themes
			if type(tok.value) == "table" then
				doc.themes = doc.themes or {}
				for _, themed in tok.value do
					for axis, val in (type(themed) == "table" and themed.theme or {}) do
						local values = doc.themes[axis]
						if type(values) ~= "table" then
							values = {}
							doc.themes[axis] = values
						end
						if not table.find(values, val) then
							table.insert(values, val)
						end
					end
				end
			end
		end
	end
	doc.tokens = now
	self.tokens_changed = true
	self.var_ctx_ = nil
end

function D:set_themes(axis: string, values: any)
	local doc = self.d.doc
	doc.themes = doc.themes or {}
	if values == nil or U.is_null(values) or (type(values) == "table" and #values == 0) then
		doc.themes[axis] = nil
	else
		doc.themes[axis] = U.deep_copy(values)
	end
	self.tokens_changed = true
	self.var_ctx_ = nil
end

-- Warnings found once the draft is done: resolve problems on what changed,
-- and text without a fill.
local function rgba(hex: any): { number }?
	local c = U.color(hex)
	if not c then
		return nil
	end
	local function h(i)
		return (tonumber(string.sub(c, i, i + 1), 16) or 0) / 255
	end
	return { h(2), h(4), h(6), h(8) }
end

-- The colour a fill shows on top: a colour, false when it's a gradient or
-- an image (unknown), nil when it has no fill.
local function top_paint(fill: any): any
	local list = U.list(fill)
	for i = #list, 1, -1 do
		local p = list[i]
		if type(p) == "string" then
			return rgba(p)
		elseif type(p) == "table" and p.enabled ~= false then
			if p.type == "color" then
				local c = rgba(p.color)
				if c and type(p.opacity) == "number" then
					c[4] *= p.opacity
				end
				return c
			end
			return false
		end
	end
	return nil
end

local function over(top: { number }, bottom: { number }): { number }
	local a = top[4]
	return { top[1] * a + bottom[1] * (1 - a), top[2] * a + bottom[2] * (1 - a), top[3] * a + bottom[3] * (1 - a), 1 }
end

local function luminance(c: { number }): number
	local function ch(v)
		return if v <= 0.03928 then v / 12.92 else ((v + 0.055) / 1.055) ^ 2.4
	end
	return 0.2126 * ch(c[1]) + 0.7152 * ch(c[2]) + 0.0722 * ch(c[3])
end

local function contrast(a: { number }, b: { number }): number
	local la, lb = luminance(a), luminance(b)
	return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05)
end
M.contrast = function(a: string, b: string): number?
	local x, y = rgba(a), rgba(b)
	return if x and y then contrast(x, y) else nil
end

local LINT_SHOWN = 6

-- The lint rules a node turns off for itself and what it holds: `lint =
-- false` (all: true) or `lintIgnore = { "contrast", … }`, added to `off`.
local function muted_rules(n: any, off: any): any
	if off == true or n.lint == false then
		return true
	end
	local list = n.lintIgnore
	if type(list) == "string" then
		list = { list }
	end
	if type(list) ~= "table" or #list == 0 then
		return off
	end
	local out = if off then table.clone(off) else {}
	for _, rule in list do
		out[tostring(rule)] = true
	end
	return out
end

-- Text meant to be faint, by its name: placeholders, disabled labels,
-- hints, muted text.
local FAINT = { "placeholder", "disabled", "hint", "muted" }
local function intended_faint(name: any): boolean
	if type(name) ~= "string" then
		return false
	end
	local low = string.lower(name)
	for _, w in FAINT do
		if string.find(low, w, 1, true) then
			return true
		end
	end
	return false
end

-- The built-in lint over what this draft touched, on the drawn `roots`:
-- text under 12 px, text with low contrast on its background, and raw hex
-- colours in a Design that has colour Tokens. One warning per rule.
function D:lint(roots: { any })
	local small, low, raw = {}, {}, {}
	local function touched(id: string): boolean
		return self.changed[id] == true or self.changed[string.match(id, "^([^/]+)") or id] == true
	end
	local function walk(n, bg, hot, off)
		hot = hot or touched(n.id)
		off = muted_rules(n, off)
		if n.type == "text" then
			if hot and off ~= true then
				local quiet_contrast = (off and off.contrast) or intended_faint(n.name)
				local size = if type(n.fontSize) == "number" then n.fontSize else 14
				if size < 12 and not (off and off["small-text"]) then
					table.insert(small, `{tostring(n.name)} ({size} px)`)
				end
				local fg = top_paint(n.fill)
				if fg and type(bg) == "table" and not quiet_contrast then
					local shown = if fg[4] < 1 then over(fg, bg) else fg
					local weight = if type(n.fontWeight) == "number" then n.fontWeight else tonumber(n.fontWeight) or 400
					local large = size >= 24 or (size >= 18.5 and weight >= 700)
					local need = if large then 3 else 4.5
					local ratio = contrast(shown, bg)
					if ratio < need then
						table.insert(low, `{tostring(n.name)} ({string.format("%.1f", ratio)}:1, needs {need})`)
					end
				end
			end
			return
		end
		local paint = top_paint(n.fill)
		local under = bg
		if paint == false then
			under = false
		elseif paint then
			if type(bg) == "table" then
				under = over(paint, bg)
			elseif paint[4] >= 0.99 and bg == nil then
				under = paint
			elseif bg == nil then
				under = false
			end
		end
		for _, c in (n.children or {}) do
			walk(c, under, hot, off)
		end
	end
	for _, r in roots do
		walk(r, nil, false, nil)
	end
	-- raw hex where colour Tokens exist
	local by_hex, any_colour = {}, false
	for name, tok in (self.d.doc.tokens or {}) do
		if type(tok) == "table" and tok.type == "color" then
			any_colour = true
			local v = if type(tok.value) == "table" then (tok.value[1] or {}).value else tok.value
			local c = U.color(v)
			if c and not by_hex[c] then
				by_hex[c] = name
			end
		end
	end
	if any_colour then
		local function hexes(v, out)
			if type(v) == "string" then
				local c = U.color(v)
				if c then
					table.insert(out, v)
				end
			elseif type(v) == "table" then
				for k, x in v do
					if k ~= "url" then
						hexes(x, out)
					end
				end
			end
		end
		for _, id in self.changed_list do
			if not is_inside(id) then
				local f = self:find(id)
				local off = false
				local up = f
				while up do
					local o = muted_rules(up.node, nil)
					if o == true or (o and o["raw-colour"]) then
						off = true
						break
					end
					up = if up.parent then self:find(up.parent.id) else nil
				end
				if f and not off then
					local found = {}
					for _, k in { "fill", "stroke", "effect" } do
						hexes(f.node[k], found)
					end
					for _, hx in found do
						local tok = by_hex[U.color(hx) :: string]
						table.insert(raw, `{tostring(f.node.name)} {hx}` .. (if tok then ` = ${tok}` else ""))
					end
				end
			end
		end
	end
	local near = self:near_misses(roots)
	local function report(rule, list, what)
		if #list == 0 then
			return
		end
		local shown = {}
		for i = 1, math.min(#list, LINT_SHOWN) do
			shown[i] = list[i]
		end
		local more = if #list > LINT_SHOWN then `, and {#list - LINT_SHOWN} more` else ""
		table.insert(self.warnings, { lint = rule, message = `{#list} {what}: {table.concat(shown, "; ")}{more}` })
	end
	report("small-text", small, "texts under 12 px")
	report("contrast", low, "texts with low contrast on their background")
	report("raw-colour", raw, "raw hex colours where the Design has colour Tokens (use \"$name\")")
	report("near-align", near, "near-misses in alignment, 1–4 px off a sibling's edge or centre (set the x/y given; lintIgnore = \"near-align\" if meant)")
end

-- (N4) Near-miss alignment: a layer this call touched, placed by its own
-- x, y (its parent has no layout, or it's absolute), whose left / centre /
-- right (top / middle / bottom) is 1–4 px off the same edge of a sibling
-- within 200 px, while no edge of it lines up exactly with any sibling on
-- that axis (one exact match says the offset is meant). Auto layout
-- children are skipped: spacing places them. One hint per layer and axis.
local NEAR_MIN, NEAR_MAX, NEAR_REACH = 1, 4, 200
function D:near_misses(roots: { any }): { string }
	local out = {}
	local hot = {}
	for _, id in self.changed_list do
		local f = if is_inside(id) then nil else self:find(id)
		local p = f and f.parent
		-- only a layer placed by its own x, y, with a sibling
		if p and (not (p.layout == "horizontal" or p.layout == "vertical") or f.node.absolute == true) and #(p.children or {}) >= 2 then
			while f and f.parent do
				f = self:find(f.parent.id)
			end
			if f then
				hot[f.node.id] = true
			end
		end
	end
	local list = {}
	for _, r in roots do
		if hot[r.id] then
			table.insert(list, r)
		end
	end
	if #list == 0 then
		return out
	end
	Layout.run(list)
	local function muted(o: any): boolean
		return o == true or (type(o) == "table" and o["near-align"] == true)
	end
	local EDGE = { { "left", "centre", "right" }, { "top", "middle", "bottom" } }
	local function edges(b: any, axis: number): { number }
		if axis == 1 then
			return { b.x, b.x + b.w / 2, b.x + b.w }
		end
		return { b.y, b.y + b.h / 2, b.y + b.h }
	end
	local function round(v: number): string
		local r = math.floor(v * 10 + 0.5) / 10
		return if r == math.floor(r) then tostring(math.floor(r)) else tostring(r)
	end
	local function check(a: any, free: { any }, axis: number, pbox: any)
		local ab = a.__box
		local ae = edges(ab, axis)
		local best, best_d, best_s, best_k = nil, math.huge, nil, nil
		local before = true
		for _, s in free do
			if s == a then
				before = false
			else
				local sb = s.__box
				-- near on the other axis
				local gap
				if axis == 1 then
					gap = math.max(sb.y - (ab.y + ab.h), ab.y - (sb.y + sb.h), 0)
				else
					gap = math.max(sb.x - (ab.x + ab.w), ab.x - (sb.x + sb.w), 0)
				end
				local se = edges(sb, axis)
				for i = 1, 3 do
					for j = 1, 3 do
						if math.abs(se[j] - ae[i]) < NEAR_MIN then
							return -- lines up with a sibling on this axis: meant
						end
					end
				end
				-- the target: a sibling this call left alone, or one before it
				-- (two new layers off by 2 px: the later one gets the hint)
				if gap <= NEAR_REACH and (before or not self.changed[s.id]) then
					for k = 1, 3 do
						local d = se[k] - ae[k]
						if math.abs(d) >= NEAR_MIN and math.abs(d) <= NEAR_MAX + 0.01 and math.abs(d) < best_d then
							best, best_d, best_s, best_k = d, math.abs(d), s, k
						end
					end
				end
			end
		end
		if best then
			local key = if axis == 1 then "x" else "y"
			local own = a[key]
			local fix = if type(own) == "number" then `: {key} = {round(own + best)}` else ` (move it {round(best)} px)`
			table.insert(out, `"{tostring(a.name)}" {EDGE[axis][best_k]} is {round(best_d)} px off "{tostring(best_s.name)}" {EDGE[axis][best_k]}{fix}`)
		end
	end
	local function walk(n: any, off: any)
		off = muted_rules(n, off)
		if off == true then
			return
		end
		local kids = n.children or {}
		local laid = n.type == "frame" and (n.layout == "horizontal" or n.layout == "vertical")
		local free = {}
		for _, c in kids do
			local b = c.__box
			if b and b.w > 0 and b.h > 0 and (not laid or c.absolute == true) and U.num(c.rotation, 0) == 0 and c.enabled ~= false and not is_inside(c.id) then
				table.insert(free, c)
			end
		end
		if #free >= 2 and #free <= 80 then
			for _, a in free do
				if self.changed[a.id] and not muted(muted_rules(a, off)) then
					check(a, free, 1, n.__box)
					check(a, free, 2, n.__box)
				end
			end
		end
		for _, c in kids do
			walk(c, off)
		end
	end
	for _, r in list do
		walk(r, nil)
	end
	return out
end

function D:finish()
	-- (N2) a Variations set goes with its node
	Variations.prune(self)
	local r = Resolve.new(self.d.doc, self.d.view_theme)
	local drawn = r:roots(self.d.doc)
	if next(self.changed) ~= nil then
		self:lint(drawn)
		-- (scrolling: only roots touched that use overflow/scroll are laid out)
		Proto.lint_scroll({ changed = self.changed, layout = function(root)
			Layout.run({ root })
		end }, drawn, self.warnings)
	end
	if next(self.changed) ~= nil or self.proto_touched or next(self.deleted) ~= nil then
		Proto.lint({ doc = self.d.doc, changed = self.changed, deleted = self.deleted, touched = self.proto_touched }, drawn, self.warnings)
		-- (step 4) variant sets and Change to
		Proto.lint_variants(self.d.doc, drawn, self.warnings, self.changed)
	end
	-- (step 5) variables: actions and bindings against the Tokens
	if next(self.changed) ~= nil or self.proto_touched or self.tokens_changed then
		Proto.lint_vars({ doc = self.d.doc, changed = self.changed, all = self.proto_touched == true or self.tokens_changed == true }, self.warnings)
	end
	for _, p in r.problems do
		local top = string.match(p.node, "^([^/]+)") or p.node
		if self.changed[p.node] or self.changed[top] then
			self:warn(p.node, nil, p.message)
		end
	end
	for _, id in self.changed_list do
		local f = self:find(id)
		if f and f.node.type == "text" and f.node.fill == nil then
			self:warn(id, "fill", `"{tostring(f.node.name)}" (text) has no fill, so it's invisible: give it a fill colour`)
		end
	end
	local names, seen, counts = {}, {}, {}
	for _, m in self.created do
		if self:find(m.id) then
			local key, n = m.name, counts[m.name] or 1
			if seen[key] then
				repeat
					n += 1
					key = m.name .. " " .. n
				until not seen[key]
				counts[m.name] = n
			end
			seen[key] = true
			names[key] = m.id
		end
	end
	return names
end

-- The outermost nodes the draft changed (for flashes), at most `max`.
function D:outermost(max: number): { string }
	local out, taken = {}, {}
	for _, id in self.changed_list do
		local f = self:find(string.match(id, "^([^/]+)") or id)
		if f then
			local inside_changed = false
			local p = f.parent
			while p do
				if self.changed[p.id] then
					inside_changed = true
					break
				end
				local pf = self:find(p.id)
				p = pf and pf.parent
			end
			if not inside_changed and not taken[id] then
				taken[id] = true
				table.insert(out, id)
				if #out >= max then
					break
				end
			end
		end
	end
	return out
end

return M
