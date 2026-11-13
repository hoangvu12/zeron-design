--!nonstrict
-- design_execute: an agent's Luau snippet run with zeron.eval against a
-- Draft of the Design, with the JS API's names (Insert, Get, Update, â€¦).
-- A call is one undo step; when it fails nothing changes, and the agent
-- can retry with find-and-replace edits to the failed snippet (editId).

local U = require("./util")
local Edit = require("./edit")
local Designs = require("./designs")
local Export = require("./export")
local Resolve = require("./resolve")
local Layout = require("./layout")

local M = {}

-- name, weight → { vb, parts }: the service's icon cache, for HTML exports.
M.icons = nil :: any

M.BUDGET_MS = 1500
local MAX_PRINTED = 200
local GLOBALS_MAX = 1048576

local failed_snippets: { [string]: any } = {}

local SAFE = {
	assert = assert, error = error, ipairs = ipairs, next = next, pairs = pairs, pcall = pcall, rawequal = rawequal,
	rawget = rawget, rawlen = rawlen, select = select, tonumber = tonumber, tostring = tostring, type = type,
	typeof = typeof, unpack = table.unpack,
}

local function show(v: any, json: any): string
	if type(v) == "string" then
		return v
	end
	if type(v) == "table" then
		local ok, s = pcall(json.encode, v)
		if ok then
			return s
		end
	end
	return tostring(v)
end

-- Error text from a draft's failure, or a plain error.
local function message(v: any): string
	if type(v) == "table" and v.draft_error then
		return v.draft_error
	end
	return tostring(v)
end

-- The env a snippet sees: Luau's safe builtins and the API over `draft`.
function M.env(draft: any, zeron: any, G: any, chat: string?): any
	local env: any = {
		math = math, string = string, table = table, utf8 = utf8, bit32 = bit32,
		null = U.NULL, Infinity = math.huge, G = G,
	}
	for k, v in SAFE do
		env[k] = v
	end
	local function id_of(v: any): string?
		if v == nil or v == U.NULL then
			return nil
		end
		if type(v) == "table" and type(v.id) == "string" then
			return v.id
		end
		return tostring(v)
	end
	-- An API function: its errors name the op and, when its first argument
	-- is a node that's there, that node's path of names; the snippet's line
	-- comes from error level 2 (the line that called it).
	local function api(op: string, f: any): any
		return function(...)
			local r = table.pack(pcall(f, ...))
			if r[1] then
				return table.unpack(r, 2, r.n)
			end
			local msg = message(r[2])
			if string.match(msg, "^agent:%d+: ") then
				-- raised by snippet code this op called back (a visitor): keep its line
				error(msg, 0)
			end
			if string.sub(msg, 1, #op + 1) ~= op .. ":" and string.sub(msg, 1, #op + 1) ~= op .. " " then
				msg = op .. ": " .. msg
			end
			local first = (...)
			local path = nil
			if type(first) == "string" or (type(first) == "table" and type(first.id) == "string") then
				local ok, p = pcall(draft.path, draft, id_of(first) :: string)
				path = if ok then p else nil
			end
			draft.failed_at = { op = op, path = path }
			if path then
				msg ..= ` (at {path})`
			end
			error(msg, 2)
		end
	end
	local function made(id: string): string
		table.insert(draft.returned, id)
		return id
	end
	-- Who is building: a node this call marks `inProgress = true` records
	-- the calling chat in `inProgressBy` (the tab names it); clearing
	-- `inProgress` clears it. `stamp` walks inline children too.
	local function mark(t: any)
		if t.inProgress == true and chat then
			t.inProgressBy = chat
		elseif t.inProgress == false or t.inProgress == U.NULL then
			t.inProgressBy = U.NULL
		end
	end
	local function stamp(t: any, depth: number?)
		if type(t) ~= "table" or (depth or 0) > 48 then
			return
		end
		mark(t)
		if type(t.children) == "table" then
			for _, c in t.children do
				stamp(c, (depth or 0) + 1)
			end
		end
	end
	env.Insert = api("Insert", function(parent: any, node: any)
		if node == nil then
			node, parent = parent, nil
		end
		stamp(node)
		return made(draft:insert(id_of(parent), node))
	end)
	env.Update = api("Update", function(id: any, props: any, opts: any)
		if type(props) == "table" then
			mark(props)
		end
		draft:update(id_of(id) :: string, props, type(opts) == "table" and opts.replace == true)
	end)
	env.Copy = api("Copy", function(id: any, parent: any, props: any)
		if type(props) == "table" then
			mark(props)
		end
		return made(draft:copy(id_of(id) :: string, id_of(parent), props))
	end)
	env.Replace = api("Replace", function(id: any, node: any)
		stamp(node)
		return made(draft:replace(id_of(id) :: string, node))
	end)
	env.FindByName = api("FindByName", function(name: any, root: any)
		return draft:find_by_name(tostring(name), id_of(root))[1]
	end)
	env.FindAll = api("FindAll", function(pred: any, root: any)
		if type(pred) ~= "function" then
			draft:fail("FindAll takes a function(node, info) that returns true for the nodes to keep")
		end
		local out = {}
		draft:visit(id_of(root), function(node, info)
			if pred(node, info) then
				table.insert(out, node.id)
			end
			return nil
		end)
		return out
	end)
	env.CheckFits = api("CheckFits", function(id: any, w: any, h: any)
		if type(w) == "table" then
			w, h = w.width, w.height
		end
		if type(w) ~= "number" then
			draft:fail("CheckFits takes the viewport's width (and height): CheckFits(id, 1440, 900)")
		end
		return draft:fits(id_of(id) :: string, w, if type(h) == "number" then h else nil)
	end)
	env.Move = api("Move", function(id: any, parent: any, index: any)
		draft:move(id_of(id) :: string, id_of(parent), if type(index) == "number" then index else nil)
	end)
	env.Delete = api("Delete", function(ids: any)
		if type(ids) ~= "table" or ids.id ~= nil then
			ids = { ids }
		end
		local list = {}
		for _, v in ids do
			table.insert(list, id_of(v))
		end
		draft:delete(list)
	end)
	env.Get = api("Get", function(id: any, opts: any, visiting: any)
		if type(id) == "function" or (type(id) == "table" and id.id == nil) then
			visiting, opts, id = opts, id, nil
		end
		if type(opts) == "function" then
			draft:visit(id_of(id), opts)
			return nil
		end
		return draft:get(id_of(id), opts)
	end)
	env.SetTokens = api("SetTokens", function(tokens: any, opts: any)
		draft:set_tokens(tokens, type(opts) == "table" and opts.replace == true)
	end)
	env.GetTokens = api("GetTokens", function(opts: any)
		return { tokens = U.deep_copy(draft.d.doc.tokens or {}), themes = U.deep_copy(draft.d.doc.themes or {}) }
	end)
	env.SetThemes = api("SetThemes", function(axis: any, values: any)
		draft:set_themes(tostring(axis), values)
	end)
	env.FindEmptySpace = api("FindEmptySpace", function(w: any)
		if type(w) == "table" and w.from ~= nil then
			w = table.clone(w)
			w.from = id_of(w.from)
		end
		return draft:empty_space(w)
	end)
	env.TakeScreenshot = api("TakeScreenshot", function(ids: any)
		if type(ids) ~= "table" or ids.id ~= nil then
			ids = { ids }
		end
		for _, v in ids do
			local id = id_of(v) :: string
			if Edit.is_inside(id) then
				if not draft:resolved_find(id) then
					draft:fail(`no node has the id "{id}"`)
				end
			elseif not draft:find(id) then
				draft:fail(`no node has the id "{id}"`)
			end
			table.insert(draft.screenshots, id)
		end
	end)
	env.Export = api("Export", function(ids: any, opts: any)
		if opts == nil and type(ids) == "table" and ids[1] == nil and ids.id == nil then
			opts, ids = ids, {}
		end
		opts = if type(opts) == "table" then opts else {}
		local list = {}
		if ids ~= nil and ids ~= U.NULL then
			if type(ids) ~= "table" or ids.id ~= nil then
				ids = { ids }
			end
			for _, v in ids do
				table.insert(list, id_of(v) :: string)
			end
		end
		local format = opts.format or "png"
		-- Written to files (engine/handoff.luau): into `folder`, else the
		-- chat's folder (design-exports/<Design>/) or the Design's folder in
		-- Documents; `inline = true` also puts the PNGs / HTML in the result.
		if opts.folder ~= nil and type(opts.folder) ~= "string" then
			draft:fail("Export's folder is a path (text)")
		end
		local folder, inline = opts.folder, opts.inline == true
		if format == "html" then
			local html = Export.html(draft.d.doc, list, { css = opts.css, scaffold = opts.scaffold, layerNames = opts.layerNames, icons = M.icons })
			table.insert(draft.exported, { format = "html", css = opts.css or "css", html = html, ids = list, folder = folder, inline = inline })
			return { "html" }
		elseif format == "png" then
			if #list == 0 then
				draft:fail("Export png needs the ids of the nodes to picture")
			end
			local scale = if type(opts.scale) == "number" then math.clamp(opts.scale, 0.1, 8) else 2
			for _, id in list do
				if not draft:find(string.match(id, "^([^/]+)") or id) then
					draft:fail(`no node has the id "{id}"`)
				end
				table.insert(draft.exported, { format = "png", id = id, scale = scale, folder = folder, inline = inline })
			end
			return list
		elseif format == "handoff" then
			-- Every board (or the boards in `ids`): PNGs, index.html, tokens.json.
			for _, id in list do
				if not draft:find(id) then
					draft:fail(`no node has the id "{id}"`)
				end
			end
			local scale = if type(opts.scale) == "number" then math.clamp(opts.scale, 0.1, 4) else 2
			table.insert(draft.exported, { format = "handoff", ids = list, scale = scale, folder = folder, css = opts.css, from = opts.from, inline = inline })
			return { "handoff" }
		end
		draft:fail(`Export's format is "png", "html" or "handoff", not "{tostring(format)}"`)
		return nil
	end)
	env.Print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[i] = show((select(i, ...)), zeron.json)
		end
		if #draft.printed < MAX_PRINTED then
			draft:print(table.concat(parts, " "))
		end
	end
	env.print = env.Print
	return env
end

local function apply_edits(snippet: string, edits: any): (string?, string?)
	local s = snippet
	for i, e in U.list(edits) do
		if type(e) ~= "table" or type(e.find) ~= "string" then
			return nil, `edit {i} needs a "find" string`
		end
		local at = string.find(s, e.find, 1, true)
		if not at then
			return nil, `edit {i}: its find text isn't in the snippet`
		end
		if string.find(s, e.find, at + 1, true) then
			return nil, `edit {i}: its find text appears more than once; make it longer`
		end
		s = string.sub(s, 1, at - 1) .. tostring(e.replace or "") .. string.sub(s, at + #e.find)
	end
	return s, nil
end

local function line_of(err: string): number?
	local l = string.match(err, "^agent:(%d+):")
	return if l then tonumber(l) else nil
end

-- Top-level frames that overlap after a call: each root `touched` (whose v
-- the call moved, so also those resized through a Component) against every
-- other top-level frame. Only roots whose v moved are laid out again; the
-- rest keep their box from d.root_boxes. One warning, or nil.
local OVERLAPS_SHOWN = 6
function M.overlaps(d: any, touched: { [string]: number }): any?
	if next(touched) == nil then
		return nil
	end
	d.root_boxes = d.root_boxes or {}
	local cache = d.root_boxes
	local stale, present = {}, {}
	for _, n in d.doc.children do
		if type(n) == "table" and (n.type == "frame" or n.type == "instance") and n.enabled ~= false then
			present[n.id] = n
			local c = cache[n.id]
			if not c or c.v ~= (d.rootv[n.id] or -1) then
				table.insert(stale, n.id)
			end
		end
	end
	if #stale > 0 then
		local r = Resolve.new(d.doc, d.view_theme)
		local roots = r:roots(d.doc, stale)
		Layout.run(roots)
		for _, n in roots do
			local b = n.__box
			cache[n.id] = { v = d.rootv[n.id] or -1, x = b.x, y = b.y, w = b.w, h = b.h }
		end
	end
	local pairs_, seen = {}, {}
	for id in touched do
		local a = present[id] and cache[id]
		if a and a.w > 0 and a.h > 0 then
			for other in present do
				local b = cache[other]
				local key = if id < other then id .. "|" .. other else other .. "|" .. id
				if other ~= id and b and not seen[key] then
					local w = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
					local h = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
					if w > 0.5 and h > 0.5 then
						seen[key] = true
						table.insert(pairs_, `"{tostring(present[id].name)}" ({id}) and "{tostring(present[other].name)}" ({other}) by {math.floor(w + 0.5)}×{math.floor(h + 0.5)}`)
					end
				end
			end
		end
	end
	for id in cache do
		if not present[id] then
			cache[id] = nil
		end
	end
	if #pairs_ == 0 then
		return nil
	end
	table.sort(pairs_)
	local shown = {}
	for i = 1, math.min(#pairs_, OVERLAPS_SHOWN) do
		shown[i] = pairs_[i]
	end
	local more = if #pairs_ > OVERLAPS_SHOWN then `, and {#pairs_ - OVERLAPS_SHOWN} more` else ""
	return { lint = "overlap", message = `{#pairs_} top-level frames overlap others: {table.concat(shown, "; ")}{more}. Move one clear with FindEmptySpace (a fit_content Screen that grew pushes into the Screens below it)` }
end

local function edit_id(): string
	return "e" .. U.new_id(failed_snippets)
end

-- The failure result: the error with its line, op and path, and an editId
-- to retry the snippet with edits.
local function failure(d: any, snippet: string, description: string, chat: string?, msg: string, ran_ms: number, at: any?): any
	local id = edit_id()
	failed_snippets[id] = { snippet = snippet, description = description, did = d.did, chat = chat }
	-- The likeliest mistake: JavaScript where Luau goes.
	local js = string.find(snippet, "%w%s*:%s*[\"'%d%[{]") ~= nil and string.find(snippet, "[{,]%s*[%a_][%w_]*%s*:") ~= nil
		or string.find(snippet, "=>", 1, true) ~= nil
		or string.find(snippet, "const ", 1, true) ~= nil
		or string.find(snippet, "let ", 1, true) ~= nil
	if js and not string.find(msg, "time budget", 1, true) then
		msg ..= " (snippets are Luau, not JavaScript: { key = value }, local x = …, function(a) … end, lists from 1)"
	end
	local r: any = { error = (string.gsub(msg, "^agent:%d+: ", "")), line = line_of(msg), code = if string.find(msg, "time budget", 1, true) then "timed_out" else "failed", editId = id, design = { name = d.name, did = d.did }, ran_ms = math.floor(ran_ms) }
	if at then
		r.op = at.op
		r.path = at.path
	end
	return r
end
M.failure = failure

-- The ids a snippet asked for: strings in G or in what it returned.
local function asked(v: any, out: { [string]: boolean }, depth: number)
	if type(v) == "string" then
		out[v] = true
	elseif type(v) == "table" and depth < 6 then
		for _, x in v do
			asked(x, out, depth + 1)
		end
	end
end

-- Runs one design_execute call on the held Design `d`. Returns the result
-- (a table for the agent) and, when it committed, the commit and draft.
-- `opts.verbose`: every new node's id in `ids`, not only the ones asked for.
function M.execute(zeron: any, d: any, snippet: string, description: string, chat: string?, opts: any?): (any, any?, any?)
	opts = opts or {}
	local key = "G:" .. (chat or "none")
	local G = Designs.kv_get(key) or {}
	local draft = Edit.draft(d)
	local env = M.env(draft, zeron, G, chat)
	local t0 = os.clock()
	local ran = table.pack(zeron.eval(snippet, { name = "agent", env = env, budget_ms = M.BUDGET_MS }))
	local ok, err = ran[1], ran[2]
	local ran_ms = (os.clock() - t0) * 1000
	if not ok then
		Designs.rollback(d)
		local msg = message(err)
		local at = draft.failed_at
		-- only when the error is the op's own (not a later plain Luau error)
		if at and not string.find(msg, at.op, 1, true) then
			at = nil
		end
		return failure(d, snippet, description, chat, msg, ran_ms, at)
	end
	local t1 = os.clock()
	local fine, names = pcall(draft.finish, draft)
	if not fine then
		Designs.rollback(d)
		return failure(d, snippet, description, chat, "checking the result failed: " .. message(names), ran_ms, nil)
	end
	local flash = draft:outermost(64)
	local t2 = os.clock()
	local committed = Designs.commit(d, description, "agent", chat)
	if committed then
		local ok_o, w = pcall(M.overlaps, d, committed.roots)
		if ok_o and w then
			table.insert(draft.warnings, w)
		end
	end
	local t3 = os.clock()
	-- Globals: JSON-able only, 1 MB at most, only from calls that succeed.
	local gok, gjson = pcall(zeron.json.encode, G)
	if gok and #gjson <= GLOBALS_MAX then
		Designs.kv_set(key, G)
	end
	-- Quiet ids: what Insert/Copy/Replace returned and what the snippet kept
	-- in G or returned; every new node's id with verbose.
	local total = 0
	for _ in names do
		total += 1
	end
	local ids = names
	if opts.verbose ~= true then
		local want: { [string]: boolean } = {}
		for _, id in draft.returned do
			want[id] = true
		end
		asked(G, want, 0)
		for i = 2, ran.n do
			asked(ran[i], want, 0)
		end
		-- named among themselves: "Pricing", not "Pricing 2" because a
		-- nav label also called Pricing went unlisted
		local alive = {}
		for _, id in names do
			alive[id] = true
		end
		ids = {}
		for _, m in draft.created do
			if want[m.id] and alive[m.id] then
				local k, n = m.name, 1
				while ids[k] ~= nil do
					n += 1
					k = m.name .. " " .. n
				end
				ids[k] = m.id
			end
		end
	end
	local result: any = {
		design = { name = d.name, did = d.did },
		version = d.version,
		ms = { run = math.floor(ran_ms), check = math.floor((t2 - t1) * 1000), save = math.floor((t3 - t2) * 1000) },
	}
	if total > 0 then
		result.ids = ids
		result.made = total
	end
	if ran.n >= 2 then
		local values = {}
		for i = 2, ran.n do
			values[i - 1] = if ran[i] == nil then U.NULL else ran[i]
		end
		local jok = pcall(zeron.json.encode, values)
		if jok then
			result.returned = if ran.n == 2 then values[1] else values
		end
	end
	if #draft.printed > 0 then
		result.printed = draft.printed
	end
	if #draft.warnings > 0 then
		result.warnings = draft.warnings
	end
	local html = {}
	for _, e in draft.exported do
		if e.format == "html" then
			table.insert(html, e.html)
		end
	end
	if #html > 0 then
		result.exported = { html = html, note = "Design (pure) can't write files itself: put this HTML where it belongs (or the person saves it from the Design tab)" }
	end
	if not committed then
		result.unchanged = true
	end
	return result, committed, draft, flash
end

-- A retry: the failed snippet with `edits` applied.
function M.retried(edit_id_: string, edits: any): (any?, string?)
	local f = failed_snippets[edit_id_]
	if not f then
		return nil, `no failed call has the editId "{edit_id_}" (they're kept until the service restarts): send the whole snippet again`
	end
	local s, why = apply_edits(f.snippet, edits)
	if not s then
		return nil, why
	end
	failed_snippets[edit_id_] = nil
	return { snippet = s, description = f.description, did = f.did }, nil
end

return M