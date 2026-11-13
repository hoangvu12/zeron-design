--!strict
-- Screenshots for agents (pure/CONTRACT.md §9): the service emits `render`,
-- this draws the root with the Canvas's own draw function through
-- `ui.render_canvas` and answers `render_done`. Registered by init.luau at
-- load, so it works with no tab open.

local Draw = require("./draw")
local Guard = require("./guard")

local M = {}

-- `scene` reply → the root to draw, and its box.
local function root_of(reply: any, id: string): any?
	for _, r in (reply and reply.roots) or {} do
		if r.id == id then
			return r
		end
	end
	return nil
end

function M.register(zeron: any)
	local service = Guard.service(zeron.service())
	service:on("render", function(e: any)
		if type(e) ~= "table" or not e.req then
			return
		end
		local function fail(why: string)
			service:call("render_done", { req = e.req, error = why }):after(function() end, function() end)
		end
		-- Only the node shot and what's inside it: a row of a big board
		-- comes as its few items, not the board's thousands.
		service:call("scene", { did = e.did, roots = { e.root }, node = e.id, theme = e.theme }):after(function(reply: any)
			local root = root_of(reply, e.root)
			if not root or not root.nodes or not root.nodes[1] then
				fail("not_found: no such root")
				return
			end
			-- (Its pictures decoded first: a render draws what's there.)
			Draw.ensure(Draw.picture_keys(root.nodes), function()
				M.draw_root_png(service, e, root, fail)
			end)
		end, function(err: any)
			fail(tostring(err))
		end)
	end)
end

function M.draw_root_png(service: any, e: any, root: any, fail: (string) -> ())
	do
			local b = root.nodes[1].box
			local x, y, w, h = e.x or b.x, e.y or b.y, e.w or b.w, e.h or b.h
			local scale = e.scale or math.min(1, 800 / math.max(w, h, 1))
			-- (The drawing runs now, inside this handler's time; the service
			-- hears how long, so a board too big to draw in it shows.)
			local t0 = os.clock()
			local ok, promise = pcall(ui.render_canvas, function(c: Canvas)
				Draw.draw_root(c, root)
			end, { width = w, height = h, scale = scale, x = x, y = y })
			local ms = (os.clock() - t0) * 1000
			if not ok then
				fail(`render: {promise}`)
				return
			end
			promise:after(function(png: string)
				service:call("render_done", { req = e.req, png = png, ms = ms, items = #root.nodes }):after(function() end, function() end)
			end, function(err: any)
				fail(`render: {err}`)
			end)
	end
end

return M
