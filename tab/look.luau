--!strict
-- The editor's look, from the redesign (the Design "Design (pure) — Editor
-- UI", its Tokens by name): floating islands over the Canvas (r14 panels,
-- r12 bars, a 1px rim, a soft shadow), 16 from the window's edges and 8 from
-- each other; 28px fields r8, 12px text; solid menus r10. Rubik for the
-- interface (bundled, fonts/), Roboto Mono for the zoom level.
-- `Look.of(dark)` gives the colours.
--
-- Older keys stay (the panels name them); each now takes a token's value.

local M = {}

M.EDGE = 16 -- from the window's edges to the islands
M.INSET = 8 -- between islands
M.LEFT_W = 260
M.RIGHT_W = 272
M.RIGHT_R = 14
M.BAR_R = 12 -- the 40-high islands: title pill, rail, theme bar, zoom pill
M.RAIL_W = 40
M.BAR_H = 40
-- (No agent composer under the left panel: Zeron's chat is the agent's.)
M.COMPOSER_H = 0
M.UI = "Rubik"
M.FIELD = "Rubik"
M.MONO = "Roboto Mono"

-- The redesign's Tokens, mode light / dark.
local T = {
	light = {
		canvas = "#f4f4f5",
		panel = "#fffffff7",
		panel_solid = "#ffffff",
		border = "#0000001a",
		field = "#0000000a",
		field_active = "#ffffff",
		fg = "#18181b",
		muted = "#52525b",
		faint = "#5f5f68",
		accent = "#4f5bff",
		accent_soft = "#4f5bff1f",
		accent_fg = "#3440d9",
		agent = "#c2551f",
		agent_soft = "#c2551f1a",
		agent_fg = "#a3441a",
		on_accent = "#ffffff",
		component = "#9b30e8",
		component_soft = "#9b30e814",
		instance = "#5b5fe8",
		danger = "#dc2626",
		guide = "#f43f5e",
		dot = "#0000002b",
		shadow = "#0000001f",
		hover = "#0000000a",
	},
	dark = {
		canvas = "#0e0e10",
		panel = "#1a1a1df7",
		panel_solid = "#1a1a1d",
		border = "#ffffff14",
		field = "#ffffff0d",
		field_active = "#ffffff1a",
		fg = "#ededef",
		muted = "#a1a1aa",
		faint = "#9898a3",
		accent = "#7c8cff",
		accent_soft = "#7c8cff29",
		accent_fg = "#aeb8ff",
		agent = "#f0915f",
		agent_soft = "#f0915f26",
		agent_fg = "#f7ae85",
		on_accent = "#0e0e10",
		component = "#d08cff",
		component_soft = "#d08cff1f",
		instance = "#a3a8ff",
		danger = "#f87171",
		guide = "#f43f5e",
		dot = "#ffffff2e",
		shadow = "#00000066",
		hover = "#ffffff0d",
	},
}

local function build(t: any, is_dark: boolean): any
	local L = table.clone(t)
	-- (the older names, each on a token)
	L.board = t.canvas
	-- (The Design's islands are 97% opaque over a 24px backdrop blur; without
	-- the blur, which would redraw the Canvas under every island at each pan,
	-- the solid panel is the closer look.)
	L.card = t.panel_solid
	L.rim = t.border
	L.fg_strong = t.fg
	L.title = t.fg
	L.val = t.fg
	L.pre = t.muted
	L.fg2 = t.muted
	L.fg3 = t.faint
	L.field_br = "#00000000"
	L.tab_on = t.field_active
	L.tgl_on = t.field_active
	L.tool_on = t.accent_soft
	L.tool_on_br = "#00000000"
	L.mut = t.field
	L.row_hover = t.field
	L.divider = t.border
	L.find_on = t.accent
	L.find_line = t.border
	L.search_bg = t.field
	L.table_head = "#00000000"
	L.theme_tab = t.field
	L.search_br = "#00000000"
	L.primary = t.accent
	L.primary_fg = t.on_accent
	L.menu_line = t.border
	L.zoom_pop = t.panel_solid
	L.zoom_br = t.border
	L.zoom_on = t.field_active
	L.keycap = t.field
	L.keycap_br = t.border
	L.keycap_fg = t.muted
	L.tab_icon_on = t.accent_soft
	L.row_sel = t.accent_soft
	L.row_sel_fg = t.accent_fg
	L.row_in_sel = if is_dark then "#7c8cff0f" else "#4f5bff0a"
	L.sel_soft = t.accent_soft
	L.line = t.border
	L.btn = t.field
	L.btn_br = t.border
	L.chk_on = t.accent
	L.chk_off = "#00000000"
	L.chk_br = if is_dark then "#ffffff33" else "#00000033"
	L.radio_br = L.chk_br
	L.dot_grid = t.dot
	L.dot = t.muted -- the alignment grid's dots
	L.dot_on = t.accent
	L.flex_on = t.accent_soft
	L.chk_mark = t.on_accent
	L.blue = t.accent
	L.magenta = t.component
	L.violet = t.instance
	L.pop = t.panel_solid
	L.pop_hl = t.field_active
	L.pop_shadow = { { y = 12, blur = 32, spread = -8, color = t.shadow }, { y = 2, blur = 6, color = if is_dark then "#0000004d" else "#0000000f" } }
	L.island_shadow = { y = 12, blur = 32, spread = -8, color = t.shadow }
	L.sel_fld = t.field_active
	-- (tooltips: a light pill over the dark editor, a dark one over the light)
	L.tip_bg = if is_dark then "#ededef" else "#18181b"
	L.tip_fg = if is_dark then "#18181b" else "#fafafa"
	return L
end

local light = build(T.light, false)
local dark = build(T.dark, true)

function M.of(is_dark: boolean?): any
	return if is_dark then dark else light
end

return M
