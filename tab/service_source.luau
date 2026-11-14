--!strict
-- The Canvas's source for one Design, from the plugin's service
-- (pure/CONTRACT.md §4–8): the scene's roots as the service lays them out,
-- refetched only where `changed` says a root's `v` moved; selection both
-- ways; agents' flashes; edits, undo and redo as calls.

local Draw = require("./draw")
local Guard = require("./guard")
local Roots = require("./roots")

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
	local flashes = ui.state(`design.{did}.flashes`, {} :: { any })
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

	-- Roots from a `scene` answer put in place: one written at its index
	-- (so the Canvas draws that Screen alone), the list rebuilt only when
	-- the order or the set of roots changes.
	local function take(reply: any)
		if disposed or type(reply) ~= "table" then
			return
		end
		version = math.max(version, reply.version or 0)
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
		end)
	end
	load()

	-- (The last `changed`, for tests to read: `zgx inspect state`.)
	local last_changed = ui.state(`design.{did}.last_changed`, nil :: any)
	table.insert(offs, service:on("changed", function(e: any)
		if type(e) ~= "table" or e.did ~= did then
			return
		end
		last_changed:set({ by = e.by, chat = e.chat, version = e.version, flash = e.flash, label = e.label })
		local ids = {}
		for id in e.roots or {} do
			table.insert(ids, id)
		end
		if e.by == "agent" and e.flash and #e.flash > 0 then
			pending_flash[e.version] = {
				ids = e.flash,
				chat = e.chat,
				label = if o.chat_title then o.chat_title(e.chat) else nil,
			}
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

	table.insert(offs, service:on("selection", function(e: any)
		if type(e) == "table" and e.did == did and e.by == "agent" then
			selection:set(e.ids or {})
		end
	end))

	-- The save status the title pill shows: "saved", "saving" (an edit, undo
	-- or redo on its way: the service saves each as it applies it) or
	-- "error: <why>" (the last one failed; the next that lands clears it).
	local save = ui.state(`design.{did}.save`, "saved")
	local pending = 0
	local function begin()
		pending += 1
		save:set("saving")
	end
	local function landed(err: any?)
		pending = math.max(0, pending - 1)
		if err ~= nil then
			save:set(`error: {err}`)
		elseif pending == 0 then
			save:set("saved")
		end
	end

	local source = { roots = roots, selection = selection, flashes = flashes, dark = o.dark, status = status, save = save, chat_title = o.chat_title }

	function source.edit(ops: { any }, label: string?, eo: any?)
		local e = eo or {}
		begin()
		service:call("edit", { did = did, ops = ops, label = label, join = e.join }):after(function(res: any)
			landed()
			if e.done then
				e.done(true, res)
			end
		end, function(err: any)
			landed(err)
			say(`edit: {err}`)
			if e.done then
				e.done(false, err)
			end
		end)
	end

	function source.undo()
		begin()
		service:call("undo", { did = did }):after(function()
			landed()
		end, function(err: any)
			landed(err)
			say(tostring(err))
		end)
	end

	function source.redo()
		begin()
		service:call("redo", { did = did }):after(function()
			landed()
		end, function(err: any)
			landed(err)
			say(tostring(err))
		end)
	end

	function source.select(ids: { string })
		service:call("select", { did = did, ids = ids }):after(function() end, function() end)
	end

	source.reload = load
	source.name = o.name

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

	function source.tokens(done: (t: any) -> ())
		service:call("tokens", { did = did }):after(done, function(err: any)
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

	function source.view_theme(axis: string, value: string)
		service:call("view_theme", { did = did, theme = { [axis] = value } }):after(function() end, function(err: any)
			say(`view_theme: {err}`)
		end)
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
		last_changed:set(nil)
	end

	return source
end
