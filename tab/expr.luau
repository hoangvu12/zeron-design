--!nonstrict
-- Expressions for prototype variables (step 5, pure/anim/f5/PLAN.md §1),
-- Figma's grammar and nothing more:
--   numbers, 'strings' / "strings", true, false, variables, parentheses;
--   + - * / (string + joins, and can append a number), unary minus;
--   == != < <= > >=, and, or, not / !;
--   a mode lookup `count:pears` (or `count:product=pears` when the value
--   name is on two axes).
-- No functions and no colour maths (Figma has neither).
--
-- Variable names: a bare name is letters, digits, "_" and "." (not starting
-- with a digit); `$count` is the same. A Token name with "/" or "-" in it is
-- written in brackets: `[cart/count] + 1`. and, or, not, true and false are
-- words, so a Token with one of those names needs brackets too.
--
-- One parse gives an AST; from it come a Luau closure (Play and Simulate),
-- a JS expression (the export) and a canonical source, so they can't drift.
-- Precedence, loosest first: or < and < not < comparisons < + - < * / < unary
-- minus. All left to right.

local M = {}

-- ── values as text ────────────────────────────────────────────────────────

-- A number as text (number → text bindings and string +). Figma's exact rule
-- isn't documented or filmed (3.990000009 shows as "3.99"): ours rounds to
-- at most 2 decimals (half up, as JS Math.round) and trims trailing zeros.
-- The export's $fmt (M.JS_HELPERS) does the same.
function M.format(n: number): string
	if n ~= n then
		return "0"
	end
	if n == math.huge or n == -math.huge then
		return if n > 0 then "Infinity" else "-Infinity"
	end
	local r = math.floor(n * 100 + 0.5) / 100
	if r == 0 then
		return "0"
	end
	if r == math.floor(r) and math.abs(r) < 1e15 then
		return string.format("%d", r)
	end
	local s = string.format("%.2f", r)
	s = string.gsub(s, "0+$", "")
	s = string.gsub(s, "%.$", "")
	return s
end

-- Any variable value as text: numbers formatted, booleans "true"/"false".
function M.text(v: any): string
	if type(v) == "number" then
		return M.format(v)
	elseif v == nil then
		return ""
	end
	return tostring(v)
end

-- The inner source when `v` is exactly "{…}" (an expression in an action's
-- `to`), else nil.
function M.inner(v: any): string?
	if type(v) == "string" and string.sub(v, 1, 1) == "{" and string.sub(v, -1) == "}" and #v >= 2 then
		return string.sub(v, 2, -2)
	end
	return nil
end

-- ── lexing ────────────────────────────────────────────────────────────────

local WORDS = { ["and"] = true, ["or"] = true, ["not"] = true, ["true"] = true, ["false"] = true }
local NAME_OK = "^[%w%-_%./]+$"
M.NAME_OK = NAME_OK

local function lex(src: string): ({ any }?, string?)
	local toks = {}
	local i, n = 1, #src
	local function push(t, v, at)
		table.insert(toks, { t = t, v = v, at = at })
	end
	while i <= n do
		local c = string.sub(src, i, i)
		if string.match(c, "%s") then
			i += 1
		elseif string.match(c, "%d") or (c == "." and string.match(string.sub(src, i + 1, i + 1), "%d")) then
			local s = string.match(src, "^%d*%.?%d*", i)
			local v = tonumber(s)
			if not v then
				return nil, `"{s}" isn't a number (at {i})`
			end
			push("num", v, i)
			i += #s
		elseif c == "'" or c == '"' or c == "\u{201C}" or string.sub(src, i, i + 2) == "\u{201C}" or string.sub(src, i, i + 2) == "\u{2018}" then
			-- (curly quotes as Figma's help prints them)
			local close, open_len = c, 1
			local three = string.sub(src, i, i + 2)
			if three == "\u{201C}" then
				close, open_len = "\u{201D}", 3
			elseif three == "\u{2018}" then
				close, open_len = "\u{2019}", 3
			end
			local j = i + open_len
			local buf = {}
			local done = false
			while j <= n do
				local d = string.sub(src, j, j)
				if d == "\\" and j < n then
					table.insert(buf, string.sub(src, j + 1, j + 1))
					j += 2
				elseif string.sub(src, j, j + #close - 1) == close then
					j += #close
					done = true
					break
				else
					table.insert(buf, d)
					j += 1
				end
			end
			if not done then
				return nil, `a text that starts at {i} isn't closed with {close}`
			end
			push("str", table.concat(buf), i)
			i = j
		elseif c == "[" then
			local j = string.find(src, "]", i + 1, true)
			if not j then
				return nil, `"[" at {i} isn't closed with "]"`
			end
			local name = string.sub(src, i + 1, j - 1)
			if not string.match(name, NAME_OK) then
				return nil, `[{name}] isn't a variable name (letters, digits, "-", "_", "." and "/")`
			end
			push("var", name, i)
			i = j + 1
		elseif c == "$" or string.match(c, "[%a_]") then
			local start = i
			if c == "$" then
				i += 1
				if string.sub(src, i, i) == "[" then
					-- ($[name] is the same as [name])
					continue
				end
			end
			local s = string.match(src, "^[%a_][%w_]*", i)
			if not s then
				return nil, `"$" at {start} needs a variable name after it`
			end
			i += #s
			while string.match(src, "^%.[%w_]", i) do
				local seg = string.match(src, "^%.[%w_]+", i)
				s ..= seg
				i += #seg
			end
			if c ~= "$" and WORDS[s] then
				push("word", s, start)
			else
				push("var", s, start)
			end
		else
			local two = string.sub(src, i, i + 1)
			if two == "==" or two == "!=" or two == "<=" or two == ">=" then
				push("op", two, i)
				i += 2
			elseif two == "&&" or two == "||" then
				return nil, `"{two}" at {i}: write {if two == "&&" then "and" else "or"} (Figma's words)`
			elseif c == "+" or c == "-" or c == "*" or c == "/" or c == "<" or c == ">" or c == "(" or c == ")" or c == "!" or c == ":" or c == "=" then
				push("op", c, i)
				i += 1
			else
				return nil, `"{c}" at {i} isn't part of an expression (use + - * /, == != < <= > >=, and, or, not, parentheses)`
			end
		end
	end
	push("end", nil, n + 1)
	return toks
end

-- ── parsing ───────────────────────────────────────────────────────────────

local function parse_tokens(toks: { any }, src: string): (any, string?)
	local pos = 1
	local function peek()
		return toks[pos]
	end
	local function is(t, v)
		local k = toks[pos]
		return k.t == t and (v == nil or k.v == v)
	end
	local function bail(msg)
		error({ expr_error = msg }, 0)
	end
	local function where(k)
		return if k.t == "end" then "at the end" else `at {k.at}`
	end
	local or_expr

	-- a mode name: letters, digits, "_", "." and inner "-" before a letter
	local function mode_name(): string
		local k = peek()
		if k.t ~= "var" and k.t ~= "word" and k.t ~= "num" then
			bail(`a mode name goes after ":" ({where(k)})`)
		end
		pos += 1
		local s = tostring(k.v)
		-- glue "dark-blue" back together (lexed as dark, -, blue)
		while is("op", "-") and toks[pos + 1].t == "var" and toks[pos + 1].at == toks[pos].at + 1 and toks[pos].at == k.at + #s do
			s ..= "-" .. toks[pos + 1].v
			pos += 2
		end
		return s
	end

	local function primary(): any
		local k = peek()
		if k.t == "num" then
			pos += 1
			return { t = "num", v = k.v }
		elseif k.t == "str" then
			pos += 1
			return { t = "str", v = k.v }
		elseif k.t == "word" and (k.v == "true" or k.v == "false") then
			pos += 1
			return { t = "bool", v = k.v == "true" }
		elseif k.t == "var" then
			pos += 1
			local node: any = { t = "var", name = k.v }
			if is("op", ":") then
				pos += 1
				local a = mode_name()
				if is("op", "=") then
					pos += 1
					node.axis, node.mode = a, mode_name()
				else
					node.mode = a
				end
			end
			return node
		elseif k.t == "op" and k.v == "(" then
			pos += 1
			local e = or_expr()
			if not is("op", ")") then
				bail(`")" expected {where(peek())}`)
			end
			pos += 1
			return e
		end
		if k.t == "end" then
			bail("a value is missing at the end")
		end
		bail(`a value is expected {where(k)}, not "{tostring(k.v)}"`)
		return nil
	end

	local function unary(): any
		if is("op", "-") then
			pos += 1
			local a = unary()
			if a.t == "num" then
				return { t = "num", v = -a.v }
			end
			return { t = "neg", a = a }
		elseif is("op", "!") or is("word", "not") then
			pos += 1
			return { t = "not", a = unary() }
		end
		return primary()
	end

	local function mul(): any
		local a = unary()
		while is("op", "*") or is("op", "/") do
			local op = peek().v
			pos += 1
			a = { t = "bin", op = op, a = a, b = unary() }
		end
		return a
	end

	local function add(): any
		local a = mul()
		while is("op", "+") or is("op", "-") do
			local op = peek().v
			pos += 1
			a = { t = "bin", op = op, a = a, b = mul() }
		end
		return a
	end

	local CMP = { ["=="] = true, ["!="] = true, ["<"] = true, ["<="] = true, [">"] = true, [">="] = true }
	local function cmp(): any
		local a = add()
		while peek().t == "op" and CMP[peek().v] do
			local op = peek().v
			pos += 1
			a = { t = "bin", op = op, a = a, b = add() }
		end
		if is("op", "=") then
			bail(`"=" {where(peek())}: compare with "=="`)
		end
		return a
	end

	local function not_expr(): any
		if is("op", "!") or is("word", "not") then
			pos += 1
			return { t = "not", a = not_expr() }
		end
		return cmp()
	end

	local function and_expr(): any
		local a = not_expr()
		while is("word", "and") do
			pos += 1
			a = { t = "bin", op = "and", a = a, b = not_expr() }
		end
		return a
	end

	or_expr = function(): any
		local a = and_expr()
		while is("word", "or") do
			pos += 1
			a = { t = "bin", op = "or", a = a, b = and_expr() }
		end
		return a
	end

	local ok, r = pcall(function()
		if peek().t == "end" then
			bail("the expression is empty")
		end
		local e = or_expr()
		if peek().t ~= "end" then
			bail(`"{tostring(peek().v)}" {where(peek())} doesn't continue the expression (an operator is missing?)`)
		end
		return e
	end)
	if not ok then
		if type(r) == "table" and r.expr_error then
			return nil, r.expr_error
		end
		error(r, 0)
	end
	return r
end

local parsed: { [string]: any } = {}
local parse_errors: { [string]: string } = {}

-- The AST of `src` (with or without its outer braces), or nil and why.
function M.parse(src: any): (any, string?)
	if type(src) ~= "string" then
		return nil, "an expression is text, as \"{count + 1}\""
	end
	src = M.inner(src) or src
	local hit = parsed[src]
	if hit then
		return hit
	end
	if parse_errors[src] then
		return nil, parse_errors[src]
	end
	local toks, why = lex(src)
	local ast
	if toks then
		ast, why = parse_tokens(toks, src)
	end
	if not ast then
		parse_errors[src] = why :: string
		return nil, why
	end
	parsed[src] = ast
	return ast
end

-- ── what it reads, and printing ───────────────────────────────────────────

-- The variable names `ast` reads, as a set.
function M.vars(ast: any, out: { [string]: boolean }?): { [string]: boolean }
	out = out or {}
	if type(ast) ~= "table" then
		return out :: any
	end
	if ast.t == "var" then
		(out :: any)[ast.name] = true
	end
	if ast.a then
		M.vars(ast.a, out)
	end
	if ast.b then
		M.vars(ast.b, out)
	end
	return out :: any
end

local PREC = { ["or"] = 1, ["and"] = 2, ["=="] = 4, ["!="] = 4, ["<"] = 4, ["<="] = 4, [">"] = 4, [">="] = 4, ["+"] = 5, ["-"] = 5, ["*"] = 6, ["/"] = 6 }
M.PREC = PREC

local function quote(s: string): string
	return "'" .. string.gsub(string.gsub(s, "\\", "\\\\"), "'", "\\'") .. "'"
end

local function bare(name: string): boolean
	if WORDS[name] or not string.match(name, "^[%a_]") then
		return false
	end
	for seg in string.gmatch(name .. ".", "([^%.]*)%.") do
		if not string.match(seg, "^[%w_]+$") then
			return false
		end
	end
	return true
end

local function var_src(name: string): string
	return if bare(name) then name else "[" .. name .. "]"
end
M.var_src = var_src

local function num_src(v: number): string
	if v == math.floor(v) and math.abs(v) < 1e15 then
		return string.format("%d", v)
	end
	return string.format("%.17g", v)
end

-- Canonical source of `ast` (no outer braces): what the panel shows and
-- what a rename writes back.
function M.print(ast: any, parent: number?): string
	local t = ast.t
	if t == "num" then
		local s = num_src(ast.v)
		return if ast.v < 0 and (parent or 0) > 0 then "(" .. s .. ")" else s
	elseif t == "str" then
		return quote(ast.v)
	elseif t == "bool" then
		return if ast.v then "true" else "false"
	elseif t == "var" then
		local s = var_src(ast.name)
		if ast.mode then
			s ..= ":" .. (if ast.axis then ast.axis .. "=" else "") .. ast.mode
		end
		return s
	elseif t == "neg" then
		return "-" .. M.print(ast.a, 7)
	elseif t == "not" then
		local s = "not " .. M.print(ast.a, 3)
		return if (parent or 0) > 3 then "(" .. s .. ")" else s
	end
	local p = PREC[ast.op]
	local s = M.print(ast.a, p) .. " " .. ast.op .. " " .. M.print(ast.b, p + 0.5)
	if (parent or 0) > p then
		s = "(" .. s .. ")"
	end
	return s
end

-- `src` with the variable `from` renamed `to` (renameToken). Unchanged when
-- it doesn't parse or doesn't read `from`.
function M.rename(src: string, from: string, to: string): string
	local braces = M.inner(src) ~= nil
	local ast = M.parse(src)
	if not ast or not M.vars(ast)[from] then
		return src
	end
	local function walk(n)
		local c = table.clone(n)
		if c.t == "var" and c.name == from then
			c.name = to
		end
		if c.a then
			c.a = walk(c.a)
		end
		if c.b then
			c.b = walk(c.b)
		end
		return c
	end
	local out = M.print(walk(ast))
	return if braces then "{" .. out .. "}" else out
end

-- ── types ─────────────────────────────────────────────────────────────────

local KIND_NAME = { number = "a number", string = "text", boolean = "true or false", color = "a colour" }
M.KIND_NAME = KIND_NAME

-- The axis a mode lookup reads, or nil and why. `themes` = doc.themes.
function M.mode_axis(node: any, themes: any): (string?, string?)
	themes = themes or {}
	if node.axis then
		local vals = themes[node.axis]
		if type(vals) ~= "table" then
			return nil, `"{node.axis}" isn't a mode axis (a Theme) of the Design`
		end
		if not table.find(vals, node.mode) then
			return nil, `the axis "{node.axis}" has no mode "{node.mode}"`
		end
		return node.axis
	end
	local found = {}
	for axis, vals in themes do
		if type(vals) == "table" and table.find(vals, node.mode) then
			table.insert(found, axis)
		end
	end
	table.sort(found)
	if #found == 0 then
		return nil, `no Theme has a mode "{node.mode}"`
	elseif #found > 1 then
		return nil, `the mode "{node.mode}" is on {table.concat(found, " and ")}: write {var_src(node.name)}:{found[1]}={node.mode}`
	end
	return found[1]
end

-- The kind `ast` gives ("number", "string", "boolean", "color"), or nil, why
-- and a code ("var-unknown", "var-type", "mode-unknown"). `kinds` = { [token
-- name] = kind }; `themes` = doc.themes (mode lookups unchecked when nil).
-- With `lenient`, an unknown variable is "any" instead of an error.
function M.check(ast: any, kinds: any, themes: any?, lenient: boolean?): (string?, string?, string?)
	local function bail(code, msg)
		error({ expr_check = msg, code = code }, 0)
	end
	local function kind(n): string
		local t = n.t
		if t == "num" then
			return "number"
		elseif t == "str" then
			return "string"
		elseif t == "bool" then
			return "boolean"
		elseif t == "var" then
			local k = kinds[n.name]
			if n.mode and themes then
				local _, why = M.mode_axis(n, themes)
				if why then
					bail("mode-unknown", why)
				end
			end
			if not k then
				if lenient then
					return "any"
				end
				bail("var-unknown", `the Design has no variable (Token) "{n.name}"`)
			end
			return k
		elseif t == "neg" then
			local a = kind(n.a)
			if a ~= "number" and a ~= "any" then
				bail("var-type", `"-" goes before a number, not {KIND_NAME[a]} ({M.print(n.a)})`)
			end
			return "number"
		elseif t == "not" then
			local a = kind(n.a)
			if a ~= "boolean" and a ~= "any" then
				bail("var-type", `not goes before true or false, not {KIND_NAME[a]} ({M.print(n.a)})`)
			end
			return "boolean"
		end
		local op = n.op
		local a, b = kind(n.a), kind(n.b)
		local any = a == "any" or b == "any"
		if op == "+" then
			if a == "number" and b == "number" then
				return "number"
			end
			if (a == "string" and (b == "string" or b == "number")) or (b == "string" and a == "number") then
				return "string"
			end
			if any and a ~= "boolean" and b ~= "boolean" and a ~= "color" and b ~= "color" then
				return if a == "string" or b == "string" then "string" else "any"
			end
			bail("var-type", `"+" adds numbers or joins text, not {KIND_NAME[a] or a} and {KIND_NAME[b] or b} ({M.print(n)})`)
		elseif op == "-" or op == "*" or op == "/" then
			if (a == "number" or a == "any") and (b == "number" or b == "any") then
				return "number"
			end
			bail("var-type", `"{op}" works on numbers, not {KIND_NAME[a] or a} and {KIND_NAME[b] or b} ({M.print(n)})`)
		elseif op == "==" or op == "!=" then
			if any or a == b or (a == "color" and b == "string") or (a == "string" and b == "color") then
				return "boolean"
			end
			bail("var-type", `"{op}" compares two values of one kind, not {KIND_NAME[a]} and {KIND_NAME[b]} ({M.print(n)})`)
		elseif op == "<" or op == "<=" or op == ">" or op == ">=" then
			if (a == "number" or a == "any") and (b == "number" or b == "any") then
				return "boolean"
			end
			bail("var-type", `"{op}" compares numbers, not {KIND_NAME[a] or a} and {KIND_NAME[b] or b} ({M.print(n)})`)
		elseif op == "and" or op == "or" then
			if (a == "boolean" or a == "any") and (b == "boolean" or b == "any") then
				return "boolean"
			end
			bail("var-type", `{op} joins true/false values, not {KIND_NAME[a] or a} and {KIND_NAME[b] or b} ({M.print(n)})`)
		end
		bail("expr-invalid", `unknown operator {tostring(op)}`)
		return "any"
	end
	local ok, r = pcall(kind, ast)
	if not ok then
		if type(r) == "table" and r.expr_check then
			return nil, r.expr_check, r.code
		end
		error(r, 0)
	end
	return r
end

-- Whether `ast` divides by a literal 0 somewhere (lint div-zero).
function M.divides_by_zero(ast: any): boolean
	if type(ast) ~= "table" then
		return false
	end
	if ast.t == "bin" and ast.op == "/" and ast.b.t == "num" and ast.b.v == 0 then
		return true
	end
	return M.divides_by_zero(ast.a) or M.divides_by_zero(ast.b)
end

-- ── running ───────────────────────────────────────────────────────────────

local function close_to(a: number, b: number): boolean
	return math.abs(a - b) <= 1e-9 * math.max(1, math.abs(a), math.abs(b))
end

local function equal(a: any, b: any): boolean
	if type(a) == "number" and type(b) == "number" then
		return close_to(a, b)
	end
	if type(a) == "string" and type(b) == "string" and string.sub(a, 1, 1) == "#" and string.sub(b, 1, 1) == "#" then
		return string.upper(a) == string.upper(b)
	end
	return a == b
end
M.equal = equal

-- A Luau closure for `ast`: fn(get, warn) → value. `get(name, axis?, mode?)`
-- reads a variable (axis/mode for a mode lookup: `axis` may be nil, then
-- the caller finds it); `warn(code, message)` hears run-time problems
-- ("div-zero" gives 0, "var-type" a fallback value).
function M.closure(ast: any): (any, any) -> any
	local t = ast.t
	if t == "num" or t == "str" or t == "bool" then
		local v = ast.v
		return function()
			return v
		end
	elseif t == "var" then
		local name, axis, mode = ast.name, ast.axis, ast.mode
		return function(get, _warn)
			return get(name, axis, mode)
		end
	elseif t == "neg" then
		local a = M.closure(ast.a)
		return function(get, warn)
			local x = a(get, warn)
			if type(x) ~= "number" then
				warn("var-type", `"-" before {M.text(x)}, which isn't a number`)
				return 0
			end
			return -x
		end
	elseif t == "not" then
		local a = M.closure(ast.a)
		return function(get, warn)
			local x = a(get, warn)
			if type(x) ~= "boolean" then
				warn("var-type", `not before {M.text(x)}, which isn't true or false`)
			end
			return x ~= true
		end
	end
	local op = ast.op
	local a, b = M.closure(ast.a), M.closure(ast.b)
	if op == "and" then
		return function(get, warn)
			return a(get, warn) == true and b(get, warn) == true
		end
	elseif op == "or" then
		return function(get, warn)
			return a(get, warn) == true or b(get, warn) == true
		end
	end
	return function(get, warn)
		local x, y = a(get, warn), b(get, warn)
		if op == "+" then
			if type(x) == "number" and type(y) == "number" then
				return x + y
			end
			if type(x) == "string" or type(y) == "string" then
				return M.text(x) .. M.text(y)
			end
			warn("var-type", `"+" on {M.text(x)} and {M.text(y)}`)
			return if type(x) == "number" then x elseif type(y) == "number" then y else 0
		elseif op == "==" then
			return equal(x, y)
		elseif op == "!=" then
			return not equal(x, y)
		end
		if type(x) ~= "number" or type(y) ~= "number" then
			warn("var-type", `"{op}" on {M.text(x)} and {M.text(y)}, which aren't both numbers`)
			if op == "-" or op == "*" or op == "/" then
				return 0
			end
			return false
		end
		if op == "-" then
			return x - y
		elseif op == "*" then
			return x * y
		elseif op == "/" then
			if y == 0 then
				warn("div-zero", `{M.text(x)} / 0 gives 0`)
				return 0
			end
			return x / y
		elseif op == "<" then
			return x < y and not close_to(x, y)
		elseif op == "<=" then
			return x < y or close_to(x, y)
		elseif op == ">" then
			return x > y and not close_to(x, y)
		elseif op == ">=" then
			return x > y or close_to(x, y)
		end
		return nil
	end
end

local compiled: { [string]: any } = {}

-- `src` compiled (cached): fn(get, warn) → value, or nil and why.
function M.compile(src: string): (((any, any) -> any)?, string?)
	local key = M.inner(src) or src
	local hit = compiled[key]
	if hit then
		return hit
	end
	local ast, why = M.parse(key)
	if not ast then
		return nil, why
	end
	local fn = M.closure(ast)
	compiled[key] = fn
	return fn
end

-- Runs `src` once over a plain table of values ({ count = 2 }); mode lookups
-- read `values["count:pears"]` or `values.count`. Returns value, problems
-- ({ { code, message } }), or nil and why.
function M.eval(src: string, values: any): (any, any)
	local fn, why = M.compile(src)
	if not fn then
		return nil, why
	end
	local problems = {}
	local v = fn(function(name, axis, mode)
		if mode then
			local k = name .. ":" .. (if axis then axis .. "=" else "") .. mode
			if values[k] ~= nil then
				return values[k]
			end
		end
		return values[name]
	end, function(code, msg)
		table.insert(problems, { code = code, message = msg })
	end)
	return v, problems
end

-- ── the export ────────────────────────────────────────────────────────────

-- `ast` as a JS expression. It calls the page's V(name, axis?, mode?) for a
-- variable and the helpers in M.JS_HELPERS for +, /, == and !=, so the
-- export runs the same rules as Play.
function M.js(ast: any): string
	local t = ast.t
	if t == "num" then
		return "(" .. num_src(ast.v) .. ")"
	elseif t == "str" then
		local s = string.gsub(ast.v, "[\\\"\n\r<>&]", function(c)
			return string.format("\\u%04x", string.byte(c))
		end)
		s = string.gsub(string.gsub(s, "\u{2028}", "\\u2028"), "\u{2029}", "\\u2029")
		return '"' .. s .. '"'
	elseif t == "bool" then
		return if ast.v then "true" else "false"
	elseif t == "var" then
		local args = '"' .. ast.name .. '"'
		if ast.mode then
			args ..= "," .. (if ast.axis then '"' .. ast.axis .. '"' else "null") .. ',"' .. ast.mode .. '"'
		end
		return "V(" .. args .. ")"
	elseif t == "neg" then
		return "(-" .. M.js(ast.a) .. ")"
	elseif t == "not" then
		return "(" .. M.js(ast.a) .. "!==true)"
	end
	local op, a, b = ast.op, M.js(ast.a), M.js(ast.b)
	if op == "+" then
		return "$add(" .. a .. "," .. b .. ")"
	elseif op == "/" then
		return "$div(" .. a .. "," .. b .. ")"
	elseif op == "==" then
		return "$eq(" .. a .. "," .. b .. ")"
	elseif op == "!=" then
		return "(!$eq(" .. a .. "," .. b .. "))"
	elseif op == "and" then
		return "(" .. a .. "===true&&" .. b .. "===true)"
	elseif op == "or" then
		return "(" .. a .. "===true||" .. b .. "===true)"
	elseif op == "<" or op == ">" or op == "<=" or op == ">=" then
		return "$cmp(" .. a .. ',"' .. op .. '",' .. b .. ")"
	end
	return "(" .. a .. op .. b .. ")"
end

-- The helpers M.js's output calls. `$warn(code, message)` is optional (the
-- page may define it to report div-zero).
M.JS_HELPERS = [[
function $fmt(n){if(typeof n!=="number")return n==null?"":String(n);if(n!==n)return"0";if(!isFinite(n))return n>0?"Infinity":"-Infinity";var r=Math.floor(n*100+0.5)/100;if(r===0)return"0";return String(r)}
function $add(a,b){if(typeof a==="number"&&typeof b==="number")return a+b;if(typeof a==="string"||typeof b==="string")return $fmt(a)+$fmt(b);return typeof a==="number"?a:typeof b==="number"?b:0}
function $div(a,b){if(b===0){if(typeof $warn==="function")$warn("div-zero",$fmt(a)+" / 0 gives 0");return 0}return a/b}
function $near(a,b){return Math.abs(a-b)<=1e-9*Math.max(1,Math.abs(a),Math.abs(b))}
function $eq(a,b){if(typeof a==="number"&&typeof b==="number")return $near(a,b);if(typeof a==="string"&&typeof b==="string"&&a[0]==="#"&&b[0]==="#")return a.toUpperCase()===b.toUpperCase();return a===b}
function $cmp(a,o,b){if(typeof a!=="number"||typeof b!=="number")return false;var n=$near(a,b);return o==="<"?a<b&&!n:o==="<="?a<b||n:o===">"?a>b&&!n:a>b||n}
]]

return M
