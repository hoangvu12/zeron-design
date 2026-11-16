--!nonstrict
-- design_guide, and the core guide a chat gets with its first design call
-- (as native's guide_once): once per chat per service run.

local Text = require("./guide_text")

local M = {}

local given: { [string]: boolean } = {}
-- Kept in zeron.db too (`M.keep = { get, set }`, set by the service), so a
-- service restart (an update, 5 idle minutes) doesn't send it again.
M.keep = nil :: any

local function was_given(key: string): boolean
	if given[key] then
		return true
	end
	if M.keep and M.keep.get("guide:" .. key) then
		given[key] = true
		return true
	end
	return false
end

local function mark(key: string)
	given[key] = true
	if M.keep then
		M.keep.set("guide:" .. key, true)
	end
end

-- (N4) Keyed by the guide's version too: a chat that had an older version
-- gets the new one once, with its first result after the update.
local function key_of(chat: string?): string
	local v = Text.VERSION or 1
	local k = chat or "none"
	return if v > 1 then `{k}@v{v}` else k
end

function M.first(chat: string?, result: any): any
	local key = key_of(chat)
	if not was_given(key) then
		local had_older = (Text.VERSION or 1) > 1 and was_given(chat or "none")
		mark(key)
		result.guide = Text.CORE
		result.guide_note = (if had_older then `The core guide changed (now version {Text.VERSION}): read it again. ` else "This is the core guide, given once per chat. ")
			.. "design_guide gives topic guides: " .. table.concat(Text.ORDER, ", ")
	end
	return result
end

function M.topic(name: any, chat: string?): any
	if name == nil or name == "" or name == "core" then
		-- The chat has the core guide now: design_* calls don't send it again.
		mark(key_of(chat))
		return { guide = Text.CORE, topics = Text.ORDER }
	end
	local t = Text.TOPICS[name]
	if not t then
		return { error = `no topic "{tostring(name)}": topics are ` .. table.concat(Text.ORDER, ", ") }
	end
	return { topic = name, guide = t }
end

return M
