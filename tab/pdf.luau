--!strict
-- A PDF of pictures, one a page (Export as PDF: each layer a page), written
-- in parts so the window never holds the file (its memory is capped):
--
--   local pdf = Pdf.new(function(data, first)
--       return ui.write_file(file, data, if first then nil else { append = true })
--   end)
--   pdf:page(jpeg_base64, px_w, px_h, w, h)   -- w, h: the page in points
--   pdf:finish()
--
-- `write(data, first)` gets a string or `{ base64 = … }` and returns a
-- promise (awaited before the next part). Pages are JPEGs, which a PDF
-- holds as they are (DCTDecode): from `ui.render_canvas { format = "jpeg" }`.
-- Byte offsets come from lengths alone, base64 counted without decoding.

local M = {}
M.__index = M

export type Pdf = typeof(setmetatable({} :: {
	write: (any, boolean) -> any,
	at: number,
	offsets: { [number]: number },
	pages: { number },
	next_id: number,
	first: boolean,
}, M))

-- Bytes a base64 text stands for.
function M.base64_bytes(b64: string): number
	local n = #b64
	local pad = if string.sub(b64, -2) == "==" then 2 elseif string.sub(b64, -1) == "=" then 1 else 0
	return n // 4 * 3 - pad
end

function M.new(write: (any, boolean) -> any): Pdf
	local self = setmetatable({
		write = write,
		at = 0,
		offsets = {},
		pages = {},
		-- 1: the catalog, 2: the page tree (written last, its kids known).
		next_id = 3,
		first = true,
	}, M)
	-- (The second line's bytes over 127 say "binary" to tools that guess.)
	self:put("%PDF-1.4\n%\226\227\207\211\n")
	return self
end

function M.put(self: Pdf, data: any)
	local n = if type(data) == "string" then #data else M.base64_bytes(data.base64)
	local p = self.write(data, self.first)
	self.first = false
	-- (zgx's promises are userdata: each part written before the next, or
	-- the first, which replaces the file, can land after later appends.)
	if p ~= nil and (type(p) == "table" or type(p) == "userdata") then
		p:await()
	end
	self.at += n
end

function M.object(self: Pdf, id: number, body: string)
	self.offsets[id] = self.at
	self:put(`{id} 0 obj\n{body}\nendobj\n`)
end

local function num(n: number): string
	if n == math.floor(n) then
		return tostring(math.floor(n))
	end
	return string.format("%.3f", n)
end

-- A page of `w` by `h` points showing a JPEG of `px_w` by `px_h` pixels.
function M.page(self: Pdf, jpeg_b64: string, px_w: number, px_h: number, w: number, h: number)
	local page, image, content = self.next_id, self.next_id + 1, self.next_id + 2
	self.next_id += 3
	local bytes = M.base64_bytes(jpeg_b64)
	self.offsets[image] = self.at
	self:put(`{image} 0 obj\n<< /Type /XObject /Subtype /Image /Width {math.floor(px_w)} /Height {math.floor(px_h)} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length {bytes} >>\nstream\n`)
	self:put({ base64 = jpeg_b64 })
	self:put("\nendstream\nendobj\n")
	local draw = `q {num(w)} 0 0 {num(h)} 0 0 cm /Im0 Do Q`
	self:object(content, `<< /Length {#draw} >>\nstream\n{draw}\nendstream`)
	self:object(page, `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {num(w)} {num(h)}] /Resources << /XObject << /Im0 {image} 0 R >> >> /Contents {content} 0 R >>`)
	table.insert(self.pages, page)
end

-- The pixels zgx makes of `n` points at `scale`: ceil(n × scale) in 32-bit
-- floats, as `ui.render_canvas` sizes its picture (a page's image object
-- says its size before zgx has made it).
local function f32(x: number): number
	return (string.unpack("<f", string.pack("<f", x)))
end
function M.pixels(n: number, scale: number): number
	return math.ceil(f32(f32(n) * f32(scale)))
end

-- A page whose JPEG zgx writes onto the file's end itself
-- (`ui.render_canvas { file, append = true }`: no pixels through Luau, and
-- full size). `append()` makes and appends it, awaited, and gives
-- `{ bytes, width, height }`; its length is an object of its own, written
-- after it. `px_w`, `px_h`: `M.pixels` of the page's size.
function M.page_appended(self: Pdf, append: () -> any, px_w: number, px_h: number, w: number, h: number)
	local page, image, content, length = self.next_id, self.next_id + 1, self.next_id + 2, self.next_id + 3
	self.next_id += 4
	self.offsets[image] = self.at
	self:put(`{image} 0 obj\n<< /Type /XObject /Subtype /Image /Width {math.floor(px_w)} /Height {math.floor(px_h)} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length {length} 0 R >>\nstream\n`)
	local got = append()
	if type(got) ~= "table" or type(got.bytes) ~= "number" then
		error("the page's picture wasn't added to the file")
	end
	if got.width ~= math.floor(px_w) or got.height ~= math.floor(px_h) then
		error(`the page's picture is {got.width}×{got.height}, not {math.floor(px_w)}×{math.floor(px_h)}`)
	end
	self.at += got.bytes
	self:put("\nendstream\nendobj\n")
	self:object(length, tostring(got.bytes))
	local draw = `q {num(w)} 0 0 {num(h)} 0 0 cm /Im0 Do Q`
	self:object(content, `<< /Length {#draw} >>\nstream\n{draw}\nendstream`)
	self:object(page, `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {num(w)} {num(h)}] /Resources << /XObject << /Im0 {image} 0 R >> >> /Contents {content} 0 R >>`)
	table.insert(self.pages, page)
end

function M.finish(self: Pdf)
	local kids = {}
	for _, p in self.pages do
		table.insert(kids, `{p} 0 R`)
	end
	self:object(1, "<< /Type /Catalog /Pages 2 0 R >>")
	self:object(2, `<< /Type /Pages /Kids [{table.concat(kids, " ")}] /Count {#self.pages} >>`)
	local xref = self.at
	local rows = { `xref\n0 {self.next_id}\n0000000000 65535 f \n` }
	for id = 1, self.next_id - 1 do
		table.insert(rows, string.format("%010d 00000 n \n", self.offsets[id] or 0))
	end
	table.insert(rows, `trailer\n<< /Size {self.next_id} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n`)
	self:put(table.concat(rows))
end

return M
