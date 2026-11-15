--!nonstrict
-- Simulate (figma-parity.md §2 "Agents can play/check the prototype", §4):
-- an agent plays its prototype headless, step by step (click, hover, press,
-- key, drag, wait, scroll, back), and gets back what a person would see:
-- the Screen shown, the overlays open, scroll offsets, hover/press looks,
-- timers pending, and the problems it met (dead ends, unreachable Screens,
-- broken links, a trigger that does nothing, a link under another layer).
--
-- It plays by Play's rules (tab/play.luau), over the same scene items Play
-- gets, with Play's own pure parts: tab/proto.luau (hit tests, reactions,
-- key combos, reversed transitions, motion) and tab/scroll.luau (scroll
-- layers, room, offsets, wheel routing, scroll memory, scrollTo's target);
-- overlays as F2c places them (engine/proto.luau `overlay_place`). What's
-- Play's own state machine (history, action lists one after another,
-- revert of hover/press, timers) is mirrored here on a virtual clock, so a
-- run is deterministic: the same Design and steps give the same result.
--
-- Screenshots: a run returns `views` (pure data: the layers shown, their
-- scroll offsets and motion at that moment); the service turns each into
-- one frame of scene items with `M.compose` and draws it through the
-- window's render path, as TakeScreenshot does.

local U = require("./util")
local EProto = require("./proto")
local Scene = require("./scene")
local Draw = require("../tab/draw")
local TProto = require("../tab/proto")
local Scroll = require("../tab/scroll")
local Smart = require("../tab/smart")
local Variants = require("../tab/variants")
local Vars = require("./vars")
local Expr = require("./expr")
local Resolve = require("./resolve")

local M = {}

M.HOVER_GRACE = 100 -- ms: a hover-opened overlay stays while the pointer crosses to it (F2c)
M.MAX_STEPS = 200
M.MAX_EVENTS = 5000 -- a run that never settles (afterDelay 0 loops)
M.MAX_WAIT = 600000
M.MAX_SHOTS = 12

-- ── the Design as Play gets it ──────────────────────────────────────────────

-- `roots`: laid-out resolved roots (Draft:laid_out). Every top-level frame
-- that isn't a Component, as scene items (opts: icons, images for drawing).
function M.world(doc: any, roots: { any }, opts: any?): any
	opts = opts or {}
	local screens = EProto.screens(doc)
	-- (step 4) opts.variant_root(id, vmap, run?) → a Screen resolved with
	-- other variants, { id, nodes }; (step 5) `run` = { vars, mode }, the
	-- variables at run time (engine/vars.luau)
	local w = { roots = {}, order = {}, screens = screens, flows = {}, device = EProto.played_prototype(doc.prototype), variant_root = opts.variant_root }
	local vs = EProto.variant_sets(doc)
	local vsets = vs.of
	-- (step 5) the variables (Tokens), the Themes' modes and the view theme
	w.toks = Vars.tokens(doc)
	w.themes = if type(doc.themes) == "table" then doc.themes else {}
	w.view = opts.view_theme
	w.vsets = vs.sets
	-- (a member's props as text: "On=true", for the result's `components`)
	w.vprops = {}
	for _, s in vs.sets do
		for id, p in s.props do
			local parts = {}
			for k, v in p do
				table.insert(parts, `{k}={v}`)
			end
			table.sort(parts)
			w.vprops[id] = table.concat(parts, ", ")
		end
	end
	for _, f in U.list(doc.flows) do
		if type(f) == "table" and type(f.start) == "string" then
			table.insert(w.flows, { name = tostring(f.name or f.start), start = f.start })
		end
	end
	for _, r in roots do
		if screens[r.id] and r.__box then
			local items = Scene.items(r, { screens = screens, icons = opts.icons, images = opts.images, vsets = vsets })
			w.roots[r.id] = { id = r.id, nodes = items }
			table.insert(w.order, r.id)
		end
	end
	return w
end

-- ── easing (what a frame mid-transition shows) ──────────────────────────────

local function bezier_at(e: any, p: number): number
	local x1, y1, x2, y2 = e[1] or 0, e[2] or 0, e[3] or 0.58, e[4] or 1
	local function bx(u: number): number
		return 3 * (1 - u) ^ 2 * u * x1 + 3 * (1 - u) * u ^ 2 * x2 + u ^ 3
	end
	local function by(u: number): number
		return 3 * (1 - u) ^ 2 * u * y1 + 3 * (1 - u) * u ^ 2 * y2 + u ^ 3
	end
	local lo, hi = 0, 1
	for _ = 1, 40 do
		local mid = (lo + hi) / 2
		if bx(mid) < p then
			lo = mid
		else
			hi = mid
		end
	end
	return by((lo + hi) / 2)
end

-- A played transition's progress at `p` (0..1 of its time): its spring (the
-- engine's solver, as anime's) or its bézier.
function M.ease_at(tr: any?, p: number): number
	p = math.clamp(p, 0, 1)
	if p >= 1 then
		return 1
	end
	if tr and type(tr.sp) == "table" then
		local x, settle = EProto.spring({ mass = tr.sp.m, stiffness = tr.sp.k, damping = tr.sp.c, velocity = tr.sp.v })
		return x(p * settle)
	end
	return bezier_at((tr and tr.ease) or { 0, 0, 0.58, 1 }, p)
end

local function tr_ms(tr: any?): number
	if not tr or tr.k == "instant" then
		return 0
	end
	return math.max(0, tr.ms or 300)
end

local DIR_WORD = { left = "left", right = "right", up = "up", down = "down" }
local function tr_text(tr: any?): string
	if not tr or tr.k == "instant" or tr_ms(tr) == 0 then
		return "instant"
	end
	local k = TProto.KIND_LABEL[tr.k] or tostring(tr.k)
	local dir = if tr.dir then " " .. (DIR_WORD[tr.dir] or tr.dir) else ""
	local ml = if tr.ml then " + smart animate matching layers" else ""
	return `{string.lower(k)}{dir}{ml}, {math.floor(tr_ms(tr) + 0.5)} ms`
end

-- ── steps ──────────────────────────────────────────────────────────────────

local VERBS = {
	click = "click", tap = "click", hover = "hover", leave = "leave", unhover = "leave", press = "press",
	release = "release", drag = "drag", key = "key", wait = "wait", back = "back", restart = "restart",
	scroll = "scroll", shot = "shot", screenshot = "shot", set = "set", mode = "mode",
}
local DRAG_PT = 4 -- (Play's: a press that moves this far is a drag)
local STEP_HELP ="a step is \"click <layer>\", \"hover <layer>\", \"leave\", \"press <layer>\", \"release\", \"drag <layer> [dx dy]\", \"key Enter\" / \"key Ctrl+K\", \"wait 1200\", \"scroll [<layer>] [dx] dy\", \"back\", \"restart\", \"set count=3\", \"mode theme=dark\" or \"shot\" (a table works too: { click = id, shot = 150 })"

-- (step 5) A step's value as written: true / false, a number, '…' or "…"
-- text, "{expr}" (kept as is: the set runs it), else the text itself.
local function step_value(s: string): any
	if s == "true" then
		return true
	elseif s == "false" then
		return false
	end
	local n = tonumber(s)
	if n then
		return n
	end
	local q = string.match(s, "^'(.*)'$") or string.match(s, '^"(.*)"$')
	if q then
		return q
	end
	return s
end

-- "count=3", "count = {count + 1}" → name, value (nil when it isn't one)
local function assignment(rest: string): (string?, string?)
	local name, value = string.match(rest, "^([^=%s]+)%s*=%s*(.-)$")
	if not name or value == "" then
		return nil, nil
	end
	return name, value
end

-- A step as written → { verb, target?, dx?, dy?, ms?, keys?, label?, shot? }.
function M.parse_step(raw: any): (any?, string?)
	if type(raw) == "string" then
		local s = string.gsub(raw, "^%s*(.-)%s*$", "%1")
		local word, rest = string.match(s, "^(%S+)%s*(.*)$")
		local verb = word and VERBS[string.lower(word)]
		if not verb then
			return nil, `"{raw}" isn't a step: {STEP_HELP}`
		end
		local st: any = { verb = verb }
		if verb == "wait" then
			st.ms = tonumber(rest)
			if not st.ms then
				return nil, `"{raw}": wait takes milliseconds, as "wait 1500"`
			end
		elseif verb == "key" then
			if rest == "" then
				return nil, `"{raw}": key takes a key or combo, as "key Enter" or "key Ctrl+K"`
			end
			st.keys = {}
			for part in string.gmatch(rest, "[^%+%s]+") do
				table.insert(st.keys, part)
			end
		elseif verb == "scroll" or verb == "drag" then
			-- trailing numbers: dy, or dx dy
			local nums = {}
			local head = rest
			while true do
				local h, n = string.match(head, "^(.-)%s*(%-?%d+%.?%d*)$")
				if not h or #nums >= 2 then
					break
				end
				table.insert(nums, 1, tonumber(n))
				head = h
			end
			if #nums == 1 then
				st.dx, st.dy = 0, nums[1]
			elseif #nums == 2 then
				st.dx, st.dy = nums[1], nums[2]
			end
			st.target = if head ~= "" then head else nil
			if verb == "scroll" and not st.dy then
				return nil, `"{raw}": scroll takes how far, as "scroll 400" (down) or "scroll Stories 300 0" (sideways)`
			end
		elseif verb == "shot" then
			st.label = if rest ~= "" then rest else nil
		elseif verb == "set" or verb == "mode" then
			-- (step 5) "set count=3", "set name='Ann'", "set n={n + 1}"; "mode theme=dark"
			local name, value = assignment(rest)
			if not name then
				return nil, if verb == "set" then `"{raw}": set takes a variable and a value, as "set count=3" or "set count=\{count + 1\}"` else `"{raw}": mode takes an axis and a value, as "mode theme=dark"`
			end
			st.assign = { { name = name, value = if verb == "set" then step_value(value :: string) else value } }
		elseif verb == "click" or verb == "hover" or verb == "press" then
			if rest == "" then
				return nil, `"{raw}": {verb} takes a layer id or name path, as "{verb} Continue"`
			end
			st.target = rest
		end
		return st, nil
	elseif type(raw) == "table" then
		-- (`shot` rides on another step: { click = id, shot = 150 }; alone it's a step)
		local words = {}
		for word in VERBS do
			if word ~= "shot" and word ~= "screenshot" then
				table.insert(words, word)
			end
		end
		table.sort(words)
		table.insert(words, "shot")
		table.insert(words, "screenshot")
		for _, word in words do
			local verb = VERBS[word]
			local v = raw[word]
			if v ~= nil then
				local st: any = { verb = verb, shot = raw.shot }
				if verb == "wait" then
					st.ms = tonumber(v)
				elseif verb == "key" then
					st.keys = if type(v) == "table" then v else nil
					if not st.keys then
						st.keys = {}
						for part in string.gmatch(tostring(v), "[^%+%s]+") do
							table.insert(st.keys, part)
						end
					end
				elseif verb == "scroll" then
					if type(v) == "number" then
						st.dx, st.dy = 0, v
					elseif type(v) == "table" then
						st.dx, st.dy = U.num(v.x, 0), U.num(v.y, 0)
					end
					st.target = raw.at
				elseif verb == "drag" then
					st.target = v
					local by = raw.by
					if type(by) == "table" then
						st.dx, st.dy = U.num(by.x, 0), U.num(by.y, 0)
					end
				elseif verb == "shot" then
					st.label = if type(v) == "string" then v else nil
					st.shot = nil
				elseif verb == "set" or verb == "mode" then
					-- (step 5) { set = { count = 3, name = "Ann" } }, { mode = { theme = "dark" } }
					if type(v) == "string" then
						local name, value = assignment(v)
						v = if name then { [name] = if verb == "set" then step_value(value :: string) else value } else nil
					end
					if type(v) ~= "table" or next(v) == nil then
						return nil, if verb == "set" then "set takes the variables and their values: { set = { count = 3 } }" else "mode takes an axis and a value: { mode = { theme = \"dark\" } }"
					end
					local names = {}
					for k in v do
						table.insert(names, tostring(k))
					end
					table.sort(names)
					st.assign = {}
					for _, k in names do
						table.insert(st.assign, { name = k, value = if verb == "mode" then tostring(v[k]) else v[k] })
					end
				elseif v ~= true then
					st.target = v
				end
				if verb == "wait" and not st.ms then
					return nil, "wait takes milliseconds: { wait = 1500 }"
				end
				return st, nil
			end
		end
		return nil, STEP_HELP
	end
	return nil, STEP_HELP
end

local function step_text(raw: any): string
	if type(raw) == "string" then
		return raw
	end
	local parts = {}
	local keys = {}
	for k in raw do
		table.insert(keys, tostring(k))
	end
	table.sort(keys)
	for _, k in keys do
		local v = raw[k]
		if type(v) == "table" then
			v = if type(v.id) == "string" then v.id else "{…}"
		end
		table.insert(parts, `{k} = {tostring(v)}`)
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

-- ── a run ──────────────────────────────────────────────────────────────────

-- opts: { start = Screen id | Screen name | flow name (the first flow, else
-- the first Screen), steps = { … }, shots = "each" | "end" | nil, check =
-- false (skip the whole-prototype checks) }. Returns the result and the
-- views to draw, or nil and why.
function M.run(world: any, opts: any?): (any?, { any } | string)
	opts = opts or {}
	local roots = world.roots
	local dv = world.device
	if #world.order == 0 then
		return nil, "the Design has no Screens (top-level frames that aren't Components) to play"
	end

	-- where it starts
	local start, flow = nil, nil
	local want = opts.start
	if type(want) == "table" and type(want.id) == "string" then
		want = want.id
	end
	if want ~= nil then
		want = tostring(want)
		if roots[want] then
			start = want
		else
			for _, f in world.flows do
				if f.name == want and roots[f.start] then
					start, flow = f.start, f.name
				end
			end
			if not start then
				for _, id in world.order do
					if roots[id].nodes[1].name == want then
						start = id
						break
					end
				end
			end
		end
		if not start then
			local names = {}
			for _, f in world.flows do
				table.insert(names, `flow "{f.name}"`)
			end
			for i, id in world.order do
				if i > 8 then
					break
				end
				table.insert(names, `"{roots[id].nodes[1].name}" ({id})`)
			end
			return nil, `"{want}" isn't a Screen or a flow here: start at {table.concat(names, ", ")}`
		end
	else
		for _, f in world.flows do
			if roots[f.start] then
				start, flow = f.start, f.name
				break
			end
		end
		start = start or world.order[1]
	end
	local steps = opts.steps
	if steps ~= nil and type(steps) ~= "table" then
		steps = { steps }
	end
	steps = steps or {}
	if #steps > M.MAX_STEPS then
		return nil, `{#steps} steps: at most {M.MAX_STEPS} in one Simulate`
	end

	local res: any = { start = { id = start, name = tostring(roots[start].nodes[1].name) }, flow = flow, steps = {}, problems = {} }
	local views = {}
	local seen_problem = {}
	local cur_step: any = nil

	local function screen_name(id: string): string
		local r = roots[id]
		return if r then tostring(r.nodes[1].name or id) else tostring(id)
	end
	local function problem(kind: string, message: string, extra: any?)
		if cur_step then
			cur_step.problems = cur_step.problems or {}
			table.insert(cur_step.problems, `{kind}: {message}`)
		end
		local key = kind .. "|" .. message
		if seen_problem[key] then
			return
		end
		seen_problem[key] = true
		local p: any = { kind = kind, message = message }
		for k, v in extra or {} do
			p[k] = v
		end
		table.insert(res.problems, p)
	end
	local function did(s: string)
		if cur_step then
			cur_step.did = cur_step.did or {}
			table.insert(cur_step.did, s)
		end
	end
	local function note(s: string)
		if cur_step then
			cur_step.notes = cur_step.notes or {}
			table.insert(cur_step.notes, s)
		end
	end

	-- the clock and what's due on it (Play's ui.after / anime onComplete)
	local now, seq, n_events = 0, 0, 0
	local events: { any } = {}
	local busy_until = 0 -- a transition running: input waits (Play's `busy`)
	local chain_until = 0 -- a scroll glide that a list waits for
	local function busy(): boolean
		return now < busy_until
	end
	local function at(t: number, label: string?, fn: () -> ())
		seq += 1
		table.insert(events, { t = t, seq = seq, fn = fn, label = label })
	end
	local runaway = false
	local function advance(to: number)
		while not runaway do
			local bi = nil
			for i, e in events do
				if e.t <= to and (bi == nil or e.t < events[bi].t or (e.t == events[bi].t and e.seq < events[bi].seq)) then
					bi = i
				end
			end
			if not bi then
				break
			end
			local e = table.remove(events, bi)
			n_events += 1
			if n_events > M.MAX_EVENTS then
				runaway = true
				table.clear(events)
				problem("runaway", `the prototype never settles: over {M.MAX_EVENTS} timed actions (afterDelay triggers that loop with no delay?)`)
				break
			end
			if e.t > now then
				now = e.t
			end
			e.fn()
		end
		if to > now then
			now = to
		end
	end

	-- Play's state
	local history: { any } = {}
	local memory: { [string]: { number } } = {}
	local screen: any = nil
	local overlays: { any } = {}
	local gen = 0
	local under: { [string]: any } = {}
	local held: any = nil
	local hovered: any = nil -- { surf, d }
	local press_look: any = nil -- { surf, d }
	local pressed: any = nil
	local pointer = { -1e9, -1e9 }
	local segments: { any } = {}
	local ran = 0
	local urls: { string } = {}
	local vw, vh = 0, 0

	local function viewport_of(r: any): (number, number)
		local b = r.nodes[1].box
		return (dv and dv.w) or b.w, (dv and dv.h) or b.h
	end
	-- (step 4) interactive components, as Play (tab/variants.luau): each
	-- Screen's variant state `vstate[id] = { vmap, root }`, and the memory
	-- by Screen group and name path. `world.variant_root(id, vmap)` resolves
	-- a Screen with those members (the service gives it).
	local vstate: { [string]: any } = {}
	local vmem: { [string]: any } = {}

	-- (step 5) the variables at run time, as Play keeps them for the session
	-- (engine/vars.luau): `vars` overrides by Token and candidate, `mode` the
	-- page's mode per axis. They survive navigate, Back, overlays and "Reset
	-- component state"; only Restart sets them back (to `opts.vars` /
	-- `opts.mode`, the run's starting values).
	local toks = world.toks or {}
	local themes = world.themes or {}
	local vars: any = {}
	local mode: any = {}
	local var_runs = 0 -- sets and mode switches run (a step that ran one did something)
	local if_skips: { string } = {} -- (V7) each `if` that took an empty branch: its condition
	local function mode_why(axis: any, value: any): string?
		local list = themes[axis]
		if type(list) ~= "table" then
			local axes = {}
			for a in themes do
				table.insert(axes, tostring(a))
			end
			table.sort(axes)
			return `the Design has no mode axis "{tostring(axis)}"{if #axes > 0 then ` (axes: {table.concat(axes, ", ")})` else " (no Themes)"}`
		end
		if not table.find(list, value) then
			local vals = {}
			for _, v in list do
				table.insert(vals, tostring(v))
			end
			return `"{tostring(axis)}" has no mode "{tostring(value)}" (modes: {table.concat(vals, ", ")})`
		end
		return nil
	end
	if opts.mode ~= nil then
		if type(opts.mode) ~= "table" then
			return nil, `Simulate's mode is \{ axis = "value" \}, as \{ theme = "dark" \}`
		end
		for axis, value in opts.mode do
			local why = mode_why(axis, tostring(value))
			if why then
				return nil, `Simulate's mode: {why}`
			end
			mode[axis] = tostring(value)
		end
	end
	if opts.vars ~= nil then
		if type(opts.vars) ~= "table" then
			return nil, "Simulate's vars is { name = value }, as { count = 3, isOpen = true }"
		end
		for name, v in opts.vars do
			local tok = toks[name]
			if not tok then
				return nil, `Simulate's vars: the Design has no variable (Token) "{tostring(name)}"`
			end
			-- a value for every mode, or { value, theme } (a list of them) for one
			local list = if type(v) == "table" and v.value ~= nil then { v } elseif type(v) == "table" and v[1] ~= nil then v else nil
			if list then
				for _, c in list do
					local th = Vars.theme(themes, world.view, mode, if type(c) == "table" and type(c.theme) == "table" then c.theme else nil)
					local got, why = Vars.write(toks, vars, name, if type(c) == "table" then c.value else c, th)
					if got == nil then
						return nil, `Simulate's vars: {why}`
					end
				end
			else
				local got, why = Vars.coerce(tok.kind, v)
				if got == nil then
					return nil, `Simulate's vars: "{name}": {why}`
				end
				vars[name] = got
			end
		end
	end
	local vars0, mode0 = U.deep_copy(vars), table.clone(mode)

	-- A look of a Screen: its variants (vmap) and the variables, resolved
	-- once per state (cached by the state's signature).
	local looks: { [string]: any } = {}
	local function run_sig(): string
		local parts = {}
		for name, o in vars do
			if type(o) == "table" then
				for s, v in o do
					table.insert(parts, `{name}[{s}]={typeof(v)}:{tostring(v)}`)
				end
			else
				table.insert(parts, `{name}={typeof(o)}:{tostring(o)}`)
			end
		end
		for a, v in mode do
			table.insert(parts, `@{a}={v}`)
		end
		table.sort(parts)
		return table.concat(parts, ";")
	end
	local function vroot_of(id: string, vmap: any): any?
		local plain = next(vars) == nil and next(mode) == nil
		if next(vmap) == nil and (plain or not world.variant_root) then
			return roots[id]
		end
		if not world.variant_root then
			return nil
		end
		local key = id .. "|" .. Variants.signature(vmap) .. "|" .. run_sig()
		local hit = looks[key]
		if hit == nil then
			hit = (if plain then world.variant_root(id, vmap) else world.variant_root(id, vmap, { vars = vars, mode = mode })) or false
			looks[key] = hit
		end
		return hit or nil
	end
	-- The look a Screen shows now: its variant state and the variables.
	local function look(id: string): any
		local vmap = if vstate[id] then vstate[id].vmap else {}
		return vroot_of(id, vmap) or (if vstate[id] then vstate[id].root else nil) or roots[id]
	end
	local function ensure_variants(id: string)
		local base = roots[id]
		if not base then
			return
		end
		local have = if vstate[id] then vstate[id].vmap else {}
		local vmap, added = Variants.from_memory(base.nodes, vmem, have)
		if not added then
			if next(vmap) == nil then
				vstate[id] = nil
			end
			return
		end
		local r = vroot_of(id, vmap)
		if r then
			local vmap2, more = Variants.from_memory(r.nodes, vmem, vmap)
			local r2 = if more then vroot_of(id, vmap2) else nil
			vstate[id] = if r2 then { vmap = vmap2, root = r2 } else { vmap = vmap, root = r }
		end
	end
	local function new_surface(kind: string, id: string): any
		local r = look(id)
		local p = TProto.of_root(r)
		return { kind = kind, id = id, root = r, plan = Scroll.plan(r, p.drivers), pos = {}, glides = {}, x = 0, y = 0, w = 0, h = 0 }
	end
	local function surf_name(s: any): string
		return screen_name(s.id)
	end

	-- scrolling: offsets per scroller, remembered by Screen and name path
	local function pos_of(surf: any, s: number): (number, number)
		local p = surf.pos[s]
		if p then
			return p[1], p[2]
		end
		return 0, 0
	end
	local function room_of(surf: any, s: number): (number, number)
		return Scroll.room(surf.plan, s, surf.w, surf.h)
	end
	local function set_pos(surf: any, s: number, x: number, y: number)
		local mx, my = room_of(surf, s)
		x, y = math.clamp(x, 0, mx), math.clamp(y, 0, my)
		surf.pos[s] = { x, y }
		memory[Scroll.memory_key(surf.plan, s)] = { x, y }
	end
	local function shift_of(surf: any): (number) -> (number, number, number)
		return function(i: number): (number, number, number)
			return Scroll.shift(surf.plan, i, function(s: number): (number, number)
				return pos_of(surf, s)
			end)
		end
	end
	-- a glide stopped (a press, a Screen shown): where it is now
	local function glide_now(sg: any): (number, number)
		local p = M.ease_at(sg.tr, (now - sg.t0) / math.max(1, sg.t1 - sg.t0))
		return sg.x0 + (sg.x1 - sg.x0) * p, sg.y0 + (sg.y1 - sg.y0) * p
	end
	local function stop_glides(surf: any?)
		if not surf then
			return
		end
		for _, sg in segments do
			if sg.kind == "scroll" and sg.surf == surf and surf.glides[sg.s] == sg.token and now < sg.t1 then
				surf.glides[sg.s] = nil
				local x, y = glide_now(sg)
				set_pos(surf, sg.s, x, y)
			end
		end
	end
	local function sync_scroll(surf: any, reset: boolean?)
		stop_glides(surf)
		for _, s in surf.plan.scrollers do
			local m = (not reset) and memory[Scroll.memory_key(surf.plan, s)]
			set_pos(surf, s, if m then m[1] else 0, if m then m[2] else 0)
		end
	end

	-- geometry: viewport points (0..vw, 0..vh) ↔ a surface's Canvas units
	local function to_canvas(surf: any, vx: number, vy: number): (number, number)
		local b = surf.root.nodes[1].box
		return b.x + vx - surf.x, b.y + vy - surf.y
	end
	local function inter(a: { number }?, b: { number }): { number }?
		if not a then
			return nil
		end
		local x0, y0 = math.max(a[1], b[1]), math.max(a[2], b[2])
		local x1, y1 = math.min(a[1] + a[3], b[1] + b[3]), math.min(a[2] + a[4], b[2] + b[4])
		if x1 - x0 <= 0 or y1 - y0 <= 0 then
			return nil
		end
		return { x0, y0, x1 - x0, y1 - y0 }
	end
	-- Item i of a surface as shown, in viewport points: its whole box (raw),
	-- and the part that shows (cut by what clips or scrolls around it, the
	-- surface and the viewport), or nil.
	local function shown_rect(surf: any, i: number): ({ number }, { number }?)
		local nodes = surf.root.nodes
		local b = nodes[1].box
		local sh = shift_of(surf)
		local function rect(k: number): { number }
			local it = nodes[k]
			local x, y, w, h = Draw.canvas_bounds(it, Draw.local_map(it))
			local dx, dy = sh(k)
			return { x + dx - b.x + surf.x, y + dy - b.y + surf.y, math.max(w, 1), math.max(h, 1) }
		end
		local raw = rect(i)
		local r: { number }? = raw
		local j = surf.plan.parent[i]
		while j and r do
			local a = nodes[j]
			if a.clip or a.ovf then
				r = inter(r, rect(j))
			end
			j = surf.plan.parent[j]
		end
		r = inter(r, { surf.x, surf.y, surf.w, surf.h })
		r = inter(r, { 0, 0, vw, vh })
		return raw, r
	end
	local function in_rect(r: { number }?, x: number, y: number): boolean
		return r ~= nil and x >= r[1] and y >= r[2] and x <= r[1] + r[3] and y <= r[2] + r[4]
	end
	-- Where a viewport point lands: the top overlay first (F2c). A point
	-- outside it goes to its backdrop when it closes on a click outside or
	-- has a background, else on down. Returns the surface, or nil and the
	-- overlay whose backdrop took it.
	local function route(vx: number, vy: number): (any?, any?)
		if vx < 0 or vy < 0 or vx > vw or vy > vh then
			return nil, nil
		end
		for k = #overlays, 1, -1 do
			local o = overlays[k]
			if vx >= o.x and vy >= o.y and vx <= o.x + o.w and vy <= o.y + o.h then
				return o, nil
			end
			if o.ovl.co or o.ovl.bg then
				return nil, o
			end
		end
		return screen, nil
	end

	local function layer_name(surf: any, i: number): string
		local it = surf.root.nodes[i]
		return `"{tostring(it.name or it.id)}"`
	end

	-- ── what a reaction does (Play's act_runners) ──────────────────────────
	local start_timers: (any, any?) -> ()
	local run: (any, any, (() -> ())?) -> ()

	local function show(surf: any)
		stop_glides(screen)
		screen = surf
		table.clear(overlays)
		vw, vh = surf.w, surf.h
		gen += 1
		table.clear(under)
		start_timers(surf)
	end

	-- Go to Screen `id` with `tr` (nil: instant); `back`: no history kept.
	local function go_to(id: string, tr: any?, is_back: boolean, done: (() -> ())?, o: any?)
		local function finish()
			if done then
				done()
			end
		end
		local from = screen
		if from and from.id == id then
			finish()
			return
		end
		if not roots[id] then
			problem("broken-link", `there's no Screen "{id}" to go to`)
			finish()
			return
		end
		if from and not is_back then
			table.insert(history, { id = from.id, tr = tr })
		end
		hovered, pressed, press_look = nil, nil, nil
		-- (step 4: it shows the variants its Instances last had)
		if o and o.rc then
			Variants.forget(vmem, roots[id].nodes)
			vstate[id] = nil
		end
		ensure_variants(id)
		local surf = new_surface("screen", id)
		local w, h = viewport_of(surf.root)
		surf.w, surf.h = w, h
		sync_scroll(surf, o and o.reset)
		local ms = tr_ms(tr)
		if ms <= 0 or not from then
			show(surf)
			finish()
			return
		end
		busy_until = math.max(busy_until, now + ms)
		table.insert(segments, { t0 = now, t1 = now + ms, kind = "screen", from = from, from_ovl = table.clone(overlays), to = surf, tr = tr })
		at(now + ms, nil, function()
			show(surf)
			finish()
		end)
	end

	-- (F4b, as Figma: the Screen picks up a change made in the overlay once
	-- the last one closes; L1: however it closes, a click outside too)
	local function pick_up()
		if #overlays == 0 and screen then
			local before = vstate[screen.id]
			ensure_variants(screen.id)
			if vstate[screen.id] ~= before then
				local s2 = new_surface(screen.kind, screen.id)
				s2.x, s2.y, s2.w, s2.h = screen.x, screen.y, screen.w, screen.h
				for s, p in screen.pos do
					s2.pos[s] = p
				end
				screen = s2
			end
		end
	end

	local function close_top(tr: any?, done0: () -> ())
		local top = table.remove(overlays)
		if not top then
			did("close: no overlay is open")
			done0()
			return
		end
		local function done()
			pick_up()
			done0()
		end
		top.closed = true
		stop_glides(top)
		local t = tr or TProto.reverse(top.tr)
		did(`close overlay {surf_name(top)} ({tr_text(t)})`)
		local ms = tr_ms(t)
		if ms <= 0 then
			done()
			return
		end
		busy_until = math.max(busy_until, now + ms)
		table.insert(segments, { t0 = now, t1 = now + ms, kind = "close", surf = top, tr = t })
		at(now + ms, nil, done)
	end

	local function overlay_surface(id: string, how: any, anchor: { number }?): any
		-- (F4b, as Figma: an overlay opens in the variants the memory holds)
		ensure_variants(id)
		local surf = new_surface("overlay", id)
		local root = surf.root.nodes[1]
		surf.ovl = root.ovl or { pos = "center", co = true }
		local pos = how.pos or surf.ovl.pos
		local x, y, w, h = EProto.overlay_place(pos, how.ox, how.oy, vw, vh, root.box.w, root.box.h, anchor and anchor[1], anchor and anchor[2])
		surf.x, surf.y, surf.w, surf.h = x, y, w, h
		surf.open = { pos = pos, ox = how.ox, oy = how.oy, anchor = anchor }
		return surf
	end

	-- (step 5) A variable or the mode changed: the Screen and each overlay
	-- open take their new look at once (Figma: no variable change animates),
	-- in place, so their timers, history and place stay; scroll offsets are
	-- kept by scroller. Returns whether anything changed.
	local function relook(surf: any): boolean
		local r = look(surf.id)
		if r == surf.root then
			return false
		end
		stop_glides(surf)
		local old = surf.root.nodes
		local by_id = {}
		for s, p in surf.pos do
			if old[s] then
				by_id[old[s].id] = p
			end
		end
		surf.root = r
		surf.plan = Scroll.plan(r, TProto.of_root(r).drivers)
		surf.pos = {}
		surf.glides = {}
		if surf.kind == "overlay" and surf.open then
			local o = surf.open
			local root = r.nodes[1]
			surf.x, surf.y, surf.w, surf.h = EProto.overlay_place(o.pos, o.ox, o.oy, vw, vh, root.box.w, root.box.h, o.anchor and o.anchor[1], o.anchor and o.anchor[2])
		elseif surf == screen then
			surf.w, surf.h = viewport_of(r)
			vw, vh = surf.w, surf.h
		end
		for _, s in surf.plan.scrollers do
			local p = by_id[r.nodes[s].id]
			if p then
				set_pos(surf, s, p[1], p[2])
			end
		end
		if hovered and hovered.surf == surf then
			hovered, press_look = nil, nil
		end
		return true
	end
	local function relook_all(): boolean
		local any = false
		if screen and relook(screen) then
			any = true
		end
		for _, o in overlays do
			if relook(o) then
				any = true
			end
		end
		return any
	end

	local act_runners: { [string]: (any, any, () -> ()) -> () } = {}
	local function who(ctx: any): string
		if ctx and ctx.name and ctx.surf then
			return `{ctx.name} on {surf_name(ctx.surf)}`
		end
		if ctx and ctx.link and ctx.surf then
			return `{layer_name(ctx.surf, ctx.link.i)} on {surf_name(ctx.surf)}`
		end
		return "a reaction"
	end
	local function where(ctx: any): any
		if ctx and ctx.link and ctx.surf then
			return { layer = ctx.link.id, screen = ctx.surf.id }
		end
		return nil
	end
	act_runners.navigate = function(act, ctx, done)
		if act.broken or not act.go or not roots[act.go] then
			problem("broken-link", `{who(ctx)} goes to "{tostring(act.go)}", which isn't a Screen (deleted?)`, where(ctx))
			done()
			return
		end
		did(`navigate → {screen_name(act.go)} ({tr_text(act.tr)}){if act.rs then ", scroll reset" else ""}{if act.rc then ", components reset" else ""}`)
		go_to(act.go, act.tr, false, done, { reset = act.rs == true, rc = act.rc == true })
	end
	act_runners.back = function(act, ctx, done)
		-- (Back closes the top overlay first: F2c)
		if #overlays > 0 then
			close_top(act.tr, done)
			return
		end
		local h = table.remove(history)
		while h and not roots[h.id] do
			h = table.remove(history)
		end
		if not h then
			did("back: nothing to go back to")
			problem("back-empty", `{who(ctx)} goes back, but nothing came before it here (a Back on the first Screen does nothing)`, where(ctx))
			done()
			return
		end
		local t = act.tr or TProto.reverse(h.tr)
		did(`back → {screen_name(h.id)} ({tr_text(t)})`)
		go_to(h.id, t, true, done)
	end
	act_runners.url = function(act, ctx, done)
		table.insert(urls, tostring(act.url))
		did(`open {tostring(act.url)} (outside the prototype)`)
		done()
	end
	act_runners.motion = function(act, ctx, done)
		did(`motion {tostring(act.play)}: reserved, not played yet`)
		done()
	end
	-- (step 4) Change to: the closest Instance of the target's set around
	-- the layer shows `act.to`; the Screen (or overlay) is resolved again
	-- and replaces itself, by the act's transition (smart: the planner).
	act_runners.changeTo = function(act, ctx, done)
		local surf = ctx and ctx.surf
		if act.broken or not surf or not ctx.link then
			problem("broken-link", `{who(ctx)} changes to "{tostring(act.to)}", which isn't a variant (deleted?)`, where(ctx))
			done()
			return
		end
		local nodes = surf.root.nodes
		local cur = if vstate[surf.id] then vstate[surf.id].vmap else {}
		local vmap, t = Variants.change(nodes, cur, ctx.link.i, act)
		if not vmap or not t then
			if t then
				problem("no-op", `{who(ctx)} changes {layer_name(surf, t)} to the variant it shows already`, where(ctx))
			else
				problem("variant-target", `{who(ctx)} changes to a variant of "{tostring(act.set)}", but no Instance of that set is around it`, where(ctx))
			end
			done()
			return
		end
		-- (step 5) an Instance whose variant properties are bound to variables:
		-- the Change to writes them (Figma's two-way binding), and the
		-- variables pick the member; the variant state stays as it was
		local tgt = nodes[t]
		local wrote = nil
		if type(tgt.vb) == "table" and next(tgt.vb) ~= nil then
			local props = (world.vsets and world.vsets[act.set] and world.vsets[act.set].props[act.to]) or {}
			local th = Vars.theme(themes, world.view, mode, tgt.th)
			local names = {}
			for prop in tgt.vb do
				table.insert(names, prop)
			end
			table.sort(names)
			wrote = {}
			for _, prop in names do
				local tok = tgt.vb[prop]
				local raw = props[prop]
				local kind = toks[tok] and toks[tok].kind
				if raw ~= nil and kind then
					local v: any = raw
					if kind == "boolean" then
						v = if raw == "true" then true elseif raw == "false" then false else raw
					elseif kind == "number" then
						v = tonumber(raw) or raw
					end
					local got, why, code = Vars.write(toks, vars, tok, v, th)
					if got == nil then
						problem(code or "var-type", `{who(ctx)} changes {layer_name(surf, t)}, whose {prop} is bound to "{tok}": {why}`, where(ctx))
					else
						table.insert(wrote, `{tok} = {Expr.text(got)}`)
					end
				end
			end
			vmap = cur
		end
		local r = vroot_of(surf.id, vmap)
		if not r then
			problem("broken-link", `{who(ctx)}: the variant "{tostring(act.to)}" couldn't be drawn`, where(ctx))
			done()
			return
		end
		if not wrote then
			Variants.remember(vmem, nodes, t, act.to, act.set)
			vstate[surf.id] = { vmap = vmap, root = r }
		end
		did(`change {layer_name(surf, t)} to {tostring(act.name or act.to)} ({tr_text(act.tr)}){if wrote and #wrote > 0 then ", which sets " .. table.concat(wrote, ", ") else ""}`)
		local s2 = new_surface(surf.kind, surf.id)
		s2.x, s2.y, s2.w, s2.h, s2.ovl, s2.open, s2.tr = surf.x, surf.y, surf.w, surf.h, surf.ovl, surf.open, surf.tr
		for s, p in surf.pos do
			s2.pos[s] = p
		end
		stop_glides(surf)
		local scope: { [string]: boolean } = {}
		local tid = nodes[t].id
		for _, it in r.nodes do
			if it.id == tid or string.sub(it.id, 1, #tid + 1) == tid .. "/" then
				scope[it.id] = true
			end
		end
		local ms = tr_ms(act.tr)
		local tr = act.tr
		if surf.kind == "screen" then
			if ms > 0 then
				table.insert(segments, { t0 = now, t1 = now + ms, kind = "screen", from = surf, from_ovl = table.clone(overlays), to = s2, tr = tr })
			end
			screen = s2
			hovered, press_look = nil, nil
		else
			local k = table.find(overlays, surf)
			if k then
				overlays[k] = s2
			end
			if ms > 0 then
				table.insert(segments, { t0 = now, t1 = now + ms, kind = "swap", surf = s2, from = surf, tr = tr })
			end
		end
		if wrote then
			-- (what else shows those variables follows at once)
			relook_all()
		end
		local function fin()
			start_timers(s2, scope)
			done()
		end
		if ms > 0 then
			busy_until = math.max(busy_until, now + ms)
			at(now + ms, nil, fin)
		else
			fin()
		end
	end
	act_runners.scrollTo = function(act, ctx, done)
		-- (the reaction's own surface first: an overlay scrolls itself)
		local surf = if ctx and ctx.surf and ctx.surf.plan.at[act.to] then ctx.surf else screen
		local i = surf and surf.plan.at[act.to]
		if not i then
			problem("scroll-target", `{who(ctx)} scrolls to "{tostring(act.to)}", which isn't on {surf_name(screen)}`, where(ctx))
			done()
			return
		end
		local s, tx, ty = Scroll.scroll_target(surf.plan, i, act.ox or 0, act.oy or 0, function(k: number): (number, number)
			return pos_of(surf, k)
		end, function(k: number): (number, number)
			return room_of(surf, k)
		end)
		local mx, my = room_of(surf, s)
		tx, ty = math.clamp(tx, 0, mx), math.clamp(ty, 0, my)
		local x0, y0 = pos_of(surf, s)
		local ms = if act.tr then act.tr.ms or 300 else 0
		local scroller = if s == 1 then surf_name(surf) else layer_name(surf, s)
		did(`scroll {scroller} to {math.floor(tx + 0.5)}, {math.floor(ty + 0.5)}{if ms > 0 then `, {math.floor(ms)} ms` else ""}`)
		if ms <= 0 or (tx == x0 and ty == y0) then
			set_pos(surf, s, tx, ty)
			done()
			return
		end
		local token = {}
		surf.glides[s] = token
		table.insert(segments, { t0 = now, t1 = now + ms, kind = "scroll", surf = surf, s = s, x0 = x0, y0 = y0, x1 = tx, y1 = ty, tr = act.tr, token = token })
		chain_until = math.max(chain_until, now + ms)
		at(now + ms, nil, function()
			if surf.glides[s] == token then
				surf.glides[s] = nil
				set_pos(surf, s, tx, ty)
			end
			done()
		end)
	end
	act_runners.overlay = function(act, ctx, done)
		if act.broken or not act.go or not roots[act.go] then
			problem("broken-link", `{who(ctx)} opens "{tostring(act.go)}" as an overlay, which isn't a top-level frame (deleted?)`, where(ctx))
			done()
			return
		end
		local anchor = nil
		if ctx and ctx.link and ctx.surf then
			local raw = shown_rect(ctx.surf, ctx.link.i)
			anchor = { raw[1], raw[2] }
		end
		local surf = overlay_surface(act.go, act, anchor)
		sync_scroll(surf)
		surf.tr = act.tr
		table.insert(overlays, surf)
		did(`open overlay {surf_name(surf)} ({surf.open.pos}, {tr_text(act.tr)})`)
		local ms = tr_ms(act.tr)
		if ms <= 0 then
			start_timers(surf)
			done()
			return
		end
		busy_until = math.max(busy_until, now + ms)
		table.insert(segments, { t0 = now, t1 = now + ms, kind = "open", surf = surf, tr = act.tr })
		at(now + ms, nil, function()
			start_timers(surf)
			done()
		end)
	end
	act_runners.swap = function(act, ctx, done)
		if act.broken or not act.go or not roots[act.go] then
			problem("broken-link", `{who(ctx)} swaps to "{tostring(act.go)}", which isn't a top-level frame (deleted?)`, where(ctx))
			done()
			return
		end
		if #overlays == 0 then
			-- (with no overlay open, a swap goes there with no history: F2c, Figma)
			did(`swap → {screen_name(act.go)}: no overlay is open, so it goes there with no history ({tr_text(act.tr)})`)
			go_to(act.go, act.tr, true, done)
			return
		end
		local old = overlays[#overlays]
		local surf = overlay_surface(act.go, old.open, old.open.anchor)
		sync_scroll(surf)
		surf.tr = old.tr
		old.closed = true
		overlays[#overlays] = surf
		did(`swap overlay {surf_name(old)} → {surf_name(surf)} ({tr_text(act.tr)})`)
		local ms = tr_ms(act.tr)
		if ms <= 0 then
			start_timers(surf)
			done()
			return
		end
		busy_until = math.max(busy_until, now + ms)
		table.insert(segments, { t0 = now, t1 = now + ms, kind = "swap", from = old, surf = surf, tr = act.tr })
		at(now + ms, nil, function()
			start_timers(surf)
			done()
		end)
	end
	act_runners.close = function(act, ctx, done)
		if #overlays == 0 then
			did("close: no overlay is open")
			problem("no-op", `{who(ctx)} closes an overlay, but none is open there`, where(ctx))
			done()
			return
		end
		close_top(act.tr, done)
	end

	local function run_acts(acts: { any }, i: number, ctx: any, done: (() -> ())?)
		local act = acts[i]
		if not act then
			if done then
				done()
			end
			return
		end
		local runner = act_runners[act.k]
		if not runner then
			did(`{tostring(act.k)}: can't run yet`)
			run_acts(acts, i + 1, ctx, done)
			return
		end
		-- (step 5: a set before it may have moved the layer in its Screen's items)
		if ctx and ctx.link and ctx.surf then
			local at_now = ctx.surf.plan.at[ctx.link.id]
			if at_now and at_now ~= ctx.link.i then
				ctx.link = table.clone(ctx.link)
				ctx.link.i = at_now
			end
		end
		runner(act, ctx, function()
			run_acts(acts, i + 1, ctx, done)
		end)
	end

	-- ── (step 5) variables, modes, conditionals ────────────────────────────
	-- A run context for engine/vars.luau: the theme the reaction's layer sees
	-- (its pinned modes over the page's), problems reported as the layer's.
	local function vctx(ctx: any): any
		return {
			toks = toks, vars = vars, themes = themes,
			theme = Vars.theme(themes, world.view, mode, ctx and ctx.pin),
			warn = function(code: string, msg: string)
				problem(code, `{who(ctx)}: {msg}`, where(ctx))
			end,
		}
	end
	local function cand_note(name: string, theme: any): string
		local tok = toks[name]
		if not tok or #tok.values < 2 then
			return ""
		end
		local _, cand = Resolve.value_in(tok, theme)
		local s = Vars.sig(cand and cand.theme)
		return if s ~= "" then ` [{s}]` else ""
	end
	act_runners.set = function(act, ctx, done)
		local c = vctx(ctx)
		local v = Vars.run_set(c, act)
		if v ~= nil then
			var_runs += 1
			did(`{if act.tg then "toggle" else "set"} {act.var}{cand_note(act.var, c.theme)} = {Expr.text(v)}`)
			relook_all()
		else
			did(`set {tostring(act.var)}: not set (see problems)`)
		end
		done()
	end
	act_runners.mode = function(act, ctx, done)
		local why = mode_why(act.axis, act.value)
		if why then
			problem("mode-unknown", `{who(ctx)}: {why}`, where(ctx))
			did(`mode {tostring(act.axis)} = {tostring(act.value)}: not switched`)
		elseif Vars.run_mode(mode, act) then
			var_runs += 1
			did(`mode {act.axis} = {act.value}`)
			relook_all()
		else
			var_runs += 1
			did(`mode {act.axis} = {act.value} (already)`)
		end
		done()
	end
	act_runners["if"] = function(act, ctx, done)
		local yes = Vars.test(vctx(ctx), act.cond)
		local list = if yes then act.th else act.el
		did(`if {act.cond}: {if yes then "then" else "else"}{if list == nil or #list == 0 then " (nothing)" else ""}`)
		if list == nil or #list == 0 then
			table.insert(if_skips, `{act.cond} was {if yes then "true" else "false"}`)
		end
		run_acts(list or {}, 1, ctx, done)
	end

	run = function(l: any, surf: any, done: (() -> ())?)
		ran += 1
		local a = l.a
		local acts = a.acts
		if not acts then
			acts = {
				if a.url then { k = "url", url = a.url, nt = a.nt } elseif a.go == "back" then { k = "back", tr = a.tr } else { k = "navigate", go = a.go, tr = a.tr },
			}
		end
		did(`{a.on} on {layer_name(surf, l.i)}:`)
		local it = surf.root.nodes[l.i]
		run_acts(acts, 1, { link = l, surf = surf, name = layer_name(surf, l.i), pin = it and it.th }, done)
	end

	-- ── triggers besides click (Play's) ─────────────────────────────────────
	local function acts_text(a: any): string
		local out = {}
		for _, act in a.acts or {} do
			local t = act.k
			if act.go and roots[act.go] then
				t ..= " " .. screen_name(act.go)
			end
			table.insert(out, t)
		end
		return table.concat(out, ", ")
	end
	local function fire(l: any, surf: any, ms: number?, still: (() -> boolean)?)
		if not ms or ms <= 0 then
			if not busy() then
				run(l, surf)
			end
			return
		end
		local g = gen
		at(now + ms, `{l.a.on} after {math.floor(ms)} ms on {layer_name(surf, l.i)} → {acts_text(l.a)}`, function()
			if g == gen and not busy() and (not still or still()) then
				run(l, surf)
			end
		end)
	end

	local function set_hover(surf: any?, d: any?)
		if hovered and (hovered.surf ~= surf or hovered.d ~= d) then
			hovered = nil
			press_look = nil
		end
		if surf and d and not hovered then
			hovered = { surf = surf, d = d }
		end
	end

	-- The hover / press reaction held ends: back to where it started (and
	-- the overlays it opened close).
	local function revert()
		local h = held
		if not h then
			return
		end
		if busy() then
			at(busy_until, nil, revert)
			return
		end
		held = nil
		local any = false
		while #overlays > h.ovl_depth do
			any = true
			close_top(nil, function() end)
		end
		if screen and screen.id ~= h.origin and #history > h.depth then
			any = true
			while #history > h.depth + 1 do
				table.remove(history)
			end
			local last = table.remove(history)
			did(`{h.kind} on {h.name} ended: back to {screen_name(last.id)}`)
			go_to(last.id, TProto.reverse(last.tr), true)
		elseif h.vmem and screen and screen.id == h.origin and Variants.signature(h.vmap) ~= Variants.signature(if vstate[screen.id] then vstate[screen.id].vmap else {}) then
			-- (step 4: while hovering / pressing → Change to goes back)
			table.clear(vmem)
			for k, x in h.vmem do
				vmem[k] = x
			end
			local r = vroot_of(screen.id, h.vmap)
			if r then
				vstate[screen.id] = if next(h.vmap) ~= nil then { vmap = h.vmap, root = r } else nil
				local old = screen
				local s2 = new_surface("screen", old.id)
				s2.x, s2.y, s2.w, s2.h = old.x, old.y, old.w, old.h
				for s, p in old.pos do
					s2.pos[s] = p
				end
				local ms = tr_ms(h.vtr)
				if ms > 0 then
					table.insert(segments, { t0 = now, t1 = now + ms, kind = "screen", from = old, from_ovl = table.clone(overlays), to = s2, tr = h.vtr })
					busy_until = math.max(busy_until, now + ms)
				end
				screen = s2
				did(`{h.kind} on {h.name} ended: back to its variant`)
			end
		elseif any then
			did(`{h.kind} on {h.name} ended: reverted`)
		end
	end
	local function hold(kind: string, l: any, surf: any)
		if held or busy() then
			return
		end
		local raw = shown_rect(surf, l.i)
		local h: any = { kind = kind, origin = screen.id, depth = #history, ovl_depth = #overlays, rect = raw, name = layer_name(surf, l.i) }
		for _, act in l.a.acts or {} do
			if act.k == "changeTo" then
				h.vmap = if vstate[screen.id] then vstate[screen.id].vmap else {}
				h.vmem = table.clone(vmem)
				h.vtr = act.tr
				break
			end
		end
		held = h
		run(l, surf)
		if #overlays > h.ovl_depth then
			h.opened = overlays[#overlays]
		end
	end
	local function hover_left(vx: number, vy: number)
		local h = held
		if not h or h.kind ~= "hover" or in_rect(h.rect, vx, vy) then
			return
		end
		local o = h.opened
		if o and not o.closed then
			if in_rect({ o.x, o.y, o.w, o.h }, vx, vy) then
				return
			end
			if not h.grace then
				h.grace = true
				at(now + M.HOVER_GRACE, nil, function()
					h.grace = false
					local px, py = pointer[1], pointer[2]
					if held == h and not in_rect(h.rect, px, py) and not (not o.closed and in_rect({ o.x, o.y, o.w, o.h }, px, py)) then
						revert()
					end
				end)
			end
			return
		end
		revert()
	end
	local function triggers_move(vx: number, vy: number)
		hover_left(vx, vy)
		local now_under: { [string]: any } = {}
		local surf = route(vx, vy)
		if surf then
			local x, y = to_canvas(surf, vx, vy)
			for _, l in TProto.reactions_at(surf.root, x, y, shift_of(surf)) do
				local on = l.a.on
				if on == "mouseEnter" or on == "mouseLeave" or on == "hover" then
					local u = now_under[l.id]
					if not u then
						u = { surf = surf, ls = {} }
						now_under[l.id] = u
					end
					table.insert(u.ls, l)
				end
			end
		end
		local ids = {}
		for id in under do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			if not now_under[id] then
				local u = under[id]
				under[id] = nil
				for _, l in u.ls do
					if l.a.on == "mouseLeave" then
						fire(l, u.surf, l.a.ms, function()
							return under[id] == nil
						end)
					end
				end
			end
		end
		ids = {}
		for id in now_under do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			if not under[id] then
				local u = now_under[id]
				under[id] = u
				for _, l in u.ls do
					if l.a.on == "mouseEnter" then
						fire(l, u.surf, l.a.ms, function()
							return under[id] == u
						end)
					elseif l.a.on == "hover" then
						hold("hover", l, u.surf)
					end
				end
			end
		end
	end

	-- A Screen (or an overlay) shows: its afterDelay reactions start counting.
	start_timers = function(surf: any, scope: any?)
		for _, l in TProto.of_root(surf.root).links do
			if l.a.on == "afterDelay" and TProto.live(l.a) and (not scope or scope[l.id]) then
				local g = gen
				local function alive(): boolean
					if surf.kind == "screen" then
						-- (a Change to shows the Screen again: its timers keep on)
						return g == gen and screen ~= nil and screen.id == surf.id
					end
					return not surf.closed and table.find(overlays, surf) ~= nil
				end
				local function go()
					if not alive() then
						return
					end
					if busy() then
						at(busy_until, nil, go)
						return
					end
					run(l, surf)
				end
				at(now + math.max(0, l.a.ms or 0), `afterDelay {math.floor(l.a.ms or 0)} ms on {layer_name(surf, l.i)} → {acts_text(l.a)}`, go)
			end
		end
	end

	-- ── the pointer (Play's on_move / on_press / on_release) ────────────────
	local function move_to(vx: number, vy: number)
		pointer = { vx, vy }
		if busy() then
			hover_left(vx, vy)
			return
		end
		triggers_move(vx, vy)
		local surf = route(vx, vy)
		local d = nil
		if surf then
			local x, y = to_canvas(surf, vx, vy)
			local _, dd = TProto.hit(surf.root, x, y, shift_of(surf))
			if dd and (dd.has.hover or dd.has.press) then
				d = dd
			end
		end
		if not pressed then
			set_hover(if d then surf else nil, d)
		end
	end
	local function press_at(vx: number, vy: number)
		if busy() then
			return
		end
		stop_glides(screen)
		local surf, backdrop = route(vx, vy)
		if not surf then
			pressed = { backdrop = backdrop, vx = vx, vy = vy }
			return
		end
		local x, y = to_canvas(surf, vx, vy)
		local sh = shift_of(surf)
		local link, d = TProto.hit(surf.root, x, y, sh)
		pressed = { surf = surf, link = link, d = d, vx = vx, vy = vy }
		local list = TProto.reactions_at(surf.root, x, y, sh)
		pressed.drag = TProto.first_on(list, "drag")
		local down = TProto.first_on(list, "mouseDown")
		local pr = TProto.first_on(list, "press")
		if pr then
			pressed.acted = true
			hold("press", pr, surf)
		end
		if down then
			pressed.acted = true
			fire(down, surf, down.a.ms)
		end
		if d then
			set_hover(surf, d)
			if d.has.press then
				press_look = { surf = surf, d = d }
			end
		end
	end
	-- Returns "ran" (a click ran), "nothing" (nothing reacts: Play flashes
	-- the hotspots), or nil.
	local function release_at(vx: number, vy: number): string?
		local p = pressed
		pressed = nil
		press_look = nil
		if held and held.kind == "press" then
			revert()
		end
		if not p then
			return nil
		end
		if p.backdrop then
			local _, b2 = route(vx, vy)
			local o = p.backdrop
			if b2 == o and o == overlays[#overlays] then
				if o.ovl.co then
					did(`click outside overlay {surf_name(o)}: it closes`)
					close_top(nil, function() end)
					return "ran"
				end
				note(`the click landed on overlay {surf_name(o)}'s background, which doesn't close it`)
			end
			return nil
		end
		if busy() then
			return nil
		end
		local surf = route(vx, vy)
		local x, y = 0, 0
		if surf then
			x, y = to_canvas(surf, vx, vy)
			local up = TProto.first_on(TProto.reactions_at(surf.root, x, y, shift_of(surf)), "mouseUp")
			if up then
				p.acted = true
				fire(up, surf, up.a.ms)
			end
		end
		if not surf or surf ~= p.surf then
			return nil
		end
		local link = TProto.hit(surf.root, x, y, shift_of(surf))
		if p.link and link and link.id == p.link.id then
			run(link, surf)
			return "ran"
		elseif not p.link and not p.acted then
			return "nothing"
		end
		return nil
	end

	-- A wheel or drag delta at viewport (vx, vy): the innermost scroller
	-- that can still move takes it (Play's scroll_by). Returns what moved.
	local function scroll_at(vx: number, vy: number, dx: number, dy: number): { [number]: { number } }
		local surf = route(vx, vy)
		if not surf then
			return {}
		end
		local x, y = to_canvas(surf, vx, vy)
		local i = TProto.deepest(surf.root, x, y, shift_of(surf))
		local chain = Scroll.chain(surf.plan, if i > 0 then i else 1)
		stop_glides(surf)
		local moves = Scroll.route(chain, dx, dy, function(s: number): (number, number)
			return pos_of(surf, s)
		end, function(s: number): (number, number)
			return room_of(surf, s)
		end)
		local keys = {}
		for s in moves do
			table.insert(keys, s)
		end
		table.sort(keys)
		for _, s in keys do
			set_pos(surf, s, moves[s][1], moves[s][2])
			local scroller = if s == 1 then surf_name(surf) else layer_name(surf, s)
			did(`scroll {scroller} to {math.floor(moves[s][1] + 0.5)}, {math.floor(moves[s][2] + 0.5)}`)
		end
		return moves
	end

	-- ── Play's own keys and buttons ─────────────────────────────────────────
	local function player_back()
		if #overlays > 0 then
			close_top(nil, function() end)
			return
		end
		local h = table.remove(history)
		while h and not roots[h.id] do
			h = table.remove(history)
		end
		if not h then
			did("back: nothing to go back to")
			return
		end
		local t = TProto.reverse(h.tr)
		did(`back → {screen_name(h.id)} ({tr_text(t)})`)
		go_to(h.id, t, true)
	end
	local function restart()
		table.clear(history)
		table.clear(memory)
		table.clear(vmem)
		table.clear(vstate)
		-- (step 5, Figma: Restart sets every variable and the mode back)
		table.clear(vars)
		for k, v in U.deep_copy(vars0) do
			vars[k] = v
		end
		table.clear(mode)
		for k, v in mode0 do
			mode[k] = v
		end
		if screen and screen.id == start and screen.root ~= look(start) then
			-- (the start Screen showing other variants: it shows its own again)
			local s2 = new_surface("screen", start)
			s2.w, s2.h, s2.pos = screen.w, screen.h, screen.pos
			screen = s2
		end
		table.clear(overlays)
		held = nil
		did(`restart at {screen_name(start)}`)
		if screen and screen.id == start then
			sync_scroll(screen, true)
			return
		end
		go_to(start, nil, true, nil, { reset = true })
	end

	-- ── finding a layer ─────────────────────────────────────────────────────
	local function surfaces_top_first(): { any }
		local out = {}
		for k = #overlays, 1, -1 do
			table.insert(out, overlays[k])
		end
		table.insert(out, screen)
		return out
	end
	local function shown_where(): string
		local names = {}
		for _, o in overlays do
			table.insert(names, surf_name(o))
		end
		return surf_name(screen) .. (if #names > 0 then ` (with overlay {table.concat(names, ", ")})` else "")
	end
	-- id or name path → surface, item index; or nil and why.
	local function locate(target: any): (any?, number?, string?)
		if type(target) == "table" and type(target.id) == "string" then
			target = target.id
		end
		target = tostring(target)
		local surfs = surfaces_top_first()
		for _, s in surfs do
			local i = s.plan.at[target]
			if i then
				return s, i, nil
			end
		end
		for _, s in surfs do
			local nodes = s.root.nodes
			local exact, ends = {}, {}
			for i = 2, #nodes do
				local p = s.plan.path[i] or ""
				if p == target then
					table.insert(exact, i)
				elseif nodes[i].name == target or string.sub(p, -(#target + 1)) == "/" .. target then
					table.insert(ends, i)
				end
			end
			local c = if #exact > 0 then exact else ends
			if #c == 1 then
				return s, c[1], nil
			end
			if #c > 1 then
				local list = {}
				for k = 1, math.min(#c, 4) do
					table.insert(list, `{s.plan.path[c[k]]} ({nodes[c[k]].id})`)
				end
				return nil, nil, `"{target}" matches {#c} layers on {surf_name(s)}: {table.concat(list, "; ")}{if #c > 4 then "; …" else ""}. Use a path ("Form/Continue") or an id`
			end
		end
		for _, id in world.order do
			for _, it in roots[id].nodes do
				if it.id == target or it.name == target then
					return nil, nil, `"{target}" isn't on what's shown, {shown_where()}: it's on {screen_name(id)}`
				end
			end
		end
		return nil, nil, `no layer "{target}" on {shown_where()} (an id, or a name path from the Screen as "Form/Continue")`
	end
	-- Where to point at a layer: the middle of what shows of it. nil and why
	-- when none of it shows.
	local function point_of(surf: any, i: number, target: string): (number?, number?, string?)
		local raw, r = shown_rect(surf, i)
		if not r then
			local off = raw[2] >= vh or raw[2] + raw[4] <= 0 or raw[1] >= vw or raw[1] + raw[3] <= 0
			if off then
				return nil, nil, `"{target}" is out of view on {surf_name(surf)} (at {math.floor(raw[1])}, {math.floor(raw[2])} in a {math.floor(vw)}×{math.floor(vh)} viewport): scroll first ("scroll 400"), or give it a scrollTo`
			end
			return nil, nil, `"{target}" doesn't show: what clips it (a frame with clip, or a scroller) hides it`
		end
		return r[1] + r[3] / 2, r[2] + r[4] / 2, nil
	end
	-- What a point would hit instead of the layer meant: nil when it's the
	-- layer (or inside it), else what covers it.
	local function covering(surf: any, i: number, vx: number, vy: number): string?
		local s2, backdrop = route(vx, vy)
		if backdrop then
			return `overlay {surf_name(backdrop)}'s background`
		end
		if s2 ~= surf then
			return if s2 then `overlay {surf_name(s2)}` else nil
		end
		local x, y = to_canvas(surf, vx, vy)
		local k = TProto.deepest(surf.root, x, y, shift_of(surf))
		local n = surf.root.nodes[i].n or 0
		if k == 0 or (k >= i and k <= i + n) then
			return nil
		end
		-- (an ancestor of i drawn after it can't be: ancestors come first)
		return layer_name(surf, k)
	end

	-- ── the state as the agent reads it ─────────────────────────────────────
	local function signature(): string
		local parts = { screen and screen.id or "", tostring(#history), tostring(#urls) }
		for _, o in overlays do
			table.insert(parts, o.id)
		end
		-- (step 4: a Change to is a change)
		for id, v in vstate do
			table.insert(parts, id .. "{" .. Variants.signature(v.vmap) .. "}")
		end
		-- (step 5: a set or mode that ran is a change, even to the same value:
		-- a clamp such as "if count <= 0 then count = 0" is meant)
		table.insert(parts, `v{var_runs}:{run_sig()}`)
		for _, s in surfaces_top_first() do
			for _, si in s.plan.scrollers do
				local x, y = pos_of(s, si)
				table.insert(parts, `{si}:{math.floor(x)}:{math.floor(y)}`)
			end
		end
		return table.concat(parts, "|")
	end
	local function snapshot(): any
		local out: any = {
			screen = { id = screen.id, name = surf_name(screen) },
			t = math.floor(now + 0.5),
			history = #history,
		}
		if #overlays > 0 then
			out.overlays = {}
			for _, o in overlays do
				table.insert(out.overlays, { id = o.id, name = surf_name(o), x = math.floor(o.x + 0.5), y = math.floor(o.y + 0.5), w = math.floor(o.w + 0.5), h = math.floor(o.h + 0.5) })
			end
		end
		-- (step 4) the interactive components shown, and their variants
		local comps = {}
		for _, s in { screen, table.unpack(overlays) } do
			for i, it in s.root.nodes do
				if it.vset then
					table.insert(comps, { layer = surf_name(s) .. "/" .. Variants.path(s.root.nodes, i), set = it.vset, variant = (world.vprops or {})[it.inst] or it.inst, id = it.inst })
				end
			end
		end
		if #comps > 0 then
			out.components = comps
		end
		-- (step 5) the variables whose values differ from the Design's: a
		-- value, or a list of { value, theme } for the modes that differ;
		-- and the modes switched
		local changed = Vars.changed(toks, vars)
		if #changed > 0 then
			local vout = {}
			for _, c in changed do
				if c.theme == nil and vout[c.name] == nil then
					vout[c.name] = c.value
				else
					local cur = vout[c.name]
					if type(cur) ~= "table" then
						cur = if cur ~= nil then { { value = cur } } else {}
						vout[c.name] = cur
					end
					table.insert(cur, { value = c.value, theme = c.theme })
				end
			end
			out.vars = vout
		end
		if next(mode) ~= nil then
			out.mode = table.clone(mode)
		end
		local scroll = {}
		for _, s in { screen, table.unpack(overlays) } do
			for _, si in s.plan.scrollers do
				local mx, my = room_of(s, si)
				if mx > 0 or my > 0 then
					local x, y = pos_of(s, si)
					local path = s.plan.path[si]
					table.insert(scroll, {
						layer = surf_name(s) .. (if path and path ~= "" then "/" .. path else ""),
						id = s.root.nodes[si].id,
						x = math.floor(x + 0.5),
						y = math.floor(y + 0.5),
						max = { x = math.floor(mx + 0.5), y = math.floor(my + 0.5) },
					})
				end
			end
		end
		if #scroll > 0 then
			out.scroll = scroll
		end
		if hovered then
			local it = hovered.surf.root.nodes[hovered.d.i]
			out.states = { { id = hovered.d.id, name = tostring(it and it.name), state = if press_look and press_look.d == hovered.d then "press" else "hover" } }
		end
		if held then
			out.holding = `{held.kind} on {held.name}`
		end
		local pend = {}
		for _, e in events do
			if e.label then
				table.insert(pend, { t = e.t, seq = e.seq, label = e.label })
			end
		end
		table.sort(pend, function(a, b)
			return if a.t == b.t then a.seq < b.seq else a.t < b.t
		end)
		if #pend > 0 then
			out.pending = {}
			for _, p in pend do
				table.insert(out.pending, { in_ms = math.floor(p.t - now + 0.5), what = p.label })
			end
		end
		if #urls > 0 then
			out.opened = table.clone(urls)
		end
		return out
	end

	-- ── views (screenshots) ─────────────────────────────────────────────────
	local function layer_of(s: any): any
		local pos = {}
		for _, si in s.plan.scrollers do
			local x, y = pos_of(s, si)
			for _, sg in segments do
				if sg.kind == "scroll" and sg.surf == s and sg.s == si and s.glides[si] == sg.token and now >= sg.t0 and now < sg.t1 then
					x, y = glide_now(sg)
				end
			end
			if x ~= 0 or y ~= 0 then
				pos[s.root.nodes[si].id] = { x, y }
			end
		end
		-- (step 4: a Screen showing other variants carries its own items)
		local items = if s.root ~= roots[s.id] then s.root.nodes else nil
		return { root = s.id, items = items, x = s.x, y = s.y, w = s.w, h = s.h, pos = pos, dx = 0, dy = 0, op = 1, overlay = s.kind == "overlay" or nil }
	end
	local function moved(L: any, ends: any, p: number): any
		L.dx = ends.a.x + (ends.b.x - ends.a.x) * p
		L.dy = ends.a.y + (ends.b.y - ends.a.y) * p
		L.op = ends.a.opacity + (ends.b.opacity - ends.a.opacity) * p
		return L
	end
	local function backdrop_of(o: any, op: number): any?
		if not o.ovl.bg then
			return nil
		end
		return { bg = o.ovl.bg, op = op }
	end
	local function view_at(label: string?): any
		local active = {}
		for _, sg in segments do
			if now >= sg.t0 and now < sg.t1 then
				table.insert(active, sg)
			end
		end
		local layers = {}
		local function add_overlays(list: { any }, dx: number, dy: number, op: number)
			for _, o in list do
				local seg = nil
				for _, sg in active do
					if (sg.kind == "open" or sg.kind == "swap") and sg.surf == o then
						seg = sg
					end
				end
				local p = if seg then M.ease_at(seg.tr, (now - seg.t0) / (seg.t1 - seg.t0)) else 1
				if seg and seg.kind == "swap" then
					local mo = TProto.motion(seg.tr, o.w, o.h)
					local bd = backdrop_of(o, op)
					if bd then
						table.insert(layers, bd)
					end
					local old = moved(layer_of(seg.from), mo.from, p)
					local new = moved(layer_of(o), mo.to, p)
					if mo.top == "to" and old.root == new.root then
						new.over = old
					end
					if mo.top == "to" then
						table.insert(layers, old)
						table.insert(layers, new)
					else
						table.insert(layers, new)
						table.insert(layers, old)
					end
					-- (step 3) a smart swap: the two overlays are its bases
					if seg.tr and (seg.tr.k == "smart" or seg.tr.ml) then
						old.smart, new.smart = "src", "dst"
						table.insert(layers, { smart = { p = p, a = old, b = new } })
					end
				else
					local bd = backdrop_of(o, op * (if seg then p else 1))
					if bd then
						table.insert(layers, bd)
					end
					local L = layer_of(o)
					if seg then
						local mo = TProto.motion(seg.tr, o.w, o.h)
						moved(L, mo.to, p)
					end
					L.dx += dx
					L.dy += dy
					L.op *= op
					table.insert(layers, L)
				end
			end
		end
		local scr = nil
		for _, sg in active do
			if sg.kind == "screen" then
				scr = sg
			end
		end
		if scr then
			-- (a drag that scrubs it: `prog` gives its progress, see drag_run)
			local p = if scr.prog then scr.prog(now) else M.ease_at(scr.tr, (now - scr.t0) / (scr.t1 - scr.t0))
			local mo = TProto.motion(scr.tr, vw, vh)
			local a = moved(layer_of(scr.from), mo.from, p)
			local b = moved(layer_of(scr.to), mo.to, p)
			-- (B1) the same Screen in another look over itself (a Change to):
			-- compose draws only what differs, as one faded group would
			if mo.top == "to" and a.root == b.root then
				b.over = a
			end
			local function add_from()
				table.insert(layers, a)
				add_overlays(scr.from_ovl, a.dx, a.dy, a.op)
			end
			if mo.top == "to" then
				add_from()
				table.insert(layers, b)
			else
				table.insert(layers, b)
				add_from()
			end
			-- (step 3) Smart Animate, or a move that smart-animates its matching
			-- layers: the two Screens are its bases, the movers go over them
			if scr.tr and (scr.tr.k == "smart" or scr.tr.ml) then
				a.smart, b.smart = "src", "dst"
				table.insert(layers, { smart = { p = p, a = a, b = b } })
			end
		else
			table.insert(layers, layer_of(screen))
			add_overlays(overlays, 0, 0, 1)
		end
		-- overlays closing, on top
		for _, sg in active do
			if sg.kind == "close" then
				local p = M.ease_at(sg.tr, (now - sg.t0) / (sg.t1 - sg.t0))
				local o = sg.surf
				local bd = backdrop_of(o, 1 - p)
				if bd then
					table.insert(layers, bd)
				end
				local L = layer_of(o)
				local k = sg.tr and sg.tr.k or "instant"
				if k == "dissolve" then
					L.op = 1 - p
				else
					local mo = TProto.motion(sg.tr, o.w, o.h)
					moved(L, mo.from, p)
				end
				table.insert(layers, L)
			end
		end
		local hover = nil
		if hovered then
			hover = { root = hovered.surf.id, id = hovered.d.id, s = if press_look and press_look.d == hovered.d then "press" else "hover" }
		end
		return { t = now, vw = vw, vh = vh, layers = layers, hover = hover, label = label }
	end
	local function take_shot(label: string, index: number)
		if #views >= M.MAX_SHOTS then
			note(`no screenshot: at most {M.MAX_SHOTS} in one Simulate`)
			return
		end
		table.insert(views, view_at(label))
		res.shots = res.shots or {}
		table.insert(res.shots, { n = #views, step = index, t = math.floor(now + 0.5), label = label })
		if cur_step then
			cur_step.shot = #views
		end
	end

	-- ── run the steps ───────────────────────────────────────────────────────
	local function settle()
		while not runaway do
			local to = math.max(busy_until, chain_until)
			if to > now then
				advance(to)
			else
				break
			end
		end
	end

	-- A drag trigger runs (a drag of dx, dy, or none). As Play's drag_smart /
	-- scrub_p / scrub_land: when its first action smart-animates (navigate or
	-- Change to, on the Screen with no overlay open) and the dragged layer
	-- itself travels (Smart.drag_follows), the transition follows the drag
	-- along that layer's travel, then lands from there: forward when let go
	-- past half way, else back where it was (no history, the variant it had).
	-- A Simulate drag has no speed, so Play's fling rule never applies.
	-- Otherwise (a layer that stays, as a switch's track) it plays through.
	local function drag_run(l: any, surf: any, dx: number, dy: number)
		local a = l.a
		local act = if a.acts then a.acts[1] elseif a.go and a.go ~= "back" and not a.url then { k = "navigate", go = a.go, tr = a.tr } else nil
		local smart = act and (act.k == "navigate" or act.k == "changeTo") and not act.broken and act.tr
			and (act.tr.k == "smart" or act.tr.ml == true) and surf == screen and #overlays == 0
		if not smart or (dx == 0 and dy == 0) then
			run(l, surf)
			return
		end
		local n_seg, seq0, busy0, hist0 = #segments, seq, busy_until, #history
		local vstate0, vmem0 = vstate[surf.id], table.clone(vmem)
		run(l, surf)
		local sg = nil
		for k = n_seg + 1, #segments do
			local s = segments[k]
			if s.kind == "screen" and s.t0 == now and s.from == surf then
				sg = s
				break
			end
		end
		if not sg then
			return -- (it didn't go anywhere: a problem says why)
		end
		local function off_of(sf: any): (number) -> (number, number)
			local rb = sf.root.nodes[1].box
			local sh = shift_of(sf)
			return function(i: number): (number, number)
				local x, y = sh(i)
				return x - rb.x + sf.x, y - rb.y + sf.y
			end
		end
		local sa = sg.from.root.nodes
		local plan = Smart.plan(sa, sg.to.root.nodes, { so = off_of(sg.from), sd = off_of(sg.to) })
		if not Smart.drag_follows(plan, sa, l.id) then
			did(`{layer_name(surf, l.i)} doesn't travel itself: the transition plays through, as Figma`)
			cur_step.scrub = { follows = false }
			return
		end
		-- the way to drag (scrub_p): the dragged layer's own travel (8 pt or
		-- more), else the layer that travels most, else across the viewport
		local vx, vy, best = 0, 0, 0
		for _, mv in plan.movers do
			local tx, ty = mv.b.x - mv.a.x, mv.b.y - mv.a.y
			local it = mv.si and sa[mv.si]
			if it and it.id == l.id and tx * tx + ty * ty >= 64 then
				vx, vy, best = tx, ty, math.huge
			elseif mv.kind ~= "fade" and tx * tx + ty * ty > best then
				vx, vy, best = tx, ty, tx * tx + ty * ty
			end
		end
		local p = 0
		if best < 64 then
			if dx * dx + dy * dy >= 16 then
				if math.abs(dx) >= math.abs(dy) then
					vx, vy = if dx < 0 then -vw else vw, 0
				else
					vx, vy = 0, if dy < 0 then -vh else vh
				end
				p = math.clamp((dx * vx + dy * vy) / (vx * vx + vy * vy), 0, 1)
			end
		else
			p = math.clamp((dx * vx + dy * vy) / (vx * vx + vy * vy), 0, 1)
		end
		-- the landing (scrub_land): from p to an end, outCubic, the part of
		-- the transition's duration still to go (60 ms at least)
		local forward = p >= 0.5
		local target = if forward then 1 else 0
		local ms = math.max(60, (act.tr.ms or 300) * math.abs(target - p))
		local t0 = now
		sg.t1 = now + ms
		sg.prog = function(t: number): number
			local u = math.clamp((t - t0) / ms, 0, 1)
			return p + (target - p) * (1 - (1 - u) ^ 3)
		end
		for k = #events, 1, -1 do
			local e = events[k]
			if e.seq > seq0 then
				if forward then
					e.t = now + ms
				else
					table.remove(events, k)
				end
			end
		end
		busy_until = math.max(busy0, now + ms)
		local pct = math.floor(p * 100 + 0.5)
		cur_step.scrub = { follows = true, p = math.floor(p * 1000 + 0.5) / 1000, lands = if forward then "forward" else "back", ms = math.floor(ms + 0.5) }
		if forward then
			did(`the transition followed the drag to {pct}%: let go past half way, it lands forward ({math.floor(ms + 0.5)} ms)`)
			return
		end
		did(`the transition followed the drag to {pct}%: let go short of half way, it goes back ({math.floor(ms + 0.5)} ms)`)
		at(now + ms, nil, function()
			if act.k == "navigate" then
				while #history > hist0 do
					table.remove(history)
				end
			else
				table.clear(vmem)
				for k, x in vmem0 do
					vmem[k] = x
				end
				vstate[surf.id] = vstate0
				if screen == sg.to then
					screen = surf
				end
			end
		end)
	end

	cur_step = nil
	do
		local surf = new_surface("screen", start)
		local w, h = viewport_of(surf.root)
		surf.w, surf.h = w, h
		sync_scroll(surf, true)
		show(surf)
	end
	settle()

	for index, raw in steps do
		if runaway then
			break
		end
		local st, why = M.parse_step(raw)
		cur_step = { step = step_text(raw) }
		table.insert(res.steps, cur_step)
		if not st then
			cur_step.error = why
			continue
		end
		local verb = st.verb
		-- (input waits for a transition, as in Play)
		if verb ~= "wait" and verb ~= "shot" and busy() then
			local w = busy_until - now
			settle()
			cur_step.waited = math.floor(w + 0.5)
		end
		cur_step.t = math.floor(now + 0.5)
		local t0 = now
		local sig0 = signature()
		local ran0 = ran
		local skips0 = #if_skips
		local check_noop = false
		local function target_point(): (any?, number?, number?, number?)
			if st.target == nil then
				cur_step.error = `{verb} needs a layer: an id or a name path`
				return nil
			end
			local surf, i, err = locate(st.target)
			if not surf then
				cur_step.error = err
				problem("not-found", err :: string)
				return nil
			end
			local vx, vy, err2 = point_of(surf, i :: number, tostring(st.target))
			if not vx then
				cur_step.error = err2
				problem("offscreen", err2 :: string, { layer = surf.root.nodes[i :: number].id, screen = surf.id })
				return nil
			end
			local cover = covering(surf, i :: number, vx, vy :: number)
			if cover then
				problem("covered", `{layer_name(surf, i :: number)} on {surf_name(surf)} is under {cover} at its middle: a {verb} there goes to that instead`, { layer = surf.root.nodes[i :: number].id, screen = surf.id })
			end
			return surf, i, vx, vy
		end

		if verb == "click" then
			local surf, i, vx, vy = target_point()
			if surf then
				check_noop = true
				move_to(vx, vy)
				press_at(vx, vy)
				local r = release_at(vx, vy)
				if r == "nothing" then
					problem("dead-click", `clicking {layer_name(surf, i)} on {surf_name(surf)} does nothing: no click reaction on it or around it`, { layer = surf.root.nodes[i].id, screen = surf.id })
				end
			end
		elseif verb == "hover" then
			local surf, i, vx, vy = target_point()
			if surf then
				local h0 = held
				local ran1 = ran
				move_to(vx, vy)
				local n_under = 0
				for _ in under do
					n_under += 1
				end
				if not hovered and n_under == 0 and held == h0 and ran == ran1 then
					note(`nothing reacts to the pointer over {layer_name(surf, i)}: no hover look, hover, mouseEnter or mouseLeave trigger`)
				end
			end
		elseif verb == "leave" then
			move_to(-1e9, -1e9)
		elseif verb == "press" then
			local surf, _, vx, vy = target_point()
			if surf then
				move_to(vx, vy)
				press_at(vx, vy)
			end
		elseif verb == "release" then
			if not pressed then
				note("nothing is pressed")
			else
				release_at(pointer[1], pointer[2])
			end
		elseif verb == "drag" then
			local surf, i, vx, vy = target_point()
			if surf then
				check_noop = true
				move_to(vx, vy)
				press_at(vx, vy)
				local p = pressed
				local dx, dy = st.dx or 0, st.dy or 0
				local short = (dx ~= 0 or dy ~= 0) and dx * dx + dy * dy < DRAG_PT * DRAG_PT
				if p and p.drag and short then
					-- (Play: a press that moves less than 4 pt isn't a drag; let go, it's a click)
					note(`moved {math.floor(math.sqrt(dx * dx + dy * dy) * 10 + 0.5) / 10} pt: under {DRAG_PT} pt isn't a drag in Play (let go, it's a click)`)
				elseif p and p.drag and not busy() then
					local l = p.drag
					p.drag = nil
					p.link = nil -- (a drag isn't a click)
					p.acted = true
					drag_run(l, surf, dx, dy)
				elseif p and (dx ~= 0 or dy ~= 0) then
					p.link = nil
					p.acted = true
					-- (the finger moves the content with it: drag up scrolls down)
					local moves = scroll_at(vx, vy, -dx, -dy)
					if next(moves) == nil then
						note(`nothing scrolls under {layer_name(surf, i)} that way`)
					end
				else
					problem("no-reaction", `dragging {layer_name(surf, i)} on {surf_name(surf)} does nothing: no drag trigger on it or around it`, { layer = surf.root.nodes[i].id, screen = surf.id })
				end
				pointer = { vx + dx, vy + dy }
				release_at(pointer[1], pointer[2])
			end
		elseif verb == "scroll" then
			local vx, vy = vw / 2, vh / 2
			local ok = true
			if st.target ~= nil then
				local surf, i, err = locate(st.target)
				if not surf then
					cur_step.error = err
					ok = false
				else
					local raw, r = shown_rect(surf, i :: number)
					local rr = r or raw
					vx, vy = rr[1] + rr[3] / 2, rr[2] + rr[4] / 2
				end
			end
			if ok then
				local moves = scroll_at(vx, vy, st.dx or 0, st.dy or 0)
				if next(moves) == nil then
					note("nothing scrolled: nothing there can scroll that way (or it's at the end)")
				end
			end
		elseif verb == "key" then
			check_noop = true
			local mods = { Shift = false, Ctrl = false, Alt = false, Meta = false }
			local main = nil
			for _, k in st.keys or {} do
				local k2 = tostring(k)
				local norm = ({ shift = "Shift", ctrl = "Ctrl", control = "Ctrl", alt = "Alt", option = "Alt", meta = "Meta", cmd = "Meta" })[string.lower(k2)]
				if norm then
					mods[norm] = true
				else
					main = k2
				end
			end
			local combo = table.concat(st.keys or {}, "+")
			if not main then
				cur_step.error = `"{combo}" has no key besides modifiers`
			elseif main == "Escape" then
				-- (Play's Esc closes Play before key triggers see it)
				note("Escape closes Play: a key trigger on Escape never runs there")
			else
				local k = { key = if main == "Space" then " " else main, shift = mods.Shift, ctrl = mods.Ctrl, alt = mods.Alt, meta = mods.Meta }
				local done_key = false
				for _, s in surfaces_top_first() do
					for _, l in TProto.of_root(s.root).links do
						if not done_key and l.a.on == "key" and TProto.live(l.a) and TProto.key_match(l.a.keys, k) then
							done_key = true
							if not busy() then
								run(l, s)
							end
						end
					end
				end
				if not done_key then
					if (main == "ArrowLeft" or main == "Backspace") then
						check_noop = false
						player_back()
					elseif (main == "r" or main == "R") and not mods.Ctrl and not mods.Meta then
						check_noop = false
						restart()
					else
						check_noop = false
						problem("no-reaction", `the key {combo} does nothing on {shown_where()}: no key trigger for it`)
					end
				end
			end
		elseif verb == "wait" then
			local ms = math.clamp(st.ms or 0, 0, M.MAX_WAIT)
			advance(now + ms)
		elseif verb == "back" then
			player_back()
		elseif verb == "restart" then
			restart()
		elseif verb == "set" or verb == "mode" then
			-- (step 5) the agent sets a variable or a mode itself, as a set or
			-- mode action with no layer would (the page's mode)
			for _, asg in st.assign or {} do
				if verb == "mode" then
					local why = mode_why(asg.name, asg.value)
					if why then
						cur_step.error = why
					else
						act_runners.mode({ k = "mode", axis = asg.name, value = asg.value }, nil, function() end)
					end
				elseif not toks[asg.name] then
					cur_step.error = `the Design has no variable (Token) "{asg.name}"`
				else
					local inner = Expr.inner(asg.value)
					local act = if inner then { k = "set", var = asg.name, ex = inner } else { k = "set", var = asg.name, to = asg.value }
					act_runners.set(act, nil, function() end)
				end
			end
		elseif verb == "shot" then
			take_shot(st.label or `step {index}`, index)
		end

		-- a frame mid-way: { …, shot = ms } after the step began
		if type(st.shot) == "number" then
			advance(t0 + math.max(0, st.shot))
			take_shot(`{step_text(raw)} at {math.floor(st.shot)} ms`, index)
		end
		settle()
		if st.shot == true or (verb ~= "shot" and opts.shots == "each") then
			take_shot(`after {step_text(raw)}`, index)
		end
		local snap = snapshot()
		cur_step.screen = snap.screen.name
		if snap.overlays then
			cur_step.overlays = {}
			for _, o in snap.overlays do
				table.insert(cur_step.overlays, o.name)
			end
		end
		if check_noop and ran > ran0 and signature() == sig0 and not cur_step.error then
			local what = if cur_step.did then table.concat(cur_step.did, " ") else "its actions"
			if #if_skips > skips0 then
				-- (V7) an `if` that took an empty branch is a guard doing its job
				-- (a clamp at 0, a disabled button): a note, not a no-op problem,
				-- so a recipe that clamps runs clean and the reason stays visible
				note(`nothing changed: if {if_skips[#if_skips]}, and that branch is empty (a guard, such as a clamp)`)
			else
				problem("no-op", `{cur_step.step} ran ({what}) but nothing changed: same Screen, overlays, history and scroll`)
			end
		end
		if not cur_step.did and not cur_step.error and not cur_step.problems and (verb == "wait") then
			cur_step.did = { "nothing happened" }
		end
	end
	cur_step = nil
	if opts.shots == "end" and #views < M.MAX_SHOTS then
		take_shot("end", #steps)
	end

	local snap = snapshot()
	for k, v in snap do
		res[k] = v
	end
	if opts.check ~= false then
		for _, p in M.check(world, start) do
			local key = p.kind .. "|" .. p.message
			if not seen_problem[key] then
				seen_problem[key] = true
				table.insert(res.problems, p)
			end
		end
	end
	res.ok = #res.problems == 0
	if #res.problems == 0 then
		res.problems = nil
	end
	return res, views
end

-- ── the whole prototype, from where it starts ───────────────────────────────

local SHOWN = 8
-- (step 5) A reaction's acts with those inside `if` branches (then and
-- else, depth first), as a list: a navigate inside an if is a way on too.
local function each_act(acts: { any }?, out: { any }?, depth: number?): { any }
	local list = out or {}
	for _, act in acts or {} do
		table.insert(list, act)
		if act.k == "if" and (depth or 0) < 8 then
			each_act(act.th, list, (depth or 0) + 1)
			each_act(act.el, list, (depth or 0) + 1)
		end
	end
	return list
end
-- Problems a person would meet anywhere from `start`: Screens never
-- reached, Screens with no way on, links to nothing, links that can't be
-- clicked (under another layer, cut off, zero size), overlays with no way
-- out, reactions that do nothing, key triggers Play keeps for itself.
function M.check(world: any, start: string): { any }
	local roots = world.roots
	local out = {}
	local function add(kind: string, message: string, extra: any?)
		local p: any = { kind = kind, message = message }
		for k, v in extra or {} do
			p[k] = v
		end
		table.insert(out, p)
	end
	-- the graph: each frame's reactions → frames they show
	local edges: { [string]: { { to: string, overlay: boolean } } } = {}
	local overlay_only: { [string]: boolean } = {}
	local as_screen: { [string]: boolean } = {}
	for _, id in world.order do
		local list = {}
		for _, it in roots[id].nodes do
			for _, a in it.ia or {} do
				for _, act in each_act(a.acts) do
					if (act.k == "navigate" or act.k == "swap") and act.go and roots[act.go] and not act.broken then
						table.insert(list, { to = act.go, overlay = act.k == "swap" })
						if act.k == "navigate" then
							as_screen[act.go] = true
						end
					elseif act.k == "overlay" and act.go and roots[act.go] and not act.broken then
						table.insert(list, { to = act.go, overlay = true })
						overlay_only[act.go] = true
					end
				end
			end
		end
		edges[id] = list
	end
	for _, f in world.flows do
		as_screen[f.start] = true
	end
	as_screen[start] = true
	local reached: { [string]: boolean } = { [start] = true }
	local queue = { start }
	while #queue > 0 do
		local id = table.remove(queue, 1)
		for _, e in edges[id] or {} do
			if not reached[e.to] then
				reached[e.to] = true
				table.insert(queue, e.to)
			end
		end
	end
	local function names(list: { string }): string
		local shown = {}
		for i = 1, math.min(#list, SHOWN) do
			shown[i] = list[i]
		end
		return table.concat(shown, "; ") .. (if #list > SHOWN then `; and {#list - SHOWN} more` else "")
	end
	local function nm(id: string): string
		return `"{tostring(roots[id].nodes[1].name)}" ({id})`
	end
	-- unreachable: Screens (not frames only ever opened as overlays)
	local unreached = {}
	for _, id in world.order do
		if not reached[id] and not (overlay_only[id] and not as_screen[id]) then
			table.insert(unreached, nm(id))
		end
	end
	if #unreached > 0 and #unreached < #world.order then
		add("unreachable", `{#unreached} Screen{if #unreached == 1 then "" else "s"} can't be reached from {nm(start)}: {names(unreached)}. Link to them or start a flow there (fine for drafts and notes)`)
	end
	-- dead ends and stuck overlays, among what's reached
	local dead, stuck = {}, {}
	for _, id in world.order do
		if reached[id] then
			local any = false
			for _, it in roots[id].nodes do
				for _, a in it.ia or {} do
					if TProto.live(a) then
						any = true
					end
				end
			end
			local is_overlay = overlay_only[id] and not as_screen[id]
			if is_overlay then
				local ovl = roots[id].nodes[1].ovl or { co = true }
				if not any and not ovl.co then
					table.insert(stuck, nm(id))
				end
			elseif not any then
				table.insert(dead, nm(id))
			end
		end
	end
	if #dead > 0 then
		add("dead-end", `{#dead} Screen{if #dead == 1 then " has" else "s have"} no way on (no link, back or timer; only Play's own ← gets out): {names(dead)}. Fine for the last Screen of a flow`)
	end
	if #stuck > 0 then
		add("stuck-overlay", `{#stuck} overlay{if #stuck == 1 then "" else "s"} can't be closed (nothing in it reacts, and a click outside doesn't close it): {names(stuck)}. Add a close button (Link(btn, "close")) or closeOutside = true`)
	end
	-- links on what's reached: broken, under another layer, cut off, empty
	local broken, covered, cut, tiny, nothing, esc = {}, {}, {}, {}, {}, {}
	for _, id in world.order do
		if not reached[id] then
			continue
		end
		local root = roots[id]
		local nodes = root.nodes
		local plan = Scroll.plan(root, TProto.of_root(root).drivers)
		local function zero(_s: number): (number, number)
			return 0, 0
		end
		local function shift(i: number): (number, number, number)
			return Scroll.shift(plan, i, zero)
		end
		for i, it in nodes do
			if not it.ia then
				continue
			end
			local label = `"{tostring(it.name or it.id)}" on {tostring(nodes[1].name)}`
			local clickish = false
			for _, a in it.ia do
				for _, act in each_act(a.acts) do
					if act.broken then
						table.insert(broken, `{label} → "{tostring(act.go)}"`)
					end
				end
				local runs = false
				for _, act in a.acts or {} do
					if act.k ~= "motion" then
						runs = true
					end
				end
				if not runs then
					table.insert(nothing, `{label} ({a.on})`)
				end
				if a.on == "key" and a.keys then
					for _, k in a.keys do
						if k == "Escape" then
							table.insert(esc, label)
						end
					end
				end
				if a.on == "click" or a.on == "press" or a.on == "mouseDown" or a.on == "mouseUp" or a.on == "hover" or a.on == "mouseEnter" or a.on == "drag" then
					clickish = true
				end
			end
			-- (the Screen itself is under all it holds: not a covered link)
			if not clickish or it.hidden or i == 1 then
				continue
			end
			local x, y, w, h = Draw.canvas_bounds(it, Draw.local_map(it))
			if w < 1 or h < 1 then
				table.insert(tiny, label)
				continue
			end
			local dx, dy = shift(i)
			x += dx
			y += dy
			-- cut off by a clipping frame around it (scrollers aside: they scroll to it)
			local r: { number }? = { x, y, w, h }
			local j = plan.parent[i]
			local clipper = nil
			while j and r do
				local a = nodes[j]
				if a.clip and not a.ovf then
					local ax, ay, aw, ah = Draw.canvas_bounds(a, Draw.local_map(a))
					local sx, sy = shift(j)
					local x0, y0 = math.max(r[1], ax + sx), math.max(r[2], ay + sy)
					local x1, y1 = math.min(r[1] + r[3], ax + sx + aw), math.min(r[2] + r[4], ay + sy + ah)
					if x1 - x0 <= 0 or y1 - y0 <= 0 then
						r = nil
						clipper = a
					else
						r = { x0, y0, x1 - x0, y1 - y0 }
					end
				end
				j = plan.parent[j]
			end
			if not r then
				table.insert(cut, `{label} (cut off by "{tostring(clipper and clipper.name)}")`)
				continue
			end
			local cx, cy = r[1] + r[3] / 2, r[2] + r[4] / 2
			local k = TProto.deepest(root, cx, cy, function(q: number): (number, number, number)
				return shift(q)
			end)
			local n = it.n or 0
			if k ~= 0 and not (k >= i and k <= i + n) then
				table.insert(covered, `{label} (under "{tostring(nodes[k].name or nodes[k].id)}")`)
			end
		end
	end
	if #broken > 0 then
		add("broken-link", `{#broken} link{if #broken == 1 then " goes" else "s go"} to a frame that isn't there: {names(broken)}`)
	end
	if #covered > 0 then
		add("covered", `{#covered} link{if #covered == 1 then " is" else "s are"} under another layer at {if #covered == 1 then "its" else "their"} middle, so a click there goes to that layer: {names(covered)}. Move the link above it (later in its parent), or put the link on the covering layer`)
	end
	if #cut > 0 then
		add("hidden-link", `{#cut} link{if #cut == 1 then " is" else "s are"} cut off by a clipping frame, so nothing of {if #cut == 1 then "it" else "them"} shows: {names(cut)}`)
	end
	if #tiny > 0 then
		add("hidden-link", `{#tiny} link{if #tiny == 1 then " has" else "s have"} no size to click: {names(tiny)}`)
	end
	if #nothing > 0 then
		add("no-op", `{#nothing} reaction{if #nothing == 1 then "" else "s"} only play a motion, which isn't played yet: {names(nothing)}`)
	end
	if #esc > 0 then
		add("key-reserved", `key triggers on Escape never run in Play (Esc closes it): {names(esc)}. Use another key`)
	end
	return out
end

-- ── a view as one frame to draw ─────────────────────────────────────────────

local function translate(dx: number, dy: number): any
	return { a = 1, b = 0, c = 0, d = 1, e = dx, f = dy }
end

local function deep_same(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not deep_same(v, b[k]) then
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

-- Keys of a scene item that don't change how it itself looks.
local NOT_LOOK = { id = true, p = true, n = true, d = true, ia = true, st = true, sttr = true, vset = true, inst = true, vdef = true, name = true }

-- Whether two scene items paint the same (their own paint; children aside).
local function same_look(a: any, b: any): boolean
	for k, v in a do
		if not NOT_LOOK[k] and not deep_same(v, b[k]) then
			return false
		end
	end
	for k, v in b do
		if not NOT_LOOK[k] and a[k] == nil then
			return false
		end
	end
	return true
end

-- `items_of(root id)` → that root's scene items as the window draws them
-- (images, icons). Returns a root { id, nodes, live = { maps } } and the
-- box to draw (the viewport, Canvas units of the first layer's root), or
-- nil when nothing is left of it.
function M.compose(view: any, items_of: (string) -> { any }?, id: string): (any?, any?)
	local out = {}
	local maps = {}
	local base = nil
	-- (step 3) Smart Animate: plan each pair of bases once, over the items
	-- as drawn, with their scroll offsets
	local smart_items: { [any]: { any } } = {}
	for _, L in view.layers do
		local sm = L.smart
		if type(sm) == "table" then
			local sa, sb = sm.a.items or items_of(sm.a.root), sm.b.items or items_of(sm.b.root)
			if sa and sb and sa[1] and sb[1] then
				local function off(items: { any }, Ly: any): (number) -> (number, number)
					local plan = Scroll.plan({ id = "smart", nodes = items }, nil)
					local pos_by = Ly.pos or {}
					local rb = items[1].box
					return function(i: number): (number, number)
						local dx, dy = Scroll.shift(plan, i, function(s: number): (number, number)
							local q = pos_by[items[s].id]
							if q then
								return q[1], q[2]
							end
							return 0, 0
						end)
						return dx - rb.x + (Ly.x or 0), dy - rb.y + (Ly.y or 0)
					end
				end
				local plan = Smart.plan(sa, sb, { so = off(sa, sm.a), sd = off(sb, sm.b) })
				sm.a.hide, sm.a.strip = plan.src_hide, plan.src_strip
				sm.b.hide, sm.b.strip = plan.dst_hide, plan.dst_strip
				sm.plan = plan
				smart_items[sm] = { sa, sb }
			end
		end
	end
	-- (B1) A layer fading in over its own Screen in another look (`over`, a
	-- Change to). The window fades each item on its own, not the layer as one
	-- group, so drawing all of it at `op` washes the look under it out. As a
	-- group would: what's the same in both is drawn once (left out up here),
	-- what changed crossfades, and what only the look under it has fades out.
	local function base_of(L: any): { any }?
		local src = L.items or items_of(L.root)
		if src and src[1] and (L.hide or L.strip) then
			src = Smart.base(src, L.hide or {}, L.strip or {})
		end
		return src
	end
	local same_of: { [any]: { [string]: boolean } } = {}
	local fade_of: { [any]: { [string]: number } } = {}
	for _, L in view.layers do
		local A = L.over
		local op = L.op or 1
		if type(A) == "table" and op < 1 and (A.op or 1) >= 1 and (L.x or 0) + (L.dx or 0) == (A.x or 0) + (A.dx or 0)
			and (L.y or 0) + (L.dy or 0) == (A.y or 0) + (A.dy or 0) then
			local sb, sa = base_of(L), base_of(A)
			if sb and sa and sb[1] and sa[1] and sa[1].id == sb[1].id then
				local in_a, in_b = {}, {}
				for _, it in sa do
					in_a[it.id] = it
				end
				for _, it in sb do
					in_b[it.id] = true
				end
				-- (same look, and every parent the same: a changed parent drawn
				-- over would cover its children, so they're drawn again too)
				local same = {}
				local pa, pb = L.pos or {}, A.pos or {}
				for _, it in sb do
					local there = in_a[it.id]
					if (it.p == nil or same[it.p]) and there and deep_same(pa[it.id], pb[it.id]) and same_look(it, there) then
						same[it.id] = true
					end
				end
				local fade = {}
				for _, it in sa do
					-- (only the top of each gone subtree: opacity passes down)
					if not in_b[it.id] and (it.p == nil or in_b[it.p]) then
						fade[it.id] = 1 - op
					end
				end
				same_of[L], fade_of[A] = same, fade
			end
		end
	end
	for k, L in view.layers do
		if L.smart and type(L.smart) == "table" then
			local sm = L.smart
			local got = smart_items[sm]
			if base and got and sm.plan then
				local pieces = Smart.pieces(sm.plan, got[1], got[2], sm.p)
				for j, pc in pieces do
					local prefix = `{id}:{k}:m{j}:`
					for idx, it in pc.nodes do
						it.id = prefix .. it.id
						if it.p then
							it.p = prefix .. it.p
						end
						if idx == 1 and pc.op < 1 then
							it.op = math.max(0, (it.op or 1) * pc.op)
						end
						table.insert(out, it)
					end
					local m = pc.map or { a = 1, b = 0, c = 0, d = 1, e = 0, f = 0 }
					maps[pc.nodes[1].id] = { a = m.a, b = m.b, c = m.c, d = m.d, e = m.e + base.x, f = m.f + base.y }
				end
			end
			continue
		end
		if L.bg then
			if base then
				table.insert(out, {
					id = `{id}:bg{k}`, d = 0, n = 0, t = "rectangle",
					box = { x = base.x, y = base.y, w = view.vw, h = view.vh },
					shape = { k = "rect", r = { 0, 0, 0, 0 } },
					fill = { { k = "solid", color = L.bg } },
					op = if (L.op or 1) < 1 then math.max(0, L.op) else nil,
				})
			end
			continue
		end
		-- (a Smart Animate base: its movers left out)
		local src = base_of(L)
		if not src or not src[1] then
			continue
		end
		if same_of[L] then
			src = Smart.base(src, {}, same_of[L])
		end
		local items = {}
		local fade = fade_of[L]
		for i, it in src do
			items[i] = table.clone(it)
			if fade and fade[it.id] then
				items[i].op = (it.op or 1) * fade[it.id]
			end
		end
		if view.hover and view.hover.root == L.root then
			Scene.apply_state(items, view.hover.id, view.hover.s)
		end
		local rb = items[1].box
		base = base or rb
		local plan = Scroll.plan({ id = `{id}:{k}`, nodes = items }, nil)
		local pos_by = L.pos or {}
		local function pos(s: number): (number, number)
			local p = pos_by[items[s].id]
			if p then
				return p[1], p[2]
			end
			return 0, 0
		end
		local prefix = `{id}:{k}:`
		-- where each item moves as shown: its scroll shift less its parent's
		-- (maps compose down the tree)
		for i = 2, #items do
			local dx, dy = Scroll.shift(plan, i, pos)
			local p = plan.parent[i] or 1
			local px, py = 0, 0
			if p ~= 1 then
				px, py = Scroll.shift(plan, p, pos)
			end
			if math.abs(dx - px) > 1e-6 or math.abs(dy - py) > 1e-6 then
				maps[prefix .. items[i].id] = translate(dx - px, dy - py)
			end
		end
		local ox = base.x + (L.x or 0) + (L.dx or 0) - rb.x
		local oy = base.y + (L.y or 0) + (L.dy or 0) - rb.y
		if math.abs(ox) > 1e-6 or math.abs(oy) > 1e-6 then
			maps[prefix .. items[1].id] = translate(ox, oy)
		end
		-- paint order: fixed and sticky layers over what scrolls (Play lifts
		-- them into elements above it)
		local kids: { [number]: { number } } = {}
		for i = 2, #items do
			local p = plan.parent[i] or 1
			kids[p] = kids[p] or {}
			table.insert(kids[p], i)
		end
		local order = {}
		local function emit(i: number)
			table.insert(order, i)
			local list = kids[i]
			if not list then
				return
			end
			for _, c in list do
				if not items[c].scr then
					emit(c)
				end
			end
			for _, c in list do
				if items[c].scr then
					emit(c)
				end
			end
		end
		emit(1)
		for _, i in order do
			local it = items[i]
			it.id = prefix .. it.id
			if it.p then
				it.p = prefix .. it.p
			end
			if it.ovf then
				it.clip = true
			end
			if i == 1 then
				local op = (it.op or 1) * (L.op or 1)
				it.op = if op < 1 then math.max(0, op) else nil
				if L.overlay and (L.w < rb.w - 0.5 or L.h < rb.h - 0.5) then
					it.clip = true
				end
			end
			table.insert(out, it)
		end
	end
	if not base or #out == 0 then
		return nil, nil
	end
	return { id = id, nodes = out, live = { maps = maps } }, { x = base.x, y = base.y, w = view.vw, h = view.vh }
end

return M
