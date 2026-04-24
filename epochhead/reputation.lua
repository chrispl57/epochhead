local ADDON_NAME, EHns = ...
local EH = _G.EpochHead or EHns or {}
_G.EpochHead = EH

------------------------------------------------------------
-- Reputation gain tracking
-- CHAT_MSG_COMBAT_FACTION_CHANGE gives exact text ("Reputation with X
-- increased by N.").  UPDATE_FACTION refreshes the stored totals;
-- we use it as a confirm signal for attribution source.
--
-- Attribution heuristic: if we've recently killed/quest-turned something,
-- attribute the gain to that source.  Otherwise emit with source=nil.
------------------------------------------------------------

local function now() return (EH.now and EH.now()) or time() end

local function chat(msg)
  if not EH._debug then return end
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff99ccff[epochhead]|r " .. tostring(msg))
  end
end

-- Ring buffer of recent attribution sources (mob kill + quest turnin)
-- Each entry: { kind="mob"|"quest", id=..., name=..., t=... }
EH._repSourceQ = EH._repSourceQ or {}

local MAX_SOURCE_AGE = 15 -- seconds

-- Public: events.lua & quest handler can push attribution hints here.
function EH.NoteRepSource(src)
  if not src then return end
  local q = EH._repSourceQ
  q[#q + 1] = { kind = src.kind, id = src.id, name = src.name, t = now() }
  -- Trim: keep only last ~20 entries
  while #q > 20 do table.remove(q, 1) end
end

local function mostRecentSource()
  local q = EH._repSourceQ
  if not q or #q == 0 then return nil end
  for i = #q, 1, -1 do
    local s = q[i]
    if s and (now() - (s.t or 0)) <= MAX_SOURCE_AGE then
      return s
    end
  end
end

------------------------------------------------------------
-- Parse the combat-chat rep message.
-- Examples:
--   "Reputation with Stormwind increased by 250."
--   "Your reputation with Bloodsail Buccaneers has decreased by 5."
--   "Faction standing with Foo increased by 10."
------------------------------------------------------------
local function parseRepMessage(msg)
  if not msg or msg == "" then return nil end
  local faction, delta, sign
  faction, delta = msg:match("[Rr]eputation with ([^ ].-) increased by (%-?%d+)")
  if faction and delta then return faction, tonumber(delta) end
  faction, delta = msg:match("[Rr]eputation with ([^ ].-) decreased by (%-?%d+)")
  if faction and delta then return faction, -tonumber(delta) end
  faction, delta = msg:match("[Ff]action standing with ([^ ].-) increased by (%-?%d+)")
  if faction and delta then return faction, tonumber(delta) end
  faction, delta = msg:match("[Ff]action standing with ([^ ].-) decreased by (%-?%d+)")
  if faction and delta then return faction, -tonumber(delta) end
  return nil
end

------------------------------------------------------------
-- Faction metadata (standing, reaction threshold) from the faction list.
------------------------------------------------------------
local function getFactionMeta(name)
  if not GetNumFactions or not GetFactionInfo then return nil end
  local n = GetNumFactions() or 0
  for i = 1, n do
    local fname, desc, standingId, bottom, top, earned, atWar, canToggle,
          isHeader, isCollapsed, hasRep, isWatched, isChild = GetFactionInfo(i)
    if fname == name then
      return {
        index      = i,
        standingId = standingId,
        bottom     = bottom,
        top        = top,
        earned     = earned,
      }
    end
  end
  return nil
end

local function onRepMessage(msg)
  local faction, delta = parseRepMessage(msg)
  if not faction or not delta then return end
  local src = mostRecentSource()
  local meta = getFactionMeta(faction)

  local ev = {
    type = "rep_gain",
    t = now(),
    faction = faction,
    delta = delta,
    source = src,
    standingId = meta and meta.standingId or nil,
    earned = meta and meta.earned or nil,
    bottom = meta and meta.bottom or nil,
    top = meta and meta.top or nil,
  }
  if EH.push then EH.push(ev) end
  chat(("rep %s %+d (src=%s)"):format(tostring(faction), delta, tostring(src and src.name or "?")))
end

------------------------------------------------------------
-- Attribution helpers: note kill + quest turn-in as rep sources.
------------------------------------------------------------
local function onCLEU(_, _, subevent, _, _, _, _, _, dstGUID, dstName)
  if subevent ~= "PARTY_KILL" then return end
  if not dstGUID then return end
  local id = EH.GetEntryIdFromGUID and EH.GetEntryIdFromGUID(dstGUID) or nil
  if not id then return end
  EH.NoteRepSource({ kind = "mob", id = id, name = dstName })
end

local function onQuestTurnedIn(questID)
  if not questID then return end
  local title = nil
  if GetQuestLogTitle and GetNumQuestLogEntries then
    -- Best-effort title lookup; quest may already be removed from log.
    for i = 1, GetNumQuestLogEntries() do
      local qtitle, _, _, _, isHeader = GetQuestLogTitle(i)
      if not isHeader and qtitle then
        -- No direct id↔title mapping without more API; skip.
        break
      end
    end
  end
  EH.NoteRepSource({ kind = "quest", id = questID, name = title })
  chat(("rep source quest turn-in: id=%s"):format(tostring(questID)))
end

local f = CreateFrame and CreateFrame("Frame") or nil
if f then
  f:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE")
  f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
  f:RegisterEvent("QUEST_TURNED_IN")
  f:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_COMBAT_FACTION_CHANGE" then
      local ok, err = pcall(onRepMessage, ...)
      if not ok then chat("rep parse error: " .. tostring(err)) end
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
      local ok, err = pcall(onCLEU, ...)
      if not ok then chat("rep cleu error: " .. tostring(err)) end
    elseif event == "QUEST_TURNED_IN" then
      local ok, err = pcall(onQuestTurnedIn, ...)
      if not ok then chat("rep questturn error: " .. tostring(err)) end
    end
  end)
end
