--!strict
-- Design (pure): the window half (pure/CONTRACT.md). The service
-- (service.luau) owns every Design; this draws them natively on a zgx canvas
-- in a panel tab (tab/canvas.luau) and sends the person's edits back.
--
--   - the panel home's Design row (key D): New design and the Designs
--     touched most recently, agents' too;
--   - the Design tab: the Canvas, from the service's scene;
--   - screenshots for agents (`render` events), answered with the Canvas's
--     own drawing through `ui.render_canvas`, even with no tab open.

-- The hand cursor on every clickable control: before any UI is built.
local ui = require("./tab/pointer").ui

local zeron = require("./zeron")("design-pure")
local PanelHome = require("@ds/panel_home")
local Text = require("@ds/text")
local Shell = require("./tab/shell")
local ServiceSource = require("./tab/service_source")
local Render = require("./tab/render")
local Guard = require("./tab/guard")
local Look = require("./tab/look")
local Kit = require("./tab/kit")
local States = require("./tab/states")
local Toast = require("./tab/toast")

local KIND = "design"
local service = Guard.service(zeron.service())

Render.register(zeron)
-- Fonts the service fetched, and pictures' bytes: loaded once for the window.
local Assets = require("./tab/assets")
Assets.register(zeron)
-- pen.dev's interface faces, bundled (fonts/, SIL OFL 1.1): Rubik 400/500/600
-- for the editor, Roboto Mono for the zoom level. Loaded once for every window.
for _, file in { "Rubik-Regular.ttf", "Rubik-Medium.ttf", "Rubik-SemiBold.ttf", "RobotoMono-Regular.ttf" } do
	local ok, promise = pcall(ui.load_font, `fonts/{file}`)
	if ok and promise then
		promise:after(function() end, function(why: any)
			print(`design-pure: font {file}: {why}`)
		end)
	end
end

-- What the editor keeps between sessions, plugin-wide (as pen.dev keeps it):
-- the left panel shown or hidden, its width. zeron.store is there before the
-- first build, so a reopened Design shows the kept layout from its first frame.
local kept_ui = zeron.store("ui", {})
local ui_prefs = {
	get = function(key: string): any
		local t = kept_ui:peek()
		return if type(t) == "table" then t[key] else nil
	end,
	set = function(key: string, value: any)
		local t = kept_ui:peek()
		local copy = if type(t) == "table" then table.clone(t) else {}
		copy[key] = value
		kept_ui:set(copy)
	end,
}

-- The board follows Zeron's appearance.
local dark = ui.computed(function(): boolean
	return zeron.context("appearance") == "dark"
end)

local function chat_title(chat: string?): string?
	-- (An agent with no chat, as an MCP client outside Zeron: "Agent".)
	if not chat or chat == "" then
		return "Agent"
	end
	local id = string.gsub(chat, "^chat:", "")
	local s = zeron.sessions()[id]
	return if type(s) == "table" and type(s.title) == "string" and s.title ~= "" then s.title else "Agent"
end

-- One source per Design while a tab shows it, and RELEASE_MS after the
-- last one goes (a tab switched away and back keeps it). All Designs share
-- this window's one plugin VM (32 MB with what its states hold), so one
-- that no tab shows lets its scene, index and layers go.
local RELEASE_MS = 30000
local sources: { [string]: { source: any, uses: number } } = {}

-- What a source says (its calls' failures, "scene: …", "edit: …"), as a
-- toast in the editor: a headline by what failed, the reason under it.
local FAILED: { [string]: string } = {
	scene = "Couldn't load the Design",
	edit = "Couldn't make that change",
	tree = "Couldn't read the layers",
	node = "Couldn't read the layer",
	tokens = "Couldn't read the variables",
	copy = "Couldn't copy",
	view_theme = "Couldn't switch the theme",
}
local function editor_toast(msg: string)
	local what, why = string.match(msg, "^([%w_]+): (.+)$")
	local title = if what then FAILED[what] else nil
	if title then
		Toast.show { tone = "danger", title = title, body = why }
	else
		Toast.show { title = msg }
	end
end

local function source_of(did: string, name: string?): (any, any)
	local held = sources[did]
	if not held then
		local s: any
		s = ServiceSource(zeron, did, {
			dark = dark,
			name = name,
			chat_title = chat_title,
			log = function(msg: string)
				-- (A Design that didn't open, or was deleted, shows a state, not a toast.)
				local st = if s then s.status:peek() else nil
				if type(st) == "string" and (string.sub(st, 1, 5) == "error" or st == "deleted") then
					return
				end
				editor_toast(msg)
			end,
		})
		held = { source = s, uses = 0 }
		sources[did] = held
	end
	return held.source, held
end
-- A tab shows `did`'s source while it is built.
local function hold(did: string, held: any)
	held.uses += 1
	ui.on_cleanup(function()
		held.uses -= 1
		if held.uses > 0 then
			return
		end
		ui.after(RELEASE_MS, function()
			if held.uses <= 0 and sources[did] == held then
				sources[did] = nil
				held.source.dispose()
			end
		end)
	end)
end

-- Dev only: the editor in a window of its own, by a command (tab/dev.luau).
require("./tab/dev").register(zeron, Shell, source_of, dark)

-- (Below: a .zdesign from disk, opened in `panel`.)
local open_file: (panel: any, done: (() -> ())?) -> ()
-- (Below: the "All designs" tab, opened in `panel`.)
local open_gallery: (panel: any?) -> ()

zeron.tab(KIND, function(tab: any): Node
	local did = tab.data and tab.data.did
	if type(did) ~= "string" then
		return ui.div { Text { "No Design", tone = "secondary" } }
	end
	local session = zeron.context("session")
	-- (The chat's Design tabs, for agents' targeting.)
	if session and session.id then
		service:call("tabs", { chat = session.id, dids = { did } }):after(function() end, function() end)
	end
	local source, held = source_of(did, tab.title)
	hold(did, held)
	local name = if type(tab.title) == "string" and tab.title ~= "" then tab.title else "Design"
	local panel = zeron.context("panel")
	-- loading, couldn't open, or the editor
	local function phase(): string
		local s = source.status:get()
		if s == "loading" then
			return "loading"
		elseif type(s) == "string" and string.sub(s, 1, 5) == "error" then
			return "error"
		elseif s == "deleted" then
			return "deleted"
		end
		return "ready"
	end
	return ui.column {
		id = `design-tab-{did}`,
		w_full = true,
		h_full = true,
		bg = function(): string
			return Look.of(dark:get()).canvas
		end,
		-- (Built again as Zeron's appearance flips: light or dark.)
		ui.presence(function(): string
			return if dark:get() then "dark" else "light"
		end, function(theme: string): Node
			local L = Look.of(theme == "dark")
			return ui.presence(phase, function(which: string): Node
				if which == "loading" then
					return States.Loading(L, `Opening {name}…`)
				elseif which == "deleted" then
					-- (Plugins can't close a panel tab: say how.)
					return States.Deleted(L, {
						name = name,
						other = if panel then function()
							open_gallery(panel)
						end else nil,
					})
				elseif which == "error" then
					local s = tostring(source.status:peek())
					local why = string.gsub(string.gsub(s, "^error:?%s*", ""), "%s+$", "")
					local body = if why == "" or string.find(why, "not_found", 1, true) or string.find(why, "missing", 1, true)
						then "The file is missing or damaged. Your other Designs aren't affected."
						else `{why}. Your other Designs aren't affected.`
					return States.Error(L, {
						title = `Couldn't open {name}`,
						body = body,
						retry = function()
							source.status:set("loading")
							source.reload()
						end,
						other = if panel then function()
							open_file(panel)
						end else nil,
					})
				end
				return Shell.Shell { source = source, id = did, dark = theme == "dark", prefs = ui_prefs }
			end, { w_full = true, h_full = true })
		end, { w_full = true, h_full = true }),
	}
end)

-- Opened in `panel`, the panel the picker was built in. (Never
-- `zeron.need` here: outside a build it raises a table when the window
-- shows no session, which stopped the plugin as "table: …".)
local function open(did: string, name: string?, panel: any?)
	local p = panel or zeron.context("panel")
	if not p then
		zeron.toast("Design: open a chat to open a Design in its panel")
		return
	end
	p.open_tab { kind = KIND, title = name or "Design", icon = "palette", data = { key = did, did = did } }
end

-- A .zdesign from disk: imported, opened in `panel`, then its pictures
-- named by a path. (From the panel home, or an editor that couldn't open.)
open_file = function(panel: any, done: (() -> ())?)
	ui.open_files({ title = "Open design" } :: any):after(function(files: any)
		local f = if type(files) == "table" then files[1] else nil
		if not f then
			return
		end
		ui.read_file(f):after(function(text: string)
			local name = if type(f) == "table" and f.name then string.gsub(f.name, "%.zdesign$", "") else nil
			service:call("import", { text = text, name = name, source = if type(f) == "table" then f.path else nil }):after(function(made: any)
				if type(made) ~= "table" or not made.did then
					return
				end
				open(made.did, made.name, panel)
				if done then
					done()
				end
				Assets.put_pictures(zeron, made.did, made.images or {}, function(msg: string)
					if msg ~= "" then
						zeron.toast(`Design: {msg}`)
					end
				end)
			end, function(why: any)
				zeron.toast(`Design: {why}`)
			end)
		end, function(why: any)
			zeron.toast(`Design: {why}`)
		end)
	end, function() end)
end

-- Agents at work, by Design: the service says when a snippet starts and
-- ends (`working`), and the Recent rows show "● {chat}" meanwhile.
local working = ui.state("design-pure.working", {} :: { [string]: string })
pcall(function()
	service:on("working", function(e: any)
		if type(e) ~= "table" or type(e.did) ~= "string" then
			return
		end
		local now = table.clone(working:peek())
		now[e.did] = if e.on then (chat_title(e.chat) or "Agent") else nil
		working:set(now)
	end)
end)

-- ---------------------------------------------------------------------------
-- The panel home's Designs: a part of its own just above the session's side
-- chats (before `#panel-home-lanes`, the column of ports, side chats and
-- subagents), folded at first, drawn with the same pieces Zeron draws those with (ds/session_row: the
-- section's title, folding; a row each, its time in the corner; "Show N
-- more"), so it reads as one more of the home's lists. A click on a row opens
-- that Design in the panel; + New makes one and opens it. Its title's
-- secondary click: New design, Open design… (a .zdesign) and the dev imports.

local SessionRow = require("@ds/session_row")
local Button = require("@ds/button")
local Icon = require("@ds/icon")
local ContextMenu = require("@ds/context_menu")
local IconButton = require("@ds/icon_button").IconButton
local control = require("@ds/control")

-- A lane's row (ds/panel_home LANE_H): the row's slot and the list's gap.
local ROW_H = 32
local ROW_GAP = ROW_H - SessionRow.SLOT
-- How many show before "Show N more" (the side chats' own count).
local FIRST = 5

-- The Designs, one list for the window, every section reading it. Asked for
-- when a section first builds; again when the service says the list changed
-- (`designs`: new, renamed, deleted, imported), when an agent's snippet ends,
-- and a while after edits (their `updated`), only while a section shows.
-- Asks never overlap: one asked meanwhile runs once after.
local designs = ui.state("design-pure.designs", nil :: { any }?)
local asking, ask_again = false, false
local showing = 0
local stale = true
local function refresh()
	if showing <= 0 then
		stale = true
		return
	end
	if asking then
		ask_again = true
		return
	end
	asking, stale = true, false
	local function settle()
		asking = false
		if ask_again then
			ask_again = false
			refresh()
		end
	end
	service:call("designs", {}):after(function(r: any)
		designs:set(if type(r) == "table" and type(r.designs) == "table" then r.designs else {})
		settle()
	end, function()
		if designs:peek() == nil then
			designs:set({})
		end
		settle()
	end)
end
local EDITS_MS = 4000
local edits_due = false
pcall(function()
	service:on("designs", function()
		refresh()
	end)
	service:on("working", function(e: any)
		if type(e) == "table" and not e.on then
			refresh()
		end
	end)
	service:on("changed", function()
		if edits_due then
			return
		end
		edits_due = true
		ui.after(EDITS_MS, function()
			edits_due = false
			refresh()
		end)
	end)
end)

-- Make a Design and open it in `panel`.
local function new_design(panel: any?)
	service:call("new", {}):after(function(made: any)
		if type(made) == "table" and made.did then
			open(made.did, made.name, panel)
		end
	end, function(why: any)
		zeron.toast(`Design: {why}`)
	end)
end

-- The dev-only imports (files under dev/ that aren't shipped): each makes a
-- Design and opens it.
local function dev_entries(panel: any?): { any }
	local out = {}
	local function import(label: string, text: string, name: string)
		table.insert(out, {
			label = label,
			icon = "plus",
			on_select = function()
				service:call("import", { text = text, name = name }):after(function(made: any)
					if type(made) == "table" and made.did then
						open(made.did, made.name, panel)
					end
				end, function(why: any)
					zeron.toast(`Design: {why}`)
				end)
			end,
		})
	end
	local has_pulse, pulse_text = pcall(require, "./dev/pulse_zdesign")
	if has_pulse then
		import("Import Pulse (dev)", pulse_text :: any, "Pulse Dashboard (dev)")
	end
	local has_extra, extra = pcall(require, "./dev/extra_zdesign")
	if has_extra then
		import(`Import {(extra :: any).name}`, (extra :: any).text, (extra :: any).name)
	end
	local has_parity, parity = pcall(require, "./dev/parity_zdesign")
	if has_parity then
		import(`Import {(parity :: any).name}`, (parity :: any).text, (parity :: any).name)
	end
	return out
end

-- A design as a session row reads it: its name, when it was last touched,
-- and "working" while an agent's snippet runs in it.
local function as_row(d: any, at_work: { [string]: string }): any
	local t = math.max(tonumber(d.updated) or 0, tonumber(d.opened) or 0)
	return {
		id = d.did,
		title = if type(d.name) == "string" and d.name ~= "" then d.name else "Design",
		status = if at_work[d.did] then "working" else nil,
		time = if t > 0 then t else nil,
	}
end

-- A Design's menu (a secondary click on its row or card, or its ⋯ under
-- the pointer): open it, rename it in place (`renaming` names the one being
-- renamed), delete it. Deleting can't be undone (the service drops it and
-- its history), so the menu asks once more. `d` is `{ id, title }`.
local function design_menu(d: any, panel: any?, renaming: any): { any }
	return {
		{ label = "Open", icon = "palette", on_select = function()
			open(d.id, d.title, panel)
		end },
		{ label = "Rename", icon = "pen", on_select = function()
			renaming:set(d.id)
		end },
		{ separator = true },
		{
			label = "Delete",
			icon = "trash-bin-minimalistic",
			danger = true,
			confirm = "Delete? Can't be undone",
			on_select = function()
				service:call("delete", { did = d.id }):after(function()
					zeron.toast(`Design: deleted {d.title}`)
				end, function(why: any)
					zeron.toast(`Design: {why}`)
				end)
			end,
		},
	}
end

local function rename_design(did: string, name: string)
	service:call("rename", { did = did, name = string.sub(name, 1, 200) }):after(function() end, function(why: any)
		zeron.toast(`Design: {why}`)
	end)
end

-- A Design's name, renamed in place: a field over its title, its text
-- selected; ↩ or leaving it keeps a changed name, Esc keeps the old (as the
-- sidebar renames a session in its row). `lead`: the palette glyph before
-- it (a row's), else none (a card's).
local function RenameField(d: any, renaming: any, lead: boolean): Node
	local draft = ui.use_state(d.title)
	local done_once = false
	local function done(keep: boolean)
		if done_once then
			return
		end
		done_once = true
		renaming:set(nil)
		local v = string.match(draft:peek(), "^%s*(.-)%s*$") or ""
		if keep and v ~= "" and v ~= d.title then
			rename_design(d.id, v)
		end
	end
	return ui.row {
		class = "dp-design-rename",
		w_full = true,
		h = SessionRow.SLOT,
		pl = if lead then (SessionRow.SLOT - 14) / 2 else "$space.2",
		pr = "$space.2",
		gap = (SessionRow.SLOT - 14) / 2,
		items = "center",
		rounded = "$radius.md",
		bg = "$hover",
		if lead then ui.div { shrink = 0, color = "$text.secondary", Icon { name = "palette", size = 14 } } else nil,
		ui.input {
			id = "dp-design-rename-field",
			value = draft,
			label = "Design name",
			placeholder = "Design name",
			grow = 1,
			min_w = 0,
			h = 20,
			px = 0,
			border = 0,
			bg = "#00000000",
			focus = { border = 0, outline = 0 },
			text_size = "$font.size.md",
			weight = "$font.weight.medium",
			color = "$text.primary",
			select_on_focus = true,
			on_key = function(e: any): boolean
				if e.key == "Enter" then
					done(true)
					return true
				elseif e.key == "Escape" then
					done(false)
					return true
				end
				return false
			end,
			on_blur = function()
				done(true)
			end,
			on_mount = function(el: any)
				local tries = 0
				local function take()
					if done_once or el:focus() then
						return
					end
					tries += 1
					if tries < 10 then
						ui.after(16, take)
					end
				end
				take()
			end,
		},
	}
end

-- Every Design as a gallery (gallery.luau): the sidebar's "Designs" page,
-- and the same as a tab in a chat's panel ("All designs" in the panel
-- home's list: a plugin can't open its page, zeron.open goes only to a
-- chat, home or Settings). Each shows while built: the list kept fresh
-- meanwhile, as the panel's.
local GALLERY = "design-gallery"
local Gallery = require("./gallery")({
	zeron = zeron,
	service = service,
	designs = designs,
	working = working,
	prefs = ui_prefs,
	open = open,
	open_file = open_file,
	new_design = new_design,
	design_menu = design_menu,
	RenameField = RenameField,
	watch = function(): () -> ()
		showing += 1
		if stale or designs:peek() == nil then
			refresh()
		end
		return function()
			showing -= 1
		end
	end,
})
open_gallery = function(panel: any?)
	local p = panel or zeron.context("panel")
	if not p then
		zeron.toast("Design: open a chat to see all designs in its panel")
		return
	end
	p.open_tab { kind = GALLERY, title = "All designs", icon = "gallery", data = { key = "all-designs" } }
end
zeron.tab(GALLERY, function(_tab: any): Node
	return Gallery { panel = zeron.context("panel"), compact = true }
end)
zeron.page {
	id = "designs",
	title = "Designs",
	icon = "palette",
	build = function(_page: any): Node
		-- (Its panel: the page's own, where a Design opens as a tab.)
		return Gallery { panel = zeron.context("panel") }
	end,
}

local function Designs(props: { panel: any }): Node
	local panel = props.panel
	showing += 1
	ui.on_cleanup(function()
		showing -= 1
	end)
	if stale or designs:peek() == nil then
		refresh()
	end
	-- Folded or not (folded at first), and shown whole or not: kept in
	-- zeron.store("ui"), as the editor's layout is.
	local open_now = ui.use_state(ui_prefs.get("designs_open") == true)
	local whole = ui.use_state(ui_prefs.get("designs_whole") == true)
	local function toggle()
		local v = not open_now:peek()
		open_now:set(v)
		ui_prefs.set("designs_open", v)
	end
	local function set_whole(v: boolean)
		whole:set(v)
		ui_prefs.set("designs_whole", v)
	end
	local all = ui.computed(function(): { any }
		return designs:get() or {}
	end)
	-- The rows shown: the first few, those at work past them, or all.
	local shown = ui.computed(function(): { rows: { any }, hidden: number }
		local list, at_work = all:get(), working:get()
		local out, n = {}, 0
		local every = whole:get() or #list <= FIRST
		for i, d in list do
			if every or i <= FIRST or at_work[d.did] then
				table.insert(out, as_row(d, at_work))
			else
				n += 1
			end
		end
		return { rows = out, hidden = n }
	end)
	local rows = ui.computed(function(): { any }
		return shown:get().rows
	end)
	local hidden = ui.computed(function(): number
		return shown:get().hidden
	end)
	local function paged(): boolean
		return hidden:get() > 0 or (whole:get() and #all:get() > FIRST)
	end
	local new_button = Button {
		id = "dp-designs-new",
		tone = "ghost",
		size = "xs",
		label = "New design",
		tooltip = "New design (D)",
		on_click = function()
			new_design(panel)
		end,
		Icon { name = "plus", size = 14 },
		ui.text { "New" },
	}
	-- The Design renamed in its row, while it is (one at a time).
	local renaming = ui.use_state(nil :: string?)
	local function row_menu(d: any): { any }
		return design_menu(d, panel, renaming)
	end
	local function rename_field(d: any): Node
		return RenameField(d, renaming, true)
	end
	local function row(_first: any, _index: any, now: any): Node
		local function cur(): any
			return now:get()
		end
		-- Its menu, opened by a secondary click or by its ⋯ (where the ⋯ is).
		local open_at: ((x: number, y: number) -> boolean)? = nil
		local dots_ref = ui.ref()
		local dots = IconButton {
			ref = dots_ref,
			icon = "more-horizontal",
			label = "Design actions",
			tooltip = "More",
			size = "sm",
			tone = "quiet",
			on_click = function()
				local el, at = dots_ref:peek(), open_at
				if not (el and at) then
					return
				end
				local menu_w = (ui.theme.get("zeron.menu.width") :: number?) or 232
				at((el.x or 0) + (el.width or 0) - menu_w, (el.y or 0) + (el.height or 0) + 4)
			end,
		}
		local plain = SessionRow.Row {
			class = "dp-design-row",
			-- (Its title in the primary ink at rest, as side chats read.)
			primary = true,
			compact = function(): boolean
				return true
			end,
			cur = cur,
			name = function(): string
				return `Open design {cur().title}`
			end,
			lead = ui.div { color = "$text.secondary", Icon { name = "palette", size = 14 } },
			harness = function(): boolean
				return true
			end,
			gap = ROW_GAP,
			action = dots,
			on_click = function()
				local d = now:peek()
				open(d.id, d.title, panel)
			end,
		}
		return ui.div {
			w_full = true,
			h = ROW_H,
			ui.presence(function(): string
				return if renaming:get() == cur().id then "rename" else "row"
			end, function(which: string): Node
				if which == "rename" then
					return rename_field(now:peek())
				end
				return ContextMenu {
					label = "Design actions",
					ring = "$radius.md",
					w_full = true,
					hook = function(at: (x: number, y: number) -> boolean)
						open_at = at
					end,
					items = function(): { any }?
						return row_menu(now:peek())
					end,
					plain,
				}
			end),
		}
	end
	local part = ui.column {
		id = "dp-designs",
		class = "panel-home-fold",
		w_full = true,
		gap = "$zeron.list.gap",
		-- Its title, as ds/session_row's Section draws one (24 high, quiet
		-- small words, brighter under the pointer, a click folds it; no
		-- arrow, as side chats' and subagents' have none), + New at its end.
		ui.row {
			id = "dp-designs-head",
			w_full = true,
			h = SessionRow.TITLE,
			pl = "$space.2",
			pr = "$space.1",
			gap = "$space.1",
			items = "center",
			color = "$text.tertiary",
			cursor = "pointer",
			hover = { color = "$text.secondary" },
			role = "button",
			label = "Designs",
			expanded = function(): boolean
				return open_now:get()
			end,
			focusable = true,
			focus = control.ring,
			rounded = PanelHome.inner(4),
			on_click = toggle,
			on_key = function(e: any): boolean?
				if (e.key == "Enter" or e.key == " ") and not (e.cmd or e.ctrl or e.alt) then
					toggle()
					return true
				end
				return nil
			end,
			ui.text { "Designs", grow = 1, min_w = 0, truncate = true, text_size = "$font.size.xs", weight = "$font.weight.medium" },
			new_button,
		},
		SessionRow.Fold {
			open = function(): boolean
				return open_now:get()
			end,
			h = function(): number
				return #rows:get() * ROW_H + (if paged() then ROW_H else 0) + ROW_H
			end,
			body = ui.column {
				w_full = true,
				gap = 0,
				ui.list {
					id = "dp-designs-list",
					data = rows,
					key = function(r: any): string
						return r.id
					end,
					row = row,
					height = ROW_H,
					w_full = true,
					-- (The home scrolls, never this list: only the rows in view are built.)
					virtualize = "ancestor",
				},
				ui.show(paged, ui.div {
					w_full = true,
					h = ROW_H,
					SessionRow.Pager {
						id = "dp-designs-pager",
						whole = function(): boolean
							return whole:get()
						end,
						more = function(): number
							return hidden:get()
						end,
						on_click = function()
							set_whole(not whole:peek())
						end,
					},
				}),
				-- All of them, as a gallery: in the panel, as a tab (a plugin
				-- can't open its sidebar page: zeron.open goes to a chat, home
				-- or Settings only).
				ui.div {
					w_full = true,
					h = ROW_H,
					SessionRow.Row {
						class = "dp-designs-all",
						compact = function(): boolean
							return true
						end,
						cur = function(): any
							return { id = "dp-all", title = "All designs" }
						end,
						name = function(): string
							return "All designs"
						end,
						lead = ui.div { color = "$text.tertiary", Icon { name = "gallery", size = 14 } },
						harness = function(): boolean
							return true
						end,
						gap = ROW_GAP,
						on_click = function()
							open_gallery(panel)
						end,
					},
				},
			},
		},
	}
	return ContextMenu {
		label = "Designs",
		w_full = true,
		items = function(): { any }?
			local entries: { any } = {
				{ label = "New design", icon = "plus", shortcut = "D", on_select = function()
					new_design(panel)
				end },
				{ label = "Open design…", icon = "folder", on_select = function()
					open_file(panel)
				end },
			}
			local dev = dev_entries(panel)
			if #dev > 0 then
				table.insert(entries, { separator = true })
				for _, e in dev do
					table.insert(entries, e)
				end
			end
			return entries
		end,
		part,
	}
end

zeron.place {
	at = "#panel-home-lanes",
	before = function(): Node
		local session = zeron.context("session")
		local panel = zeron.context("panel")
		if not session or not panel then
			return ui.div {}
		end
		-- D on the home makes a Design, as S makes a side chat (the home
		-- passes plugins the letters it doesn't take).
		local key = zeron.live("panel_key")
		local now = key()
		local seen = if type(now) == "table" then now.n else nil
		ui.effect(function()
			local k = key()
			if type(k) ~= "table" or k.n == seen then
				return
			end
			seen = k.n
			if string.upper(tostring(k.key or "")) == "D" then
				ui.after(0, function()
					new_design(panel)
				end)
			end
		end)
		return Designs { panel = panel }
	end,
}
