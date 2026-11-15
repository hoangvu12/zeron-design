--!nonstrict
-- The person's hand edits (`edit` call, pure/CONTRACT.md §6): the old
-- EditDesign op set, run on a Draft as one undo step, all or none.

local U = require("./util")
local Resolve = require("./resolve")
local Edit = require("./edit")
local Expr = require("./expr")

local M = {}

local function ids_of(op: any): { string }
	if type(op.ids) == "table" then
		return op.ids
	end
	if op.id ~= nil then
		return { op.id }
	end
	return {}
end

-- The laid-out box of `id` (absolute), or nil.
local function box_of(draft: any, id: string?): any
	if not id then
		return { x = 0, y = 0, w = 0, h = 0 }
	end
	local roots = draft:laid_out(id)
	local found = nil
	local function walk(n)
		if n.id == id then
			found = n.__box
			return
		end
		for _, c in (n.children or {}) do
			if found then
				return
			end
			walk(c)
		end
	end
	for _, r in roots do
		walk(r)
	end
	return found
end

local function parent_id(draft: any, id: string): string?
	local f = draft:find(id)
	return f and f.parent and f.parent.id
end

local function num(v: any, what: string): number
	if type(v) ~= "number" then
		error({ draft_error = what .. " is a number" }, 0)
	end
	return v
end

local function renew(draft: any, n: any, made: { any })
	n.id = draft:new_id()
	table.insert(made, { name = n.name or "Node", id = n.id })
	for _, c in U.list(n.children) do
		renew(draft, c, made)
	end
end

local RUN = {}

function RUN.move(draft, op)
	local id = op.id
	local dx, dy = num(op.dx or 0, "dx"), num(op.dy or 0, "dy")
	local x, y = 0, 0
	if string.find(id, "/", 1, true) then
		local r = draft:resolved_find(id)
		if r then
			x, y = U.num(r.x, 0), U.num(r.y, 0)
		end
	else
		local f = draft:find(id)
		if not f then
			draft:fail(`no node has the id "{id}"`)
		end
		x, y = U.num(f.node.x, 0), U.num(f.node.y, 0)
	end
	draft:update(id, { x = x + dx, y = y + dy })
end

local function sizing(v: any): any
	if v == "fit_content" or v == "fill_container" then
		return v
	end
	return num(v, "a size")
end

function RUN.resize(draft, op)
	local props = {}
	if op.w ~= nil then
		props.width = sizing(op.w)
	end
	if op.h ~= nil then
		props.height = sizing(op.h)
	end
	draft:update(op.id, props)
end

function RUN.set(draft, op)
	local v = op.value
	if v == nil then
		v = U.NULL
	end
	draft:update(op.id, { [op.prop] = v })
end

function RUN.text(draft, op)
	draft:update(op.id, { content = tostring(op.text or "") })
end

function RUN.update(draft, op)
	local props = {}
	for k, v in (op.props or {}) do
		props[k] = v
	end
	-- (B1) `turn`: a new rotation turns the layer about its centre (the
	-- Properties panel; the Canvas's handle sends its own move)
	local f = op.turn == true and props.rotation ~= nil and draft:find(op.id)
	local old = if f then U.num(f.node.rotation, 0) else nil
	draft:update(op.id, props)
	if old ~= nil then
		draft:turn_about_centre({ { id = op.id, old = old } })
	end
end

function RUN.insert(draft, op, made)
	local nodes = if type(op.nodes) == "table" then op.nodes else { op.node }
	local parent = op.parent
	if U.is_null(parent) then
		parent = nil
	end
	local origin = nil
	if type(op.at) == "table" then
		local pb = box_of(draft, parent) or { x = 0, y = 0 }
		origin = { x = num(op.at.x, "at.x") - pb.x, y = num(op.at.y, "at.y") - pb.y }
	end
	local first = true
	local list = draft:children_of(parent)
	local index = if type(op.index) == "number" then op.index else nil
	for i, node in nodes do
		local copy = U.deep_copy(node)
		if first and origin then
			copy.x, copy.y = origin.x, origin.y
		end
		first = false
		local sub = {}
		local built = draft:prepare(copy, "insert", sub)
		draft:attach(list, if index then index + i - 1 else nil, built, sub)
		table.insert(made, built.id)
	end
end

function RUN.delete(draft, op)
	local hidden = {}
	local real = {}
	for _, id in ids_of(op) do
		if string.find(id, "/", 1, true) then
			draft:fail(`delete: "{id}" is inside an Instance: hide it with enabled = false`)
		end
		table.insert(real, id)
	end
	local _ = hidden
	draft:delete(real)
end

function RUN.duplicate(draft, op, made)
	for _, id in ids_of(op) do
		local f = draft:find(id)
		if not f then
			draft:fail(`no node has the id "{id}"`)
		end
		local copy = U.deep_copy(f.node)
		local sub = {}
		renew(draft, copy, sub)
		local dx, dy = U.num(op.dx, 0), U.num(op.dy, 0)
		if f.parent == nil and op.dx == nil and op.dy == nil then
			local b = box_of(draft, id)
			dx = (if b then b.w else 0) + 40
		end
		copy.x = U.num(copy.x, 0) + dx
		copy.y = U.num(copy.y, 0) + dy
		draft:attach(f.list, f.index, copy, sub)
		table.insert(made, copy.id)
	end
end

function RUN.reorder(draft, op)
	local id = op.id
	local f = draft:find(id)
	if not f then
		draft:fail(`no node has the id "{id}"`)
	end
	local current = if f.parent then f.parent.id else nil
	if op.parent ~= nil and op.parent ~= current then
		return RUN.reparent(draft, { ids = { id }, parent = op.parent, index = op.index })
	end
	local n = #f.list
	local i = f.index -- 1-based
	local to
	if op.to == "front" then
		to = n
	elseif op.to == "back" then
		to = 1
	elseif op.to == "forward" then
		to = math.min(i + 1, n)
	elseif op.to == "backward" then
		to = math.max(i - 1, 1)
	elseif type(op.index) == "number" then
		to = math.clamp(math.floor(op.index) + 1, 1, n)
	else
		draft:fail('reorder needs to = "front"|"back"|"forward"|"backward" or an index')
	end
	draft:move(id, current, to - 1)
end

function RUN.reparent(draft, op)
	local parent = op.parent
	if U.is_null(parent) then
		parent = nil
	end
	local pb = box_of(draft, parent) or { x = 0, y = 0 }
	for k, id in ids_of(op) do
		local b = box_of(draft, id)
		draft:move(id, parent, if type(op.index) == "number" then op.index + k - 1 else nil)
		if b then
			draft:update(id, { x = b.x - pb.x, y = b.y - pb.y })
		end
	end
end

function RUN.tokens(draft, op)
	draft:set_tokens(op.tokens or {}, op.replace == true)
end

-- The Design's prototype flows: { {name, start} } ("__null" or {} clears).
function RUN.flows(draft, op)
	draft:set_flows(op.flows)
end

-- The Design's prototype settings: { device, rotate, fit, background }
-- ("__null" or {} clears; `merge = true` changes only the keys given).
function RUN.prototype(draft, op)
	draft:set_prototype(op.prototype, op.merge == true)
end

function RUN.themes(draft, op)
	draft:set_themes(tostring(op.axis), op.values)
end

-- Whether `id` is placed by its parent's auto layout.
local function laid_by_parent(draft: any, id: string): boolean
	local f = draft:find(id)
	if not f or not f.parent then
		return false
	end
	local l = f.parent.layout
	return (l == "horizontal" or l == "vertical") and f.node.absolute ~= true
end

local function union(boxes: { any }): any
	local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
	for _, b in boxes do
		x0, y0 = math.min(x0, b.x), math.min(y0, b.y)
		x1, y1 = math.max(x1, b.x + b.w), math.max(y1, b.y + b.h)
	end
	return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- Boxes of several ids at once (one layout).
local function boxes_of(draft: any, ids: { string }): { [string]: any }
	local want = {}
	for _, id in ids do
		want[id] = true
	end
	local out = {}
	local function walk(n)
		if want[n.id] then
			out[n.id] = n.__box
		end
		for _, c in (n.children or {}) do
			walk(c)
		end
	end
	for _, r in draft:laid_out(nil) do
		walk(r)
	end
	return out
end

function RUN.wrap(draft, op, made)
	local ids = ids_of(op)
	if #ids == 0 then
		draft:fail("wrap needs ids")
	end
	local parent, list = nil, nil
	local top = 0
	for i, id in ids do
		if string.find(id, "/", 1, true) then
			draft:fail(`"{id}" is inside an Instance`)
		end
		local f = draft:find(id)
		if not f then
			draft:fail(`no node has the id "{id}"`)
		end
		local p = f.parent and f.parent.id
		if i > 1 and p ~= parent then
			draft:fail("wrap: the nodes must share a parent")
		end
		parent, list = p, f.list
		top = math.max(top, f.index)
	end
	local boxes = boxes_of(draft, ids)
	local pb = if parent then boxes_of(draft, { parent })[parent] else { x = 0, y = 0 }
	local bs = {}
	for _, id in ids do
		table.insert(bs, boxes[id])
	end
	local u = union(bs)
	-- in their order among siblings
	local ordered = table.clone(ids)
	table.sort(ordered, function(a, b)
		return draft:find(a).index < draft:find(b).index
	end)
	local as = op.as or "group"
	local frame: any = { type = "frame", name = op.name or (if as == "frame" then "Frame" else "Group"), x = u.x - pb.x, y = u.y - pb.y }
	if op.layout == "horizontal" or op.layout == "vertical" then
		frame.layout = op.layout
		-- the spacing they have now, along the layout
		local axis = if op.layout == "horizontal" then "x" else "y"
		local size = if op.layout == "horizontal" then "w" else "h"
		local sorted = table.clone(bs)
		table.sort(sorted, function(a, b)
			return a[axis] < b[axis]
		end)
		local gaps, n = 0, 0
		for i = 2, #sorted do
			gaps += math.max(sorted[i][axis] - (sorted[i - 1][axis] + sorted[i - 1][size]), 0)
			n += 1
		end
		frame.gap = if n > 0 then math.floor(gaps / n + 0.5) else 0
	elseif as == "frame" then
		frame.width, frame.height = u.w, u.h
	end
	local sub = {}
	local built = draft:prepare(frame, "wrap", sub)
	local index = top - #ids -- where the topmost one was, once they're out
	built.children = {}
	for _, id in ordered do
		local f = draft:find(id)
		local node = table.remove(f.list, f.index)
		draft:stale()
		local b = boxes[id]
		node.x, node.y = b.x - u.x, b.y - u.y
		table.insert(built.children, node)
	end
	draft:attach(list, math.max(index, 0), built, sub)
	draft:changed_id(built.id)
	table.insert(made, built.id)
end

function RUN.unwrap(draft, op, made)
	local id = op.id
	local f = draft:find(id)
	if not f or f.node.type ~= "frame" then
		draft:fail(`unwrap: "{tostring(id)}" isn't a frame`)
	end
	local kids = U.list(f.node.children)
	local kid_ids = {}
	for _, c in kids do
		table.insert(kid_ids, c.id)
	end
	local parent = f.parent and f.parent.id
	local boxes = boxes_of(draft, kid_ids)
	local pb = if parent then boxes_of(draft, { parent })[parent] else { x = 0, y = 0 }
	local list, at = f.list, f.index
	table.remove(list, at)
	for i, c in kids do
		local b = boxes[c.id]
		if b then
			c.x, c.y = b.x - pb.x, b.y - pb.y
		end
		table.insert(list, at + i - 1, c)
		table.insert(made, c.id)
		draft:changed_id(c.id)
	end
	draft:stale()
	draft.changed[id] = true
	if parent then
		draft:changed_id(parent)
	end
end

function RUN.detach(draft, op, made)
	local id = op.id
	local f = draft:find(id)
	if not f or f.node.type ~= "instance" then
		draft:fail(`detach: "{tostring(id)}" isn't an Instance`)
	end
	local r = Resolve.new(draft.d.doc)
	local copy, comp = r:expand(U.deep_copy(f.node), {})
	if not comp then
		draft:fail(`detach: {r.problems[1] and r.problems[1].message or "its Component is missing"}`)
	end
	copy.__inst = nil
	copy.__broken = nil
	copy.__vb = nil
	copy.__ref0 = nil
	local sub = {}
	renew(draft, copy, sub)
	f.list[f.index] = copy
	draft:stale()
	for _, m in sub do
		draft:changed_id(m.id)
		table.insert(draft.created, m)
	end
	draft.changed[id] = true
	table.insert(made, copy.id)
end

function RUN.align(draft, op)
	local ids = ids_of(op)
	local movable = {}
	for _, id in ids do
		if not laid_by_parent(draft, id) then
			table.insert(movable, id)
		end
	end
	if #movable == 0 then
		return
	end
	local boxes = boxes_of(draft, ids)
	local area
	if #ids == 1 then
		local p = parent_id(draft, ids[1])
		if not p then
			return
		end
		area = boxes_of(draft, { p })[p]
	else
		local bs = {}
		for _, id in ids do
			table.insert(bs, boxes[id])
		end
		area = union(bs)
	end
	for _, id in movable do
		local b = boxes[id]
		local f = draft:find(id)
		local dx, dy = 0, 0
		local to = op.to
		if to == "left" then
			dx = area.x - b.x
		elseif to == "hcenter" then
			dx = area.x + area.w / 2 - (b.x + b.w / 2)
		elseif to == "right" then
			dx = area.x + area.w - (b.x + b.w)
		elseif to == "top" then
			dy = area.y - b.y
		elseif to == "vcenter" then
			dy = area.y + area.h / 2 - (b.y + b.h / 2)
		elseif to == "bottom" then
			dy = area.y + area.h - (b.y + b.h)
		else
			draft:fail('align: to is "left", "hcenter", "right", "top", "vcenter" or "bottom"')
		end
		draft:update(id, { x = U.num(f.node.x, 0) + dx, y = U.num(f.node.y, 0) + dy })
	end
end

function RUN.distribute(draft, op)
	local ids = ids_of(op)
	if #ids < 3 then
		draft:fail("distribute needs 3 or more ids")
	end
	local axis = if op.axis == "y" then "y" else "x"
	local size = if axis == "x" then "w" else "h"
	local boxes = boxes_of(draft, ids)
	local sorted = table.clone(ids)
	table.sort(sorted, function(a, b)
		return boxes[a][axis] < boxes[b][axis]
	end)
	local first, last = boxes[sorted[1]], boxes[sorted[#sorted]]
	local total = last[axis] + last[size] - first[axis]
	local sizes = 0
	for _, id in sorted do
		sizes += boxes[id][size]
	end
	local gap = (total - sizes) / (#sorted - 1)
	local at = first[axis] + first[size] + gap
	for i = 2, #sorted - 1 do
		local id = sorted[i]
		if not laid_by_parent(draft, id) then
			local f = draft:find(id)
			draft:update(id, { [axis] = U.num(f.node[axis], 0) + (at - boxes[id][axis]) })
		end
		at += boxes[id][size] + gap
	end
end

-- A clip of `ids` (CONTRACT §5 `copy`): the nodes as written, the same with
-- Instances expanded (for another Design), their boxes and the Tokens used.
function M.clip(draft: any, ids: { string }): any
	local boxes = boxes_of(draft, ids)
	local nodes, detached, bs = {}, {}, {}
	local used = {}
	local r = Resolve.new(draft.d.doc)
	for _, id in ids do
		local node
		if string.find(id, "/", 1, true) then
			local x = draft:resolved_find(id)
			node = x and Edit.clean_resolved(x)
		else
			local f = draft:find(id)
			node = f and U.deep_copy(f.node)
		end
		if not node then
			draft:fail(`no node has the id "{id}"`)
		end
		table.insert(nodes, node)
		-- expanded, Tokens kept as references
		local function expand(n)
			if n.type == "instance" then
				local c, ok = r:expand(U.deep_copy(n), {})
				if ok then
					c.__inst = nil
					c.__vb = nil
					c.__ref0 = nil
					n = c
				end
			end
			if type(n.children) == "table" then
				for i, c in n.children do
					n.children[i] = expand(c)
				end
			end
			return n
		end
		table.insert(detached, expand(U.deep_copy(node)))
		local b = boxes[id] or { x = 0, y = 0, w = 0, h = 0 }
		table.insert(bs, { b.x, b.y, b.w, b.h })
		local function refs(v)
			if type(v) == "string" then
				local name = Resolve.reference(v)
				if name then
					used[name] = true
				end
			elseif type(v) == "table" then
				for _, x in v do
					refs(x)
				end
			end
		end
		refs(node)
	end
	local tokens = {}
	for name in used do
		if draft.d.doc.tokens and draft.d.doc.tokens[name] then
			tokens[name] = U.deep_copy(draft.d.doc.tokens[name])
		end
	end
	return { zeronDesignClip = 1, source = draft.d.did, nodes = nodes, detached = detached, boxes = bs, tokens = tokens }
end

function RUN.paste(draft, op, made)
	local clip = op.clip or M.clipboard
	if type(clip) ~= "table" or clip.zeronDesignClip ~= 1 then
		draft:fail("paste: nothing to paste")
	end
	local same = clip.source == draft.d.did
	local nodes = U.deep_copy(if same then clip.nodes else clip.detached)
	-- links to Screens this Design lacks come along, as broken links (lint)
	draft.lenient_links = not same
	if not same then
		-- Tokens it uses that this Design lacks come along
		local now = draft.d.doc.tokens or {}
		local add = {}
		for name, tok in (clip.tokens or {}) do
			if now[name] == nil then
				add[name] = tok
			end
		end
		if next(add) then
			draft:set_tokens(add, false)
		end
	end
	local parent, index = op.parent, op.index
	if U.is_null(parent) then
		parent = nil
	end
	if op.into then
		local f = draft:find(op.into)
		if f and f.node.type == "frame" then
			parent, index = f.node.id, nil
		elseif f then
			parent = f.parent and f.parent.id
			index = f.index -- after it (0-based index of the next place)
		end
	end
	local list = draft:children_of(parent)
	local pb = if parent then boxes_of(draft, { parent })[parent] else { x = 0, y = 0 }
	local dx, dy = 0, 0
	if type(op.at) == "table" and clip.boxes[1] then
		dx, dy = op.at.x - clip.boxes[1][1], op.at.y - clip.boxes[1][2]
	end
	for i, node in nodes do
		local b = clip.boxes[i]
		if b then
			node.x, node.y = b[1] + dx - pb.x, b[2] + dy - pb.y
		end
		local sub = {}
		renew(draft, node, sub)
		draft:attach(list, if index then index + i - 1 else nil, node, sub)
		table.insert(made, node.id)
	end
end

function RUN.renameToken(draft, op)
	local from, to = op.from, op.to
	local doc = draft.d.doc
	if type(from) ~= "string" or not (doc.tokens and doc.tokens[from]) then
		draft:fail(`renameToken: no Token "{tostring(from)}"`)
	end
	if type(to) ~= "string" or not string.match(to, "^[%w%-_%./]+$") then
		draft:fail(`renameToken: "{tostring(to)}" can't name a Token`)
	end
	if doc.tokens[to] then
		draft:fail(`renameToken: "{to}" is taken`)
	end
	doc.tokens[to] = doc.tokens[from]
	doc.tokens[from] = nil
	local old, new = "$" .. from, "$" .. to
	local function rewrite(v)
		if type(v) == "table" then
			-- (step 5) an action's variable and its expressions
			if (v.action == "set" or v.action == "toggle") and v.var == from then
				v.var = to
			end
			if v.action == "set" and Expr.inner(v.to) then
				v.to = Expr.rename(v.to, from, to)
			elseif v.action == "if" and type(v.cond) == "string" then
				v.cond = Expr.rename(v.cond, from, to)
			end
			for k, x in v do
				if x == old then
					v[k] = new
				elseif type(x) == "table" then
					rewrite(x)
				end
			end
		end
	end
	for _, root in doc.children do
		rewrite(root)
	end
	draft.tokens_changed = true
end

local function fmt(x: number): string
	if x == math.floor(x) then
		return string.format("%d", x)
	end
	return string.format("%.2f", x)
end

-- Points (Canvas) as a path node boxed to them; a side without extent is 1 wide.
local function path_of(pts: { any }, closed: boolean): any
	local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
	for _, p in pts do
		x0, y0 = math.min(x0, p.x), math.min(y0, p.y)
		x1, y1 = math.max(x1, p.x), math.max(y1, p.y)
	end
	local w, h = x1 - x0, y1 - y0
	local ox, oy = 0, 0
	if w <= 0 then
		w, ox = 1, 0.5
	end
	if h <= 0 then
		h, oy = 1, 0.5
	end
	local d = {}
	for i, p in pts do
		table.insert(d, (if i == 1 then "M" else "L") .. fmt(p.x - x0 + ox) .. " " .. fmt(p.y - y0 + oy))
	end
	if closed then
		table.insert(d, "Z")
	end
	return { type = "path", geometry = table.concat(d, " "), viewBox = { 0, 0, w, h }, width = w, height = h }, x0 - ox, y0 - oy
end

function RUN.shape(draft, op, made)
	local kind = op.kind
	local node, ax, ay
	local LINE = { align = "center", thickness = 1, fill = "#000000" }
	if kind == "line" then
		if type(op.from) ~= "table" or type(op.to) ~= "table" then
			draft:fail("shape line needs from and to")
		end
		node, ax, ay = path_of({ op.from, op.to }, false)
		node.name = "Line"
		node.stroke = LINE
	elseif kind == "path" then
		if type(op.points) ~= "table" or #op.points < 2 then
			draft:fail("shape path needs 2 or more points")
		end
		node, ax, ay = path_of(op.points, op.closed == true)
		node.name = "Path"
		if op.closed then
			node.fill = "#D9D9D9"
		else
			node.stroke = LINE
		end
	elseif kind == "polygon" then
		node = { type = "polygon", name = "Polygon", width = num(op.width, "width"), height = num(op.height, "height"), polygonCount = math.clamp(math.floor(U.num(op.sides, 3)), 3, 64), fill = "#D9D9D9" }
	elseif kind == "star" then
		local w, h = num(op.width, "width"), num(op.height, "height")
		local n = math.clamp(math.floor(U.num(op.points, 5)), 3, 64)
		local inner = U.clamp(U.num(op.inner, 0.38), 0, 1)
		local d = {}
		for i = 0, 2 * n - 1 do
			local a = i * math.pi / n - math.pi / 2
			local r = if i % 2 == 0 then 1 else inner
			table.insert(d, (if i == 0 then "M" else "L") .. fmt(w / 2 + w / 2 * r * math.cos(a)) .. " " .. fmt(h / 2 + h / 2 * r * math.sin(a)))
		end
		table.insert(d, "Z")
		node = { type = "path", name = "Star", geometry = table.concat(d, " "), viewBox = { 0, 0, w, h }, width = w, height = h, fill = "#D9D9D9" }
	else
		draft:fail('shape kind is "line", "polygon", "star" or "path"')
	end
	if op.name then
		node.name = op.name
	end
	for k, v in (op.props or {}) do
		if k ~= "type" and k ~= "geometry" and k ~= "viewBox" then
			node[k] = v
		end
	end
	local at = if ax then { x = ax, y = ay } else op.at
	RUN.insert(draft, { node = node, parent = op.parent, index = op.index, at = at }, made)
end

M.NAMES = {}
for k in RUN do
	table.insert(M.NAMES, k)
end
table.sort(M.NAMES)

-- Runs `ops` on `draft`; the ids made, or raises.
function M.run(draft: any, ops: any): { string }
	local made = {}
	for i, op in U.list(ops) do
		if type(op) ~= "table" then
			draft:fail(`op {i} is a table`)
		end
		local f = RUN[op.op]
		if not f then
			draft:fail(`op {i}: unknown op "{tostring(op.op)}" (known: {table.concat(M.NAMES, ", ")})`)
		end
		local ok, e = pcall(f, draft, op, made)
		if not ok then
			local msg = if type(e) == "table" and e.draft_error then e.draft_error else tostring(e)
			draft:fail(`op {i} ({op.op}): {msg}`)
		end
	end
	return made
end

local _ = Resolve
return M
