--!nonstrict
-- (N2) Variations: "show me 5 ways" (pure/anim/n2/README.md). A node (a
-- Screen, a card, a button) gets N versions, the original one of them. The
-- board, Play, export, Layers and History see one node: the version shown,
-- which always has the original's id (links to it keep working). The others
-- wait in `doc.variations`, keyed by that id:
--
--   doc.variations[slot] = {
--     current = 2,                       -- the version shown
--     list = { { name = "Original", original = true, node = <stored> },
--              { name = "Tighter hierarchy" },   -- shown: no node here
--              { name = "Bolder", node = <stored> } },
--     by = <chat>, made = <seconds>,
--   }
--
-- A stored version is the whole node (its top id is the slot's; ids inside
-- are its own). Flipping swaps the shown node and a stored one in place,
-- keeping the slot's x and y. `doc.variations` is its own part of a step
-- (engine/designs.luau), so a flip redraws only the Screen it's in.

local U = require("./util")
local Resolve = require("./resolve")

local M = {}

M.MAX = 15 -- versions in a set, the original counted (as Gui)
M.NAME_MAX = 40

local function sets_of(doc: any): any
	local v = doc.variations
	if type(v) ~= "table" or U.is_array(v) and next(v) ~= nil then
		return nil
	end
	return v
end
M.sets_of = sets_of

-- Every stored node's id, for a draft's id registry (no clash later).
function M.walk_stored(doc: any, visit: (any) -> ())
	local sets = sets_of(doc)
	if not sets then
		return
	end
	for _, s in sets do
		for _, e in U.list(s.list) do
			if type(e) == "table" and type(e.node) == "table" then
				Resolve.walk({ e.node }, function(n)
					visit(n)
					return true
				end)
			end
		end
	end
end

-- "2", 2 or a version's name → its index in `set`, or nil.
local function index_of(set: any, which: any): number?
	if type(which) == "number" then
		local i = math.floor(which)
		return if set.list[i] then i else nil
	end
	if type(which) == "string" then
		local n = tonumber(which)
		if n and set.list[math.floor(n)] then
			return math.floor(n)
		end
		local low = string.lower(which)
		for i, e in set.list do
			if string.lower(tostring(e.name)) == low then
				return i
			end
		end
		if low == "original" then
			for i, e in set.list do
				if e.original then
					return i
				end
			end
		end
	end
	return nil
end
M.index_of = index_of

local function original_index(set: any): number
	for i, e in set.list do
		if e.original then
			return i
		end
	end
	return 1
end

local function names(list: any): string
	local t = {}
	for i, e in list do
		table.insert(t, `{i} "{tostring(e.name)}"`)
	end
	return table.concat(t, ", ")
end

-- A set, as agents and the tab read it.
local function describe(slot: string, set: any): any
	local list = {}
	for i, e in set.list do
		table.insert(list, { index = i, name = e.name, original = e.original == true or nil })
	end
	return { id = slot, current = set.current, count = #set.list, name = set.list[set.current] and set.list[set.current].name, versions = list, by = set.by }
end
M.describe = describe

-- The sets whose node is in the doc, for the tab: { [slot] = { current,
-- count, names, original } } (no stored nodes), or nil when none.
function M.summary(doc: any): any
	local sets = sets_of(doc)
	if not sets or next(sets) == nil then
		return nil
	end
	local here = {}
	Resolve.walk(doc.children, function(n)
		if sets[n.id] then
			here[n.id] = true
		end
		return true
	end)
	local out = nil
	for slot, set in sets do
		if here[slot] and type(set.list) == "table" then
			out = out or {}
			local nm = {}
			for _, e in set.list do
				table.insert(nm, tostring(e.name))
			end
			out[slot] = { current = set.current, count = #set.list, names = nm, original = original_index(set), by = set.by }
		end
	end
	return out
end

-- Drops sets whose node is gone (deleted, or undone past) and sets of one.
function M.prune(draft: any)
	local doc = draft.d.doc
	local sets = sets_of(doc)
	if not sets then
		return
	end
	local any = false
	for slot, set in sets do
		any = true
		if not draft:find(slot) or type(set.list) ~= "table" or #set.list < 2 then
			sets[slot] = nil
		end
	end
	if any and next(sets) == nil then
		doc.variations = nil
	end
end

local function slot_of(draft: any, id: any): (string, any)
	if type(id) == "table" and type(id.id) == "string" then
		id = id.id
	end
	if type(id) ~= "string" then
		draft:fail("takes a node's id")
	end
	if string.find(id, "/", 1, true) then
		draft:fail(`"{id}" is inside an Instance: make versions of the Instance, or of its Component's layers`)
	end
	local f = draft:find(id)
	if not f then
		draft:missing(id)
	end
	return id, f
end

local function set_of(draft: any, slot: string): any
	local sets = sets_of(draft.d.doc)
	local set = sets and sets[slot]
	if not set then
		draft:fail(`"{slot}" has no variations (make them with Variations(id, list))`)
	end
	return set
end

-- Shows version `i` of `slot`'s set in the slot's place.
local function show(draft: any, slot: string, set: any, i: number)
	if i == set.current then
		return
	end
	local f = draft:find(slot)
	local live = f.node
	local incoming = set.list[i].node
	if type(incoming) ~= "table" then
		draft:fail(`version {i} of "{slot}" has nothing stored`)
	end
	set.list[set.current].node = live
	set.list[i].node = nil
	incoming = U.deep_copy(incoming)
	incoming.id = slot
	-- in the original's place
	incoming.x, incoming.y = live.x, live.y
	if live.absolute ~= nil then
		incoming.absolute = live.absolute
	end
	f.list[f.index] = incoming
	set.current = i
	draft:stale()
	draft:changed_id(slot)
end

-- No node a Component holds (its Instances would each copy the set).
local function check_place(draft: any, slot: string, f: any)
	local p = f
	while p do
		if p.node.type == "frame" and p.node.reusable == true then
			draft:fail(if p == f
				then `"{tostring(f.node.name)}" is a Component: its variants are MakeVariants' job; Variations makes versions of a Screen or a layer`
				else `"{tostring(f.node.name)}" is inside the Component "{tostring(p.node.name)}": make versions of a layer outside Components (or the variants with MakeVariants)`)
		end
		p = if p.parent then draft:find(p.parent.id) else nil
	end
end

-- Variations(id, entries, opts) inside a snippet. `entries`: a list of
-- { name, build = function(id, map) } (edits a copy of the original),
-- { name, props = {...} } (a copy with these props) or
-- { name, node = {...} } (a new node in its place). `api` = the snippet's
-- env (Update, Insert, … run against the copy). opts.show: index or name
-- shown after (default the first new one); opts.original: its name.
function M.make(draft: any, id: any, entries: any, opts: any, chat: string?): any
	local slot, f = slot_of(draft, id)
	check_place(draft, slot, f)
	if type(entries) ~= "table" or entries[1] == nil then
		draft:fail("Variations takes a list: { { name = \"Tighter\", build = function(id, map) … end }, … }")
	end
	opts = if type(opts) == "table" then opts else {}
	local doc = draft.d.doc
	local sets = sets_of(doc)
	if not sets then
		sets = {}
		doc.variations = sets
	end
	local set = sets[slot]
	if not set then
		local oname = if type(opts.original) == "string" and opts.original ~= "" then string.sub(opts.original, 1, M.NAME_MAX) else "Original"
		set = { current = 1, list = { { name = oname, original = true } }, by = chat, made = os.time() }
		sets[slot] = set
	end
	if #set.list + #entries > M.MAX then
		draft:fail(`a set holds at most {M.MAX} versions, the original counted ("{tostring(f.node.name)}" has {#set.list})`)
	end
	-- each version is built where the original is (its parent's layout and
	-- widths apply), then stored
	local parent = if f.parent then f.parent.id else nil
	local first_new = #set.list + 1
	for k, e in entries do
		if type(e) ~= "table" then
			draft:fail(`version {k} is a table: \{ name = "…", build = function(id, map) … end \}`)
		end
		local name = e.name
		if type(name) ~= "string" or name == "" then
			draft:fail(`version {k} needs a name (a few words: "Tighter hierarchy")`)
		end
		name = string.sub(name, 1, M.NAME_MAX)
		for _, other in set.list do
			if string.lower(tostring(other.name)) == string.lower(name) then
				draft:fail(`two versions are called "{name}": name each differently`)
			end
		end
		local at = draft:find(slot)
		local nid
		if type(e.node) == "table" then
			nid = draft:insert(parent, e.node)
		else
			local map
			nid, map = draft:copy(slot, parent, if type(e.props) == "table" then e.props else nil)
			draft:move(nid, parent, at.index)
			if type(e.build) == "function" then
				e.build(nid, map or { [slot] = nid })
			elseif e.build ~= nil then
				draft:fail(`version {k}'s build is a function(id, map)`)
			end
		end
		local nf = draft:find(nid)
		if not nf then
			draft:fail(`version "{name}" was deleted while it was built`)
		end
		local node = table.remove(nf.list, nf.index)
		draft:stale()
		node.id = slot
		table.insert(set.list, { name = name, node = node })
	end
	-- (the original's own children may have been touched by a build: they're
	-- the original's, and stay)
	local want = if opts.show ~= nil then index_of(set, opts.show) else first_new
	if not want then
		draft:fail(`Variations: show "{tostring(opts.show)}" isn't one of {names(set.list)}`)
	end
	show(draft, slot, set, want)
	draft:changed_id(slot)
	return describe(slot, set)
end

function M.get(draft: any, id: any): any
	local sets = sets_of(draft.d.doc)
	if id == nil then
		local out = {}
		for slot, set in sets or {} do
			if draft:find(slot) then
				table.insert(out, describe(slot, set))
			end
		end
		table.sort(out, function(a, b)
			return a.id < b.id
		end)
		return out
	end
	local slot = slot_of(draft, id)
	local set = sets and sets[slot]
	return if set then describe(slot, set) else nil
end

function M.show(draft: any, id: any, which: any): any
	local slot = slot_of(draft, id)
	local set = set_of(draft, slot)
	local i = index_of(set, which)
	if not i then
		draft:fail(`"{tostring(which)}" isn't one of {names(set.list)}`)
	end
	show(draft, slot, set, i)
	return describe(slot, set)
end

-- Keeps one version (the shown one when `which` is nil) as the node; the
-- others go.
function M.keep(draft: any, id: any, which: any): any
	local slot = slot_of(draft, id)
	local set = set_of(draft, slot)
	local i = if which == nil then set.current else index_of(set, which)
	if not i then
		draft:fail(`"{tostring(which)}" isn't one of {names(set.list)}`)
	end
	show(draft, slot, set, i)
	local kept = set.list[i].name
	draft.d.doc.variations[slot] = nil
	if next(draft.d.doc.variations) == nil then
		draft.d.doc.variations = nil
	end
	draft:changed_id(slot)
	return kept
end

-- Back to the original; every other version goes.
function M.discard(draft: any, id: any)
	local slot = slot_of(draft, id)
	local set = set_of(draft, slot)
	M.keep(draft, slot, original_index(set))
end

-- A copy of `doc` (shallow, but for the root holding `slot`) with version `i`
-- of its set in the slot's place: for screenshots of versions not shown.
-- Returns doc, root id; nil when there's no such version.
function M.doc_with(doc: any, slot: string, i: number): (any?, string?)
	local sets = sets_of(doc)
	local set = sets and sets[slot]
	if not set or not set.list[i] then
		return nil, nil
	end
	local root_i, path = nil, nil
	local function find(list: any, trail: { number }): boolean
		for k, n in U.list(list) do
			if type(n) == "table" then
				if n.id == slot then
					path = table.clone(trail)
					table.insert(path, k)
					return true
				end
				table.insert(trail, k)
				if find(n.children, trail) then
					return true
				end
				table.remove(trail)
			end
		end
		return false
	end
	if not find(doc.children, {}) then
		return nil, nil
	end
	root_i = path[1]
	local out = table.clone(doc)
	out.children = table.clone(doc.children)
	if i == set.current then
		return out, out.children[root_i].id
	end
	local root = U.deep_copy(doc.children[root_i])
	out.children[root_i] = root
	local list, node = out.children, root
	for k = 2, #path do
		list = node.children
		node = list[path[k]]
	end
	if #path == 1 then
		list = out.children
	end
	local incoming = U.deep_copy(set.list[i].node)
	incoming.id = slot
	incoming.x, incoming.y = node.x, node.y
	list[path[#path]] = incoming
	return out, out.children[root_i].id
end

return M
