--!strict
-- A Design's scene roots, kept in Luau. Only a light list goes into state:
-- `{ id, v, k, live? }` per root, what the board's `each` walks (a root's
-- item changes, so that root alone is drawn again). The roots themselves
-- (hundreds of items each) never go into state: a state holding them would
-- copy them to Rust on every write and back on the first read after it,
-- and that copy ran in whichever call read them first (a whole Design's in
-- one draw or one index, past a call's time budget on a large Design).
--
-- Reads like a list state: `get()` (follows it) and `peek()` give the
-- roots in paint order; `set(list)`, `set_key(i, root)` write them;
-- `set_live(i, live)` / `live_at(i)` hold a drag's live state per root.

local M = {}

export type Roots = {
	items: any, -- State<{ { id: string, v: number?, k: number, live: any? } }>
	rev: number, -- bumped on every write of a root (not of `live`)
	get: (self: Roots) -> { any },
	peek: (self: Roots) -> { any },
	set: (self: Roots, list: { any }) -> (),
	set_key: (self: Roots, i: number, root: any) -> (),
	set_live: (self: Roots, i: number, live: any) -> (),
	live_at: (self: Roots, i: number) -> any,
	full: (self: Roots, item: any) -> any?,
}

function M.new(key: string?): Roots
	local items = if key then ui.state(key, {} :: { any }) else ui.use_state({} :: { any })
	-- (A named state outlives a reload; the roots it named don't.)
	items:set({})
	local by: { [string]: any } = {}
	local list: { any } = {}
	local k = 0
	local self: any = { items = items, rev = 0 }

	local function item_of(root: any): any
		k += 1
		return { id = root.id, v = root.v, k = k }
	end

	function self.get(_s: any): { any }
		local _ = items:get()
		return list
	end
	function self.peek(_s: any): { any }
		return list
	end
	function self.set(_s: any, new: { any })
		list = table.clone(new)
		table.clear(by)
		local light = {}
		for i, r in list do
			by[r.id] = r
			light[i] = item_of(r)
		end
		self.rev += 1
		items:set(light)
	end
	function self.set_key(_s: any, i: number, root: any)
		local old = list[i]
		if old and old.id ~= root.id then
			by[old.id] = nil
		end
		list = table.clone(list)
		list[i] = root
		by[root.id] = root
		self.rev += 1
		items:set_key(i, item_of(root))
	end
	function self.set_live(_s: any, i: number, live: any)
		if list[i] then
			items:set_key({ i, "live" }, live)
		end
	end
	function self.live_at(_s: any, i: number): any
		local l = items:peek()[i]
		return if l then l.live else nil
	end
	function self.full(_s: any, item: any): any?
		return by[item.id]
	end
	return self :: Roots
end

return M
