--!strict
-- Interactive components (step 4, figma-parity.md §3.4), the parts Play and
-- Simulate share. Pure: no state, no ui.
--
-- The scene carries `vset` on an Instance's item (the variant set its
-- Component is in; `inst` is the member it shows) and, in a reaction,
-- `{ k = "changeTo", to = <member id>, set, tr, broken? }`.
--
-- A Screen's variant state is a map { [instance item id] = member id }
-- (the service resolves the Screen with it: `scene { variants }`). The
-- memory is by set and name path (Figma shares a component's state with
-- matching instances on other frames): { [key] = { to, set } }.

local M = {}

local function index_of(nodes: { any }): { [string]: number }
	local at = {}
	for i, it in nodes do
		at[it.id] = i
	end
	return at
end

-- The closest Instance at or above item `i` whose set is `set` (Figma: a
-- Change to on a nested layer changes the instance whose set holds it).
function M.target(nodes: { any }, i: number, set: string): number?
	local at = index_of(nodes)
	local k: number? = i
	while k do
		local it = nodes[k]
		if it.vset == set then
			return k
		end
		k = if it.p then at[it.p] else nil
	end
	return nil
end

-- Item i's names from the root down (the root left out): "Row/Switch".
function M.path(nodes: { any }, i: number): string
	local at = index_of(nodes)
	local names = {}
	local k: number? = i
	while k and k > 1 do
		local it = nodes[k]
		table.insert(names, 1, tostring(it.name or it.id))
		k = if it.p then at[it.p] else nil
	end
	return table.concat(names, "/")
end

-- (F4b, filmed in Figma: the state is shared by the Instance's set and name
-- path on every frame and overlay, whatever the Screen; "Profile" and an
-- overlay's "Wifi" share "Settings"' Wifi, while a "Bluetooth" in Wifi's
-- place doesn't)
function M.key(nodes: { any }, i: number): string
	return tostring(nodes[i].vset) .. "|" .. M.path(nodes, i)
end

-- Navigate's "Reset component state": the target Screen's Instances forget
-- (and so do the matching ones elsewhere, which share their keys).
function M.forget(mem: { [string]: any }, nodes: { any })
	for i, it in nodes do
		if it.vset then
			mem[M.key(nodes, i)] = nil
		end
	end
end

-- The state after a Change to `act` on item `i` (the reaction's layer):
-- the new map, the target item's index and id, or nil (no Instance of the
-- set around it, or it shows that member already).
function M.change(nodes: { any }, vmap: { [string]: string }, i: number, act: any): ({ [string]: string }?, number?)
	if not act.set or not act.to then
		return nil, nil
	end
	local t = M.target(nodes, i, act.set)
	if not t then
		return nil, nil
	end
	local it = nodes[t]
	if it.inst == act.to then
		return nil, t
	end
	local out = {}
	local inner = it.id .. "/"
	for id, m in vmap do
		-- (the Instances inside start at their own variants: the new member's)
		if string.sub(id, 1, #inner) ~= inner then
			out[id] = m
		end
	end
	-- (back to the member the Design has: no entry, the Screen as it is)
	out[it.id] = if it.vdef and act.to == it.vdef then nil else act.to
	return out, t
end

-- Remembers item t's new member under its key.
function M.remember(mem: { [string]: any }, nodes: { any }, t: number, to: string, set: string)
	mem[M.key(nodes, t)] = { to = to, set = set }
end

-- The map a Screen shows by the memory: each Instance (of a set) whose key
-- has a member remembered, of its own set, that it doesn't show yet. Adds
-- to `base`; returns the map and whether it added anything.
function M.from_memory(nodes: { any }, mem: { [string]: any }, base: { [string]: string }?): ({ [string]: string }, boolean)
	local out = table.clone(base or {})
	local added = false
	if next(mem) == nil then
		return out, false
	end
	for i, it in nodes do
		if it.vset then
			local m = mem[M.key(nodes, i)]
			if m and m.set == it.vset and m.to ~= it.inst and out[it.id] ~= m.to then
				out[it.id] = m.to
				added = true
			elseif m and m.set == it.vset and m.to == (it.vdef or it.inst) and out[it.id] ~= nil then
				-- (back to the Design's own member, changed elsewhere)
				out[it.id] = nil
				added = true
			end
		end
	end
	return out, added
end

-- A map as one string (cache keys).
function M.signature(vmap: { [string]: string }): string
	local parts = {}
	for id, m in vmap do
		table.insert(parts, id .. "=" .. m)
	end
	table.sort(parts)
	return table.concat(parts, ";")
end

-- The ids of the items inside item t (t included), for a Change to's own
-- timers (an afterDelay on the new member starts when it shows).
function M.inside(nodes: { any }, t: number): { [string]: boolean }
	local out = {}
	for k = t, t + (nodes[t].n or 0) do
		out[nodes[k].id] = true
	end
	return out
end

return M
