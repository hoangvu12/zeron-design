--!strict
-- Every Design, as a gallery: the sidebar's "Designs" page (zeron.page), and
-- the same in a chat's panel as a tab ("All designs" in the panel home's
-- list). Laid out as Zeron's own pages are (GitHub's pull requests): a
-- title with what to do at its end, a search and the sort under it, then
-- the cards, in a column no wider than 960, centred, the page scrolling.
--
-- Cards: the Design's first screen as a thumbnail, its name and when it was
-- last edited. A click opens it in the page's (or chat's) panel; a
-- secondary click or its ⋯: Open, Rename (in place), Delete (asks once
-- more). Rows of cards are a virtual list: only those in view are built,
-- so hundreds of Designs cost what a screenful does.
--
-- Thumbnails: drawn in this window, lazily, one at a time, only for cards
-- that are built (in view): the service's `scene` for the first screen
-- (capped in bytes), drawn small with the Canvas's own draw (tab/draw, as
-- agents' screenshots are) to a PNG, decoded once into a bitmap. At most
-- CAP are kept (the least recently shown go); one is drawn again when its
-- Design's version moved, no sooner than REDRAW_S after the last.

local Draw = require("./tab/draw")
local SessionRow = require("@ds/session_row")
local Button = require("@ds/button")
local Icon = require("@ds/icon")
local IconButton = require("@ds/icon_button").IconButton
local ContextMenu = require("@ds/context_menu")
local SearchField = require("@ds/search_field")
local Tabs = require("@ds/tabs")
local EmptyState = require("@ds/empty_state")
local Text = require("@ds/text")
local FadeText = require("@ds/fade_text")
local status = require("@ds/status")

local THUMB_H = 136
local CARD_MIN_W = 200
local GAP = 16
local CARD_H = THUMB_H + 8 + 22 + 18
local ROW_H = CARD_H + GAP
-- The thumbnail's longest side, drawn (2× a card's, for a sharp picture).
local THUMB_PX = 480
local CAP = 48
local REDRAW_S = 20
local SCENE_BYTES = 300000

return function(ctx: any)
	local zeron, service = ctx.zeron, ctx.service

	-- ── thumbnails ──────────────────────────────────────────────────────
	type Thumb = { bitmap: any, version: number?, at: number, n: number }
	local thumbs: { [string]: Thumb } = {}
	local order: { string } = {}
	local landed = ui.state("design-pure.gallery.thumbs", 0)
	local queue: { { did: string, version: number? } } = {}
	local queued: { [string]: boolean } = {}
	local busy = false
	local n = 0

	local function touch(did: string)
		local i = table.find(order, did)
		if i then
			table.remove(order, i)
		end
		table.insert(order, did)
		while #order > CAP do
			local gone = table.remove(order, 1) :: string
			thumbs[gone] = nil
		end
	end

	local pump: () -> ()
	local function settle(did: string, version: number?, bitmap: any)
		queued[did] = nil
		n += 1
		thumbs[did] = { bitmap = bitmap, version = version, at = os.clock(), n = n }
		touch(did)
		landed:set(n)
		busy = false
		-- (A breath between two: the window keeps its frames.)
		ui.after(40, pump)
	end
	pump = function()
		if busy or #queue == 0 then
			return
		end
		busy = true
		local job = table.remove(queue, 1) :: any
		local did, version = job.did, job.version
		local old = thumbs[did]
		local function fail()
			settle(did, version, if old then old.bitmap else false)
		end
		if not (ui :: any).decode_image then
			fail()
			return
		end
		service:call("scene", { did = did, max_bytes = SCENE_BYTES }):after(function(reply: any)
			-- (Its largest screen of those that came: a first root is often
			-- a small part, a status bar or a component.)
			local root, area = nil, -1
			for _, r in (if type(reply) == "table" and type(reply.roots) == "table" then reply.roots else {}) do
				local b = r.nodes and r.nodes[1] and r.nodes[1].box
				if b and b.w * b.h > area then
					root, area = r, b.w * b.h
				end
			end
			if not root or not root.nodes or not root.nodes[1] then
				settle(did, version, false)
				return
			end
			Draw.ensure(Draw.picture_keys(root.nodes), function()
				local b = root.nodes[1].box
				local scale = math.min(1, THUMB_PX / math.max(b.w, b.h, 1))
				local ok, promise = pcall(ui.render_canvas, function(c: Canvas)
					Draw.draw_root(c, root)
				end, { width = b.w, height = b.h, scale = scale, x = b.x, y = b.y })
				if not ok then
					fail()
					return
				end
				promise:after(function(png: string)
					ui.decode_image(png):after(function(bitmap: any)
						settle(did, version, bitmap)
					end, fail)
				end, fail)
			end)
		end, fail)
	end
	-- A card in view asks for its Design's thumbnail.
	local function want(did: string, version: number?)
		local t = thumbs[did]
		if t then
			touch(did)
			if t.version == version or os.clock() - t.at < REDRAW_S then
				return
			end
		end
		if queued[did] then
			return
		end
		queued[did] = true
		table.insert(queue, { did = did, version = version })
		pump()
	end

	-- ── a card ──────────────────────────────────────────────────────────
	local function edited(d: any): string
		local t = math.max(tonumber(d.updated) or 0, tonumber(d.opened) or 0)
		if t <= 0 then
			return ""
		end
		local ago = status.ago(status.since(t))
		return if ago == "now" or ago == "" then "Edited just now" else `Edited {ago} ago`
	end

	local function Thumbnail(d: any): Node
		local size = ui.use_state({ w = 0, h = THUMB_H })
		ui.after(0, function()
			want(d.did, tonumber(d.version))
		end)
		return ui.div {
			w_full = true,
			h = THUMB_H,
			rounded = "$radius.lg",
			bg = "$zeron.secondary.bg",
			overflow = "hidden",
			on_resize = function(s: { w: number, h: number })
				if math.abs(size:peek().w - s.w) >= 1 then
					size:set({ w = s.w, h = THUMB_H })
				end
			end,
			ui.presence(function(): string
				landed:get()
				local t = thumbs[d.did]
				if t == nil then
					return "waiting"
				end
				return if t.bitmap then `pic{t.n}` else "none"
			end, function(key: string): Node
				if key == "waiting" or key == "none" then
					return ui.row {
						w_full = true,
						h_full = true,
						items = "center",
						justify = "center",
						color = "$text.tertiary",
						opacity = if key == "waiting" then 0.5 else 1,
						Icon { name = "palette", size = 22 },
					}
				end
				local bitmap = (thumbs[d.did] :: Thumb).bitmap
				return ui.canvas {
					w_full = true,
					h = THUMB_H,
					draw = function(c: Canvas)
						local w = size:get().w
						if w <= 0 then
							return
						end
						local pad = 10
						pcall(c.image, c, bitmap, pad, pad, w - 2 * pad, THUMB_H - 2 * pad, { fit = "contain" :: any, radius = 4 })
					end,
				}
			end, { w_full = true, h_full = true }),
		}
	end

	local function Card(d: any, props: any): Node
		local hovered = ui.use_state(false)
		local open_at: ((x: number, y: number) -> boolean)? = nil
		local dots_ref = ui.ref()
		local row = { id = d.did, title = if type(d.name) == "string" and d.name ~= "" then d.name else "Design" }
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
		local body = ui.column {
			class = "dp-gallery-card",
			role = "button",
			label = `Open design {row.title}`,
			focusable = true,
			cursor = "pointer",
			grow = 1,
			basis = 0,
			min_w = 0,
			h = CARD_H,
			gap = 0,
			relative = true,
			on_hover = function(inside: boolean)
				hovered:set(inside)
			end,
			on_click = function()
				ctx.open(row.id, row.title, props.panel)
			end,
			on_key = function(e: any): boolean?
				if (e.key == "Enter" or e.key == " ") and not (e.cmd or e.ctrl or e.alt) then
					ctx.open(row.id, row.title, props.panel)
					return true
				end
				return nil
			end,
			Thumbnail(d),
			ui.div { h = 8 },
			ui.presence(function(): string
				return if props.renaming:get() == row.id then "rename" else "name"
			end, function(which: string): Node
				if which == "rename" then
					return ui.div { w_full = true, h = 22, mt = -4, ctx.RenameField(row, props.renaming, false) }
				end
				return ui.row {
					w_full = true,
					h = 22,
					gap = "$space.2",
					items = "center",
					FadeText { row.title, grow = 1, min_w = 0, text_size = "$font.size.md", weight = "$font.weight.medium", color = "$text.primary" },
					ui.show(function(): boolean
						return ctx.working:get()[row.id] ~= nil
					end, SessionRow.state("working")),
				}
			end, { w_full = true }),
			ui.text { edited(d), h = 18, text_size = "$font.size.sm", color = "$text.tertiary", truncate = true, w_full = true },
			-- Its ⋯, over the thumbnail's corner, under the pointer.
			ui.show(function(): boolean
				return hovered:get()
			end, ui.div { absolute = true, top = 6, right = 6, rounded = "$radius.md", bg = "$zeron.secondary.bg", dots }),
		}
		return ContextMenu {
			label = "Design actions",
			grow = 1,
			basis = 0,
			min_w = 0,
			hook = function(at: (x: number, y: number) -> boolean)
				open_at = at
			end,
			items = function(): { any }?
				return ctx.design_menu(row, props.panel, props.renaming)
			end,
			body,
		}
	end

	-- ── the gallery ─────────────────────────────────────────────────────
	return function(props: { panel: any?, compact: boolean? }): Node
		local panel = props.panel
		ui.on_cleanup(ctx.watch())
		local query = ui.use_state("")
		local sort = ui.use_state(if ctx.prefs.get("gallery_sort") == "name" then "name" else "recent")
		local renaming = ui.use_state(nil :: string?)
		local width = ui.use_state(0)
		local all = ui.computed(function(): { any }
			return ctx.designs:get() or {}
		end)
		local shown = ui.computed(function(): { any }
			local q = string.lower(query:get())
			local out = {}
			for _, d in all:get() do
				if q == "" or string.find(string.lower(tostring(d.name or "")), q, 1, true) then
					table.insert(out, d)
				end
			end
			if sort:get() == "name" then
				table.sort(out, function(a: any, b: any): boolean
					return string.lower(tostring(a.name or "")) < string.lower(tostring(b.name or ""))
				end)
			end
			return out
		end)
		local function cols(): number
			local w = width:get()
			return math.max(1, math.floor((w + GAP) / (CARD_MIN_W + GAP)))
		end
		-- The cards in rows of as many as fit.
		local rows = ui.computed(function(): { any }
			local list, k = shown:get(), cols()
			local out = {}
			for i = 1, #list, k do
				local items = table.move(list, i, math.min(i + k - 1, #list), 1, {})
				table.insert(out, { key = `{(i - 1) // k}`, items = items, k = k })
			end
			return out
		end)
		local function row(_first: any, _index: any, now: any): Node
			return ui.presence(function(): string
				local r = now:get()
				local parts = { tostring(r.k) }
				for _, d in r.items do
					table.insert(parts, `{d.did}\0{d.name}\0{d.version}\0{d.updated}`)
				end
				return table.concat(parts, "\1")
			end, function(): Node
				local r = now:peek()
				local cards: { Node } = {}
				for _, d in r.items do
					table.insert(cards, Card(d, { panel = panel, renaming = renaming }))
				end
				-- (A short last row keeps its cards their width.)
				for _ = #r.items + 1, r.k do
					table.insert(cards, ui.div { grow = 1, basis = 0, min_w = 0 })
				end
				return ui.row { w_full = true, h = ROW_H, gap = GAP, items = "start", table.unpack(cards) }
			end, { w_full = true })
		end
		local function head(): Node
			return ui.column {
				w_full = true,
				gap = "$space.3",
				ui.row {
					w_full = true,
					gap = "$space.2",
					items = "center",
					Text { "Designs", style = "title", heading = 1, grow = 1, min_w = 0 },
					Button {
						id = "dp-gallery-open-file",
						tone = "ghost",
						size = "sm",
						label = "Open design…",
						on_click = function()
							ctx.open_file(panel)
						end,
						Icon { name = "folder", size = 14 },
						ui.text { "Open…" },
					},
					Button {
						id = "dp-gallery-new",
						tone = "primary",
						size = "sm",
						label = "New design",
						on_click = function()
							ctx.new_design(panel)
						end,
						Icon { name = "plus", size = 14 },
						ui.text { "New" },
					},
				},
				ui.row {
					w_full = true,
					gap = "$space.3",
					items = "center",
					ui.div {
						w = 280,
						shrink = 1,
						min_w = 0,
						SearchField { value = query, placeholder = "Search designs", name = "Search designs", size = "sm", w_full = true },
					},
					Tabs {
						value = sort,
						size = "sm",
						label = "Sort",
						options = { { value = "recent", label = "Recent" }, { value = "name", label = "Name" } },
						on_change = function(v: any)
							ctx.prefs.set("gallery_sort", v)
						end,
					},
				},
			}
		end
		local function body(): Node
			return ui.presence(function(): string
				if ctx.designs:get() == nil then
					return "loading"
				elseif #all:get() == 0 then
					return "empty"
				elseif #shown:get() == 0 then
					return "nomatch"
				end
				return "list"
			end, function(which: string): Node
				if which == "loading" then
					return ui.div { w_full = true, h = 120 }
				elseif which == "empty" then
					return ui.div {
						id = "dp-gallery-empty",
						w_full = true,
						pt = "$space.6",
						EmptyState {
							icon = "palette",
							title = "No designs yet",
							body = "Make one with New, open a .zdesign file, or ask an agent to design something.",
						},
					}
				elseif which == "nomatch" then
					return ui.div {
						id = "dp-gallery-nomatch",
						w_full = true,
						pt = "$space.6",
						EmptyState {
							icon = "magnifer",
							title = function(): string
								return `No designs match “{query:get()}”`
							end,
							body = "Try another name.",
						},
					}
				end
				return ui.list {
					id = "dp-gallery-list",
					data = rows,
					key = function(r: any): string
						return r.key
					end,
					row = row,
					height = ROW_H,
					w_full = true,
					-- (The page scrolls, never the list: only the rows in view are built.)
					virtualize = "ancestor",
				}
			end, { w_full = true })
		end
		local gutter = if props.compact then "$space.4" else "$space.6"
		return ui.column {
			id = "dp-gallery",
			w_full = true,
			h_full = true,
			ui.scroll {
				w_full = true,
				h_full = true,
				fade = { 16, 16 },
				fade_overflow = true,
				ui.column {
					w_full = true,
					min_h = "100%",
					items = "center",
					px = gutter,
					pt = gutter,
					pb = "$space.6",
					ui.column {
						w_full = true,
						max_w = ui.raw(960, "as Zeron's own pages (GitHub's board)"),
						gap = "$space.5",
						on_resize = function(s: { w: number, h: number })
							local w = math.floor(s.w)
							if w > 0 and w ~= width:peek() then
								width:set(w)
							end
						end,
						head(),
						body(),
					},
				},
			},
		}
	end
end
