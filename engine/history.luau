--!nonstrict
-- (N3) The History of a Design's changes (pure/anim/n3/README.md): its undo
-- steps (engine/designs.luau `steps`) newest first, each with who made it,
-- when, the Screens it touched, and small before/after pictures of them that
-- the tab draws once and sends here (`hist.thumbs`). Undo to here = undo
-- every step after one.

local Designs = require("./designs")

local M = {}

M.LIST_MAX = 100 -- rows a list gives (steps keep 100 at most anyway)
M.THUMBS_KEEP = 24 -- the newest steps with pictures; older ones drop theirs
M.THUMB_MAX = 120000 -- one picture's base64, at most
M.ROOTS_MAX = 3 -- pictures for this many Screens of a step

local json: any = nil

function M.init(z: any)
	json = z.json
end

local function q(sql: string, p: any?): { any }
	return Designs.sql.query(sql, p)
end
local function x(sql: string, p: any?)
	Designs.sql.exec(sql, p)
end

-- A step's roots as stored: `{ { id, name? } }` (a list of ids before names
-- were kept).
local function roots_of(text: string?): { any }
	if type(text) ~= "string" then
		return {}
	end
	local ok, l = pcall(json.decode, text)
	if not ok or type(l) ~= "table" then
		return {}
	end
	local out = {}
	for _, r in l do
		if type(r) == "string" then
			table.insert(out, { id = r })
		elseif type(r) == "table" and type(r.id) == "string" then
			table.insert(out, { id = r.id, name = r.name })
		end
	end
	return out
end

-- The newest step still done (what Undo undoes next), or 0.
function M.latest(did: string): number
	local r = q("SELECT seq FROM steps WHERE did = ? AND done = 1 ORDER BY seq DESC LIMIT 1", { did })[1]
	return if r then r.seq else 0
end

-- The Design's steps, newest first: { seq, label, by, chat, at, done,
-- screens = { { id, name, gone? } }, thumbs = n pictures kept }, and
-- `latest` (the newest done step's seq).
function M.list(d: any): any
	local did = d.did
	-- (rows of steps trimmed by size, or older tables: gone with them)
	x("DELETE FROM hist WHERE did = ? AND seq NOT IN (SELECT seq FROM steps WHERE did = ?)", { did, did })
	local rows = q([[SELECT s.seq, s.label, s.by, s.chat, s.at, s.done, h.roots, h.thumbs IS NOT NULL AS th, h.did AS has
		FROM steps s LEFT JOIN hist h ON h.did = s.did AND h.seq = s.seq
		WHERE s.did = ? ORDER BY s.seq DESC LIMIT ?]], { did, M.LIST_MAX })
	local by = {}
	for _, n in d.doc.children do
		by[n.id] = n.name or n.id
	end
	local out = {}
	for _, r in rows do
		local roots
		if r.has == nil then
			-- A step made before History: its roots from its undo, once.
			local u = q("SELECT undo FROM steps WHERE did = ? AND seq = ?", { did, r.seq })[1]
			local ok, step = pcall(json.decode, u and u.undo or "")
			local ids = if ok and type(step) == "table" and type(step.nodes) == "table" then Designs.step_roots(step) else {}
			roots = {}
			for _, id in ids do
				table.insert(roots, { id = id })
			end
			x("INSERT OR IGNORE INTO hist (did, seq, roots) VALUES (?, ?, ?)", { did, r.seq, json.encode(roots) })
		else
			roots = roots_of(r.roots)
		end
		local screens = {}
		for _, s in roots do
			local now = by[s.id]
			table.insert(screens, { id = s.id, name = now or s.name or "Deleted layer", gone = if now == nil then true else nil })
		end
		table.insert(out, {
			seq = r.seq, label = r.label, by = r.by, chat = if r.chat ~= "" then r.chat else nil,
			at = r.at, done = r.done == 1, screens = screens, thumbs = r.th == 1 or r.th == true,
		})
	end
	return { steps = out, latest = M.latest(did) }
end

-- One step's pictures: { [root id] = { b = base64?, a = base64? } }.
function M.thumbs(did: string, seq: number): any
	local r = q("SELECT thumbs FROM hist WHERE did = ? AND seq = ?", { did, seq })[1]
	if not r or type(r.thumbs) ~= "string" then
		return {}
	end
	local ok, t = pcall(json.decode, r.thumbs)
	return if ok and type(t) == "table" then t else {}
end

-- Keeps the tab's pictures of `root` before (`b`) and after (`a`) step
-- `seq`. Only for a root the step holds, the first ROOTS_MAX of them, each
-- under THUMB_MAX; a picture already there stays. Then only the newest
-- THUMBS_KEEP steps keep pictures. Whether it kept any.
function M.put_thumb(did: string, seq: number, root: string, b: string?, a: string?): boolean
	local row = q("SELECT roots, thumbs FROM hist WHERE did = ? AND seq = ?", { did, seq })[1]
	if not row then
		return false
	end
	local allowed = false
	for i, s in roots_of(row.roots) do
		if i > M.ROOTS_MAX then
			break
		end
		if s.id == root then
			allowed = true
		end
	end
	if not allowed then
		return false
	end
	local function fine(p: any): string?
		return if type(p) == "string" and #p > 0 and #p <= M.THUMB_MAX then p else nil
	end
	local t = {}
	if type(row.thumbs) == "string" then
		local ok, got = pcall(json.decode, row.thumbs)
		if ok and type(got) == "table" then
			t = got
		end
	end
	local e = t[root] or {}
	local nb, na = e.b or fine(b), e.a or fine(a)
	if nb == e.b and na == e.a then
		return false
	end
	t[root] = { b = nb, a = na }
	x("UPDATE hist SET thumbs = ? WHERE did = ? AND seq = ?", { json.encode(t), did, seq })
	x([[UPDATE hist SET thumbs = NULL WHERE did = ? AND thumbs IS NOT NULL AND seq NOT IN (
		SELECT seq FROM hist WHERE did = ? AND thumbs IS NOT NULL ORDER BY seq DESC LIMIT ?)]], { did, did, M.THUMBS_KEEP })
	return true
end

-- Undoes every done step after `seq` (and `seq` itself unless `keep`), one
-- by one, newest first; `expect`: the newest done step the person saw (when
-- another landed since, nothing is undone). Each undo's change, in order.
function M.undo_to(d: any, seq: number, keep: boolean, expect: number?): ({ any }?, string?)
	local latest = M.latest(d.did)
	if expect ~= nil and expect ~= latest then
		return nil, "the Design changed since: look again"
	end
	local stop = if keep then seq else seq - 1
	if latest <= stop then
		return nil, "nothing to undo"
	end
	if not keep and q("SELECT 1 AS y FROM steps WHERE did = ? AND seq = ? AND done = 1", { d.did, seq })[1] == nil then
		return nil, "that change isn't there to undo"
	end
	local out = {}
	for _ = 1, M.LIST_MAX do
		if M.latest(d.did) <= stop then
			break
		end
		local c = Designs.undo(d)
		if not c then
			break
		end
		table.insert(out, c)
	end
	return out, nil
end

return M
