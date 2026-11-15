--!strict
-- GIF layers (pure/anim/f7/PLAN.md §2, notes in pure/anim/f7/gif/README.md),
-- pure: which GIF fills of a Screen layer play in Play, and where.
--
-- A GIF is an image paint marked `gif` by the scene (engine/scene.luau: the
-- stored picture is a GIF, or a web url ends in .gif). The board and every
-- canvas draw its first frame (`c:image` draws no other: the board canvas is
-- never redrawn to animate, pure/anim/m0-perf.md). Play draws the layer's
-- canvas without the GIFs that play (Draw's `gifs`) and puts each one over
-- it as a `ui.image` element, which zgx plays on its own (it pauses one off
-- screen); then, cut to the GIF's box, a small canvas of what paints over
-- it (Draw's `after`): its later paints, what it holds, its stroke, later
-- layers.
--
-- A turned or flipped GIF plays too: every canvas draws a picture upright in
-- its item's bounding box (zgx's `c:image` has no transform), and so does the
-- element. Not played (first frame, as on the board): GIFs inside something
-- turned that clips (that clip isn't a box), in a Smart Animate or Change to
-- frame, past the cap, and until their picture is decoded (`plan`'s second
-- result lists those, so Play can add them once they are).
--
-- (pure/anim/f7/followups/README.md: turned GIFs, the area cap, late ones)

local Draw = require("./draw")

local M = {}

-- GIFs playing at once per Screen layer (each a live element with its own
-- frame stream): always `MIN`, then more while their boxes add up to at most
-- `AREA` (Canvas units²; a sticker or an icon costs little), up to `CAP`.
M.MIN = 4
M.CAP = 16
M.AREA = 4 * 1024 * 1024

local function gif_paint(it: any): (any?, number)
	for k, p in it.fill or {} do
		if p.k == "image" and p.gif then
			return p, k
		end
	end
	return nil, 0
end

-- The `img:` key, or the web url, a paint shows; nil when it can't play.
local function source(p: any): (string?, string?)
	local src = p.src or ""
	if string.sub(src, 1, 4) == "img:" then
		return string.sub(src, 5), nil
	end
	if string.match(string.lower(src), "^https?://") then
		return nil, src
	end
	return nil, nil
end

local function turned(it: any): boolean
	local x = it.xf
	if not x then
		return false
	end
	-- (an affine: anything but a plain move is turned, flipped or skewed)
	return math.abs((x.a or 1) - 1) > 1e-9 or math.abs(x.b or 0) > 1e-9 or math.abs(x.c or 0) > 1e-9 or math.abs((x.d or 1) - 1) > 1e-9
end

local function intersect(a: { number }?, b: { number }): { number }
	if not a then
		return b
	end
	local x0, y0 = math.max(a[1], b[1]), math.max(a[2], b[2])
	local x1, y1 = math.min(a[1] + a[3], b[1] + b[3]), math.min(a[2] + a[4], b[2] + b[4])
	return { x0, y0, math.max(0, x1 - x0), math.max(0, y1 - y0) }
end

local function overlaps(a: { number }, b: { number }): boolean
	return a[1] < b[1] + b[3] and b[1] < a[1] + a[3] and a[2] < b[2] + b[4] and b[2] < a[2] + a[4]
end

export type Entry = {
	i: number, -- the item's index in the root given
	id: string,
	key: string?, -- an `img:` picture's key
	url: string?, -- or a web url
	box: { number }, -- x, y, w, h (Canvas units)
	clip: { number }, -- what shows of it: its box cut by the clips around it
	fit: string, -- ui.image's fit
	radius: number,
	op: number, -- its opacity with what holds it
	over: boolean, -- something paints over it (Draw's `after` canvas)
}

-- The GIFs of `root` (a Scroll.layer_root, or any root) that play, in paint
-- order: at most `cap` when given, else as M.MIN / M.AREA / M.CAP say.
-- `hide`: ids the layer's canvas leaves out (with what they hold).
-- `ready(key)`: whether a picture is decoded (Draw.images); `waiting(key)`:
-- whether one not ready yet still may be (then it's in the second result).
function M.plan(root: any, hide: { [string]: boolean }?, ready: ((key: string) -> boolean)?, cap: number?, waiting: ((key: string) -> boolean)?): ({ Entry }, { string })
	local nodes = root.nodes or {}
	local out: { Entry } = {}
	local later: { string } = {}
	local limit = cap or M.CAP
	local area = 0
	local function room(box: { number }): boolean
		if #out >= limit then
			return false
		end
		if cap or #out < M.MIN then
			return true
		end
		return area + box[3] * box[4] <= M.AREA
	end
	-- what holds item i: { last, op, clip, turned, stroked } (open ranges)
	local stack: { any } = {}
	local skip_to = 0
	for i, it in nodes do
		while #stack > 0 and stack[#stack].last < i do
			table.remove(stack)
		end
		local top = stack[#stack]
		if i <= skip_to then
			continue
		end
		if (hide and hide[it.id]) or it.hidden then
			skip_to = i + (it.n or 0)
			continue
		end
		local op = (if top then top.op else 1) * (it.op or 1)
		-- (inside a turned clip: the canvas clips by the turned shape)
		local bent = top ~= nil and top.turned
		local x, y, w, h = Draw.canvas_bounds(it, Draw.local_map(it))
		local box = { x, y, w, h }
		local p, _ = gif_paint(it)
		if p and not bent and room(box) and it.t ~= "text" then
			local key, url = source(p)
			if key and not (ready == nil or ready(key)) and waiting and waiting(key) and not table.find(later, key) then
				table.insert(later, key)
			end
			if (key and (ready == nil or ready(key))) or url then
				local radius = if it.shape and it.shape.k == "rect" and it.shape.r then (it.shape.r[1] or 0) else 0
				local fit = if p.mode == "contain" then "contain" elseif p.mode == "stretch" then "fill" else "cover"
				local clip = intersect(if top then top.clip else nil, box)
				-- over it: its later paints, what it holds, its stroke, the
				-- stroke of what holds it, or a later item over its box
				local over = (it.n or 0) > 0 or it.stroke ~= nil or (top ~= nil and top.stroked)
				if not over then
					local seen = false
					for _, q in it.fill do
						if q == p then
							seen = true
						elseif seen then
							over = true
							break
						end
					end
				end
				if not over then
					for j = i + (it.n or 0) + 1, #nodes do
						local o = nodes[j]
						if not o.hidden and not (hide and hide[o.id]) and o.box then
							local ox, oy, ow, oh = Draw.canvas_bounds(o, Draw.local_map(o))
							if overlaps({ ox, oy, ow, oh }, clip) then
								over = true
								break
							end
						end
					end
				end
				if clip[3] > 0 and clip[4] > 0 then
					area += box[3] * box[4]
					table.insert(out, {
						i = i,
						id = it.id,
						key = key,
						url = url,
						box = box,
						clip = clip,
						fit = fit,
						radius = radius,
						op = op * (p.op or 1),
						over = over,
					})
				end
			end
		end
		if (it.n or 0) > 0 then
			local clip = if top then top.clip else nil
			if it.clip then
				clip = intersect(clip, box)
			end
			table.insert(stack, {
				last = i + (it.n or 0),
				op = op,
				clip = clip,
				turned = bent or (it.clip == true and turned(it)),
				stroked = (top ~= nil and top.stroked) or it.stroke ~= nil,
			})
		end
	end
	return out, later
end

-- The ids of the entries (Draw's `gifs`: their GIF paints left out).
function M.ids(list: { Entry }): { [string]: boolean }?
	if #list == 0 then
		return nil
	end
	local s = {}
	for _, e in list do
		s[e.id] = true
	end
	return s
end

-- Whether a root shows any GIF paint (the editor's badge, Layers).
function M.has_gif(it: any): boolean
	local p = gif_paint(it)
	return p ~= nil
end

return M
