--!strict
-- The window's share of a Design's assets (pure/CONTRACT.md Changes, "Google
-- Fonts and pictures from bytes"), set up once by init.luau, tab or no tab:
--   - fonts: the faces the service fetched (`fonts` → `web`), each loaded
--     once here (`font_get` → `ui.load_font { base64 }`), so the Canvas and
--     screenshots draw what the service measured; then every root is drawn
--     again;
--   - pictures: `img:<key>` bytes from `image_get`, decoded once into a
--     Bitmap (draw.luau keeps them by key);
--   - pictures a Design names by a local path, after an import: picked by
--     the person and sent with `image_put`, where the window can read bytes.

local Draw = require("./draw")
local Guard = require("./guard")

local M = {}

local loaded: { [string]: boolean } = {}

function M.register(zeron: any)
	local service = Guard.service(zeron.service())

	-- Pictures: the service's bytes (any tab's source may set its own too).
	if not Draw.fetch then
		Draw.fetch = function(key: string, got: (b64: string?) -> ())
			service:call("image_get", { key = key }):after(function(r: any)
				got(if type(r) == "table" then r.base64 else nil)
			end, function()
				got(nil)
			end)
		end
	end

	-- Fonts.
	local function load_fonts()
		service:call("fonts", {}):after(function(r: any)
			local web = if type(r) == "table" then r.web else nil
			if type(web) ~= "table" then
				return
			end
			for _, f in web do
				local key = f.key
				if type(key) == "string" and not loaded[key] then
					loaded[key] = true
					service:call("font_get", { key = key }):after(function(face: any)
						if type(face) ~= "table" or type(face.base64) ~= "string" then
							loaded[key] = nil
							return
						end
						local ok, promise = pcall(ui.load_font, { base64 = face.base64 })
						if not ok then
							loaded[key] = nil
							return
						end
						promise:after(function()
							Draw.redraw_all()
						end, function()
							loaded[key] = nil
						end)
					end, function()
						loaded[key] = nil
					end)
				end
			end
		end, function() end)
	end
	load_fonts()
	service:on("fonts", function()
		load_fonts()
	end)
end

-- A file's bytes in base64: `ui.read_file(file, { base64 = true })` (zgx
-- #2096). An older zgx ignores the option and reads text, which isn't
-- base64: then `done(nil)`.
local function read_base64(file: any, done: (b64: string?) -> ())
	local ok, promise = pcall(ui.read_file, file, { base64 = true } :: any)
	if not ok then
		done(nil)
		return
	end
	promise:after(function(data: string)
		if type(data) == "string" and #data > 0 and not string.find(data, "[^%w%+/=\r\n]") then
			done(data)
		else
			done(nil)
		end
	end, function()
		done(nil)
	end)
end
M.read_base64 = read_base64

-- After an import: the pictures it names by a local path, picked by the
-- person and stored (`image_put {did, url, base64}`). Answers what it did.
function M.put_pictures(zeron: any, did: string, urls: { string }, done: (msg: string) -> ())
	if #urls == 0 then
		done("")
		return
	end
	local service = Guard.service(zeron.service())
	ui.open_files({ title = `Pick the Design's pictures ({#urls})`, multiple = true } :: any):after(function(files: any)
		-- Matched by file name (a Design names them by a path).
		local by_name: { [string]: any } = {}
		for _, f in files or {} do
			local name = if type(f) == "table" then (f.name or f.path) else tostring(f)
			by_name[string.lower(string.match(name, "[^/\\]+$") or name)] = f
		end
		local stored, unreadable, left = 0, 0, #urls
		local function one()
			left -= 1
			if left == 0 then
				done(if unreadable > 0
					then `{stored} of {#urls} picture(s) stored; {unreadable} couldn't be read as bytes (this zgx reads files as text).`
					else `{stored} of {#urls} picture(s) stored.`)
			end
		end
		for _, url in urls do
			local base = string.lower(string.match(url, "[^/\\]+$") or url)
			local f = by_name[base]
			if not f then
				one()
				continue
			end
			read_base64(f, function(b64: string?)
				if not b64 then
					unreadable += 1
					one()
					return
				end
				service:call("image_put", { did = did, url = url, base64 = b64 }):after(function()
					stored += 1
					one()
				end, function()
					one()
				end)
			end)
		end
	end, function() end)
end

return M
