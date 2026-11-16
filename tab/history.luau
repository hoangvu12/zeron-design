--!strict
-- (N3) The History tab's data (pure/anim/n3/README.md): the Design's undo
-- steps newest first, and small before/after pictures of the Screens an
-- agent's call touched. The pictures are drawn here once, as the call lands:
-- "before" from the root the tab still holds when `changed` comes, "after"
-- once the new root is in; each goes to the source (`put_thumb`) and is read
-- back, decoded, only for rows shown.
--
--   local h = History.new({ roots, list, thumbs, put_thumb, undo_to, key })
--   h.changed(e)  -- every `changed` event ({ by, seq, touched, roots, removed })
--   h.open()      -- the tab shown: load the rows, keep them fresh from now on
--
-- The source is the service (tab/service_source.luau) or a fixture's
-- stand-in (tab/fixture_source.luau); both give the same `api`.

local Draw = require("./draw")

local M = {}

M.THUMB_PX = 240 -- a picture's longest side, in pixels
M.ROOTS_MAX = 3 -- pictures for this many Screens of one call
M.CACHE_ROWS = 30 -- rows whose decoded pictures stay
M.WAIT_TRIES = 40 -- "after" waits up to this many × 100 ms for the new root

-- A root drawn small: `done(base64 PNG or nil)`.
function M.render(root: any, done: (b64: string?) -> ())
	local first = root and root.nodes and root.nodes[1]
	local b = first and first.box
	if not b or (b.w or 0) <= 0 or (b.h or 0) <= 0 then
		done(nil)
		return
	end
	local scale = math.min(1, M.THUMB_PX / math.max(b.w, b.h, 1))
	Draw.ensure(Draw.picture_keys(root.nodes), function()
		local ok, p = pcall(ui.render_canvas, function(c: Canvas)
			Draw.draw_root(c, root)
		end, { width = b.w, height = b.h, scale = scale, x = b.x, y = b.y })
		if not ok then
			done(nil)
			return
		end
		p:after(function(png: string)
			done(png)
		end, function()
			done(nil)
		end)
	end)
end

local function find(list: { any }, id: string): any?
	for _, r in list do
		if r.id == id then
			return r
		end
	end
	return nil
end

function M.new(api: any): any
	local h: any = {}
	local key = api.key or "design"
	-- { steps = { … }, latest = seq } as the source lists them
	local rows = ui.state(`{key}.history`, { steps = {}, latest = 0 } :: any)
	rows:set({ steps = {}, latest = 0 })
	-- bumped when a decoded picture arrives (the rows read it)
	local rev = ui.state(`{key}.history_rev`, 0)
	-- (for tests: pictures drawn and kept, calls captured)
	local made = ui.state(`{key}.history_made`, 0)
	made:set(0)
	h.rows = rows
	h.rev = rev
	h.made = made
	local opened = false
	local queued = false

	-- `{seq}.{at}` → { [root] = { b = bitmap | false, a = … } }; `asked` once.
	local cache: { [string]: any } = {}
	local asked: { [string]: boolean } = {}
	local function row_key(s: any): string
		return `{s.seq}.{s.at}`
	end

	local function load()
		api.list(function(r: any?)
			if type(r) ~= "table" or type(r.steps) ~= "table" then
				return
			end
			-- (decoded pictures of rows gone or old let go)
			local keep = {}
			for i, s in r.steps do
				if i <= M.CACHE_ROWS then
					keep[row_key(s)] = true
				end
			end
			for k in cache do
				if not keep[k] then
					cache[k] = nil
					asked[k] = nil
				end
			end
			rows:set(r)
		end)
	end
	-- A reload soon (several events in a row make one).
	local function refresh()
		if not opened or queued then
			return
		end
		queued = true
		ui.after(150, function()
			queued = false
			load()
		end)
	end
	h.refresh = refresh

	function h.open()
		if not opened then
			opened = true
			load()
		end
	end

	-- A row's picture, decoded (asked for the first time it's wanted).
	function h.picture(s: any, root: string, which: string): any?
		local _ = rev:get()
		local k = row_key(s)
		local e = cache[k]
		if e == nil and not asked[k] and s.thumbs then
			asked[k] = true
			ui.after(0, function()
				api.thumbs(s.seq, function(t: any?)
					local got = {}
					cache[k] = got
					if type(t) ~= "table" or not (ui :: any).decode_image then
						rev:set(rev:peek() + 1)
						return
					end
					for id, p in t do
						if type(p) == "table" then
							local slot = { b = false, a = false } :: any
							got[id] = slot
							for _, w in { "b", "a" } do
								if type(p[w]) == "string" then
									ui.decode_image(p[w]):after(function(bm: any)
										if cache[k] == got then
											slot[w] = bm
											rev:set(rev:peek() + 1)
										end
									end, function() end)
								end
							end
						end
					end
					rev:set(rev:peek() + 1)
				end)
			end)
		end
		local slot = e and e[root]
		if slot and slot[which] then
			return slot[which]
		end
		return nil
	end

	-- ── pictures as an agent's call lands ────────────────────────────────
	local jobs: { any } = {}
	local busy = false
	local function next_job()
		if busy then
			return
		end
		local j = table.remove(jobs, 1)
		if not j then
			return
		end
		busy = true
		local function finish(b: string?, a: string?)
			if b or a then
				api.put_thumb(j.seq, j.id, b, a)
				made:set(made:peek() + 1)
			end
			busy = false
			-- (one Screen's pictures at a time, a frame apart)
			ui.after(16, next_job)
		end
		local function after_pic(b: string?)
			if j.gone then
				finish(b, nil)
				return
			end
			local tries = 0
			local function look()
				local now = find(api.roots:peek(), j.id)
				-- (the new root: another table than the one held before, at the
				-- version `changed` named)
				local ready = now and now.nodes and now.nodes[1] and now ~= j.old
					and (j.v == nil or (now.v or 0) >= j.v)
				if ready then
					M.render(now, function(a: string?)
						finish(b, a)
					end)
					return
				end
				tries += 1
				if tries > M.WAIT_TRIES then
					finish(b, nil)
					return
				end
				ui.after(100, look)
			end
			look()
		end
		if j.old and j.old.nodes and j.old.nodes[1] then
			M.render(j.old, after_pic)
		else
			after_pic(nil)
		end
	end

	-- Every `changed`: an agent's call with a step gets its pictures made
	-- (the root held now is "before"); every change reloads the rows.
	function h.changed(e: any)
		if type(e) ~= "table" then
			return
		end
		if e.by == "agent" and type(e.seq) == "number" and type(e.touched) == "table" then
			local gone = {}
			for _, id in e.removed or {} do
				gone[id] = true
			end
			local list = api.roots:peek()
			for i, id in e.touched do
				if i > M.ROOTS_MAX then
					break
				end
				local old = find(list, id)
				local v = if type(e.roots) == "table" then e.roots[id] else nil
				if old or not gone[id] then
					table.insert(jobs, { seq = e.seq, id = id, old = old, v = v, gone = gone[id] == true })
				end
			end
			ui.after(0, next_job)
		end
		refresh()
	end

	function h.undo_to(seq: number, keep: boolean, done: ((ok: boolean, err: any?) -> ())?)
		api.undo_to(seq, keep, rows:peek().latest, function(ok: boolean, err: any?)
			refresh()
			if done then
				done(ok, err)
			end
		end)
	end

	return h
end

-- ── rows as the tab shows them ───────────────────────────────────────────

-- The steps as shown: each agent's call on its own; the person's (and any
-- other's) steps in a row folded into one group. `{ kind = "agent", s }` or
-- `{ kind = "person", items = { s… } }`, newest first.
function M.groups(steps: { any }): { any }
	local out = {}
	local cur: any = nil
	for _, s in steps do
		if s.by == "agent" then
			cur = nil
			table.insert(out, { kind = "agent", s = s })
		else
			-- (done and undone steps don't share a group)
			if not cur or cur.done ~= s.done then
				cur = { kind = "person", items = {}, done = s.done }
				table.insert(out, cur)
			end
			table.insert(cur.items, s)
		end
	end
	return out
end

-- What a row's undo button does: "undo" (it's the newest step done),
-- "to" (Undo to here: steps after it are done), or nil (it's undone).
-- `seq` = the row's newest step.
function M.action(seq: number, done: boolean, latest: number): string?
	if not done then
		return nil
	end
	if seq == latest then
		return "undo"
	end
	if seq < latest then
		return "to"
	end
	return nil
end

-- How many done steps Undo to here at `seq` undoes.
function M.count_after(steps: { any }, seq: number): number
	local n = 0
	for _, s in steps do
		if s.done and s.seq > seq then
			n += 1
		end
	end
	return n
end

return M
