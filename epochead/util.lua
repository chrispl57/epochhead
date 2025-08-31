local ADDON_NAME, EH = ...

-- GUID -> NPC ID (supports hyphenated and 3.3.5 hex GUIDs)
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


function EH.GetNPCIDFromGUID(guid)
  if not guid then return nil end
  local g = tostring(guid)

  -- Retail/Classic hyphenated GUIDs (Creature-...-<npcId>-...)
  local id = g:match("Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
          or g:match("%-([0-9]+)%-[0-9A-Fa-f]+$")
          or g:match("%-([0-9]+)%-[^%-]+$")
  if id then return tonumber(id) end

  -- Wrath/3.3.5 hex GUID like 0xF130000CAC001E20 (NPC id is chars 7..12 => '000CAC')
  if g:sub(1,2) == "0x" and #g >= 12 then
    local hexid = g:sub(7,12)
    if hexid:match("^[0-9A-Fa-f]+$") then
      local num = tonumber(hexid, 16)
      if num and num > 0 then return num end
    end
  end
  return nil
end

function EH.GetItemIDFromLink(link)
  if not link then return nil end
  local id = link:match("item:(%d+)")
  return id and tonumber(id) or nil
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
  local raid = (GetNumRaidMembers and GetNumRaidMembers()) and GetNumRaidMembers() or 0
  local party = (GetNumPartyMembers and GetNumPartyMembers()) and GetNumPartyMembers() or 0
  return { lootMethod = lootMethod, masterLooterParty = mlParty, masterLooterRaid = mlRaid, partySize = party, raidSize = raid }
end

-- 3.3.5 map API
function EH.Pos()
  SetMapToCurrentZone()
  local x, y = GetPlayerMapPosition("player")
  local z, s = GetRealZoneText(), GetSubZoneText()
  if x and y then
    x = math.floor(x * 10000) / 10000
    y = math.floor(y * 10000) / 10000
  end
  return z, s, x, y
end

-- Parse “10 Copper”, “3s 25c”, “1 Gold”, or a raw copper number.
-- Returns total copper as a single integer.
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

  -- Fallback: plain number (already copper)
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
