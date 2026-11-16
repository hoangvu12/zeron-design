--!strict
-- N8 (pure/anim/n8/README.md): when each piece of an agent's call reveals.
-- Pure (no `ui`), so pure/tests/agent_fx_plan.luau runs it headless.
--
-- One `design_execute` call often makes a whole Screen at once. So it still
-- reads as built piece by piece (as Paper's does), a call's new nodes reveal
-- one after another in reading order:
--   * one new node with 2+ parts (its children, or the children of the one
--     wrapper filling it): a "shell" unit (the node's own cover sweeps away
--     fast, its ring stays while its parts come), then one "part" unit per
--     child, STEP_MAX ms apart (less when there are many, so the whole call
--     is done within CAP ms);
--   * several new nodes: each a whole "new" unit, staggered the same way;
--   * edits, deletes, reads: at once.
-- Every unit has `start` (ms after the entry's `at`) and `life` (ms it lasts
-- from its start); a group (one call's entries) is gone at `P.ends(group)`.

local P = {}

P.MS = { new = 1200, edit = 900, delete = 800, read = 1400 }
P.STEP_MAX = 180 -- between two parts' starts
P.CAP = 2000 -- a call's last part done by then
P.SHELL = 420 -- the shell's cover sweep
P.FIRST = 240 -- the first part starts (the shell's cover half way)
P.PART = 560 -- a part's sweep
P.PART_LIFE = P.PART + 420 -- its outline fading after it
P.MAX_PARTS = 24 -- parts after this start with the last
P.GRACE = 150 -- a unit first on screen this late after its start doesn't play
P.MIN_PX = 8 -- parts smaller than this on screen aren't parts

local function bounds(ix: any, id: string): { number }?
	local n = ix.by[id]
	return if n then n.bounds else nil
end

-- Reading order: rows top to bottom (8-unit bands), then left to right.
function P.reading(ix: any, ids: { string }): { string }
	local out = table.clone(ids)
	table.sort(out, function(a: string, b: string): boolean
		local ba, bb = bounds(ix, a), bounds(ix, b)
		if not ba or not bb then
			return a < b
		end
		local ra, rb = math.floor(ba[2] / 8), math.floor(bb[2] / 8)
		if ra ~= rb then
			return ra < rb
		end
		if ba[1] ~= bb[1] then
			return ba[1] < bb[1]
		end
		return a < b
	end)
	return out
end

-- A node whose own paint is nothing or one opaque solid colour on top: a
-- part's cover (the colour behind it) then matches what shows round it.
local function plain(ix: any, id: string): boolean
	local n = ix.by[id]
	if not n then
		return false
	end
	local fills = n.it and n.it.fill
	if type(fills) ~= "table" or #fills == 0 then
		return true
	end
	local f = fills[#fills]
	if type(f) ~= "table" or f.k ~= "solid" or type(f.color) ~= "string" or (f.op ~= nil and f.op < 1) then
		return false
	end
	local c = f.color
	return #c == 7 or string.lower(string.sub(c, 8, 9)) == "ff"
end

-- The parts of new node `id` (ids, reading order), nil when it isn't a
-- top-level layer (a Screen), has fewer than 2 or its paint isn't plain.
-- (A smaller new node keeps one reveal with its children outlined in turn.)
-- `z` = the view's zoom.
function P.parts(ix: any, id: string, z: number): { string }?
	local top = ix.by[id]
	if not top or (top.parent ~= nil and top.parent ~= "") then
		return nil
	end
	local at = id
	for _ = 1, 4 do
		if not plain(ix, at) then
			return nil
		end
		local b = bounds(ix, at)
		if not b then
			return nil
		end
		local kids = {}
		for _, cid in ix.kids[at] or {} do
			local c = bounds(ix, cid)
			if c and c[3] * z >= P.MIN_PX and c[4] * z >= P.MIN_PX then
				table.insert(kids, cid)
			end
		end
		if #kids >= 2 then
			return P.reading(ix, kids)
		end
		if #kids == 0 then
			return nil
		end
		-- one child: a wrapper filling it (most of it)? look inside
		local c = bounds(ix, kids[1]) :: { number }
		if b[3] * b[4] <= 0 or (c[3] * c[4]) / (b[3] * b[4]) < 0.6 then
			return nil
		end
		at = kids[1]
	end
	return nil
end

-- The gap between two starts for n units each lasting `dur`, all done by CAP.
local function step(n: number, first: number, dur: number): number
	if n <= 1 then
		return 0
	end
	return math.max(0, math.min(P.STEP_MAX, (P.CAP - first - dur) / (n - 1)))
end

-- A group's units. `group` = the entries of one call (same `call`), `ix`
-- the board's index, `z` the zoom. Units: { key, id, kind, at, start, life,
-- box? } with kind "new" | "shell" | "part" | "edit" | "delete" | "read".
-- Order = drawing order (a shell after its parts: its cover is over theirs).
function P.plan(group: { any }, ix: any, z: number): { any }
	local out = {}
	local news: { any } = {}
	for _, e in group do
		if e.kind == "new" and ix.by[e.id] then
			table.insert(news, e)
		else
			table.insert(out, { key = e.key, id = e.id, kind = e.kind, at = e.at or 0, start = 0, life = (P.MS[e.kind] or 1000) + 100, box = e.box })
		end
	end
	if #news == 0 then
		return out
	end
	local by_id: { [string]: any } = {}
	local ids = {}
	for _, e in news do
		by_id[e.id] = e
		table.insert(ids, e.id)
	end
	ids = P.reading(ix, ids)
	local parts = if #ids == 1 then P.parts(ix, ids[1], z) else nil
	if parts then
		local e = by_id[ids[1]]
		local n = math.min(#parts, P.MAX_PARTS)
		local s = step(n, P.FIRST, P.PART)
		local last = 0
		for k, pid in parts do
			local st = P.FIRST + (math.min(k, n) - 1) * s
			last = math.max(last, st)
			table.insert(out, { key = `{e.key}#{k}`, id = pid, kind = "part", at = e.at or 0, start = st, life = P.PART_LIFE, parent = e.key })
		end
		table.insert(out, { key = `{e.key}#0`, id = e.id, kind = "shell", at = e.at or 0, start = 0, life = last + P.PART + 300, parts = #parts })
		return out
	end
	local s = step(#ids, 0, P.MS.new)
	for k, id in ids do
		local e = by_id[id]
		table.insert(out, { key = e.key, id = id, kind = "new", at = e.at or 0, start = (k - 1) * s, life = P.MS.new + 400 })
	end
	return out
end

-- When a planned group is all done (ms, on the `ui.now()` clock).
function P.ends(units: { any }): number
	local t = 0
	for _, u in units do
		t = math.max(t, u.at + u.start + u.life)
	end
	return t
end

-- Whether unit `u` shows at `now`, given whether it is on screen and was
-- mounted before. Returns "show" | "skip" | "dead" (never again: it went
-- off screen after it mounted, or it's over).
function P.state(u: any, now: number, on_screen: boolean, was_mounted: boolean): string
	local t0 = u.at + u.start
	if now > t0 + u.life then
		return "dead"
	end
	if not on_screen then
		return if was_mounted then "dead" else "skip"
	end
	if was_mounted then
		return "show"
	end
	-- first time on screen: only if it hasn't really begun (no replay mid-way)
	if now > t0 + P.GRACE then
		return "skip"
	end
	return "show"
end

return P
