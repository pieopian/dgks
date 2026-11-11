-- wow_shim.lua: a minimal emulation of the WoW addon environment so dgks.lua can be
-- exercised under plain Lua 5.1. It records every observable side effect (sounds,
-- addon messages, chat, emotes, prints) so tests can assert on behaviour.
--
-- It simulates one kind of client, Retail 12.x / WoW Forever: no CombatLogGetCurrentEventInfo,
-- registering the combat log events is refused, and character names carry a surname.

local M = {}

M.ADDON_DIR = nil -- set by the runner

local function deepcopy(t)
	if type(t) ~= "table" then return t end
	local c = {}
	for k, v in pairs(t) do c[deepcopy(k)] = deepcopy(v) end
	return c
end
M.deepcopy = deepcopy

-- A "secret value" stand-in. Real secrets throw on comparison; here we make the
-- handler's job the same: it must detect it with issecretvalue() and not touch it.
function M.secret(label)
	local s = setmetatable({ __secret = true, label = label }, {
		__eq = function() error("attempt to compare a secret value") end,
		__concat = function(a, b) return tostring(a) .. tostring(b) end,
		__tostring = function() return "<SECRET>" end,
	})
	return s
end

function M.resetRecorders()
	M.frames = {}
	M.timers = {}
	M.secretChecks = {}
	M.sounds = {}
	M.comms = {}
	M.chat = {}
	M.emotes = {}
	M.prints = {}
	M.pours = {}
	M.forbidden = {}
	M.uiErrors = {}
	M.pourThrows = false
	M.screenshots = 0
	M.registeredPrefixes = {}
	M.now = 1000
end

-- World state the tests can poke
function M.resetWorld()
	M.player = { guid = "Player-4613-00B5553D", name = "Marshed", surname = "Malloe", realm = "70" }
	M.players = {
		["Player-4613-00B5553D"] = { class = "Warrior", eclass = "WARRIOR", race = "Human", erace = "Human", sex = 2, name = "Marshed Malloe", realm = "70" },
		["Player-4613-00B55500"] = { class = "Mage", eclass = "MAGE", race = "Gnome", erace = "Gnome", sex = 3, name = "Strawberrie Jaeme", realm = "70" },
	}
	M.npcs = { ["Creature-0-4615-0-2169-30-000043FE58"] = "Kobold Vermin" }
	M.petGUID = nil
	M.targetGUID = nil
	M.inGuild = true
	M.inParty = false
	M.inRaid = false
	M.isBG = false
	M.isArena = false
	M.bnFriends = {}		-- Battle.net friends online, each a list of game accounts
	M.cvars = {}			-- console variables that differ from "1", e.g. Sound_EnableMusic = "0"
	M.recapEvents = nil		-- what C_DeathRecap.GetRecapEvents returns
end

local function bandImpl(a, b)
	local r, bitv = 0, 1
	while a > 0 and b > 0 do
		if a % 2 == 1 and b % 2 == 1 then r = r + bitv end
		a, b, bitv = math.floor(a / 2), math.floor(b / 2), bitv * 2
	end
	return r
end

function M.install()
	M.resetRecorders()
	M.resetWorld()
	M.forbiddenEvents = {}

	-- Lua aliases WoW provides
	_G.floor, _G.ceil, _G.abs = math.floor, math.ceil, math.abs
	_G.tinsert, _G.tremove, _G.wipe = table.insert, table.remove, function(t) for k in pairs(t) do t[k] = nil end return t end
	_G.strmatch, _G.strfind, _G.format, _G.gsub, _G.gmatch = string.match, string.find, string.format, string.gsub, string.gmatch
	_G.strbyte, _G.strchar, _G.strsub, _G.strlen, _G.strlower, _G.strupper = string.byte, string.char, string.sub, string.len, string.lower, string.upper
	_G.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
	_G.strsplit = function(sep, s) local t = {} for piece in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do t[#t + 1] = piece end return unpack(t) end
	_G.strjoin = function(sep, ...) return table.concat({ ... }, sep) end
	_G.time, _G.date = os.time, os.date
	_G.GetTime = function() return M.now end
	_G.bit = { band = bandImpl, bor = function(a, b) return a + b - bandImpl(a, b) end }
	_G.message = function(m) M.prints[#M.prints + 1] = "MESSAGE:" .. tostring(m) end
	_G.debugstack = function() return "" end
	_G.geterrorhandler = function() return function(e) error(e, 0) end end
	_G.seterrorhandler = function() end
	_G.hooksecurefunc = function(tbl, name, fn)
		if type(tbl) == "string" then tbl, name, fn = _G, tbl, name end
		local orig = tbl[name]
		tbl[name] = function(...) local r = { orig(...) } fn(...) return unpack(r) end
	end
	_G.securecallfunction = function(fn, ...) return fn(...) end
	_G.print = function(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end M.prints[#M.prints + 1] = table.concat(t, " ") end

	-- Secret values. Plain Lua 5.1 cannot make `secret == "x"` throw (the __eq metamethod is only
	-- consulted for two tables sharing it), so instead every issecretvalue() call is recorded and tests
	-- assert the guard was consulted for the values that could be secret.
	_G.issecretvalue = function(v)
		M.secretChecks[#M.secretChecks + 1] = v
		return type(v) == "table" and rawget(v, "__secret") == true
	end

	-- WoW's string.format understands positional specifiers (%1$s, %2$s) used by GlobalStrings.
	local rawformat = string.format
	local function wowformat(fmt, ...)
		if type(fmt) ~= "string" or not fmt:find("%%%d+%$") then return rawformat(fmt, ...) end
		local args, picked, n = { ... }, {}, 0
		local plain = fmt:gsub("%%(%d+)%$", function(pos)
			n = n + 1
			picked[n] = args[tonumber(pos)]
			return "%"
		end)
		return rawformat(plain, unpack(picked, 1, n))
	end
	string.format = wowformat
	_G.format = wowformat

	-- The simulated client: Retail 12.x / WoW Forever
	_G.WOW_PROJECT_MAINLINE = 1
	_G.WOW_PROJECT_CLASSIC = 2
	_G.WOW_PROJECT_ID = 18
	_G.LE_EXPANSION_LEVEL_CURRENT = 0
	_G.GetBuildInfo = function() return "1.60.1", "70888", "Nov 4 2026", 16001 end
	_G.CombatLogGetCurrentEventInfo = nil
	_G.C_CombatLog = { IsCombatLogRestricted = function() return true end }
	M.forbiddenEvents["COMBAT_LOG_EVENT_UNFILTERED"] = true
	M.forbiddenEvents["COMBAT_LOG_EVENT"] = true
	M.unknownEvents = {}
	_G.RegionalUniqueNamesEnabled = function() return true end
	-- Frames
	_G.CreateFrame = function(ftype, name, parent, template)
		local f = { events = {}, scripts = {}, ftype = ftype, name = name }
		function f:RegisterEvent(e)
			if M.forbiddenEvents[e] then M.forbidden[#M.forbidden + 1] = e return end
			-- The real client throws on events it does not know (e.g. PARTY_KILL before 12.0)
			if M.unknownEvents and M.unknownEvents[e] then error("Attempt to register unknown event \"" .. tostring(e) .. "\"") end
			self.events[e] = true
		end
		function f:UnregisterEvent(e) self.events[e] = nil end
		function f:IsEventRegistered(e) return self.events[e] == true end
		function f:SetScript(k, fn) self.scripts[k] = fn end
		function f:GetScript(k) return self.scripts[k] end
		function f:HookScript(k, fn)
			local old = self.scripts[k]
			if old then self.scripts[k] = function(...) old(...) fn(...) end else self.scripts[k] = fn end
		end
		for _, m in ipairs({ "Show", "Hide", "SetPoint", "SetSize", "SetWidth", "SetHeight", "SetFrameStrata", "SetAllPoints",
			"RegisterUnitEvent", "SetParent", "ClearAllPoints", "SetAlpha", "EnableMouse", "SetMovable", "SetScale" }) do
			f[m] = function() end
		end
		f.IsShown = function() return false end
		M.frames[#M.frames + 1] = f
		if name then _G[name] = f end
		return f
	end
	_G.UIParent = _G.CreateFrame("Frame", "UIParent")
	_G.DEFAULT_CHAT_FRAME = { AddMessage = function(self, msg) M.prints[#M.prints + 1] = tostring(msg) end }
	_G.SELECTED_CHAT_FRAME = _G.DEFAULT_CHAT_FRAME
	_G.UIErrorsFrame = { AddMessage = function(self, msg, r, g, b, hold) M.uiErrors[#M.uiErrors + 1] = tostring(msg) end }

	-- Timers
	_G.C_Timer = { After = function(delay, fn) M.timers[#M.timers + 1] = fn end }

	-- Units
	_G.UnitGUID = function(u)
		u = tostring(u):lower()
		if u == "player" then return M.player.guid end
		if u == "pet" then return M.petGUID end
		if u == "target" then return M.targetGUID end
		return nil
	end
	_G.UnitName = function(u) if tostring(u):lower() == "player" then return M.player.name end return nil end
	_G.UnitNameUnmodified = function(u)
		if tostring(u):lower() == "player" then return M.player.name, M.player.surname end

	end
	_G.GetUnitName = function(u) return _G.UnitName(u) end
	_G.UnitIsPlayer = function() return false end
	_G.UnitIsEnemy = function() return false end
	_G.UnitHealth = function() return 100 end
	_G.UnitHealthMax = function() return 100 end
	_G.UnitFactionGroup = function() return "Alliance", "Alliance" end
	_G.UnitInParty = function() return M.inParty end
	_G.UnitInBattleground = function() return M.isBG and 1 or nil end
	_G.IsActiveBattlefieldArena = function() return M.isArena, false end
	_G.IsInRaid = function() return M.inRaid end
	_G.IsInGroup = function() return M.inParty or M.inRaid end
	_G.IsInGuild = function() return M.inGuild end
	_G.IsInInstance = function()
		if M.isBG then return true, "pvp" elseif M.isArena then return true, "arena" end
		return false, "none"
	end
	_G.InCombatLockdown = function() return false end
	_G.GetRealZoneText = function() return "Elwynn Forest" end
	_G.GetRealmName = function() return M.player.realm end
	_G.GetPlayerInfoByGUID = function(guid)
		if type(guid) ~= "string" then error("Usage: GetPlayerInfoByGUID(guid)") end
		local p = M.players[guid]
		if not p then return nil end
		return p.class, p.eclass, p.race, p.erace, p.sex, p.name, p.realm
	end
	_G.UnitNameFromGUID = function(guid)
		if type(guid) ~= "string" then error("Usage: UnitNameFromGUID(guid)") end
		return M.npcs[guid]
	end
	_G.C_PlayerInfo = { GUIDIsPlayer = function(guid)
		if type(guid) ~= "string" then error("Usage: C_PlayerInfo.GUIDIsPlayer(guid)") end
		return guid:find("^Player%-") ~= nil
	end }
	_G.C_PvP = {
		IsArena = function() return M.isArena end,
		IsBattleground = function() return M.isBG end,
	}

	_G.C_DeathRecap = { GetRecapEvents = function() return M.recapEvents end }
	-- Ambiguate(name, context): strips "-Realm" when it is our own realm, as the client does.
	_G.Ambiguate = function(name, ctx)
		if type(name) ~= "string" then error("Usage: Ambiguate(name, context)") end
		local short, realm = name:match("^(.-)%-(.+)$")
		if short and realm == M.player.realm then return short end
		return name
	end


	-- Output side effects
	_G.PlaySoundFile = function(path, chan) M.sounds[#M.sounds + 1] = { path = path, channel = chan } return true, 1 end
	_G.GetCVar = function(name) local v = M.cvars[name] if v ~= nil then return v end return "1" end	-- M.cvars overrides single settings
	_G.SetCVar = function() end
	_G.SendChatMessage = function(msg, chatType, lang, target) M.chat[#M.chat + 1] = { msg = msg, chatType = chatType, target = target } end
	_G.DoEmote = function(token, target) M.emotes[#M.emotes + 1] = { token = token, target = target } end
	_G.Screenshot = function() M.screenshots = M.screenshots + 1 end
	_G.SendSystemMessage = function(msg) M.prints[#M.prints + 1] = "SYSTEM:" .. tostring(msg) end
	_G.C_ChatInfo = {
		RegisterAddonMessagePrefix = function(p) M.registeredPrefixes[p] = true return 0 end,
		SendAddonMessage = function(prefix, text, chatType, target)
			M.comms[#M.comms + 1] = { prefix = prefix, text = text, dist = chatType, target = target, via = "C_ChatInfo" }
			return 0
		end,
	}
	-- Battle.net friends: M.bnFriends is a list of friends, each a list of game-account tables
	-- (the Battle.net app, the mobile app, a game ...), in the order the client lists them.
	_G.BNGetNumFriends = function() return #M.bnFriends, #M.bnFriends end
	_G.C_BattleNet = {
		GetFriendNumGameAccounts = function(i) return M.bnFriends[i] and #M.bnFriends[i] or 0 end,
		GetFriendGameAccountInfo = function(i, j) return M.bnFriends[i] and M.bnFriends[i][j] end,
	}
	_G.C_FriendList = { GetNumFriends = function() return 0 end, GetFriendInfoByIndex = function() return nil end }
	_G.C_AddOns = { IsAddOnLoaded = function() return true end, LoadAddOn = function() return true end,
		GetAddOnMetadata = function() return nil end }	-- dgks.lua reads addon metadata while it loads
	_G.Settings = { OpenToCategory = function() end }
	_G.SlashCmdList = {}

	-- Global strings / constants. The duel strings are the real enUS GlobalStrings, filled with
	-- (winner, loser); the positional %N$s is handled by the format() override above.
	_G.LE_PARTY_CATEGORY_HOME = 1
	_G.LE_PARTY_CATEGORY_INSTANCE = 2
	_G.COMBATLOG_OBJECT_TYPE_PLAYER = 0x00000400
	_G.COMBATLOG_OBJECT_AFFILIATION_MINE = 0x00000001
	_G.DUEL_WINNER_KNOCKOUT = "%1$s has defeated %2$s in a duel"
	_G.DUEL_WINNER_RETREAT = "%2$s has fled from %1$s in a duel"
	_G.DUEL_COUNTDOWN = "Duel starting: %d"
	_G.WHISPER = "Whisper"

	-- Libraries: real LibStub + real AceSerializer, fakes for the rest
	_G.LibStub = nil
	dofile(M.ADDON_DIR .. "/libs/LibStub/LibStub.lua")
	dofile(M.ADDON_DIR .. "/libs/AceSerializer-3.0/AceSerializer-3.0.lua")
	local LibStub = _G.LibStub

	local AceAddon = LibStub:NewLibrary("AceAddon-3.0", 1)
	function AceAddon:NewAddon(name)
		local a = { name = name }
		function a:RegisterComm(prefix) M.registeredPrefixes[prefix] = true end
		function a:SendCommMessage(prefix, text, dist, target)
			M.comms[#M.comms + 1] = { prefix = prefix, text = text, dist = dist, target = target, via = "AceComm" }
		end
		function a:Print(...)
			local t = {}
			for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
			M.prints[#M.prints + 1] = table.concat(t, " ")
		end
		function a:Serialize(...) return LibStub("AceSerializer-3.0"):Serialize(...) end
		function a:Deserialize(s) return LibStub("AceSerializer-3.0"):Deserialize(s) end
		function a:SetSinkStorage() end
		function a:Pour(msg)
			-- A test can make the text output fail, as a real output can
			if M.pourThrows then error("simulated text output failure") end

			M.pours[#M.pours + 1] = tostring(msg)
		end
		function a:GetSinkAce3OptionsDataTable() return { type = "group", args = {} } end
		function a:RegisterEvent() end
		return a
	end

	local AceDB = LibStub:NewLibrary("AceDB-3.0", 1)
	function AceDB:New(name, defaults)
		local db = { defaults = defaults, profile = deepcopy(defaults.profile) }
		function db:ResetProfile() self.profile = deepcopy(self.defaults.profile) end
		_G[name] = _G[name] or {}
		return db
	end

	local Reg = LibStub:NewLibrary("AceConfigRegistry-3.0", 1)
	Reg.tables = {}
	function Reg:RegisterOptionsTable(name, fn) self.tables[name] = fn end

	local Dlg = LibStub:NewLibrary("AceConfigDialog-3.0", 1)
	function Dlg:AddToBlizOptions(app, name, parent) return _G.CreateFrame("Frame"), name or app end
end

-- dgks.lua as a packaged release ships it: with the --@debug@ blocks commented out, using the same
-- substitution the packager makes.
function M.releaseSource()
	local f = assert(io.open(M.ADDON_DIR .. "/dgks.lua", "rb"))
	local src = f:read("*a")
	f:close()
	return (src:gsub("%-%-@debug@", "--[===[@debug@"):gsub("%-%-@end%-debug@", "--@end-debug@]===]"))
end

-- Load dgks.lua fresh and run its lifecycle like AceAddon would at PLAYER_LOGIN. By default the
-- release build is loaded, because that is what players run and debug-only code can hide a problem.
-- Pass "source" to load the file as it is in the repository, with the debug blocks live.
function M.loadAddon(build)
	local chunk, err
	if build == "source" then
		chunk, err = loadfile(M.ADDON_DIR .. "/dgks.lua")
	else
		chunk, err = loadstring(M.releaseSource(), "=dgks.lua (release)")
	end
	assert(chunk, err)
	chunk("dgks", {})
	_G.dgks:OnInitialize()
	_G.dgks:OnEnable()
	return _G.dgks
end

-- Dispatch an event to every frame registered for it, then run queued timers.
function M.fire(event, ...)
	local delivered = 0
	for _, f in ipairs(M.frames) do
		if f.events[event] and f.scripts.OnEvent then
			f.scripts.OnEvent(f, event, ...)
			delivered = delivered + 1
		end
	end
	M.flushTimers()
	return delivered
end

function M.flushTimers()
	local guard = 0
	while #M.timers > 0 and guard < 100 do
		local pending = M.timers
		M.timers = {}
		for _, fn in ipairs(pending) do fn() end
		guard = guard + 1
	end
end


function M.commsWith(dist)
	local out = {}
	for _, c in ipairs(M.comms) do if c.dist == dist then out[#out + 1] = c end end
	return out
end


-- Was issecretvalue() consulted for this exact value?
function M.wasSecretChecked(v)
	for _, c in ipairs(M.secretChecks) do if c == v then return true end end
	return false
end


return M
