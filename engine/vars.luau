--!nonstrict
-- Prototype variables at run time (step 5, pure/anim/f5/PLAN.md §1): the
-- state Play, Simulate and the export share. A variable is a Token; its
-- values per mode are the Token's themed candidates.
--
--   vars = { [token name] = { [candidate sig] = value } }   (overrides)
--          a plain value instead of the table overrides every candidate
--   mode = { [axis] = value }                                 (run-time picks)
--
-- A candidate's sig is its theme as "axis=value,…" (sorted), "" for an
-- unthemed one. A write overrides only the candidate the writing layer's
-- theme picks (Figma: "only update the value of that specific mode"); a
-- read takes the candidate as Resolve does, then its override. Restart
-- clears both tables.

local U = require("./util")
local Resolve = require("./resolve")
local Expr = require("./expr")

local M = {}

M.sig = Resolve.sig

-- { [name] = { kind, values = { {value, theme} } } } for the doc's Tokens.
function M.tokens(doc: any): any
	local out = {}
	for name, tok in (doc and doc.tokens or {}) do
		local t = Resolve.read_token(name, tok)
		if t then
			out[name] = t
		end
	end
	return out
end

-- { [name] = kind } (what Expr.check takes).
function M.kinds(toks: any): any
	local out = {}
	for name, t in toks do
		out[name] = t.kind
	end
	return out
end

-- The theme a layer sees: the Design's default theme, the run-time `mode`
-- over it, the layer's pinned theme (`pin`: its and its parents' `theme`
-- keys merged) over that.
function M.theme(themes: any, view: any?, mode: any?, pin: any?): any
	local t = Resolve.default_theme(themes)
	for _, over in { view, mode, pin } do
		if type(over) == "table" then
			for k, v in over do
				t[k] = v
			end
		end
	end
	return t
end

-- The theme a mode lookup reads (`count:pears`): `theme` with that axis set.
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

-- A variable's value in `theme` (with its override), and its kind; nil when
-- there's no such Token.
function M.read(toks: any, vars: any, name: string, theme: any): (any, string?)
	local tok = toks[name]
	if not tok then
		return nil, nil
	end
	local v, cand = Resolve.value_in(tok, theme)
	local o = vars and vars[name]
	if o ~= nil then
		if type(o) == "table" then
			local x = o[Resolve.sig(cand.theme)]
			if x ~= nil then
				v = x
			end
		else
			v = o
		end
	end
	return v, tok.kind
end

-- `v` as a value of `kind`, or nil and why. A number becomes text for a
-- string variable (Figma's string expressions take numbers).
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
		if U.color(v) then
			return v
		end
	end
	return nil, `a {kind} variable can't hold {Expr.text(v)} ({typeof(v)})`
end

-- Writes `value` to the candidate of `name` that `theme` picks. Returns the
-- value written, or nil and why ("var-unknown" / "var-type" as the code).
function M.write(toks: any, vars: any, name: string, value: any, theme: any): (any, string?, string?)
	local tok = toks[name]
	if not tok then
		return nil, `the Design has no variable (Token) "{name}"`, "var-unknown"
	end
	local v, why = M.coerce(tok.kind, value)
	if v == nil then
		return nil, `"{name}": {why}`, "var-type"
	end
	local _, cand = Resolve.value_in(tok, theme)
	local o = vars[name]
	if o ~= nil and type(o) ~= "table" then
		-- (a plain override covered every candidate: spell it out first)
		local all = {}
		for _, c in tok.values do
			all[Resolve.sig(c.theme)] = o
		end
		o = all
	end
	o = o or {}
	o[Resolve.sig(cand.theme)] = v
	vars[name] = o
	return v
end

-- A getter for Expr closures over a run context:
-- ctx = { toks, vars, theme, themes, warn? }.
function M.getter(ctx: any): (string, string?, string?) -> any
	return function(name, axis, mode)
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
	return function(code, msg)
		if ctx.warn then
			ctx.warn(code, msg)
		end
	end
end

-- Runs an expression source over a run context. nil (and a warning
-- "expr-invalid") when it doesn't parse.
function M.eval(ctx: any, src: string): any
	local fn, why = Expr.compile(src)
	if not fn then
		warn_of(ctx)("expr-invalid", `{src}: {why}`)
		return nil
	end
	return fn(M.getter(ctx), warn_of(ctx))
end

-- What a set action's `to` gives: a literal, "$x" (x's value) or "{expr}".
function M.value_of(ctx: any, to: any): any
	local inner = Expr.inner(to)
	if inner then
		return M.eval(ctx, inner)
	end
	local ref = Resolve.reference(to)
	if ref and ctx.toks[ref] then
		return M.getter(ctx)(ref)
	end
	return to
end

-- A played set (Scene.act_of's { k = "set", var, to? | ex? }) run over a run
-- context: writes the variable, returns the value written (nil on a
-- problem, reported through ctx.warn).
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

-- A played if's condition: true or false (a non-boolean warns "var-type").
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

-- A played mode action: sets mode[axis] = value. Returns whether it changed.
function M.run_mode(mode: any, act: any): boolean
	if type(act.axis) ~= "string" or act.value == nil then
		return false
	end
	if mode[act.axis] == act.value then
		return false
	end
	mode[act.axis] = act.value
	return true
end

-- The variables a doc's Tokens list differ from: { [name] = { value, theme?
-- } } per overridden candidate whose value differs from the Token's
-- (snapshots, the Play popover).
function M.changed(toks: any, vars: any): { any }
	local out = {}
	for name, o in (vars or {}) do
		local tok = toks[name]
		if not tok then
			continue
		end
		for _, cand in tok.values do
			local s = Resolve.sig(cand.theme)
			local v = if type(o) == "table" then o[s] else o
			if v ~= nil and not Expr.equal(v, cand.value) then
				table.insert(out, { name = name, value = v, theme = if s ~= "" then cand.theme else nil, sig = s })
			end
		end
	end
	table.sort(out, function(a, b)
		return if a.name == b.name then a.sig < b.sig else a.name < b.name
	end)
	return out
end

return M
