--!strict
-- Several layers' interactions as one panel (F6 C2, Figma's multi-select
-- editing) and "Select N matching interactions". Pure: no state, no ui.
--
--   merge(layers) → rows
--     layers: { { id, list = stored interactions } }
--     rows:   { { key, rec, layers = { { id, i } }, all } }, one per trigger key
--     (the trigger with its delay or key; a layer's second "On click" is a
--     second row). `rec` is `{ trigger, actions }` where a value the layers
--     don't share is `MIXED`. `transition` and `offset` are merged key by
--     key; a Conditional's `then` / `else` is MIXED as a whole unless equal.
--     An action only some layers have is merged from those that have it.
--   matching(roots, id, k) → { { id, k } }
--     the layers with the same name path from their Screen (Figma's "same
--     name at the same depth") in every Screen, with an `equal` reaction.
--     It includes the layer itself, so the button shows at 2 or more.
--   equal(e1, e2): two scene reactions (`ia` entries) have the same trigger
--     (and delay/keys), first action kind and destination.
--   scene_k(list, i): a stored interaction's place in the scene's `ia`
--     (the inverse of noodles.luau's stored_index).

local M = {}

M.MIXED = "\0mixed"

local function deq(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not deq(v, b[k]) then
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
M.deq = deq

local function copy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local o = {}
	for k, x in v do
		o[k] = copy(x)
	end
	return o
end

local function is_map(v: any): boolean
	return type(v) == "table" and v[1] == nil
end

function M.trigger_name(t: any): string
	if type(t) == "table" then
		return tostring(t.type or "click")
	end
	return if type(t) == "string" then t else "click"
end

-- The row key: the trigger and what tells two of a kind apart.
function M.trigger_key(t: any): string
	local s = M.trigger_name(t)
	if type(t) == "table" then
		if t.ms ~= nil then
			s ..= ":" .. tostring(t.ms)
		end
		if t.delay ~= nil and t.delay ~= 0 then
			s ..= ":d" .. tostring(t.delay)
		end
		if t.keys ~= nil then
			s ..= ":" .. (if type(t.keys) == "table" then table.concat(t.keys, "+") else tostring(t.keys))
		end
	end
	return s
end

local RECURSE = { transition = true, offset = true }

-- objs: tables (all present). A key's value when all agree, else MIXED.
local function merge_obj(objs: { any }): any
	local out = {}
	local keys: { [any]: boolean } = {}
	for _, o in objs do
		for k in o do
			keys[k] = true
		end
	end
	for k in keys do
		local first = objs[1][k]
		local same = true
		for n = 2, #objs do
			if not deq(first, objs[n][k]) then
				same = false
				break
			end
		end
		if same then
			out[k] = copy(first)
		elseif RECURSE[k] then
			local sub = {}
			for _, o in objs do
				if is_map(o[k]) then
					table.insert(sub, o[k])
				end
			end
			out[k] = if #sub == #objs then merge_obj(sub) else M.MIXED
		else
			out[k] = M.MIXED
		end
	end
	return out
end

function M.merge(layers: { any }): { any }
	local rows: { any } = {}
	local by: { [string]: any } = {}
	for _, ly in layers do
		local seen: { [string]: number } = {}
		for i, r in (if type(ly.list) == "table" then ly.list else {}) do
			if type(r) ~= "table" then
				continue
			end
			local tk = M.trigger_key(r.trigger)
			local n = (seen[tk] or 0) + 1
			seen[tk] = n
			local key = if n == 1 then tk else `{tk}#{n}`
			local row = by[key]
			if not row then
				row = { key = key, layers = {}, recs = {} }
				by[key] = row
				table.insert(rows, row)
			end
			table.insert(row.layers, { id = ly.id, i = i })
			table.insert(row.recs, r)
		end
	end
	for _, row in rows do
		local recs = row.recs
		local acts: { any } = {}
		local most = 0
		for _, r in recs do
			if type(r.actions) == "table" then
				most = math.max(most, #r.actions)
			end
		end
		for j = 1, most do
			local present = {}
			for _, r in recs do
				local a = type(r.actions) == "table" and r.actions[j]
				if type(a) == "table" then
					table.insert(present, a)
				end
			end
			acts[j] = if #present > 0 then merge_obj(present) else { action = "navigate" }
		end
		row.rec = { trigger = copy(recs[1].trigger), actions = acts }
		row.all = #row.layers == #layers
		row.recs = nil
	end
	return rows
end

-- A value is MIXED (anywhere inside, for a table).
function M.has_mixed(v: any): boolean
	if v == M.MIXED then
		return true
	end
	if type(v) == "table" then
		for _, x in v do
			if M.has_mixed(x) then
				return true
			end
		end
	end
	return false
end

function M.scene_k(list: any, i: number): number?
	if type(list) ~= "table" or type(list[i]) ~= "table" then
		return nil
	end
	local r = list[i]
	if type(r.actions) ~= "table" or #r.actions == 0 then
		return nil
	end
	local n = 0
	for j = 1, i do
		local x = list[j]
		if type(x) == "table" and type(x.actions) == "table" and #x.actions > 0 then
			n += 1
		end
	end
	return n
end

function M.equal(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	if a.on ~= b.on or a.ms ~= b.ms or not deq(a.keys, b.keys) then
		return false
	end
	local x = a.acts and a.acts[1]
	local y = b.acts and b.acts[1]
	if (x == nil) ~= (y == nil) then
		return false
	end
	if x then
		for _, k in { "k", "go", "to", "url", "var", "axis", "value", "cond" } do
			if not deq(x[k], y[k]) then
				return false
			end
		end
	end
	return true
end

local function is_screen(r: any): boolean
	local it = r.nodes and r.nodes[1]
	return it ~= nil and it.t == "frame" and not it.comp
end

local function name_of(it: any): string
	return if type(it.name) == "string" then it.name else `<{tostring(it.t)}>`
end

-- The names from the Screen's child down to nodes[at] (nil for the Screen).
local function path_at(nodes: { any }, at: number): { string }?
	if at <= 1 then
		return nil
	end
	local chain = { name_of(nodes[at]) }
	for j = at - 1, 2, -1 do
		if j + (nodes[j].n or 0) >= at then
			table.insert(chain, 1, name_of(nodes[j]))
		end
	end
	return chain
end

local function same_path(a: { string }, b: { string }): boolean
	if #a ~= #b then
		return false
	end
	for n = 1, #a do
		if a[n] ~= b[n] then
			return false
		end
	end
	return true
end

function M.matching(roots: { any }, id: string, k: number): { any }
	local mine, path, found = nil, nil, false
	for _, r in roots do
		for at, it in r.nodes or {} do
			if it.id == id then
				mine = it.ia and it.ia[k]
				path = path_at(r.nodes, at)
				found = true
				break
			end
		end
		if found then
			break
		end
	end
	if not mine then
		return {}
	end
	if not path then
		return { { id = id, k = k } }
	end
	local out = {}
	for _, r in roots do
		if not is_screen(r) then
			continue
		end
		local nodes = r.nodes
		for at, it in nodes do
			if it.ia == nil or at <= 1 or name_of(it) ~= path[#path] then
				continue
			end
			local p = path_at(nodes, at)
			if not p or not same_path(p, path) then
				continue
			end
			if it.id == id then
				table.insert(out, { id = id, k = k })
				continue
			end
			for kk, e in it.ia do
				if M.equal(e, mine) then
					table.insert(out, { id = it.id, k = kk })
					break
				end
			end
		end
	end
	return out
end

return M
