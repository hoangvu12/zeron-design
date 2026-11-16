--!strict
-- The Canvas's source for one Design, from the plugin's service
-- (pure/CONTRACT.md §4–8): the scene's roots as the service lays them out,
-- refetched only where `changed` says a root's `v` moved; selection both
-- ways; agents' flashes; edits, undo and redo as calls.

local Draw = require("./draw")
local Guard = require("./guard")
local Roots = require("./roots")
local History = require("./history") -- (N3)

-- A `scene` answer's size, at most (its JSON; past it, `more`). An answer
-- becomes Luau tables all at once, with no garbage collected meanwhile:
-- about 11 times its JSON in the window's plugin memory (32 MB, every
-- Design tab's), so 900 KB answers took Workbook Studio past it.
local MAX_BYTES = 300000

return function(zeron: any, did: string, opts: { dark: any?, log: ((string) -> ())?, chat_title: ((string?) -> string?)? }?)
	local o = opts or {}
	local service = Guard.service(zeron.service())
	local roots = Roots.new(`design.{did}.roots`)
	local selection = ui.state(`design.{did}.selection`, {} :: { string })
	-- Selected interactions (F6 C1, noodles): `{ key, list = { { id, k } } }`,
	-- `key` the layer selection they were picked in (its ids joined by ","):
	-- read as none once the selection changes (canvas.luau `ia_list`).
	local ia_sel = ui.state(`design.{did}.ia_sel`, { key = "", list = {} } :: any)
	ia_sel:set({ key = "", list = {} })
	local flashes = ui.state(`design.{did}.flashes`, {} :: { any })
	-- (N1) Agents' changes to animate on the overlay (canvas.luau's agent fx):
	-- `{ { key, id, kind = "new"|"edit"|"delete"|"read", chat, at, call?, box? } }`
	-- (`box`, a deleted node's last canvas box). The Canvas drops each when done.
	local agent_fx = ui.state(`design.{did}.agent_fx`, {} :: { any })
	agent_fx:set({})
	-- (N1) Agents present: `{ { chat, name, at, busy } }`, newest first; `at`
	-- the last time each changed or read this Design (ui.now()), `busy` while
	-- its snippet runs. Shell's title chip shows them.
	local agents = ui.state(`design.{did}.agents`, {} :: { any })
	agents:set({})
	local fx_n = 0
	local function seen_agent(chat: string?, busy: boolean?)
		local key = chat or ""
		local out = { { chat = chat, name = (if o.chat_title then o.chat_title(chat) else nil) or "Agent", at = ui.now(), busy = busy == true } }
		for _, a in agents:peek() do
			if (a.chat or "") ~= key then
				table.insert(out, a)
			end
		end
		agents:set(out)
	end
	local status = ui.state(`design.{did}.status`, "loading")
	local version = 0
	local pending_flash: { [number]: any } = {}
	-- What `dispose` undoes: the service's events listened to, and the
	-- drawing's hooks. A disposed source ignores answers still coming.
	local offs: { () -> () } = {}
	local disposed = false

	local function say(s: string)
		if o.log then
			o.log(s)
		end
	end

	local function index_of(list: { any }): { [string]: number }
		local at = {}
		for i, r in list do
			at[r.id] = i
		end
		return at
	end

	-- The Design's flows (`{ { name, start } }`, proto-step1-spec §2): from
	-- `scene` answers and `changed` events. (Small: a state.)
	local flows = ui.state(`design.{did}.flows`, {} :: { any })
	flows:set({})
	local function take_flows(f: any)
		local list = if type(f) == "table" then f else {}
		local was = flows:peek()
		local same = #was == #list
		if same then
			for i, x in list do
				if was[i].name ~= x.name or was[i].start ~= x.start then
					same = false
				end
			end
		end
		if not same then
			flows:set(list)
		end
	end

	-- The Design's prototype settings (F2a): `prototype` as stored (the
	-- panel edits it) and `device` as Play plays it ({ w?, h?, fit, bg? }).
	-- Every scene answer and `changed` carries them; missing is none.
	local prototype = ui.state(`design.{did}.prototype`, nil :: any)
	local device = ui.state(`design.{did}.device`, nil :: any)
	prototype:set(nil)
	device:set(nil)
	local function take_proto(p: any, dv: any)
		local function same(a: any, b: any): boolean
			if type(a) ~= "table" or type(b) ~= "table" then
				return a == b
			end
			for k, v in a do
				if not same(v, b[k]) then
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
		if not same(prototype:peek(), p) then
			prototype:set(p)
		end
		if not same(device:peek(), dv) then
			device:set(dv)
		end
	end

	-- (N4) The Design's brief (text, "" for none): every scene answer and
	-- `changed` carries it; the panel with nothing selected edits it.
	local brief = ui.state(`design.{did}.brief`, "")
	brief:set("")
	local function take_brief(b: any)
		local t = if type(b) == "string" then b else ""
		if brief:peek() ~= t then
			brief:set(t)
		end
	end

	-- (N2) Variations sets waiting for a pick: { [node id] = { current, count,
	-- names, original } } (engine/variations.luau `summary`); the Canvas's
	-- bar (tab/variations_bar.luau) flips them.
	local variations = ui.state(`design.{did}.variations`, {} :: any)
	variations:set({})
	local function take_variations(v: any)
		if type(v) ~= "table" then
			v = {}
		end
		local cur = variations:peek()
		local same = true
		for k, s in v do
			local c = cur[k]
			if not c or c.current ~= s.current or c.count ~= s.count or table.concat(c.names or {}, "\0") ~= table.concat(s.names or {}, "\0") then
				same = false
			end
		end
		for k in cur do
			if v[k] == nil then
				same = false
			end
		end
		if not same then
			variations:set(v)
		end
	end

	-- Roots from a `scene` answer put in place: one written at its index
	-- (so the Canvas draws that Screen alone), the list rebuilt only when
	-- the order or the set of roots changes.
	local function take(reply: any)
		if disposed or type(reply) ~= "table" then
			return
		end
		version = math.max(version, reply.version or 0)
		-- (The Design's flows, beside the roots: missing or empty is none.)
		if reply.flows ~= nil then
			take_flows(reply.flows)
		end
		take_proto(reply.prototype, reply.device)
		take_brief(reply.brief)
		if reply.variations ~= nil then
			take_variations(reply.variations)
		end
		local list = roots:peek()
		local at = index_of(list)
		local order = reply.order
		local same_order = true
		if order then
			if #order ~= #list then
				same_order = false
			else
				for i, id in order do
					if list[i].id ~= id then
						same_order = false
						break
					end
				end
			end
		end
		local got: { [string]: any } = {}
		for _, r in reply.roots or {} do
			got[r.id] = r
		end
		if same_order and not (reply.removed and #reply.removed > 0) then
			ui.batch(function()
				for id, r in got do
					local i = at[id]
					if i then
						roots:set_key(i, r)
					end
				end
			end)
		else
			-- (A root still to come, in `more`, holds its place empty: the list
			-- has the whole order from the first answer, so the answers after
			-- it write their roots alone, by `set_key`. A whole `set` draws
			-- every root again; on a large Design that, once an answer, left
			-- garbage the next answer's tables landed on, past the window's
			-- 32 MB plugin memory: "scene answer: not enough memory".)
			local out = {}
			for _, id in order or {} do
				local r = got[id] or (if at[id] then list[at[id]] else nil)
				table.insert(out, r or { id = id, nodes = {} })
			end
			roots:set(out)
		end
		-- A flash waiting for its roots.
		local f = pending_flash[reply.version or -1]
		if f then
			pending_flash[reply.version] = nil
			local now = ui.now()
			local l = table.clone(flashes:peek())
			for _, id in f.ids do
				table.insert(l, { id = id, chat = f.chat, label = f.label, at = now })
			end
			flashes:set(l)
			-- (N1) new and edited nodes animate as the board shows them
			if f.fx and #f.fx > 0 then
				local a = table.clone(agent_fx:peek())
				-- (N8) `call`: one call's nodes reveal one after another (agent_fx_plan.luau)
				for _, x in f.fx do
					fx_n += 1
					table.insert(a, { key = `{fx_n}`, id = x.id, kind = x.kind, chat = f.chat, at = now, call = reply.version })
				end
				agent_fx:set(a)
			end
		end
		if reply.more and #reply.more > 0 then
			service:call("scene", { did = did, roots = reply.more, max_bytes = MAX_BYTES }):after(take, function(err: any)
				say(`scene: {err}`)
			end)
		end
	end

	local function load()
		service:call("scene", { did = did, max_bytes = MAX_BYTES }):after(function(reply: any)
			status:set("ready")
			take(reply)
		end, function(err: any)
			status:set(`error: {err}`)
			say(`scene: {err}`)
			-- (Not there any more: deleted, say so rather than "damaged".)
			service:call("designs", {}):after(function(r: any)
				if disposed or type(r) ~= "table" or type(r.designs) ~= "table" then
					return
				end
				for _, d in r.designs do
					if d.did == did then
						return
					end
				end
				status:set("deleted")
			end, function() end)
		end)
	end
	load()

	-- Deleted (here, from the Designs page, or by an agent): every tab
	-- showing it says so (init.luau). Plugins can't close a panel tab.
	table.insert(offs, service:on("designs", function(e: any)
		if type(e) == "table" and e.deleted == did then
			status:set("deleted")
		end
	end))

	-- (The last `changed`, for tests to read: `zgx inspect state`.)
	local last_changed = ui.state(`design.{did}.last_changed`, nil :: any)
	table.insert(offs, service:on("changed", function(e: any)
		if type(e) ~= "table" or e.did ~= did then
			return
		end
		last_changed:set({ by = e.by, chat = e.chat, version = e.version, flash = e.flash, label = e.label })
		-- (Every `changed` carries the Design's flows when it has any.)
		take_flows(e.flows)
		take_proto(e.prototype, e.device)
		take_brief(e.brief)
		if e.variations ~= nil then
			take_variations(e.variations)
		end
		local ids = {}
		for id in e.roots or {} do
			table.insert(ids, id)
		end
		-- (N1) new and edited nodes wait for their roots (above); deleted ones
		-- animate now, at their last box in the roots still shown.
		local later_fx = {}
		if e.by == "agent" and type(e.fx) == "table" then
			local gone: { [string]: boolean } = {}
			local any_gone = false
			for _, x in e.fx do
				if x.kind == "delete" then
					gone[x.id] = true
					any_gone = true
				else
					table.insert(later_fx, x)
				end
			end
			if any_gone then
				local look_in: { [string]: boolean } = {}
				for id in e.roots or {} do
					look_in[id] = true
				end
				for _, id in e.removed or {} do
					look_in[id] = true
				end
				local now = ui.now()
				local a = table.clone(agent_fx:peek())
				for _, r in roots:peek() do
					if look_in[r.id] or gone[r.id] then
						for _, it in r.nodes or {} do
							-- (only the outermost: a deleted node's deleted parent covers it)
							if gone[it.id] and not gone[it.p or ""] and it.box then
								fx_n += 1
								table.insert(a, { key = `{fx_n}`, id = it.id, kind = "delete", chat = e.chat, at = now, box = { it.box.x, it.box.y, it.box.w, it.box.h } })
							end
						end
					end
				end
				agent_fx:set(a)
			end
		end
		if e.by == "agent" and ((e.flash and #e.flash > 0) or #later_fx > 0) then
			pending_flash[e.version] = {
				ids = e.flash or {},
				fx = later_fx,
				chat = e.chat,
				label = if o.chat_title then o.chat_title(e.chat) else nil,
			}
		end
		if e.by == "agent" then
			seen_agent(e.chat, false)
		end
		if #ids == 0 and not e.removed and not e.order then
			return
		end
		service:call("scene", { did = did, roots = ids, max_bytes = MAX_BYTES }):after(function(reply: any)
			-- (A reply is read-only: what `changed` said goes in a copy.)
			if type(reply) == "table" then
				local r2 = table.clone(reply)
				r2.removed = reply.removed or e.removed
				r2.order = reply.order or e.order
				reply = r2
			end
			take(reply)
		end, function(err: any)
			say(`scene: {err}`)
		end)
	end))

	-- (N1) An agent's snippet running here (`working`), and the Screens it
	-- screenshot (`read`): presence, and a pale wash over each read Screen.
	table.insert(offs, service:on("working", function(e: any)
		if type(e) == "table" and e.did == did then
			seen_agent(e.chat, e.on == true)
		end
	end))
	table.insert(offs, service:on("read", function(e: any)
		if type(e) ~= "table" or e.did ~= did or type(e.roots) ~= "table" then
			return
		end
		local now = ui.now()
		local a = table.clone(agent_fx:peek())
		for _, id in e.roots do
			fx_n += 1
			table.insert(a, { key = `{fx_n}`, id = id, kind = "read", chat = e.chat, at = now })
		end
		agent_fx:set(a)
		seen_agent(e.chat, false)
	end))

	table.insert(offs, service:on("selection", function(e: any)
		if type(e) == "table" and e.did == did and e.by == "agent" then
			selection:set(e.ids or {})
		end
	end))

	-- The save status the title pill shows: "saved", "saving" (an edit, undo
	-- or redo on its way: the service saves each as it applies it) or
	-- "error: <why>" (the last one failed; the next that lands clears it).
	-- (D5) Kept calm: every keystroke and drag step is an edit, and showing
	-- "saving" for each flipped the pill at every key. "saving" shows only
	-- when one save has been on its way for SHOW_AFTER ms (a fast drag keeps
	-- some save on its way all along, each quick: that isn't slow), and once
	-- shown it stays at least MIN_SHOWN ms and until nothing has been on its
	-- way for QUIET ms. An error shows at once.
	local SHOW_AFTER, MIN_SHOWN, QUIET = 400, 600, 300
	local save = ui.state(`design.{did}.save`, "saved")
	save:set("saved")
	local pending = 0
	local out: { [number]: boolean } = {} -- the saves on their way, by ticket
	local ticket = 0 -- bumped by each save: a "back to saved" timer for an older one does nothing
	local shown_at = 0
	local function begin(): number
		pending += 1
		ticket += 1
		local t = ticket
		out[t] = true
		ui.after(SHOW_AFTER, function()
			if not disposed and out[t] and save:peek() ~= "saving" then
				shown_at = ui.now()
				save:set("saving")
			end
		end)
		return t
	end
	local function landed(t: number, err: any?)
		out[t] = nil
		pending = math.max(0, pending - 1)
		if err ~= nil then
			save:set(`error: {err}`)
			return
		end
		if pending > 0 then
			return
		end
		local s = save:peek()
		if s ~= "saving" then
			if s ~= "saved" then
				save:set("saved") -- an error cleared by a save that landed
			end
			return
		end
		-- (And QUIET ms with nothing new on its way: edits still coming with
		-- short gaps keep it on "saving".)
		local left = math.max(MIN_SHOWN - (ui.now() - shown_at), QUIET)
		local b = ticket
		ui.after(left, function()
			if not disposed and pending == 0 and ticket == b and save:peek() == "saving" then
				save:set("saved")
			end
		end)
	end

	local source = { roots = roots, selection = selection, ia_sel = ia_sel, flashes = flashes, agent_fx = agent_fx, agents = agents, dark = o.dark, status = status, save = save, chat_title = o.chat_title, flows = flows, prototype = prototype, device = device, brief = brief, variations = variations }

	-- (step 4) A Screen resolved with Play's variant state ({ [instance id] =
	-- member id }): its root as `scene` gives it, or nil.
	-- (V3) `run` = { vars, mode }: Play's variables, as the scene call takes them.
	-- (step 6 P5) `size` = { w, h }: laid out at that window (Responsive).
	function source.variant_root(id: string, vmap: { [string]: string }, done: (root: any?) -> (), run: any?, size: any?)
		local args: any = { did = did, roots = { id }, variants = vmap, max_bytes = 50000000, size = size }
		if run then
			args.vars = run.vars
			args.mode = run.mode
		end
		service:call("scene", args):after(function(reply: any)
			local r = type(reply) == "table" and type(reply.roots) == "table" and reply.roots[1] or nil
			done(if r and r.id == id then r else nil)
		end, function(err: any)
			say(`variant: {err}`)
			done(nil)
		end)
	end

	-- (step 6 P5) Screens `ids` laid out at a window of `size` ({ w, h }), as
	-- Play's Responsive shows them: their roots as `scene` gives them, or nil.
	function source.sized_roots(ids: { string }, size: any, done: (roots: { any }?) -> ())
		service:call("scene", { did = did, roots = ids, size = size, max_bytes = 50000000 }):after(function(reply: any)
			done(if type(reply) == "table" and type(reply.roots) == "table" then reply.roots else nil)
		end, function(err: any)
			say(`responsive: {err}`)
			done(nil)
		end)
	end

	-- A prototype's web link (Play): where Zeron opens links.
	function source.open_url(url: string)
		if type(zeron.open_url) == "function" then
			zeron.open_url(url)
		end
	end

	function source.edit(ops: { any }, label: string?, eo: any?)
		local e = eo or {}
		local t = begin()
		service:call("edit", { did = did, ops = ops, label = label, join = e.join }):after(function(res: any)
			landed(t)
			if e.done then
				e.done(true, res)
			end
		end, function(err: any)
			landed(t, err)
			say(`edit: {err}`)
			if e.done then
				e.done(false, err)
			end
		end)
	end

	function source.undo()
		local t = begin()
		service:call("undo", { did = did }):after(function()
			landed(t)
		end, function(err: any)
			landed(t, err)
			say(tostring(err))
		end)
	end

	function source.redo()
		local t = begin()
		service:call("redo", { did = did }):after(function()
			landed(t)
		end, function(err: any)
			landed(t, err)
			say(tostring(err))
		end)
	end

	function source.select(ids: { string })
		service:call("select", { did = did, ids = ids }):after(function() end, function() end)
	end

	-- (step 7) Local comments (tab/comments_ui.luau): the Design's pins with
	-- their replies, asked again on each `comments` event; `comment` sends one
	-- action ({ action = "add" | "reply" | "edit" | "resolve" | "reopen" |
	-- "delete", … }) and `done(ok, result or error)`.
	local comments = ui.state(`design.{did}.comments`, {} :: { any })
	local function load_comments()
		service:call("comments", { did = did }):after(function(r: any)
			if not disposed and type(r) == "table" and type(r.comments) == "table" then
				comments:set(r.comments)
			end
		end, function(err: any)
			say(`comments: {err}`)
		end)
	end
	load_comments()
	table.insert(offs, service:on("comments", function(e: any)
		if type(e) == "table" and e.did == did then
			load_comments()
		end
	end))
	source.comments = comments
	function source.comment(args: any, done: ((ok: boolean, r: any) -> ())?)
		local a = table.clone(args)
		a.did = did
		service:call("comment", a):after(function(r: any)
			if done then
				done(true, r)
			end
		end, function(err: any)
			say(`comment: {err}`)
			if done then
				done(false, err)
			end
		end)
	end

	-- (N3) The History tab's data (tab/history.luau): steps from `history`,
	-- pictures kept with `history_thumb`, Undo to here with `undo_to`.
	local history = History.new({
		key = `design.{did}`,
		roots = roots,
		list = function(done: (r: any?) -> ())
			service:call("history", { did = did }):after(function(r: any)
				if not disposed then
					done(r)
				end
			end, function(err: any)
				say(`history: {err}`)
			end)
		end,
		thumbs = function(seq: number, done: (t: any?) -> ())
			service:call("history_thumbs", { did = did, seq = seq }):after(function(r: any)
				done(if type(r) == "table" then r.thumbs else nil)
			end, function()
				done(nil)
			end)
		end,
		put_thumb = function(seq: number, root: string, b: string?, a: string?)
			service:call("history_thumb", { did = did, seq = seq, root = root, before = b, after = a }):after(function() end, function(err: any)
				say(`history_thumb: {err}`)
			end)
		end,
		undo_to = function(seq: number, keep: boolean, expect: number?, done: (ok: boolean, err: any?) -> ())
			local t = begin()
			service:call("undo_to", { did = did, seq = seq, keep = keep, expect = expect }):after(function()
				landed(t)
				done(true)
			end, function(err: any)
				landed(t)
				say(tostring(err))
				done(false, err)
			end)
		end,
	})
	table.insert(offs, service:on("changed", function(e: any)
		if type(e) == "table" and e.did == did then
			history.changed(e)
		end
	end))
	table.insert(offs, service:on("history", function(e: any)
		if type(e) == "table" and e.did == did then
			history.refresh()
		end
	end))
	source.history = history

	source.reload = load
	source.name = o.name
	source.did = did
	-- (f7 share) words into the chat's message box ("compose"), for the
	-- person to send.
	function source.compose(text: string)
		zeron.compose(text)
	end

	-- The layers list (`tree`), asked again as the Design changes.
	-- (Held in Luau, as the roots are: a state would hold the whole list
	-- again in Rust, counted against the window's plugin memory, and copy
	-- it at every edit. Read as a state: `get` follows it, `peek` doesn't.)
	local tree_rev = ui.state(`design.{did}.tree_rev`, 0)
	-- (Earlier versions held the list in this state; a named state outlives a
	-- reload, so let its value go.)
	ui.state(`design.{did}.tree`, nil :: any):set(nil)
	local tree_list: { any } = {}
	local tree = {
		get = function(_self: any): { any }
			local _ = tree_rev:get()
			return tree_list
		end,
		peek = function(_self: any): { any }
			return tree_list
		end,
		set = function(_self: any, list: { any })
			tree_list = list
			tree_rev:set(tree_rev:peek() + 1)
		end,
	}
	local tree_by: { [string]: any } = {}
	local function load_tree()
		service:call("tree", { did = did }):after(function(r: any)
			if not disposed and type(r) == "table" and type(r.nodes) == "table" then
				table.clear(tree_by)
				for _, n in r.nodes do
					tree_by[n.id] = n
				end
				tree:set(r.nodes)
			end
		end, function(err: any)
			say(`tree: {err}`)
		end)
	end
	load_tree()
	table.insert(offs, service:on("changed", function(e: any)
		if type(e) == "table" and e.did == did then
			load_tree()
		end
	end))
	source.tree = tree

	-- A node for the properties panel, with its parent's JSON (whether it
	-- lays the node out).
	function source.node(id: string, done: (info: any?) -> ())
		service:call("node", { did = did, id = id }):after(function(r: any)
			if type(r) ~= "table" then
				done(nil)
				return
			end
			local t = tree_by[id]
			if t and t.p then
				service:call("node", { did = did, id = t.p }):after(function(p: any)
					local r2 = table.clone(r)
					r2.parent = if type(p) == "table" then p.node else nil
					done(r2)
				end, function()
					done(r)
				end)
			else
				done(r)
			end
		end, function(err: any)
			say(`node: {err}`)
			done(nil)
		end)
	end

	-- (N5) Selection colors: the paints of the layers and all inside them.
	function source.paints(ids: { string }, done: (r: any?) -> ())
		service:call("paints", { did = did, ids = ids }):after(function(r: any)
			done(if type(r) == "table" then r else nil)
		end, function(err: any)
			say(`paints: {err}`)
			done(nil)
		end)
	end

	function source.tokens(done: (t: any) -> ())
		service:call("tokens",{ did = did }):after(done, function(err: any)
			say(`tokens: {err}`)
		end)
	end

	-- Copy (or cut) layers to the service's clipboard; `paste` edits read it.
	function source.copy(ids: { string }, cut: boolean?, done: ((ok: boolean) -> ())?)
		service:call("copy", { did = did, ids = ids, cut = cut == true }):after(function()
			if done then
				done(true)
			end
		end, function(err: any)
			say(`copy: {err}`)
			if done then
				done(false)
			end
		end)
	end

	function source.code(o: { ids: { string }, css: string?, scaffold: boolean? }, done: (r: any) -> ())
		service:call("code", { did = did, ids = o.ids, css = o.css, scaffold = o.scaffold }):after(done, function(err: any)
			done({ code = `<!-- {err} -->` })
		end)
	end

	-- Pictures in zeron.db (`image_get`), for the drawing to decode.
	Draw.fetch = function(key: string, got: (b64: string?) -> ())
		service:call("image_get", { key = key }):after(function(r: any)
			got(if type(r) == "table" then r.base64 else nil)
		end, function()
			got(nil)
		end)
	end

	-- A picture decoded: the roots showing it drawn again (written whole:
	-- their drawing is kept by the item).
	local function redraw_all()
		local list = roots:peek()
		ui.batch(function()
			for i, r in list do
				local r2 = table.clone(r)
				r2.pics = (r.pics or 0) + 1
				roots:set_key(i, r2)
			end
		end)
	end
	local function redraw_showing(key: string)
		local list = roots:peek()
		ui.batch(function()
			for i, r in list do
				local shows = false
				for _, it in r.nodes do
					for _, p in it.fill or {} do
						if p.src == "img:" .. key then
							shows = true
						end
					end
				end
				if shows then
					-- (A value of its own changes, so the item draws again.)
					local r2 = table.clone(r)
					r2.pics = (r.pics or 0) + 1
					roots:set_key(i, r2)
				end
			end
		end)
	end
	table.insert(Draw.redrawers, redraw_all)
	table.insert(Draw.listeners, redraw_showing)

	-- The theme the Design is viewed in: every axis picked so far is sent
	-- (the service keeps the map it's given whole, so one axis alone reset
	-- the others). Play reads it for the page's modes (V3).
	local view_map: { [string]: string } = {}
	function source.view_theme(axis: string, value: string)
		view_map[axis] = value
		service:call("view_theme", { did = did, theme = table.clone(view_map) }):after(function() end, function(err: any)
			say(`view_theme: {err}`)
		end)
	end
	function source.view_theme_map(): { [string]: string }
		return table.clone(view_map)
	end

	-- Let go of the Design: no tab shows it any more (init.luau). Its
	-- scene, index and layers go with it; opening it again loads it anew.
	function source.dispose()
		if disposed then
			return
		end
		disposed = true
		for _, off in offs do
			off()
		end
		table.clear(offs)
		local i = table.find(Draw.redrawers, redraw_all)
		if i then
			table.remove(Draw.redrawers, i)
		end
		i = table.find(Draw.listeners, redraw_showing)
		if i then
			table.remove(Draw.listeners, i)
		end
		table.clear(pending_flash)
		table.clear(tree_by)
		roots:set({})
		tree:set({})
		flashes:set({})
		agent_fx:set({})
		agents:set({})
		last_changed:set(nil)
		comments:set({})
	end

	return source
end
