--!strict
-- N1 (live building): what an agent's call did, for the Design tab to
-- animate on its overlay (pure/anim/n1/README.md). Read from the committed
-- draft (engine/edit.luau), after `Agent.execute`; nothing here changes it.
--
-- `changes(draft, max)`: `{ { id, kind } }`, kind "new" (made by this call),
-- "edit" (changed) or "delete" (taken out: the tab finds its old bounds in
-- the scene it still shows). The outermost of each, at most `max` in all.
-- `reads(draft)`: the Screens (root ids) the call looked at (screenshots).

local M = {}

local function root_of(draft: any, id: string): string?
	local f = draft:find(string.match(id, "^([^/]+)") or id)
	local guard = 0
	while f and f.parent and guard < 256 do
		guard += 1
		f = draft:find(f.parent.id)
	end
	return if f then f.node.id else nil
end

function M.changes(draft: any, max: number): { any }
	local out = {}
	if type(draft) ~= "table" or type(draft.outermost) ~= "function" then
		return out
	end
	local made: { [string]: boolean } = {}
	for _, m in draft.created or {} do
		if type(m) == "table" and type(m.id) == "string" then
			made[m.id] = true
		end
	end
	local ok, list = pcall(draft.outermost, draft, max)
	if ok and type(list) == "table" then
		for _, id in list do
			table.insert(out, { id = id, kind = if made[id] then "new" else "edit" })
		end
	end
	-- Deleted: `D:delete` marks each id it was asked for in `changed` (not in
	-- `changed_list`); their descendants are only in `deleted`.
	for id in draft.deleted or {} do
		if #out >= max then
			break
		end
		if draft.changed and draft.changed[id] and not draft:find(id) then
			table.insert(out, { id = id, kind = "delete" })
		end
	end
	return out
end

function M.reads(draft: any): { string }
	local out, seen = {}, {}
	if type(draft) ~= "table" then
		return out
	end
	for _, s in draft.screenshots or {} do
		local id = if type(s) == "string" then s elseif type(s) == "table" and type(s.id) == "string" then s.id else nil
		local r = if id then root_of(draft, id) else nil
		if r and not seen[r] then
			seen[r] = true
			table.insert(out, r)
		end
	end
	return out
end

return M
