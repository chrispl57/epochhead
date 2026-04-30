local ADDON_NAME, EH = ...
EH.ADDON_NAME     = "epochhead"
EH.VERSION        = "0.9.43"
EH.SCHEMA_VERSION = 2
EH.MAX_QUEUE      = 50000

epochheadDB = epochheadDB or {}

-- Realm allow-list: keys normalized to lowercase.
EH.ALLOWED_REALMS = { ["kezan"]=true, ["gurubashi"]=true }

function EH.isRealmAllowed(r)
  if not r then return false end
  return EH.ALLOWED_REALMS[string.lower(tostring(r))] == true
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

-- Opt-in gate. Default is opted IN (existing users keep collecting);
-- `/eh optout` flips it off until re-enabled.
function EH.isCollectionEnabled()
  local st = epochheadDB and epochheadDB.state
  if not st then return true end
  if st.optedOut == true then return false end
  return true
end

local function clamp()
  local ev = epochheadDB.events
  local max = EH.MAX_QUEUE
  if #ev <= max then return end
  -- Drop oldest in a single pass without O(n^2) table.remove.
  local cut = #ev - max
  local out = {}
  for i = cut + 1, #ev do out[#out+1] = ev[i] end
  epochheadDB.events = out
end
EH.clampQueue = clamp

function EH.push(ev)
  epochheadDB.state  = epochheadDB.state  or {}
  epochheadDB.events = epochheadDB.events or {}

  if not EH.isCollectionEnabled() then
    epochheadDB.state.droppedByOptOut = (epochheadDB.state.droppedByOptOut or 0) + 1
    return
  end

  ev.session = epochheadDB.state.sessionId

  if epochheadDB.meta and epochheadDB.meta.player then
    local p = epochheadDB.meta.player
    if UnitLevel then p.level = UnitLevel("player") end
    if not EH.isRealmAllowed(p.realm) then
      epochheadDB.state.droppedByRealm = (epochheadDB.state.droppedByRealm or 0) + 1
      if EH._debug then
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
    local pn = UnitName("player")
    local className, class = UnitClass("player")
    local raceName, race = UnitRace("player")
    local faction = UnitFactionGroup("player")
    local realmName = GetRealmName()
    epochheadDB.meta = {
      addon=EH.ADDON_NAME, version=EH.VERSION,
      schemaVersion=EH.SCHEMA_VERSION,
      clientVersion=v, clientBuild=build, interface=toc, created=EH.now(),
      player={ name=pn, realm=realmName, class=class, className=className, race=race, raceName=raceName, faction=faction },
      allowedRealms={"Kezan","Gurubashi"}, realmAllowed=EH.isRealmAllowed(realmName)
    }
  else
    -- Keep meta.schemaVersion up to date; future migrations can branch on old values.
    epochheadDB.meta.schemaVersion = epochheadDB.meta.schemaVersion or EH.SCHEMA_VERSION
    epochheadDB.meta.version = EH.VERSION
  end
  epochheadDB.events = epochheadDB.events or {}
  epochheadDB.state  = epochheadDB.state  or {}
  local st = epochheadDB.state
  st.debug          = st.debug or false
  st.sessionStarted = EH.now()
  st.sessionId      = newSessionId()
  st.eventsThisSession = 0
  st.settings = st.settings or { snapPrintCooldown=30, printMouseover=false }
  -- Persistent tooltip dedupe with per-item timestamps for TTL pruning.
  epochheadDB.seenTooltips = epochheadDB.seenTooltips or {}
end


------------------------------------------------------------
-- Version tracking & notify
------------------------------------------------------------
EH.VER_PREFIX = "EHVER"
EH._verLatest = EH.VERSION
EH._verLatestFrom = nil
EH._verNotified = false
EH._verLastBroadcast = 0

local function parseVer(v)
  if not v then return {0,0,0} end
  local a,b,c = tostring(v):match("^(%d+)%.(%d+)%.(%d+)$")
  if not a then
    local p = {}
    for num in tostring(v):gmatch("(%d+)") do p[#p+1] = tonumber(num,10) or 0 end
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
    for i=1,4 do if UnitExists("party"..i) then return true end end
    return false
  end
  return false
end

-- Minimum seconds between version broadcasts (anti-spam)
local VER_BROADCAST_COOLDOWN = 60

function EH.broadcastVersion(force)
  local nowSec = EH.now()
  if (not force) and (nowSec - (EH._verLastBroadcast or 0)) < VER_BROADCAST_COOLDOWN then
    return
  end
  EH._verLastBroadcast = nowSec
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
    if EH.compareVersion(their, EH.VERSION) == 1 and not EH._verNotified then
      verMsg(("|cffff4444Your EpochHead is out of date|r (yours %s, latest %s from %s)."):format(tostring(EH.VERSION), tostring(their), tostring(sender or "?")))
      verMsg("Grab the latest build when you can.")
      EH._verNotified = true
    end
    return
  end
  if message == "VER?" then
    local me = "VER:"..tostring(EH.VERSION or "0.0.0")
    if sender and sender ~= UnitName("player") then
      SendAddonMessage(EH.VER_PREFIX, me, "WHISPER", sender)
    end
  end
end

-- Post-login broadcast once, throttled.
do
  local vf = CreateFrame("Frame")
  local t0, armed, sent = 0, false, false
  vf:RegisterEvent("PLAYER_LOGIN")
  vf:RegisterEvent("PLAYER_ENTERING_WORLD")
  vf:RegisterEvent("CHAT_MSG_ADDON")
  vf:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
      EH._onAddonMsg(...)
    else
      if not armed then
        armed = true
        t0 = (GetTime and GetTime() or 0) + 3
        self:SetScript("OnUpdate", function(self, elapsed)
          if (GetTime and GetTime() or 0) >= t0 then
            if not sent then
              EH.broadcastVersion(true)
              sent = true
            end
            self:SetScript("OnUpdate", nil)
          end
        end)
      end
    end
  end)
end

-- Periodic GUID-dedupe prune (util.lua owns the table)
do
  local pf = CreateFrame("Frame")
  pf:RegisterEvent("PLAYER_ENTERING_WORLD")
  pf:RegisterEvent("ZONE_CHANGED_NEW_AREA")
  pf:SetScript("OnEvent", function()
    if EH.pruneGuidHits then EH.pruneGuidHits(true) end
  end)
end
