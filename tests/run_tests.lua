-- run_tests.lua: behaviour tests for dgks.lua, run under plain Lua 5.1 against wow_shim.lua
-- (a small simulation of the WoW addon API). No game client is needed.
--
-- Usage, from the repository root:   lua5.1 tests/run_tests.lua .
-- The exit code is the number of failed tests.

local addonDir = arg[1] or "."
package.path = (arg[0]:match("^(.*)[/\\]") or ".") .. "/?.lua;" .. package.path
local W = require("wow_shim")
W.ADDON_DIR = addonDir

local PLAYER = "Player-4613-00B5553D"	-- the player:  Marshed Malloe
local VICTIM = "Player-4613-00B55500"	-- an enemy:    Strawberrie Jaeme
local VICTIM2 = "Player-4613-00B55501"	-- another one: Second Victim
local NPC = "Creature-0-4615-0-2169-30-000043FE58"	-- Kobold Vermin
local ME = "Marshed Malloe"
local passed, failed = 0, 0

-- The client delivers our own GUILD/PARTY/RAID/INSTANCE_CHAT broadcasts back to us, and a whisper
-- addressed to ourselves. echo() plays that part, so the tests do not depend on whether dgks handles
-- its own kill before or after the broadcast comes back.
local delivered
local function echo(dgks)
	local n = #W.comms
	for i = delivered + 1, n do
		local c = W.comms[i]
		if c.dist ~= "WHISPER" or c.target == ME then
			dgks:OnCommReceived(c.prefix, c.text, c.dist, ME)
		end
	end
	delivered = n
	W.flushTimers()
end

local function kill(dgks, attacker, target)
	W.fire("PARTY_KILL", attacker or PLAYER, target or VICTIM)
	echo(dgks)
end

local function lastSound()
	local s = W.sounds[#W.sounds]
	return s and tostring(s.path):match("[^\\/]+$") or "none"
end

local function logHas(dgks, text)
	for _, line in ipairs(dgks.db.profile.killlog) do
		if line:find(text, 1, true) then return true end
	end
	return false
end

-- test(name, fn [, setup]): loads a fresh copy of the addon on the Retail 12 / WoW Forever profile.
-- fn(dgks) passes by returning true; setup() runs before the addon loads.
local function test(name, fn, setup)
	W.install("forever")
	delivered = 0
	W.players[VICTIM2] = { class = "Rogue", eclass = "ROGUE", race = "Human", erace = "Human", sex = 2, name = "Second Victim", realm = "70" }
	if setup then setup() end
	local ok, result = pcall(function()
		local dgks = W.loadAddon()
		return fn(dgks)
	end)
	if ok and result == true then
		passed = passed + 1
		io.write("  PASS  ", name, "\n")
	else
		failed = failed + 1
		io.write("  FAIL  ", name, (not ok) and ("\n        " .. tostring(result)) or "", "\n")
	end
end

io.write("dgks tests against ", addonDir, "\n")

-- Loading ---------------------------------------------------------------------------------------
test("the addon loads and enables", function() return true end)

test("the release build compiles (debug blocks stripped the way the packager does it)", function()
	local f = assert(io.open(addonDir .. "/dgks.lua", "rb")); local src = f:read("*a"); f:close()
	local out = src:gsub("%-%-@debug@", "--[===[@debug@"):gsub("%-%-@end%-debug@", "--@end-debug@]===]")
	local chunk, err = loadstring(out, "=dgks.lua (release)")
	if not chunk then error(err, 0) end
	return true
end)

-- Kills -----------------------------------------------------------------------------------------
test("my kill on a player: one sound, one line of text, one stat entry", function(dgks)
	kill(dgks)
	local list = dgks.db.profile.killList["Strawberrie Jaeme"]
	return #W.sounds == 1 and lastSound() == "ownage.ogg" and logHas(dgks, "Marshed Malloe killed Strawberrie Jaeme!")
		and list ~= nil and #list == 1
end)

test("the same kill delivered back on two channels still counts once", function(dgks)
	W.inParty = true
	kill(dgks)
	return #W.sounds == 1 and #dgks.db.profile.killList["Strawberrie Jaeme"] == 1
end)

test("a second kill 15 seconds later moves up a rank", function(dgks)
	kill(dgks)
	W.now = W.now + 15
	kill(dgks, PLAYER, VICTIM2)
	return #W.sounds == 2 and lastSound() == "killingspree.ogg" and dgks.db.profile.maxstreak == 2
end)

test("a second kill within 10 seconds is a double kill", function(dgks)
	kill(dgks)
	W.now = W.now + 5
	kill(dgks, PLAYER, VICTIM2)
	return #W.sounds == 2 and lastSound() == "doublekill.ogg" and logHas(dgks, "DOUBLEKILL")
end)

test("an NPC kill only counts with the PvE option on", function(dgks)
	kill(dgks, PLAYER, NPC)
	if #W.sounds ~= 0 then return false end
	dgks.db.profile.dopve = true
	kill(dgks, PLAYER, NPC)
	return #W.sounds == 1 and logHas(dgks, "killed Kobold Vermin!")
end)

test("a kill event with secret GUIDs is ignored without an error", function(dgks)
	W.fire("PARTY_KILL", W.secret("attacker"), W.secret("target"))
	echo(dgks)
	return #W.sounds == 0 and #W.comms == 0
end)

test("with sounds switched off nothing is played, the kill is still logged", function(dgks)
	dgks.db.profile.dosound = false
	kill(dgks)
	return #W.sounds == 0 and logHas(dgks, "killed Strawberrie Jaeme!")
end)

-- Broadcasts -------------------------------------------------------------------------------------
test("a kill is broadcast to the guild", function()
	W.fire("PARTY_KILL", PLAYER, VICTIM)
	local c = W.commsWith("GUILD")
	return #c == 1 and c[1].prefix == "dgks"
end)

test("inside a battleground a kill is broadcast to INSTANCE_CHAT, not PARTY", function()
	W.isBG = true
	W.inParty = true
	W.fire("ZONE_CHANGED_NEW_AREA")
	W.fire("PARTY_KILL", PLAYER, VICTIM)
	return #W.commsWith("INSTANCE_CHAT") >= 1 and #W.commsWith("PARTY") == 0
end)

test("a guildmate's kill is heard and shown, and not added to my stats", function(dgks)
	dgks:OnCommReceived("dgks", dgks:Serialize("Strawberrie Jaeme", "Some Victim", 1234, 1, 0), "GUILD", "Strawberrie Jaeme")
	W.flushTimers()
	return #W.sounds == 1 and logHas(dgks, "Strawberrie Jaeme killed Some Victim!")
		and dgks.db.profile.killList["Some Victim"] == nil
end)

test("with broadcasts off, other players' kills are ignored", function(dgks)
	dgks.db.profile.dobroadcasts = false
	dgks:OnCommReceived("dgks", dgks:Serialize("Strawberrie Jaeme", "Some Victim", 1234, 1, 0), "GUILD", "Strawberrie Jaeme")
	W.flushTimers()
	return #W.sounds == 0
end)

test("a friend on the other faction is not whispered", function()
	W.bnFriends = { { { characterName = "Anthos Hyde", factionName = "Horde", realmName = "SomeRealm", clientProgram = "WoW", wowProjectID = 18, isOnline = true } } }
	W.fire("PARTY_KILL", PLAYER, VICTIM)
	for _, c in ipairs(W.commsWith("WHISPER")) do
		if c.target == "Anthos Hyde" then return false end
	end
	return true
end)

test("a version request is answered with a whisper to the sender", function(dgks)
	dgks:OnCommReceived("dgksV", "1.0", "GUILD", "Strawberrie Jaeme")
	local w = W.commsWith("WHISPER")
	return #w == 1 and w[1].prefix == "dgksVR" and w[1].target == "Strawberrie Jaeme"
end)

-- Duels -----------------------------------------------------------------------------------------
test("a duel win is detected from the system message", function(dgks)
	W.fire("CHAT_MSG_SYSTEM", string.format(DUEL_WINNER_KNOCKOUT, ME, "Strawberrie Jaeme"))
	echo(dgks)
	return #W.sounds == 1 and logHas(dgks, "Marshed Malloe has defeated Strawberrie Jaeme!")
end)

test("a duel loss is logged and counts toward the death streak", function(dgks)
	W.fire("CHAT_MSG_SYSTEM", string.format(DUEL_WINNER_KNOCKOUT, "Strawberrie Jaeme", ME))
	echo(dgks)
	return logHas(dgks, "You were defeated by Strawberrie Jaeme.") and dgks.db.profile.maxdeathstreak == 1
end)

test("fleeing a duel plays the humiliation sound", function(dgks)
	W.fire("CHAT_MSG_SYSTEM", string.format(DUEL_WINNER_RETREAT, "Strawberrie Jaeme", ME))
	echo(dgks)
	return lastSound() == "humiliation.ogg" and logHas(dgks, "You were defeated by Strawberrie Jaeme.")
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed)
