--!strict
-- Play's flows sidebar (step 6 P3, pure/anim/f6/PLAN.md), the pure part:
-- which flow is playing, whether the sidebar opens, and a flow's description
-- (plain text, as the panel writes it) cut into blocks for Play to show.
-- No `ui`: tests/play_flows.luau runs it headless.

local M = {}

-- The sidebar's width (Figma's: 240 px on the left).
M.W = 240

-- Open or not: the viewer's own choice (`saved`: true / false) when made,
-- else open for a Design with 2+ flows (as Figma's).
function M.open(saved: any, n: number): boolean
	if saved == true or saved == false then
		return saved
	end
	return n >= 2
end

-- The playing flow's index in `flows`: the one named `name` starting at
-- `start`, else the first starting at `start`, else the first named `name`;
-- nil when none matches (Play started at a Screen no flow starts at).
function M.current(flows: { any }, start: string?, name: string?): number?
	local by_start, by_name = nil, nil
	for i, f in flows do
		if f.start == start and f.name == name then
			return i
		end
		if by_start == nil and start ~= nil and f.start == start then
			by_start = i
		end
		if by_name == nil and name ~= nil and f.name == name then
			by_name = i
		end
	end
	return by_start or by_name
end

-- A line's runs: plain text and URLs (`http(s)://…` or `www.…`, up to a
-- space; a trailing `.,;:!?)` stays text). Each run is `{ x, url? }`.
function M.runs(line: string): { any }
	local out = {}
	local at = 1
	while at <= #line do
		local s1, e1 = string.find(line, "https?://[^%s]+", at)
		-- (a "www." that starts a word)
		local s2, e2 = string.find(line, "%f[%w]www%.[^%s]+", at)
		local s, e = s1, e1
		if s2 and (not s or s2 < s) then
			s, e = s2, e2
		end
		if not s or not e then
			break
		end
		while e > s and string.find(string.sub(line, e, e), "[%.,;:!%?%)]") do
			e -= 1
		end
		if s > at then
			table.insert(out, { x = string.sub(line, at, s - 1) })
		end
		local u = string.sub(line, s, e)
		table.insert(out, { x = u, url = if string.sub(u, 1, 4) == "www." then "https://" .. u else u })
		at = e + 1
	end
	if at <= #line then
		table.insert(out, { x = string.sub(line, at) })
	end
	-- (neighbouring text runs as one)
	local merged = {}
	for _, r in out do
		local last = merged[#merged]
		if last and not last.url and not r.url then
			last.x ..= r.x
		else
			table.insert(merged, r)
		end
	end
	return merged
end

-- A description cut into blocks, in order: `{ t = "p", runs }` (a paragraph:
-- lines next to each other joined by a space), `{ t = "ul", items = { runs } }`
-- (lines starting "- ", "* " or "• "), `{ t = "ol", start, items = { runs } }`
-- (lines starting "1. " or "1) "). A blank line ends a block. Empty or blank:
-- no blocks (Play says "No description").
function M.blocks(text: string?): { any }
	local out = {}
	if type(text) ~= "string" then
		return out
	end
	local cur: any = nil
	local para: { string } = {}
	local function end_para()
		if #para > 0 then
			table.insert(out, { t = "p", runs = M.runs(table.concat(para, " ")) })
			table.clear(para)
		end
	end
	local norm = string.gsub(string.gsub(text, "\r\n", "\n"), "\r", "\n")
	for _, raw in string.split(norm, "\n") do
		local line = string.match(raw, "^%s*(.-)%s*$") or ""
		local bullet = string.match(line, "^[%-%*]%s+(.*)$") or string.match(line, "^•%s*(.*)$")
		local num, item = string.match(line, "^(%d+)[%.%)]%s+(.*)$")
		if line == "" then
			end_para()
			cur = nil
		elseif bullet then
			end_para()
			if not cur or cur.t ~= "ul" then
				cur = { t = "ul", items = {} }
				table.insert(out, cur)
			end
			table.insert(cur.items, M.runs(bullet))
		elseif num and item then
			end_para()
			if not cur or cur.t ~= "ol" then
				cur = { t = "ol", start = tonumber(num) or 1, items = {} }
				table.insert(out, cur)
			end
			table.insert(cur.items, M.runs(item))
		else
			cur = nil
			table.insert(para, line)
		end
	end
	end_para()
	return out
end

return M
