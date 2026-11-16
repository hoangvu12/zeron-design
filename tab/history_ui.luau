--!nonstrict
-- The hand cursor on clickable controls (zgx's ui is read-only: see pointer.luau).
local ui = require("./pointer").ui
-- (N3) The left panel's History tab (pure/anim/n3/README.md): every change
-- to the Design newest first. An agent's call is a card: who (the chat's
-- title), when, what it said it did, and for each Screen it touched (3 at
-- most) a small picture before → after; a click on one zooms the board to
-- that Screen. The person's edits in a row fold into one line ("You · 4
-- edits", a click lists them). Undo on the newest; Undo to here on older
-- ones (undoes everything after it); undone ones show faded.
--
--   HistoryUI.List { L, history = source.history, chat_title, zoom(id) }

local Kit = require("./kit")
local Look = require("./look")
local H = require("./history")
local CM = require("./comments") -- (`ago`: "now", "5 min", "2 h")

local M = {}

local CLEAR = "#00000000"
local THUMB_H = 96
local P = "history"

local function small_btn(L: any, id: string, label: string, tip: string, fn: () -> ()): Node
	return ui.button {
		id = id,
		label = label,
		tooltip = Kit.tip(L, tip),
		tooltip_placement = { side = "bottom", align = "end", offset = 6 },
		h = 22,
		px = 7,
		gap = 4,
		rounded = 6,
		border = 0,
		items = "center",
		shrink = 0,
		bg = L.field,
		hover = { bg = L.field_active },
		focus = { outline = 0 },
		color = L.fg,
		on_click = fn,
		Kit.icon("undo", 11),
		ui.text { label, text_size = 11, weight = 500, font = Look.UI, color = L.fg },
	}
end

-- The undo button a row gets (or none): `seq` its newest step.
local function action(L: any, h: any, steps: { any }, latest: number, seq: number, done: boolean): Node
	local a = H.action(seq, done, latest)
	if a == "undo" then
		return small_btn(L, `{P}-undo-{seq}`, "Undo", "Undo this change", function()
			h.undo_to(seq, false)
		end)
	elseif a == "to" then
		local n = H.count_after(steps, seq)
		return small_btn(L, `{P}-to-{seq}`, "Undo to here", `Undo the {n} change{if n == 1 then "" else "s"} after this one (Redo brings them back)`, function()
			h.undo_to(seq, true)
		end)
	end
	if not done then
		return ui.text { "Undone", id = `{P}-undone-{seq}`, text_size = 11, color = L.faint, font = Look.UI, shrink = 0 }
	end
	return ui.div {}
end

-- One picture (or a quiet box while there's none).
local function thumb(L: any, h: any, s: any, root: string, which: string, id: string): Node
	return ui.presence(function(): string
		return if h.picture(s, root, which) then "1" else "0"
	end, function(k: string): Node
		if k == "1" then
			return ui.image { id = id, src = h.picture(s, root, which), w_full = true, h = THUMB_H, fit = "contain" }
		end
		return ui.div { id = `{id}-none`, w_full = true, h = THUMB_H }
	end, { grow = 1, basis = 0, min_w = 0, h = THUMB_H, rounded = 6, bg = L.field, overflow = "hidden" })
end

-- A Screen the call touched: its name (a click zooms to it), and its
-- before → after when the call kept pictures.
local function screen(L: any, h: any, o: any, s: any, sc: any, i: number, pictures: boolean): Node
	local id = `{P}-screen-{s.seq}-{i}`
	local zoom = function()
		if not sc.gone and o.zoom then
			o.zoom(sc.id)
		end
	end
	local kids: any = {
		id = id,
		label = `Show {sc.name}`,
		w_full = true,
		direction = "column",
		gap = 4,
		p = 0,
		border = 0,
		rounded = 6,
		bg = CLEAR,
		hover = { opacity = 0.85 },
		focus = { outline = 0 },
		on_click = zoom,
		ui.row {
			w_full = true,
			gap = 4,
			items = "center",
			ui.div { color = L.faint, shrink = 0, Kit.icon("frame", 11) },
			ui.text { sc.name, literal = true, text_size = 11, color = if sc.gone then L.faint else L.muted, truncate = true, min_w = 0, shrink = 1, font = Look.UI },
			if sc.gone then ui.text { "deleted", text_size = 11, color = L.faint, shrink = 0, font = Look.UI } else ui.div {},
		},
	}
	if pictures then
		table.insert(kids, ui.row {
			w_full = true,
			gap = 4,
			items = "center",
			thumb(L, h, s, sc.id, "b", `{id}-b`),
			ui.div { color = L.faint, shrink = 0, Kit.icon("arrowRight", 11) },
			thumb(L, h, s, sc.id, "a", `{id}-a`),
		})
	end
	return ui.button(kids)
end

local function agent_card(L: any, h: any, o: any, steps: { any }, latest: number, s: any, pictures: boolean, now: number): Node
	local who = "Agent"
	local t = s.chat and o.chat_title and o.chat_title(s.chat)
	if type(t) == "string" and t ~= "" then
		who = t
	end
	local col: any = {
		id = `{P}-row-{s.seq}`,
		w_full = true,
		px = 6,
		py = 8,
		gap = 6,
		rounded = 8,
		opacity = if s.done then 1 else 0.55,
		ui.row {
			w_full = true,
			gap = 6,
			items = "center",
			ui.div { color = L.agent_fg or L.accent, shrink = 0, Kit.icon("sparkles", 12) },
			ui.text { who, literal = true, text_size = 11, weight = 600, color = L.fg, truncate = true, min_w = 0, shrink = 1, font = Look.UI },
			ui.text { CM.ago(s.at, now), text_size = 11, color = L.faint, shrink = 0, font = Look.UI },
			ui.div { grow = 1 },
			action(L, h, steps, latest, s.seq, s.done),
		},
		ui.text { s.label or "Agent edit", literal = true, wrap = true, w_full = true, lines = 3, text_size = 12, line_height = 17, color = L.fg, font = Look.UI },
	}
	for i, sc in s.screens or {} do
		if i > H.ROOTS_MAX then
			table.insert(col, ui.text { `+{#s.screens - H.ROOTS_MAX} more`, text_size = 11, color = L.faint, font = Look.UI })
			break
		end
		table.insert(col, screen(L, h, o, s, sc, i, pictures and s.thumbs))
	end
	return ui.column(col)
end

-- The person's edits in a row, folded: a click opens their list.
local function person_group(L: any, h: any, steps: { any }, latest: number, g: any, open: any, now: number): Node
	local top = g.items[1]
	local n = #g.items
	local key = `{top.seq}`
	local words = if n == 1 then (top.label or "Edit") else `{n} edits`
	local col: any = {
		id = `{P}-group-{top.seq}`,
		w_full = true,
		gap = 2,
		opacity = if g.done then 1 else 0.55,
		ui.row {
			w_full = true,
			gap = 6,
			items = "center",
			ui.button {
				id = `{P}-group-{top.seq}-toggle`,
				label = if n == 1 then words else `Your {n} edits`,
				grow = 1,
				min_w = 0,
				h = 26,
				px = 6,
				gap = 6,
				rounded = 7,
				border = 0,
				items = "center",
				bg = CLEAR,
				hover = { bg = L.hover },
				focus = { outline = 0 },
				on_click = function()
					local m = table.clone(open:peek())
					m[key] = not m[key] or nil
					open:set(m)
				end,
				ui.div { color = L.faint, shrink = 0, Kit.icon("pencil", 11) },
				ui.text { `You · {words}`, literal = true, text_size = 11, color = L.muted, truncate = true, min_w = 0, shrink = 1, font = Look.UI },
				ui.text { CM.ago(top.at, now), text_size = 11, color = L.faint, shrink = 0, font = Look.UI },
			},
			action(L, h, steps, latest, top.seq, g.done),
		},
	}
	if n > 1 and open:peek()[key] then
		for _, s in g.items do
			table.insert(col, ui.text { s.label or "Edit", literal = true, pl = 26, text_size = 11, color = L.faint, truncate = true, font = Look.UI })
		end
	end
	return ui.column(col)
end

function M.List(o: any): Node
	local L = o.L
	local h = o.history
	if not h then
		return Kit.empty(L, { icon = "history", title = "No history here", body = "History shows a Design's changes from the plugin's service." })
	end
	return ui.component(function(): Node
	local open = ui.use_state({} :: { [string]: boolean })
	local function key(): string
		local r = h.rows:get()
		local parts = { tostring(r.latest) }
		for _, s in r.steps do
			table.insert(parts, `{s.seq}.{s.at}.{s.done}.{s.thumbs}.{s.label}`)
		end
		for k in open:get() do
			table.insert(parts, "o" .. k)
		end
		return table.concat(parts, "\1")
	end
	return ui.column {
		id = `{P}-list`,
		w_full = true,
		grow = 1,
		min_h = 0,
		on_mount = function()
			h.open()
		end,
		ui.presence(key, function(_: string): Node
			local r = h.rows:peek()
			local steps = r.steps or {}
			if #steps == 0 then
				return Kit.empty(L, { icon = "history", title = "No changes yet", body = "Each agent call shows here with a before and after of the Screens it touched. Undo any of them." })
			end
			local now = os.time()
			local col: any = { w_full = true, px = 4, pb = 12, gap = 2 }
			local agents = 0
			for _, g in H.groups(steps) do
				if g.kind == "agent" then
					agents += 1
					-- (pictures for the newest calls only: older ones dropped theirs)
					table.insert(col, agent_card(L, h, o, steps, r.latest, g.s, agents <= H.CACHE_ROWS, now))
				else
					table.insert(col, person_group(L, h, steps, r.latest, g, open, now))
				end
			end
			return ui.scroll { id = `{P}-scroll`, w_full = true, grow = 1, min_h = 0, ui.column(col) }
		end, { w_full = true, grow = 1, min_h = 0 }),
	}
	end)({})
end

return M
