--!nonstrict
-- Local comments in the tab (step 7, pure/anim/f7/comments/README.md), pure
-- (no `ui`): where a pin sits on a Screen as drawn, a click's point on the
-- Screen and the layer under it, the pins of one Screen, the sidebar's groups,
-- and an in-memory store with the service's rules (the harness's fixture
-- source). The UI is tab/comments_ui.luau.

local Rules = require("./comments_rules")

local M = {}

M.GONE = "Not in the Design"

-- A store kept here (the fixture source's): `run(args)` → result, or raises;
-- `list()` → pins with replies.
function M.memory(rows: { any }?): any
	local all = rows or {}
	local clock = 0
	return {
		run = function(args: any): any
			-- (seconds, as the service's; each action later than the one before)
			clock = math.max(clock + 1, os.time())
			local a = table.clone(args)
			a.did = a.did or "fixture"
			local _, _, r = Rules.act(all, a, { author = if type(args.author) == "string" then args.author else "You", chat = args.chat }, clock)
			return r
		end,
		list = function(): { any }
			return Rules.threads(all)
		end,
	}
end

local function index_of(root: any, id: string?): number?
	if not id or not root or not root.nodes then
		return nil
	end
	for i, it in root.nodes do
		if it.id == id then
			return i
		end
	end
	return nil
end

-- A click at (x, y), Canvas units as laid out (Play's `to_screen`), over item
-- `i` of `root` (Proto.deepest; 0 or nil: none): the Screen point under it
-- (scrolling taken off) and the layer with the point on it.
-- `shift(i)` → dx, dy: item i's scroll offset as shown.
function M.local_point(root: any, i: number?, x: number, y: number, shift: ((number) -> (number, number))?): any
	local b = root.nodes[1].box
	local it = i and i > 1 and root.nodes[i] or nil
	local dx, dy = 0, 0
	if it and shift then
		dx, dy = shift(i :: number)
	end
	local out: any = { x = x - dx - b.x, y = y - dy - b.y }
	if it and it.box then
		out.node = it.id
		out.nx = x - dx - it.box.x
		out.ny = y - dy - it.box.y
	end
	return out
end

-- Where pin `t` is on `root` as drawn (Canvas units): on its layer (moved
-- with it, its scroll counted) while the layer is there, else at its Screen
-- point.
function M.anchor(root: any, t: any, shift: ((number) -> (number, number))?): any?
	if not root or not root.nodes or not root.nodes[1] then
		return nil
	end
	local i = index_of(root, t.node)
	if i and type(t.nx) == "number" and type(t.ny) == "number" then
		local it = root.nodes[i]
		local dx, dy = 0, 0
		if shift then
			dx, dy = shift(i)
		end
		return { x = it.box.x + dx + t.nx, y = it.box.y + dy + t.ny }
	end
	local b = root.nodes[1].box
	return { x = b.x + t.x, y = b.y + t.y }
end

-- (followups) The layer a new pin hangs on: item `i` of Play's `root`, or
-- the nearest layer around it that the Design itself has (`base`: the scene's
-- root of that Screen). An Instance switched to another variant in Play
-- (Change to) holds that variant's layers, which the board doesn't have:
-- the pin then hangs on the Instance, so it follows it everywhere.
function M.kept_layer(root: any, i: number?, base: any?): number?
	if not i or not base or not base.nodes then
		return i
	end
	local have: { [string]: boolean } = {}
	for _, it in base.nodes do
		have[it.id] = true
	end
	local k = i
	while k and k > 1 do
		local it = root.nodes[k]
		if not it then
			return nil
		end
		if have[it.id] then
			return k
		end
		k = index_of(root, it.p)
	end
	return nil
end

-- Root id → root (the scene's roots list).
function M.roots_by(list: { any }?): { [string]: any }
	local out = {}
	for _, r in list or {} do
		if r.id then
			out[r.id] = r
		end
	end
	return out
end

-- The pins on Screen `screen`: open ones (and resolved with `resolved`).
function M.on_screen(list: { any }, screen: string, resolved: boolean?): { any }
	local out = {}
	for _, t in list do
		if t.screen == screen and (resolved or not t.resolved) then
			table.insert(out, t)
		end
	end
	return out
end

function M.count_open(list: { any }): number
	local n = 0
	for _, t in list do
		if not t.resolved then
			n += 1
		end
	end
	return n
end

-- The sidebar's groups: { screen, name, items }, the shown Screen (`first`)
-- first, then the others by their first pin's number. `names`: Screen id →
-- name (a Screen not there: M.GONE).
function M.groups(list: { any }, names: { [string]: string }, first: string?, resolved: boolean?): { any }
	local by, order = {}, {}
	for _, t in list do
		if resolved or not t.resolved then
			local g = by[t.screen]
			if not g then
				g = { screen = t.screen, name = names[t.screen] or M.GONE, items = {} }
				by[t.screen] = g
				table.insert(order, g)
			end
			table.insert(g.items, t)
		end
	end
	if first and by[first] then
		local i = table.find(order, by[first])
		table.remove(order, i)
		table.insert(order, 1, by[first])
	end
	return order
end

-- "3 min" / "2 h" / "5 d" ago from seconds; "" when unknown.
function M.ago(at: number?, now: number): string
	if type(at) ~= "number" or at <= 0 then
		return ""
	end
	local s = math.max(0, now - at)
	if s < 60 then
		return "now"
	elseif s < 3600 then
		return `{math.floor(s / 60)} min`
	elseif s < 86400 then
		return `{math.floor(s / 3600)} h`
	end
	return `{math.floor(s / 86400)} d`
end

-- Who wrote it, as shown: the person ("You"), an agent (its chat's title
-- when the host knows it), or the name kept.
function M.who(c: any, chat_title: ((string?) -> string?)?): string
	if c.author == "Agent" then
		local t = chat_title and c.chat and chat_title(c.chat)
		return if t and t ~= "" then `Agent · {t}` else "Agent"
	end
	return if type(c.author) == "string" and c.author ~= "" then c.author else "You"
end

return M
