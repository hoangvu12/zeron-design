--!nonstrict
-- Exports written to files (pure/CONTRACT.md §9): what an agent's
-- `Export` asked for, as files in a folder the person can find, their paths
-- in the call's result.
--
--   Export({ format = "handoff" })   every board as a 2x PNG, index.html
--                                    (+ its CSS) and tokens.json
--   Export(ids, { format = "png" })  those nodes as PNGs
--   Export(ids, { format = "html" }) their HTML as a file
--
-- The folder: `folder` when the agent gave one (a whole path inside its
-- chat's or project's folder, or a relative one under Documents), else
-- `<chat's folder>/design-exports/<Design name>/`, or `<Design name>/`
-- (which Zeron puts in the plugin's own folder in Documents) for a chat
-- with no folder. PNGs are drawn one by one for
-- about BUDGET seconds a call (a tool call has 30 s); the rest are left for
-- the next call, which the result says how to make.

local Export = require("./export")

local M = {}

M.BUDGET = 20

-- A name as a file's: its letters (any script, case as written), digits,
-- dashes. (string.lower knows only ASCII: "Đăng" would stay half-cased.)
function M.slug(name: any, fallback: string?): string
	local s = tostring(name or "")
	s = string.gsub(s, "[%c/\\:%*%?\"<>|]", " ")
	s = string.gsub(s, "[%s%.·,;!'`%(%)%[%]{}#&%%+=~^@$]+", "-")
	s = string.gsub(s, "%-+", "-")
	s = string.gsub(s, "^%-+", "")
	s = string.gsub(s, "%-+$", "")
	if #s > 60 then
		s = string.sub(s, 1, 60)
		-- (not mid-character)
		while #s > 0 and string.byte(s, #s) >= 0x80 and string.byte(s, #s) < 0xC0 do
			s = string.sub(s, 1, #s - 1)
		end
		if #s > 0 and string.byte(s, #s) >= 0xC0 then
			s = string.sub(s, 1, #s - 1)
		end
	end
	if s == "" then
		return fallback or "untitled"
	end
	return s
end

-- The boards: top-level Frames that aren't Components, in the Design's order.
function M.boards(doc: any): { any }
	local out = {}
	for _, n in doc.children or {} do
		if n.type == "frame" and n.reusable ~= true then
			table.insert(out, n)
		end
	end
	return out
end

local function joined(folder: string, file: string): string
	if string.find(folder, "[/\\]$") then
		return folder .. file
	end
	local sep = if string.find(folder, "\\", 1, true) and not string.find(folder, "/", 1, true) then "\\" else "/"
	return folder .. sep .. file
end

local function dir_of(path: string): string
	return string.match(path, "^(.*)[/\\][^/\\]*$") or path
end

-- Runs `entries` (the draft's `exported`, html/png/handoff) for Design `d`.
-- `io.write(path, data, base64?) → whole path` (raises on failure),
-- `io.render(id, scale) → png base64 | nil, why`, `io.now() → seconds`.
-- Returns `exported` for the result (folder, files, remaining, next,
-- notes) and the PNGs drawn (`{id, png}`, for `inline`).
function M.run(d: any, entries: { any }, io: any): (any, { any })
	local files, notes, pngs = {}, {}, {}
	local out: any = { files = files }
	local folder_abs: string? = nil
	local start = io.now()
	-- `io.base`: the chat's folder's design-exports/ (a whole path), else
	-- nil: relative, so Zeron puts it in the plugin's folder in Documents.
	local default_folder = M.slug(d.name, "design")
	if type(io.base) == "string" and io.base ~= "" then
		default_folder = joined(io.base, default_folder)
	end
	local used: { [string]: boolean } = {}

	local function folder_for(e: any): string
		if type(e.folder) == "string" and e.folder ~= "" then
			return e.folder
		end
		return default_folder
	end
	local function put(folder: string, file: string, data: string, b64: boolean?, kind: string, extra: any?): boolean
		local ok, path = pcall(io.write, joined(folder, file), data, b64)
		if not ok then
			table.insert(notes, `couldn't write {file}: {path}`)
			return false
		end
		folder_abs = folder_abs or dir_of(path)
		local row = { path = path, kind = kind }
		for k, v in extra or {} do
			row[k] = v
		end
		table.insert(files, row)
		return true
	end
	local function unique(name: string, id: string, ext: string): string
		local file = name .. ext
		if used[file] then
			file = name .. "-" .. id .. ext
		end
		used[file] = true
		return file
	end
	local function name_of(id: string): string
		local found = nil
		local function walk(n)
			if found then
				return
			end
			if n.id == id then
				found = n.name
				return
			end
			for _, c in n.children or {} do
				walk(c)
			end
		end
		for _, n in d.doc.children or {} do
			walk(n)
		end
		return M.slug(found or id, id)
	end
	local function png(folder: string, id: string, scale: number, file: string, extra: any): boolean
		if io.now() - start >= M.BUDGET then
			return false
		end
		local data, why = io.render(id, scale)
		if type(data) ~= "string" then
			table.insert(notes, `no PNG of {id}: {why or "it wasn't drawn"}`)
			return true
		end
		table.insert(pngs, { id = id, png = data })
		put(folder, file, data, true, "png", extra)
		return true
	end

	for _, e in entries do
		local folder = folder_for(e)
		if e.format == "html" then
			local base = if e.ids and e.ids[1] then name_of(e.ids[1]) else "index"
			put(folder, unique(base, "html", ".html"), e.html, false, "html")
		elseif e.format == "png" then
			local id = e.id
			if not png(folder, id, e.scale or 2, unique(name_of(id), (string.gsub(id, "/", "-")), ".png"), { id = id }) then
				out.remaining = (out.remaining or 0) + 1
			end
		elseif e.format == "handoff" then
			local boards = M.boards(d.doc)
			if e.ids and #e.ids > 0 then
				local want = {}
				for _, id in e.ids do
					want[id] = true
				end
				local some = {}
				for _, b in boards do
					if want[b.id] then
						table.insert(some, b)
					end
				end
				boards = some
			end
			local from = math.max(1, math.floor(tonumber(e.from) or 1))
			local digits = if #boards >= 100 then "%03d" else "%02d"
			if from == 1 then
				local ids = {}
				for _, b in boards do
					table.insert(ids, b.id)
				end
				local okh, html = pcall(Export.html, d.doc, ids, { css = e.css, scaffold = true, icons = io.icons })
				if okh then
					put(folder, "index.html", html, false, "html")
				else
					table.insert(notes, `no index.html: {html}`)
				end
				put(folder, "tokens.json", io.json({ tokens = d.doc.tokens or {}, themes = d.doc.themes or {} }), false, "tokens")
			end
			local stopped_at = nil
			for i = from, #boards do
				local b = boards[i]
				local file = string.format(digits, i) .. "-" .. M.slug(b.name, b.id) .. ".png"
				if not png(folder, b.id, e.scale or 2, file, { id = b.id, board = b.name }) then
					stopped_at = i
					break
				end
			end
			out.boards = #boards
			if stopped_at then
				out.remaining = (out.remaining or 0) + (#boards - stopped_at + 1)
				local args = { `format = "handoff"`, `from = {stopped_at}` }
				if type(e.folder) == "string" and e.folder ~= "" then
					table.insert(args, string.format("folder = %q", e.folder))
				end
				if e.css then
					table.insert(args, string.format("css = %q", e.css))
				end
				out.next = `Export(\{ {table.concat(args, ", ")} \})`
			end
		end
	end
	out.folder = folder_abs
	if out.remaining then
		table.insert(notes, `{out.remaining} PNG(s) not written yet: this call stopped drawing at {M.BUDGET} s. ` .. (if out.next then `Call {out.next} for the rest.` else "Export them again in another call."))
	end
	out.notes = if #notes > 0 then notes else nil
	if #files == 0 and not out.notes then
		return nil, pngs
	end
	return out, pngs
end

return M
