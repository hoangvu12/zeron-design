--!strict
-- Errors out of the tab's handlers made readable. Zeron reports a handler's
-- error as the plugin's crash note with `tostring`, so an error that is a
-- table (zeron.need's, a structured error) read "table: 0000…" and said
-- nothing. `Guard.wrap(where, f)` runs `f` and, if it fails, raises a string
-- instead: where, what (a table's fields), and the traceback.

local M = {}

local function describe(e: any): string
	if type(e) ~= "table" then
		return tostring(e)
	end
	local parts = {}
	for k, v in e do
		if #parts >= 8 then
			table.insert(parts, "…")
			break
		end
		table.insert(parts, `{tostring(k)}={tostring(v)}`)
	end
	local mt = getmetatable(e)
	local kind = if type(mt) == "table" and mt.__tostring then tostring(e) else "table"
	return `{kind} \{{table.concat(parts, ", ")}\}`
end
M.describe = describe

function M.wrap<A..., R...>(where: string, f: (A...) -> R...): (A...) -> R...
	return function(...: A...): R...
		local out = table.pack(xpcall(f, function(e: any): string
			-- (Where the VM gives one: a sandbox without `debug` gives none,
			-- and Zeron adds the stack to a string error anyway.)
			local got, trace = pcall(function(): string
				return (debug :: any).traceback("", 3)
			end)
			trace = if got and type(trace) == "string" then trace else ""
			return `Design: {where}: {describe(e)}{trace}`
		end, ...))
		if not out[1] then
			error(out[2], 0)
		end
		return table.unpack(out, 2, out.n)
	end
end

-- `raw` (zeron.service()) with each event's handler and each call's
-- answer and failure handlers wrapped: what fails in them says where.
function M.service(raw: any): any
	local out = {}
	function out.on(_self: any, name: string, f: (any) -> ())
		return raw:on(name, M.wrap(`service event {name}`, f))
	end
	function out.call(_self: any, name: string, args: any): any
		local promise = raw:call(name, args)
		return {
			after = function(_p: any, ok: ((any) -> ())?, failed: ((any) -> ())?)
				return promise:after(
					if ok then M.wrap(`{name} answer`, ok) else nil,
					if failed then M.wrap(`{name} failure`, failed) else nil
				)
			end,
		}
	end
	return out
end

return M
