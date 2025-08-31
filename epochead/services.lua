-- Interface\AddOns\EpochHead\services.lua
-- Vendor capture DISABLED on purpose.
-- This file stubs EH.captureVendor() and does NOT register any MERCHANT_* events.
-- Swap this in when you want to pause vendor ingestion.

local ADDON_NAME, EHns = ...
local EH = _G.EpochHead or EHns or {}
_G.EpochHead = EH

local function chat(msg)
  if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff99ccff[EpochHead]|r "..tostring(msg)) end
end

-- Hard-disable
function EH.captureVendor()
  if EH._debug or (epochheadDB and epochheadDB.state and epochheadDB.state.debug) then
    chat("vendor capture is disabled in this build")
  end
  -- no-op
end

-- No MERCHANT_* registrations here on purpose.

-- Optional: tiny toggle UX (purely cosmetic; remains disabled)
SLASH_EPOCHHEAD1 = "/eh"
SlashCmdList["EPOCHHEAD"] = function(msg)
  msg = (msg or ""):lower()
  if msg == "vendor on" then
    chat("vendor capture is disabled in this build; replace services.lua to re-enable")
  elseif msg == "vendor off" or msg == "vendor" then
    chat("vendor capture is already disabled")
  else
    chat("Usage: /eh vendor off  (capture disabled in this build)")
  end
end
