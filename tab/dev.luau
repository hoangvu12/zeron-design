--!strict
-- Dev only: the Design editor in a window of its own, opened by a command
-- (`design-pure/dev-open`, "Design: Open in a window (dev)"), so tests can
-- reach it without a click in a chat's panel (`zgx inspect command
-- design-pure/dev-open`). It lists the service's Designs to pick from, and
-- can import the bundled Pulse Dashboard. Harmless in use: a menu item that
-- opens what the panel tab shows.

local M = {}

function M.register(zeron: any, Shell: any, source_of: (did: string, name: string?) -> any, dark: any)
	local service = zeron.service()
	local open = ui.state("design-pure.dev.open", false)
	local chosen = ui.state("design-pure.dev.did", nil :: { did: string, name: string }?)
	local list = ui.state("design-pure.dev.designs", {} :: { any })
	local status = ui.state("design-pure.dev.status", "")

	local function refresh()
		service:call("designs", {}):after(function(r: any)
			list:set(if type(r) == "table" and type(r.designs) == "table" then r.designs else {})
		end, function(err: any)
			status:set(`designs: {err}`)
		end)
	end

	ui.command {
		id = "dev-open",
		title = "Design: Open in a window (dev)",
		menu = "Window",
		run = function()
			refresh()
			open:set(true)
		end,
	}

	local function import_pulse()
		status:set("Importing Pulse…")
		local ok, text = pcall(require, "../dev/pulse_zdesign")
		if not ok then
			status:set("no bundled Pulse")
			return
		end
		service:call("import", { text = text, name = "Pulse Dashboard (dev)" }):after(function(r: any)
			status:set(`imported {r and r.did}`)
			refresh()
			if type(r) == "table" and r.did then
				chosen:set({ did = r.did, name = r.name or "Pulse Dashboard" })
			end
		end, function(err: any)
			status:set(`import: {err}`)
		end)
	end

	ui.window {
		id = "dev-design",
		title = "Design (dev)",
		width = 1440,
		height = 840,
		open = open,
		ui.column {
			w_full = true,
			h_full = true,
			ui.row {
				id = "dev-designs",
				w_full = true,
				h = 30,
				px = 8,
				gap = 4,
				items = "center",
				bg = "#e4e4e7",
				ui.each(list, function(d: any, i: number): Node
					return ui.button {
						id = `dev-design-{i}`,
						label = `{d.name} ({d.did})`,
						h = 22,
						px = 6,
						rounded = 4,
						on_click = function()
							chosen:set({ did = d.did, name = d.name })
						end,
						ui.text { d.name, text_size = 11 },
					}
				end, {
					key = function(d: any): string
						return d.did
					end,
				}),
				ui.button {
					id = "dev-import-pulse",
					label = "Import Pulse",
					h = 22,
					px = 6,
					rounded = 4,
					on_click = import_pulse,
					ui.text { "Import Pulse", text_size = 11 },
				},
				ui.text { status, text_size = 11, color = "#52525b" },
			},
			ui.presence(function(): string
				local c = chosen:get()
				return if c then c.did .. (if dark:get() then ":dark" else ":light") else ""
			end, function(key: string): Node
				local c = chosen:peek()
				if key == "" or not c then
					return ui.div { p = 16, ui.text { "Pick a Design above.", text_size = 12 } }
				end
				return Shell.Shell { source = source_of(c.did, c.name), id = c.did, dark = dark:peek() }
			end, { w_full = true, grow = 1, min_h = 0 }),
		},
	}
end

return M
