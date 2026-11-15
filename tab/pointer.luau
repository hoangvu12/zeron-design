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

-- Enter or Space on a focused button (reached with Tab): the same jump as
-- above, since an edit that rebuilds the panel removes the focused button.
-- The press is a keyboard one when the button holds focus (a click no longer
-- gives it focus). Its key (id, else label) is remembered for a moment, and
-- the rebuilt button with that key takes focus back as it mounts.
local focused_key: string? = nil
local restore_key: string? = nil
local restore_seq = 0
local mounted_el: { [string]: any } = setmetatable({}, { __mode = "v" }) :: any

-- Whether keyboard focus is on a button now: the editor's shortcuts then
-- leave Enter and Space to it (the Canvas's Enter selects children, which
-- rebuilt the panel: focus jumped to Layer name and the button never ran).
local function button_focused(): boolean
	local key = focused_key
	if key == nil then
		return false
	end
	local el = mounted_el[key]
	return el ~= nil and el.mounted == true
end

local function chain(a: any, b: (...any) -> ()): any
	if a == nil then
		return b
	end
	if type(a) ~= "function" then
		return a -- an Action Rust runs: left alone
	end
	return function(...: any): any
		b(...)
		return a(...)
	end
end

local function keep_focus(props: any)
	local key = props.id or props.label
	if type(key) ~= "string" or props.disabled == true then
		return
	end
	if props.on_click ~= nil and type(props.on_click) ~= "function" then
		return
	end
	props.on_focus = chain(props.on_focus, function()
		focused_key = key
	end)
	props.on_blur = chain(props.on_blur, function()
		if focused_key == key then
			focused_key = nil
		end
	end)
	local click = props.on_click
	if click then
		props.on_click = function(...: any): any
			if focused_key == key then
				restore_key = key
				restore_seq += 1
				local seq = restore_seq
				real.after(0.5, function()
					if restore_seq == seq then
						restore_key = nil
					end
				end)
			end
			return click(...)
		end
	end
	local mount = props.on_mount
	props.on_mount = function(el: any)
		mounted_el[key] = el
		if restore_key == key then
			restore_key = nil
			pcall(function()
				el:focus({ scroll = false })
			end)
		end
		if mount then
			mount(el)
		end
	end
end

local function wrap(name: string, is_button: boolean): any
	local original = real[name]
	return function(props: any, ...: any): any
		if clickable(props, is_button) then
			props.cursor = "pointer"
		end
		-- A button pressed leaves focus where it was (the Canvas, a layer row,
		-- a field), as pen's and the Mac's buttons do. Taking it, an edit that
		-- builds its panel again (Add stroke, a Fill's eye…) removed the
		-- focused button and zgx moved focus on to the next Tab stop: the new
		-- panel's first field, Layer name. (Tab still reaches buttons.)
		if is_button and type(props) == "table" and props.focus_on_press == nil then
			props.focus_on_press = false
		end
		if is_button and type(props) == "table" then
			keep_focus(props)
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

return { ui = proxy, button_focused = button_focused }
