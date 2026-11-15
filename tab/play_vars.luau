--!strict
-- Play's variables (step 5, V3; pure/anim/f5/PLAN.md): the run-time model of
-- engine/vars.luau, for the tab. The harness refuses modules above the
-- script's folder, so this is that file's logic over `./expr` (a copy of
-- engine/expr.luau); pure/tests/vars_play.luau runs both on the same cases.
--
--   vars = { [token name] = { [candidate sig] = value } }   (overrides)
--   mode = { [axis] = value }                                 (run-time picks)
--
-- A write overrides only the candidate the clicked layer's theme picks
-- (Figma's per-mode write); a read takes the candidate, then its override.

local Expr = require("./expr")

local M = {}

-- ── Resolve's token helpers (engine/resolve.luau) ──────────────────────────

local function name_char_ok(s: string): boolean
	return string.match(s, "^[%w%-_%./]+$") ~= nil
end

function M.reference(text: any): string?
	if type(text) ~= "string" or string.sub(text, 1, 1) ~= "$" then
		return nil
	end
	local name = string.sub(text, 2)
	if name ~= "" and name_char_ok(name) then
		return name
	end
	return nil
end

-- A Token's values as { kind, values = { {value, theme} } }, or nil.
function M.read_token(token: any): any?
	if type(token) ~= "table" then
		return nil
	end
	local kind = token.type
	if kind ~= "color" and kind ~= "number" and kind ~= "string" and kind ~= "boolean" then
		return nil
	end
	local v = token.value
	if v == nil then
		return nil
	end
	if type(v) == "table" then
		local values = {}
		for _, themed in v do
			if type(themed) ~= "table" then
				return nil
			end
			table.insert(values, { value = themed.value, theme = if type(themed.theme) == "table" then themed.theme else {} })
		end
		if #values == 0 then
			return nil
		end
		return { kind = kind, values = values }
	end
	return { kind = kind, values = { { value = v, theme = {} } } }
end

function M.sig(theme: any): string
	if type(theme) ~= "table" or next(theme) == nil then
		return ""
	end
	local parts = {}
	for k, v in theme do
		table.insert(parts, tostring(k) .. "=" .. tostring(v))
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

local function count(t: any): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

function M.value_in(token: any, theme: any): (any, any)
	local best, best_n = nil, -1
	for _, cand in token.values do
		local ok = true
		for axis, val in cand.theme do
			if theme[axis] ~= val then
				ok = false
				break
			end
		end
		if ok then
			local n = count(cand.theme)
			if n >= best_n then
				best, best_n = cand, n
			end
		end
	end
	local cand = best or token.values[1]
	return cand.value, cand
end

function M.default_theme(themes: any): any
	local t = {}
	for axis, values in (themes or {}) do
		if type(values) == "table" and values[1] ~= nil then
			t[axis] = values[1]
		end
	end
	return t
end

-- ── engine/vars.luau ───────────────────────────────────────────────────────

-- { [name] = { kind, values } } from a Design's `tokens` (the `tokens` answer).
function M.tokens(raw: any): any
	local out = {}
	for name, tok in (raw or {}) do
		local t = M.read_token(tok)
		if t then
			out[name] = t
		end
	end
	return out
end

function M.theme(themes: any, view: any?, mode: any?, pin: any?): any
	local t = M.default_theme(themes)
	for _, over in { view, mode, pin } do
		if type(over) == "table" then
			for k, v in over do
				t[k] = v
			end
		end
	end
	return t
end

function M.lookup_theme(themes: any, theme: any, axis: string?, mode: string): any
	local a = axis
	if not a then
		a = Expr.mode_axis({ name = "", mode = mode }, themes)
	end
	local t = table.clone(theme)
	if a then
		t[a] = mode
	end
	return t
end

function M.read(toks: any, vars: any, name: string, theme: any): (any, string?)
	local tok = toks[name]
	if not tok then
		return nil, nil
	end
	local v, cand = M.value_in(tok, theme)
	local o = vars and vars[name]
	if o ~= nil then
		if type(o) == "table" then
			local x = o[M.sig(cand.theme)]
			if x ~= nil then
				v = x
			end
		else
			v = o
		end
	end
	return v, tok.kind
end

local function is_color(v: any): boolean
	if type(v) ~= "string" then
		return false
	end
	local h = string.match(v, "^#(%x+)$")
	return h ~= nil and (#h == 3 or #h == 4 or #h == 6 or #h == 8)
end

function M.coerce(kind: string, v: any): (any, string?)
	if kind == "number" then
		if type(v) == "number" and v == v then
			return v
		end
	elseif kind == "string" then
		if type(v) == "string" then
			return v
		elseif type(v) == "number" then
			return Expr.format(v)
		end
	elseif kind == "boolean" then
		if type(v) == "boolean" then
			return v
		end
	elseif kind == "color" then
		if is_color(v) then
			return v
		end
	end
	return nil, `a {kind} variable can't hold {Expr.text(v)} ({typeof(v)})`
end

function M.write(toks: any, vars: any, name: string, value: any, theme: any): (any, string?, string?)
	local tok = toks[name]
	if not tok then
		return nil, `the Design has no variable (Token) "{name}"`, "var-unknown"
	end
	local v, why = M.coerce(tok.kind, value)
	if v == nil then
		return nil, `"{name}": {why}`, "var-type"
	end
	local _, cand = M.value_in(tok, theme)
	local o = vars[name]
	if o ~= nil and type(o) ~= "table" then
		local all = {}
		for _, c in tok.values do
			all[M.sig(c.theme)] = o
		end
		o = all
	end
	o = o or {}
	o[M.sig(cand.theme)] = v
	vars[name] = o
	return v
end

function M.getter(ctx: any): (string, string?, string?) -> any
	return function(name: string, axis: string?, mode: string?): any
		local theme = ctx.theme
		if mode then
			theme = M.lookup_theme(ctx.themes, theme, axis, mode)
		end
		local v, kind = M.read(ctx.toks, ctx.vars, name, theme)
		if kind == nil then
			if ctx.warn then
				ctx.warn("var-unknown", `the Design has no variable (Token) "{name}"`)
			end
			return nil
		end
		return v
	end
end

local function warn_of(ctx: any): (string, string) -> ()
	return function(code: string, msg: string)
		if ctx.warn then
			ctx.warn(code, msg)
		end
	end
end

function M.eval(ctx: any, src: string): any
	local fn, why = Expr.compile(src)
	if not fn then
		warn_of(ctx)("expr-invalid", `{src}: {why}`)
		return nil
	end
	return (fn :: any)(M.getter(ctx), warn_of(ctx))
end

function M.value_of(ctx: any, to: any): any
	local inner = Expr.inner(to)
	if inner then
		return M.eval(ctx, inner)
	end
	local ref = M.reference(to)
	if ref and ctx.toks[ref] then
		return M.getter(ctx)(ref)
	end
	return to
end

function M.run_set(ctx: any, act: any): any
	local v
	if act.ex then
		v = M.eval(ctx, act.ex)
	else
		v = M.value_of(ctx, act.to)
	end
	if v == nil then
		return nil
	end
	local got, why, code = M.write(ctx.toks, ctx.vars, act.var, v, ctx.theme)
	if got == nil then
		warn_of(ctx)(code or "var-type", why or "")
	end
	return got
end

function M.test(ctx: any, cond: string): boolean
	local v = M.eval(ctx, cond)
	if type(v) ~= "boolean" then
		if v ~= nil then
			warn_of(ctx)("var-type", `the condition {cond} gave {Expr.text(v)}, not true or false`)
		end
		return false
	end
	return v
end

-- A mode action against the Design's Themes: (changed, problem?). An
-- unknown axis or value switches nothing ("mode-unknown", as Simulate).
function M.run_mode(themes: any, mode: any, act: any): (boolean, string?)
	if type(act.axis) ~= "string" or act.value == nil then
		return false, nil
	end
	local values = themes and themes[act.axis]
	if type(values) ~= "table" or not table.find(values, act.value) then
		return false, `mode-unknown: the Design has no mode {act.axis}={tostring(act.value)}`
	end
	if mode[act.axis] == act.value then
		return false, nil
	end
	mode[act.axis] = act.value
	return true, nil
end

function M.changed(toks: any, vars: any): { any }
	local out = {}
	for name, o in (vars or {}) do
		local tok = toks[name]
		if not tok then
			continue
		end
		for _, cand in tok.values do
			local s = M.sig(cand.theme)
			local v = if type(o) == "table" then o[s] else o
			if v ~= nil and not Expr.equal(v, cand.value) then
				table.insert(out, { name = name, value = v, theme = if s ~= "" then cand.theme else nil, sig = s })
			end
		end
	end
	table.sort(out, function(a: any, b: any): boolean
		return if a.name == b.name then a.sig < b.sig else a.name < b.name
	end)
	return out
end

-- ── Play's own ─────────────────────────────────────────────────────────────

local function enc(v: any): string
	if type(v) == "number" then
		return string.format("%.17g", v)
	elseif type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

-- A look's run-state key for a root reading Tokens `uses` (the scene's
-- list): the overrides of those Tokens and the mode axes their candidates
-- name; "" when the Design's values would show. Two states with one key
-- draw that root the same, so a set refreshes only roots that read it.
function M.run_sig(toks: any, uses: { string }?, vars: any, mode: any): string
	if not uses or #uses == 0 then
		return ""
	end
	local parts = {}
	local axes: { [string]: boolean } = {}
	for _, name in uses do
		local tok = toks[name]
		if tok then
			for _, c in tok.values do
				for axis in c.theme do
					axes[axis] = true
				end
			end
		end
		local o = vars and vars[name]
		if o ~= nil and tok then
			-- (only overrides that differ from the Token's own value count)
			local diffs = {}
			for _, c in tok.values do
				local s = M.sig(c.theme)
				local v = if type(o) == "table" then o[s] else o
				if v ~= nil and not Expr.equal(v, c.value) then
					table.insert(diffs, s .. ":" .. enc(v))
				end
			end
			if #diffs > 0 then
				table.sort(diffs)
				table.insert(parts, name .. "=" .. table.concat(diffs, ";"))
			end
		end
	end
	table.sort(parts)
	local ms = {}
	for axis, v in (mode or {}) do
		if axes[axis] then
			table.insert(ms, "@" .. axis .. "=" .. tostring(v))
		end
	end
	table.sort(ms)
	for _, m in ms do
		table.insert(parts, m)
	end
	return table.concat(parts, "|")
end

-- A deep copy of a run state (vars and mode), for predicting a click.
function M.clone(vars: any, mode: any): (any, any)
	local v = {}
	for k, o in vars do
		v[k] = if type(o) == "table" then table.clone(o) else o
	end
	return v, table.clone(mode)
end

-- A Change to's member prop text as a value for a Token of `kind` (two-way
-- binding): "true"/"false" → booleans, numbers by tonumber.
function M.prop_value(kind: string, text: any): any
	if kind == "boolean" then
		if text == "true" or text == true then
			return true
		elseif text == "false" or text == false then
			return false
		end
		return nil
	elseif kind == "number" then
		return tonumber(text)
	end
	return if text == nil then nil else tostring(text)
end

M.equal = Expr.equal

-- A value as the popover shows it.
function M.show(v: any): string
	if type(v) == "string" then
		return v
	end
	return Expr.text(v)
end

return M
