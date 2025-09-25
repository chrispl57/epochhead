-- Interface\\AddOns\\EpochHead\\services.lua
-- Vendor capture (enabled)

local ADDON_NAME, EHns = ...
local EH = _G.EpochHead or EHns or {}
_G.EpochHead = EH

local function chat(msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff99ccff[EpochHead]|r " .. tostring(msg))
  end
end

local function now()
  if EH.now then return EH.now() end
  return time()
end

local function GetEntryIdFromGUID(guid)
  if not guid then return nil end
  local s = tostring(guid)
  if s:find("-", 1, true) then
    local parts = { strsplit("-", s) }
    local id = tonumber(parts[6] or parts[5])
    if id and id > 0 then return id end
  end
  local up = s:gsub("^0x", ""):upper()
  if #up < 10 then return nil end
  local high = up:sub(1, 4)
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

local function VendorSessionSignature(vendorId, vendorGuid, itemIds)
  local parts = {}
  if vendorId then parts[#parts + 1] = tostring(vendorId) end
  if vendorGuid and not vendorId then parts[#parts + 1] = tostring(vendorGuid) end
  table.sort(itemIds)
  for i = 1, #itemIds do
    parts[#parts + 1] = tostring(itemIds[i])
  end
  return table.concat(parts, ":")
end

local function SnapshotVendorUnit()
  local guid = UnitGUID and UnitGUID("target") or nil
  local name = UnitName and UnitName("target") or nil
  if (not guid or not name) and UnitExists and UnitExists("mouseover") then
    local mg = UnitGUID("mouseover")
    if mg and not guid then guid = mg end
    local mn = UnitName("mouseover")
    if mn and not name then name = mn end
  end
  local snap = (guid and EH.mobSnap and EH.mobSnap[guid]) or nil
  local entryId = snap and snap.id or GetEntryIdFromGUID(guid)
  if not name and snap and snap.name then name = snap.name end
  return {
    guid = guid,
    id = entryId,
    name = name,
  }
end

local function CollectVendorItems()
  if type(GetMerchantNumItems) ~= "function" then return nil end
  local count = GetMerchantNumItems()
  if not count or count <= 0 then return nil end

  local items, uniqueIds, seen = {}, {}, {}
  for index = 1, count do
    local link = GetMerchantItemLink and GetMerchantItemLink(index) or nil
    local name, _, price, quantity, numAvailable, _, extendedCost = GetMerchantItemInfo(index)
    local entry = EH.BuildItemEntry and EH.BuildItemEntry(link, name, quantity, nil) or {
      id = nil,
      name = name,
      info = nil,
    }
    local iid = entry and entry.id or nil
    if (not iid) and link then
      iid = tonumber(tostring(link):match("item:(%d+)"))
    end
    if iid then
      entry.id = iid
      entry.name = entry.name or name
      entry.priceCopper = price
      entry.qtyPerPurchase = quantity
      entry.numAvailable = numAvailable
      entry.extendedCost = extendedCost
      items[#items + 1] = entry
      if not seen[iid] then
        seen[iid] = true
        uniqueIds[#uniqueIds + 1] = iid
      end
    end
  end

  if #items == 0 then return nil end
  return items, uniqueIds
end

function EH.captureVendor(eventName)
  if not MerchantFrame or not MerchantFrame:IsShown() then return end

  local items, itemIds = CollectVendorItems()
  if not items or not itemIds then return end

  local vendorInfo = SnapshotVendorUnit()
  local meta = EH._lastVendorMeta or {}
  if vendorInfo.guid then meta.guid = vendorInfo.guid end
  if vendorInfo.id then meta.id = vendorInfo.id end
  if vendorInfo.name then meta.name = vendorInfo.name end
  EH._lastVendorMeta = meta

  local signature = VendorSessionSignature(meta.id, meta.guid, { unpack(itemIds) })
  local last = EH._lastVendorSnapshot
  if last and last.sig == signature and (now() - (last.ts or 0) < 2) then
    return
  end

  local z, s, x, y = EH.Pos and EH.Pos() or nil
  local sourceKey = EH.sourceKeyForVendor and EH.sourceKeyForVendor(meta.id, meta.guid, meta.name) or nil

  local event = {
    type = "vendor_snapshot",
    t = now(),
    session = EH.session,
    source = {
      kind = "vendor",
      id = meta.id,
      guid = meta.guid,
      name = meta.name,
      zone = z,
      subzone = s,
      x = x,
      y = y,
    },
    vendor = {
      name = meta.name,
      guid = meta.guid,
      canRepair = CanMerchantRepair and CanMerchantRepair() or nil,
    },
    items = items,
    sourceKey = sourceKey,
    zone = z,
    subZone = s,
    x = x,
    y = y,
  }

  EH.push(event)
  EH._lastVendorSnapshot = { sig = signature, ts = now() }
  if EH._debug then
    chat(("captured vendor %s (%s) with %d items"):format(tostring(meta.name or "?"), tostring(meta.id or meta.guid or "?"), #items))
  end
end

local vendorFrame = CreateFrame and CreateFrame("Frame") or nil
if vendorFrame then
  vendorFrame:RegisterEvent("MERCHANT_SHOW")
  vendorFrame:RegisterEvent("MERCHANT_UPDATE")
  vendorFrame:RegisterEvent("MERCHANT_CLOSED")
  vendorFrame:SetScript("OnEvent", function(_, event)
    if event == "MERCHANT_CLOSED" then
      EH._lastVendorSnapshot = nil
      EH._lastVendorMeta = nil
      return
    end
    EH.captureVendor(event)
  end)
end

SLASH_EPOCHHEAD_VENDOR1 = "/ehvendor"
SlashCmdList["EPOCHHEAD_VENDOR"] = function()
  EH.captureVendor("MANUAL")
end

