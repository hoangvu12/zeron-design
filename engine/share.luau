--!nonstrict
-- The prototype "for sharing" (pure/anim/f7/share/README.md): the HTML
-- export made into one self-contained page an agent can publish as a
-- private Claude artifact (claude.ai), which the person then shares from
-- claude.ai if they want to.
--
-- An artifact page is at most 16 MB with its `data:` URIs, loads scripts
-- only from a few CDNs with an exact version and stylesheets only from
-- Google Fonts. So the page here:
--   - has the Design's own pictures (kept in zeron.db, `img:`) inlined as
--     `data:` URIs (as stored: not resized);
--   - loads Tailwind (css = "tailwind") pinned to an exact version;
--   - keeps Google Fonts' stylesheet (allowed);
--   - is refused past M.LIMIT, with the heaviest pictures named.
-- Pure: `lookup(url) → { mime, base64 } | nil` gives a picture's bytes.

local M = {}

M.LIMIT = 15 * 1024 * 1024
M.TAILWIND = "https://cdn.tailwindcss.com/3.4.17"
M.PRIVACY = "Private until you share it from claude.ai."
-- An artifact's link: claude.ai/artifact/{id} or claude.ai/code/artifact/{uuid}.
function M.is_link(url: any): boolean
	return type(url) == "string"
		and (string.match(url, "^https://claude%.ai/artifact/[%w%-_]+/?$") ~= nil or string.match(url, "^https://claude%.ai/code/artifact/[%w%-_]+/?$") ~= nil)
end

-- (as engine/export.luau writes them)
local function quote(s: string): string
	return '"' .. string.gsub(s, '["\\]', "\\%0") .. '"'
end
local function escape(s: string): string
	return (string.gsub(s, "[<>&\"]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;", ['"'] = "&quot;" }))
end

-- Every `from` in `text` replaced by `to` (plain, no patterns); the count.
local function replace(text: string, from: string, to: string): (string, number)
	local parts, n, at = {}, 0, 1
	while true do
		local i, j = string.find(text, from, at, true)
		if not i then
			break
		end
		table.insert(parts, string.sub(text, at, i - 1))
		table.insert(parts, to)
		n += 1
		at = j + 1
	end
	if n == 0 then
		return text, 0
	end
	table.insert(parts, string.sub(text, at))
	return table.concat(parts), n
end

-- The picture urls a Design's paints name, sorted.
function M.image_urls(doc: any): { string }
	local out, seen = {}, {}
	local function visit(v)
		if type(v) ~= "table" then
			return
		end
		if v.type == "image" and type(v.url) == "string" and v.url ~= "" and not seen[v.url] then
			seen[v.url] = true
			table.insert(out, v.url)
		end
		for _, x in v do
			if type(x) == "table" then
				visit(x)
			end
		end
	end
	visit(doc and doc.children)
	visit(doc and doc.components)
	table.sort(out)
	return out
end

local function mb(n: number): string
	return string.format("%.1f MB", n / 1048576)
end

-- `html` (Export.html with prototype = true and the scaffold) made ready to
-- share. Returns { ok, html?, bytes, images = { { url, bytes } }, notes, error? }.
function M.prepare(html: string, doc: any, lookup: (url: string) -> any?, title: string?): any
	local notes, images = {}, {}
	-- Tailwind, pinned (an artifact loads only exact versions)
	html = replace(html, '<script src="https://cdn.tailwindcss.com"></script>', `<script src="{M.TAILWIND}"></script>`)
	-- A title, for the artifact's name and the browser's tab
	if title and not string.find(html, "<title>", 1, true) then
		html = replace(html, '<meta name="viewport" content="width=device-width, initial-scale=1">', `<meta name="viewport" content="width=device-width, initial-scale=1">\n  <title>{escape(title)}</title>`)
	end
	for _, url in M.image_urls(doc) do
		if string.sub(url, 1, 5) == "data:" then
			continue
		end
		local used = string.find(html, quote(url), 1, true) or string.find(html, escape(quote(url)), 1, true)
		if not used then
			continue -- (on a hidden layer or a Component no Screen shows)
		end
		local pic = lookup(url)
		if type(pic) == "table" and type(pic.base64) == "string" and type(pic.mime) == "string" then
			local data = "data:" .. pic.mime .. ";base64," .. pic.base64
			local n1, n2
			html, n1 = replace(html, quote(url), quote(data))
			html, n2 = replace(html, escape(quote(url)), escape(quote(data)))
			table.insert(images, { url = url, bytes = #pic.base64 * (n1 + n2) })
		elseif string.match(string.lower(url), "^https?://") then
			table.insert(notes, `the picture {url} loads from the web: a claude.ai page may not show outside pictures; add it to the Design (drop it in) to have it inside the page`)
		else
			table.insert(notes, `the picture "{url}" isn't in the Design yet (drop the file in): it's left out`)
		end
	end
	table.sort(images, function(a, b)
		return a.bytes > b.bytes
	end)
	local out: any = { bytes = #html, images = images, notes = if #notes > 0 then notes else nil }
	if #html > M.LIMIT then
		local heavy = {}
		for i = 1, math.min(5, #images) do
			table.insert(heavy, `{images[i].url} ({mb(images[i].bytes)})`)
		end
		out.ok = false
		out.error = `the shared page would be {mb(#html)}; a claude.ai page is at most 15 MB here. Heaviest pictures: `
			.. (if #heavy > 0 then table.concat(heavy, ", ") else "none (the page itself is big)")
			.. ". Make those pictures smaller (or share fewer Screens), then share again"
		return out
	end
	out.ok = true
	out.html = html
	return out
end

-- What the agent does with the file (the result's `steps`).
function M.steps(file: string, link: string?): string
	local publish = if link
		then `publish it with the Artifact tool, url = "{link}" (the Design's link: it updates that page, same link)`
		else "publish it with the Artifact tool as a new artifact"
	return `Share it: {publish}, file_path = the file above, unchanged (it's the person's prototype: don't restyle or rewrite it). `
		.. `Then save the link in the Design: design_execute with SetPrototype(\{ shareUrl = "<the artifact's link>" \}). `
		.. `Tell the person the link and that it's private until they share it from claude.ai. Never publish without the person asking for it.`
end

return M
