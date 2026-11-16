--!nonstrict
-- Designs kept in zeron.db (pure/CONTRACT.md §2–3): each Design's whole
-- `.zdesign` JSON, its version and per-root versions, and its undo steps.
-- Steps keep what a change replaced at top-level granularity, as native
-- crates/design/src/history.rs. Everything is written as it commits, since
-- the service may stop whenever it's idle.

local U = require("./util")

local M = {}

local MAX_STEPS = 100
M.STEPS_BYTES = 12 * 1024 * 1024
M.HOLD = 4

local zeron: any = nil
local json: any = nil
local live: { [string]: any } = {}

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS designs (did TEXT PRIMARY KEY, name TEXT, doc TEXT, meta TEXT, version INTEGER, created INTEGER, updated INTEGER, opened INTEGER, source TEXT);
CREATE TABLE IF NOT EXISTS steps (did TEXT, seq INTEGER, label TEXT, by TEXT, chat TEXT, at INTEGER, undo TEXT, redo TEXT, done INTEGER, PRIMARY KEY (did, seq));
CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS hist (did TEXT, seq INTEGER, roots TEXT, thumbs TEXT, PRIMARY KEY (did, seq));
]]
-- (N3 history) `hist`: per step, the roots it holds (`roots`, a JSON list)
-- and small before/after pictures of them (`thumbs`, engine/history.luau).

local ready = false
-- The schema, made on first use: inside a call or tool, where awaiting
-- works (a service's top level isn't a task).
local function schema()
	if not ready then
		ready = true
		zeron.db.exec(SCHEMA):await()
	end
end
local function exec(sql: string, params: any?): any
	schema()
	return zeron.db.exec(sql, params):await()
end
local function query(sql: string, params: any?): { any }
	schema()
	return zeron.db.query(sql, params):await()
end

-- (history, engine/history.luau) the same database, schema made first
M.sql = { exec = exec, query = query }

function M.init(z: any)
	zeron = z
	json = z.json
end

function M.now(): number
	return os.time()
end

-- ── a Design held in memory ──────────────────────────────────────────────

-- Drops empty `children` (zeron.json writes an empty table as `{}`, which
-- isn't a list) all the way down.
local function tidy(n: any)
	local kids = n.children
	if kids ~= nil then
		if type(kids) ~= "table" or next(kids) == nil then
			n.children = nil
		else
			for _, c in kids do
				if type(c) == "table" then
					tidy(c)
				end
			end
		end
	end
end
M.tidy = tidy

-- The parts of a doc a step compares: each root's JSON, the order, the rest.
local function parts(d: any): any
	local roots, order = {}, {}
	for _, n in U.list(d.doc.children) do
		local id = n.id
		table.insert(order, id)
		tidy(n)
		local cached = json.encode(n)
		d.json[id] = cached
		roots[id] = cached
	end
	local rest = {}
	for k, v in d.doc do
		if k ~= "children" and k ~= "variations" then
			rest[k] = v
		end
	end
	-- (N2) Variations' stored versions: a part of their own, so a change to
	-- them redraws only the roots that changed ("" = none)
	local vars = if type(d.doc.variations) == "table" and next(d.doc.variations) ~= nil then json.encode(d.doc.variations) else ""
	return { roots = roots, order = order, rest = json.encode(rest), vars = vars }
end

local function hold(row: any): any
	local doc = json.decode(row.doc)
	if type(doc) ~= "table" then
		doc = { version = "1.0", children = {} }
	end
	doc.children = U.list(doc.children)
	local meta = if row.meta then json.decode(row.meta) else {}
	local d = {
		did = row.did,
		name = row.name,
		doc = doc,
		version = row.version or 0,
		rootv = meta.rootv or {},
		json = {},
		source = row.source,
		view_theme = {},
	}
	d.before = parts(d)
	-- Hold a few at once (memory: a 5k-node Design is ~10 MB held); the
	-- rest stay in the database, all committed.
	local n, oldest, oldest_at = 0, nil, math.huge
	for did, x in live do
		n += 1
		if x.used < oldest_at then
			oldest, oldest_at = did, x.used
		end
	end
	if n >= M.HOLD and oldest then
		live[oldest] = nil
	end
	d.used = os.clock()
	live[row.did] = d
	return d
end

function M.get(did: string): any
	local d = live[did]
	if d then
		d.used = os.clock()
		return d
	end
	local rows = query("SELECT did, name, doc, meta, version, source FROM designs WHERE did = ?", { did })
	if not rows[1] then
		error("not_found: no Design " .. tostring(did), 0)
	end
	return hold(rows[1])
end

function M.exists(did: string): boolean
	if live[did] then
		return true
	end
	return query("SELECT did FROM designs WHERE did = ?", { did })[1] ~= nil
end

function M.list(): { any }
	local rows = query("SELECT did, name, version, created, updated, opened, source FROM designs ORDER BY MAX(COALESCE(opened, 0), COALESCE(updated, 0)) DESC")
	return rows
end

local function new_did(): string
	local taken = {}
	for _, r in query("SELECT did FROM designs") do
		taken[r.did] = true
	end
	local id
	repeat
		id = "d" .. U.new_id({}) .. U.new_id({})
		id = string.sub(id, 1, 11)
	until not taken[id]
	return id
end

function M.find_by_name(name: string): any
	local rows = query("SELECT did FROM designs WHERE name = ? ORDER BY updated DESC", { name })
	return rows[1] and rows[1].did
end

function M.create(name: string?, doc: any?, source: string?): any
	local did = new_did()
	doc = doc or { version = "1.0", children = {} }
	doc.children = U.list(doc.children)
	local t = M.now()
	local nm = name or "Untitled design"
	exec("INSERT INTO designs (did, name, doc, meta, version, created, updated, opened, source) VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?)", { did, nm, json.encode(doc), "{}", t, t, t, source or "" })
	return M.get(did)
end

function M.rename(did: string, name: string)
	local d = M.get(did)
	d.name = name
	exec("UPDATE designs SET name = ?, updated = ? WHERE did = ?", { name, M.now(), did })
end

function M.delete(did: string)
	exec("DELETE FROM designs WHERE did = ?", { did })
	exec("DELETE FROM steps WHERE did = ?", { did })
	exec("DELETE FROM hist WHERE did = ?", { did })
	live[did] = nil
end

function M.touch(did: string)
	exec("UPDATE designs SET opened = ? WHERE did = ?", { M.now(), did })
end

-- Runs `f` (which awaits the db) with the Design's step writes to itself:
-- two calls committing at once would otherwise both take the same seq.
local function locked(d: any, f: () -> ())
	while d.writing do
		zeron.sleep(0.005):await()
	end
	d.writing = true
	if M.while_writing then
		-- tests: what another call does while this one waits on the db
		M.while_writing(d)
	end
	local ok, e = pcall(f)
	d.writing = nil
	if not ok then
		error(e, 0)
	end
end

local function save(d: any)
	exec("UPDATE designs SET doc = ?, meta = ?, version = ?, updated = ? WHERE did = ?", { json.encode(d.doc), json.encode({ rootv = d.rootv }), d.version, M.now(), d.did })
end

-- The roots that draw differently once `changed` roots changed: those, and
-- every root with an Instance of a Component in one of them (and so on);
-- all of them when Tokens or Themes changed.
function M.affected(d: any, changed: { string }, rest: boolean): { string }
	local out = {}
	if rest then
		for _, n in d.doc.children do
			table.insert(out, n.id)
		end
		return out
	end
	local set = {}
	local comps = {}
	local function mark(root)
		if set[root.id] then
			return
		end
		set[root.id] = true
		table.insert(out, root.id)
		local function walk(n)
			if n.type == "frame" and n.reusable == true then
				comps[n.id] = true
			end
			for _, c in U.list(n.children) do
				walk(c)
			end
		end
		walk(root)
	end
	local by_id = {}
	for _, n in d.doc.children do
		by_id[n.id] = n
	end
	for _, id in changed do
		if by_id[id] then
			mark(by_id[id])
		elseif not set[id] then
			set[id] = true
			table.insert(out, id)
		end
	end
	local grew = true
	while grew and next(comps) ~= nil do
		grew = false
		for _, root in d.doc.children do
			if not set[root.id] then
				local uses = false
				local function walk(n)
					if uses then
						return
					end
					if n.type == "instance" and comps[n.ref] then
						uses = true
						return
					end
					for _, c in U.list(n.children) do
						walk(c)
					end
				end
				walk(root)
				if uses then
					mark(root)
					grew = true
				end
			end
		end
	end
	return out
end

-- ── steps ────────────────────────────────────────────────────────────────

-- Same data, whatever order the keys came in.
local function same(x: any, y: any): boolean
	if x == y then
		return true
	end
	if type(x) ~= "table" or type(y) ~= "table" then
		return false
	end
	for k, v in x do
		if not same(v, y[k]) then
			return false
		end
	end
	for k in y do
		if x[k] == nil then
			return false
		end
	end
	return true
end

-- Two JSON texts of one part: equal as data. zeron.json writes a table's
-- keys in the order the table holds them, and that order moves when a node
-- gains and loses a key, so the same root can come out as different text.
-- Compared as text, every call (a screenshot alone) saved every root as
-- changed: a 2.6k-layer Design's undo steps filled the 100 MB database in
-- 99 calls, and every root was sent to the tab again after each.
local function same_json(x: string?, y: string?): boolean
	if x == y then
		return true
	end
	if x == nil or y == nil then
		return false
	end
	return same(json.decode(x), json.decode(y))
end
M.same_json = same_json

-- What changed from `a` to `b` (parts): the step that puts `a` back.
local function between(a: any, b: any): (any?, { string })
	local nodes, changed = {}, {}
	local any = false
	local differs = {}
	for id, j in a.roots do
		if not same_json(b.roots[id], j) then
			differs[id] = true
			nodes[id] = j
			any = true
		end
	end
	for id in b.roots do
		if a.roots[id] == nil then
			nodes[id] = false
			any = true
		end
	end
	for id in b.roots do
		if a.roots[id] == nil or differs[id] then
			table.insert(changed, id)
		end
	end
	local same_order = #a.order == #b.order
	if same_order then
		for i, id in a.order do
			if b.order[i] ~= id then
				same_order = false
				break
			end
		end
	end
	local rest = if not same_json(a.rest, b.rest) then a.rest else nil
	local av, bv = a.vars or "", b.vars or ""
	local vars = nil
	if av ~= bv and (av == "" or bv == "" or not same_json(av, bv)) then
		vars = av
	end
	if not any and same_order and rest == nil and vars == nil then
		return nil, changed
	end
	return { order = a.order, nodes = nodes, rest = rest, vars = vars }, changed
end

-- Puts a step's state onto `d`; the roots it set.
local function apply(d: any, step: any): { string }
	local by_id = {}
	for _, n in d.doc.children do
		by_id[n.id] = n
	end
	local set = {}
	for id, j in step.nodes do
		if j == false then
			by_id[id] = nil
		else
			by_id[id] = json.decode(j)
			d.json[id] = j
		end
		table.insert(set, id)
	end
	local children = {}
	for _, id in step.order do
		if by_id[id] then
			table.insert(children, by_id[id])
		end
	end
	local doc = { children = children }
	if step.rest then
		for k, v in json.decode(step.rest) do
			if k ~= "variations" then
				doc[k] = v
			end
		end
	else
		for k, v in d.doc do
			if k ~= "children" and k ~= "variations" then
				doc[k] = v
			end
		end
	end
	-- (N2) the step's Variations when it holds them, else the ones now
	if step.vars ~= nil then
		doc.variations = if step.vars == "" then nil else json.decode(step.vars)
	else
		doc.variations = d.doc.variations
	end
	d.doc = doc
	return set
end

-- Notes the change made to `d.doc` since its last commit as one step.
-- Returns { version, roots = {id → v}, removed, order? } or nil when
-- nothing changed. `join`: merge into the latest step when its label is
-- the same (a run of keystrokes).
-- `quiet` (N2, flipping through Variations): saved and sent like any change,
-- but no undo step (the step that made the set holds it; History shows one
-- row).
function M.commit(d: any, label: string, by: string, chat: string?, join: boolean?, quiet: boolean?): any?
	d.dirty_all = true
	local after = parts(d)
	d.dirty_all = nil
	local undo, changed = between(d.before, after)
	if not undo then
		return nil
	end
	local redo = between(after, d.before)
	d.version += 1
	local removed = {}
	for id in d.before.roots do
		if after.roots[id] == nil then
			table.insert(removed, id)
			d.rootv[id] = nil
		end
	end
	local roots = {}
	for _, id in M.affected(d, changed, undo.rest ~= nil) do
		d.rootv[id] = d.version
		roots[id] = d.version
	end
	-- The held state is the new one before anything awaits: another call
	-- runs while this one waits on the db, and a failing one rolls back to
	-- d.before (which must already hold this commit, or its nodes vanish).
	local old_parts = d.before
	d.before = after
	local step_seq, touched = nil, nil
	-- (history) the roots a step holds, with their names (a deleted one's
	-- from its JSON before the change)
	local function named(ids: { string }): string
		local by = {}
		for _, n in d.doc.children do
			by[n.id] = n.name
		end
		local out = {}
		for _, id in ids do
			local nm = by[id]
			if nm == nil and old_parts.roots[id] then
				local ok, n = pcall(json.decode, old_parts.roots[id])
				if ok and type(n) == "table" then
					nm = n.name
				end
			end
			table.insert(out, { id = id, name = nm })
		end
		return json.encode(out)
	end
	locked(d, function()
	if quiet then
		save(d)
		return
	end
	exec("DELETE FROM steps WHERE did = ? AND done = 0", { d.did })
	local latest = query("SELECT seq, label, undo FROM steps WHERE did = ? AND done = 1 ORDER BY seq DESC LIMIT 1", { d.did })[1]
	-- (history) the redo branch just dropped: its rows go too (a seq is
	-- taken again by the step made now)
	exec("DELETE FROM hist WHERE did = ? AND seq > ?", { d.did, if latest then latest.seq else 0 })
	if join and latest and latest.label == label then
		local old = json.decode(latest.undo)
		for id, j in undo.nodes do
			if old.nodes[id] == nil then
				old.nodes[id] = j
			end
		end
		old.rest = old.rest or undo.rest
		if old.vars == nil then
			old.vars = undo.vars
		end
		-- redo puts back the state now, for every root the merged step holds
		redo = { order = after.order, nodes = {}, rest = if old.rest then after.rest else nil, vars = if old.vars ~= nil then after.vars else nil }
		for id in old.nodes do
			redo.nodes[id] = after.roots[id] or false
		end
		exec("UPDATE steps SET undo = ?, redo = ?, at = ? WHERE did = ? AND seq = ?", { json.encode(old), json.encode(redo), M.now(), d.did, latest.seq })
		step_seq = latest.seq
		touched = M.step_roots(old)
		exec("INSERT INTO hist (did, seq, roots) VALUES (?, ?, ?) ON CONFLICT(did, seq) DO UPDATE SET roots = excluded.roots", { d.did, step_seq, named(touched) })
	else
		local seq = if latest then latest.seq + 1 else 1
		exec("INSERT INTO steps (did, seq, label, by, chat, at, undo, redo, done) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)", { d.did, seq, label, by, chat or "", M.now(), json.encode(undo), json.encode(redo) })
		step_seq = seq
		touched = M.step_roots(undo)
		exec("INSERT OR REPLACE INTO hist (did, seq, roots) VALUES (?, ?, ?)", { d.did, seq, named(touched) })
		exec("DELETE FROM steps WHERE did = ? AND seq <= ?", { d.did, seq - MAX_STEPS })
		exec("DELETE FROM hist WHERE did = ? AND seq <= ?", { d.did, seq - MAX_STEPS })
		-- And by size: every Design shares the plugin's one 100 MB database,
		-- so a big Design's history keeps its newest STEPS_BYTES (the step
		-- just made always stays).
		exec([[DELETE FROM steps WHERE did = ? AND seq < ? AND seq IN (
			SELECT seq FROM (SELECT seq, SUM(length(undo) + length(redo)) OVER (ORDER BY seq DESC) AS run FROM steps WHERE did = ?) WHERE run > ?)]],
			{ d.did, seq, d.did, M.STEPS_BYTES })
	end
	save(d)
	end)
	local order_changed = #after.order ~= #undo.order
	if not order_changed then
		for i, id in after.order do
			if undo.order[i] ~= id then
				order_changed = true
				break
			end
		end
	end
	return { version = d.version, roots = roots, removed = if #removed > 0 then removed else nil, order = if order_changed then after.order else nil, seq = step_seq, touched = touched }
end

-- (history) The roots a step's undo holds, in the Design's order (those
-- gone after it last): what that step changed, made or deleted.
function M.step_roots(step: any): { string }
	local out, seen = {}, {}
	for _, id in U.list(step.order) do
		if step.nodes[id] ~= nil and not seen[id] then
			seen[id] = true
			table.insert(out, id)
		end
	end
	for id in step.nodes do
		if not seen[id] then
			seen[id] = true
			table.insert(out, id)
		end
	end
	return out
end


-- Forgets uncommitted changes (a failed call): back to the last commit.
function M.rollback(d: any)
	local doc = { children = {} }
	for k, v in json.decode(d.before.rest) do
		doc[k] = v
	end
	for _, id in d.before.order do
		table.insert(doc.children, json.decode(d.before.roots[id]))
	end
	if (d.before.vars or "") ~= "" then
		doc.variations = json.decode(d.before.vars)
	end
	d.doc = doc
end

local function step_back_locked(d: any, undoing: boolean): any?
	local row
	if undoing then
		row = query("SELECT seq, label, undo, redo FROM steps WHERE did = ? AND done = 1 ORDER BY seq DESC LIMIT 1", { d.did })[1]
	else
		row = query("SELECT seq, label, undo, redo FROM steps WHERE did = ? AND done = 0 ORDER BY seq ASC LIMIT 1", { d.did })[1]
	end
	if not row then
		return nil
	end
	local step = json.decode(if undoing then row.undo else row.redo)
	local set = apply(d, step)
	d.version += 1
	local after = parts(d)
	d.before = after
	exec("UPDATE steps SET done = ? WHERE did = ? AND seq = ?", { if undoing then 0 else 1, d.did, row.seq })
	local roots, removed = {}, {}
	for _, id in M.affected(d, set, step.rest ~= nil) do
		if after.roots[id] then
			d.rootv[id] = d.version
			roots[id] = d.version
		else
			d.rootv[id] = nil
			table.insert(removed, id)
		end
	end
	save(d)
	return { version = d.version, label = row.label, roots = roots, removed = if #removed > 0 then removed else nil, order = after.order }
end


local function step_back(d: any, undoing: boolean): any?
	local out
	locked(d, function()
		out = step_back_locked(d, undoing)
	end)
	return out
end
function M.undo(d: any): any?
	return step_back(d, true)
end

function M.redo(d: any): any?
	return step_back(d, false)
end

function M.can(d: any): (boolean, boolean)
	local u = query("SELECT 1 AS x FROM steps WHERE did = ? AND done = 1 LIMIT 1", { d.did })[1] ~= nil
	local r = query("SELECT 1 AS x FROM steps WHERE did = ? AND done = 0 LIMIT 1", { d.did })[1] ~= nil
	return u, r
end

-- ── key/value (selection, tabs, globals) ────────────────────────────────

function M.kv_get(k: string): any
	local r = query("SELECT v FROM kv WHERE k = ?", { k })[1]
	return if r then json.decode(r.v) else nil
end

function M.kv_set(k: string, v: any)
	if v == nil then
		exec("DELETE FROM kv WHERE k = ?", { k })
	else
		exec("INSERT OR REPLACE INTO kv (k, v) VALUES (?, ?)", { k, json.encode(v) })
	end
end

function M.forget_all()
	table.clear(live)
end

return M
