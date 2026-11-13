--!strict
-- The hand cursor on everything the person can click, in one place.
--
-- zgx makes the script's `ui` table read-only, so this can't patch it.
-- Instead it gives a `ui` of its own: everything reads through to the real
-- one, except `ui.button` and the containers that can take an `on_click`
-- (`ui.div`, `ui.row`, `ui.column`). A node that is clickable and names no
-- cursor gets `cursor = "pointer"`; one that names a cursor keeps it
-- (resize handles' ew_resize, scrub labels, the eyedropper's crosshair),
-- and a disabled one keeps the arrow. Text fields and the Canvas (a
-- `ui.overlay` whose tools set their own cursors) aren't touched.
--
-- Each file that builds UI starts with:
--   local ui = require("./pointer").ui      (tab/*.luau)
--   local ui = require("./tab/pointer").ui  (init.luau)

local real: any = ui

local function clickable(props: any, is_button: boolean): boolean
	if type(props) ~= "table" or props.cursor ~= nil or props.disabled == true then
		return false
	end
	-- `on_click` only: `on_press` also marks drag surfaces (the picker's
	-- colour area) and click-swallowing containers (toasts).
	return is_button or props.on_click ~= nil
end

local function wrap(name: string, is_button: boolean): any
	local original = real[name]
	return function(props: any, ...: any): any
		if clickable(props, is_button) then
			props.cursor = "pointer"
		end
		return original(props, ...)
	end
end

local proxy: any = setmetatable({
	button = wrap("button", true),
	div = wrap("div", false),
	row = wrap("row", false),
	column = wrap("column", false),
}, { __index = real })

return { ui = proxy }
