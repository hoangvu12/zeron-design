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
				-- (A Design that didn't open shows States.Error, not a toast.)
				local st = if s then s.status:peek() else nil
				if type(st) == "string" and string.sub(st, 1, 5) == "error" then
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

-- "Edited 2 min ago", "Edited 1 h ago", "Yesterday", "Nov 11": from the
-- `designs` reply's `updated` (os.time seconds).
local function edited(t: any): string
	if type(t) ~= "number" or t <= 0 then
		return ""
	end
	local d = math.max(0, os.time() - t)
	if d < 60 then
		return "Edited just now"
	elseif d < 3600 then
		return `Edited {math.floor(d / 60)} min ago`
	elseif d < 86400 then
		return `Edited {math.floor(d / 3600)} h ago`
	elseif d < 2 * 86400 then
		return "Yesterday"
	end
	local ok, s = pcall(function(): string
		return `{os.date("%b", t)} {tonumber(os.date("%d", t))}`
	end)
	return if ok then s else `{math.floor(d / 86400)} days ago`
end

-- The picker's rows, in the redesign's metrics (Board · Home and states):
-- 32 high (40 a Recent row), r7, the content 36 in so it lines up under the
-- Design row's label; hover in the field grey.
local function pick_row(L: any, o: { id: string, icon: string, label: string, accent: boolean?, meta: string?, on_click: () -> () }): Node
	return ui.button {
		id = o.id,
		label = o.label,
		w_full = true,
		h = 32,
		pl = 36,
		pr = 10,
		gap = 10,
		rounded = 7,
		border = 0,
		items = "center",
		bg = "#00000000",
		hover = { bg = L.field },
		focus = { outline = 0 },
		on_click = o.on_click,
		ui.div { shrink = 0, color = if o.accent then L.accent else L.muted, Kit.icon(o.icon, 15) },
		ui.text { o.label, text_size = 13, weight = if o.accent then 500 else 400, color = if o.accent then L.accent_fg else L.fg, grow = 1, min_w = 0, truncate = true },
		if o.meta then ui.text { o.meta, text_size = 12, color = L.faint, shrink = 0 } else ui.div {},
	}
end

local function thumb(L: any): Node
	return ui.row {
		w = 40,
		h = 28,
		shrink = 0,
		p = 5,
		gap = 3,
		rounded = 5,
		bg = L.field,
		ui.div { grow = 1, basis = 0, h_full = true, rounded = 2, bg = L.faint, opacity = 0.35 },
		ui.div { grow = 1, basis = 0, h_full = true, rounded = 2, bg = L.faint, opacity = 0.35 },
	}
end

local function recent_row(L: any, r: any, i: number, on_click: () -> ()): Node
	return ui.button {
		id = `dp-recent-{i}`,
		label = r.name or "Design",
		w_full = true,
		h = 40,
		pl = 36,
		pr = 10,
		gap = 10,
		rounded = 7,
		border = 0,
		items = "center",
		bg = "#00000000",
		hover = { bg = L.field },
		focus = { outline = 0 },
		on_click = on_click,
		thumb(L),
		ui.column {
			grow = 1,
			min_w = 0,
			gap = 2,
			ui.text { r.name or "Design", text_size = 13, color = L.fg, truncate = true, w_full = true },
			ui.text { edited(r.updated), text_size = 12, color = L.faint, truncate = true, w_full = true },
		},
		ui.show(function(): boolean
			return working:get()[r.did] ~= nil
		end, ui.row {
			shrink = 0,
			gap = 4,
			items = "center",
			ui.div { w = 6, h = 6, rounded = 3, bg = L.agent },
			ui.text {
				function(): string
					return working:get()[r.did] or ""
				end,
				text_size = 12,
				weight = 500,
				color = L.agent_fg,
			},
		}),
	}
end

local function skeleton(L: any, w: number): Node
	return ui.row {
		w_full = true,
		h = 40,
		pl = 36,
		pr = 10,
		gap = 10,
		items = "center",
		opacity = ui.loop { from = 0.55, to = 1, duration = 900 },
		ui.div { w = 40, h = 28, shrink = 0, rounded = 5, bg = L.field },
		ui.column {
			grow = 1,
			gap = 6,
			ui.div { w = w, h = 8, rounded = 4, bg = L.field_active },
			ui.div { w = 60, h = 6, rounded = 3, bg = L.field },
		},
	}
end

-- The picker: what the Design row opens under itself.
local function Picker(props: { done: () -> (), panel: any? }): Node
	local function open_here(did: string, name: string?)
		open(did, name, props.panel)
	end
	local recent = ui.use_state(nil :: { any }?)
	service:call("designs", {}):after(function(r: any)
		recent:set(if type(r) == "table" and type(r.designs) == "table" then r.designs else {})
	end, function()
		recent:set({})
	end)
	local function new()
		service:call("new", {}):after(function(made: any)
			if type(made) == "table" and made.did then
				open_here(made.did, made.name)
			end
			props.done()
		end, function(why: any)
			zeron.toast(`Design: {why}`)
		end)
	end
	-- Dev only: a Design with a picture stored in zeron.db, made as an
	-- import would (a paint naming a path, then its bytes by `image_put`).
	local has_picture, pictures = pcall(require, "./dev/test_picture")
	local function picture_design()
		service:call("new", { name = "Picture (dev)" }):after(function(made: any)
			local did = made.did
			local node = { type = "frame", name = "Card", width = 320, height = 240, fill = "#FFFFFF", cornerRadius = 16, layout = "vertical", padding = 16, gap = 12, children = {
				{ type = "rectangle", name = "Photo", width = "fill_container", height = 144, cornerRadius = 12, fill = { type = "image", url = "images/demo.png", mode = "cover" } },
				{ type = "text", name = "Caption", content = "A picture from zeron.db", fontSize = 16, fill = "#18181B" },
			} }
			service:call("edit", { did = did, ops = { { op = "insert", node = node, at = { x = 0, y = 0 } } }, label = "Picture card" }):after(function()
				service:call("image_put", { did = did, url = "images/demo.png", base64 = (pictures :: any)["p1-demo"] }):after(function(r: any)
					zeron.toast(`Design: stored {r and r.key}`)
					open_here(did, made.name)
					props.done()
				end, function(why: any)
					zeron.toast(`Design: image_put {why}`)
				end)
			end, function(why: any)
				zeron.toast(`Design: {why}`)
			end)
		end, function(why: any)
			zeron.toast(`Design: {why}`)
		end)
	end
	local has_pulse, pulse_text = pcall(require, "./dev/pulse_zdesign")
	local function import_pulse()
		service:call("import", { text = pulse_text, name = "Pulse Dashboard (dev)" }):after(function(made: any)
			if type(made) == "table" and made.did then
				open_here(made.did, made.name)
			end
			props.done()
		end, function(why: any)
			zeron.toast(`Design: {why}`)
		end)
	end
	-- Dev only: another bundled Design (dev/extra_zdesign.luau, not shipped).
	local has_extra, extra = pcall(require, "./dev/extra_zdesign")
	-- Dev only: the pen.dev parity Design (dev/parity_zdesign.luau, not shipped).
	local has_parity, parity = pcall(require, "./dev/parity_zdesign")
	local function import_parity()
		service:call("import", { text = parity.text, name = parity.name }):after(function(made: any)
			if type(made) == "table" and made.did then
				open_here(made.did, made.name)
			end
			props.done()
		end, function(why: any)
			zeron.toast(`Design: {why}`)
		end)
	end
	local function import_extra()
		service:call("import", { text = extra.text, name = extra.name }):after(function(made: any)
			if type(made) == "table" and made.did then
				open_here(made.did, made.name)
			end
			props.done()
		end, function(why: any)
			zeron.toast(`Design: {why}`)
		end)
	end
	-- The Recent list: skeleton rows while it loads, a line when it's empty.
	local function recents(L: any): Node
		return ui.presence(function(): string
			local r = recent:get()
			return if r == nil then "loading" elseif #r == 0 then "empty" else "list"
		end, function(which: string): Node
			if which == "loading" then
				return ui.column { w_full = true, gap = 2, skeleton(L, 150), skeleton(L, 110), skeleton(L, 170) }
			elseif which == "empty" then
				return ui.div {
					w_full = true,
					pt = 4,
					pr = 10,
					pb = 10,
					pl = 36,
					ui.text { "Designs you or your agents open show up here.", text_size = 12, color = L.faint, wrap = true, w_full = true },
				}
			end
			return ui.each(ui.computed(function(): { any }
				local r = recent:get() or {}
				local top = {}
				for i = 1, math.min(#r, 8) do
					top[i] = r[i]
				end
				return top
			end), function(r: any, i: number): Node
				return recent_row(L, r, i, function()
					open_here(r.did, r.name)
					props.done()
				end)
			end, {
				key = function(r: any): string
					return r.did
				end,
				w_full = true,
				gap = 2,
			})
		end, { w_full = true })
	end
	return ui.column {
		id = "dp-picker",
		w_full = true,
		-- (Built again as Zeron's appearance flips.)
		ui.presence(function(): string
			return if dark:get() then "dark" else "light"
		end, function(theme: string): Node
			local L = Look.of(theme == "dark")
			return ui.column {
				w_full = true,
				gap = 2,
				pick_row(L, { id = "dp-new", icon = "plus", label = "New design", accent = true, on_click = new }),
				pick_row(L, {
					id = "dp-open-file",
					icon = "folder",
					label = "Open design…",
					meta = ".zdesign",
					on_click = function()
						open_file(props.panel, props.done)
					end,
				}),
				-- Dev only: present when dev/pulse_zdesign.luau is (it isn't shipped).
				ui.column {
					w_full = true,
					gap = "$zeron.list.gap",
					pl = "$space.4",
					if has_pulse then PanelHome.Row { id = "dp-import-pulse", icon = "plus", label = "Import Pulse (dev)", on_click = import_pulse } else ui.div {},
					if has_extra then PanelHome.Row { id = "dp-import-extra", icon = "plus", label = `Import {extra.name}`, on_click = import_extra } else ui.div {},
					if has_parity then PanelHome.Row { id = "dp-import-parity", icon = "plus", label = `Import {parity.name}`, on_click = import_parity } else ui.div {},
					if has_picture then PanelHome.Row { id = "dp-picture", icon = "plus", label = "Picture Design (dev)", on_click = picture_design } else ui.div {},
				},
				ui.div { w_full = true, pt = 10, pr = 10, pb = 4, pl = 36, ui.text { "Recent", text_size = 12, weight = 600, color = L.faint } },
				recents(L),
			}
		end, { w_full = true }),
	}
end

zeron.place {
	at = "hook:panel.empty",
	after = function(): Node
		local session = zeron.context("session")
		local panel = zeron.context("panel")
		if not session or not panel then
			return ui.div {}
		end
		local shown = ui.use_state(false)
		local function toggle()
			shown:set(not shown:peek())
		end
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
				ui.after(0, toggle)
			end
		end)
		return ui.column {
			id = "dp-empty-rows",
			w_full = true,
			gap = "$zeron.list.gap",
			PanelHome.Choice { id = "dp-open-design", icon = "palette" :: any, label = "Design" :: any, key = "D", on_click = toggle },
			ui.presence(function(): string
				return if shown:get() then "open" else "shut"
			end, function(which: string): Node
				if which == "shut" then
					return ui.div {}
				end
				return Picker {
					panel = panel,
					done = function()
						shown:set(false)
					end,
				}
			end, { w_full = true }),
		}
	end,
}
