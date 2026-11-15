--!strict
-- The hand cursor on clickable controls (zgx's ui is read-only: see pointer.luau).
local ui = require("./pointer").ui
-- The Design tab's states before its editor shows (the redesign's Board ·
-- Home and states, "Editor · loading" and "Editor · couldn't open"): a
-- centred line on the canvas colour.
--
--   States.Loading(L, "Opening Ledger app…")
--   States.Error(L, { title = "Couldn't open Ledger app", body = "…", retry = f, other = g? })
--
-- `States.icon(name, size, color)`: the panel set (icon_paths.luau) plus
-- the few glyphs these states and the toasts need that it lacks.

local Kit = require("./kit")
local Look = require("./look")
local Paths = require("./icon_paths")

local M = {}

-- (Lucide's, 24-box strokes; to move into icon_paths.luau.)
local EXTRA: { [string]: string } = {
	alert = "<circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M12 8v4M12 16h.01\"/>",
	info = "<circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M12 16v-4M12 8h.01\"/>",
	loader = "<path d=\"M12 2v4M16.2 7.8l2.9-2.9M18 12h4M16.2 16.2l2.9 2.9M12 18v4M4.9 19.1l2.9-2.9M2 12h4M4.9 4.9l2.9 2.9\"/>",
	refresh = "<path d=\"M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8\"/><path d=\"M21 3v5h-5\"/>",
	message = "<path d=\"M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z\"/>",
}
M.EXTRA = EXTRA

function M.icon(name: string, size: number?, color: any?, sw: number?): Node
	if Paths[name] then
		return Kit.icon(name, size, color, sw)
	end
	local s = size or 16
	return ui.svg {
		code = `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#000000" stroke-width="{sw or 1.6}" stroke-linecap="round" stroke-linejoin="round">{EXTRA[name] or ""}</svg>`,
		w = s,
		h = s,
		tint = color or "currentColor",
		label = "",
	}
end

local function frame(L: any, id: string, children: { Node }): Node
	local c: any = {
		id = id,
		w_full = true,
		h_full = true,
		bg = L.canvas,
		items = "center",
		justify = "center",
		gap = 10,
		p = 24,
	}
	for _, n in children do
		table.insert(c, n)
	end
	return ui.column(c)
end

-- A turning loader over `text` ("Opening Ledger app…"), 13/500 muted.
function M.Loading(L: any, text: string): Node
	return frame(L, "design-loading", {
		ui.div {
			w = 22,
			h = 22,
			rotate = ui.loop { from = 0, to = 360, duration = 1100, ease = "linear", yoyo = false },
			M.icon("loader", 22, L.faint),
		},
		ui.text { text, text_size = 13, weight = 500, color = L.muted, font = Look.UI },
	})
end

-- The alert in danger, the title 14/600, the body 12 muted (300 wide), then
-- "Try again" (primary) and "Open another" (secondary, when `other`).
function M.Error(L: any, o: { title: string, body: string?, retry: () -> (), other: (() -> ())? }): Node
	local actions: any = { gap = 8, items = "center", mt = 6 }
	table.insert(actions, Kit.button(L, { id = "design-retry", label = "Try again", icon = "rotate", kind = "primary", on_click = o.retry }))
	if o.other then
		table.insert(actions, Kit.button(L, { id = "design-open-another", label = "Open another", icon = "folder", on_click = o.other }))
	end
	return frame(L, "design-error", {
		M.icon("alert", 22, L.danger),
		ui.text { o.title, text_size = 14, weight = 600, color = L.fg, font = Look.UI, align = "center" },
		if o.body
			then ui.text { o.body, text_size = 12, color = L.muted, font = Look.UI, align = "center", wrap = "balance", w = 300, line_height = 18 }
			else ui.div {},
		ui.row(actions),
	})
end

-- The Design was deleted while its tab was open. Plugins can't close a
-- panel tab, so it says how, and offers "All designs" (when `other`).
function M.Deleted(L: any, o: { name: string, other: (() -> ())? }): Node
	return frame(L, "design-deleted", {
		M.icon("trash", 22, L.faint),
		ui.text { "This design was deleted", text_size = 14, weight = 600, color = L.fg, font = Look.UI, align = "center" },
		ui.text { `“{o.name}” is gone. Close this tab with its × or Ctrl+W.`, text_size = 12, color = L.muted, font = Look.UI, align = "center", wrap = "balance", w = 300, line_height = 18 },
		if o.other
			then ui.row { gap = 8, items = "center", mt = 6, Kit.button(L, { id = "design-deleted-all", label = "All designs", icon = "layers", on_click = o.other }) }
			else ui.div {},
	})
end

return M
