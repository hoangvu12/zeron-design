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
local Proto = require("./proto")
local Sim = require("./sim")
local Scene = require("./scene")
local Vars = require("./vars")
local Expr = require("./expr")
local Comments = require("./comments")
local Smart = require("../tab/smart")

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
		local nid = draft:insert(id_of(parent), node)
		-- (B1) a layer made turned is turned about its centre: x, y are where
		-- it sits unturned (draw, then rotate, as in Figma)
		local turns = {}
		local f = draft:find(nid)
		Resolve.walk(if f then { f.node } else {}, function(n)
			if U.num(n.rotation, 0) ~= 0 then
				table.insert(turns, { id = n.id, old = 0 })
			end
			return true
		end)
		if #turns > 0 then
			draft:turn_about_centre(turns)
		end
		return made(nid)
	end)
	env.Update = api("Update", function(id: any, props: any, opts: any)
		if type(props) == "table" then
			mark(props)
		end
		local sid = id_of(id) :: string
		local before = type(props) == "table" and props.rotation ~= nil and type(sid) == "string" and draft:find(sid)
		local old = if before then U.num(before.node.rotation, 0) else nil
		draft:update(sid, props, type(opts) == "table" and opts.replace == true)
		if old ~= nil then
			draft:turn_about_centre({ { id = sid, old = old } })
		end
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
	-- (step 5) Prototype variables are Tokens. SetVars{ count = 0, isOpen =
	-- false, name = "Ann", accent = "#EF4444" } infers each type (a variable
	-- already there keeps its own); a value per mode is a list of { value,
	-- theme = { axis = "mode" } }; null deletes.
	env.SetVars = api("SetVars", function(list: any)
		if type(list) ~= "table" or list[1] ~= nil or list.id ~= nil then
			draft:fail("SetVars takes variables by name: SetVars({ count = 0, isOpen = false, name = \"Ann\" })")
		end
		local cur = Vars.tokens(draft.d.doc)
		local out = {}
		for name, v in list do
			if type(name) ~= "string" then
				draft:fail(`SetVars: "{tostring(name)}" isn't a name`)
			end
			if U.is_null(v) then
				out[name] = U.NULL
				continue
			end
			local cands: { any }? = nil
			if type(v) == "table" then
				if v.type ~= nil then
					draft:fail(`SetVars: "{name}" is a value (or a list of \{ value, theme \}); for a whole Token use SetTokens`)
				end
				cands = if v.value ~= nil then { v } elseif v[1] ~= nil then v else nil
				if not cands then
					draft:fail(`SetVars: "{name}" is a number, text, true / false, a colour "#RRGGBB", or a list of \{ value, theme = \{ axis = "mode" \} \}`)
				end
			end
			local first = if cands then (if type(cands[1]) == "table" then cands[1].value else nil) else v
			local kind = cur[name] and cur[name].kind
			if not kind then
				if type(first) == "boolean" then
					kind = "boolean"
				elseif type(first) == "number" then
					kind = "number"
				elseif type(first) == "string" then
					kind = if string.sub(first, 1, 1) == "#" and U.color(first) then "color" else "string"
				else
					draft:fail(`SetVars: "{name}" = {tostring(first)}: a variable is a number, text, true / false or a colour "#RRGGBB"`)
				end
			end
			local function typed(x: any): any
				local got, why = Vars.coerce(kind :: string, x)
				if got == nil then
					draft:fail(`SetVars: "{name}" is a {kind} variable: {why}`)
				end
				return got
			end
			if cands then
				local value = {}
				for i, c in cands do
					if type(c) ~= "table" or c.value == nil then
						draft:fail(`SetVars: "{name}"[{i}] is \{ value, theme = \{ axis = "mode" \} \}`)
					end
					local th = c.theme
					if th ~= nil and type(th) ~= "table" then
						draft:fail(`SetVars: "{name}"[{i}].theme is \{ axis = "mode" \}`)
					end
					table.insert(value, { value = typed(c.value), theme = U.deep_copy(th or {}) })
				end
				out[name] = { type = kind, value = value }
			else
				out[name] = { type = kind, value = typed(v) }
			end
		end
		draft:set_tokens(out)
	end)
	-- { [name] = { type, value (in the Design's default modes), values? (each
	-- mode's: { value, theme }) } }, or one variable's when named.
	env.GetVars = api("GetVars", function(one: any)
		local toks = Vars.tokens(draft.d.doc)
		local theme = Vars.theme(draft.d.doc.themes, draft.d.view_theme, nil, nil)
		local function row(t: any): any
			local v = Resolve.value_in(t, theme)
			local r: any = { type = t.kind, value = v }
			if #t.values > 1 or next(t.values[1].theme or {}) ~= nil then
				r.values = U.deep_copy(t.values)
			end
			return r
		end
		if one ~= nil then
			local t = toks[tostring(one)]
			if not t then
				draft:fail(`the Design has no variable (Token) "{tostring(one)}"`)
			end
			return row(t)
		end
		local out = {}
		for name, t in toks do
			out[name] = row(t)
		end
		return out
	end)
	-- Runs an expression, as a set or an if would: Eval("{count + 1}", {
	-- count = 2 }) → 3, problems? The values given win; other names read the
	-- Design's variables (in its default modes, or `opts.mode`).
	env.Eval = api("Eval", function(src: any, values: any, opts: any)
		if type(src) ~= "string" then
			draft:fail("Eval takes an expression, as Eval(\"{count + 1}\", { count = 2 })")
		end
		local ast, why = Expr.parse(src)
		if not ast then
			draft:fail(`{src}: {why}`)
		end
		values = if type(values) == "table" then values else {}
		local toks = Vars.tokens(draft.d.doc)
		local themes = draft.d.doc.themes or {}
		local mode = if type(opts) == "table" and type(opts.mode) == "table" then opts.mode else nil
		local ctx = { toks = toks, vars = {}, themes = themes, theme = Vars.theme(themes, draft.d.view_theme, mode, nil) }
		local get = Vars.getter(ctx)
		local problems = {}
		local fn = Expr.compile(src) :: any
		local v = fn(function(name: string, axis: string?, m: string?): any
			if m then
				local k = name .. ":" .. (if axis then axis .. "=" else "") .. m
				if values[k] ~= nil then
					return values[k]
				end
			end
			if values[name] ~= nil then
				return values[name]
			end
			if not toks[name] then
				table.insert(problems, `var-unknown: the Design has no variable (Token) "{name}"`)
				return nil
			end
			return get(name, axis, m)
		end, function(code: string, msg: string)
			table.insert(problems, `{code}: {msg}`)
		end)
		if #problems > 0 then
			return v, problems
		end
		return v
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
	env.TakeScreenshot = api("TakeScreenshot", function(ids: any, opts: any)
		if type(ids) ~= "table" or ids.id ~= nil then
			ids = { ids }
		end
		-- { state = "hover" | "press" }: the node drawn in that state (its own
		-- or the nearest node above it that has states drives it)
		local state = type(opts) == "table" and opts.state or nil
		if state ~= nil and not Proto.STATES[state] then
			draft:fail(`TakeScreenshot's state is "hover" or "press", not {tostring(state)}`)
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
			table.insert(draft.screenshots, if state then { id = id, state = state } else id)
		end
	end)
	-- Prototyping: a click link from a layer to a Screen, `back` or a URL.
	local function link_impl(from: any, to: any, transition: any, opts: any)
		local id = id_of(from)
		if type(id) ~= "string" then
			draft:fail("Link takes the layer to click, then a Screen id, \"back\" or a URL")
		end
		if
			type(transition) == "table"
			and opts == nil
			and transition.type == nil
			and (transition.replace ~= nil or transition.trigger ~= nil or transition.append ~= nil or transition.easing ~= nil or transition.duration ~= nil)
		then
			opts, transition = transition, nil
		end
		-- (step 4) Link(layer, { On = "true" }): the variant of the set the
		-- layer's Component is in, with those props
		if type(to) == "table" and to.id == nil and next(to) ~= nil and to[1] == nil then
			local top = string.match(id, "^([^/]+)") or id
			local f = draft:find(top)
			while f and f.parent do
				f = draft:find(f.parent.id)
			end
			local vs = Proto.variant_sets(draft.d.doc)
			local set = f and vs.of[f.node.id]
			if not set then
				draft:fail("Link(layer, { prop = value }) changes the variant of the set the layer's Component is in, and this layer is in no variant set's Component: link to a variant's id (Variant(set, props))")
			end
			local found = Proto.variant_find(vs, set :: string, to, vs.sets[set].props[f.node.id])
			if not found then
				draft:fail(`Link: the set "{set}" has no variant with those props`)
			end
			to = found
		end
		local target = if type(to) == "string" then to else id_of(to)
		if type(target) ~= "string" or target == "" then
			draft:fail("Link needs where to go: a Screen id, \"back\" or an http(s) URL")
		end
		local tr, why = Proto.expand(transition)
		if why then
			draft:fail(why)
		end
		-- opts: trigger (a name or { type, … }; "click"), easing and duration
		-- (over the transition's), append = true (add to the reaction with
		-- this trigger: it runs after what's there), replace = true.
		opts = if type(opts) == "table" then opts else {}
		local trigger = if opts.trigger ~= nil then U.deep_copy(opts.trigger) else "click"
		Proto.check_trigger(trigger, "Link's trigger", function(msg)
			draft:fail(msg)
		end)
		local tname = Proto.trigger_name(trigger)
		if (opts.easing ~= nil or opts.duration ~= nil) and tr and tr.type ~= "instant" then
			tr = table.clone(tr)
			if opts.easing ~= nil then
				tr.easing = U.deep_copy(opts.easing)
			end
			if opts.duration ~= nil then
				tr.duration = opts.duration
			end
		elseif (opts.easing ~= nil or opts.duration ~= nil) and not tr then
			tr = { type = "dissolve", duration = opts.duration or Proto.DEFAULT_MS, easing = U.deep_copy(opts.easing or "ease-out") }
		end
		-- (B1) a spring times itself (Figma's physics springs: mass, stiffness
		-- and damping decide it), so a duration given with one does nothing
		local asked = if opts.duration ~= nil then opts.duration elseif type(transition) == "table" then transition.duration else nil
		local sp = tr and Proto.spring_of(tr.easing)
		if type(asked) == "number" and sp then
			local _, settle = Proto.spring(sp)
			local own = math.floor(settle * 1000 + 0.5)
			if math.abs(own - asked) > math.max(50, own * 0.1) then
				-- (one warning per call: the links listed, up to 6)
				local sd = draft.__spring_dur
				if not sd then
					sd = { list = {}, w = { lint = "spring-duration", message = "" } }
					draft.__spring_dur = sd
					table.insert(draft.warnings, sd.w)
				end
				table.insert(sd.list, `{id} {asked} → {own} ms`)
				local shown = table.concat(sd.list, "; ", 1, math.min(#sd.list, 6))
				local more = if #sd.list > 6 then `, and {#sd.list - 6} more` else ""
				sd.w.message = `{#sd.list} spring link{if #sd.list == 1 then "" else "s"} with a duration that's ignored: a spring takes its own time, as in Figma ({shown}{more}). For a faster one raise stiffness (\{ spring = \{ mass, stiffness, damping \} \}) or pick "quick"; for a set time use a curve like "ease-out"`
			end
		end
		local action
		if target == "back" then
			action = { action = "back", transition = tr }
		elseif target == "close" then
			-- (overlays, step 2) closes the top overlay; no transition = its opening backwards
			action = { action = "close", transition = tr }
		elseif opts.overlay == true or opts.swap == true then
			action = { action = if opts.swap == true then "swap" else "overlay", to = target, transition = tr }
			if opts.overlay == true and opts.position ~= nil then
				action.position = opts.position
			end
			if opts.overlay == true and opts.offset ~= nil then
				action.offset = U.deep_copy(opts.offset)
				action.position = action.position or "manual"
			end
		elseif string.match(target, "^https?://") or string.match(target, "^mailto:") then
			action = { action = "url", url = target, newTab = true }
		elseif Proto.variant_sets(draft.d.doc).of[target] then
			-- (step 4) a link to a variant is a Change to
			if tr and not Proto.CHANGE_TYPES[tr.type] then
				draft:fail(`Link to a variant changes the Instance in place: its transition is "instant", "dissolve" or "smart", not {tostring(tr.type)}`)
			end
			action = { action = "changeTo", to = target, transition = tr }
		else
			action = { action = "navigate", to = target, transition = tr }
		end
		-- the reactions it has now, as written (an Instance's inner node: as drawn)
		-- (an Instance's inherited click links give way to its own, as in Figma)
		local now, inherited = nil, false
		if Edit.is_inside(id) then
			local r = draft:resolved_find(id, { keep_disabled = true, keep_tokens = true })
			if not r then
				draft:missing(id)
			end
			now = r.interactions
			inherited = r.__inh_ia == true
		else
			local f = draft:find(id)
			if not f then
				draft:missing(id)
			end
			now = f.node.interactions
			if now == nil and f.node.type == "instance" then
				local r = draft:resolved_find(id, { keep_disabled = true, keep_tokens = true })
				now = r and r.interactions
				inherited = r ~= nil and r.__inh_ia == true
			end
		end
		local list = {}
		local into = nil
		for _, r in U.list(now) do
			if type(r) == "table" and not ((inherited or opts.replace == true) and Proto.trigger_name(r.trigger) == tname) then
				local copy = U.deep_copy(r)
				table.insert(list, copy)
				if opts.append == true and not into and Proto.trigger_name(r.trigger) == tname then
					into = copy
				end
			end
		end
		if into then
			into.actions = into.actions or {}
			table.insert(into.actions, action)
		else
			table.insert(list, { trigger = trigger, actions = { action } })
		end
		draft:update(id, { interactions = list })
	end
	env.Link = api("Link", link_impl)
	-- Interactive components (step 4): MakeVariants(set, { { props, node }, … })
	-- makes (or joins) a variant set. `node` is a Component's or a top-level
	-- frame's id (it becomes a Component), or a node table (inserted at the
	-- top level as a Component). Returns the members' ids, in order.
	env.MakeVariants = api("MakeVariants", function(set: any, list: any)
		if type(set) ~= "string" or string.match(set, "^%s*$") then
			draft:fail("MakeVariants takes the set's name, then a list of { props = { On = \"false\" }, node = id or node }")
		end
		if type(list) ~= "table" or #list < 1 then
			draft:fail("MakeVariants(set, list): list is { { props = { On = \"false\" }, node = … }, … }, one entry per variant")
		end
		local ids = {}
		for i, e in list do
			if type(e) ~= "table" or type(e.props) ~= "table" or e.node == nil then
				draft:fail(`MakeVariants: entry {i} is \{ props = \{ On = "false" \}, node = id or node \}`)
			end
			local props = {}
			for k, v in e.props do
				props[k] = Proto.prop_value(v) or v
			end
			local nid
			if type(e.node) == "table" and e.node.type ~= nil and e.node.id == nil then
				local n = U.deep_copy(e.node)
				n.reusable = true
				n.variant = { set = set, props = props }
				stamp(n)
				nid = made(draft:insert(nil, n))
			else
				nid = id_of(e.node)
				local f = type(nid) == "string" and draft:find(nid)
				if not f then
					draft:fail(`MakeVariants: entry {i}'s node "{tostring(nid)}" isn't in the Design`)
				end
				if f.parent ~= nil or f.node.type ~= "frame" then
					draft:fail(`MakeVariants: entry {i}'s node "{tostring(f.node.name)}" is a {tostring(f.node.type)}{if f.parent then " inside another node" else ""}: a variant is a top-level frame (a Component)`)
				end
				draft:update(nid, { reusable = true, variant = { set = set, props = props } })
			end
			table.insert(ids, nid)
		end
		return ids
	end)
	-- The id of set's variant with these props (the closest: every prop
	-- given matches). Fails when there's none.
	env.Variant = api("Variant", function(set: any, props: any)
		local vs = Proto.variant_sets(draft.d.doc)
		if type(set) ~= "string" or not vs.sets[set] then
			local names = {}
			for k in vs.sets do
				table.insert(names, `"{k}"`)
			end
			table.sort(names)
			draft:fail(`Variant: no variant set "{tostring(set)}"` .. (if #names > 0 then ` (sets: {table.concat(names, ", ")})` else " (MakeVariants makes one)"))
		end
		local found = Proto.variant_find(vs, set, if type(props) == "table" then props else {}, nil)
		if not found then
			draft:fail(`Variant: the set "{set}" has no variant with those props`)
		end
		return found
	end)
	-- Overlays (step 2): Overlay(trigger, frame, opts?) opens `frame` over the
	-- Screen when `trigger` is clicked (or opts.trigger). opts: transition
	-- (a table or "dissolve", "move-in-up", "slide-in-left" …), position
	-- ("center", "top", "bottom-right" … or "manual" with offset = { x, y }
	-- from the trigger's top-left), swap = true (replace the top overlay),
	-- trigger, append, replace, easing, duration as Link's; background =
	-- { color, opacity } | false and closeOutside go on the frame's overlay
	-- settings (every action that opens it uses them).
	env.Overlay = api("Overlay", function(from: any, frame: any, opts: any)
		opts = if type(opts) == "table" then table.clone(opts) else {}
		local fid = if type(frame) == "string" then frame else id_of(frame)
		if type(fid) ~= "string" or fid == "" then
			draft:fail("Overlay takes the layer that opens it, then the top-level frame to open")
		end
		if opts.background ~= nil or opts.closeOutside ~= nil then
			local f = draft:find(fid)
			if not f or f.parent ~= nil then
				draft:fail(`Overlay: "{fid}" isn't a top-level frame`)
			end
			local now = if type(f.node.overlay) == "table" then U.deep_copy(f.node.overlay) else {}
			if opts.background ~= nil then
				now.background = U.deep_copy(opts.background)
			end
			if opts.closeOutside ~= nil then
				now.closeOutside = opts.closeOutside
			end
			draft:update(fid, { overlay = now })
		end
		local tr = opts.transition
		local link_opts = {
			trigger = opts.trigger, append = opts.append, replace = opts.replace, easing = opts.easing, duration = opts.duration,
			position = opts.position, offset = opts.offset,
		}
		if opts.swap == true then
			link_opts.swap = true
		else
			link_opts.overlay = true
		end
		link_impl(from, fid, tr or "dissolve", link_opts)
	end)
	env.SetFlows = api("SetFlows", function(list: any)
		if type(list) == "table" then
			local clean = {}
			for i, f in list do
				if type(f) == "table" then
					clean[i] = { name = f.name, start = id_of(f.start), description = f.description }
				else
					clean[i] = f
				end
			end
			list = clean
		end
		draft:set_flows(list)
	end)
	env.GetFlows = api("GetFlows", function()
		return U.deep_copy(draft.d.doc.flows or {})
	end)
	-- The device Play shows Screens in, and how it fits the window:
	-- { device = "iphone-16" | { w, h }, model? (the frame's colour, one of
	-- the preset's: "Black", "Pink", …), rotate? (landscape), fit? ("fit" |
	-- "width" | "actual" | "fill" | "responsive"), deviceFit? ("fit" |
	-- "fill" | "actual", with a framed preset), showFrame? (false hides the
	-- drawn device), background? }. Keys given replace those set (a new
	-- device drops a model it doesn't offer); nil (or {}) clears them all.
	env.SetPrototype = api("SetPrototype", function(p: any)
		draft:set_prototype(p, true)
	end)
	env.GetPrototype = api("GetPrototype", function()
		return U.deep_copy(draft.d.doc.prototype or {})
	end)
	-- (step 7) Local comments the person left on Screens in Play
	-- (engine/comments.luau). GetComments(opts?) → the open ones ({ all = true }:
	-- resolved too; { screen = id }: one Screen's), each { id, n, screen,
	-- screenName, node, x, y, text, author, replies? }. ResolveComment(id,
	-- note?) and ReplyComment(id, text) happen once the call ran through
	-- (a failed call does nothing to comments).
	local function comment_of(id: any): any
		id = id_of(id)
		for _, t in (draft.comments or {}) do
			if t.id == id or ("#" .. tostring(t.n)) == id or (type(id) == "string" and tonumber(id) == t.n) then
				return t
			end
		end
		draft:fail(`no comment "{tostring(id)}" (ids come from GetComments or design_state)`)
		return nil
	end
	env.GetComments = api("GetComments", function(opts: any)
		opts = if type(opts) == "table" then opts else {}
		local list = Comments.for_agents(draft.comments or {}, draft.d.doc, opts.all == true)
		if type(opts.screen) == "string" then
			local only = {}
			for _, c in list do
				if c.screen == id_of(opts.screen) then
					table.insert(only, c)
				end
			end
			list = only
		end
		return list
	end)
	env.ResolveComment = api("ResolveComment", function(id: any, note: any)
		local t = comment_of(id)
		if note ~= nil and type(note) ~= "string" then
			draft:fail("ResolveComment's note is text (what you changed), or nil")
		end
		table.insert(draft.comment_ops, { action = "resolve", id = t.id, note = note })
		return t.id
	end)
	env.ReplyComment = api("ReplyComment", function(id: any, text: any)
		local t = comment_of(id)
		if type(text) ~= "string" or text == "" then
			draft:fail("ReplyComment needs the reply's words")
		end
		table.insert(draft.comment_ops, { action = "reply", id = t.id, text = text })
		return t.id
	end)
	-- Plays the prototype headless by Play's rules (engine/sim.luau):
	-- Simulate(start?, steps?, opts?) or Simulate({ start, steps, shots,
	-- check }). Returns what's shown after the steps and the problems met;
	-- its screenshots come back with the call's (in the order asked).
	env.Simulate = api("Simulate", function(a: any, b: any, c: any)
		local opts
		if type(a) == "table" and a.id == nil and a[1] == nil and (a.start ~= nil or a.steps ~= nil or a.shots ~= nil or a.check ~= nil or a.vars ~= nil or a.mode ~= nil or next(a) == nil) then
			opts = table.clone(a)
		elseif type(a) == "table" and a[1] ~= nil and (b == nil or (type(b) == "table" and b[1] == nil and b.id == nil)) then
			-- Simulate(steps) or (step 5) Simulate(steps, { vars, mode, … })
			opts = { steps = a }
			for k, v in (if type(b) == "table" then b else {}) do
				opts[k] = v
			end
		else
			opts = { start = id_of(a), steps = b }
			if type(c) == "table" then
				for k, v in c do
					opts[k] = v
				end
			end
		end
		if type(opts.start) == "table" then
			opts.start = id_of(opts.start)
		end
		if opts.shots ~= nil and opts.shots ~= "each" and opts.shots ~= "end" then
			draft:fail(`Simulate's shots is "each" (after every step), "end" or nil (only "shot" steps), not {tostring(opts.shots)}`)
		end
		local screens_ = Proto.screens(draft.d.doc)
		local vsets = Proto.variant_sets(draft.d.doc).of
		local world = Sim.world(draft.d.doc, draft:laid_out(nil), {
			icons = M.icons,
			view_theme = draft.d.view_theme,
			-- (step 4) a Screen resolved with other variants (Change to); (step
			-- 5) `run` = { vars, mode }, the variables at run time
			variant_root = function(id: string, vmap: any, run: any?): any?
				local ok, rs = pcall(draft.laid_out, draft, id, vmap, run)
				local r = ok and rs[1]
				if not r or r.id ~= id then
					return nil
				end
				return { id = id, nodes = Scene.items(r, { screens = screens_, icons = M.icons, vsets = vsets }) }
			end,
		})
		local result, views = Sim.run(world, opts)
		if not result then
			draft:fail(views :: any)
		end
		for _, v in views :: any do
			table.insert(draft.screenshots, { sim = v })
		end
		return result
	end)
	-- Smart Animate (step 3): what pairs between two Screens (or overlays)
	-- by name path or `match`, what fades, and how Play animates it.
	env.CheckSmart = api("CheckSmart", function(a: any, b: any)
		local ia, ib = id_of(a), id_of(b)
		local world = Sim.world(draft.d.doc, draft:laid_out(nil), { icons = M.icons })
		local ra, rb = world.roots[ia :: string], world.roots[ib :: string]
		if not ra or not rb then
			draft:fail(`CheckSmart takes two top-level frames (Screens or overlays): {tostring(ia)}{if ra then "" else " isn't one"}, {tostring(ib)}{if rb then "" else " isn't one"}`)
		end
		local rep = Smart.report(ra.nodes, rb.nodes)
		local out: any = {
			paired = #rep.paired, movers = rep.movers, kinds = rep.kinds,
			pairs = rep.paired, only_from = rep.only_from, only_to = rep.only_to,
		}
		if #rep.paired == 0 then
			out.hint = "nothing pairs, so it all dissolves: Copy the Screen and edit the copy (names stay), or give the two layers the same name or `match` key"
		end
		if rep.over > 0 then
			out.hint = `{rep.over} more pairs than Play animates one by one ({Smart.MAX_MOVERS}): they dissolve`
		end
		-- (long lists cut, as lint does)
		for _, k in { "pairs", "only_from", "only_to" } do
			local l = out[k]
			if #l > 30 then
				local n = #l
				out[k] = table.move(l, 1, 30, 1, {})
				table.insert(out[k], `… and {n - 30} more`)
			end
		end
		return out
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
		-- (f7 share) Export({ share = true }): the whole prototype as one page
		-- to publish as a private Claude artifact (engine/share.luau): written
		-- as <Design>-share.html, its pictures inside.
		if opts.share == true then
			if #list == 0 then
				for _, b in require("./handoff").boards(draft.d.doc) do
					table.insert(list, b.id)
				end
			end
			if #list == 0 then
				draft:fail("Export share needs a Screen to share: this Design has none")
			end
			local html = Export.html(draft.d.doc, list, { css = opts.css, scaffold = true, icons = M.icons, prototype = true })
			table.insert(draft.exported, { format = "share", css = opts.css or "css", html = html, ids = list, folder = folder })
			return { "share" }
		end
		if format == "html" then
			local html = Export.html(draft.d.doc, list, { css = opts.css, scaffold = opts.scaffold, layerNames = opts.layerNames, icons = M.icons, prototype = opts.prototype == true })
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
	-- (step 7) the Design's comments as the call began, and what it does to them
	draft.comments = if type(opts.comments) == "table" then opts.comments else {}
	draft.comment_ops = {}
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