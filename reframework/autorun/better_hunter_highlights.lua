-- Better Hunter Highlights
--
-- Logs quest award contributions for all players at the end of a quest
-- Hooks into quest sync and result methods to collect and summarize player awards
-- ONLY WORKS WHEN YOU ARE THE QUEST HOST -> otherwise the userIndex param in syncQuestAwardInfo() is incorrect

-- types
local cQuestPlayingType = sdk.find_type_definition("app.cQuestPlaying")
local cQuestRewardType = sdk.find_type_definition("app.cQuestReward")
local cQuestDirectorType = sdk.find_type_definition("app.cQuestDirector")
local questDefType = sdk.find_type_definition("app.QuestDef")
local messageUtilType = sdk.find_type_definition("app.MessageUtil")

-- methods to hook
local syncQuestAwardInfo = cQuestDirectorType:get_method("syncQuestAwardInfo")
local notifyHostChangeQuestSession = cQuestDirectorType:get_method("notifyHostChangeQuestSession(System.Int32)")
local enterQuestPlaying = cQuestPlayingType:get_method("enter()")
local enterQuestReward = cQuestRewardType:get_method("enter()")

-- utility methods
local getTextHelper = messageUtilType:get_method("getText(System.Guid, System.Int32)")
local getAwardNameHelper = questDefType:get_method("Name(app.QuestDef.AwardID)")
local getAwardExplainHelper = questDefType:get_method("Explain(app.QuestDef.AwardID)")

-- variables
local isQuestHost = true
local playerstats = {}
local config = { enabled = true }

local DEBUG_MODE = true
local SESSION_TYPE = { LOBBY = 1, QUEST = 2, LINK = 3 }
local CONFIG_PATH = "better_hunter_highlights.json"

-- Save config to json file in data directory of reframework
local function saveConfig()
  json.dump_file(CONFIG_PATH, config)
  if DEBUG_MODE then
    log.debug("Config saved to " .. CONFIG_PATH)
  end
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
  if DEBUG_MODE and not ok then
    log.debug("ERROR in safeCall: " .. tostring(result))
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

--- Updates host status by checking NetworkManager singleton
local function updateQuestHost()
  local nm = sdk.get_managed_singleton("app.NetworkManager")
  if not nm then return end
  local uim = nm:get_UserInfoManager()
  if not uim then return end

  local ui = uim:call("getHostUserInfo(app.net_session_manager.SESSION_TYPE)", SESSION_TYPE.QUEST)
  if ui then
    isQuestHost = ui:get_IsSelf()
    if DEBUG_MODE then
      log.debug(string.format("Quest Host: %s (IsSelf: %s)", ui:getDispPlName(), tostring(isQuestHost)))
    end
  end
end

--- Handler for syncQuestAwardInfo hook
-- @param args table Hook arguments
-- @return sdk.PreHookResult|nil
local function onSyncQuestAwardInfo(args)
  if not isQuestHost then
    return sdk.PreHookResult.CALL_ORIGINAL
  end
  -- userIndex of the player who sent the sync packet
  local userIndex = safeCall(function()
    local idx = sdk.to_int64(args[3])
    if idx < 0 or idx >= 4 then error("Invalid userIndex: " .. tostring(idx)) end
    return idx
  end)
  if not userIndex then
    log.debug("ERROR: Invalid userIndex in syncQuestAwardInfo.")
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  -- the cQuestAwardSync packet itself
  local cQuestAwardSync = safeCall(function() return sdk.to_managed_object(args[4]) end)
  if not cQuestAwardSync then
    log.debug("ERROR: Invalid cQuestAwardSync in syncQuestAwardInfo.")
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  -- get stats from cQuestAwardSync and update playerstats
  local stats = extractAwardStats(cQuestAwardSync)
  playerstats[userIndex] = stats

  if DEBUG_MODE then
    local statsStr = {}
    for id, data in pairs(stats) do
      table.insert(statsStr, string.format("(%d|%d)", id, data.count or 0))
    end
    log.debug(string.format("Player [%d] Awards: %s", userIndex, table.concat(statsStr, ", ")))
  end
end

--- Handler for host change notification
-- @param args table Hook arguments
local function onNotifyHostChange(args)
  if DEBUG_MODE then
    log.debug("NotifyHostChangeSession called")
    log.debug("New Host ID: " .. tostring(sdk.to_int64(args[3])))
  end
end

--- Post-handler to update host flag
-- @param retval any Return value of original
-- @return any
local function onNotifyHostChangePost(retval)
  if DEBUG_MODE then
    log.debug("NotifyHostChangeSession post-hook called")
  end
  updateQuestHost()
  return retval
end

--- Handler when entering quest playing state
-- @param args table Hook arguments
local function onEnterQuestPlaying()
  if DEBUG_MODE then
    log.debug("Quest playing enter() called")
  end
  updateQuestHost()
end

--- Handler when entering quest reward state
-- @param args table Hook arguments
local function onEnterQuestReward(args)
  if DEBUG_MODE then
    log.debug("Quest reward enter() called")
  end
  -- skip if not quest host
  if not isQuestHost then
    if DEBUG_MODE then
      log.debug("Not the quest host, skipping quest reward enter() hook.")
    end
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  local networkManagerSingleton = sdk.get_managed_singleton("app.NetworkManager")
  if not networkManagerSingleton then
    log.debug("ERROR: NetworkManager singleton not found.")
    return
  end

  local userInfoManager = networkManagerSingleton:get_UserInfoManager()
  if not userInfoManager then
    log.debug("ERROR: UserInfoManager not found in NetworkManager.")
    return
  end

  local userInfoList = userInfoManager:getUserInfoList(SESSION_TYPE.QUEST)
  if not userInfoList then
    log.debug("ERROR: UserInfoList not found in UserInfoManager.")
    return
  end

  local memberNum = userInfoManager:getMemberNum(SESSION_TYPE.QUEST)
  if memberNum <= 0 then
    log.debug("ERROR: No members found in UserInfoList.")
    return
  end
  local userInfoArray = userInfoList._ListInfo
  if not userInfoArray then
    log.debug("ERROR: UserInfoArray is nil.")
    return
  end

  -- map playerstats to user by index
  local userIndexToAwards = {}

  for i = 0, memberNum - 1 do
    userIndexToAwards[i + 1] = { -- stupid 1-based indexing
      userName = userInfoArray[i]:get_PlName(),
      shortHunterId = userInfoArray[i]:get_ShortHunterId(),
      isSelf = userInfoArray[i]:get_IsSelf(),
      awards = playerstats[i] or {},
    }
  end

  -- Print all player awards
  if DEBUG_MODE then
    log.debug(" --- Player Awards ---")
    for _, data in pairs(userIndexToAwards) do
      local awardsStr = {}
      for _, award in pairs(data.awards) do
        table.insert(awardsStr, string.format("%s: %d", award.name, award.count))
      end
      log.debug(string.format("-> %s: %s", data.userName, table.concat(awardsStr, ", ")))
    end
    log.debug(" --- Damage to Main Target Large Monster ---")
    -- sort userIndexToAwards by damage count
    table.sort(userIndexToAwards, function(a, b)
      return (a.awards[4] and a.awards[4].count or 0) > (b.awards[4] and b.awards[4].count or 0)
    end)
    -- sum up total damage
    local dmgSum = 0
    for _, data in ipairs(userIndexToAwards) do
      local dmg = data.awards[4] and data.awards[4].count or 0
      dmgSum = dmgSum + dmg
    end
    -- print each player's info in order
    for _, data in ipairs(userIndexToAwards) do
      local dmg = data.awards[4] and data.awards[4].count or 0
      local percentage = dmgSum > 0 and (dmg / dmgSum) * 100 or 0
      log.debug(string.format("-> %s: %d dmg (%.2f%%)", data.userName, dmg, percentage))
    end
  end
end

-- Helper function to register hooks
local function registerHook(method, pre, post)
  if not method then return end
  sdk.hook(method, pre, post)
  if DEBUG_MODE then
    log.debug("Hook registered for method: " .. tostring(method:get_name()))
  end
end

-- Load configuration and add config save listener
loadConfig()

re.on_config_save(function()
  saveConfig()
  loadConfig()
end)

-- Draw REFramework UI
re.on_draw_ui(function()
  if imgui.tree_node("Better Hunter Highlights") then
    -- checkbox returns true if clicked
    if imgui.checkbox("Enable Mod", config.enabled) then
      -- toggle the flag and mark config dirty
      config.enabled = not config.enabled
    end

    -- optionally show more options only if enabled
    if config.enabled then
      imgui.indent(20)
      imgui.text("Stats will be shown at quest end.")
      -- here you could add more checkboxes/sliders
      imgui.unindent(20)
    end

    imgui.tree_pop()
  end
end)


-- Game Function Hooks

-- Called multiple times per quest, updates playerstats object every time
registerHook(syncQuestAwardInfo, onSyncQuestAwardInfo, nil)

-- Called when the host changes, updates quest host status
registerHook(notifyHostChangeQuestSession, onNotifyHostChange, onNotifyHostChangePost)

-- Called when entering quest playing state, updates quest host status
registerHook(enterQuestPlaying, onEnterQuestPlaying, nil)

-- Called when entering quest reward state, prints stats if host
registerHook(enterQuestReward, onEnterQuestReward, nil)


if DEBUG_MODE then
  log.debug("Better Hunter Highlights initialized successfully!")
end
