local ADDON_NAME, EH = ...
EH.ADDON_NAME = "epochhead"
EH.VERSION    = "0.8.2"

epochheadDB = epochheadDB or {}

EH.ALLOWED_REALMS = { ["Kezan"]=true, ["Gurubashi"]=true }
-- === GUID anti-dupe (5 min) ===
local ANTI_DUPE_WINDOW = 300  -- 5 minutes
Epoch_DropsData = Epoch_DropsData or {}
Epoch_DropsData.recentGuidHits = Epoch_DropsData.recentGuidHits or {}
local __recentGuidHits = Epoch_DropsData.recentGuidHits

local function shouldSkipGuid(guid)
    if not guid or guid == "" then return false end
    local now = time()
    local last = __recentGuidHits[guid]
    if last and (now - last) < ANTI_DUPE_WINDOW then
        return true
    end
    __recentGuidHits[guid] = now
    return false
end

local function collectLootGuids()
    local seen = {}
    local n = GetNumLootItems and GetNumLootItems() or 0
    for slot = 1, n do
        -- GetLootSourceInfo returns a vararg list: guid1, qty1, guid2, qty2, ...
        local src = {GetLootSourceInfo(slot)}
        for i = 1, #src, 2 do
            local g = src[i]
            if g then seen[g] = true end
        end
    end
    -- Return as an array
    local arr, i = {}, 1
    for g,_ in pairs(seen) do
        arr[i] = g
        i = i + 1
    end
    return arr
end
-- === /GUID anti-dupe ===


function EH.isRealmAllowed(r)
  if not r then return false end
  if EH.ALLOWED_REALMS[r] then return true end
  local rl = string.lower(r)
  for k,_ in pairs(EH.ALLOWED_REALMS) do
    if string.lower(k) == rl then return true end
  end
  return false
end

function EH.now() return time() end

local rngCounter = 0
local function rngHex(n)
  local t = (GetTime and GetTime() or EH.now()) * 1000
  local acc = math.floor(t) + (rngCounter or 0)
  rngCounter = (acc + 1) % 2000000000
  local s = ""
  for _=1,n do
    acc = (acc * 1103515245 + 12345) % 2147483648
    s = s .. string.format("%x", acc % 16)
  end
  return s
end
EH.rngHex = rngHex

local function newSessionId()
  local t = date("!%Y%m%d%H%M%S", EH.now())
  return t .. "-" .. rngHex(8)
end
EH.newSessionId = newSessionId

function EH.dprint(...)
  if epochheadDB.state and epochheadDB.state.debug then
    if tostringall then
      DEFAULT_CHAT_FRAME:AddMessage("|cff99ccff[epochhead]|r "..table.concat({tostringall(...)}, " "))
    else
      local t = {}
      for i=1,select("#", ...) do t[#t+1] = tostring(select(i, ...)) end
      DEFAULT_CHAT_FRAME:AddMessage("|cff99ccff[epochhead]|r "..table.concat(t, " "))
    end
  end
end

local function clamp()
  local ev = epochheadDB.events
  if #ev <= 30000 then return end
  local cut = #ev - 30000
  for i=1,cut do ev[i]=nil end
  local out = {}
  for i=1,#ev do if ev[i] then out[#out+1]=ev[i] end end
  epochheadDB.events = out
end

function EH.push(ev)
  ev.session = epochheadDB.state and epochheadDB.state.sessionId or nil

  if epochheadDB.meta and epochheadDB.meta.player then
    local p = epochheadDB.meta.player
    -- keep level fresh in metadata only
    if UnitLevel then
      p.level = UnitLevel("player")
    end
    -- realm gate using metadata
    if not EH.isRealmAllowed(p.realm) then
      epochheadDB.state = epochheadDB.state or {}
      epochheadDB.state.droppedByRealm = (epochheadDB.state.droppedByRealm or 0) + 1
      if epochheadDB.state.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff99ccff[epochhead]|r drop (realm not allowed): "..tostring(p.realm or "?"))
      end
      return
    end
  end

  table.insert(epochheadDB.events, ev)
  epochheadDB.state.eventsThisSession = (epochheadDB.state.eventsThisSession or 0) + 1
  clamp()
end

function EH.init()
  if not epochheadDB.meta then
    local v, build, dateStr, toc = GetBuildInfo()
    local pn, pr = UnitName("player")
    local className, class = UnitClass("player")
    local raceName, race = UnitRace("player")
    local faction = UnitFactionGroup("player")
    local realmName = GetRealmName()
    epochheadDB.meta = {
      addon=EH.ADDON_NAME, version=EH.VERSION, clientVersion=v, clientBuild=build, interface=toc, created=EH.now(),
      player={ name=pn, realm=realmName, class=class, className=className, race=race, raceName=raceName, faction=faction },
      allowedRealms={"Kezan","Gurubashi"}, realmAllowed=EH.isRealmAllowed(realmName)
    }
  end
  epochheadDB.events = epochheadDB.events or {}
  epochheadDB.state  = epochheadDB.state  or {
    debug=false, sessionStarted=EH.now(), sessionId=newSessionId(), eventsThisSession=0,
    settings={ snapPrintCooldown=30, printMouseover=false }
  }
  if not epochheadDB.state.sessionId then epochheadDB.state.sessionId = newSessionId() end
  epochheadDB.state.settings = epochheadDB.state.settings or { snapPrintCooldown=30, printMouseover=false }
end


------------------------------------------------------------
-- Version tracking & notify
------------------------------------------------------------
EH.VER_PREFIX = "EHVER"
EH._verLatest = EH.VERSION
EH._verLatestFrom = nil
EH._verNotified = false

local function parseVer(v)
  if not v then return {0,0,0} end
  local a,b,c = tostring(v):match("^(%d+)%.(%d+)%.(%d+)$")
  if not a then
    -- fallback: split on dots, take numeric
    local p = {}
    for num in tostring(v):gmatch("(%%d+)") do p[#p+1] = tonumber(num,10) or 0 end
    a,b,c = p[1] or 0, p[2] or 0, p[3] or 0
  end
  return {tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0}
end

function EH.compareVersion(a, b)
  local A, B = parseVer(a), parseVer(b)
  for i=1,3 do
    if (A[i] or 0) > (B[i] or 0) then return 1 end
    if (A[i] or 0) < (B[i] or 0) then return -1 end
  end
  return 0
end

local function verMsg(msg) if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff99ccffEpochHead|r: "..msg) end end

local function tryRegisterPrefix()
  if RegisterAddonMessagePrefix then
    pcall(RegisterAddonMessagePrefix, EH.VER_PREFIX)
  end
end

local function canSend(channel)
  if channel == "GUILD" then return IsInGuild and IsInGuild() end
  if channel == "RAID" then return UnitInRaid and UnitInRaid("player") end
  if channel == "PARTY" then
    if IsInGroup then return IsInGroup() end
    -- 3.3.5 fallback
    for i=1,4 do if UnitExists("party"..i) then return true end end
    return false
  end
  return false
end

function EH.broadcastVersion()
  tryRegisterPrefix()
  local payload = "VER:"..tostring(EH.VERSION or "0.0.0")
  if canSend("GUILD") then SendAddonMessage(EH.VER_PREFIX, payload, "GUILD") end
  if canSend("RAID")  then SendAddonMessage(EH.VER_PREFIX, payload, "RAID") end
  if canSend("PARTY") then SendAddonMessage(EH.VER_PREFIX, payload, "PARTY") end
end

function EH._onAddonMsg(prefix, message, channel, sender)
  if prefix ~= EH.VER_PREFIX or type(message) ~= "string" then return end
  local their = message:match("^VER:(.+)$")
  if their then
    local cmp = EH.compareVersion(their, EH._verLatest or EH.VERSION)
    if cmp == 1 then
      EH._verLatest = their
      EH._verLatestFrom = sender
    end
    -- If we're behind, notify once per session
    if EH.compareVersion(their, EH.VERSION) == 1 and not EH._verNotified then
      verMsg(("|cffff4444Your EpochHead is out of date|r (yours %s, latest %s from %s)."):format(tostring(EH.VERSION), tostring(their), tostring(sender or "?")))
      verMsg("Grab the latest build when you can.")
      EH._verNotified = true
    end
    return
  end
  if message == "VER?" then
    local me = "VER:"..tostring(EH.VERSION or "0.0.0")
    -- reply privately to avoid spam
    if sender and sender ~= UnitName("player") then
      SendAddonMessage(EH.VER_PREFIX, me, "WHISPER", sender)
    end
  end
end

-- Lightweight timer for post-login broadcast (no C_Timer in 3.3.5)
do
  local vf = CreateFrame("Frame")
  local t0, sent = 0, false
  vf:RegisterEvent("PLAYER_LOGIN")
  vf:RegisterEvent("PLAYER_ENTERING_WORLD")
  vf:RegisterEvent("CHAT_MSG_ADDON")
  vf:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
      EH._onAddonMsg(...)
    else
      -- throttle to fire once shortly after entering world
      if not sent then
        t0 = GetTime() + 3
        sent = true
        self:SetScript("OnUpdate", function(self, elapsed)
          if GetTime() >= t0 then
            EH.broadcastVersion()
            self:SetScript("OnUpdate", nil)
          end
        end)
      end
    end
  end)
end

-- Optional: /eh ver
if SlashCmdList and SlashCmdList["EPOCHHEAD"] then
  local prev = SlashCmdList["EPOCHHEAD"]
  SlashCmdList["EPOCHHEAD"] = function(msg)
    msg = tostring(msg or ""):lower()
    if msg == "ver" or msg == "version" then
      local latest = EH._verLatest or EH.VERSION
      verMsg(("Version: |cffcceeff%s|r (latest seen: |cffcceeff%s|r%s)")
        :format(tostring(EH.VERSION), tostring(latest), EH._verLatestFrom and (" from "..EH._verLatestFrom) or ""))
      EH.broadcastVersion()
      return
    end
    prev(msg)
  end
end

