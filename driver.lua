local DRIVER_VERSION = "000020"

-- Bindings (per driver.xml)
local LIGHT_BINDING = 5101
local RELAY_BINDING = 1

local TOP_BUTTON_LINK_ID = 301
local BOTTOM_BUTTON_LINK_ID = 311
local TOGGLE_BUTTON_LINK_ID = 321

local function trim(s)
  if not s then return "" end
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function isTruthyProperty(v)
  v = string.lower(trim(v))
  return v == "1" or v == "yes" or v == "true" or v == "on"
end

local function setProperty(name, value)
  value = tostring(value or "")
  if C4 and type(C4.UpdateProperty) == "function" then
    pcall(function() C4:UpdateProperty(name, value) end)
  elseif Properties then
    Properties[name] = value
  end
end

local function debugLog(msg)
  if isTruthyProperty(Properties and Properties["Debug"] or "") then
    pcall(function() print("DEBUG MINI_LIGHT: " .. tostring(msg)) end)
    if C4 and type(C4.PrintToLog) == "function" then
      pcall(function() C4:PrintToLog("DEBUG MINI_LIGHT: " .. tostring(msg)) end)
    end
  end
end

-- Track last-known state to avoid feedback loops (Light UI can resend SET_LEVEL 100 when already ON).
local gLastKnownOn = nil
local gLastCmdKey = nil
local gLastCmdAt = 0

local function nowMs()
  if C4 and type(C4.GetTickCount) == "function" then
    local ok, v = pcall(function() return C4:GetTickCount() end)
    if ok and type(v) == "number" then return v end
  end
  return math.floor((os.clock() or 0) * 1000)
end

local function previewParams(t)
  if type(t) ~= "table" then return tostring(t or "") end
  if C4 and type(C4.JsonEncode) == "function" then
    local ok, s = pcall(function() return C4:JsonEncode(t, false, true) end)
    if ok and type(s) == "string" then return s end
  end
  local out = {}
  for k, v in pairs(t) do out[#out + 1] = tostring(k) .. "=" .. tostring(v) end
  return table.concat(out, ",")
end

local function sendToProxy(bindingId, cmd, params)
  if not (C4 and type(C4.SendToProxy) == "function") then return end
  local ok, ret = pcall(function() return C4:SendToProxy(bindingId, cmd, params or {}) end)
  debugLog("SendToProxy id=" .. tostring(bindingId) .. " cmd=" .. tostring(cmd) .. " ret=" .. tostring(ret) .. " ok=" .. tostring(ok))
end

local function sendNotifyToProxy(bindingId, cmd, params)
  if not (C4 and type(C4.SendToProxy) == "function") then return end

  -- Prefer 4-arg SendToProxy(..., "NOTIFY"). Fallback for older Director builds.
  local ok, ret = pcall(function() return C4:SendToProxy(bindingId, cmd, params or {}, "NOTIFY") end)
  if not ok then
    ok, ret = pcall(function() return C4:SendToProxy(bindingId, cmd, params or {}) end)
  end

  debugLog("SendToProxy(NOTIFY) id=" .. tostring(bindingId) .. " cmd=" .. tostring(cmd) .. " ret=" .. tostring(ret) .. " ok=" .. tostring(ok))
end

local function sendRelayCommand(cmd, params)
  -- Relay class varies across drivers: some expect CLOSE/OPEN, others accept ON/OFF.
  local attempts = {}
  cmd = string.upper(tostring(cmd or ""))
  if cmd == "ON" or cmd == "CLOSE" or cmd == "CLOSED" then
    attempts = { "CLOSE", "CLOSED", "ON" }
  elseif cmd == "OFF" or cmd == "OPEN" or cmd == "OPENED" then
    attempts = { "OPEN", "OPENED", "OFF" }
  elseif cmd == "TOGGLE" or cmd == "TGL" then
    attempts = { "TOGGLE", "TGL" }
  else
    attempts = { cmd }
  end
  for _, c in ipairs(attempts) do
    sendToProxy(RELAY_BINDING, c, params or {})
  end
end

local function desiredOnFromLightCmd(cmd, params)
  cmd = string.upper(tostring(cmd or ""))
  if cmd == "ON" then return true end
  if cmd == "OFF" then return false end

  if cmd == "SET_STATE" or cmd == "SET_TO" or cmd == "SET_VALUE" or cmd == "SET_TO_VALUE" then
    local v = params and (params.STATE or params.state or params.VALUE or params.value)
    if v ~= nil then
      local s = string.upper(tostring(v))
      if s == "ON" or s == "1" or s == "TRUE" or s == "CLOSED" then return true end
      if s == "OFF" or s == "0" or s == "FALSE" or s == "OPEN" or s == "OPENED" then return false end
    end
  end

  if cmd == "SET_LEVEL" or cmd == "SET_LEVEL_TARGET" or cmd == "RAMP_TO_LEVEL" or cmd == "SET" then
    local level = params and (params.LEVEL or params.level or params.VALUE or params.Value or params.TARGET_LEVEL or params.TargetLevel or params.BRIGHTNESS or params.brightness)
    level = tonumber(level)
    if level ~= nil then
      return level > 0
    end
  end

  return nil
end

local function mapLightCmdToRelay(cmd, params)
  cmd = string.upper(tostring(cmd or ""))

  if cmd == "ON" then return "CLOSE", {} end
  if cmd == "OFF" then return "OPEN", {} end
  if cmd == "TOGGLE" or cmd == "TGL" then return "TOGGLE", {} end

  -- Some firmwares send SET_STATE/SET_TO/SET_VALUE with STATE/VALUE fields
  if cmd == "SET_STATE" or cmd == "SET_TO" or cmd == "SET_VALUE" or cmd == "SET_TO_VALUE" then
    local v = params and (params.STATE or params.state or params.VALUE or params.value)
    if v ~= nil then
      local s = string.upper(tostring(v))
      if s == "ON" or s == "1" or s == "TRUE" or s == "CLOSED" then return "CLOSE", {} end
      if s == "OFF" or s == "0" or s == "FALSE" or s == "OPEN" or s == "OPENED" then return "OPEN", {} end
    end
  end

  -- LIGHT_V2 sends lots of level/ramp commands; translate to ON/OFF.
  -- Some UIs send SET_LEVEL. Translate to ON/OFF for relays.
  if cmd == "SET_LEVEL" or cmd == "SET_LEVEL_TARGET" or cmd == "RAMP_TO_LEVEL" or cmd == "SET" then
    local level = params and (params.LEVEL or params.level or params.VALUE or params.Value or params.TARGET_LEVEL or params.TargetLevel or params.BRIGHTNESS or params.brightness)
    level = tonumber(level)
    if level and level <= 0 then return "OPEN", {} end
    if level and level > 0 then return "CLOSE", {} end
  end

  return cmd, params
end

local function UpdateProxy(level0to100)
  local level = tonumber(level0to100) or 0
  if level < 0 then level = 0 end
  if level > 100 then level = 100 end

  gLastKnownOn = level > 0

  -- IMPORTANT: For LIGHT_V2, update the UI using NOTIFY + LIGHT_BRIGHTNESS_CHANGED only.
  -- Do NOT send STATE_CHANGED / LIGHT_LEVEL_CHANGED / ON / OFF to the Light binding.
  sendNotifyToProxy(LIGHT_BINDING, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = tostring(level) })
end

local function relayEventToLightState(cmd, params)
  cmd = string.upper(tostring(cmd or ""))
  local state

  if cmd == "ON" or cmd == "CLOSED" or cmd == "CLOSE" then state = true end
  if cmd == "OFF" or cmd == "OPEN" or cmd == "OPENED" then state = false end

  if state == nil and type(params) == "table" then
    local v = params.STATE or params.state or params.VALUE or params.value
    if v ~= nil then
      local s = string.upper(tostring(v))
      if s == "ON" or s == "1" or s == "TRUE" or s == "CLOSED" then state = true end
      if s == "OFF" or s == "0" or s == "FALSE" or s == "OPEN" or s == "OPENED" then state = false end
    end
  end

  if state == nil then return end

  UpdateProxy(state and 100 or 0)
end

function OnDriverInit()
  setProperty("Driver Version", DRIVER_VERSION)
  setProperty("Last Light Command", "---")
  setProperty("Last Relay Command", "---")
end

function OnDriverLateInit()
  -- Start with a defined state (OFF) until relay feedback arrives.
  if gLastKnownOn == nil then
    UpdateProxy(0)
  end
end

function OnPropertyChanged(name)
  if name == "Debug" then
    debugLog("Debug=" .. tostring(Properties and Properties["Debug"]))
  end
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  strCommand = tostring(strCommand or "")
  tParams = tParams or {}
  debugLog("RX id=" .. tostring(idBinding) .. " cmd=" .. tostring(strCommand) .. " params=" .. previewParams(tParams))

  -- Button Link bindings from UI
  if idBinding == TOGGLE_BUTTON_LINK_ID then
    setProperty("Last Light Command", "TOGGLE_LINK " .. strCommand .. " " .. previewParams(tParams))
    sendRelayCommand("TOGGLE", {})
    return
  end
  if idBinding == TOP_BUTTON_LINK_ID then
    setProperty("Last Light Command", "TOP_LINK " .. strCommand .. " " .. previewParams(tParams))
    sendRelayCommand("ON", {})
    return
  end
  if idBinding == BOTTOM_BUTTON_LINK_ID then
    setProperty("Last Light Command", "BOTTOM_LINK " .. strCommand .. " " .. previewParams(tParams))
    sendRelayCommand("OFF", {})
    return
  end

  -- Light UI commands arrive on LIGHT_V2 connection binding.
  if idBinding == LIGHT_BINDING then
    -- Debounce duplicate UI commands (prevents repeated CLOSE when already ON).
    local desired = desiredOnFromLightCmd(strCommand, tParams)
    if desired ~= nil and gLastKnownOn ~= nil and desired == gLastKnownOn then
      debugLog("Ignoring redundant light cmd (already " .. (gLastKnownOn and "ON" or "OFF") .. "): " .. tostring(strCommand))
      return
    end

    local key = tostring(idBinding) .. "|" .. tostring(strCommand) .. "|" .. previewParams(tParams)
    local t = nowMs()
    if gLastCmdKey == key and (t - gLastCmdAt) < 400 then
      debugLog("Debounce duplicate cmd: " .. key)
      return
    end
    gLastCmdKey = key
    gLastCmdAt = t

    local rcmd, rparams = mapLightCmdToRelay(strCommand, tParams)
    setProperty("Last Light Command", tostring(idBinding) .. " " .. strCommand .. " -> " .. tostring(rcmd) .. " " .. previewParams(tParams))
    debugLog("LIGHT->RELAY cmd=" .. tostring(rcmd) .. " params=" .. previewParams(rparams))
    sendRelayCommand(rcmd, rparams)

    -- Do not assume new state here: wait for relay feedback, then UpdateProxy().
    return
  end

  if idBinding == RELAY_BINDING then
    setProperty("Last Relay Command", tostring(idBinding) .. " " .. strCommand .. " " .. previewParams(tParams))
    debugLog("RELAY->LIGHT cmd=" .. tostring(strCommand) .. " params=" .. previewParams(tParams))
    relayEventToLightState(strCommand, tParams)
    return
  end
end
