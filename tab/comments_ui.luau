--!nonstrict
-- Local comments' UI (step 7, pure/anim/f7/comments/README.md): numbered pins
-- over a Screen (Play's stage, or the board in the editor), the box to write a
-- new one, a pin's thread (replies, Resolve / Reopen, Delete), and the list
-- (Play's sidebar, the editor's Comments tab). Pure parts: tab/comments.luau.
-- Pins are elements over what's drawn: nothing is drawn into a canvas.

local Kit = require("./kit")
local Look = require("./look")
local CM = require("./comments")

local M = {}

M.PIN = 24 -- a pin's size
M.CARD_W = 280 -- the thread and new-comment cards
M.SIDE_W = 280 -- Play's sidebar
local PIN_BG = "#FFC21A" -- open: amber, as a sticky note
local PIN_FG = "#1A1A1A"
local PIN_DONE = "#8A8A93"
local CLEAR = "#00000000"

-- Presses inside a pin or a card (or anything in them) count here: the
-- stage under them, which takes the same press, leaves it alone (`cm.press`
-- looks a tick later).
M.inside_n = 0
function M.inside(_e: any)
	M.inside_n += 1
end

local function small_btn(L: any, id: string, label: string, icon: string, fn: () -> (), color: string?): Node
	return ui.button {
		id = id,
		label = label,
		tooltip = Kit.tip(L, label),
		tooltip_placement = { side = "bottom", offset = 6 },
		w = 24,
		h = 24,
		p = 0,
		rounded = 6,
		border = 0,
		items = "center",
		justify = "center",
		shrink = 0,
		bg = CLEAR,
		hover = { bg = L.hover },
		focus = { outline = 0 },
		color = color or L.muted,
		on_click = fn,
		Kit.icon(icon, 13),
	}
end

local function text_btn(L: any, id: string, label: string, primary: boolean, fn: () -> ()): Node
	return ui.button {
		id = id,
		label = label,
		h = 26,
		px = 10,
		rounded = 7,
		border = 0,
		items = "center",
		shrink = 0,
		bg = if primary then L.accent else L.field,
		hover = { opacity = 0.9 },
		focus = { outline = 1, outline_color = L.accent },
		on_click = fn,
		ui.text { label, text_size = 12, weight = 500, font = Look.UI, color = if primary then (L.on_accent or "#FFFFFF") else L.fg },
	}
end

-- A box to type in: Enter sends, Shift+Enter a new line, Esc cancels.
-- `o` = { L, id, label, placeholder, send(text), cancel(), focus? }
local function writer(o: any): Node
	return ui.component(function(): Node
	local L = o.L
	local text = ui.use_state("")
	local function send()
		local t = string.gsub(string.gsub(text:peek(), "^%s+", ""), "%s+$", "")
		if t ~= "" then
			o.send(t)
			text:set("")
		end
	end
	return ui.column {
		w_full = true,
		gap = 6,
		ui.textarea {
			id = o.id,
			label = o.label,
			w_full = true,
			h = 52,
			value = function(): string
				return text:get()
			end,
			placeholder = o.placeholder,
			placeholder_color = L.faint,
			on_change = function(t: string)
				text:set(t)
			end,
			on_key = function(k: any): boolean?
				if k.key == "Enter" and not k.shift then
					send()
					return true
				elseif k.key == "Escape" then
					o.cancel()
					return true
				end
				-- (typing stays here: Play's and the editor's keys wait)
				return nil
			end,
			on_mount = function(e: any)
				if o.focus ~= false then
					e:focus()
				end
			end,
			wrap = true,
			px = 8,
			py = 6,
			rounded = 7,
			border = 0,
			bg = L.field,
			focus = { outline = 1, outline_color = L.accent, bg = L.field_active },
			text_size = 12,
			font = Look.UI,
			color = L.fg,
		},
		ui.row {
			w_full = true,
			gap = 6,
			justify = "end",
			text_btn(L, o.id .. "-cancel", "Cancel", false, o.cancel),
			text_btn(L, o.id .. "-send", o.send_label or "Post", true, send),
		},
	}
	end)({})
end
M.writer = writer

local function card(L: any, id: string, kids: { Node }): any
	local c: any = {
		id = id,
		role = "dialog",
		label = "Comment",
		w = M.CARD_W,
		p = 10,
		gap = 8,
		rounded = 10,
		bg = L.panel_solid or L.card,
		border = 1,
		border_color = L.border,
		shadow = { y = 6, blur = 20, color = L.shadow or "#00000040" },
		color = L.fg,
		font = Look.UI,
		-- (a press here isn't a press on the Screen under it)
		on_press = M.inside,
	}
	for _, k in kids do
		table.insert(c, k)
	end
	return c
end

local function entry(L: any, c: any, chat_title: any, now: number): Node
	return ui.column {
		w_full = true,
		gap = 2,
		ui.row {
			w_full = true,
			gap = 6,
			items = "center",
			ui.text { CM.who(c, chat_title), literal = true, text_size = 12, weight = 600, color = if c.author == "Agent" then (L.agent_fg or L.fg) else L.fg, truncate = true, min_w = 0, shrink = 1 },
			ui.text { CM.ago(c.at, now), text_size = 11, color = L.faint, shrink = 0 },
		},
		ui.text { c.text, literal = true, wrap = true, w_full = true, text_size = 12, line_height = 17, color = L.fg },
	}
end

-- One pin's thread. `o` = { L, prefix, t, act(args, done?), close(), names,
-- chat_title }
function M.Thread(o: any): Node
	local L, t = o.L, o.t
	local p = o.prefix
	local now = os.time()
	local list: any = { w_full = true, gap = 10, entry(L, t, o.chat_title, now) }
	for _, r in t.replies or {} do
		table.insert(list, entry(L, r, o.chat_title, now))
	end
	local name = (o.names or {})[t.screen] or CM.GONE
	return ui.column(card(L, `{p}-thread`, {
		ui.row {
			w_full = true,
			gap = 2,
			items = "center",
			ui.text { `#{t.n}  ·  {name}`, literal = true, text_size = 11, weight = 500, color = L.muted, grow = 1, truncate = true, min_w = 0 },
			if t.resolved
				then small_btn(L, `{p}-reopen`, "Reopen", "undo", function()
					o.act({ action = "reopen", id = t.id })
				end)
				else small_btn(L, `{p}-resolve`, "Resolve", "check", function()
					o.act({ action = "resolve", id = t.id })
					o.close()
				end, L.accent),
			small_btn(L, `{p}-delete`, "Delete comment", "trash", function()
				o.act({ action = "delete", id = t.id })
				o.close()
			end),
			small_btn(L, `{p}-close`, "Close", "x", o.close),
		},
		if t.resolved then ui.text { "Resolved", id = `{p}-resolved-note`, text_size = 11, weight = 500, color = L.accent } else ui.div {},
		-- (a long thread scrolls; a short one is as tall as its words)
		if #(t.replies or {}) >= 4 or #t.text > 600 then ui.scroll { w_full = true, h = 260, ui.column(list) } else ui.column(list),
		writer {
			L = L,
			id = `{p}-reply`,
			label = "Reply",
			placeholder = "Reply",
			send_label = "Reply",
			focus = false,
			send = function(text: string)
				o.act({ action = "reply", id = t.id, text = text })
			end,
			cancel = o.close,
		},
	}))
end

-- The box for a new pin. `o` = { L, prefix, post(text), cancel() }
function M.Compose(o: any): Node
	return ui.column(card(o.L, `{o.prefix}-new`, {
		writer {
			L = o.L,
			id = `{o.prefix}-new-text`,
			label = "New comment",
			placeholder = "Add a comment",
			send = o.post,
			cancel = o.cancel,
		},
	}))
end

-- Pins and the card open over them, absolutely placed in their parent.
-- `o` = {
--   L, prefix,
--   pins: () -> { { t, x, y } }  (reactive: where each pin shows, parent points),
--   open: state (a pin's id | "new" | nil), new_at: () -> { x, y }?,
--   size: () -> { w, h } (the parent's), act(args, done?), post(text),
--   names: () -> { [id]: name }, chat_title, hidden: () -> boolean,
-- }
function M.Pins(o: any): Node
	local L = o.L
	local p = o.prefix
	local pins = ui.computed(function(): { any }
		if o.hidden() then
			return {}
		end
		return o.pins()
	end)
	local function at(id: string): any?
		for _, e in pins:get() do
			if e.t.id == id then
				return e
			end
		end
		return nil
	end
	-- the card beside a point, kept inside the parent
	local function card_pos(x: number, y: number): (number, number)
		local s = o.size()
		local cx = x + M.PIN / 2 + 8
		if cx + M.CARD_W > s.w - 8 then
			cx = x - M.PIN / 2 - 8 - M.CARD_W
		end
		local cy = math.clamp(y - 20, 8, math.max(8, s.h - 220))
		return math.max(8, cx), cy
	end
	local function pin(e: any): Node
		local t = e.t
		local id = t.id
		return ui.button {
			id = `{p}-pin-{t.n}`,
			label = `Comment {t.n}`,
			absolute = true,
			left = function(): number
				local q = at(id)
				return (if q then q.x else -100) - M.PIN / 2
			end,
			top = function(): number
				local q = at(id)
				return (if q then q.y else -100) - M.PIN
			end,
			w = M.PIN,
			h = M.PIN,
			p = 0,
			-- (a speech bubble whose tip is the point: round but its bottom left)
			corners = { tl = M.PIN / 2, tr = M.PIN / 2, br = M.PIN / 2, bl = 3 },
			border = 2,
			border_color = "#FFFFFF",
			items = "center",
			justify = "center",
			bg = if t.resolved then PIN_DONE else PIN_BG,
			shadow = { y = 2, blur = 6, color = "#00000059" },
			focus = { outline = 0 },
			scale = function(): number
				return if o.open:get() == id then 1.15 else 1
			end,
			on_press = M.inside,
			on_click = function()
				o.open:set(if o.open:peek() == id then nil else id)
			end,
			ui.text { tostring(t.n), text_size = 11, weight = 700, font = Look.UI, color = if t.resolved then "#FFFFFF" else PIN_FG, tabular = true },
		}
	end
	return ui.div {
		id = `{p}-layer`,
		absolute = true,
		left = 0,
		top = 0,
		right = 0,
		bottom = 0,
		pointer_events = "none", -- (the pins and cards in it still take the pointer)
		ui.each(pins, pin, {
			key = function(e: any): string
				-- (a pin's look changes with its number or state: a new element)
				return `{e.t.id}|{e.t.n}|{e.t.resolved}`
			end,
		}),
		-- the card open: a pin's thread, or the box for a new pin
		ui.presence(function(): string
			local open = o.open:get()
			if open == "new" then
				local q = o.new_at and o.new_at()
				return if q then "new" else "none"
			end
			if not open then
				return "none"
			end
			local t = nil
			for _, x in o.list() do
				if x.id == open then
					t = x
				end
			end
			if not t then
				return "none"
			end
			local sig = { open, tostring(t.resolved), t.text }
			for _, r in t.replies or {} do
				table.insert(sig, r.id)
			end
			return table.concat(sig, "|")
		end, function(which: string): Node
			if o.zone then
				-- (no card yet: its box comes with its first layout)
				o.zone.w, o.zone.h = 0, 0
			end
			if which == "none" then
				return ui.div {}
			end
			local function place(): (number, number)
				if which == "new" then
					local q = o.new_at()
					return card_pos(q and q.x or 0, q and q.y or 0)
				end
				local q = at(o.open:peek())
				return card_pos(q and q.x or 0, q and q.y or 0)
			end
			local inner
			if which == "new" then
				inner = M.Compose {
					L = L,
					prefix = p,
					post = o.post,
					cancel = function()
						o.open:set(nil)
					end,
				}
			else
				local t = nil
				for _, x in o.list() do
					if x.id == o.open:peek() then
						t = x
					end
				end
				if not t then
					return ui.div {}
				end
				inner = M.Thread {
					L = L,
					prefix = p,
					t = t,
					act = o.act,
					names = o.names(),
					chat_title = o.chat_title,
					close = function()
						o.open:set(nil)
					end,
				}
			end
			local zone = o.zone
			return ui.div {
				absolute = true,
				left = function(): number
					local x, y = place()
					if zone then
						zone.x, zone.y = x, y
					end
					return x
				end,
				top = function(): number
					local _, y = place()
					return y
				end,
				on_resize = function(s: { w: number, h: number })
					if zone then
						zone.w, zone.h = s.w, s.h
					end
				end,
				inner,
			}
		end),
		-- the new pin, where it will go
		ui.show(function(): boolean
			return o.open:get() == "new" and o.new_at ~= nil and o.new_at() ~= nil
		end, ui.div {
			id = `{p}-new-pin`,
			absolute = true,
			left = function(): number
				local q = o.new_at and o.new_at()
				return (if q then q.x else -100) - M.PIN / 2
			end,
			top = function(): number
				local q = o.new_at and o.new_at()
				return (if q then q.y else -100) - M.PIN
			end,
			w = M.PIN,
			h = M.PIN,
			corners = { tl = M.PIN / 2, tr = M.PIN / 2, br = M.PIN / 2, bl = 3 },
			border = 2,
			border_color = "#FFFFFF",
			bg = L.accent,
			pointer_events = "none",
		}),
	}
end

-- The list: a row per pin, grouped by Screen (the shown one first), resolved
-- ones behind a toggle. `o` = { L, prefix, list: state, names(), first(),
-- resolved: state, pick(t), picked(): id?, chat_title, head: Node? }
function M.List(o: any): Node
	local L = o.L
	local p = o.prefix
	local function key(): string
		local parts = { tostring(o.resolved:get()), tostring(o.first()), tostring(o.picked()) }
		for _, t in o.list:get() do
			table.insert(parts, `{t.id}.{t.n}.{t.resolved}.{t.screen}.{#(t.replies or {})}.{t.text}`)
		end
		local names = o.names()
		for id, n in names do
			table.insert(parts, `{id}={n}`)
		end
		return table.concat(parts, "\1")
	end
	return ui.column {
		id = `{p}-list`,
		w_full = true,
		grow = 1,
		min_h = 0,
		o.head or ui.div {},
		ui.row {
			w_full = true,
			h = 30,
			px = 12,
			gap = 6,
			items = "center",
			shrink = 0,
			ui.text {
				function(): string
					local n = CM.count_open(o.list:get())
					return if n == 0 then "No open comments" elseif n == 1 then "1 open" else `{n} open`
				end,
				id = `{p}-count`,
				text_size = 11,
				color = L.faint,
				grow = 1,
				font = Look.UI,
			},
			ui.button {
				id = `{p}-show-resolved`,
				label = "Show resolved",
				h = 22,
				px = 6,
				gap = 4,
				rounded = 6,
				border = 0,
				items = "center",
				bg = function(): string
					return if o.resolved:get() then L.field_active else CLEAR
				end,
				hover = { bg = L.hover },
				focus = { outline = 0 },
				color = L.muted,
				on_click = function()
					o.resolved:set(not o.resolved:peek())
				end,
				ui.div {
					opacity = function(): number
						return if o.resolved:get() then 1 else 0.35
					end,
					Kit.icon("check", 11),
				},
				ui.text { "Resolved", text_size = 11, font = Look.UI, color = L.muted },
			},
		},
		ui.presence(key, function(_: string): Node
			local groups = CM.groups(o.list:peek(), o.names(), o.first(), o.resolved:peek())
			local col: any = { w_full = true, px = 8, pb = 12, gap = 2 }
			if #groups == 0 then
				table.insert(col, ui.text {
					"Press C (or the comment button), then click the Screen to leave a comment. Agents read them with design_state.",
					id = `{p}-empty`,
					wrap = true,
					w_full = true,
					px = 4,
					py = 8,
					text_size = 12,
					line_height = 17,
					color = L.faint,
					font = Look.UI,
				})
			end
			local now = os.time()
			for _, g in groups do
				table.insert(col, ui.text { g.name, literal = true, px = 4, pt = 8, pb = 2, text_size = 11, weight = 600, color = L.muted, truncate = true, font = Look.UI })
				for _, t in g.items do
					local on = o.picked() == t.id
					table.insert(col, ui.button {
						id = `{p}-item-{t.n}`,
						label = `Comment {t.n}`,
						w_full = true,
						px = 6,
						py = 6,
						gap = 8,
						rounded = 7,
						border = 0,
						items = "start",
						bg = if on then L.field_active else CLEAR,
						hover = { bg = L.hover },
						focus = { outline = 0 },
						opacity = if t.resolved then 0.6 else 1,
						on_click = function()
							o.pick(t)
						end,
						ui.div {
							w = 20,
							h = 20,
							shrink = 0,
							corners = { tl = 10, tr = 10, br = 10, bl = 2 },
							bg = if t.resolved then PIN_DONE else PIN_BG,
							items = "center",
							justify = "center",
							ui.text { tostring(t.n), text_size = 10, weight = 700, color = if t.resolved then "#FFFFFF" else PIN_FG, tabular = true },
						},
						ui.column {
							grow = 1,
							min_w = 0,
							gap = 2,
							ui.row {
								w_full = true,
								gap = 6,
								ui.text { CM.who(t, o.chat_title), literal = true, text_size = 11, weight = 600, color = L.fg, truncate = true, min_w = 0, shrink = 1, font = Look.UI },
								ui.text { CM.ago(t.at, now), text_size = 11, color = L.faint, shrink = 0, font = Look.UI },
								ui.div { grow = 1 },
								if #(t.replies or {}) > 0 then ui.text { `{#t.replies} repl{if #t.replies == 1 then "y" else "ies"}`, text_size = 11, color = L.faint, shrink = 0, font = Look.UI } else ui.div {},
							},
							ui.text { t.text, literal = true, wrap = true, w_full = true, lines = 3, text_size = 12, line_height = 17, color = L.fg, font = Look.UI },
						},
					})
				end
			end
			return ui.scroll { id = `{p}-scroll`, w_full = true, grow = 1, min_h = 0, ui.column(col) }
		end, { w_full = true, grow = 1, min_h = 0 }),
	}
end

-- ── Play ─────────────────────────────────────────────────────────────────
-- Comment mode in Play (Figma's C): the pins of the Screens shown, a click
-- on a Screen drops a new one, the sidebar on the right. Built inside
-- Play's component (it makes states); Play keeps its locals for itself and
-- hands its parts in `a`:
--   D, L (looks), source, current (state: the shown slot's key), slot(key) →
--   slot data, overlays() → open overlay keys, to_screen(lx, ly), shift_of(sd),
--   deepest(root, x, y, shift), go(id) (navigate), hidden() (Hide UI),
--   stage() → { w, h }, resized() (the stage changes size now), focus() (Play's keys).
-- Returns { on, open, press(e) → bool, key(k) → bool?, moved(), button(),
-- side(), layer(), shown() }.
function M.play(a: any): any
	local D = a.D
	local source = a.source
	local cm: any = {
		on = ui.use_state(false),
		open = ui.use_state(nil :: string?), -- a pin's id, or "new"
		resolved = ui.use_state(false),
		tick = ui.use_state(0), -- (scrolling moves the pins)
		new = nil :: any, -- the new pin: { key, screen, x, y, node, nx, ny }
		zone = { x = 0, y = 0, w = 0, h = 0 }, -- the open card's box on the stage
	}
	local function list_get(): { any }
		return if source.comments then source.comments:get() or {} else {}
	end
	local function list_peek(): { any }
		return if source.comments then source.comments:peek() or {} else {}
	end
	-- Screen ids → names, from the scene
	local function names(): { [string]: string }
		local out = {}
		for _, r in source.roots:peek() do
			local n = r.nodes and r.nodes[1]
			if n then
				out[r.id] = n.name or r.id
			end
		end
		return out
	end
	-- the slots shown: the Screen, then the overlays open over it
	local function shown_keys(): { string }
		local out = {}
		local cur = a.current:peek()
		if cur then
			table.insert(out, cur)
		end
		for _, k in a.overlays() do
			table.insert(out, k)
		end
		return out
	end
	-- a Canvas point on slot `sd` → the stage
	local function to_stage(sd: any, x: number, y: number): (number, number)
		local pl = sd.place
		return pl.left + (x - pl.b.x) * pl.z, pl.top + (y - pl.b.y) * pl.z
	end
	function cm.pins(): { any }
		local list = list_get()
		local _ = a.current:get()
		local _ = cm.tick:get()
		local _ = a.stage_v()
		local res = cm.resolved:get()
		if not cm.on:get() then
			return {}
		end
		local out = {}
		for _, key in shown_keys() do
			local sd = a.slot(key)
			if sd and sd.place and sd.root then
				local shift = a.shift_of(sd)
				for _, t in CM.on_screen(list, sd.id, res) do
					local q = CM.anchor(sd.root, t, shift)
					if q then
						local x, y = to_stage(sd, q.x, q.y)
						local pl = sd.place
						-- (inside the slot's viewport only)
						if x >= pl.left - 2 and y >= pl.top - 2 and x <= pl.left + pl.w + 2 and y <= pl.top + pl.h + 2 then
							table.insert(out, { t = t, x = x, y = y })
						end
					end
				end
			end
		end
		return out
	end
	function cm.new_at(): any?
		local n = cm.new
		local _ = cm.tick:get()
		local sd = n and a.slot(n.key)
		if not sd or not sd.place then
			return nil
		end
		local q = CM.anchor(sd.root, n, a.shift_of(sd))
		if not q then
			return nil
		end
		local x, y = to_stage(sd, q.x, q.y)
		return { x = x, y = y }
	end
	function cm.act(args: any, done: any?)
		if source.comment then
			source.comment(args, done)
		end
	end
	function cm.set_on(on: boolean)
		if cm.on:peek() == on then
			return
		end
		cm.open:set(nil)
		cm.new = nil
		a.resized()
		cm.on:set(on)
	end
	-- a press on the stage in comment mode: a card open closes; else a new pin
	function cm.press(e: any): boolean
		if not cm.on:peek() then
			return false
		end
		-- (a press on a pin or a card reaches the stage too: theirs, not ours,
		-- whichever of them hears it first)
		local lx, ly = e.local_x or 0, e.local_y or 0
		local z = cm.zone
		if cm.open:peek() ~= nil and z.w > 0 and lx >= z.x and ly >= z.y and lx <= z.x + z.w and ly <= z.y + z.h then
			return true -- (in the card)
		end
		for _, p in cm.pins() do
			if math.abs(lx - p.x) <= M.PIN / 2 + 2 and ly <= p.y + 2 and ly >= p.y - M.PIN - 2 then
				return true -- (on a pin: its own click opens it)
			end
		end
		local mark = M.inside_n
		ui.after(0, function()
			if M.inside_n == mark then
				cm.stage_press(e)
			end
		end)
		return true
	end
	function cm.stage_press(e: any)
		if cm.open:peek() ~= nil then
			cm.open:set(nil)
			cm.new = nil
			a.focus()
			return true
		end
		local key, x, y = a.to_screen(e.local_x or 0, e.local_y or 0)
		local sd = key and a.slot(key)
		if not sd or x < -1e8 then
			return true
		end
		local shift = a.shift_of(sd)
		local i = a.deepest(sd.root, x, y, shift)
		-- (followups: a layer the board has too, so the pin follows it there)
		local base = CM.roots_by(source.roots and source.roots:peek() or nil)[sd.id]
		i = CM.kept_layer(sd.root, if i and i > 0 then i else nil, base)
		local lp = CM.local_point(sd.root, i, x, y, shift)
		lp.key = key
		lp.screen = sd.id
		cm.new = lp
		cm.open:set("new")
		return true
	end
	function cm.post(text: string)
		local n = cm.new
		if not n then
			return
		end
		cm.act({ action = "add", screen = n.screen, x = n.x, y = n.y, node = n.node, nx = n.nx, ny = n.ny, text = text }, function(ok: boolean, r: any)
			if ok and type(r) == "table" and r.id then
				cm.new = nil
				cm.open:set(nil)
				a.focus()
			end
		end)
	end
	-- Play's keys, first: C toggles comment mode; Esc closes a card, then
	-- leaves comment mode. (nil: not ours)
	function cm.key(k: any): boolean?
		local key = k.key
		if (key == "c" or key == "C") and not k.cmd and not k.alt and not k.shift then
			cm.set_on(not cm.on:peek())
			return true
		end
		if key == "Escape" and cm.on:peek() then
			if cm.open:peek() ~= nil then
				cm.open:set(nil)
				cm.new = nil
			else
				cm.set_on(false)
			end
			return true
		end
		return nil
	end
	function cm.moved()
		if cm.on:peek() then
			cm.tick:set(cm.tick:peek() + 1)
		end
	end
	-- the bar's button: comment mode, with the open count
	function cm.button(): Node
		return ui.button {
			id = "play-comments-toggle",
			label = "Comments",
			tooltip = Kit.tip(D, "Comments  C"),
			tooltip_placement = { side = "bottom", offset = 8 },
			h = 28,
			px = 7,
			gap = 4,
			rounded = 8,
			border = 0,
			items = "center",
			shrink = 0,
			bg = function(): string
				return if cm.on:get() then D.field_active else CLEAR
			end,
			hover = { bg = D.hover },
			focus = { outline = 0 },
			color = function(): string
				return if cm.on:get() then D.fg else D.muted
			end,
			on_click = function()
				cm.set_on(not cm.on:peek())
			end,
			Kit.icon("message", 14),
			ui.text {
				function(): string
					local n = CM.count_open(list_get())
					return if n > 0 then tostring(n) else ""
				end,
				id = "play-comments-badge",
				text_size = 11,
				weight = 600,
				tabular = true,
				font = Look.UI,
			},
		}
	end
	-- the sidebar (right, as Figma's comments panel)
	function cm.side(): Node
		return ui.show(function(): boolean
			return cm.on:get() and not a.hidden()
		end, ui.column {
			id = "play-comments",
			role = "group",
			label = "Comments",
			w = M.SIDE_W,
			h_full = true,
			shrink = 0,
			bg = D.panel_solid or D.canvas,
			border_sides = { 0, 0, 0, 1 },
			border_color = D.border,
			M.List {
				L = D,
				prefix = "play-comments",
				list = source.comments,
				names = names,
				first = function(): string?
					local cur = a.current:get()
					local sd = cur and a.slot(cur)
					return sd and sd.id
				end,
				resolved = cm.resolved,
				picked = function(): string?
					return cm.open:get()
				end,
				chat_title = source.chat_title,
				pick = function(t: any)
					local cur = a.current:peek()
					local sd = cur and a.slot(cur)
					if not (sd and sd.id == t.screen) then
						a.go(t.screen)
					end
					cm.new = nil
					cm.open:set(t.id)
				end,
				head = ui.row {
					w_full = true,
					h = 40,
					shrink = 0,
					pl = 16,
					pr = 8,
					items = "center",
					ui.text { "Comments", text_size = 12, weight = 600, font = Look.UI, color = D.fg, grow = 1 },
					small_btn(D, "play-comments-close", "Close comments", "x", function()
						cm.set_on(false)
						a.focus()
					end),
				},
			},
		})
	end
	-- the pins and the card over the stage
	function cm.layer(): Node
		return M.Pins {
			L = D,
			prefix = "play-comment",
			pins = cm.pins,
			zone = cm.zone,
			open = cm.open,
			new_at = cm.new_at,
			list = list_get,
			size = a.stage,
			act = cm.act,
			post = cm.post,
			names = names,
			chat_title = source.chat_title,
			hidden = a.hidden,
		}
	end
	-- (for the harness) the pins as placed
	function cm.state(): any
		local out = {}
		for _, p in cm.pins() do
			table.insert(out, { n = p.t.n, x = math.floor(p.x + 0.5), y = math.floor(p.y + 0.5), node = p.t.node })
		end
		return { on = cm.on:peek(), open = cm.open:peek(), pins = out, count = #list_peek() }
	end
	return cm
end

return M
