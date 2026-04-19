local ADDON_NAME, EHns = ...
local EH = _G.EpochHead or EHns or {}
_G.EpochHead = EH

------------------------------------------------------------
-- Quest objective progress tracking
-- Diffs GetQuestLogLeaderBoard for each quest in the log on
-- UNIT_QUESTLOG_CHANGED / QUEST_WATCH_UPDATE and emits per-
-- objective progress events.  Feeds "X needed for quest Y"
-- aggregation: which mobs drop quest items, which kills progress
-- which quests, etc.
------------------------------------------------------------

local function now() return (EH.now and EH.now()) or time() end

local function chat(msg)
  if not EH._debug then return end
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff99ccff[epochhead]|r " .. tostring(msg))
  end
end

local function questIDFromLink(link)
  local id = tostring(link or ""):match("Hquest:(%d+)")
  return id and tonumber(id) or nil
end

local function getQuestIdAt(idx)
  if not GetQuestLink then return nil end
  return questIDFromLink(GetQuestLink(idx))
end

local function parseObjective(text)
  -- Common forms: "Thing slain: 3/10"  "Thing: 3/10"  "Thing (3/10)"
  if not text or text == "" then return nil, nil, nil end
  local name, have, need = text:match("^(.-): (%d+)/(%d+)")
  if name and have and need then return name, tonumber(have), tonumber(need) end
  name, have, need = text:match("^(.-) %((%d+)/(%d+)%)")
  if name and have and need then return name, tonumber(have), tonumber(need) end
  return text, nil, nil
end

-- Cache: qid -> { title = "...", objs = { [idx] = {text, have, need, type, finished} } }
local cache = {}

local function snapshotQuestObjectives(questIndex, qid, title)
  if not GetNumQuestLeaderBoards or not GetQuestLogLeaderBoard then return nil end
  if SelectQuestLogEntry then pcall(SelectQuestLogEntry, questIndex) end
  local n = GetNumQuestLeaderBoards(questIndex) or 0
  if n == 0 then return nil end
  local out = {}
  for i = 1, n do
    local text, objType, finished = GetQuestLogLeaderBoard(i, questIndex)
    local name, have, need = parseObjective(text)
    out[i] = {
      index    = i,
      text     = text,
      type     = objType, -- "item"|"monster"|"event"|"reputation"|"object"
      finished = finished and true or false,
      name     = name,
      have     = have,
      need     = need,
    }
  end
  return out
end

local function emitDiff(qid, title, oldObjs, newObjs)
  if not newObjs then return end
  local changes = {}
  for idx, newO in ipairs(newObjs) do
    local oldO = oldObjs and oldObjs[idx] or nil
    local oldHave = oldO and oldO.have or nil
    local newHave = newO.have
    local becameFinished = (not (oldO and oldO.finished)) and newO.finished
    if (oldHave ~= newHave) or becameFinished then
      changes[#changes + 1] = {
        index    = idx,
        text     = newO.text,
        type     = newO.type,
        name     = newO.name,
        have     = newO.have,
        need     = newO.need,
        prevHave = oldHave,
        finished = newO.finished,
      }
    end
  end
  if #changes == 0 then return end
  local z, s, x, y = EH.Pos and EH.Pos() or nil, nil, nil, nil
  local ev = {
    type = "quest_objective_progress",
    t = now(),
    questId = qid,
    title = title,
    changes = changes,
    zone = z, subzone = s, x = x, y = y,
  }
  if EH.push then EH.push(ev) end
  chat(("objective progress q=%s changes=%d"):format(tostring(qid), #changes))
end

local function scanAll()
  if not GetNumQuestLogEntries then return end
  local n = GetNumQuestLogEntries() or 0
  local seen = {}
  for i = 1, n do
    local title, _, _, _, isHeader = GetQuestLogTitle(i)
    if not isHeader and title then
      local qid = getQuestIdAt(i)
      if qid then
        seen[qid] = true
        local newObjs = snapshotQuestObjectives(i, qid, title)
        local prev = cache[qid]
        if prev and newObjs then
          emitDiff(qid, title, prev.objs, newObjs)
        end
        cache[qid] = { title = title, objs = newObjs }
      end
    end
  end
  -- Drop cache entries for quests no longer in the log (turned in / abandoned).
  for qid in pairs(cache) do
    if not seen[qid] then cache[qid] = nil end
  end
end

local f = CreateFrame and CreateFrame("Frame") or nil
if f then
  f:RegisterEvent("PLAYER_LOGIN")
  f:RegisterEvent("QUEST_LOG_UPDATE")
  f:RegisterEvent("UNIT_QUESTLOG_CHANGED")
  f:RegisterEvent("QUEST_WATCH_UPDATE")
  local pending = false
  local armedAt = 0
  local function arm()
    pending = true
    armedAt = (GetTime and GetTime() or 0) + 0.25
    f:SetScript("OnUpdate", function(self, elapsed)
      local t = GetTime and GetTime() or 0
      if t < armedAt then return end
      self:SetScript("OnUpdate", nil)
      pending = false
      local ok, err = pcall(scanAll)
      if not ok then chat("questobj scan error: " .. tostring(err)) end
    end)
  end
  f:SetScript("OnEvent", function(self, event) arm() end)
end
