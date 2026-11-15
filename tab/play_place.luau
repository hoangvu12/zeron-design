--!strict
-- Where Play shows a Screen (step 6 P1, pure/anim/f6/PLAN.md): the scaling
-- menu's choices and the placement each gives. Pure (no ui): Play calls it,
-- tests/play_place.luau checks every mode.
--
-- Two menus, as Figma's (f6/figma/README.md):
-- - **plain** (no device, a custom size, or the frame hidden): Actual size,
--   Fit width and height, Fit width, Fill screen (`fit` choices);
-- - **framed** (a preset with a frame, shown): Fit device on screen, Zoom
--   device to fill screen, Show device at 100% (`device_fit` choices). The
--   frame's insets count, so the device fits *with* its frame.
-- The session's choice overrides the Design's (`prototype.fit` /
-- `deviceFit`); Play keeps it in ui.state("design.{id}.play_fit").

local DeviceFrame = require("./device_frame")

local M = {}

M.MARGIN = 24
-- Each Screen layer is one canvas the size of its content at the zoom, and
-- Play keeps several mounted (the one shown, those mounted ahead, a new
-- place's while it draws). zgx won't raster one over 32 MiB, and at 3 M
-- points each (1.5× display) the GPU ran out of memory (zgx-run: "GPU error:
-- Out of Memory", then a panic). The modes that zoom up (Fit width, Fill
-- screen, Zoom device to fill) stop where the Screen's canvas would pass
-- this many points, about a 1440 × 900 Screen at 100% (never under 100%).
M.RASTER_PTS = 1500000
-- (step 6 P6, T1's finding) The real limit is zgx's raster cache: 32 MiB
-- (zgx-gpu canvas.rs `BUDGET`), shared by every canvas the window shows,
-- in device pixels (4 bytes each). When the mounted canvases add up past
-- it, each frame evicts and rasters them all again (T1: 220-320 ms
-- frames). So the cap counts device pixels: a Screen's canvas may take a
-- `MOUNTED`th of the share Screens get, at the display's scale (pixels a
-- point, ×2 on a 2× display: 4× the pixels). At 1× it's RASTER_PTS as
-- before; at 1.5× 0.70 M points, at 2× 0.39 M. The Screens mounted ahead
-- are also counted against the share (M.fits), so their total stays in it.
M.CACHE_PX = 32 * 1024 * 1024 / 4
-- (the rest: the device frame, overlays, the bar, the editor's own canvases)
M.SCREENS_SHARE = 0.75
-- (the shown Screen, a fresh copy while re-placing, and those mounted ahead)
M.MOUNTED = 4

-- The scale Play assumes until it has measured the display's, and where it
-- can't. Play measures it with an element's snapshot, which zgx takes on
-- macOS only; on Windows nothing tells Luau the scale. Zeron there is
-- per-monitor DPI aware, so it rasters at the display's scale: 1.5 is
-- Windows' usual laptop default (and this machine's, 144 DPI). A 2×
-- Windows display can still pass the cache. (`design.display_scale`, a
-- number, overrides it: the hidden-desktop harness renders at 1×.)
M.DEFAULT_SCALE = 1.5

-- The most points a Screen's canvas may have at display scale `scale`.
function M.cap_pts(scale: number?): number
	local s = math.max(1, scale or 1)
	return math.min(M.RASTER_PTS, M.CACHE_PX * M.SCREENS_SHARE / (M.MOUNTED * s * s))
end

-- The device pixels a placed Screen's canvas takes (`pl`: M.place's): its
-- whole root at the zoom, scrolled parts too (one canvas holds them).
function M.screen_px(pl: any, scale: number?): number
	local s = math.max(1, scale or 1)
	return pl.b.w * pl.b.h * pl.z * pl.z * s * s
end

-- Whether a Screen of `add` device pixels may be mounted beside `used`.
function M.fits(used: number, add: number): boolean
	return used + add <= M.CACHE_PX * M.SCREENS_SHARE
end

-- The plain choices, in Figma's order and groups (Z cycles them in order).
M.PLAIN = {
	{ name = "actual", label = "Actual size (100%)", group = "Recommended" },
	{ name = "fit", label = "Fit width and height", group = "Recommended" },
	{ name = "width", label = "Fit width", group = "Other scaling options" },
	{ name = "fill", label = "Fill screen", group = "Other scaling options" },
	-- (step 6 P5) the Screen laid out again at the window's size (Z skips it:
	-- each press would lay the Screen out again)
	{ name = "responsive", label = "Responsive", group = "Other scaling options", noz = true },
}
-- (step 6 P5) A framed device's content: Fixed size (the Screen as
-- designed, cropped and scrolled) or Responsive (laid out at the device's
-- size). Picking one writes the session's `fit`.
M.CONTENT = {
	{ name = "fit", label = "Fixed size", group = "Recommended" },
	{ name = "responsive", label = "Responsive", group = "Recommended" },
}
-- The framed choices (the device switcher's; tab/scroll.luau DEVICE_FITS).
M.FRAMED = {
	{ name = "fit", label = "Fit device on screen", group = "Device" },
	{ name = "fill", label = "Zoom device to fill screen", group = "Device" },
	{ name = "actual", label = "Show device at 100%", group = "Device" },
}

local function one_of(list: { any }, v: any): boolean
	for _, c in list do
		if c.name == v then
			return true
		end
	end
	return false
end

-- The settings in force: the Design's device `dv` (Scroll.played's shape, or
-- nil) and the session's choice `sess` ({ fit?, dfit?, frame?, hints? }).
-- → { framed, fit, dfit, hints, inset? } (`inset` = the frame's { l, t, r, b }
-- in points when framed).
function M.settings(dv: any?, sess: any?): any
	local s = sess or {}
	local framed = false
	local inset = nil
	if dv and dv.frame and dv.w and dv.h then
		local show = if s.frame ~= nil then s.frame == true else dv.show_frame ~= false
		if show then
			local f = DeviceFrame.shapes(dv.frame, dv.w, dv.h, dv.rotate, dv.model)
			if f then
				framed, inset = true, f.inset
			end
		end
	end
	local fit = if one_of(M.PLAIN, s.fit) then s.fit else (dv and dv.fit)
	if not one_of(M.PLAIN, fit) then
		fit = "fit"
	end
	local dfit = if one_of(M.FRAMED, s.dfit) then s.dfit else (dv and dv.device_fit)
	if not one_of(M.FRAMED, dfit) then
		dfit = "fit"
	end
	-- (step 6 P5) `responsive`: the Screen is laid out at `M.responsive_size`
	return { framed = framed, fit = fit, dfit = dfit, hints = s.hints ~= false, inset = inset, responsive = fit == "responsive" }
end

-- (step 6 P5) The size a Responsive Screen is laid out at on a `sw` × `sh`
-- stage: the device's (rotated, as `dv` has it) when there is one, else the
-- stage less the margin (none in Play, as Figma's Responsive fills the
-- window; the Preview's 8). A window past the raster budget gets a smaller
-- size, the ratio kept, shown at 100% in the middle (see M.RASTER_PTS).
-- → w, h (whole points), or nil when not responsive or the stage isn't
-- measured yet.
function M.responsive_size(sw: number, sh: number, dv: any?, st: any): (number?, number?)
	if not st.responsive then
		return nil, nil
	end
	if dv and dv.w and dv.h then
		return math.max(1, math.floor(dv.w + 0.5)), math.max(1, math.floor(dv.h + 0.5))
	end
	if sw < 2 or sh < 2 then
		return nil, nil
	end
	local m = st.margin or 0
	local w, h = math.max(1, math.floor(sw - 2 * m)), math.max(1, math.floor(sh - 2 * m))
	local cap = st.cap or M.RASTER_PTS -- (step 6 P6: M.cap_pts at the display's scale)
	if w * h > cap then
		local k = math.sqrt(cap / (w * h))
		w, h = math.max(1, math.floor(w * k)), math.max(1, math.floor(h * k))
	end
	return w, h
end

-- The menu's choices for these settings, and the one picked.
function M.choices(st: any): ({ any }, string)
	if st.framed then
		return M.FRAMED, st.dfit
	end
	return M.PLAIN, st.fit
end

-- Z: the choice after `cur` in `list` (round).
function M.cycle(list: { any }, cur: string): string
	for k, c in list do
		if c.name == cur then
			for j = 1, #list do
				local nx = list[(k + j - 1) % #list + 1]
				if not nx.noz then
					return nx.name
				end
			end
		end
	end
	return list[1].name
end

-- Where a Screen with root box `b` ({ x, y, w, h }) sits on a `sw` × `sh`
-- stage, for device `dv` (or nil) and settings `st` (M.settings).
-- → { z, left, top, w, h, vw, vh, tall, b, mode, inset? }: the viewport on the
-- stage (`left`, `top`, `w`, `h`, in points), its size in Canvas units (`vw`,
-- `vh`), the zoom, and whether the Screen is taller than it (it scrolls).
-- `inset` (framed): the frame's reach past the viewport, in stage points.
function M.place(sw: number, sh: number, b: any, dv: any?, st: any): any
	local sized = dv ~= nil and dv.w ~= nil and dv.h ~= nil
	local vw, vh = (if sized then dv.w else b.w), (if sized then dv.h else b.h)
	vw, vh = math.max(1, vw), math.max(1, vh)
	local z
	local m = st.margin or M.MARGIN -- (step 6 P4: the Preview's is smaller)
	local il, it, ir, ib = 0, 0, 0, 0
	local mode
	if st.framed and st.inset then
		il, it, ir, ib = st.inset[1], st.inset[2], st.inset[3], st.inset[4]
		mode = "device-" .. st.dfit
		local fw, fh = vw + il + ir, vh + it + ib
		local aw, ah = math.max(1, sw - 2 * m), math.max(1, sh - 2 * m)
		if st.dfit == "actual" then
			z = 1
		elseif st.dfit == "fill" then
			-- (the device's screen fills the stage; the frame runs off it)
			m = 0
			z = math.min(sw / vw, sh / vh)
		else
			z = math.min(1, aw / fw, ah / fh)
		end
	else
		mode = st.fit
		if st.fit == "fill" then
			m = 0
		end
		-- (step 6 P5) Responsive: with a device, the device fits as in Fit
		-- (its Screen is laid out at its size); without one, the Screen was
		-- laid out at the stage's size (M.responsive_size) and shows at 100%
		if mode == "responsive" then
			if sized then
				mode = "fit"
			else
				m = st.margin or 0
			end
		end
		local aw, ah = math.max(1, sw - 2 * m), math.max(1, sh - 2 * m)
		if mode == "actual" or mode == "responsive" then
			z = 1
		elseif st.fit == "width" then
			z = aw / vw
		elseif st.fit == "fill" then
			-- (cover: what's past the stage scrolls; a long page fills its width)
			z = math.max(aw / vw, ah / vh)
		else
			local zw = math.min(1, aw / vw)
			z = math.min(zw, ah / vh)
			-- (no device: a long page, which whole would be under 60% of its
			-- width's fit, fits its width and scrolls, as in step 1)
			if not sized and ah / vh < zw * 0.6 then
				z = zw
			end
		end
	end
	if mode == "width" or mode == "fill" or mode == "device-fill" then
		z = math.min(z, math.max(1, math.sqrt((st.cap or M.RASTER_PTS) / math.max(1, b.w * b.h))))
	end
	z = math.max(0.05, z)
	-- (the viewport is never bigger than the stage: what's past it scrolls)
	local aw, ah = math.max(1, sw - 2 * m), math.max(1, sh - 2 * m)
	vw, vh = math.min(vw, aw / z), math.min(vh, ah / z)
	local w, h = vw * z, vh * z
	-- (a frame: the device box, frame and all, is centred)
	local bw, bh = w + (il + ir) * z, h + (it + ib) * z
	local left = math.floor((sw - bw) / 2 + il * z + 0.5)
	local top
	if bh >= sh - 2 * m - 0.5 then
		top = math.floor(m + it * z + 0.5)
		if bh > sh then
			-- (bigger than the stage: the screen centred, the frame cut)
			top = math.floor((sh - h) / 2 + 0.5)
		end
	else
		top = math.floor((sh - bh) / 2 + it * z + 0.5)
	end
	if bw > sw then
		left = math.floor((sw - w) / 2 + 0.5)
	end
	return {
		z = z,
		left = left,
		top = top,
		w = w,
		h = h,
		vw = vw,
		vh = vh,
		tall = b.h > vh + 0.5,
		b = b,
		mode = mode,
		inset = if st.framed then { il * z, it * z, ir * z, ib * z } else nil,
	}
end

-- (step 6 P2) The device frame's canvases round a placed viewport. `f` =
-- DeviceFrame.shapes for the viewport's size (`vw`, `vh`), `pl` = { left,
-- top, z } (M.place's), `sw` × `sh` the stage. Drawn once per size (M0: never
-- per frame), and kept small (P1's raster budget): the body in four strips
-- round the screen (none under it: the Screen hides that part), and the over
-- shapes in pieces (each rounded corner, the island or notch), so no canvas
-- covers the Screen whole. → { body = { part }, over = { part } }, each part
-- { left, top, w, h } on the stage (whole points, cut to the stage) with
-- `ox`, `oy`: where the screen's top-left is inside it (points).
function M.frame_parts(f: any, pl: any, sw: number, sh: number): any
	local z = pl.z
	local L, T = pl.left, pl.top
	local W, H = f.w * z, f.h * z
	local i = f.inset
	local X0, Y0 = L - i[1] * z, T - i[2] * z
	local X1, Y1 = L + W + i[3] * z, T + H + i[4] * z
	local function part(x0: number, y0: number, x1: number, y1: number): any?
		x0, y0 = math.max(0, math.floor(x0)), math.max(0, math.floor(y0))
		x1, y1 = math.min(sw, math.ceil(x1)), math.min(sh, math.ceil(y1))
		if x1 - x0 < 1 or y1 - y0 < 1 then
			return nil
		end
		return { left = x0, top = y0, w = x1 - x0, h = y1 - y0, ox = L - x0, oy = T - y0 }
	end
	local body, over = {}, {}
	local function add(list: { any }, p: any?)
		if p then
			table.insert(list, p)
		end
	end
	-- (strips overlap the screen's edge by a point: no seam at a fractional zoom)
	add(body, part(X0, Y0, X1, T + 1)) -- top
	add(body, part(X0, T + H - 1, X1, Y1)) -- bottom
	add(body, part(X0, T, L + 1, T + H)) -- left
	add(body, part(L + W - 1, T, X1, T + H)) -- right
	if #f.over > 0 then
		if f.radius > 0 then
			-- (the corner rings and cuts: the screen's square corners hidden)
			local R = f.radius * z + 1
			add(over, part(X0, Y0, L + R, T + R))
			add(over, part(L + W - R, Y0, X1, T + R))
			add(over, part(L + W - R, T + H - R, X1, Y1))
			add(over, part(X0, T + H - R, L + R, Y1))
		end
		for _, s in f.over do
			if s.kind == "rect" then
				add(over, part(L + s.x * z - 1, T + s.y * z - 1, L + (s.x + s.w) * z + 1, T + (s.y + s.h) * z + 1))
			elseif s.kind == "circle" then
				add(over, part(L + (s.x - s.r) * z - 1, T + (s.y - s.r) * z - 1, L + (s.x + s.r) * z + 1, T + (s.y + s.r) * z + 1))
			end
		end
	end
	return { body = body, over = over }
end

-- ── (step 6 P4) the inline Preview ─────────────────────────────────────
-- Figma's Preview shows phone, tablet and watch frames only: a laptop,
-- desktop or TV plays there without its frame (at its size).
M.PREVIEW_FRAMES = { ["phone-island"] = true, ["phone-notch"] = true, ["phone-home"] = true, android = true, tablet = true, watch = true }
M.PREVIEW_MARGIN = 8 -- (round the Screen in the Preview: its stage is small)
M.PREVIEW_BAR = 36 -- (the Preview's bar)
M.PREVIEW_SIZE = { w = 320, h = 640 } -- (the island's first size)
M.PREVIEW_MIN = { w = 200, h = 240 }

-- The device as the Preview plays it: `dv` less a frame it doesn't show.
function M.preview_device(dv: any): any
	if dv.frame and not M.PREVIEW_FRAMES[dv.frame] then
		local c = table.clone(dv)
		c.frame = nil
		return c
	end
	return dv
end

-- The island resized from `from` ({ w, h }) by a drag of (`dx`, `dy`) on
-- `edge`: "l" (its left edge: it's docked on the right), "b" (bottom) or
-- "lb" (the corner). `ratio`: Shift held, the ratio kept (by the edge's own
-- axis; the corner by the larger move). Kept between M.PREVIEW_MIN and `max`.
function M.preview_resize(from: any, edge: string, dx: number, dy: number, ratio: boolean, max: any): any
	local w, h = from.w, from.h
	local l, b = string.find(edge, "l", 1, true) ~= nil, string.find(edge, "b", 1, true) ~= nil
	if l then
		w = from.w - dx
	end
	if b then
		h = from.h + dy
	end
	if ratio and from.w > 0 and from.h > 0 then
		local r = from.h / from.w
		if l and (not b or math.abs(dx) * r >= math.abs(dy)) then
			h = w * r
		else
			w = h / r
		end
	end
	local mw, mh = math.max(M.PREVIEW_MIN.w, max.w), math.max(M.PREVIEW_MIN.h, max.h)
	w = math.clamp(math.floor(w + 0.5), M.PREVIEW_MIN.w, mw)
	h = math.clamp(math.floor(h + 0.5), M.PREVIEW_MIN.h, mh)
	return { w = w, h = h }
end

-- Resize to 100%: the island's size that shows a Screen with root box `b` at
-- 100% (the device's size, its frame, the Preview's margin and bar), as
-- `place` lays it out. `st`: M.settings.
function M.preview_100(b: any, dv: any?, st: any): any
	local sized = dv ~= nil and dv.w ~= nil and dv.h ~= nil
	local vw, vh = (if sized then dv.w else b.w), (if sized then dv.h else b.h)
	local i = if st.framed and st.inset then st.inset else { 0, 0, 0, 0 }
	local m = M.PREVIEW_MARGIN
	return {
		w = math.ceil(vw + i[1] + i[3] + 2 * m),
		h = math.ceil(vh + i[2] + i[4] + 2 * m + M.PREVIEW_BAR),
	}
end

return M
