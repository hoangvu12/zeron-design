--!nonstrict
-- Design (pure)'s service: the single owner of every Design (pure/CONTRACT.md).
-- Agents' tools (design_execute, design_state, design_guide) and the tab's
-- calls (scene, edit, undo, â€¦) all land here; changes go out as events.

local zeron = require("./zeron")("design-pure")

local U = require("./engine/util")
local Boot = require("./engine/boot")
local Designs = require("./engine/designs")
local Resolve = require("./engine/resolve")
local Layout = require("./engine/layout")
local Scene = require("./engine/scene")
local Edit = require("./engine/edit")
local Ops = require("./engine/ops")
local Agent = require("./engine/agent")
local Guide = require("./engine/guide")
local Files = require("./engine/files")
local Icons = require("./engine/icons")
local Export = require("./engine/export")
local Images = require("./engine/images")
local Webfonts = require("./engine/webfonts")
local Handoff = require("./engine/handoff")

Boot.fonts(zeron)
Designs.init(zeron)
Icons.init(zeron)
Images.init(zeron)
Webfonts.init(zeron)
Guide.keep = { get = Designs.kv_get, set = Designs.kv_set }
Agent.icons = function(name, weight)
	return Icons.get(name, weight)
end

local M = {}

local function fail(code: string, words: string)
	error(code .. ": " .. words, 0)
end

local function did_of(args: any): string
	if type(args) ~= "table" or type(args.did) ~= "string" then
		fail("bad_params", "needs a did")
	end
	return args.did
end

local function held(did: string): any
	local ok, d = pcall(Designs.get, did)
	if not ok then
		fail("not_found", "no Design " .. did)
	end
	return d
end

local function emit(name: string, data: any)
	local ok, e = pcall(zeron.emit, name, data)
	if not ok then
		print("emit " .. name .. ": " .. tostring(e))
	end
end

local function tell_changed(d: any, c: any, by: string, label: string, chat: string?, flash: any?, made: any?)
	if not c then
		return
	end
	emit("changed", {
		did = d.did, version = c.version, roots = c.roots, removed = c.removed, order = c.order,
		by = by, chat = chat, label = label, flash = flash, ids = made,
	})
end

-- â”€â”€ the scene â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local function roots_summary(d: any): { any }
	local r = Resolve.new(d.doc, d.view_theme)
	local roots = r:roots(d.doc)
	Layout.run(roots)
	local out = {}
	for _, n in roots do
		local b = n.__box
		table.insert(out, { id = n.id, name = n.name, t = n.type, box = { x = b.x, y = b.y, w = b.w, h = b.h }, v = d.rootv[n.id] or 0, comp = n.reusable == true or nil })
	end
	return out
end

local function order_of(d: any): { string }
	local o = {}
	for _, n in d.doc.children do
		table.insert(o, n.id)
	end
	return o
end

function M.scene(args: any): any
	local d = held(did_of(args))
	local want = nil
	if type(args.roots) == "table" and #args.roots > 0 then
		want = args.roots
	end
	local have = if type(args.have) == "table" then args.have else {}
	local theme = if type(args.theme) == "table" then args.theme else d.view_theme
	local r = Resolve.new(d.doc, theme)
	local ids = {}
	local exists = {}
	for _, n in d.doc.children do
		exists[n.id] = true
	end
	if want then
		for _, id in want do
			if exists[id] then
				table.insert(ids, id)
			end
		end
	else
		for _, n in d.doc.children do
			local v = d.rootv[n.id] or 0
			if have[n.id] == nil or have[n.id] ~= v then
				table.insert(ids, n.id)
			end
		end
	end
	local removed = {}
	for id in have do
		if not exists[id] then
			table.insert(removed, id)
		end
	end
	local max = if type(args.max_bytes) == "number" then args.max_bytes else 900000
	local out, more, bytes = {}, {}, 0
	local resolved = r:roots(d.doc, ids)
	Webfonts.start()
	local fresh = Webfonts.need(Webfonts.wanted(resolved))
	if #fresh > 0 then
		emit("fonts", { families = fresh })
	end
	Layout.run(resolved)
	Icons.need(Icons.used(resolved))
	local images = Images.links(d.did)
	local function icon(name, weight)
		return Icons.get(name, weight)
	end
	for _, root in resolved do
		if bytes >= max then
			table.insert(more, root.id)
			continue
		end
		local items = Scene.items(root, { images = images, icons = icon })
		if type(args.node) == "string" and args.node ~= root.id then
			-- One node and what's inside it (a screenshot's): its items are
			-- a run of the root's, the node first and `n` after it.
			local cut = nil
			for i, it in items do
				if it.id == args.node then
					cut = table.move(items, i, i + (it.n or 0), 1, {})
					cut[1] = table.clone(cut[1])
					cut[1].p = nil
					break
				end
			end
			items = cut or items
		end
		local entry = { id = root.id, v = d.rootv[root.id] or 0, nodes = items }
		local size = #zeron.json.encode(entry)
		if bytes > 0 and bytes + size > max then
			table.insert(more, root.id)
		else
			bytes += size
			table.insert(out, entry)
		end
	end
	return { did = d.did, version = d.version, theme = theme, roots = out, removed = if #removed > 0 then removed else nil, order = order_of(d), more = if #more > 0 then more else nil }
end

-- â”€â”€ calls from the window â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local function summary(d: any): any
	local u, r = Designs.can(d)
	return {
		did = d.did, name = d.name, version = d.version, order = order_of(d), roots = roots_summary(d),
		themes = d.doc.themes or {}, tokens = d.doc.tokens or {},
		selection = (Designs.kv_get("sel:" .. d.did) or {}).ids or {},
		can_undo = u, can_redo = r,
	}
end

-- One change to a Design at a time. Calls interleave wherever one awaits
-- (every database write does), so two agents' snippets on one Design
-- changed the same document between each other's reads and both wrote the
-- same undo step ("UNIQUE constraint failed: steps.did, steps.seq"). A
-- change waits here for the one before it; reads don't.
local writing: { [string]: boolean } = {}
local function exclusive(did: string, fn: (...any) -> ...any, ...: any): ...any
	while writing[did] do
		zeron.sleep(0.01):await()
	end
	writing[did] = true
	local r = table.pack(pcall(fn, ...))
	writing[did] = nil
	if not r[1] then
		error(r[2], 0)
	end
	return table.unpack(r, 2, r.n)
end
M.exclusive = exclusive

local function serve(name: string, fn: (any) -> any, safe: boolean?)
	M[name] = fn
	zeron.serve(name, function(args: any)
		args = if type(args) == "table" then args else {}
		if not safe and type(args.did) == "string" then
			return exclusive(args.did, fn, args)
		end
		return fn(args)
	end, { safe = safe })
end

serve("designs", function()
	local list = {}
	for _, r in Designs.list() do
		table.insert(list, { did = r.did, name = r.name, updated = r.updated, opened = r.opened, version = r.version })
	end
	return { designs = list }
end, true)

serve("new", function(args)
	local d = Designs.create(if type(args.name) == "string" then args.name else nil)
	emit("designs", {})
	return { did = d.did, name = d.name, version = d.version }
end)

serve("open", function(args)
	local d = held(did_of(args))
	Designs.touch(d.did)
	return summary(d)
end, true)

serve("rename", function(args)
	local d = held(did_of(args))
	if type(args.name) ~= "string" or args.name == "" then
		fail("bad_params", "a name is text")
	end
	Designs.rename(d.did, args.name)
	emit("designs", {})
	return { did = d.did, name = args.name }
end)

serve("delete", function(args)
	Designs.delete(did_of(args))
	emit("designs", {})
	return {}
end)

serve("import", function(args)
	if type(args.text) ~= "string" then
		fail("bad_params", "import needs the .zdesign text")
	end
	local doc, warnings = Files.read(zeron, args.text)
	if not doc then
		fail("bad_params", warnings[1] or "not a Design")
	end
	local d = Designs.create(if type(args.name) == "string" then args.name else "Imported design", doc, args.source)
	emit("designs", {})
	-- Pictures it names by a path beside its file: the tab can send them (image_put).
	local missing = Images.missing(d.doc, {})
	return { did = d.did, name = d.name, version = d.version, warnings = warnings, images = if #missing > 0 then missing else nil }
end)

serve("export", function(args)
	local d = held(did_of(args))
	return { text = Files.write(d.doc), name = d.name }
end, true)

serve("scene", M.scene, true)

serve("tree", function(args)
	local d = held(did_of(args))
	local nodes = {}
	local r = Resolve.new(d.doc, d.view_theme)
	local function walk(list, parent, depth, inside)
		for _, n in U.list(list) do
			if type(n) == "table" then
				local item = { id = n.id, p = parent, d = depth, t = n.type, name = n.name, hidden = n.enabled == false or nil, lock = n.locked == true or nil, comp = n.reusable == true or nil, inst = if n.type == "instance" then n.ref else nil }
				-- `txt`: a text's content (its first 200 bytes), for Find.
				if n.type == "text" and type(n.content) == "string" then
					item.txt = string.sub(n.content, 1, 200)
				end
				-- `lay`: its flex layout, "horizontal" or "vertical" (an Instance's from its Component).
				local lay = n.layout
				table.insert(nodes, item)
				if n.type == "instance" and not inside then
					local x = r:node(n, r.theme, {})
					if x and lay == nil then
						lay = x.layout
					end
					if x then
						walk(x.children, n.id, depth + 1, true)
					end
				else
					walk(n.children, n.id, depth + 1, inside)
				end
				item.lay = if lay == "horizontal" or lay == "vertical" then lay else nil
			end
		end
	end
	walk(d.doc.children, nil, 0, false)
	return { version = d.version, nodes = nodes }
end, true)

serve("node", function(args)
	local d = held(did_of(args))
	local draft = Edit.draft(d)
	local id = args.id
	if type(id) ~= "string" then
		fail("bad_params", "needs an id")
	end
	local raw
	if Edit.is_inside(id) then
		local r = draft:resolved_find(id)
		raw = if r then Edit.clean_resolved(r) else nil
	else
		local f = draft:find(id)
		raw = f and U.props(f.node)
	end
	if not raw then
		fail("not_found", "no node " .. id)
	end
	raw.children = nil
	local r = draft:resolved_find(id)
	local box = nil
	local roots = draft:laid_out(id)
	local function walk(n)
		if n.id == id then
			box = n.__box
		end
		for _, c in (n.children or {}) do
			walk(c)
		end
	end
	for _, x in roots do
		walk(x)
	end
	local resolved = r and U.props(Edit.clean_resolved(r)) or nil
	return { node = raw, box = box and { x = box.x, y = box.y, w = box.w, h = box.h }, resolved = resolved }
end, true)

serve("edit", function(args)
	local d = held(did_of(args))
	local draft = Edit.draft(d)
	local ok, made = pcall(Ops.run, draft, args.ops)
	if not ok then
		Designs.rollback(d)
		local msg = if type(made) == "table" and made.draft_error then made.draft_error else tostring(made)
		fail("bad_params", msg)
	end
	draft:finish()
	local label = if type(args.label) == "string" then args.label else "Edit"
	local c = Designs.commit(d, label, "person", nil, args.join == true)
	tell_changed(d, c, "person", label, nil, nil, made)
	return { version = d.version, ids = made, warnings = if #draft.warnings > 0 then draft.warnings else nil }
end)

serve("copy", function(args)
	local d = held(did_of(args))
	local ids = if type(args.ids) == "table" then args.ids else {}
	local draft = Edit.draft(d)
	local ok, clip = pcall(Ops.clip, draft, ids)
	if not ok then
		fail("bad_params", if type(clip) == "table" and clip.draft_error then clip.draft_error else tostring(clip))
	end
	Ops.clipboard = clip
	local out = { clip = clip, text = zeron.json.encode(clip) }
	if args.cut == true then
		local okc, e = pcall(Ops.run, draft, { { op = "delete", ids = ids } })
		if not okc then
			Designs.rollback(d)
			fail("bad_params", if type(e) == "table" and e.draft_error then e.draft_error else tostring(e))
		end
		local c = Designs.commit(d, "Cut", "person", nil)
		tell_changed(d, c, "person", "Cut", nil, nil, nil)
		out.version = d.version
	end
	return out
end)

serve("code", function(args)
	local d = held(did_of(args))
	local ids = if type(args.ids) == "table" then args.ids elseif type(args.id) == "string" then { args.id } else {}
	local roots = Resolve.new(d.doc):roots(d.doc)
	Icons.need(Icons.used(roots))
	local ok, code = pcall(Export.html, d.doc, ids, {
		css = if args.css == "css" then "css" else "tailwind",
		scaffold = args.scaffold == true,
		layerNames = args.layerNames == true,
		icons = Agent.icons,
	})
	if not ok then
		fail("bad_params", if type(code) == "table" and code.draft_error then code.draft_error else tostring(code))
	end
	return { code = code, language = "html" }
end, true)

-- Image bytes (pure/NEEDS.md §2): kept once by SHA-256; a Design links a
-- paint's url to a key, and its scene then names `img:<key>`.
serve("image_put", function(args)
	if type(args.base64) ~= "string" then
		fail("bad_params", "image_put needs base64")
	end
	local img = Images.put(args.base64)
	if type(args.did) == "string" and type(args.url) == "string" and args.url ~= "" then
		local d = held(args.did)
		Images.link(d.did, args.url, img.key)
		local all = {}
		for _, n in d.doc.children do
			all[n.id] = d.rootv[n.id] or 0
		end
		emit("changed", { did = d.did, version = d.version, roots = all, by = "images", label = "Images", refetch = true })
	end
	return img
end)

serve("image_get", function(args)
	if type(args.key) ~= "string" then
		fail("bad_params", "image_get needs a key")
	end
	local img = Images.get((string.gsub(args.key, "^img:", "")))
	if not img then
		fail("not_found", "no picture " .. args.key)
	end
	return img
end, true)

serve("images_missing", function(args)
	local d = held(did_of(args))
	return { urls = Images.missing(d.doc, Images.links(d.did)) }
end, true)

serve("clipboard", function()
	return { clip = Ops.clipboard }
end, true)

local function step(args: any, undoing: boolean): any
	local d = held(did_of(args))
	local c = if undoing then Designs.undo(d) else Designs.redo(d)
	if not c then
		fail("nothing", if undoing then "nothing to undo" else "nothing to redo")
	end
	tell_changed(d, c, if undoing then "undo" else "redo", c.label)
	return { version = c.version, label = c.label }
end
serve("undo", function(args)
	return step(args, true)
end)
serve("redo", function(args)
	return step(args, false)
end)

serve("select", function(args)
	local d = held(did_of(args))
	local ids = if type(args.ids) == "table" then args.ids else {}
	Designs.kv_set("sel:" .. d.did, { ids = ids, chat = args.chat, at = os.time() })
	emit("selection", { did = d.did, ids = ids, by = "person", chat = args.chat })
	return {}
end)

serve("tabs", function(args)
	if type(args.chat) ~= "string" then
		fail("bad_params", "needs a chat")
	end
	Designs.kv_set("tabs:" .. args.chat, if type(args.dids) == "table" then args.dids else {})
	return {}
end)

serve("tokens", function(args)
	local d = held(did_of(args))
	local rows = {}
	for name, tok in (d.doc.tokens or {}) do
		local t = Resolve.read_token(name, tok)
		if t then
			table.insert(rows, { name = name, type = t.kind, values = t.values })
		end
	end
	table.sort(rows, function(a, b)
		return a.name < b.name
	end)
	local axes = {}
	for axis, values in (d.doc.themes or {}) do
		table.insert(axes, { axis = axis, values = values })
	end
	return { tokens = d.doc.tokens or {}, themes = d.doc.themes or {}, rows = rows, axes = axes }
end, true)

serve("components", function(args)
	local d = held(did_of(args))
	local comps = {}
	local uses = {}
	Resolve.walk(d.doc.children, function(n)
		if n.type == "instance" and type(n.ref) == "string" then
			uses[n.ref] = (uses[n.ref] or 0) + 1
		end
		return true
	end)
	local draft = Edit.draft(d)
	local roots = draft:laid_out(nil)
	local function walk(n)
		if n.reusable == true then
			local b = n.__box
			table.insert(comps, { id = n.id, name = n.name, box = { x = b.x, y = b.y, w = b.w, h = b.h }, instances = uses[n.id] or 0 })
		end
		for _, c in (n.children or {}) do
			walk(c)
		end
	end
	for _, r in roots do
		walk(r)
	end
	return { components = comps }
end, true)

serve("fonts", function()
	Webfonts.start()
	local families, files = {}, {}
	for file, fams in Boot.loaded do
		table.insert(files, file)
		for _, f in fams do
			table.insert(families, f)
		end
	end
	-- Fonts fetched from Google Fonts: the window loads each one's bytes
	-- (`font_get {key}` → `ui.load_font { base64 = … }`).
	local web = {}
	for _, k in Webfonts.loaded_keys do
		table.insert(web, { key = k.key, family = k.family, weight = k.weight })
		table.insert(families, k.family)
	end
	return { families = families, files = files, web = web }
end, true)

serve("font_get", function(args)
	if type(args.key) ~= "string" then
		fail("bad_params", "font_get needs a key")
	end
	local f = Webfonts.get(args.key)
	if not f then
		fail("not_found", "no font " .. args.key)
	end
	return f
end, true)

serve("view_theme", function(args)
	local d = held(did_of(args))
	d.view_theme = if type(args.theme) == "table" then args.theme else {}
	local all = {}
	for _, n in d.doc.children do
		all[n.id] = d.rootv[n.id] or 0
	end
	emit("changed", { did = d.did, version = d.version, roots = all, by = "view", label = "Theme" })
	return {}
end)

-- â”€â”€ screenshots (Â§9) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local renders: { [string]: any } = {}
local req_n = 0

serve("render_done", function(args)
	if type(args.req) == "string" and renders[args.req] then
		renders[args.req].done = { png = args.png, error = args.error, ms = args.ms, items = args.items }
	end
	return {}
end)

local SHOT_MAX = 800
-- Renders go to the window one at a time: four agents' boards at once made
-- the window hold four scenes and draw four boards back to back in its
-- handlers, and a window over its time or memory is stopped with every
-- render after it. Each waits RENDER_WAIT for its answer and is asked once
-- more (an event lost to a reload); once a render got no answer at all,
-- the next ones wait SILENT_WAIT until one is answered again.
local RENDER_WAIT, RENDER_TRIES, SILENT_WAIT = 8, 2, 2
local render_busy = false
local window_silent = false
M.render_stats = { asked = 0, answered = 0, retried = 0, unanswered = 0, draw_ms_max = 0 }

local function render_one(event: any): (any?, number)
	while render_busy do
		zeron.sleep(0.02):await()
	end
	render_busy = true
	local stats = M.render_stats
	local done, tries = nil, 0
	local ok, err = pcall(function()
		for try = 1, if window_silent then 1 else RENDER_TRIES do
			tries = try
			req_n += 1
			local req = "r" .. req_n .. "-" .. os.time()
			renders[req] = {}
			stats.asked += 1
			if try > 1 then
				stats.retried += 1
			end
			local ev = table.clone(event)
			ev.req = req
			emit("render", ev)
			local wait = if window_silent then SILENT_WAIT else RENDER_WAIT
			local waited = 0
			while not renders[req].done and waited < wait do
				zeron.sleep(0.02):await()
				waited += 0.02
			end
			done = renders[req].done
			renders[req] = nil
			if done then
				break
			end
		end
	end)
	render_busy = false
	if not ok then
		return { error = tostring(err) }, tries
	end
	if done then
		window_silent = false
		stats.answered += 1
		if type(done.ms) == "number" and done.ms > stats.draw_ms_max then
			stats.draw_ms_max = done.ms
			-- (In plugin_status's log: how near a draw comes to the window's
			-- 50 ms a call.)
			print(string.format("render: slowest draw so far %.1f ms (%s items, %s)", done.ms, tostring(done.items), tostring(event.id)))
		end
	else
		window_silent = true
		stats.unanswered += 1
	end
	return done, tries
end

local function screenshots(d: any, shots: { any }): ({ any }, { string })
	if #shots == 0 then
		return {}, {}
	end
	local draft = Edit.draft(d)
	local reqs = {}
	local gone = {}
	for _, shot in shots do
		local id = shot.id
		local fine, roots = pcall(draft.laid_out, draft, id)
		if not fine then
			-- it was there when the snippet asked; something changed the
			-- Design since (the person, an undo, another chat)
			table.insert(gone, `no screenshot of {id}: it isn't in the Design any more (changed after this call by the person, an undo or another chat)`)
			roots = {}
		end
		local box = nil
		local function walk(n)
			if n.id == id then
				box = n.__box
			end
			for _, c in (n.children or {}) do
				walk(c)
			end
		end
		for _, r in roots do
			walk(r)
		end
		if box then
			local scale = shot.scale or math.min(2, SHOT_MAX / math.max(box.w, box.h, 1))
			table.insert(reqs, { id = id, event = { did = d.did, root = roots[1] and roots[1].id, id = id, scale = scale, x = box.x, y = box.y, w = math.max(box.w, 1), h = math.max(box.h, 1) } })
		end
	end
	-- (Laid out above, before any wait: what the call made, where it is now.)
	local images, notes, shot_list = {}, gone, {}
	for _, r in reqs do
		local done, tries = render_one(r.event)
		if done and type(done.png) == "string" then
			table.insert(images, { type = "image", data = done.png, mimeType = "image/png" })
			table.insert(shot_list, { id = r.id, png = done.png, scale = r.event.scale })
		elseif done then
			table.insert(notes, `no screenshot of {r.id}: {done.error}`)
		else
			table.insert(notes, `no screenshot of {r.id}: no Design (pure) window answered (asked {tries} time{if tries == 1 then "" else "s"}). `
				.. "Its window script isn't running: Zeron stops a plugin's window when it runs over its time or memory. Turn Design (pure) off and on in Plugins and take it again.")
		end
	end
	return images, notes, shot_list
end

-- One node as a PNG at `scale` (an export's): base64, or nil and why.
local function render_png(d: any, id: string, scale: number): (string?, string?)
	local draft = Edit.draft(d)
	local fine, roots = pcall(draft.laid_out, draft, id)
	if not fine then
		return nil, "it isn't in the Design any more"
	end
	local box = nil
	local function walk(n)
		if box then
			return
		end
		if n.id == id then
			box = n.__box
			return
		end
		for _, c in (n.children or {}) do
			walk(c)
		end
	end
	for _, r in roots do
		walk(r)
	end
	if not box then
		return nil, "it has no box (hidden, or not drawn)"
	end
	local done, tries = render_one({ did = d.did, root = roots[1] and roots[1].id, id = id, scale = scale, x = box.x, y = box.y, w = math.max(box.w, 1), h = math.max(box.h, 1) })
	if done and type(done.png) == "string" then
		return done.png
	end
	if done then
		return nil, tostring(done.error)
	end
	return nil, `no Design (pure) window answered (asked {tries} times): turn Design (pure) off and on in Plugins`
end

-- What an agent's Export asked for, written to files (engine/handoff.luau).
-- Into the chat's folder (`call.cwd`) under design-exports/, else the
-- plugin's folder in Documents. Needs `zeron.write_file` ("files.write");
-- without it, exports come back in the result as before.
local function write_exports(d: any, entries: { any }, cwd: string?, result: any)
	local base = nil
	if type(cwd) == "string" and cwd ~= "" then
		local sep = if string.find(cwd, "\\", 1, true) and not string.find(cwd, "/", 1, true) then "\\" else "/"
		base = (string.gsub(cwd, "[/\\]+$", "")) .. sep .. "design-exports"
	end
	local out, pngs = Handoff.run(d, entries, {
		base = base,
		write = function(path: string, data: string, b64: boolean?): string
			return zeron.write_file(path, data, { base64 = b64 == true }):await().path
		end,
		render = function(id: string, scale: number)
			return render_png(d, id, scale)
		end,
		now = os.time,
		json = zeron.json.encode,
		icons = Agent.icons,
	})
	-- `inline = true`: the PNGs (and HTML) in the result as well.
	local inline_ids, inline_html = {}, {}
	for _, e in entries do
		if e.inline then
			if e.format == "png" then
				inline_ids[e.id] = true
			elseif e.format == "html" then
				table.insert(inline_html, e.html)
			elseif e.format == "handoff" then
				for _, p in pngs do
					inline_ids[p.id] = true
				end
			end
		end
	end
	for _, p in pngs do
		if inline_ids[p.id] then
			result.imageContent = result.imageContent or {}
			table.insert(result.imageContent, { type = "image", data = p.png, mimeType = "image/png" })
		end
	end
	if out then
		out.html = if #inline_html > 0 then inline_html else nil
	end
	result.exported = out
end

-- â”€â”€ agents' tools â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local function front_for(chat: string?): string?
	if chat then
		local tabs = Designs.kv_get("tabs:" .. chat)
		if type(tabs) == "table" and tabs[1] then
			return tabs[1]
		end
	end
	return nil
end

local function target(args: any, chat: string?): (any?, string?)
	if type(args.did) == "string" and args.did ~= "" then
		return held(args.did)
	end
	if type(args.path) == "string" and args.path ~= "" then
		if Designs.exists(args.path) then
			return held(args.path)
		end
		local by = Designs.find_by_name(args.path)
		if by then
			return held(by)
		end
		return nil, `no Design "{args.path}": Designs here are named by their did (see design_state)`
	end
	if type(args.name) == "string" and args.name ~= "" then
		local d = Designs.create(args.name)
		emit("designs", {})
		return d
	end
	local f = front_for(chat)
	if f and Designs.exists(f) then
		return held(f)
	end
	local list = Designs.list()
	if list[1] then
		return held(list[1].did)
	end
	return nil, "no Design yet: pass name to make one"
end

zeron.tool({
	name = "design_execute",
	run = function(args: any, call: any): any
		local chat = call and call.chat
		local snippet, description = args.snippet, args.description
		local d, why
		if type(args.editId) == "string" then
			local r, e = Agent.retried(args.editId, args.edits)
			if not r then
				return { error = e }
			end
			snippet = r.snippet
			description = description or r.description
			d = held(r.did)
		else
			if type(snippet) ~= "string" or snippet == "" then
				return { error = "design_execute needs a snippet (Luau), or an editId and edits to retry a failed one" }
			end
			d, why = target(args, chat)
			if not d then
				return { error = why }
			end
		end
		description = if type(description) == "string" and description ~= "" then description else "Agent edit"
		-- The change, alone on this Design (`exclusive`); its screenshots after.
		local seen_key, seen, before, ok, result, committed, draft, flash, after
		local failed = exclusive(d.did, function()
		seen_key = "seen:" .. tostring(chat) .. ":" .. d.did
		seen = Designs.kv_get(seen_key)
		before = d.version
		emit("working", { did = d.did, chat = chat, on = true, label = description })
		ok, result, committed, draft, flash = pcall(Agent.execute, zeron, d, snippet, description, chat, { verbose = args.verbose == true })
		emit("working", { did = d.did, chat = chat, on = false })
		if not ok then
			Designs.rollback(d)
			local msg = if type(result) == "table" and result.draft_error then result.draft_error else tostring(result)
			return Agent.failure(d, snippet, description, chat, "the call failed inside Design: " .. msg, 0, nil)
		end
		-- From here the call has committed: nothing below may fail it (an
		-- error now would hide a change that happened), so each step's
		-- failure becomes a note.
		after = function(what: string, f: any)
			local fine, e = pcall(f)
			if not fine then
				result.notes = result.notes or {}
				table.insert(result.notes, `{what} failed after the call was saved: ` .. (if type(e) == "table" and e.draft_error then e.draft_error else tostring(e)))
			end
		end
		if committed then after("checking icons and fonts", function()
			-- Icons it uses that don't exist: native fails the call; a
			-- snippet can't wait on the network, so they come as warnings.
			local roots = {}
			for id in committed.roots do
				table.insert(roots, id)
			end
			local rr = Resolve.new(d.doc, d.view_theme):roots(d.doc, roots)
			local missing = Icons.need(Icons.used(rr))
			for _, name in missing do
				result.warnings = result.warnings or {}
				table.insert(result.warnings, { message = `the icon "{name}" doesn't exist in Iconify (names are "set:name", as lucide:search or ph:house-fill); it draws nothing` })
			end
			-- Families the engine didn't have: from Google Fonts, now. Text in
			-- them was measured in Geist inside the snippet; the tab and
			-- screenshots get the real font from here on.
			Webfonts.start()
			local fresh, absent = Webfonts.need(Webfonts.wanted(rr))
			if #fresh > 0 then
				emit("fonts", { families = fresh })
				local keep = {}
				for _, w in (result.warnings or {}) do
					local drop = false
					for _, f in fresh do
						if w.property == "fontFamily" and string.find(w.message or "", `"{f}"`, 1, true) then
							drop = true
						end
					end
					if not drop then
						table.insert(keep, w)
					end
				end
				result.warnings = if #keep > 0 then keep else nil
				result.fonts = { loaded = fresh, note = "fetched from Google Fonts during this call: bounds this call printed for text in these families were measured in Geist; read them again" }
			end
			for _, f in absent do
				result.warnings = result.warnings or {}
				table.insert(result.warnings, { property = "fontFamily", message = `"{f}" isn't a Google Fonts family Design (pure) could fetch; its text draws in Geist` })
			end
		end) end
		if committed then
			tell_changed(d, committed, "agent", description, chat, flash, nil)
		end
		if type(seen) == "number" and seen < before then
			result.notice = "the Design changed since your last call (another chat or the person): re-read nodes before changing what you didn't just make"
		end
		Designs.kv_set(seen_key, d.version)
		return nil
		end)
		if failed then
			return failed
		end
		local shots, exports = {}, {}
		local can_write = type(zeron.write_file) == "function"
		if draft then
			for _, id in draft.screenshots do
				table.insert(shots, { id = id })
			end
			for _, e in draft.exported do
				if can_write then
					table.insert(exports, e)
				elseif e.format == "png" then
					table.insert(shots, { id = e.id, scale = e.scale })
				elseif e.format == "handoff" then
					result.exported = result.exported or {}
					result.exported.notes = { "this Zeron can't write files yet (it needs \"files.write\"): nothing was written. Export the Screens as png and html instead; they come back in the result" }
				end
			end
		end
		if #exports > 0 then
			after("writing the export", function()
				write_exports(d, exports, call and call.cwd, result)
			end)
		end
		if #shots > 0 then
			after("taking screenshots", function()
				local images, notes = screenshots(d, shots)
				if #images > 0 then
					result.imageContent = images
				end
				if #notes > 0 then
					result.screenshot_notes = notes
				end
			end)
		end
		return Guide.first(chat, result)
	end,
})

zeron.tool({
	name = "design_state",
	run = function(_args: any, call: any): any
		local chat = call and call.chat
		local tabs = if chat then Designs.kv_get("tabs:" .. chat) else nil
		local open = {}
		for _, did in (if type(tabs) == "table" then tabs else {}) do
			if Designs.exists(did) then
				local d = held(did)
				local sel = Designs.kv_get("sel:" .. did) or {}
				table.insert(open, { did = did, name = d.name, version = d.version, selection = sel.ids or {} })
			end
		end
		local recent = {}
		for i, r in Designs.list() do
			if i > 10 then
				break
			end
			local sel = Designs.kv_get("sel:" .. r.did) or {}
			table.insert(recent, { did = r.did, name = r.name, version = r.version, selection = if sel.ids and #sel.ids > 0 then sel.ids else nil })
		end
		return Guide.first(chat, { open = open, recent = recent })
	end,
})

zeron.tool({
	name = "design_guide",
	run = function(args: any, call: any): any
		return Guide.topic(args.topic, call and call.chat)
	end,
})

print("design-pure service loaded")

return M
