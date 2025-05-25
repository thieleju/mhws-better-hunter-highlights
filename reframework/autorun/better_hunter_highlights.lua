-- Better Hunter Highlights
--
-- Logs quest award contributions for all players at the end of a quest
-- Hooks into quest sync and result methods to collect and summarize player awards
--
---@diagnostic disable: undefined-global

-- types
local cQuestRewardType = sdk.find_type_definition("app.cQuestReward")
local cQuestDirectorType = sdk.find_type_definition("app.cQuestDirector")
local questDefType = sdk.find_type_definition("app.QuestDef")
local messageUtilType = sdk.find_type_definition("app.MessageUtil")
local subMenuType = sdk.find_type_definition("app.cGUISubMenuInfo")
local guidType = sdk.find_type_definition("System.Guid")
local guiManagerType = sdk.find_type_definition("app.GUIManager")

-- methods to hook
local syncQuestAwardInfo = cQuestDirectorType:get_method("syncQuestAwardInfo")
local enterQuestReward = cQuestRewardType:get_method("enter()")
local guiManagerRequestSubMenu = guiManagerType:get_method("requestSubMenu")

-- utility methods
local getTextHelper = messageUtilType:get_method("getText(System.Guid, System.Int32)")
local getAwardNameHelper = questDefType:get_method("Name(app.QuestDef.AwardID)")
local getAwardExplainHelper = questDefType:get_method("Explain(app.QuestDef.AwardID)")
local addSubMenuItem = subMenuType:get_method(
  "addItem(System.String, System.Guid, System.Guid, System.Boolean, System.Boolean, System.Action)")
local newGuid = guidType:get_method("NewGuid")

-- variables
local awardStats = {}
local memberAwardStats = {}
local config = { enabled = true, debug = false }

local SESSION_TYPE = { LOBBY = 1, QUEST = 2, LINK = 3 }
local CONFIG_PATH = "better_hunter_highlights.json"

-- Log debug message
local function logDebug(message)
  if config.debug then
    log.debug("[Better Hunter Highlights] " .. message)
  end
end

-- Log error message
local function logError(message)
  log.debug("[Better Hunter Highlights] ERROR: " .. message)
end

-- Save config to json file in data directory of reframework
local function saveConfig()
  json.dump_file(CONFIG_PATH, config)
  logDebug("Config saved to " .. CONFIG_PATH)
end

-- Load existing config or create default
local function loadConfig()
  local loaded = json.load_file(CONFIG_PATH)
  if loaded then
    config = loaded
  else
    saveConfig()
  end
end

--- Safely call a function and return result or nil
-- @param fn function The function to call
-- @return any|nil The result if successful
local function safeCall(fn)
  local ok, result = pcall(fn)
  if not ok then
    logError("n safeCall: " .. tostring(result))
  end
  return ok and result or nil
end

--- Gets a localized string from a GUID via MessageUtil
-- @param guid any The GUID
-- @return string The localized string or fallback
local function getAwardText(guid)
  return safeCall(function()
    return getTextHelper:call(nil, guid, 0)
  end) or "<Unknown>"
end

--- Get award name from ID
-- @param awardId number The award ID
-- @return string Award name
local function getAwardName(awardId)
  local guid = safeCall(function()
    return getAwardNameHelper:call(nil, awardId)
  end)
  return guid and getAwardText(guid) or string.format("Award_%d", awardId)
end

--- Get award description from ID
-- @param awardId number The award ID
-- @return string Award explanation
local function getAwardExplain(awardId)
  local guid = safeCall(function()
    return getAwardExplainHelper:call(nil, awardId)
  end)
  return guid and getAwardText(guid) or string.format("Explain_%d", awardId)
end

--- Extracts stats from a sync packet
-- @param packet userdata The cQuestAwardSync packet
-- @return table Table of awardId to stats
local function extractAwardStats(packet)
  local stats = {}
  -- award01 is special case, its type is System.UInt32[]
  local award01Count = safeCall(function()
    local award01Array = packet["award01"]
    if not award01Array then return 0 end
    -- sum up all 4 elements of the array (It's always 4)
    return award01Array:get_Item(0) + award01Array:get_Item(1) + award01Array:get_Item(2) + award01Array:get_Item(3)
  end)
  stats[0] = {
    name = getAwardName(0),
    explain = getAwardExplain(0),
    count = award01Count,
  }
  -- awards 02 to 30
  for i = 2, 30 do
    local raw = safeCall(function()
      return packet[string.format("award%02d", i)]
    end)
    local awardId = i - 1
    stats[awardId] = {
      name = getAwardName(awardId),
      explain = getAwardExplain(awardId),
      count = raw and math.floor(raw) or 0,
    }
  end
  return stats
end

--- Prints member award stats and damage to main target table
local function printMemberAwardStats()
  logDebug(" --- Player Awards ---")
  for _, data in pairs(memberAwardStats) do
    local awardsStr = {}
    for _, award in pairs(data.awards) do
      table.insert(awardsStr, string.format("%s: %d", award.name, award.count))
    end
    logDebug(string.format("-> %s(%d): %s", data.username, data.memberIndex, table.concat(awardsStr, ", ")))
  end
  logDebug(" --- Damage to Main Target Large Monster ---")
  -- sort memberAwardStats by damage count
  table.sort(memberAwardStats, function(a, b)
    return (a.awards[4] and a.awards[4].count or 0) > (b.awards[4] and b.awards[4].count or 0)
  end)
  -- sum up total damage
  local dmgSum = 0
  for _, data in ipairs(memberAwardStats) do
    local dmg = data.awards[4] and data.awards[4].count or 0
    dmgSum = dmgSum + dmg
  end
  -- print each player's info in order
  for i, data in ipairs(memberAwardStats) do
    local dmg = data.awards[4] and data.awards[4].count or 0
    local percentage = dmgSum > 0 and (dmg / dmgSum) * 100 or 0
    logDebug(string.format("-> %s(%d): %d dmg (%.2f%%)", data.username, data.memberIndex, dmg, percentage))
  end
end

--- Handler for syncQuestAwardInfo hook
-- @param args table Hook arguments
-- @return sdk.PreHookResult|nil
local function onSyncQuestAwardInfo(args)
  if not config.enabled then
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  -- userIndex of the player who sent the sync packet
  local userIndex = safeCall(function()
    local idx = sdk.to_int64(args[3])
    if idx < 0 or idx >= 4 then error("Invalid userIndex: " .. tostring(idx)) end
    return idx
  end)
  if not userIndex then
    logError("Invalid userIndex in syncQuestAwardInfo.")
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  -- the cQuestAwardSync packet itself
  local cQuestAwardSync = safeCall(function() return sdk.to_managed_object(args[4]) end)
  if not cQuestAwardSync then
    logError("Invalid cQuestAwardSync in syncQuestAwardInfo.")
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  -- get stats from cQuestAwardSync and update playerstats
  local stats = extractAwardStats(cQuestAwardSync)
  awardStats[userIndex] = stats

  local statsStr = {}
  for id, data in pairs(stats) do
    table.insert(statsStr, string.format("(%d|%d)", id, data.count or 0))
  end
  logDebug(string.format("Player [%d] Awards: %s", userIndex, table.concat(statsStr, ", ")))
end

--- Handler when entering quest reward state
-- @param args table Hook arguments
local function onEnterQuestReward(args)
  if not config.enabled then
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  logDebug("Quest reward enter() called")

  local networkManagerSingleton = sdk.get_managed_singleton("app.NetworkManager")
  if not networkManagerSingleton then
    logError("NetworkManager singleton not found.")
    return
  end

  local userInfoManager = networkManagerSingleton:get_UserInfoManager()
  if not userInfoManager then
    logError("UserInfoManager not found in NetworkManager.")
    return
  end

  local userInfoList = userInfoManager:getUserInfoList(SESSION_TYPE.QUEST)
  if not userInfoList then
    logError("UserInfoList not found in UserInfoManager.")
    return
  end

  local memberNum = userInfoManager:getMemberNum(SESSION_TYPE.QUEST)
  if memberNum <= 0 then
    logError("No members found in UserInfoList.")
    return
  end

  local userInfoArray = userInfoList._ListInfo
  if not userInfoArray then
    logError("UserInfoArray is nil.")
    return
  end

  -- map playerstats to user by index
  memberAwardStats = {}

  for i = 0, memberNum - 1 do
    memberAwardStats[i + 1] = { -- stupid 1-based indexing
      memberIndex = i,
      username = userInfoArray[i]:get_PlName(),
      shortHunterId = userInfoArray[i]:get_ShortHunterId(),
      isSelf = userInfoArray[i]:get_IsSelf(),
      awards = awardStats[i] or {},
    }
  end

  -- Print all member award stats with dmg table
  printMemberAwardStats()
end

--- Handler for when sub menus open
-- @param args table Hook arguments
local function onRequestSubMenu(args)
  if not config.enabled then
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  local owner = sdk.to_managed_object(args[3])
  local subMenu = sdk.to_managed_object(args[4])

  logDebug("RequestSubMenu called for " .. tostring(owner:get_type_definition():get_full_name()))

  if subMenu == nil then
    logDebug("requestSubMenu subMenu is nil")
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  -- skip all submenus except the one for parts list
  if owner:get_type_definition():get_full_name() ~= "app.GUI070003PartsList" then
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  local item0 = subMenu:getItem(0)

  local executeAction = item0 and item0:get_ExecuteAction()
  if executeAction == nil then
    logDebug("No execute action found in item 1 of submenu")
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  executeAction:add_ref()

  -- Add custom item to the submenu

  local guid = newGuid:call(nil)
  local item4Text = "Show Better Hunter Highlights"
  addSubMenuItem:call(subMenu, item4Text, guid, guid, true, false, executeAction)

  return sdk.PreHookResult.CALL_ORIGINAL
end


-- Helper function to register hooks
local function registerHook(method, pre, post)
  if not method then return end
  sdk.hook(method, pre, post)

  logDebug("Hook registered for method: " .. tostring(method:get_name()))
end

-- Draw REFramework UI
re.on_draw_ui(function()
  if imgui.tree_node("Better Hunter Highlights") then
    -- checkbox returns true if clicked
    if imgui.checkbox("Enable Mod", config.enabled) then
      config.enabled = not config.enabled
      if not config.enabled then
        config.debug = false -- disable debug mode if mod is disabled
      end
      logDebug("Config set enabled to " .. tostring(config.enabled))
    end

    -- skip if mod disabled
    if not config.enabled then
      imgui.tree_pop()
      return
    end

    -- checkbox for debug mode
    if imgui.checkbox("Debug Mode", config.debug) then
      logDebug("Config set debug mode to " .. tostring(config.debug))
    end

    imgui.indent(20)

    imgui.text("Stats will be shown at quest end.")

    imgui.unindent(20)

    imgui.tree_pop()
  end
end)

-- Load configuration and add config save listener

loadConfig()

re.on_config_save(function()
  saveConfig()
  loadConfig()
end)

-- Game Function Hooks

if config.enabled then
  -- Called multiple times per quest, updates playerstats object every time
  registerHook(syncQuestAwardInfo, onSyncQuestAwardInfo, nil)

  -- Called when entering quest reward state, prints stats if host
  registerHook(enterQuestReward, onEnterQuestReward, nil)

  -- Called when opening a sub-menu, adds custom items
  registerHook(guiManagerRequestSubMenu, onRequestSubMenu, nil)
end

logDebug("Better Hunter Highlights initialized successfully!")
