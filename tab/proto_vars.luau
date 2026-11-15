--!strict
-- The Prototype panel's variable actions (step 5, V5a; pure/anim/f5/PLAN.md):
-- what Set variable, Toggle, Set variable mode and Conditional rows show and
-- check. Pure (no ui): the panel (proto_panel.luau) draws the rows, this
-- reads the Tokens, checks values and conditions with the engine's own
-- `expr.luau` (the same grammar and messages the service's lint uses), and
-- turns what's typed in a value box into the stored `to`.
--
-- Stored shapes (CONTRACT, V1):
--   { action = "set", var, to = literal | "$other" | "{expr}" }
--   { action = "toggle", var }
--   { action = "mode", axis, value }
--   { action = "if", cond = "{expr}", ["then"] = { … }, ["else"] = { … } }

-- (tab/expr.luau is engine/expr.luau byte for byte: the window can't reach
-- engine/ from tab/ in the harness; tests/vars_panel.luau fails if they differ)
local Expr = require("./expr")

local M = {}

M.KINDS = { set = true, toggle = true, mode = true, ["if"] = true }
M.LABEL = { set = "Set variable", toggle = "Toggle variable", mode = "Set variable mode", ["if"] = "Conditional" }
M.ICON = { set = "braces", toggle = "check", mode = "moon", ["if"] = "code" }
M.KIND_NAME = Expr.KIND_NAME
-- A variable's type icon (as the Variables panel's; boolean: a check).
function M.type_icon(kind: string?): string
	return if kind == "color" then "drop" elseif kind == "string" then "text" elseif kind == "boolean" then "check" else "braces"
end
M.TYPE_LABEL = { color = "Colour", number = "Number", string = "Text", boolean = "Boolean" }

-- What the panel knows of the Tokens (`source.tokens`' answer, or nil before
-- it lands): `{ loaded, kinds = { [name] = kind }, names (sorted), themes,
-- axes (sorted), first = { [name] = first value } }`.
function M.read(t: any): any
	local kinds, first, names = {}, {}, {}
	for name, tok in (t and t.tokens) or {} do
		if type(tok) == "table" then
			local k = tok.type
			if k == "color" or k == "number" or k == "string" or k == "boolean" then
				kinds[name] = k
				local v = tok.value
				if type(v) == "table" and v[1] ~= nil then
					v = v[1].value
				end
				first[name] = v
				table.insert(names, name)
			end
		end
	end
	table.sort(names)
	local themes = (t and t.themes) or {}
	local axes = {}
	for axis, vals in themes do
		if type(vals) == "table" then
			table.insert(axes, axis)
		end
	end
	table.sort(axes)
	return { loaded = t ~= nil, kinds = kinds, names = names, themes = themes, axes = axes, first = first }
end

local function is_color(v: any): boolean
	if type(v) ~= "string" then
		return false
	end
	local n = #v
	return string.match(v, "^#%x+$") ~= nil and (n == 4 or n == 5 or n == 7 or n == 9)
end

local function literal_kind(v: any): string?
	if type(v) == "number" and v == v then
		return "number"
	elseif type(v) == "boolean" then
		return "boolean"
	elseif type(v) == "string" then
		return if is_color(v) then "color" else "string"
	end
	return nil
end

local function fits(want: string, got: string): boolean
	return got == "any" or want == got or (want == "string" and got == "number")
end
M.fits = fits

-- The kind an expression gives, or nil and why (V1's messages).
function M.check_expr(T: any, src: string): (string?, string?)
	local ast, why = Expr.parse(src)
	if not ast then
		return nil, why
	end
	local k, why2 = Expr.check(ast, T.kinds, T.themes, not T.loaded)
	if not k then
		return nil, why2
	end
	if Expr.divides_by_zero(ast) then
		return k, nil -- (a lint warning in the service, not an error here)
	end
	return k
end

-- What's wrong with a Set variable, or nil.
function M.check_set(T: any, var: any, to: any): string?
	if type(var) ~= "string" or var == "" then
		return "Choose a variable"
	end
	local want = T.kinds[var]
	if T.loaded and not want then
		return `No variable "{var}" in this Design`
	end
	if to == nil then
		return "Give it a value"
	end
	local inner = Expr.inner(to)
	if inner then
		if want == "color" then
			return "A colour is set to a colour, not an expression (Figma has no colour maths)"
		end
		local k, why = M.check_expr(T, inner)
		if not k then
			return why
		end
		if want and not fits(want, k) then
			return `This gives {Expr.KIND_NAME[k] or k}, but "{var}" holds {Expr.KIND_NAME[want]}`
		end
		return nil
	end
	if type(to) == "string" and string.sub(to, 1, 1) == "$" then
		local ref = string.sub(to, 2)
		local k = T.kinds[ref]
		if T.loaded and not k then
			return `No variable "{ref}" in this Design`
		end
		if want and k and not fits(want, k) then
			return `"{ref}" is {Expr.KIND_NAME[k]}, but "{var}" holds {Expr.KIND_NAME[want]}`
		end
		return nil
	end
	local k = literal_kind(to)
	if not k then
		return "A value is a number, text, true or false, a colour, $other or {expression}"
	end
	if want and not fits(want, k) and not (want == "string" and k == "color") then
		return `{M.value_text(to)} is {Expr.KIND_NAME[k]}, but "{var}" holds {Expr.KIND_NAME[want]}`
	end
	return nil
end

function M.check_toggle(T: any, var: any): string?
	if type(var) ~= "string" or var == "" then
		return "Choose a true/false variable"
	end
	local k = T.kinds[var]
	if T.loaded and not k then
		return `No variable "{var}" in this Design`
	end
	if k and k ~= "boolean" then
		return `Toggle flips true/false, but "{var}" holds {Expr.KIND_NAME[k]}`
	end
	return nil
end

function M.check_mode(T: any, axis: any, value: any): string?
	if not T.loaded then
		return nil
	end
	if #T.axes == 0 then
		return "The Design has no modes: add a Theme in Variables"
	end
	local vals = T.themes[axis]
	if type(vals) ~= "table" then
		return if axis then `No mode axis "{axis}"` else "Choose a mode axis"
	end
	if not table.find(vals, value) then
		return if value then `"{axis}" has no mode "{value}"` else "Choose a mode"
	end
	return nil
end

function M.check_cond(T: any, cond: any): string?
	if type(cond) ~= "string" or cond == "" or cond == "{}" then
		return "Write a condition, as count > 0"
	end
	local k, why = M.check_expr(T, Expr.inner(cond) or cond)
	if not k then
		return why
	end
	if k ~= "boolean" and k ~= "any" then
		return `This gives {Expr.KIND_NAME[k] or k}: a condition is true or false (compare it: count > 0)`
	end
	return nil
end

-- A stored `to` as the value box shows it.
function M.value_text(to: any): string
	if to == nil then
		return ""
	elseif type(to) == "number" then
		local s = tostring(to)
		return s
	end
	return tostring(to)
end

-- A condition as the box shows it (no outer braces).
function M.cond_text(cond: any): string
	if type(cond) ~= "string" then
		return ""
	end
	return Expr.inner(cond) or cond
end

-- What's typed in a value box → the stored `to`, for a variable of `kind`:
-- "{…}" is an expression and "$x" a copy of x, as stored; otherwise a number
-- for a number variable (anything else typed there is taken as an
-- expression), true/false for a boolean one (else an expression), the text
-- as is for a text one, a hex for a colour.
function M.parse_value(kind: string?, text: string): any
	local t = string.match(text, "^%s*(.-)%s*$") or text
	if string.sub(t, 1, 1) == "{" and string.sub(t, -1) == "}" then
		return t
	end
	if string.match(t, "^%$[%w%-_%./]+$") then
		return t
	end
	if kind == "number" then
		local n = tonumber(t)
		if n then
			return n
		end
		return if t == "" then 0 else "{" .. t .. "}"
	elseif kind == "boolean" then
		if t == "true" then
			return true
		elseif t == "false" then
			return false
		end
		return if t == "" then false else "{" .. t .. "}"
	elseif kind == "color" then
		local h = string.gsub(t, "#", "")
		return "#" .. string.upper(h)
	end
	return text
end

-- A condition typed → stored ("{…}", the braces added).
function M.parse_cond(text: string): string
	local t = string.match(text, "^%s*(.-)%s*$") or text
	return "{" .. (Expr.inner(t) or t) .. "}"
end

-- A Set variable's first value for `var`: one more for a number, true for a
-- boolean, the variable's own value otherwise.
function M.default_to(T: any, var: string?): any
	if not var then
		return 0
	end
	local k = T.kinds[var]
	local to = if k == "number" then `\{{M.ref(var)} + 1\}` elseif k == "boolean" then true else T.first[var]
	if to == nil then
		to = if k == "string" then "" elseif k == "color" then "#000000" else 0
	end
	return to
end

-- A fresh action of `kind` (what picking it in the Action menu makes).
function M.fresh(T: any, kind: string): any
	if kind == "set" then
		local var = T.names[1]
		for _, n in T.names do
			if T.kinds[n] == "number" then
				var = n
				break
			end
		end
		return { action = "set", var = var, to = M.default_to(T, var) }
	elseif kind == "toggle" then
		local var = nil
		for _, n in T.names do
			if T.kinds[n] == "boolean" then
				var = n
				break
			end
		end
		return { action = "toggle", var = var }
	elseif kind == "mode" then
		local axis = T.axes[1]
		local vals = axis and T.themes[axis]
		local value = if type(vals) == "table" then (vals[2] or vals[1]) else nil
		return { action = "mode", axis = axis, value = value }
	end
	local var = T.names[1]
	local k = var and T.kinds[var]
	local cond = if not var then "{true}"
		elseif k == "number" then `\{{M.ref(var)} > 0\}`
		elseif k == "boolean" then `\{{M.ref(var)}\}`
		elseif k == "string" then `\{{M.ref(var)} != ''\}`
		else "{true}"
	return { action = "if", cond = cond, ["then"] = { M.fresh(T, "set") } }
end

-- A name as an expression writes it (brackets around "/", "-" or a word).
function M.ref(name: string): string
	local words = { ["and"] = true, ["or"] = true, ["not"] = true, ["true"] = true, ["false"] = true }
	if string.match(name, "^[%a_][%w_%.]*$") and not words[name] then
		return name
	end
	return "[" .. name .. "]"
end

-- Binding a property (step 5, V5b; tab/bind.luau draws it) -----------------------

-- Every variable as the Apply variable lists show it: `{ { name, kind,
-- value } }` (each Token's first value), sorted by name.
function M.bind_vars(t: any): { any }
	local T = M.read(t)
	local out = {}
	for _, name in T.names do
		table.insert(out, { name = name, kind = T.kinds[name], value = T.first[name] })
	end
	return out
end

-- The variables of `kinds`, in order.
function M.vars_of(vars: { any }, kinds: { string }): { any }
	local out = {}
	for _, v in vars do
		if table.find(kinds, v.kind) then
			table.insert(out, v)
		end
	end
	return out
end

-- The variable named, when `v` is exactly "$name" (a binding), else nil.
function M.bind_ref(v: any): string?
	if type(v) == "string" and string.match(v, "^%$[^%s{}]+$") then
		return string.sub(v, 2)
	end
	return nil
end

function M.kind_of(vars: { any }, name: string?): string?
	for _, v in vars do
		if v.name == name then
			return v.kind
		end
	end
	return nil
end

-- A value as a row or chip shows it: a number ≤ 2 decimals (Expr.format),
-- true/false, a colour's hex (no #), text cut at 18.
function M.var_text(kind: string?, v: any): string
	if type(v) == "number" then
		return Expr.format(v)
	elseif type(v) == "boolean" then
		return if v then "true" else "false"
	elseif type(v) == "string" and kind == "color" then
		local h = string.upper(string.sub(v, 2, 7))
		return if is_color(v) then h else v
	elseif type(v) == "string" then
		return if #v > 18 then string.sub(v, 1, 17) .. "…" else v
	end
	return ""
end

-- The literal a detach keeps, as the property holds it: `as` "text"
-- (content: the words shown, numbers as Expr.format), "prop" (a variant
-- property: "true"/"false", text), "visible" (enabled: false only when the
-- value is false), "number" (as is).
function M.bind_literal(kind: string?, v: any, as: string): any
	if as == "text" or as == "prop" then
		if v == nil then
			return ""
		elseif type(v) == "string" then
			return v
		end
		return M.var_text(kind, v)
	elseif as == "visible" then
		return v ~= false
	end
	return v
end

-- A collapsed branch's summary ("2 actions: Set count, Navigate").
function M.summary(list: any): string
	local n = if type(list) == "table" then #list else 0
	if n == 0 then
		return "No actions"
	end
	local parts = {}
	for k = 1, math.min(n, 2) do
		local a = list[k]
		local kind = type(a) == "table" and a.action
		table.insert(parts, if kind == "set" or kind == "toggle" then `{M.LABEL[kind]} {a.var or ""}` elseif kind and M.LABEL[kind] then M.LABEL[kind] else (kind or "navigate"))
	end
	return `{n} action{if n == 1 then "" else "s"}: {table.concat(parts, ", ")}{if n > 2 then ", …" else ""}`
end

return M
