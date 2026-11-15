--!strict
local ui = require("./pointer").ui
-- "Share link…" (pure/anim/f7/share/README.md): the Prototype panel's Share
-- section, nothing selected. The plugin can't publish a page itself: the
-- button puts a ready prompt in the chat's message box (zeron.compose,
-- permission "compose"); an agent in a Claude Code chat exports the
-- prototype as one page (`Export({ share = true })`), publishes it as a
-- private Claude artifact and saves its link in the Design
-- (`prototype.shareUrl`), so the next share updates the same link.
--
--   Share.prompt(name, did?, link?)   the words put in the message box
--   Share.Section { L, source, sec }  the panel's section

local Kit = require("./kit")
local Toast = require("./toast")

local M = {}

M.PRIVACY = "Private until you share it from claude.ai."
M.NEEDS = "Needs a Claude Code chat (not Codex)."

-- An artifact's link: claude.ai/artifact/{id} or claude.ai/code/artifact/{uuid}
-- (as engine/share.luau's is_link).
function M.is_link(url: any): boolean
	return type(url) == "string"
		and (string.match(url, "^https://claude%.ai/artifact/[%w%-_]+/?$") ~= nil or string.match(url, "^https://claude%.ai/code/artifact/[%w%-_]+/?$") ~= nil)
end

function M.prompt(name: string?, did: string?, link: string?): string
	local which = `the Design "{name or "Design"}"` .. (if did then ` (did {did})` else "")
	local s = `Share the prototype of {which} as a private Claude artifact: call design_execute with Export(\{ share = true \}), `
		.. "publish the file it writes with the Artifact tool exactly as it is, "
	if M.is_link(link) then
		s ..= `updating the artifact it was shared as before ({link}) so the link stays the same, `
	end
	s ..= "save the link with SetPrototype({ shareUrl = <link> }), and give me the link. Keep it private: I'll share it from claude.ai myself."
	return s
end

-- The prompt into the message box, with a toast; whether it got there.
function M.send(source: any): boolean
	local p = source.prototype and source.prototype:peek() or nil
	local link = if type(p) == "table" and M.is_link(p.shareUrl) then p.shareUrl else nil
	local ok = type(source.compose) == "function" and pcall(source.compose, M.prompt(source.name, source.did, link))
	Toast.show({
		icon = "link",
		title = if ok then "Prompt is in the chat box" else "Couldn't reach the chat box",
		body = if ok then "Send it in a Claude Code chat to get a private link." else "Allow Design to write in the message box (Settings → Plugins).",
		tone = if ok then "info" else "danger",
	})
	return ok == true
end

function M.Section(props: { L: any, source: any, sec: any }): Node
	return ui.component(function(): Node
		local L, source = props.L, props.source
		local sent = ui.use_state(false)
		local p = source.prototype and source.prototype:peek() or nil
		local link = if type(p) == "table" and M.is_link(p.shareUrl) then p.shareUrl else nil
		local function put_link(v: any, label: string)
			source.edit({ { op = "prototype", prototype = { shareUrl = v }, merge = true } }, label)
		end
		local rows: { Node } = {
			ui.row { w_full = true, Kit.button(L, {
				id = "share-link",
				label = if link then "Update share link…" else "Share link…",
				icon = "link",
				grow = 1,
				on_click = function()
					sent:set(M.send(source))
				end,
			}) },
			ui.column {
				id = "share-note",
				w_full = true,
				gap = 4,
				ui.text {
					function(): string
						return if sent:get() then "Prompt put in the chat box: send it." else M.PRIVACY
					end,
					text_size = 12,
					color = L.muted,
					min_w = 0,
				},
				Kit.text(L, M.NEEDS, { color = L.faint }),
			},
			Kit.field(L, {
				id = "share-url",
				tip = "The shared link (paste one, or clear it)",
				leading = ui.div { w = 24, min_w = 24, shrink = 0, h_full = true, pl = 2, items = "center", justify = "center", color = L.faint, Kit.icon("link", 13) },
				placeholder = "No link yet",
				mono = false,
				value = function(): string?
					return link or ""
				end,
				commit = function(t: string)
					t = (string.gsub(t, "^%s+", ""))
					t = (string.gsub(t, "%s+$", ""))
					if t == (link or "") then
						return
					elseif t == "" then
						put_link("__null", "Forget share link")
					elseif M.is_link(t) then
						put_link(t, "Share link")
					else
						Toast.show({ title = "That isn't a Claude artifact's link", body = "It looks like https://claude.ai/artifact/…", tone = "danger" })
					end
				end,
			}),
		}
		return props.sec("Share", nil, rows, { id = "share-head" })
	end)({})
end

return M
