--!strict
-- The interaction clipboard (F6 C3): Ctrl+C on selected interactions (noodles
-- on the Canvas, or a row picked in the Prototype panel), Ctrl+V on layers
-- appends them to each layer's interactions, as Figma does. It is the tab's
-- own, apart from the service's layer clipboard; Ctrl+V pastes whichever was
-- copied last (`newer`). Module-wide, so every Design tab in the window shares
-- it. Records are kept as stored (variable actions, Conditionals and all);
-- a destination (`to`, at any depth) the Design doesn't have is dropped on a
-- paste, and `paste` says so.
--
--   IaClip.put(records)              -- after a copy of interactions
--   IaClip.layers_copied()           -- after a copy of layers
--   IaClip.newer() → boolean         -- the interactions were copied last
--   IaClip.records(source, keys, done(recs))  -- `{ id, k }` (noodles) → stored records
--   IaClip.paste(source, ids, o?)    -- append to each layer, one edit

local Noodles = require("./noodles")

local M = {}

local seq = 0
local clip: { any }? = nil
local ia_at = 0
local layer_at = 0

local function deep(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local o = {}
	for k, x in v do
		o[k] = deep(x)
	end
	return o
end
M.deep = deep

function M.put(records: { any })
	seq += 1
	clip = deep(records)
	ia_at = seq
end

function M.layers_copied()
	seq += 1
	layer_at = seq
end

function M.has(): boolean
	return clip ~= nil and #(clip :: any) > 0
end

function M.newer(): boolean
	return M.has() and ia_at > layer_at
end

function M.get(): { any }
	return deep(clip or {})
end

-- (tests)
function M.reset()
	seq, clip, ia_at, layer_at = 0, nil, 0, 0
end

-- The ids the Design has: its roots and every node the scene lists.
-- `complete` is false while a root's nodes aren't loaded yet (then only a
-- missing Screen is known missing).
function M.ids_of(roots: { any }?): ({ [string]: boolean }, boolean)
	local ids: { [string]: boolean } = {}
	local complete = true
	for _, r in roots or {} do
		if type(r) == "table" then
			if r.id then
				ids[r.id] = true
			end
			if type(r.nodes) == "table" then
				for _, n in r.nodes do
					if type(n) == "table" and n.id then
						ids[n.id] = true
					end
				end
			else
				complete = false
			end
		end
	end
	return ids, complete
end

-- The records with every action whose destination isn't in `ids` taken out
-- (inside a Conditional's branches too); a reaction left with no action goes.
-- Returns (records, dropped = { "navigate → id", … }).
function M.keep(records: { any }, ids: { [string]: boolean }, complete: boolean?, roots: { any }?): ({ any }, { string })
	local dropped: { string } = {}
	local is_root: { [string]: boolean } = {}
	for _, r in roots or {} do
		if type(r) == "table" and r.id then
			is_root[r.id] = true
		end
	end
	local function missing(to: any): boolean
		if type(to) ~= "string" or to == "" then
			return false
		end
		if ids[to] then
			return false
		end
		-- (a node in a root not loaded yet may be there; a Screen would be listed)
		return complete ~= false
	end
	local function filter(actions: any): { any }
		local out = {}
		for _, a in (if type(actions) == "table" then actions else {}) do
			if type(a) == "table" and missing(a.to) then
				table.insert(dropped, `{tostring(a.action)} → {tostring(a.to)}`)
			else
				if type(a) == "table" and a.action == "conditional" then
					a["then"] = filter(a["then"])
					a["else"] = filter(a["else"])
				end
				table.insert(out, a)
			end
		end
		return out
	end
	local out = {}
	for _, rec in deep(records) do
		if type(rec) == "table" then
			local had = type(rec.actions) == "table" and #rec.actions > 0
			rec.actions = filter(rec.actions)
			if #rec.actions > 0 or not had then
				table.insert(out, rec)
			end
		end
	end
	return out, dropped
end

-- A layer's list to add to: its own, or (an Instance with none of its own)
-- the Component's, as the panel shows it.
function M.base(id: string, info: any?): { any }
	local nd = (info and info.node) or {}
	local rs = (info and info.resolved) or {}
	local inst = nd.type == "instance" or string.find(id, "/", 1, true) ~= nil
	local own = nd.interactions
	if type(own) == "table" then
		return deep(own)
	end
	if inst and type(rs.interactions) == "table" then
		return deep(rs.interactions)
	end
	return {}
end

-- The ops that append `records` to each layer (`infos[id]` from source.node).
function M.ops(ids: { string }, infos: { [string]: any }, records: { any }): { any }
	local ops = {}
	if #records == 0 then
		return ops
	end
	for _, id in ids do
		local l = M.base(id, infos[id])
		for _, rec in records do
			table.insert(l, deep(rec))
		end
		table.insert(ops, { op = "update", id = id, props = { interactions = l } })
	end
	return ops
end

-- Fetch each id's node (source.node), then `done(infos)`.
local function fetch(source: any, ids: { string }, done: (infos: { [string]: any }) -> ())
	local infos: { [string]: any } = {}
	if #ids == 0 or not source.node then
		done(infos)
		return
	end
	local left = #ids
	for _, id in ids do
		source.node(id, function(info: any?)
			infos[id] = info
			left -= 1
			if left == 0 then
				done(infos)
			end
		end)
	end
end

-- The stored records the noodles `{ id, k }` stand for (in that order).
function M.records(source: any, keys: { any }, done: (recs: { any }) -> ())
	local ids, seen = {}, {}
	for _, x in keys do
		if not seen[x.id] then
			seen[x.id] = true
			table.insert(ids, x.id)
		end
	end
	fetch(source, ids, function(infos)
		local out = {}
		for _, x in keys do
			local l = M.base(x.id, infos[x.id])
			local i = Noodles.stored_index(l, x.k)
			if i and l[i] then
				table.insert(out, l[i])
			end
		end
		done(out)
	end)
end

-- Paste: append the clipboard's records to every layer in `ids`, one edit
-- ("Paste interactions", one undo). `o.say(title, body)` hears what was
-- dropped; `o.done(n_layers, dropped)` after.
function M.paste(source: any, ids: { string }, o: { say: ((string, string?) -> ())?, done: ((number, { string }) -> ())?, label: string? }?)
	local opts = o or {}
	local roots = if source.roots then source.roots:peek() else {}
	local known, complete = M.ids_of(roots)
	local recs, dropped = M.keep(M.get(), known, complete, roots)
	if #dropped > 0 and opts.say then
		local n = #dropped
		opts.say(
			if n == 1 then "1 action left out" else `{n} actions left out`,
			(if n == 1 then "Its destination isn't in this Design: " else "Their destinations aren't in this Design: ") .. table.concat(dropped, ", ")
		)
	end
	if #recs == 0 or #ids == 0 then
		if opts.done then
			opts.done(0, dropped)
		end
		return
	end
	fetch(source, ids, function(infos)
		local ops = M.ops(ids, infos, recs)
		if #ops > 0 then
			source.edit(ops, opts.label or "Paste interactions")
		end
		if opts.done then
			opts.done(#ops, dropped)
		end
	end)
end

return M
