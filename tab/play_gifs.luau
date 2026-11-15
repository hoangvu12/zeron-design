--!strict
local ui = require("./pointer").ui
-- Play's playing GIFs (tab/gif.luau plans them; pure/anim/f7/gif/README.md,
-- pure/anim/f7/followups/README.md). Out of play.luau, whose main function
-- is at Luau's 200-locals limit.
--
--   PlayGifs.layer(root, hide, counted?)  the GIFs of a layer (or a driver's
--       look): { gifs, ids, ver, any }. One whose picture isn't decoded yet
--       is asked for; once it is, the plan is made again and `ver` moves, so
--       the canvas draws again without it and the element appears.
--   PlayGifs.add(kids, gl, sid, org, z, root, hide)  the elements, into a
--       layer's children (in a box that's built again when `ver` moves, when
--       some are still to come).
--   PlayGifs.look(canvas, gl, sid, org, z, root, ext, opacity)  a driver's
--       look (hover/press) with its GIFs over it, faded as one.

local Draw = require("./draw")
local Gif = require("./gif")

local M = {}

-- One playing GIF over its layer's canvas: a box cut to what shows of it, the
-- picture (zgx plays it), and the small canvas of what paints over it.
-- `org`: the layer element's Canvas origin.
function M.element(e: any, sid: string, org: any, z: number, lroot: any, live: any): Node
	local src: any = e.url
	if e.key then
		src = Draw.images[e.key]
	end
	local cx, cy, cw, ch = e.clip[1], e.clip[2], e.clip[3], e.clip[4]
	local kids: any = {
		id = `play-gif-{sid}-{e.id}`,
		absolute = true,
		left = (cx - org.x) * z,
		top = (cy - org.y) * z,
		w = cw * z,
		h = ch * z,
		overflow = "hidden",
		pointer_events = "none",
		ui.image {
			absolute = true,
			left = (e.box[1] - cx) * z,
			top = (e.box[2] - cy) * z,
			w = e.box[3] * z,
			h = e.box[4] * z,
			src = src,
			fit = e.fit,
			rounded = if e.radius > 0 then e.radius * z else nil,
			opacity = if e.op < 1 then e.op else nil,
			pointer_events = "none",
		},
	}
	if e.over then
		table.insert(kids, ui.canvas {
			id = `play-gif-over-{sid}-{e.id}`,
			absolute = true,
			left = 0,
			top = 0,
			w = cw * z,
			h = ch * z,
			pointer_events = "none",
			view = function(): any
				return { x = -cx * z, y = -cy * z, zoom = z }
			end,
			draw = function(c: Canvas)
				Draw.draw_root(c, lroot, { hide = live.hide, gifs = live.gifs, after = e.i })
			end,
		})
	end
	return ui.div(kids)
end

local function ready(key: string): boolean
	local b = Draw.images[key]
	if b == nil then
		Draw.want(key)
	end
	return b ~= nil and b ~= false
end

local function waiting(key: string): boolean
	return Draw.images[key] == nil
end

export type Layer = { gifs: { any }, ids: { [string]: boolean }?, ver: any, any: boolean, late: boolean }

function M.layer(root: any, hide: { [string]: boolean }?, counted: ((n: number) -> ())?): Layer
	local gifs, later = Gif.plan(root, hide, ready, nil, waiting)
	local gl: Layer = { gifs = gifs, ids = Gif.ids(gifs), ver = ui.use_state(0), any = #gifs > 0 or #later > 0, late = #later > 0 }
	if counted then
		counted(#gifs)
	end
	if #later == 0 then
		return gl
	end
	local want: { [string]: boolean } = {}
	for _, k in later do
		want[k] = true
	end
	local function heard(key: string)
		if not want[key] then
			return
		end
		want[key] = nil
		gl.gifs = Gif.plan(root, hide, ready)
		gl.ids = Gif.ids(gl.gifs)
		if counted then
			counted(#gl.gifs)
		end
		gl.ver:set(gl.ver:peek() + 1)
		if next(want) == nil then
			-- (not while Draw goes through its listeners)
			ui.after(0, function()
				local i = table.find(Draw.listeners, heard)
				if i then
					table.remove(Draw.listeners, i)
				end
			end)
		end
	end
	table.insert(Draw.listeners, heard)
	-- (a picture that can't be decoded never tells: let go after a while)
	ui.after(30000, function()
		local i = table.find(Draw.listeners, heard)
		if i then
			table.remove(Draw.listeners, i)
		end
	end)
	return gl
end

local function elements(gl: Layer, sid: string, org: any, z: number, root: any, hide: any): { Node }
	local out = {}
	for _, e in gl.gifs do
		table.insert(out, M.element(e, sid, org, z, root, { hide = hide, gifs = gl.ids }))
	end
	return out
end

function M.add(kids: { any }, gl: Layer, sid: string, org: any, z: number, root: any, hide: any)
	if not gl.late then
		for _, n in elements(gl, sid, org, z, root, hide) do
			table.insert(kids, n)
		end
		return
	end
	table.insert(kids, ui.presence(function(): string
		return tostring(gl.ver:get())
	end, function(_: string): Node
		local box: any = elements(gl, sid, org, z, root, hide)
		box.id = `play-gifs-{sid}-{math.floor(org.x)}-{math.floor(org.y)}`
		box.absolute = true
		box.left = 0
		box.top = 0
		box.w = org.w * z
		box.h = org.h * z
		box.pointer_events = "none"
		return ui.div(box)
	end))
end

function M.look(canvas: Node, gl: Layer, sid: string, org: any, z: number, root: any, ext: { number }, opacity: any): Node
	if not gl.any then
		return canvas
	end
	local kids: any = {
		absolute = true,
		left = 0,
		top = 0,
		w = ext[3] * z,
		h = ext[4] * z,
		pointer_events = "none",
		opacity = opacity,
		canvas,
	}
	M.add(kids, gl, sid, { x = org.x, y = org.y, w = ext[3], h = ext[4] }, z, root, nil)
	return ui.div(kids)
end

return M
