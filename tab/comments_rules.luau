--!nonstrict
-- Local comments' rules (step 7, pure/anim/f7/comments/README.md), pure:
-- one action on a Design's rows (`act`) and rows → pins with their replies
-- (`threads`). Used by the service (engine/comments.luau, over zeron.db) and
-- the harness's fixture source (tab/comments.luau `memory`).

local M = {}

M.MAX_TEXT = 4000
M.MAX_THREADS = 500 -- a Design's pins, at most

local n_ids = 0
local function new_id(now: number): string
	n_ids += 1
	-- (time, then a count: ids made in one second sort in the order made)
	return string.format("c%08x%04x%04x", math.floor(now) % 0x100000000, n_ids % 0x10000, math.random(0, 0xffff))
end
M.new_id = new_id

local function clean_text(t: any): string?
	if type(t) ~= "string" then
		return nil
	end
	t = string.gsub(t, "^%s+", "")
	t = string.gsub(t, "%s+$", "")
	if t == "" then
		return nil
	end
	if #t > M.MAX_TEXT then
		t = string.sub(t, 1, M.MAX_TEXT)
		-- (not inside a UTF-8 sequence)
		while #t > 0 and not utf8.len(t) do
			t = string.sub(t, 1, #t - 1)
		end
	end
	return t
end

local function num(v: any): number?
	return if type(v) == "number" and v == v and math.abs(v) < 1e7 then v else nil
end

-- One action on `rows` (every row of one Design). `who` = { author, chat? }.
-- Returns (changed rows to write, deleted ids, result) or raises
-- "bad_params: …". Rows are changed in place; new ones appended.
--   add     { screen, x, y, node?, nx?, ny?, text }  → { id, n }
--   reply   { id, text }                              → { id }
--   edit    { id, text }   (a comment's own words)
--   resolve { id, note? }  (note: a reply first)
--   reopen  { id }
--   delete  { id }         (a pin: with its replies)
function M.act(rows: { any }, args: any, who: any, now: number): ({ any }, { string }, any)
	local function fail(w: string)
		error("bad_params: " .. w, 0)
	end
	local by = {}
	for _, r in rows do
		by[r.id] = r
	end
	local action = args.action
	local changed, deleted = {}, {}
	if action == "add" then
		local text = clean_text(args.text) or fail("a comment needs some words")
		if type(args.screen) ~= "string" or args.screen == "" then
			fail("a comment needs the Screen it's on")
		end
		local x, y = num(args.x), num(args.y)
		if not x or not y then
			fail("a comment needs x and y (points on its Screen)")
		end
		local count, top = 0, 0
		for _, r in rows do
			if not r.thread then
				count += 1
				top = math.max(top, r.n or 0)
			end
		end
		if count >= M.MAX_THREADS then
			fail(`a Design keeps {M.MAX_THREADS} comments at most: delete resolved ones first`)
		end
		local row = {
			id = new_id(now), did = args.did, n = top + 1, screen = args.screen, x = x, y = y,
			node = if type(args.node) == "string" and args.node ~= "" then args.node else nil,
			nx = num(args.nx), ny = num(args.ny), text = text, author = who.author, chat = who.chat,
			at = now, resolved = 0,
		}
		table.insert(rows, row)
		table.insert(changed, row)
		return changed, deleted, { id = row.id, n = row.n }
	end
	local r = by[args.id]
	if type(args.id) ~= "string" or not r then
		fail(`no comment "{tostring(args.id)}"`)
	end
	local root = if r.thread then by[r.thread] else r
	if action == "reply" then
		local text = clean_text(args.text) or fail("a reply needs some words")
		local row = { id = new_id(now), did = r.did, thread = root.id, text = text, author = who.author, chat = who.chat, at = now, resolved = 0 }
		table.insert(rows, row)
		table.insert(changed, row)
		return changed, deleted, { id = row.id }
	elseif action == "edit" then
		r.text = clean_text(args.text) or fail("a comment needs some words")
		r.edited = now
		table.insert(changed, r)
	elseif action == "resolve" or action == "reopen" then
		if not root then
			fail("its pin is gone")
		end
		if action == "resolve" then
			local note = clean_text(args.note)
			if note then
				local row = { id = new_id(now), did = root.did, thread = root.id, text = note, author = who.author, chat = who.chat, at = now, resolved = 0 }
				table.insert(rows, row)
				table.insert(changed, row)
			end
		end
		root.resolved = if action == "resolve" then now else 0
		table.insert(changed, root)
	elseif action == "delete" then
		local gone = { [r.id] = true }
		if not r.thread then
			for _, x in rows do
				if x.thread == r.id then
					gone[x.id] = true
				end
			end
		end
		for i = #rows, 1, -1 do
			if gone[rows[i].id] then
				table.insert(deleted, rows[i].id)
				table.remove(rows, i)
			end
		end
	else
		fail(`a comment's action is add, reply, edit, resolve, reopen or delete, not "{tostring(action)}"`)
	end
	return changed, deleted, {}
end

-- Rows → pins, each with its replies (oldest first), pins by number.
function M.threads(rows: { any }): { any }
	local pins, by = {}, {}
	for _, r in rows do
		if not r.thread then
			local t = table.clone(r)
			t.replies = {}
			by[r.id] = t
			table.insert(pins, t)
		end
	end
	for _, r in rows do
		local t = r.thread and by[r.thread]
		if t then
			table.insert(t.replies, { id = r.id, text = r.text, author = r.author, chat = r.chat, at = r.at, edited = r.edited })
		end
	end
	table.sort(pins, function(a, b)
		return (a.n or 0) < (b.n or 0)
	end)
	for _, t in pins do
		table.sort(t.replies, function(a, b)
			if a.at ~= b.at then
				return (a.at or 0) < (b.at or 0)
			end
			return a.id < b.id
		end)
		t.did = nil
		t.thread = nil
		t.resolved = (t.resolved or 0) ~= 0
	end
	return pins
end

return M
