--!nonstrict
-- Local comments (step 7, pure/anim/f7/comments/README.md): pins dropped on a
-- Screen in Play, kept in zeron.db on this device, for the person and their
-- agents. One row per comment; a reply is a row whose `thread` is the pin's
-- id. A pin's place is in its Screen's points (x, y from the Screen's
-- top-left), plus the layer under it (`node`) and where on that layer
-- (`nx`, `ny`), so the pin follows the layer when it moves.
--
-- The rules (`act`, `threads`) are pure, in tab/comments_rules.luau (the
-- harness's fixture source uses them too); here, zeron.db and agents' view.

local R = require("../tab/comments_rules")

local M = {}

M.MAX_TEXT = R.MAX_TEXT
M.MAX_THREADS = R.MAX_THREADS
M.act = R.act
M.threads = R.threads
M.new_id = R.new_id

local zeron: any = nil

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS comments (id TEXT PRIMARY KEY, did TEXT, n INTEGER, screen TEXT, x REAL, y REAL, node TEXT, nx REAL, ny REAL, text TEXT, author TEXT, chat TEXT, at INTEGER, resolved INTEGER, thread TEXT, edited INTEGER);
CREATE INDEX IF NOT EXISTS comments_did ON comments (did);
]]

local ready = false
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

function M.init(z: any)
	zeron = z
end

local COLS = { "id", "did", "n", "screen", "x", "y", "node", "nx", "ny", "text", "author", "chat", "at", "resolved", "thread", "edited" }

-- ── zeron.db ─────────────────────────────────────────────────────────────

function M.rows(did: string): { any }
	local out = query("SELECT * FROM comments WHERE did = ?", { did })
	for _, r in out do
		-- (nothing is written as "": every column read back as nil)
		for k, v in table.clone(r) do
			if v == "" or type(v) == "userdata" then
				r[k] = nil
			end
		end
	end
	return out
end

function M.list(did: string): { any }
	return M.threads(M.rows(did))
end

local function write(row: any)
	local vals = {}
	for i, c in COLS do
		local v = row[c]
		vals[i] = if v == nil then "" else v
	end
	exec(`INSERT OR REPLACE INTO comments ({table.concat(COLS, ", ")}) VALUES ({string.rep("?, ", #COLS - 1)}?)`, vals)
end

-- One action, written. Returns its result.
function M.run(did: string, args: any, who: any): any
	local rows = M.rows(did)
	local a = table.clone(args)
	a.did = did
	local changed, deleted, result = M.act(rows, a, who, os.time())
	for _, row in changed do
		write(row)
	end
	for _, id in deleted do
		exec("DELETE FROM comments WHERE id = ?", { id })
	end
	return result
end

function M.forget(did: string)
	exec("DELETE FROM comments WHERE did = ?", { did })
end

-- What agents see (design_state, GetComments): the pins, open ones only
-- unless `all`, with their Screen's and layer's names.
function M.for_agents(list: { any }, doc: any, all: boolean?): { any }
	local names = {}
	for _, n in (doc and doc.children or {}) do
		if type(n) == "table" and n.id then
			names[n.id] = n.name
		end
	end
	local out = {}
	for _, t in list do
		if all or not t.resolved then
			local replies = {}
			for _, r in t.replies do
				table.insert(replies, { text = r.text, author = r.author })
			end
			table.insert(out, {
				id = t.id, n = t.n, screen = t.screen, screenName = names[t.screen] or "(a Screen no longer in the Design)",
				node = t.node, x = math.floor(t.x + 0.5), y = math.floor(t.y + 0.5), text = t.text, author = t.author,
				resolved = t.resolved or nil, replies = if #replies > 0 then replies else nil,
			})
		end
	end
	return out
end

return M
