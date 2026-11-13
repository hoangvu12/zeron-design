--!nonstrict
-- Wiring the engine to the service's helpers: the text measurer and the
-- plugin's own font files (listed here, as a service can't list its folder).

local Text = require("./text")

local M = {}

-- Font files shipped in the plugin's fonts/ (the window loads the same).
-- Geist, Geist Mono and Instrument Serif are the app's own: every window
-- and zeron.measure_text has them already.
M.FONT_FILES = {}

M.loaded = {} :: { [string]: { string } }

function M.fonts(zeron: any)
	Text.use(zeron.measure_text)
	for _, file in M.FONT_FILES do
		if not M.loaded[file] then
			local ok, families = pcall(zeron.load_font, file)
			if ok then
				M.loaded[file] = families
				for _, f in families do
					Text.known(f)
				end
			else
				print("font " .. file .. ": " .. tostring(families))
			end
		end
	end
end

return M
