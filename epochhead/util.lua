local ADDON_NAME, EH = ...

------------------------------------------------------------
-- Shared GUID anti-dupe (5 min) + periodic prune
------------------------------------------------------------
local ANTI_DUPE_WINDOW = 300
local PRUNE_INTERVAL   = 600

Epoch_DropsData = Epoch_DropsData or {}
Epoch_DropsData.recentGuidHits = Epoch_DropsData.recentGuidHits or {}
local __recentGuidHits = Epoch_DropsData.recentGuidHits
local __lastPrune = 0

local function pruneGuidHits(force)
  local now = time()
  if not force and (now - __lastPrune) < PRUNE_INTERVAL then return 0 end
  __lastPrune = now
  local cutoff = now - ANTI_DUPE_WINDOW
  local removed = 0
  for g, t in pairs(__recentGuidHits) do
    if (t or 0) < cutoff then
      __recentGuidHits[g] = nil
      removed = removed + 1
    end
  end
  return removed
end
EH.pruneGuidHits = pruneGuidHits

function EH.shouldSkipGuid(guid)
  if not guid or guid == "" then return false end
  pruneGuidHits(false)
  local now = time()
  local last = __recentGuidHits[guid]
  if last and (now - last) < ANTI_DUPE_WINDOW then
    return true
  end
  __recentGuidHits[guid] = now
  return false
end

function EH.collectLootGuids()
  local seen = {}
  local n = GetNumLootItems and GetNumLootItems() or 0
  for slot = 1, n do
    local src = { GetLootSourceInfo and GetLootSourceInfo(slot) }
    for i = 1, #src, 2 do
      local g = src[i]
      if g then seen[g] = true end
    end
  end
  local arr, i = {}, 1
  for g, _ in pairs(seen) do arr[i] = g; i = i + 1 end
  return arr
end

------------------------------------------------------------
-- GUID -> entry/NPC id (supports hyphenated + 3.3.5 hex GUIDs)
------------------------------------------------------------
function EH.GetEntryIdFromGUID(guid)
  if not guid then return nil end
  local s = tostring(guid)

  -- Hyphenated GUIDs (Creature-0-0-0-0-<npcId>-...)
  if s:find("-", 1, true) then
    if strsplit then
      local parts = { strsplit("-", s) }
      local id = tonumber(parts[6] or parts[5])
      if id and id > 0 then return id end
    end
    local id = s:match("Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
            or s:match("%-([0-9]+)%-[0-9A-Fa-f]+$")
            or s:match("%-([0-9]+)%-[^%-]+$")
    if id then return tonumber(id) end
    return nil
  end

  -- 3.3.5 hex GUID like 0xF130000CAC001E20 (NPC id is chars 7..12 => '000CAC')
  local up = s:gsub("^0x", ""):upper()
  if #up < 10 then return nil end
  local high  = up:sub(1, 4)
  local idHex = up:sub(5, 10)
  if high:sub(1, 2) == "F1" then
    local id = tonumber(idHex, 16)
    if id and id > 0 then return id end
  end
  local nB = tonumber(up:sub(5, 10), 16)
  if nB and nB > 0 then return nB end
  local nA = tonumber(up:sub(9, 14), 16)
  if nA and nA > 0 then return nA end
  return nil
end

-- Back-compat alias for mobs.lua and older callers
EH.GetNPCIDFromGUID = EH.GetEntryIdFromGUID

function EH.GetItemIDFromLink(link)
  if not link then return nil end
  local id = link:match("item:(%d+)")
  return id and tonumber(id) or nil
end

-- Try to set a tooltip to an item link while ignoring enchants/gems.
function EH.SetTooltipFromLink(tip, link)
  if not tip or not link then return false end

  local itemId = EH.GetItemIDFromLink(link)
  if itemId and tip.SetItemByID then
    local ok = pcall(tip.SetItemByID, tip, itemId)
    if ok then return true end
  end

  local sanitized = link
  if itemId then sanitized = "item:" .. tostring(itemId) end

  if tip.SetHyperlink then
    local ok = pcall(tip.SetHyperlink, tip, sanitized)
    if ok then return true end
    if sanitized ~= link then
      ok = pcall(tip.SetHyperlink, tip, link)
      if ok then return true end
    end
  end

  return false
end

function EH.InstanceCtx()
  if not GetInstanceInfo then return nil end
  local name, instType, difficultyIndex, difficultyName, maxPlayers, dynDiff, isDyn, mapID, lfgID = GetInstanceInfo()
  local isRaid = (instType == "raid")
  return {
    name = name, type = instType, difficultyIndex = difficultyIndex, difficultyName = difficultyName,
    maxPlayers = maxPlayers, mapId = mapID, lfgDungeonId = lfgID, isRaid = isRaid
  }
end

function EH.GroupCtx()
  local lootMethod, mlParty, mlRaid = GetLootMethod()
  local raid  = (GetNumRaidMembers and GetNumRaidMembers()) and GetNumRaidMembers() or 0
  local party = (GetNumPartyMembers and GetNumPartyMembers()) and GetNumPartyMembers() or 0
  return { lootMethod = lootMethod, masterLooterParty = mlParty, masterLooterRaid = mlRaid, partySize = party, raidSize = raid }
end

-- Returns a flat list of group member GUIDs (excluding the player) for dedupe attribution.
-- Returns nil if solo, to keep solo events lightweight.
function EH.GroupMemberGUIDs()
  local raid  = (GetNumRaidMembers and GetNumRaidMembers()) and GetNumRaidMembers() or 0
  local party = (GetNumPartyMembers and GetNumPartyMembers()) and GetNumPartyMembers() or 0
  if raid == 0 and party == 0 then return nil end
  local guids = {}
  if raid > 0 then
    for i = 1, raid do
      local g = UnitGUID and UnitGUID("raid"..i)
      if g then guids[#guids+1] = g end
    end
  elseif party > 0 then
    for i = 1, party do
      local g = UnitGUID and UnitGUID("party"..i)
      if g then guids[#guids+1] = g end
    end
  end
  if #guids == 0 then return nil end
  return guids
end

-- 3.3.5 map API; 5 decimal precision (~1.1 yd @ 100-yd zone)
function EH.Pos()
  if SetMapToCurrentZone then SetMapToCurrentZone() end
  local x, y = 0, 0
  if GetPlayerMapPosition then
    local px, py = GetPlayerMapPosition("player")
    if px and py then x, y = px, py end
  end
  local z = (GetRealZoneText and GetRealZoneText()) or (GetZoneText and GetZoneText()) or ""
  local s = (GetSubZoneText and GetSubZoneText()) or ""
  if x and y then
    x = math.floor(x * 100000) / 100000
    y = math.floor(y * 100000) / 100000
  end
  return z, s, x, y
end

function EH.parseMoneyString(text)
  if text == nil then return 0 end
  if type(text) == "number" then
    return math.max(0, text)
  end

  local s = tostring(text)
  local norm = s:gsub(",", ""):gsub("•", "")

  local g  = tonumber((norm:match("([%d%.]+)%s*[Gg][^%a]?") or "0")) or 0
  local si = tonumber((norm:match("([%d%.]+)%s*[Ss][^%a]?") or "0")) or 0
  local c  = tonumber((norm:match("([%d%.]+)%s*[Cc][^%a]?") or "0")) or 0

  if g == 0 and si == 0 and c == 0 then
    local maybe = tonumber(norm)
    if maybe then return math.max(0, maybe) end
  end

  return g * 10000 + si * 100 + c
end

function EH.splitCopper(cp)
  local g  = math.floor((cp or 0) / 10000)
  local si = math.floor(((cp or 0) % 10000) / 100)
  local c  = (cp or 0) % 100
  return g, si, c
end

EH.RARITY_META = {
  [0] = {name="poor",      hex="9d9d9d"},
  [1] = {name="common",    hex="ffffff"},
  [2] = {name="uncommon",  hex="1eff00"},
  [3] = {name="rare",      hex="0070dd"},
  [4] = {name="epic",      hex="a335ee"},
  [5] = {name="legendary", hex="ff8000"},
  [6] = {name="artifact",  hex="e6cc80"},
  [7] = {name="heirloom",  hex="00ccff"},
}

function EH.getRarity(link, fallbackQ)
  local q
  if link and GetItemInfo then
    local _, _, quality = GetItemInfo(link)
    q = quality
  end
  q = q or fallbackQ or -1
  local meta = EH.RARITY_META[q]
  return q, (meta and meta.name or nil), (meta and meta.hex or nil)
end
