--!strict
-- The hand cursor on clickable controls (zgx's ui is read-only: see pointer.luau).
local ui = require("./pointer").ui
-- The Layers tab (the redesign's Board · Left panel, "Layers · every row
-- state"): rows h28 r7 a pixel apart, 8 + 12 a level from the left, a 12px
-- chevron, a 14px type icon, the name 12px. Screens (top level) 12/500 in
-- fg, the rest 12/400 muted; Components (name and icon) in `component`,
-- Instances in `instance`. Selected: accent_soft, the icon accent, the name
-- accent_fg 500; the selection's children a fainter tint. Hover: the field
-- grey, the lock and the eye at the right (pinned while locked / hidden; a
-- hidden row at 45%). A drag drops between rows (a 2px accent line, indented)
-- or into a frame (the row outlined in accent). Renaming: an accent-outlined
-- field. A root an agent is building shows "● <chat>" in agent colours.
-- The hover follows the Canvas's both ways. Order: a flex layout's children
-- as written, free ones topmost first. Click selects (Shift adds),
-- double-click renames. Edits are the contract's ops (update, reorder,
-- reparent).

local Kit = require("./kit")
local Look = require("./look")

local M = {}

local ROW_H = 28
local ROW_GAP = 1
local INDENT = 12
local PAD_L = 8

local function type_icon(n: any): string
	if n.comp then
		return "component"
	end
	if n.t == "instance" or n.inst then
		return "instance"
	end
	if n.lay == "vertical" then
		return "layV"
	elseif n.lay == "horizontal" then
		return "layH"
	end
	if n.t == "text" then
		return "text"
	elseif n.t == "rectangle" then
		return "rect"
	elseif n.t == "ellipse" then
		return "ellipse"
	elseif n.t == "icon" then
		return "icon"
	elseif n.t == "path" or n.t == "line" then
		return "path"
	elseif n.t == "polygon" then
		return "polygon"
	end
	return "frame"
end
M.type_icon = type_icon

function M.Layers(props: { L: any, source: any, hover: any, id: string?, find: any? }): Node
	local L = props.L
	local source = props.source
	local selection = source.selection
	local hover = props.hover
	-- Open rows: Screens open by default one level (pen opens the Screen
	-- the selection is in).
	local open = ui.use_state({} :: { [string]: boolean })
	local renaming = ui.use_state(nil :: string?)
	local drop = ui.use_state(nil :: { id: string, where: string }?)
	local filter = ui.use_state("")
	local last_click: { id: string?, at: number } = { id = nil, at = 0 }

	local function kids_of(list: { any }): { [string]: { any } }
		local kids: { [string]: { any } } = {}
		for _, n in list do
			local p = n.p or ""
			kids[p] = kids[p] or {}
			table.insert(kids[p], n)
		end
		return kids
	end

	-- Roots an agent is building (`inProgress`, by a chat): from the tree
	-- when it carries `wip` / `by`, else from the scene's root items.
	local agents = ui.computed(function(): { [string]: any }
		local out: { [string]: any } = {}
		local roots = source.roots
		if roots and roots.get then
			for _, r in roots:get() or {} do
				local first = type(r) == "table" and r.nodes and r.nodes[1]
				if first and first.wip then
					out[first.id] = first.by or true
				end
			end
		end
		return out
	end)
	local function agent_of(n: any): string?
		local by = if n.wip then (n.by or true) else agents:get()[n.id]		if by == nil then
			return nil
		end
		local who = if type(by) == "string" and source.chat_title then source.chat_title(by) else nil
		return who or "Agent"
	end

	-- The rows shown: depth first, the topmost (last drawn) first as pen
	-- lists them, children only under open rows.
	local rows = ui.computed(function(): { any }
		local list = source.tree:get()
		local o = open:get()
		-- (The filter holds only while Find is open: closing it shows every row.)
		local find_on = props.find == nil or props.find:get() == true
		local f = if find_on then string.lower(filter:get()) else ""
		local kids = kids_of(list)
		local out = {}
		local by: { [string]: any } = {}
		for _, n in list do
			by[n.id] = n
		end
		-- (The selection's ancestors open, so it shows.)
		local sel_open: { [string]: boolean } = {}
		for _, id in selection:get() or {} do
			local n = by[id]
			while n and n.p do
				sel_open[n.p] = true
				n = by[n.p]
			end
		end
		local function walk(p: string, depth: number, in_comp: boolean, anc: { string })
			local list2 = kids[p] or {}
			local parent = by[p]
			local flex = parent ~= nil and parent.lay ~= nil
			local from, to, step = #list2, 1, -1
			if flex then
				from, to, step = 1, #list2, 1
			end
			for k = from, to, step do
				local n = list2[k]
				local has = kids[n.id] ~= nil and #kids[n.id] > 0
				local is_open = o[n.id] or (o[n.id] == nil and sel_open[n.id])
				if f == "" or string.find(string.lower(n.name or ""), f, 1, true) then
					table.insert(out, { id = n.id, n = n, depth = depth, has = has, open = is_open and has, light = in_comp, anc = anc })
				end
				if has and (is_open or f ~= "") then
					local anc2 = table.clone(anc)
					table.insert(anc2, n.id)
					walk(n.id, depth + 1, in_comp or n.comp == true, anc2)
				end
			end
		end
		walk("", 0, false, {})
		return out
	end)

	local function select(id: string, add: boolean)
		local s = table.clone(selection:peek() or {})
		if add then
			local at = table.find(s, id)
			if at then
				table.remove(s, at)
			else
				table.insert(s, id)
			end
		else
			s = { id }
		end
		selection:set(s)
		if source.select then
			source.select(s)
		end
	end

	local function set(id: string, p: { [string]: any }, label: string)
		source.edit({ { op = "update", id = id, props = p } }, label)
	end

	local function row(r: any, _i: number): Node
		local n = r.n
		local kind = if n.comp then "component" elseif (n.t == "instance" or n.inst or string.find(n.id, "/", 1, true)) then "instance" else ""
		local screen = r.depth == 0
		local hovered = ui.use_state(false)
		local pl = PAD_L + INDENT * r.depth
		local function is_sel(): boolean
			return table.find(selection:get() or {}, n.id) ~= nil
		end
		local function in_sel(): boolean
			local s = selection:get() or {}
			for _, a in r.anc do
				if table.find(s, a) then
					return true
				end
			end
			return false
		end
		local function is_hover(): boolean
			return hovered:get() or (hover ~= nil and hover:get() == n.id)
		end
		local function name_color(): string
			if is_sel() then
				return L.accent_fg
			elseif kind == "component" then
				return L.component
			elseif kind == "instance" then
				return L.instance
			end
			return if screen then L.fg else L.muted
		end
		local function icon_color(): string
			if is_sel() then
				return L.accent
			elseif kind == "component" then
				return L.component
			elseif kind == "instance" then
				return L.instance
			end
			return L.faint
		end
		local weight = if screen or kind == "component" then 500 else 400
		local agent = agent_of(n)

		-- the lock and the eye: 13px, faint; shown on hover, pinned while set
		local function toggle(o: { label: string, icon: string, pinned: boolean, on_click: () -> () }): Node
			return ui.show(function(): boolean
				return o.pinned or is_hover()
			end, ui.button {
				label = o.label,
				w = 19,
				h = 22,
				p = 0,
				rounded = 5,
				border = 0,
				bg = "#00000000",
				color = if o.pinned then L.muted else L.faint,
				hover = { color = L.fg },
				focus = { outline = 0 },
				items = "center",
				justify = "center",
				on_click = o.on_click,
				Kit.icon(o.icon, 13),
			})
		end

		return ui.row {
			id = `layer-{n.id}`,
			role = "treeitem",
			label = n.name,
			w_full = true,
			h = ROW_H,
			items = "center",
			gap = 6,
			pr = 8,
			pl = pl,
			rounded = 7,
			opacity = if n.hidden then 0.45 else 1,
			on_hover = function(on: boolean)
				hovered:set(on)
				if hover then
					hover:set(if on then n.id else nil)
				end
			end,
			bg = function(): string
				local d = drop:get()
				if d and d.id == n.id and d.where == "in" then
					return L.accent_soft
				end
				if is_sel() then
					return L.accent_soft
				end
				if is_hover() then
					return L.field
				end
				if in_sel() then
					return L.row_in_sel
				end
				return "#00000000"
			end,
			border = 1,
			border_color = function(): string
				local d = drop:get()
				return if d and d.id == n.id and d.where == "in" then L.accent else "#00000000"
			end,
			on_click = function(e: any)
				-- (A second click on the row soon after: rename, as a double
				-- click; counted here too, inspect's clicks come one by one.)
				local now = ui.now()
				if last_click.id == n.id and now - last_click.at < 500 and not (e.shift or e.cmd) then
					last_click.id = nil
					renaming:set(n.id)
					return
				end
				last_click.id, last_click.at = n.id, now
				select(n.id, e.shift or e.cmd)
			end,
			on_double_click = function()
				renaming:set(n.id)
			end,
			on_drag = function(): any
				return { layer = n.id }
			end,
			drop_when = function(p: any): boolean
				return type(p) == "table" and p.layer ~= nil and p.layer ~= n.id
			end,
			on_drag_over = function(_p: any, e: any)
				local where = if e.local_y < 8 then "before" elseif e.local_y > ROW_H - 8 then "after" else "in"
				if where == "in" and n.t ~= "frame" and n.t ~= "instance" then
					where = if e.local_y < ROW_H / 2 then "before" else "after"
				end
				local d = drop:peek()
				if not d or d.id ~= n.id or d.where ~= where then
					drop:set({ id = n.id, where = where })
				end
			end,
			on_drag_leave = function()
				drop:set(nil)
			end,
			on_drop = function(p: any)
				local d = drop:peek()
				drop:set(nil)
				if not d or type(p) ~= "table" or not p.layer then
					return
				end
				local list = source.tree:peek()
				local kids = kids_of(list)
				if d.where == "in" then
					source.edit({ { op = "reparent", ids = { p.layer }, parent = n.id } }, "Move into")
					return
				end
				-- Before / after in the list = above / below in paint order
				-- (the list shows the topmost first).
				local parent = n.p or ""
				local sibs = {}
				for _, s in kids[parent] or {} do
					if s.id ~= p.layer then
						table.insert(sibs, s.id)
					end
				end
				local at = (table.find(sibs, n.id) :: number) - 1
				local index = if d.where == "before" then at + 1 else at
				local moved_parent = nil
				for _, s in list do
					if s.id == p.layer then
						moved_parent = s.p or ""
					end
				end
				if moved_parent == parent then
					source.edit({ { op = "reorder", id = p.layer, index = index } }, "Reorder")
				else
					source.edit({ { op = "reparent", ids = { p.layer }, parent = if parent == "" then "__null" else parent, index = index } }, "Move")
				end
			end,
			-- the drop line: 2px accent, indented to the row's icon
			ui.show(function(): boolean
				local d = drop:get()
				return d ~= nil and d.id == n.id and d.where ~= "in"
			end, ui.div {
				absolute = true,
				left = pl + 12,
				right = 0,
				h = 2,
				rounded = 1,
				bg = L.accent,
				top = function(): number
					local d = drop:get()
					return if d and d.where == "before" then -1 else ROW_H - 1
				end,
			}),
			-- the chevron
			ui.div {
				w = 12,
				h = 12,
				min_w = 12,
				shrink = 0,
				items = "center",
				justify = "center",
				color = L.faint,
				on_click = function()
					if r.has then
						open:set_key({ n.id }, not r.open)
					end
				end,
				if r.has then Kit.icon(if r.open then "chevDown" else "chev", 12) else ui.div {},
			},
			-- the type icon
			ui.div {
				w = 14,
				h = 14,
				min_w = 14,
				shrink = 0,
				items = "center",
				justify = "center",
				color = icon_color,
				Kit.icon(type_icon(n), 14),
			},
			ui.presence(function(): string
				return if renaming:get() == n.id then "edit" else "show"
			end, function(which: string): Node
				if which == "edit" then
					return ui.input {
						id = `layer-name-{n.id}`,
						label = "Layer name",
						value = function(): string
							return n.name or ""
						end,
						select_on_focus = true,
						on_commit = function(t: string)
							renaming:set(nil)
							if t ~= n.name then
								set(n.id, { name = t }, "Rename")
							end
						end,
						on_key = function(k: any): boolean?
							if k.key == "Escape" then
								renaming:set(nil)
								return true
							end
							return nil
						end,
						on_mount = function(el: any)
							el:focus()
							el:select_all()
						end,
						w_full = true,
						h = 22,
						px = 6,
						rounded = 5,
						border = 1,
						border_color = L.accent,
						bg = L.panel_solid,
						focus = { outline = 0 },
						color = L.fg,
						text_size = 12,
						weight = 500,
						font = Look.UI,
					}
				end
				return ui.text {
					n.name or "",
					text_size = 12,
					weight = function(): number
						return if is_sel() then 500 else weight
					end,
					color = name_color,
					truncate = true,
					font = Look.UI,
					w_full = true,
					min_w = 0,
				}
			end, { grow = 1, min_w = 0, items = "center" }),
			-- the agent at work: ● and the chat's title
			if agent
				then ui.row {
					gap = 4,
					items = "center",
					shrink = 0,
					ui.div { w = 6, h = 6, rounded = 3, bg = L.agent },
					ui.text { agent, text_size = 12, weight = 500, color = L.agent_fg, font = Look.UI, truncate = true, max_w = 96 },
				}
				else ui.div {},
			-- prototyping: it has states or links (tree's `proto`)
			if n.proto
				then ui.div { id = `layer-proto-{n.id}`, label = "Interactive", tooltip = "Has interactions or states", shrink = 0, w = 16, items = "center", justify = "center", color = L.accent_fg, Kit.icon("click", 12) }
				else ui.div {},
			-- the lock, then the eye
			ui.row {
				gap = 0,
				items = "center",
				shrink = 0,
				toggle({
					label = if n.lock then "Unlock" else "Lock",
					icon = if n.lock then "lock" else "unlock",
					pinned = n.lock == true,
					on_click = function()
						set(n.id, { locked = if n.lock then "__null" else true }, if n.lock then "Unlock" else "Lock")
					end,
				}),
				toggle({
					label = if n.hidden then "Show" else "Hide",
					icon = if n.hidden then "eyeOff" else "eye",
					pinned = n.hidden == true,
					on_click = function()
						set(n.id, { enabled = if n.hidden then "__null" else false }, if n.hidden then "Show" else "Hide")
					end,
				}),
			},
		}
	end

	-- Find: a 28px field over the tree; rows whose name holds it, with their
	-- parents' rows open.
	local find_row = ui.show(function(): boolean
		return props.find ~= nil and props.find:get() == true
	end, ui.div {
		w_full = true,
		pb = 6,
		ui.input {
			id = "layers-find",
			label = "Find layers",
			value = filter,
			placeholder = "Find…",
			placeholder_color = L.faint,
			on_mount = function(el: any)
				el:focus()
			end,
			on_key = function(k: any): boolean?
				if k.key == "Escape" then
					filter:set("")
					if props.find then
						props.find:set(false)
					end
					return true
				end
				return nil
			end,
			w_full = true,
			h = 28,
			px = 8,
			rounded = 8,
			border = 0,
			bg = L.field,
			focus = { outline = 1, outline_color = L.accent, bg = L.field_active },
			text_size = 12,
			font = Look.UI,
			color = L.fg,
		},
	})
	-- The empty state: the layers icon, "Empty canvas", a line.
	local empty = ui.show(function(): boolean
		return #(source.tree:get() or {}) == 0
	end, ui.column {
		id = "layers-empty",
		w_full = true,
		shrink = 0,
		items = "center",
		gap = 6,
		px = 12,
		py = 24,
		ui.div { color = L.faint, mb = 2, Kit.icon("layers", 20) },
		ui.text { "Empty canvas", text_size = 13, weight = 500, color = L.fg, font = Look.UI },
		ui.text {
			"Draw something, or ask an agent in the chat. Frames and layers show up here.",
			text_size = 12,
			color = L.muted,
			font = Look.UI,
			align = "center",
			wrap = true,
			w_full = true,
		},
	})
	return ui.column {
		id = "layers",
		w_full = true,
		grow = 1,
		min_h = 0,
		find_row,
		empty,
		ui.list {
			id = "layers-list",
			w_full = true,
			grow = 1,
			min_h = 0,
			pb = 8,
			data = rows,
			height = ROW_H + ROW_GAP,
			key = function(r: any): string
				return `{r.id}:{r.n.name}:{r.open}:{r.n.hidden}:{r.n.lock}:{r.depth}:{r.has}:{r.n.wip}:{r.n.by}:{r.n.proto}`
			end,
			row = function(r: any, i: number): Node
				return ui.component(function(): Node
					return ui.div { w_full = true, h = ROW_H + ROW_GAP, row(r, i) }
				end)({})
			end,
		},
	}
end

return M
