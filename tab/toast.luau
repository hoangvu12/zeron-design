--!strict
-- The hand cursor on clickable controls (zgx's ui is read-only: see pointer.luau).
local ui = require("./pointer").ui
-- The editor's toasts (the redesign's Board · Home and states, "Toasts"):
-- cards 360 wide, r12, panel_solid with a 1px rim and the island shadow,
-- p 12/14: an icon (16), the title 13/500 and a body 12 muted, an action
-- in accent_fg 12/600 at the right. Stacked at the editor's bottom centre,
-- newest at the bottom; each goes after 4 s (6 s with an action), or on ✕.
--
--   Toast.show { icon = "image"?, title = "12 of 14 pictures stored", body = "…"?,
--                action = { label = "Pick again", run = f }?, tone = "info"|"danger"|"success"? }
--   Toast.Stack { L = L }   -- absolute; mounted in the editor's root (shell)
--
-- The list is module-wide: `show` works from anywhere, and every editor
-- the window shows draws the same stack.

local Look = require("./look")
local States = require("./states")

local M = {}

local MAX = 4
local LIFE_MS = 4000
local LIFE_ACTION_MS = 6000

export type Show = {
	icon: string?,
	title: string,
	body: string?,
	action: { label: string, run: () -> () }?,
	tone: ("info" | "danger" | "success")?,
}

-- (A state holds no functions: the records are plain, the actions kept here.)
local list = ui.state("design.toasts", {} :: { any })
local runs: { [number]: () -> () } = {}
local made = 0

function M.dismiss(id: number)
	runs[id] = nil
	local now = list:peek()
	local out = {}
	for _, t in now do
		if t.id ~= id then
			table.insert(out, t)
		end
	end
	if #out ~= #now then
		list:set(out)
	end
end

function M.show(o: Show)
	made += 1
	local id = made
	local tone = o.tone or "info"
	local icon = o.icon or (if tone == "danger" then "alert" elseif tone == "success" then "check" else "info")
	local l = table.clone(list:peek())
	table.insert(l, { id = id, icon = icon, title = o.title, body = o.body, tone = tone, action = if o.action then o.action.label else nil })
	while #l > MAX do
		runs[l[1].id] = nil
		table.remove(l, 1)
	end
	if o.action then
		runs[id] = o.action.run
	end
	list:set(l)
	ui.after(if o.action then LIFE_ACTION_MS else LIFE_MS, function()
		M.dismiss(id)
	end)
end

function M.clear()
	table.clear(runs)
	list:set({})
end

local function card(L: any, t: any): Node
	local tint = if t.tone == "danger" then L.danger else L.accent
	local r: any = {
		id = `toast-{t.id}`,
		role = "status",
		w = 360,
		px = 14,
		py = 12,
		gap = 10,
		items = "start",
		rounded = 12,
		bg = L.panel_solid,
		border = 1,
		border_color = L.border,
		shadow = L.pop_shadow,
		pointer_events = "auto",
		on_press = function() end,
		ui.div { pt = 1, shrink = 0, States.icon(t.icon, 16, tint) },
		ui.column {
			grow = 1,
			min_w = 0,
			gap = 2,
			ui.text { t.title, text_size = 13, weight = 500, color = L.fg, font = Look.UI, wrap = true, w_full = true },
			if t.body then ui.text { t.body, text_size = 12, color = L.muted, font = Look.UI, wrap = true, w_full = true, line_height = 17 } else ui.div {},
		},
	}
	if t.action then
		table.insert(
			r,
			ui.button {
				id = `toast-{t.id}-action`,
				label = t.action,
				shrink = 0,
				p = 0,
				border = 0,
				bg = "#00000000",
				hover = { opacity = 0.8 },
				on_click = function()
					local run = runs[t.id]
					M.dismiss(t.id)
					if run then
						run()
					end
				end,
				ui.text { t.action, text_size = 12, weight = 600, color = L.accent_fg, font = Look.UI },
			}
		)
	else
		table.insert(
			r,
			ui.button {
				id = `toast-{t.id}-close`,
				label = "Dismiss",
				shrink = 0,
				w = 16,
				h = 16,
				p = 0,
				border = 0,
				rounded = 4,
				items = "center",
				justify = "center",
				bg = "#00000000",
				color = L.faint,
				hover = { bg = L.field },
				on_click = function()
					M.dismiss(t.id)
				end,
				States.icon("x", 12),
			}
		)
	end
	return ui.row(r)
end

-- The stack: absolute along the bottom of its containing block (the
-- editor's root), centred, 16 above its edge; lets the pointer through
-- except over a card.
function M.Stack(props: { L: any, bottom: number? }): Node
	local L = props.L
	return ui.column {
		id = "design-toasts",
		absolute = true,
		left = 0,
		right = 0,
		bottom = props.bottom or 16,
		items = "center",
		pointer_events = "none",
		ui.each(list, function(t: any): Node
			return card(L, t)
		end, {
			key = function(t: any): number
				return t.id
			end,
			animate = { duration = 220, ease = "out(3)" },
			enter = { opacity = { 0, 1 }, y = { 8, 0 }, duration = 180 },
			exit = { opacity = { 1, 0 }, duration = 140 },
			w_full = true,
			items = "center",
			gap = 8,
			pointer_events = "none",
		}),
	}
end

return M
