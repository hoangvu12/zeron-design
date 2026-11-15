--!nonstrict
-- Prototyping, step 1 (pure/anim/proto-step1-spec.md): the `states`,
-- `interactions` and Design-level `flows` keys. Their shapes and checks,
-- transitions (short strings → stored tables → what the tab plays), and the
-- lint rules. No dependency on the scene or the draft: callers pass in what
-- they know.

local U = require("./util")
local Resolve = require("./resolve")

local M = {}

M.STATES = { hover = true, press = true }
M.STATE_RESERVED = { focus = true, selected = true, disabled = true }
-- What a state may set (nothing that changes layout).
M.STATE_PROPS = { fill = true, stroke = true, effect = true, opacity = true, cornerRadius = true, scale = true }
local STATE_PROP_LIST = "fill, stroke, effect, opacity, cornerRadius and scale"
local LAYOUT = {
	width = true, height = true, x = true, y = true, padding = true, gap = true, layout = true, justifyContent = true,
	alignItems = true, content = true, fontSize = true, fontFamily = true, fontWeight = true, lineHeight = true,
	letterSpacing = true, textGrowth = true, textAlign = true, textAlignVertical = true, children = true, absolute = true,
	enabled = true, rotation = true, icon = true, weight = true, geometry = true, viewBox = true, clip = true,
	type = true, ref = true, polygonCount = true,
}

-- Triggers (Figma's): click; hover / press act while it lasts and revert
-- when it ends; mouseEnter / mouseLeave / mouseDown / mouseUp are one-off
-- events (`delay` ms: the pointer must stay that long); afterDelay fires
-- once `ms` after the Screen shows; key on a key combo; drag on a drag.
M.TRIGGERS = {
	click = true, hover = true, press = true, mouseEnter = true, mouseLeave = true, mouseDown = true, mouseUp = true,
	afterDelay = true, key = true, drag = true,
}
local TRIGGER_LIST = "click, hover, press, mouseEnter, mouseLeave, mouseDown, mouseUp, drag, { type = \"afterDelay\", ms } or { type = \"key\", keys }"
M.MOUSE_DELAY = { mouseEnter = true, mouseLeave = true, mouseDown = true, mouseUp = true }
-- Figma allows several of these on one layer; one of each of the others.
M.MULTI_TRIGGER = { key = true, drag = true }
M.MAX_DELAY_MS = 60000
-- Key names a `key` trigger takes (with one letter or digit, and the
-- modifiers Shift, Ctrl, Alt, Meta).
M.KEY_NAMES = {
	Enter = true, Escape = true, Space = true, Tab = true, Backspace = true, Delete = true, ArrowLeft = true,
	ArrowRight = true, ArrowUp = true, ArrowDown = true, Home = true, End = true, PageUp = true, PageDown = true,
	F1 = true, F2 = true, F3 = true, F4 = true, F5 = true, F6 = true, F7 = true, F8 = true, F9 = true, F10 = true,
	F11 = true, F12 = true,
}
M.MODIFIERS = { Shift = true, Ctrl = true, Alt = true, Meta = true }
-- `motion` is reserved for timeline motion (A2's `motion` key): its shape
-- { action = "motion", play = <motion id> } is stored; Play and the export
-- don't run it yet.
M.ACTIONS = { navigate = true, back = true, url = true, motion = true }
local ACTION_RESERVED = { overlay = true, swap = true, close = true, scrollTo = true, changeTo = true }
-- Per action kind, its own checks: fn(action, path, fail, target, ctx?).
-- Kinds that take part in a prototype add themselves here (and to
-- M.ACTIONS). `ctx` (step 5) = { kinds, themes } or nil.
M.ACTION_CHECKS = {} :: { [string]: (any, string, (string) -> (), (string) -> string?, any?) -> () }

M.TYPES = { instant = true, dissolve = true, moveIn = true, moveOut = true, push = true, slideIn = true, slideOut = true, smart = true }
M.DIRECTIONAL = { moveIn = true, moveOut = true, push = true, slideIn = true, slideOut = true }
M.DIRECTIONS = { left = true, right = true, up = true, down = true }

M.EASINGS = {
	linear = { 0, 0, 1, 1 },
	["ease-in"] = { 0.42, 0, 1, 1 },
	["ease-out"] = { 0, 0, 0.58, 1 },
	["ease-in-out"] = { 0.42, 0, 0.58, 1 },
	["ease-in-back"] = { 0.36, 0, 0.66, -0.56 },
	["ease-out-back"] = { 0.34, 1.56, 0.64, 1 },
	["ease-in-out-back"] = { 0.68, -0.6, 0.32, 1.6 },
}
local EASING_LIST =
	"linear, ease-in, ease-out, ease-in-out, ease-in-back, ease-out-back, ease-in-out-back, { x1, y1, x2, y2 }, a spring gentle, quick, bouncy or slow, or { spring = { mass, stiffness, damping } }"

-- Figma's spring presets. Figma doesn't publish their numbers; these are
-- the values commonly quoted for them [unverified]. A spring's duration is
-- its own (the physics settles it), as in Figma: a stored duration is kept
-- but not used.
M.SPRINGS = {
	gentle = { mass = 1, stiffness = 100, damping = 15 },
	quick = { mass = 1, stiffness = 300, damping = 20 },
	bouncy = { mass = 1, stiffness = 600, damping = 15 },
	slow = { mass = 1, stiffness = 80, damping = 20 },
}
M.SPRING_LIMITS = {
	mass = { 0.1, 100 },
	stiffness = { 1, 10000 },
	damping = { 0, 1000 },
	velocity = { -100, 100 },
}

-- A damped spring from rest at 0 to 1, in closed form: the same solver
-- zgx's anime uses (`spring(m, k, c, v)`), so Play, the panel's curve and
-- the export's CSS `linear()` agree. Returns x(t) (t in seconds) and its
-- settle time: when it stays within 0.001 of rest for 1/6 s at 120 Hz.
function M.spring(sp: any): ((number) -> number, number)
	local mass = math.clamp(U.num(sp.mass, 1), 1e-3, 1e4)
	local k = math.clamp(U.num(sp.stiffness, 100), 1e-3, 1e5)
	local c = math.clamp(U.num(sp.damping, 10), 1e-3, 1e4)
	local v = U.num(sp.velocity, 0)
	local w0 = math.sqrt(k / mass)
	local zeta = c / (2 * math.sqrt(k * mass))
	local wd = if zeta < 1 then w0 * math.sqrt(1 - zeta * zeta) else 0
	local b = if zeta < 1 then (zeta * w0 - v) / wd else -v + w0
	local function x(t: number): number
		if zeta < 1 then
			return 1 - math.exp(-t * zeta * w0) * (math.cos(wd * t) + b * math.sin(wd * t))
		end
		return 1 - (1 + b * t) * math.exp(-t * w0)
	end
	local step, hold = 1 / 120, 20
	local time, still = 0, 0
	while still < hold and time < 60 do
		time += step
		if math.abs(1 - x(time)) < 1e-3 then
			still += 1
		else
			still = 0
		end
	end
	return x, math.max(step, time - step * hold)
end

-- An easing's spring parameters, or nil when it's a curve.
function M.spring_of(e: any): any?
	if type(e) == "string" then
		return M.SPRINGS[e]
	end
	if type(e) == "table" and type(e.spring) == "table" then
		return e.spring
	end
	return nil
end

-- The spring as samples over its settle time: { {t 0..1, x} … }, `n` + 1
-- evenly spaced (CSS linear(), the curve drawn in the panel).
function M.spring_points(sp: any, n: number?): { number }
	local x, settle = M.spring(sp)
	local count = n or 40
	local out = {}
	for i = 0, count do
		out[i + 1] = if i == count then 1 else x(settle * i / count)
	end
	return out
end

M.DEFAULT_MS = 300
M.MAX_MS = 10000
M.DEFAULT_STATE_MS = 150

local function present(v: any): boolean
	return v ~= nil and not U.is_null(v)
end

-- A node (raw or resolved) takes part in a prototype.
function M.has(n: any): boolean
	return type(n) == "table" and (present(n.states) or present(n.interactions))
end

-- ── checks ────────────────────────────────────────────────────────────────

local function is_bezier(e: any): boolean
	if type(e) ~= "table" or #e ~= 4 then
		return false
	end
	for i = 1, 4 do
		if type(e[i]) ~= "number" then
			return false
		end
	end
	return e[1] >= 0 and e[1] <= 1 and e[3] >= 0 and e[3] <= 1
end

local function check_easing(e: any, path: string, fail: (string) -> ())
	if e == nil then
		return
	end
	if type(e) == "string" and M.EASINGS[e] then
		return
	end
	if type(e) == "string" and M.SPRINGS[e] then
		return
	end
	if type(e) == "table" and e.spring ~= nil then
		local sp = e.spring
		if type(sp) ~= "table" then
			fail(`{path}.easing.spring is \{ mass = 1, stiffness = 100, damping = 15 \}`)
		end
		for key, v in sp do
			local lim = M.SPRING_LIMITS[key]
			if not lim then
				fail(`{path}.easing.spring.{tostring(key)} isn't a spring key: a spring has mass, stiffness, damping and velocity`)
			end
			if type(v) ~= "number" or v ~= v or v < lim[1] or v > lim[2] then
				fail(`{path}.easing.spring.{key} is {lim[1]} to {lim[2]}, not {tostring(v)}`)
			end
		end
		for key, v in e do
			if key ~= "spring" then
				fail(`{path}.easing.{tostring(key)}: a spring easing is \{ spring = \{ mass, stiffness, damping \} \} only`)
			end
		end
		local _, settle = M.spring(sp)
		if settle * 1000 > M.MAX_MS then
			fail(`{path}.easing.spring takes {math.floor(settle * 1000)} ms to settle, over {M.MAX_MS}: raise damping or stiffness`)
		end
		return
	end
	if is_bezier(e) then
		return
	end
	fail(`{path}.easing is {EASING_LIST} (x1 and x2 within 0–1), not {tostring(e)}`)
end

local function check_duration(v: any, path: string, fail: (string) -> ())
	if v == nil then
		return
	end
	if type(v) ~= "number" or v ~= v or v < 0 or v > M.MAX_MS then
		fail(`{path}.duration is milliseconds, 0 to {M.MAX_MS}, not {tostring(v)}`)
	end
end

function M.check_transition(t: any, path: string, fail: (string) -> ())
	if t == nil or U.is_null(t) then
		return
	end
	if type(t) ~= "table" then
		fail(`{path} is a table \{ type = "push", direction = "left", duration = 300, easing = "ease-out" \} (Link takes short strings like "push-left")`)
	end
	local k = t.type
	if not M.TYPES[k] then
		fail(`{path}.type is instant, dissolve, moveIn, moveOut, push, slideIn, slideOut or smart, not {tostring(k)}`)
	end
	if M.DIRECTIONAL[k] then
		if not M.DIRECTIONS[t.direction] then
			fail(`{path}.direction is left, right, up or down (where the motion travels) for {k}, not {tostring(t.direction)}`)
		end
	elseif t.direction ~= nil and not M.DIRECTIONS[t.direction] then
		fail(`{path}.direction is left, right, up or down, not {tostring(t.direction)}`)
	end
	check_duration(t.duration, path, fail)
	check_easing(t.easing, path, fail)
	if t.matchLayers ~= nil and not U.is_null(t.matchLayers) then
		if type(t.matchLayers) ~= "boolean" then
			fail(`{path}.matchLayers is true or false, not {tostring(t.matchLayers)}`)
		end
		if t.matchLayers and not M.MATCH_LAYERS[k] then
			fail(`{path}.matchLayers ("Smart animate matching layers") goes with moveIn, moveOut, push, slideIn or slideOut, not {k}: use type = "smart" for Smart Animate`)
		end
	end
	for key in t do
		if key ~= "type" and key ~= "direction" and key ~= "duration" and key ~= "easing" and key ~= "matchLayers" then
			fail(`{path}.{tostring(key)} isn't a transition key: a transition has type, direction, duration, easing and matchLayers`)
		end
	end
end

-- Smart Animate (step 3, figma-parity.md §3.1): a node's `match` key pairs
-- it with the layer of the same key on the other Screen, instead of its
-- name path; `false` never matches it.
M.MATCH_LAYERS = { moveIn = true, moveOut = true, push = true, slideIn = true, slideOut = true }
function M.check_match(v: any, path: string, fail: (string) -> ())
	if v == false then
		return
	end
	if type(v) ~= "string" or v == "" or #v > 200 then
		fail(`{path} is a key shared by the two layers to pair ("hero-card"), or false to never pair it, not {tostring(v)}`)
	end
end

local function check_state_props(props: any, path: string, fail: (string) -> (), nested: boolean)
	if type(props) ~= "table" or (props[1] ~= nil) then
		fail(`{path} is a table of properties, as \{ fill = "$primary-hover", scale = 0.97 \}`)
	end
	for k, v in props do
		if type(k) ~= "string" then
			fail(`{path}: its keys are property names`)
		end
		if k == "descendants" and not nested then
			if type(v) ~= "table" then
				fail(`{path}.descendants is a table \{ <layer id or name> = \{ fill = … \} \}`)
			end
			for key, sub in v do
				if type(key) ~= "string" then
					fail(`{path}.descendants: its keys are layer ids or names`)
				end
				check_state_props(sub, `{path}.descendants.{key}`, fail, true)
			end
		elseif M.STATE_PROPS[k] then
			if U.is_null(v) or Resolve.refers(v) then
				continue
			end
			if k == "opacity" and (type(v) ~= "number" or v < 0 or v > 1) then
				fail(`{path}.opacity is 0 to 1, not {tostring(v)}`)
			elseif k == "scale" and (type(v) ~= "number" or v < 0.5 or v > 2) then
				fail(`{path}.scale is 0.5 to 2 (about the centre), not {tostring(v)}`)
			elseif k == "cornerRadius" and type(v) ~= "number" and not (type(v) == "table" and #v == 4) then
				fail(`{path}.cornerRadius is a number or \{ tl, tr, br, bl \}, not {tostring(v)}`)
			end
		elseif LAYOUT[k] or k == "descendants" then
			fail(`{path}.{k} can't change in a state: use a separate Screen or a variant (a state sets {STATE_PROP_LIST})`)
		else
			fail(`{path}.{k} isn't a state property: a state sets {STATE_PROP_LIST}`)
		end
	end
end

function M.check_states(states: any, path: string, fail: (string) -> ())
	if type(states) ~= "table" or states[1] ~= nil then
		fail(`{path} is a table \{ hover = \{…\}, press = \{…\}, transition = \{ duration, easing \} \}`)
	end
	for name, v in states do
		if name == "transition" then
			if U.is_null(v) then
				continue
			end
			if type(v) ~= "table" then
				fail(`{path}.transition is \{ duration = 150, easing = "ease-out" \}`)
			end
			check_duration(v.duration, `{path}.transition`, fail)
			check_easing(v.easing, `{path}.transition`, fail)
			for key in v do
				if key ~= "duration" and key ~= "easing" then
					fail(`{path}.transition.{tostring(key)}: a state transition has duration and easing`)
				end
			end
		elseif M.STATES[name] then
			if not U.is_null(v) then
				check_state_props(v, `{path}.{name}`, fail, false)
			end
		elseif M.STATE_RESERVED[name] then
			fail(`{path}.{name} isn't supported yet: states are hover and press`)
		else
			fail(`{path}.{tostring(name)} isn't a state: states are hover and press (and transition)`)
		end
	end
end

-- `target(id)` → nil when `id` may be linked to, else why not.
function M.check_interactions(list: any, path: string, fail: (string) -> (), target: (string) -> string?, ctx: any?)
	if type(list) ~= "table" or (next(list) ~= nil and list[1] == nil) then
		fail(`{path} is a list: \{ \{ trigger = "click", actions = \{ \{ action = "navigate", to = id \} \} \} \}`)
	end
	for i, r in list do
		local p = `{path}[{i}]`
		if type(r) ~= "table" then
			fail(`{p} is \{ trigger = "click", actions = \{…\} \}`)
		end
		M.check_trigger(r.trigger, `{p}.trigger`, fail)
		if r.action ~= nil then
			fail(`{p}: actions go in a list, actions = \{ \{ action = …\} \}`)
		end
		if type(r.actions) ~= "table" or (next(r.actions) ~= nil and r.actions[1] == nil) then
			fail(`{p}.actions is a list of \{ action = "navigate" | "back" | "url", … \}`)
		end
		M.check_actions(r.actions, `{p}.actions`, fail, target, ctx, 0)
	end
end

-- A list of actions (a reaction's, or an if's then/else). `ctx` (step 5):
-- { kinds = { [token] = kind }, themes } to check variables against, or nil.
M.MAX_IF_DEPTH = 8
function M.check_actions(list: any, path: string, fail: (string) -> (), target: (string) -> string?, ctx: any?, depth: number)
	if type(list) ~= "table" or (next(list) ~= nil and list[1] == nil) then
		fail(`{path} is a list of actions: \{ \{ action = "navigate", to = id \} \}`)
	end
	for j, a in list do
		local q = `{path}[{j}]`
		if type(a) ~= "table" then
			fail(`{q} is \{ action = "navigate", to = id \}`)
		end
		local kind = a.action
		if not M.ACTIONS[kind] then
			local names = {}
			for k in M.ACTIONS do
				table.insert(names, k)
			end
			table.sort(names)
			local list_ = table.concat(names, ", ")
			if ACTION_RESERVED[kind] then
				fail(`{q}.action "{tostring(kind)}" isn't supported yet: use {list_}`)
			end
			fail(`{q}.action is {list_}, not {tostring(kind)}`)
		end
		if kind == "if" then
			if depth >= M.MAX_IF_DEPTH then
				fail(`{q}: ifs nest at most {M.MAX_IF_DEPTH} deep`)
			end
			M.check_if(a, q, fail, ctx)
			for _, branch in { "then", "else" } do
				if a[branch] ~= nil then
					M.check_actions(a[branch], `{q}.{branch}`, fail, target, ctx, depth + 1)
				end
			end
			continue
		end
		local check = M.ACTION_CHECKS[kind]
		if check then
			check(a, q, fail, target, ctx)
		end
	end
end

-- A trigger: a name, or { type = name, … } with its own settings. Returns
-- its name.
function M.check_trigger(t: any, p: string, fail: (string) -> ()): string
	local name = if type(t) == "table" then t.type else t
	if type(name) ~= "string" or not M.TRIGGERS[name] then
		fail(`{p} is {TRIGGER_LIST}, not {tostring(name)}`)
	end
	if name == "afterDelay" then
		if type(t) ~= "table" or type(t.ms) ~= "number" or t.ms ~= t.ms or t.ms < 0 or t.ms > M.MAX_DELAY_MS then
			fail(`{p} is \{ type = "afterDelay", ms = 1500 \} (ms 0 to {M.MAX_DELAY_MS}), not {tostring(if type(t) == "table" then t.ms else t)}`)
		end
	elseif name == "key" then
		if type(t) ~= "table" then
			fail(`{p} is \{ type = "key", keys = "Enter" \} or \{ type = "key", keys = \{ "Ctrl", "K" \} \}`)
		end
		M.check_keys(t.keys, `{p}.keys`, fail)
	end
	if type(t) == "table" then
		for key, v in t do
			if key == "type" or (key == "ms" and name == "afterDelay") or (key == "keys" and name == "key") then
				continue
			end
			if key == "delay" and M.MOUSE_DELAY[name] then
				if type(v) ~= "number" or v ~= v or v < 0 or v > M.MAX_DELAY_MS then
					fail(`{p}.delay is milliseconds, 0 to {M.MAX_DELAY_MS}, not {tostring(v)}`)
				end
				continue
			end
			local takes = if name == "afterDelay"
				then "type and ms"
				elseif name == "key" then "type and keys"
				elseif M.MOUSE_DELAY[name] then "type and delay"
				else "type only"
			fail(`{p}.{tostring(key)}: a {name} trigger takes {takes}`)
		end
	end
	return name
end

-- A key combo: one key, with modifiers before it ("Enter", { "Shift", "A" }).
function M.check_keys(keys: any, p: string, fail: (string) -> ())
	local list = if type(keys) == "string" then { keys } else keys
	if type(list) ~= "table" or #list == 0 then
		fail(`{p} is a key ("Enter", "ArrowRight", "k") or a combo \{ "Ctrl", "K" \}`)
	end
	local main = 0
	for _, k in list do
		if type(k) ~= "string" then
			fail(`{p}: each key is a name, as "Enter"`)
		end
		if M.MODIFIERS[k] then
			continue
		end
		if M.KEY_NAMES[k] or (#k == 1 and string.match(k, "^[%w%p]$")) then
			main += 1
		else
			fail(`{p}: "{k}" isn't a key: use one letter or digit, Enter, Escape, Space, Tab, Backspace, Delete, the arrows (ArrowLeft…), Home, End, PageUp, PageDown, F1–F12, with Shift, Ctrl, Alt or Meta`)
		end
	end
	if main ~= 1 then
		fail(`{p} has one key besides its modifiers (Shift, Ctrl, Alt, Meta), not {main}`)
	end
end

-- A trigger's name ("click" when it has none).
function M.trigger_name(t: any): string
	local name = if type(t) == "table" then t.type else t
	return if type(name) == "string" then name else "click"
end

M.ACTION_CHECKS.navigate = function(a, q, fail, target)
	if type(a.to) ~= "string" or a.to == "" then
		fail(`{q}.to is the id of the Screen to go to`)
	end
	local why = target(a.to)
	if why then
		fail(`{q}.to "{a.to}" is not a Screen{why}`)
	end
	M.check_transition(a.transition, `{q}.transition`, fail)
end
M.ACTION_CHECKS.back = function(a, q, fail, _target)
	M.check_transition(a.transition, `{q}.transition`, fail)
end
M.ACTION_CHECKS.url = function(a, q, fail, _target)
	if type(a.url) ~= "string" or not (string.match(a.url, "^https?://") or string.match(a.url, "^mailto:")) then
		fail(`{q}.url is an http(s) or mailto: link, not {tostring(a.url)}`)
	end
	if a.newTab ~= nil and type(a.newTab) ~= "boolean" then
		fail(`{q}.newTab is true or false`)
	end
end
M.ACTION_CHECKS.motion = function(a, q, fail, _target)
	if type(a.play) ~= "string" or a.play == "" then
		fail(`{q}.play is the id of the motion to play (reserved: timeline motion isn't played yet)`)
	end
	for key in a do
		if key ~= "action" and key ~= "play" then
			fail(`{q}.{tostring(key)}: a motion action is \{ action = "motion", play = id \} (reserved)`)
		end
	end
end

function M.check_flows(list: any, fail: (string) -> (), target: (string) -> string?)
	if type(list) ~= "table" or (next(list) ~= nil and list[1] == nil) then
		fail(`flows is a list: \{ \{ name = "Onboarding", start = screenId \} \}`)
	end
	for i, f in list do
		if type(f) ~= "table" or type(f.name) ~= "string" or f.name == "" then
			fail(`flows[{i}] is \{ name = "…", start = screenId \}`)
		end
		if type(f.start) ~= "string" then
			fail(`flows[{i}].start is the id of its first Screen`)
		end
		local why = target(f.start)
		if why then
			fail(`flows[{i}].start "{f.start}" is not a Screen{why}`)
		end
		-- (step 6) plain text: lines starting "- " or "1. " show as lists,
		-- URLs as links (Play's flows sidebar)
		local desc = f.description
		if desc ~= nil and not U.is_null(desc) then
			if type(desc) ~= "string" then
				fail(`flows[{i}].description is plain text (lines starting "- " or "1. " show as lists)`)
			elseif utf8.len(desc) == nil then
				fail(`flows[{i}].description isn't valid UTF-8`)
			elseif (utf8.len(desc) :: number) > M.FLOW_DESCRIPTION_MAX then
				fail(`flows[{i}].description is at most {M.FLOW_DESCRIPTION_MAX} characters, not {utf8.len(desc)}`)
			end
		end
	end
end
M.FLOW_DESCRIPTION_MAX = 2000

-- Every `to` / `start` id inside `v` (interactions, overrides, flows).
function M.targets_in(v: any, out: { [string]: boolean }, depth: number?)
	if type(v) ~= "table" or (depth or 0) > 64 then
		return
	end
	-- (step 5) a set's `to` is a value, not an id
	if v.action == "set" then
		return
	end
	for k, x in v do
		if (k == "to" or k == "start") and type(x) == "string" then
			out[x] = true
		elseif type(x) == "table" then
			M.targets_in(x, out, (depth or 0) + 1)
		end
	end
end

-- ── transitions ───────────────────────────────────────────────────────────

local SHORT_KIND = {
	instant = "instant", dissolve = "dissolve", smart = "smart", push = "push", slide = "slideIn",
	["slide-in"] = "slideIn", ["slide-out"] = "slideOut", move = "moveIn", ["move-in"] = "moveIn", ["move-out"] = "moveOut",
}
local SHORT_DIR = { left = "left", right = "right", up = "up", down = "down", top = "up", bottom = "down" }

-- "push-left", "slide-up", "dissolve", … → the stored table; a table as is.
function M.expand(t: any): (any, string?)
	if t == nil or U.is_null(t) then
		return nil
	end
	if type(t) == "table" then
		return t
	end
	if type(t) ~= "string" then
		return nil, `a transition is a table or a short string as "push-left", not {tostring(t)}`
	end
	local s = string.lower(t)
	local kind, dir = SHORT_KIND[s], nil
	if not kind then
		local head, d = string.match(s, "^(.-)%-(%a+)$")
		if head and SHORT_KIND[head] and SHORT_DIR[d] then
			kind, dir = SHORT_KIND[head], SHORT_DIR[d]
		end
	end
	if not kind then
		return nil, `"{t}" isn't a transition: use instant, dissolve, push-<dir>, slide-in-<dir>, slide-out-<dir>, move-in-<dir> or move-out-<dir> (<dir> = left, right, up, down)`
	end
	if M.DIRECTIONAL[kind] and not dir then
		return nil, `"{t}" needs a direction: "{s}-left", "{s}-right", "{s}-up" or "{s}-down"`
	end
	if kind == "instant" then
		return { type = "instant" }
	end
	return { type = kind, direction = dir, duration = M.DEFAULT_MS, easing = "ease-out" }
end

function M.bezier(e: any): { number }
	if type(e) == "string" and M.EASINGS[e] then
		return table.clone(M.EASINGS[e])
	end
	if is_bezier(e) then
		return { e[1], e[2], e[3], e[4] }
	end
	return table.clone(M.EASINGS["ease-out"])
end

-- An easing as the tab plays it: `ease` (bézier numbers, also the fallback
-- for a spring) and `sp = { m, k, c, v }` with its settle time in ms.
function M.played_ease(e: any): ({ number }, any?, number?)
	local sp = M.spring_of(e)
	if sp then
		local _, settle = M.spring(sp)
		local ms = math.max(1, math.floor(settle * 1000 + 0.5))
		return M.bezier("ease-out"), { m = U.num(sp.mass, 1), k = U.num(sp.stiffness, 100), c = U.num(sp.damping, 10), v = U.num(sp.velocity, 0) }, ms
	end
	return M.bezier(e), nil, nil
end

-- A stored transition as the tab plays it: { k, dir?, ms, ease, sp? }.
-- With a spring, `ms` is the spring's own settle time.
function M.played(t: any): any
	if type(t) ~= "table" or t.type == "instant" then
		return { k = "instant", ms = 0, ease = M.bezier("ease-out") }
	end
	local k = t.type
	local ease, sp, sp_ms = M.played_ease(t.easing)
	return {
		k = k,
		dir = if M.DIRECTIONAL[k] then t.direction else nil,
		ms = sp_ms or U.num(t.duration, M.DEFAULT_MS),
		ease = ease,
		sp = sp,
		-- (step 3) Smart animate the matching layers over a directional move
		ml = if t.matchLayers == true and M.MATCH_LAYERS[k] then true else nil,
	}
end

-- The actions that change the Screen (or leave it, for a URL).
M.MOVES = { navigate = true, back = true, url = true }

-- The first action of each reaction that changes the Screen.
function M.first_moves(list: any): { any }
	local out = {}
	for _, r in U.list(list) do
		if type(r) == "table" then
			for _, a in U.list(r.actions) do
				if type(a) == "table" and M.MOVES[a.action] then
					table.insert(out, a)
					break
				end
			end
		end
	end
	return out
end

-- Every action of every reaction that changes the Screen, in order (they
-- all run, one after another, as in Figma). (step 5) Those inside an if's
-- then/else count too (noodles, broken links).
function M.moves(list: any): { any }
	local out = {}
	local function each(acts, depth)
		for _, a in U.list(acts) do
			if type(a) == "table" then
				if M.MOVES[a.action] then
					table.insert(out, a)
				elseif a.action == "if" and depth < 16 then
					each(a["then"], depth + 1)
					each(a["else"], depth + 1)
				end
			end
		end
	end
	for _, r in U.list(list) do
		if type(r) == "table" then
			each(r.actions, 0)
		end
	end
	return out
end

-- The Screen ids a node links to (navigate), in order.
function M.links(n: any): { string }?
	if type(n) ~= "table" or type(n.interactions) ~= "table" then
		return nil
	end
	local out = {}
	for _, a in M.moves(n.interactions) do
		if a.action == "navigate" and type(a.to) == "string" then
			table.insert(out, a.to)
		end
	end
	return if #out > 0 then out else nil
end

-- The Screens of a doc: top-level frames that aren't Components.
function M.screens(doc: any): { [string]: string }
	local out = {}
	for _, n in U.list(doc.children) do
		if type(n) == "table" and n.type == "frame" and n.reusable ~= true and type(n.id) == "string" then
			out[n.id] = tostring(n.name or n.id)
		end
	end
	return out
end

-- A state's `descendants` key → the item ids it reaches inside the driver
-- (`within`: the driver's subtree items, after the driver): a child id, its
-- slash id, a slash path, or a name that's unique there.
function M.reach(key: string, driver: string, within: { any }): { string }
	local ids = {}
	for _, it in within do
		if it.id == key or it.id == driver .. "/" .. key then
			return { it.id }
		end
	end
	local suffix = "/" .. key
	for _, it in within do
		if string.sub(it.id, -#suffix) == suffix then
			table.insert(ids, it.id)
		end
	end
	if #ids == 1 then
		return ids
	end
	ids = {}
	for _, it in within do
		if it.name == key then
			table.insert(ids, it.id)
		end
	end
	return if #ids == 1 then ids else {}
end

-- ── lint ──────────────────────────────────────────────────────────────────

local SHOWN = 6
local function report(warnings: { any }, rule: string, list: { string }, what: string)
	if #list == 0 then
		return
	end
	local shown = {}
	for i = 1, math.min(#list, SHOWN) do
		shown[i] = list[i]
	end
	local more = if #list > SHOWN then `, and {#list - SHOWN} more` else ""
	table.insert(warnings, { lint = rule, message = `{#list} {what}: {table.concat(shown, "; ")}{more}` })
end

local function muted(n: any, off: any, rule: string): boolean
	if off == true or n.lint == false then
		return true
	end
	local list = n.lintIgnore
	if type(list) == "string" then
		list = { list }
	end
	return type(list) == "table" and table.find(list, rule) ~= nil
end

local LINT_RULES = { "broken-link", "nested-link", "smart-fallback", "state-target", "dead-end", "duplicate-trigger", "motion-reserved", "smart-nothing-matches" }

-- (step 3) A doc subtree as the flat list Smart's matching reads: { id, p,
-- name, mt } in paint order.
function M.match_items(root: any): { any }
	local out = {}
	local function walk(n, parent)
		if type(n) ~= "table" or n.enabled == false then
			return
		end
		table.insert(out, { id = tostring(n.id), p = parent, name = n.name, mt = n.match })
		for _, c in U.list(n.children) do
			walk(c, tostring(n.id))
		end
	end
	walk(root, nil)
	return out
end

-- Over the drawn roots, after a change: `ctx = { changed, deleted, touched
-- (prototype keys or flows changed), doc }`. Adds warnings.
function M.lint(ctx: any, roots: { any }, warnings: { any })
	local doc = ctx.doc
	local screens = M.screens(doc)
	local broken, nested, smart, missing = {}, {}, {}, {}
	local dupes, motions = {}, {}
	local smart_pairs = {}
	local reached, out_of = {}, {}
	local function hot_of(id: string): boolean
		return ctx.changed[id] == true or ctx.changed[string.match(id, "^([^/]+)") or id] == true
	end
	local function walk(n, root, in_link, hot, ignore)
		hot = hot or hot_of(n.id)
		local my_ignore = {}
		for _, rule in LINT_RULES do
			my_ignore[rule] = (ignore and ignore[rule]) or muted(n, nil, rule)
		end
		local linking = false
		if type(n.interactions) == "table" then
			-- Triggers: one of each per layer (key and drag may repeat), and
			-- not click with hover (Figma's rules; Play runs the first).
			local seen, dup = {}, {}
			for _, r in U.list(n.interactions) do
				if type(r) ~= "table" then
					continue
				end
				local tn = M.trigger_name(r.trigger)
				if seen[tn] and not M.MULTI_TRIGGER[tn] and not dup[tn] then
					dup[tn] = true
					if hot and not my_ignore["duplicate-trigger"] then
						table.insert(dupes, `{tostring(n.name)} ({tn})`)
					end
				end
				seen[tn] = true
				for _, a in U.list(r.actions) do
					if type(a) == "table" and a.action == "motion" and hot and not my_ignore["motion-reserved"] then
						table.insert(motions, tostring(n.name))
					end
				end
				if tn == "click" then
					for _, a in U.list(r.actions) do
						if type(a) == "table" and M.MOVES[a.action] then
							linking = true
						end
					end
				end
			end
			if seen.click and seen.hover and hot and not my_ignore["duplicate-trigger"] then
				table.insert(dupes, `{tostring(n.name)} (click and hover: use mouseEnter and mouseLeave with click)`)
			end
			for _, a in M.moves(n.interactions) do
				out_of[root] = true
				if a.action == "navigate" and type(a.to) == "string" then
					if screens[a.to] then
						reached[a.to] = true
					elseif (hot or ctx.deleted[a.to]) and not my_ignore["broken-link"] then
						table.insert(broken, `{tostring(n.name)} → "{a.to}"` .. (if ctx.deleted[a.to] then ` ({ctx.deleted[a.to]}, deleted)` else ""))
					end
				end
				if hot and type(a.transition) == "table" and (a.transition.type == "smart" or a.transition.matchLayers == true) and type(a.to) == "string" and screens[a.to] then
					table.insert(smart_pairs, { from = root, to = a.to, name = tostring(n.name), ignore = my_ignore["smart-nothing-matches"] })
				end
			end
			-- overlays (step 2): their frames must be there; smart doesn't
			-- apply to opening one (Figma's rule), only to a swap
			for _, r in U.list(n.interactions) do
				for _, a in U.list(type(r) == "table" and r.actions or nil) do
					if type(a) ~= "table" or (a.action ~= "overlay" and a.action ~= "swap") or type(a.to) ~= "string" then
						continue
					end
					if not screens[a.to] and (hot or ctx.deleted[a.to]) and not my_ignore["broken-link"] then
						table.insert(broken, `{tostring(n.name)} → overlay "{a.to}"` .. (if ctx.deleted[a.to] then ` ({ctx.deleted[a.to]}, deleted)` else ""))
					end
					if hot and a.action == "overlay" and type(a.transition) == "table" and a.transition.type == "smart" and not my_ignore["smart-fallback"] then
						table.insert(smart, `{tostring(n.name)} ({a.action})`)
					end
				end
			end
			if linking and in_link and hot and not my_ignore["nested-link"] then
				table.insert(nested, `{tostring(n.name)} (inside {in_link})`)
			end
		end
		if hot and type(n.states) == "table" and not my_ignore["state-target"] then
			local within = {}
			local function gather(x)
				for _, c in (x.children or {}) do
					table.insert(within, { id = c.id, name = c.name })
					gather(c)
				end
			end
			for _, s in { "hover", "press" } do
				local st = n.states[s]
				if type(st) == "table" and type(st.descendants) == "table" then
					if #within == 0 then
						gather(n)
					end
					for key in st.descendants do
						if #M.reach(key, n.id, within) == 0 then
							table.insert(missing, `{tostring(n.name)} states.{s}.descendants "{key}"`)
						end
					end
				end
			end
		end
		local next_link = if linking then (in_link or tostring(n.name)) else in_link
		for _, c in (n.children or {}) do
			walk(c, root, next_link, hot, my_ignore)
		end
	end
	for _, r in roots do
		walk(r, r.id, nil, false, nil)
	end
	report(warnings, "broken-link", broken, "links to a Screen that isn't there (deleted, or not a Screen)")
	report(warnings, "nested-link", nested, "links inside another link (the HTML export can't make both real links)")
	report(warnings, "smart-fallback", smart, "Smart Animate on opening an overlay, which dissolves (Figma's rule: it applies to Swap overlay, not Open)")
	-- (step 3) two Screens a smart link joins that share no layer name
	if #smart_pairs > 0 then
		local Smart = require("../tab/smart")
		local by_id = {}
		for _, r in roots do
			by_id[r.id] = r
		end
		local none, seen = {}, {}
		for _, sp in smart_pairs do
			local a, b = by_id[sp.from], by_id[sp.to]
			local key = sp.from .. ">" .. sp.to
			if a and b and not seen[key] and not sp.ignore then
				seen[key] = true
				local pairs_ = Smart.match(M.match_items(a), M.match_items(b))
				if pairs_.count == 0 then
					table.insert(none, `{sp.name}: {tostring(a.name)} → {tostring(b.name)}`)
				end
			end
		end
		report(warnings, "smart-nothing-matches", none, "smart links between Screens that share no layer name, so everything dissolves (Copy the Screen, then edit the copy; or CheckSmart(a, b))")
	end
	report(warnings, "state-target", missing, "state overrides that match no layer inside their node (use a child's id or unique name)")
	report(warnings, "duplicate-trigger", dupes, "layers with a trigger twice (one each per layer, key and drag aside: only the first runs)")
	report(warnings, "motion-reserved", motions, "motion actions, which are kept but don't play yet")
	if ctx.touched and type(doc.flows) == "table" and #doc.flows > 0 then
		local dead = {}
		for id, name in screens do
			if reached[id] and not out_of[id] then
				table.insert(dead, `{name} ({id})`)
			end
		end
		table.sort(dead)
		report(warnings, "dead-end", dead, "Screens reached by a link with no link or back out of them")
	end
end

-- ── scrolling and the device (step 2, figma-parity.md §3.2) ────────────────
-- Node `overflow = "vertical" | "horizontal" | "both"`: the frame scrolls its
-- content in Play and the export (it always clips there). Node `scroll =
-- "fixed" | "sticky"`: a child that stays put while its scrolling parent
-- scrolls (fixed), or scrolls until its top reaches the scroller's top, then
-- sticks inside its own parent (sticky, vertical). Design `prototype = {
-- device, rotate, fit, background }`. Action `scrollTo`; navigate's
-- `resetScroll`.

M.OVERFLOW = { vertical = true, horizontal = true, both = true }
M.SCROLL = { fixed = true, sticky = true }
-- Device presets: Figma's frame presets of the same names (points). Step 6
-- (pure/anim/f6/PLAN.md E1): `frame` = the drawn frame's kind
-- (engine/device_frame.luau), `models` = its colours (first = default),
-- `group` = the dropdown's group. tab/scroll.luau mirrors this table (a
-- test keeps them equal).
local ISLAND_16 = { "Black", "White", "Pink", "Teal", "Ultramarine" }
local ISLAND_PRO = { "Black Titanium", "White Titanium", "Natural Titanium", "Desert Titanium" }
local ISLAND_17 = { "Black", "White", "Mist Blue", "Sage", "Lavender" }
local ISLAND_17_PRO = { "Silver", "Cosmic Orange", "Deep Blue" }
local IPAD = { "Space Gray", "Silver" }
local MAC = { "Space Gray", "Silver", "Starlight", "Midnight" }
local WATCH = { "Midnight", "Starlight", "Silver", "Red" }
M.DEVICES = {
	["iphone-17"] = { w = 402, h = 874, label = "iPhone 17", group = "Phones", frame = "phone-island", models = ISLAND_17 },
	["iphone-17-pro"] = { w = 402, h = 874, label = "iPhone 17 Pro", group = "Phones", frame = "phone-island", models = ISLAND_17_PRO },
	["iphone-17-pro-max"] = { w = 440, h = 956, label = "iPhone 17 Pro Max", group = "Phones", frame = "phone-island", models = ISLAND_17_PRO },
	["iphone-air"] = { w = 420, h = 912, label = "iPhone Air", group = "Phones", frame = "phone-island", models = { "Space Black", "Cloud White", "Light Gold", "Sky Blue" } },
	["iphone-16"] = { w = 393, h = 852, label = "iPhone 16", group = "Phones", frame = "phone-island", models = ISLAND_16 },
	["iphone-16-pro"] = { w = 402, h = 874, label = "iPhone 16 Pro", group = "Phones", frame = "phone-island", models = ISLAND_PRO },
	["iphone-16-pro-max"] = { w = 440, h = 956, label = "iPhone 16 Pro Max", group = "Phones", frame = "phone-island", models = ISLAND_PRO },
	["iphone-se"] = { w = 375, h = 667, label = "iPhone SE", group = "Phones", frame = "phone-home", models = { "Midnight", "Starlight", "Red" } },
	["android-compact"] = { w = 412, h = 917, label = "Android Compact", group = "Phones", frame = "android", models = { "Obsidian", "Porcelain", "Hazel", "Rose" } },
	["android-medium"] = { w = 700, h = 840, label = "Android Medium", group = "Phones", frame = "android", models = { "Obsidian", "Porcelain" } },
	["ipad-mini"] = { w = 744, h = 1133, label = "iPad mini", group = "Tablets", frame = "tablet", models = { "Space Gray", "Starlight", "Purple", "Blue" } },
	["ipad-pro-11"] = { w = 834, h = 1194, label = "iPad Pro 11\"", group = "Tablets", frame = "tablet", models = IPAD },
	["ipad-pro-12-9"] = { w = 1024, h = 1366, label = "iPad Pro 12.9\"", group = "Tablets", frame = "tablet", models = IPAD },
	["ipad-pro-13"] = { w = 1032, h = 1376, label = "iPad Pro 13\"", group = "Tablets", frame = "tablet", models = IPAD },
	["android-expanded"] = { w = 1280, h = 800, label = "Android Expanded", group = "Tablets", frame = "tablet", models = { "Space Gray", "Silver" } },
	["surface-pro-8"] = { w = 1440, h = 960, label = "Surface Pro 8", group = "Tablets", frame = "tablet", models = { "Platinum", "Graphite" } },
	["apple-watch-41"] = { w = 176, h = 215, label = "Apple Watch 41mm", group = "Watches", frame = "watch", models = WATCH },
	["apple-watch"] = { w = 198, h = 242, label = "Apple Watch 45mm", group = "Watches", frame = "watch", models = WATCH },
	["macbook-air"] = { w = 1280, h = 832, label = "MacBook Air", group = "Computers", frame = "laptop", models = MAC },
	["macbook-pro-14"] = { w = 1512, h = 982, label = "MacBook Pro 14\"", group = "Computers", frame = "laptop", models = { "Space Black", "Silver" } },
	["macbook-pro-16"] = { w = 1728, h = 1117, label = "MacBook Pro 16\"", group = "Computers", frame = "laptop", models = { "Space Black", "Silver" } },
	desktop = { w = 1440, h = 1024, label = "Desktop", group = "Computers", frame = "desktop", models = { "Silver", "Black" } },
	tv = { w = 1280, h = 720, label = "TV", group = "TV", frame = "tv", models = { "Black" } },
}
-- The dropdown's order, by group (phones, tablets, watches, computers, TV).
M.DEVICE_ORDER = {
	"iphone-17", "iphone-17-pro", "iphone-17-pro-max", "iphone-air", "iphone-16", "iphone-16-pro", "iphone-16-pro-max",
	"iphone-se", "android-compact", "android-medium",
	"ipad-mini", "ipad-pro-11", "ipad-pro-12-9", "ipad-pro-13", "android-expanded", "surface-pro-8",
	"apple-watch-41", "apple-watch",
	"macbook-air", "macbook-pro-14", "macbook-pro-16", "desktop",
	"tv",
}
-- How Play scales the viewport into the window (Figma's names): "actual" =
-- Actual size (100%), "fit" = Fit width and height (whole, at most 100%),
-- "width" = Fit width (a long Screen scrolls), "fill" = Fill screen (covers
-- the window, cropped), "responsive" = Responsive (the Screen re-laid out
-- at the window's size: P5; until then played as "fit").
M.FITS = { fit = true, width = true, actual = true, fill = true, responsive = true }
-- With a framed device, the device switcher: Fit device on screen, Zoom
-- device to fill screen, Show device at 100%.
M.DEVICE_FITS = { fit = true, fill = true, actual = true }

-- A preset's model names as a set.
local function has_model(d: any, m: any): boolean
	if type(m) ~= "string" or type(d) ~= "table" or type(d.models) ~= "table" then
		return false
	end
	for _, x in d.models do
		if x == m then
			return true
		end
	end
	return false
end
M.has_model = has_model

function M.check_overflow(v: any, path: string, fail: (string) -> ())
	if v == nil or U.is_null(v) or v == "none" or Resolve.refers(v) then
		return
	end
	if not M.OVERFLOW[v] then
		fail(`{path} is "vertical", "horizontal", "both" or "none" (the frame scrolls its content that way), not {tostring(v)}`)
	end
end

function M.check_scroll(v: any, path: string, fail: (string) -> ())
	if v == nil or U.is_null(v) or v == "scrolls" then
		return
	end
	if not M.SCROLL[v] then
		fail(`{path} is "fixed" (stays put while its parent scrolls), "sticky" (sticks at the top) or "scrolls" (the default), not {tostring(v)}`)
	end
end

local DEVICE_HELP = `a preset ("iphone-16", "iphone-se", "android-compact", "ipad-mini", "macbook-air", "desktop", …) or \{ w, h \}`
function M.check_prototype(p: any, fail: (string) -> ())
	if type(p) ~= "table" or p[1] ~= nil then
		fail(`prototype is \{ device = "iphone-16" | \{ w, h \}, model = "Black", rotate = false, fit = "fit" | "width" | "actual" | "fill" | "responsive", deviceFit = "fit" | "fill" | "actual", showFrame = true, background = "#…" \}`)
	end
	for k, v in p do
		if k == "device" then
			if U.is_null(v) then
				continue
			end
			if type(v) == "string" then
				if not M.DEVICES[v] then
					local names = table.concat(M.DEVICE_ORDER, ", ")
					fail(`prototype.device "{v}" isn't a preset: use one of {names}, or \{ w = 390, h = 844 \}`)
				end
			elseif type(v) == "table" then
				local w, h = v.w or v.width or v[1], v.h or v.height or v[2]
				if type(w) ~= "number" or type(h) ~= "number" or w < 50 or h < 50 or w > 8000 or h > 8000 then
					fail(`prototype.device is {DEVICE_HELP}, with sides 50 to 8000`)
				end
			else
				fail(`prototype.device is {DEVICE_HELP}, not {tostring(v)}`)
			end
		elseif k == "rotate" then
			if type(v) ~= "boolean" and not U.is_null(v) then
				fail(`prototype.rotate is true (landscape) or false`)
			end
		elseif k == "fit" then
			if not M.FITS[v] and not U.is_null(v) then
				fail(`prototype.fit is "fit" (whole, at most 100%), "width" (fit the width; a long Screen scrolls), "actual" (100%), "fill" (cover the window) or "responsive", not {tostring(v)}`)
			end
		elseif k == "model" then
			if U.is_null(v) then
				continue
			end
			local d = if type(p.device) == "string" then M.DEVICES[p.device] else nil
			if not d then
				fail(`prototype.model is a colour of a preset device's frame; this device has none`)
			elseif not has_model(d, v) then
				fail(`prototype.model "{tostring(v)}" isn't a {d.label} model: use one of {table.concat(d.models, ", ")}`)
			end
		elseif k == "deviceFit" then
			if not M.DEVICE_FITS[v] and not U.is_null(v) then
				fail(`prototype.deviceFit is "fit" (fit the device on screen), "fill" (zoom the device to fill the screen) or "actual" (the device at 100%), not {tostring(v)}`)
			end
		elseif k == "showFrame" then
			if type(v) ~= "boolean" and not U.is_null(v) then
				fail(`prototype.showFrame is true (draw the device around the Screen, the default) or false`)
			end
		elseif k == "background" then
			if not U.is_null(v) and not (type(v) == "string" and (string.match(v, "^#%x+$") or Resolve.refers(v))) then
				fail(`prototype.background is a colour "#RRGGBB" or a Token "$name", not {tostring(v)}`)
			end
		else
			fail(`prototype.{tostring(k)} isn't a prototype setting: they are device, model, rotate, fit, deviceFit, showFrame and background`)
		end
	end
end

-- The device's size in points (rotated), or nil (no device: each Screen's
-- own size).
function M.device_size(p: any): (number?, number?)
	if type(p) ~= "table" then
		return nil, nil
	end
	local d = p.device
	local w, h
	if type(d) == "string" and M.DEVICES[d] then
		w, h = M.DEVICES[d].w, M.DEVICES[d].h
	elseif type(d) == "table" then
		w, h = d.w or d.width or d[1], d.h or d.height or d[2]
	end
	if type(w) ~= "number" or type(h) ~= "number" then
		return nil, nil
	end
	if p.rotate == true then
		w, h = h, w
	end
	return w, h
end

-- The Design's `prototype` as the tab plays it: { w?, h?, device?, fit,
-- bg?, rotate?, frame?, model?, device_fit, show_frame }. `frame` (a
-- device_frame kind) and `model` (its colour name) only for a preset;
-- `show_frame` is false when the Design turned the frame off.
function M.played_prototype(p: any): any?
	if type(p) ~= "table" then
		return nil
	end
	local w, h = M.device_size(p)
	local d = if type(p.device) == "string" then M.DEVICES[p.device] else nil
	return {
		w = w,
		h = h,
		device = if type(p.device) == "string" then p.device elseif w then "custom" else nil,
		fit = if M.FITS[p.fit] then p.fit else "fit",
		bg = if type(p.background) == "string" and string.match(p.background, "^#%x+$") then U.color(p.background) else nil,
		rotate = p.rotate == true or nil,
		frame = if d then d.frame else nil,
		model = if d then (if has_model(d, p.model) then p.model else d.models[1]) else nil,
		device_fit = if M.DEVICE_FITS[p.deviceFit] then p.deviceFit else "fit",
		show_frame = p.showFrame ~= false,
	}
end

-- A prototype merged with new keys: a model the new device doesn't offer
-- is dropped (it was the old device's colour).
function M.merge_prototype(old: any, p: any): any
	local both = U.deep_copy(old)
	for k, v in p do
		both[k] = v
	end
	if p.device ~= nil and p.model == nil and both.model ~= nil then
		local d = if type(both.device) == "string" then M.DEVICES[both.device] else nil
		if not has_model(d, both.model) then
			both.model = nil
		end
	end
	return both
end

M.ACTIONS.scrollTo = true
M.ACTION_CHECKS.scrollTo = function(a, q, fail, _target)
	if type(a.to) ~= "string" or a.to == "" then
		fail(`{q}.to is the id of the layer to scroll to (inside the same Screen)`)
	end
	local o = a.offset
	if o ~= nil and not (type(o) == "number" or (type(o) == "table" and (o.x == nil or type(o.x) == "number") and (o.y == nil or type(o.y) == "number"))) then
		fail(`{q}.offset is a number (points above the layer) or \{ x, y \}`)
	end
	local t = a.transition
	if t ~= nil and not U.is_null(t) then
		if type(t) ~= "table" then
			fail(`{q}.transition is \{ type = "instant" \} or \{ type = "animate", duration = 300, easing = "ease-out" \}`)
		end
		if t.type ~= nil and t.type ~= "instant" and t.type ~= "animate" then
			fail(`{q}.transition.type is "instant" or "animate" for a scroll, not {tostring(t.type)}`)
		end
		check_duration(t.duration, `{q}.transition`, fail)
		check_easing(t.easing, `{q}.transition`, fail)
		for key in t do
			if key ~= "type" and key ~= "duration" and key ~= "easing" then
				fail(`{q}.transition.{tostring(key)}: a scroll's transition has type, duration and easing`)
			end
		end
	end
	for key in a do
		if key ~= "action" and key ~= "to" and key ~= "offset" and key ~= "transition" then
			fail(`{q}.{tostring(key)}: a scrollTo action is \{ action = "scrollTo", to = id, offset?, transition? \}`)
		end
	end
end
do
	local navigate = M.ACTION_CHECKS.navigate
	M.ACTION_CHECKS.navigate = function(a, q, fail, target)
		navigate(a, q, fail, target)
		if a.resetScroll ~= nil and type(a.resetScroll) ~= "boolean" then
			fail(`{q}.resetScroll is true (the Screen opens scrolled to the top) or false (it keeps where it was, the default)`)
		end
	end
end

-- A scrollTo as the tab plays it: { k = "scrollTo", to, ox, oy, tr = { ms, ease, sp? } }.
function M.played_scroll(a: any): any
	local o = a.offset
	local ox, oy = 0, 0
	if type(o) == "number" then
		oy = o
	elseif type(o) == "table" then
		ox, oy = U.num(o.x, 0), U.num(o.y, 0)
	end
	local t = a.transition
	local tr = nil
	if type(t) == "table" and t.type ~= "instant" then
		local ease, sp, sp_ms = M.played_ease(t.easing)
		tr = { ms = sp_ms or U.num(t.duration, M.DEFAULT_MS), ease = ease, sp = sp }
	end
	return { k = "scrollTo", to = a.to, ox = ox, oy = oy, tr = tr }
end

-- A laid-out frame's content extent (Canvas units, from its box's top-left):
-- what's inside it, with its padding at the far ends, at least its own box.
function M.content_extent(n: any): (number, number)
	local b = n.__box
	local w, h = b.w, b.h
	local pr, pb = 0, 0
	if n.layout == "horizontal" or n.layout == "vertical" then
		local p = n.padding
		if type(p) == "number" then
			pr, pb = p, p
		elseif type(p) == "table" then
			if #p == 1 then
				pr, pb = U.num(p[1], 0), U.num(p[1], 0)
			elseif #p == 2 then
				pb, pr = U.num(p[1], 0), U.num(p[2], 0)
			elseif #p == 4 then
				pr, pb = U.num(p[2], 0), U.num(p[3], 0)
			end
		end
	end
	for _, c in (n.children or {}) do
		local cb = c.__box
		if cb and c.enabled ~= false then
			w = math.max(w, cb.x + cb.w - b.x + pr)
			h = math.max(h, cb.y + cb.h - b.y + pb)
		end
	end
	return w, h
end

-- Lint over laid-out roots: `scroll-fits` (a scrolling frame whose content
-- fits it), `scroll-fixed` (fixed on a layer whose parent doesn't scroll),
-- `scroll-sticky` (sticky with nothing scrolling up and down above it),
-- `scroll-target` (scrollTo a layer that isn't in the same Screen).
function M.lint_scroll(ctx: any, roots: { any }, warnings: { any })
	local fits, fixed, sticky, target = {}, {}, {}, {}
	local function hot_of(id: string): boolean
		return ctx.changed[id] == true or ctx.changed[string.match(id, "^([^/]+)") or id] == true
	end
	for _, r in roots do
		local ids = {}
		local hot, uses = false, false
		local function gather(n)
			ids[n.id] = true
			hot = hot or hot_of(n.id)
			uses = uses or n.overflow ~= nil or n.scroll ~= nil or type(n.interactions) == "table"
			for _, c in (n.children or {}) do
				gather(c)
			end
		end
		gather(r)
		if not hot or not uses then
			continue
		end
		if not r.__box and ctx.layout then
			ctx.layout(r)
		end
		local function walk(n, parent, vscroll, ignore)
			local quiet = function(rule)
				return (ignore and ignore[rule]) or muted(n, nil, rule)
			end
			local my_ignore = {}
			for _, rule in { "scroll-fits", "scroll-fixed", "scroll-sticky", "scroll-target" } do
				my_ignore[rule] = quiet(rule)
			end
			local ovf = n.overflow
			if M.OVERFLOW[ovf] and n.__box and not my_ignore["scroll-fits"] then
				local w, h = M.content_extent(n)
				local b = n.__box
				local over_x, over_y = w > b.w + 0.5, h > b.h + 0.5
				local ok = if ovf == "vertical" then over_y elseif ovf == "horizontal" then over_x else (over_x or over_y)
				if not ok then
					local hint = if n.height == "fit_content" or n.height == nil or n.width == "fit_content" or n.width == nil
						then " (it hugs its content: give it a fixed size, or wrap the content in a frame that scrolls)"
						else ""
					table.insert(fits, `{tostring(n.name)} ({ovf}){hint}`)
				end
			end
			if n.scroll == "fixed" and not my_ignore["scroll-fixed"] then
				local scrolls = parent and (parent == r or M.OVERFLOW[parent.overflow])
				if not scrolls then
					table.insert(fixed, `{tostring(n.name)} (its parent doesn't scroll: fixed works on a Screen's or a scrolling frame's own layers)`)
				elseif parent.layout and parent.layout ~= "none" and n.absolute ~= true then
					table.insert(fixed, `{tostring(n.name)} (inside an auto layout: set absolute = true, or the others leave room for it)`)
				end
			end
			if n.scroll == "sticky" and not vscroll and not my_ignore["scroll-sticky"] then
				table.insert(sticky, `{tostring(n.name)} (nothing above it scrolls up and down)`)
			end
			if type(n.interactions) == "table" and not my_ignore["scroll-target"] then
				for _, re in U.list(n.interactions) do
					for _, a in U.list(type(re) == "table" and re.actions or nil) do
						if type(a) == "table" and a.action == "scrollTo" and type(a.to) == "string" and not ids[a.to] then
							table.insert(target, `{tostring(n.name)} → "{a.to}"`)
						end
					end
				end
			end
			local v = vscroll or n == r or ovf == "vertical" or ovf == "both"
			for _, c in (n.children or {}) do
				walk(c, n, v, my_ignore)
			end
		end
		walk(r, nil, false, nil)
	end
	report(warnings, "scroll-fits", fits, "scrolling frames whose content fits them, so they don't scroll")
	report(warnings, "scroll-fixed", fixed, "fixed layers that won't stay put")
	report(warnings, "scroll-sticky", sticky, "sticky layers with nothing scrolling above them")
	report(warnings, "scroll-target", target, "scrollTo actions whose layer isn't in the same Screen")
end

-- ── overlays (step 2, figma-parity.md §1.4, §3.3) ────────────────────────
-- A top-level frame's `overlay = { position, background = { color, opacity }
-- | false, closeOutside }` (its defaults, as Figma keeps them on the frame);
-- actions `overlay` (open over the Screen), `swap` (replace the top one) and
-- `close` (the top one). Play keeps a stack; Back closes the top one.

M.OVERLAY_POSITIONS = {
	center = "center", ["top-left"] = "top-left", top = "top", ["top-center"] = "top", ["top-right"] = "top-right",
	["bottom-left"] = "bottom-left", bottom = "bottom", ["bottom-center"] = "bottom", ["bottom-right"] = "bottom-right",
}
local POSITION_LIST = "center, top-left, top, top-right, bottom-left, bottom or bottom-right"
M.OVERLAY_DEFAULTS = { position = "center", closeOutside = true }
-- What each action's transition may be (a close without one plays its
-- opening backwards).
M.OVERLAY_TYPES = {
	overlay = { instant = true, dissolve = true, moveIn = true, slideIn = true, smart = true },
	close = { instant = true, dissolve = true, moveOut = true, slideOut = true },
	swap = M.TYPES,
}
local OVERLAY_TYPE_LIST = {
	overlay = "instant, dissolve, moveIn or slideIn (it arrives over the Screen)",
	close = "instant, dissolve, moveOut or slideOut (it leaves; none = its opening backwards)",
}

function M.check_overlay(v: any, path: string, fail: (string) -> ())
	if v == nil or U.is_null(v) then
		return
	end
	if type(v) ~= "table" or v[1] ~= nil then
		fail(`{path} is \{ position = "center", background = \{ color = "#000000", opacity = 0.4 \} | false, closeOutside = true \}`)
	end
	for k, x in v do
		if k == "position" then
			if x == "manual" then
				fail(`{path}.position "manual" goes on the action that opens it (\{ action = "overlay", position = "manual", offset = \{ x, y \} \}): it's measured from the layer clicked`)
			elseif not M.OVERLAY_POSITIONS[x] and not U.is_null(x) then
				fail(`{path}.position is {POSITION_LIST}, not {tostring(x)}`)
			end
		elseif k == "background" then
			if x == false or U.is_null(x) then
				continue
			end
			if type(x) ~= "table" then
				fail(`{path}.background is \{ color = "#000000", opacity = 0.4 \} or false`)
			end
			local c = x.color
			if c ~= nil and not (type(c) == "string" and (string.match(c, "^#%x+$") or Resolve.refers(c))) then
				fail(`{path}.background.color is a colour "#RRGGBB" or a Token "$name", not {tostring(c)}`)
			end
			local o = x.opacity
			if o ~= nil and (type(o) ~= "number" or o ~= o or o < 0 or o > 1) then
				fail(`{path}.background.opacity is 0 to 1, not {tostring(o)}`)
			end
			for key in x do
				if key ~= "color" and key ~= "opacity" then
					fail(`{path}.background.{tostring(key)}: a background has color and opacity`)
				end
			end
		elseif k == "closeOutside" then
			if type(x) ~= "boolean" then
				fail(`{path}.closeOutside is true (a click outside closes it) or false`)
			end
		else
			fail(`{path}.{tostring(k)} isn't an overlay setting: they are position, background and closeOutside`)
		end
	end
end

local function check_overlay_tr(kind: string, a: any, q: string, fail: (string) -> ())
	M.check_transition(a.transition, `{q}.transition`, fail)
	local t = a.transition
	if type(t) == "table" and OVERLAY_TYPE_LIST[kind] and not M.OVERLAY_TYPES[kind][t.type] then
		fail(`{q}.transition.type for {kind} is {OVERLAY_TYPE_LIST[kind]}, not {tostring(t.type)}`)
	end
end

M.ACTIONS.overlay = true
M.ACTIONS.swap = true
M.ACTIONS.close = true
M.ACTION_CHECKS.overlay = function(a, q, fail, target)
	if type(a.to) ~= "string" or a.to == "" then
		fail(`{q}.to is the id of the top-level frame to open as an overlay`)
	end
	local why = target(a.to)
	if why then
		fail(`{q}.to "{a.to}" can't be an overlay: it is not a top-level frame{why}`)
	end
	check_overlay_tr("overlay", a, q, fail)
	local p = a.position
	if p ~= nil and p ~= "manual" and not M.OVERLAY_POSITIONS[p] then
		fail(`{q}.position is {POSITION_LIST} or "manual" (offset from the layer clicked), not {tostring(p)}`)
	end
	local o = a.offset
	if o ~= nil then
		if p ~= "manual" then
			fail(`{q}.offset goes with position = "manual" (it's measured from the layer clicked's top-left)`)
		end
		if type(o) ~= "table" or (o.x ~= nil and type(o.x) ~= "number") or (o.y ~= nil and type(o.y) ~= "number") then
			fail(`{q}.offset is \{ x, y \} in points from the layer clicked's top-left`)
		end
	end
	for key in a do
		if key ~= "action" and key ~= "to" and key ~= "transition" and key ~= "position" and key ~= "offset" then
			fail(`{q}.{tostring(key)}: an overlay action is \{ action = "overlay", to, transition?, position?, offset? \} (background and closeOutside are the frame's: its overlay key)`)
		end
	end
end
M.ACTION_CHECKS.swap = function(a, q, fail, target)
	if type(a.to) ~= "string" or a.to == "" then
		fail(`{q}.to is the id of the top-level frame to swap the top overlay for`)
	end
	local why = target(a.to)
	if why then
		fail(`{q}.to "{a.to}" can't be an overlay: it is not a top-level frame{why}`)
	end
	check_overlay_tr("swap", a, q, fail)
	for key in a do
		if key ~= "action" and key ~= "to" and key ~= "transition" then
			fail(`{q}.{tostring(key)}: a swap action is \{ action = "swap", to, transition? \}`)
		end
	end
end
M.ACTION_CHECKS.close = function(a, q, fail, _target)
	check_overlay_tr("close", a, q, fail)
	for key in a do
		if key ~= "action" and key ~= "transition" then
			fail(`{q}.{tostring(key)}: a close action is \{ action = "close", transition? \} (it closes the top overlay)`)
		end
	end
end

-- A frame's `overlay` as the tab plays it: { pos, bg? = "#RRGGBBAA", co }.
function M.played_overlay(v: any): any
	local s = if type(v) == "table" then v else {}
	local pos = M.OVERLAY_POSITIONS[s.position] or "center"
	local bg = nil
	if type(s.background) == "table" then
		local c = U.color(if type(s.background.color) == "string" then s.background.color else "#000000") or "#000000FF"
		local a = math.clamp(U.num(s.background.opacity, 0.4), 0, 1)
		local base_a = tonumber(string.sub(c, 8, 9), 16) or 255
		bg = string.sub(c, 1, 7) .. string.format("%02X", math.floor(base_a * a + 0.5))
	end
	return { pos = pos, bg = bg, co = s.closeOutside ~= false }
end

-- An overlay action as the tab plays it.
function M.played_overlay_act(a: any): any
	if a.action == "close" then
		return { k = "close", tr = if type(a.transition) == "table" then M.played(a.transition) else nil }
	end
	local e: any = { k = a.action, go = a.to, tr = M.played(a.transition) }
	if a.action == "overlay" and e.tr.k == "smart" then
		-- (Figma's rule: Smart Animate doesn't apply to opening an overlay,
		-- only to a swap; it dissolves, and lint `smart-fallback` says so)
		e.tr.k = "dissolve"
	end
	if a.action == "overlay" then
		if a.position == "manual" then
			e.pos = "manual"
			local o = if type(a.offset) == "table" then a.offset else {}
			e.ox, e.oy = U.num(o.x, 0), U.num(o.y, 0)
		elseif M.OVERLAY_POSITIONS[a.position] then
			e.pos = M.OVERLAY_POSITIONS[a.position]
		end
	end
	return e
end

-- Where an overlay sits in the viewport (points, from its top-left), as
-- Figma places it: flush to the viewport's edges for the 7 positions; for
-- "manual", the trigger's top-left as shown (tx, ty) plus (ox, oy), not
-- clamped. An overlay bigger than the viewport is cut to it (it scrolls).
-- Mirrored in tab/proto.luau (a test keeps them equal). Returns x, y, w, h.
function M.overlay_place(pos: string?, ox: number?, oy: number?, vw: number, vh: number, ow: number, oh: number, tx: number?, ty: number?): (number, number, number, number)
	local w, h = math.min(ow, vw), math.min(oh, vh)
	local p = pos or "center"
	if p == "manual" then
		return (tx or 0) + (ox or 0), (ty or 0) + (oy or 0), w, h
	end
	local x = (vw - w) / 2
	local y = (vh - h) / 2
	if string.find(p, "left", 1, true) then
		x = 0
	elseif string.find(p, "right", 1, true) then
		x = vw - w
	end
	if string.sub(p, 1, 3) == "top" then
		y = 0
	elseif string.sub(p, 1, 6) == "bottom" then
		y = vh - h
	end
	return x, y, w, h
end

-- The overlay frames a node opens or swaps to, in order.
function M.overlay_targets(n: any): { string }?
	if type(n) ~= "table" or type(n.interactions) ~= "table" then
		return nil
	end
	local out = {}
	for _, r in U.list(n.interactions) do
		for _, a in U.list(type(r) == "table" and r.actions or nil) do
			if type(a) == "table" and (a.action == "overlay" or a.action == "swap") and type(a.to) == "string" then
				table.insert(out, a.to)
			end
		end
	end
	return if #out > 0 then out else nil
end

-- ── interactive components (step 4, figma-parity.md §3.4) ─────────────────
-- A Component's `variant = { set = "Switch", props = { On = "false" } }`:
-- Components with the same `set` form a variant set. An Instance's `ref` is
-- the member it shows. `{ action = "changeTo", to = <member id>,
-- transition? }` on a layer inside an Instance switches the closest
-- Instance (itself or above) whose set holds `to`, as Figma's "Change to"
-- (a nested one changes its parent). Play remembers the member per
-- Instance; navigate's `resetComponents = true` forgets it.

-- What a Change to may play (Figma's: the Screen's own place doesn't move,
-- so the directional ones don't apply).
M.CHANGE_TYPES = { instant = true, dissolve = true, smart = true }

-- A property value as stored: text ("true", "Default"); booleans and
-- numbers are written as text.
function M.prop_value(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	elseif type(v) == "boolean" or type(v) == "number" then
		return tostring(v)
	end
	return nil
end

function M.check_variant(v: any, path: string, fail: (string) -> ())
	if v == nil or U.is_null(v) then
		return
	end
	if type(v) ~= "table" or type(v.set) ~= "string" or string.match(v.set, "^%s*$") then
		fail(`{path} is \{ set = "Switch", props = \{ On = "false" \} \}: the set's name and this member's property values`)
	end
	if type(v.props) ~= "table" or next(v.props) == nil or v.props[1] ~= nil then
		fail(`{path}.props names this member's values, as \{ On = "false" \} or \{ State = "Default", Size = "Large" \}`)
	end
	for k, x in v.props do
		if type(k) ~= "string" or k == "" then
			fail(`{path}.props: each key is a property's name`)
		end
		if not M.prop_value(x) then
			fail(`{path}.props.{k} is text ("true", "Default"), not {tostring(x)}`)
		end
	end
	for k in v do
		if k ~= "set" and k ~= "props" then
			fail(`{path}.{tostring(k)}: a variant is \{ set, props \}`)
		end
	end
end

M.ACTIONS.changeTo = true
M.ACTION_CHECKS.changeTo = function(a, q, fail, target)
	if type(a.to) ~= "string" or a.to == "" then
		fail(`{q}.to is the id of the variant (a Component in a set) to change to; Variant(set, props) finds it`)
	end
	local why = target(a.to, "variant")
	if why then
		fail(`{q}.to "{a.to}" is not a variant{why}`)
	end
	M.check_transition(a.transition, `{q}.transition`, fail)
	local t = a.transition
	if type(t) == "table" and not M.CHANGE_TYPES[t.type] then
		fail(`{q}.transition.type for changeTo is instant, dissolve or smart, not {tostring(t.type)}`)
	end
	for key in a do
		if key ~= "action" and key ~= "to" and key ~= "transition" then
			fail(`{q}.{tostring(key)}: a changeTo action is \{ action = "changeTo", to = variantId, transition? \}`)
		end
	end
end
do
	local navigate = M.ACTION_CHECKS.navigate
	M.ACTION_CHECKS.navigate = function(a, q, fail, target)
		navigate(a, q, fail, target)
		if a.resetComponents ~= nil and type(a.resetComponents) ~= "boolean" then
			fail(`{q}.resetComponents is true (its interactive components start at their own variants) or false (they keep the ones last shown, the default)`)
		end
	end
end

-- The variant sets of a doc: { sets = { [set] = { members = { id }, props =
-- { [id] = props } } }, of = { [component id] = set } }.
function M.variant_sets(doc: any): any
	local sets, of = {}, {}
	local function walk(list)
		for _, n in U.list(list) do
			if type(n) == "table" then
				if n.type == "frame" and n.reusable == true and type(n.variant) == "table" and type(n.variant.set) == "string" and type(n.id) == "string" then
					local s = n.variant.set
					sets[s] = sets[s] or { members = {}, props = {} }
					table.insert(sets[s].members, n.id)
					local p = {}
					for k, v in (if type(n.variant.props) == "table" then n.variant.props else {}) do
						p[k] = M.prop_value(v)
					end
					sets[s].props[n.id] = p
					of[n.id] = s
				end
				walk(n.children)
			end
		end
	end
	walk(doc.children)
	return { sets = sets, of = of }
end

-- The member of `set` whose props match `want` best: every key of `want`
-- matches, then the most of `base`'s other values (Figma's rule when one
-- property changes). nil when none has `want`.
function M.variant_find(vs: any, set: string, want: any, base: any?): string?
	local s = vs.sets[set]
	if not s then
		return nil
	end
	local best, best_n = nil, -1
	for _, id in s.members do
		local p = s.props[id]
		local ok = true
		for k, v in want do
			if p[k] ~= M.prop_value(v) then
				ok = false
				break
			end
		end
		if ok then
			local n = 0
			for k, v in (base or {}) do
				if want[k] == nil and p[k] == v then
					n += 1
				end
			end
			if n > best_n then
				best, best_n = id, n
			end
		end
	end
	return best
end

-- Lint (step 4): sets whose members repeat a combination or differ in
-- their property names; changeTo targets no Instance around them holds.
function M.lint_variants(doc: any, roots: { any }, warnings: { any }, changed: any)
	local vs = M.variant_sets(doc)
	local dup, keys_off = {}, {}
	for name, s in vs.sets do
		local seen, keys0 = {}, nil
		for _, id in s.members do
			local p = s.props[id]
			local ks = {}
			for k in p do
				table.insert(ks, k)
			end
			table.sort(ks)
			local combo = {}
			for _, k in ks do
				table.insert(combo, `{k}={p[k]}`)
			end
			local c = table.concat(combo, ", ")
			if seen[c] and (changed[id] or changed[seen[c]]) then
				table.insert(dup, `{name}: {c}`)
			end
			seen[c] = id
			local kk = table.concat(ks, ",")
			if keys0 == nil then
				keys0 = kk
			elseif kk ~= keys0 and changed[id] then
				table.insert(keys_off, `{name} ({id}: {kk}, others: {keys0})`)
			end
		end
	end
	report(warnings, "variant-duplicate", dup, "variant sets with two members of the same values (Change to and Update(…, \{ props \}) pick the first)")
	report(warnings, "variant-props", keys_off, "variants whose property names differ from their set's (give every member the same properties)")
	-- changeTo: an Instance around the layer (or the layer) shows a member of
	-- the target's set
	local stray = {}
	local function walk(n, sets_up, hot)
		hot = hot or changed[n.id] == true or changed[string.match(tostring(n.id), "^([^/]+)") or ""] == true
		local up = sets_up
		local set = n.__inst and vs.of[n.__inst]
		if set then
			up = table.clone(sets_up)
			up[set] = true
		end
		if hot and type(n.interactions) == "table" and not muted(n, nil, "variant-target") then
			for _, r in U.list(n.interactions) do
				for _, a in U.list(type(r) == "table" and r.actions or nil) do
					if type(a) == "table" and a.action == "changeTo" and type(a.to) == "string" then
						local ts = vs.of[a.to]
						if ts and not up[ts] then
							table.insert(stray, `{tostring(n.name)} → {ts} ({a.to}): no Instance of that set holds it`)
						end
					end
				end
			end
		end
		for _, c in U.list(n.children) do
			walk(c, up, hot)
		end
	end
	for _, r in roots do
		-- (a set member itself counts as an Instance of its set: its own
		-- change-to links are what every Instance of it inherits)
		local up = {}
		if r.reusable == true and vs.of[r.id] then
			up[vs.of[r.id]] = true
		end
		walk(r, up, false)
	end
	report(warnings, "variant-target", stray, "Change to actions with no Instance of the target's set around them (they do nothing in Play)")
end

-- ── variables, conditionals and modes (step 5, pure/anim/f5/PLAN.md) ───────
-- { action = "set", var = "count", to = 0 | "Ann" | true | "#EF4444" | "$other" | "{count + 1}" }
-- { action = "toggle", var = "isOpen" }                (ours: set isOpen = not isOpen)
-- { action = "mode", axis = "theme", value = "dark" }  (Figma's Set variable mode)
-- { action = "if", cond = "{email != '' and agree}", ["then"] = { … }, ["else"] = { … } }
-- Variables are Tokens; checks against them need ctx = { kinds, themes }.
-- An unknown variable or mode isn't an error here (the Tokens may come later
-- in the same call): lint_vars reports it.

M.ACTIONS.set = true
M.ACTIONS.toggle = true
M.ACTIONS.mode = true
M.ACTIONS["if"] = true

local Expr = require("./expr")

local function var_ok(v: any): boolean
	return type(v) == "string" and string.match(v, Expr.NAME_OK) ~= nil
end

local function only_keys(a: any, q: string, fail: (string) -> (), keys: { [string]: boolean }, shape: string)
	for key in a do
		if not keys[key] then
			fail(`{q}.{tostring(key)}: {shape}`)
		end
	end
end

-- Whether a value of kind `got` may be written to a variable of kind `want`.
function M.kind_fits(want: string, got: string): boolean
	return got == "any" or want == got or (want == "string" and got == "number")
end

-- The kind of a literal `to` ("number", "string", "boolean", "color"), or nil.
local function literal_kind(v: any): string?
	if type(v) == "number" and v == v then
		return "number"
	elseif type(v) == "boolean" then
		return "boolean"
	elseif type(v) == "string" then
		return if U.color(v) then "color" else "string"
	end
	return nil
end

-- Checks an expression's source; returns its kind ("any" without ctx).
local function check_expr(src: string, q: string, fail: (string) -> (), ctx: any?): string
	local ast, why = Expr.parse(src)
	if not ast then
		fail(`{q}: {why} (in "{src}")`)
	end
	if ctx and ctx.kinds then
		local k, why2 = Expr.check(ast, ctx.kinds, nil, true)
		if not k then
			fail(`{q}: {why2}`)
		end
		return k :: string
	end
	return "any"
end

local SET_SHAPE = `a set action is \{ action = "set", var = name, to = value \}`
M.ACTION_CHECKS.set = function(a, q, fail, _target, ctx)
	if not var_ok(a.var) then
		fail(`{q}.var is the name of the variable (a Token) to set, as "count" (no "$")`)
	end
	only_keys(a, q, fail, { action = true, var = true, to = true }, SET_SHAPE)
	local want = ctx and ctx.kinds and ctx.kinds[a.var]
	local to = a.to
	if to == nil or U.is_null(to) then
		fail(`{q}.to is the value: a number, text, true or false, a colour "#RRGGBB", "$other" (its value) or an expression "\{count + 1\}"`)
	end
	local inner = Expr.inner(to)
	if inner then
		local k = check_expr(inner, `{q}.to`, fail, ctx)
		if want and not M.kind_fits(want, k) then
			fail(`{q}.to gives {Expr.KIND_NAME[k] or k}, but "{a.var}" holds {Expr.KIND_NAME[want]}`)
		end
		return
	end
	local ref = Resolve.reference(to)
	if ref then
		local k = ctx and ctx.kinds and ctx.kinds[ref]
		if want and k and not M.kind_fits(want, k) then
			fail(`{q}.to "{to}" is {Expr.KIND_NAME[k]}, but "{a.var}" holds {Expr.KIND_NAME[want]}`)
		end
		return
	end
	local k = literal_kind(to)
	if not k then
		fail(`{q}.to is a number, text, true or false, a colour, "$other" or "\{expression\}", not {tostring(to)} ({typeof(to)})`)
	end
	-- (text that happens to be a hex colour is fine for a string variable)
	if want and not M.kind_fits(want, k :: string) and not (want == "string" and k == "color") then
		fail(`{q}.to {if type(to) == "string" then '"' .. to .. '"' else tostring(to)} is {Expr.KIND_NAME[k]}, but "{a.var}" holds {Expr.KIND_NAME[want]}`)
	end
end

M.ACTION_CHECKS.toggle = function(a, q, fail, _target, ctx)
	if not var_ok(a.var) then
		fail(`{q}.var is the name of the boolean variable (a Token) to flip, as "isOpen"`)
	end
	only_keys(a, q, fail, { action = true, var = true }, `a toggle action is \{ action = "toggle", var = name \}`)
	local want = ctx and ctx.kinds and ctx.kinds[a.var]
	if want and want ~= "boolean" then
		fail(`{q}: toggle flips a boolean variable; "{a.var}" holds {Expr.KIND_NAME[want]} (use set)`)
	end
end

M.ACTION_CHECKS.mode = function(a, q, fail, _target, _ctx)
	if type(a.axis) ~= "string" or a.axis == "" then
		fail(`{q}.axis is the Theme axis to switch, as "theme" (Figma's collection)`)
	end
	if type(a.value) ~= "string" or a.value == "" then
		fail(`{q}.value is the mode to switch to, as "dark" (one of the axis's values)`)
	end
	only_keys(a, q, fail, { action = true, axis = true, value = true }, `a mode action is \{ action = "mode", axis, value \}`)
end

function M.check_if(a: any, q: string, fail: (string) -> (), ctx: any?)
	if type(a.cond) ~= "string" or a.cond == "" then
		fail(`{q}.cond is a true/false expression, as "\{count > 0\}"`)
	end
	only_keys(a, q, fail, { action = true, cond = true, ["then"] = true, ["else"] = true }, `an if action is \{ action = "if", cond, ["then"] = \{…\}, ["else"] = \{…\} \}`)
	local k = check_expr(Expr.inner(a.cond) or a.cond, `{q}.cond`, fail, ctx)
	if k ~= "boolean" and k ~= "any" then
		fail(`{q}.cond gives {Expr.KIND_NAME[k] or k}: a condition is true or false (compare it: count > 0)`)
	end
end

-- Every action in `list`, the ifs' branches too, depth first: visit(a, depth).
function M.each_action(list: any, visit: (any, number) -> (), depth: number?)
	for _, a in U.list(list) do
		if type(a) == "table" then
			visit(a, depth or 0)
			if a.action == "if" and (depth or 0) < 16 then
				M.each_action(a["then"], visit, (depth or 0) + 1)
				M.each_action(a["else"], visit, (depth or 0) + 1)
			end
		end
	end
end

local VAR_RULES = { "var-unknown", "var-type", "mode-unknown", "expr-invalid", "div-zero", "var-unused" }
M.VAR_RULES = VAR_RULES

-- Lint (step 5) over the doc as stored: actions and bindings against the
-- Tokens. `ctx = { doc, changed, all }`: only changed roots unless `all`
-- (Tokens or prototype keys changed).
function M.lint_vars(ctx: any, warnings: { any })
	local doc = ctx.doc
	local toks = {}
	for name, tok in (doc.tokens or {}) do
		local t = Resolve.read_token(name, tok)
		if t then
			toks[name] = t.kind
		end
	end
	local themes = doc.themes or {}
	local lists = {}
	for _, r in VAR_RULES do
		lists[r] = {}
	end
	local written, read = {}, {}
	local function add(rule, n, ignore, msg)
		if not ignore[rule] then
			table.insert(lists[rule], `{tostring(n.name or n.id)}: {msg}`)
		end
	end
	local function expr(src, n, hot, ignore, want_bool): string?
		local ast, why = Expr.parse(src)
		if not ast then
			if hot then
				add("expr-invalid", n, ignore, `"{src}": {why}`)
			end
			return nil
		end
		for name in Expr.vars(ast) do
			read[name] = true
		end
		if not hot then
			return nil
		end
		local k, why2, code = Expr.check(ast, toks, themes)
		if not k then
			add(code or "expr-invalid", n, ignore, `"{src}": {why2}`)
		elseif want_bool and k ~= "boolean" then
			add("var-type", n, ignore, `the condition "{src}" gives {Expr.KIND_NAME[k]}, not true or false`)
		end
		if Expr.divides_by_zero(ast) then
			add("div-zero", n, ignore, `"{src}" divides by 0 (Play gives 0)`)
		end
		return k
	end
	local function actions(list, n, hot, ignore)
		M.each_action(list, function(a)
			local kind = a.action
			if kind == "set" or kind == "toggle" then
				if type(a.var) ~= "string" then
					return
				end
				written[a.var] = n
				local want = toks[a.var]
				if not want then
					if hot then
						add("var-unknown", n, ignore, `${a.var} isn't a Token (SetTokens, or SetVars)`)
					end
				elseif kind == "toggle" and want ~= "boolean" and hot then
					add("var-type", n, ignore, `toggle on ${a.var}, which holds {Expr.KIND_NAME[want]}`)
				end
				if kind == "set" then
					local inner = Expr.inner(a.to)
					if inner then
						local k = expr(inner, n, hot, ignore, false)
						if hot and k and want and not M.kind_fits(want, k) then
							add("var-type", n, ignore, `set ${a.var} to "{a.to}", which gives {Expr.KIND_NAME[k]}; it holds {Expr.KIND_NAME[want]}`)
						end
					else
						local ref = Resolve.reference(a.to)
						if ref then
							read[ref] = true
							if hot and not toks[ref] then
								add("var-unknown", n, ignore, `set ${a.var} to "{a.to}", which isn't a Token`)
							elseif hot and want and not M.kind_fits(want, toks[ref]) then
								add("var-type", n, ignore, `set ${a.var} to "{a.to}" ({Expr.KIND_NAME[toks[ref]]}); it holds {Expr.KIND_NAME[want]}`)
							end
						elseif hot and want then
							local k = literal_kind(a.to)
							if k and not M.kind_fits(want, k) and not (want == "string" and k == "color") then
								add("var-type", n, ignore, `set ${a.var} to {tostring(a.to)} ({Expr.KIND_NAME[k]}); it holds {Expr.KIND_NAME[want]}`)
							end
						end
					end
				end
			elseif kind == "if" and type(a.cond) == "string" then
				expr(Expr.inner(a.cond) or a.cond, n, hot, ignore, true)
			elseif kind == "mode" and hot and type(a.axis) == "string" then
				local vals = themes[a.axis]
				if type(vals) ~= "table" then
					add("mode-unknown", n, ignore, `mode axis "{a.axis}" isn't a Theme of the Design`)
				elseif not table.find(vals, a.value) then
					add("mode-unknown", n, ignore, `the Theme "{a.axis}" has no mode "{tostring(a.value)}" ({table.concat(vals, ", ")})`)
				end
			end
		end)
	end
	-- a binding: text content (string or number), enabled (boolean), props
	local function binding(n, key, v, hot, ignore)
		local name = Resolve.reference(v)
		if not name then
			return
		end
		read[name] = true
		local k = toks[name]
		if not hot or not k then
			return
		end
		if key == "content" and (k == "boolean" or k == "color") then
			add("var-type", n, ignore, `its text shows ${name}, which holds {Expr.KIND_NAME[k]} (bind text to a string or number)`)
		elseif key == "enabled" and k ~= "boolean" then
			add("var-type", n, ignore, `its visibility (enabled) is bound to ${name}, which holds {Expr.KIND_NAME[k]}, not true or false`)
		elseif key == "props" and k == "color" then
			add("var-type", n, ignore, `a variant property is bound to ${name}, a colour (bind to a string, boolean or number)`)
		end
	end
	local function refs_in(v)
		if type(v) == "string" then
			local name = Resolve.reference(v)
			if name then
				read[name] = true
			end
		elseif type(v) == "table" then
			for k, x in v do
				if k ~= "interactions" then
					refs_in(x)
				end
			end
		end
	end
	local function visit(n, hot, ignore, type_)
		hot = hot or (ctx.changed ~= nil and type(n.id) == "string" and ctx.changed[n.id] == true)
		local my = {}
		for _, rule in VAR_RULES do
			my[rule] = ignore[rule] or muted(n, nil, rule)
		end
		local t = n.type or type_
		if type(n.interactions) == "table" then
			for _, r in U.list(n.interactions) do
				if type(r) == "table" then
					actions(r.actions, n, hot, my)
				end
			end
		end
		-- (an Instance's override has no type)
		if t == "text" or t == nil then
			binding(n, "content", n.content, hot, my)
		end
		binding(n, "enabled", n.enabled, hot, my)
		if (t == "instance" or t == nil) and type(n.props) == "table" then
			for _, v in n.props do
				binding(n, "props", v, hot, my)
			end
		end
		-- every other "$name" counts as a read (fills, sizes, …)
		for k, v in n do
			if k ~= "interactions" and k ~= "children" and k ~= "descendants" and k ~= "content" and k ~= "enabled" and k ~= "props" then
				refs_in(v)
			end
		end
		if type(n.descendants) == "table" then
			for _, ov in n.descendants do
				if type(ov) == "table" then
					visit(ov, hot, my, nil)
				end
			end
		end
		for _, c in U.list(n.children) do
			if type(c) == "table" then
				visit(c, hot, my, nil)
			end
		end
	end
	for _, root in U.list(doc.children) do
		if type(root) == "table" then
			local hot = ctx.all == true or (ctx.changed and ctx.changed[root.id] == true)
			visit(root, hot, {}, nil)
		end
	end
	-- variables an action writes that nothing reads or shows
	local unused = {}
	for name, n in written do
		if toks[name] and not read[name] and not muted(n, nil, "var-unused") then
			table.insert(unused, `${name} (set by {tostring(n.name or n.id)})`)
		end
	end
	table.sort(unused)
	report(warnings, "var-unknown", lists["var-unknown"], "actions or expressions that name a variable the Design has no Token for")
	report(warnings, "var-type", lists["var-type"], "variables set, bound or tested with the wrong kind of value")
	report(warnings, "mode-unknown", lists["mode-unknown"], "modes that aren't values of a Theme of the Design")
	report(warnings, "expr-invalid", lists["expr-invalid"], "expressions that don't parse")
	report(warnings, "div-zero", lists["div-zero"], "expressions that divide by 0")
	local before = #warnings
	report(warnings, "var-unused", unused, "variables actions set that nothing shows or reads")
	if #warnings > before then
		warnings[#warnings].level = "info"
	end
end

return M
