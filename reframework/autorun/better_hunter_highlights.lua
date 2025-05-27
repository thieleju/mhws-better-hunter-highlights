--
-- Better Hunter Highlights
--
-- Logs quest award contributions for all players at the end of a quest
-- Hooks into quest sync and result methods to collect and summarize player awards
--
---@diagnostic disable: undefined-global, undefined-doc-name

-- types
local cQuestRewardType                        = sdk.find_type_definition("app.cQuestReward")
local cQuestDirectorType                      = sdk.find_type_definition("app.cQuestDirector")
local questDefType                            = sdk.find_type_definition("app.QuestDef")
local messageUtilType                         = sdk.find_type_definition("app.MessageUtil")
local subMenuType                             = sdk.find_type_definition("app.cGUISubMenuInfo")
local guidType                                = sdk.find_type_definition("System.Guid")
local guiManagerType                          = sdk.find_type_definition("app.GUIManager")
-- local gui070003PartsList                      = sdk.find_type_definition("app.GUI070003PartsList")
-- local guiBaseAppType                          = sdk.find_type_definition("app.GUIBaseApp")
-- local guiUtilAppType                          = sdk.find_type_definition("app.GUIUtilApp")
-- local gui040301                               = sdk.find_type_definition("app.GUI040301")
local guiInputCtrlFluentScrollListType        = sdk.find_type_definition(
  "ace.cGUIInputCtrl_FluentScrollList`2<app.GUIID.ID,app.GUIFunc.TYPE>")

-- methods to hook
local syncQuestAwardInfo                      = cQuestDirectorType:get_method("syncQuestAwardInfo")
local enterQuestReward                        = cQuestRewardType:get_method("enter()")
local guiManagerRequestSubMenu                = guiManagerType:get_method("requestSubMenu")
local guiInputCtrlFluentScrollListIndexChange = guiInputCtrlFluentScrollListType:get_method(
  "getSelectedIndex")
-- local updateListItem = gui070003PartsList:get_method("updateListItem")

-- utility methods
local getAwardNameHelper                      = questDefType:get_method("Name(app.QuestDef.AwardID)")
local getAwardExplainHelper                   = questDefType:get_method("Explain(app.QuestDef.AwardID)")
local getAwardThresholdHelper                 = questDefType:get_method("Threshold(app.QuestDef.AwardID)")
local getAwardUnitHelper                      = questDefType:get_method("Unit(app.QuestDef.AwardID)")
local getAwardWeightHelper                    = questDefType:get_method("Weight(app.QuestDef.AwardID)")
local getTextHelper                           = messageUtilType:get_method("getText(System.Guid, System.Int32)")
local newGuid                                 = guidType:get_method("NewGuid")
local addSubMenuItem                          = subMenuType:get_method(
  "addItem(System.String, System.Guid, System.Guid, System.Boolean, System.Boolean, System.Action)")
-- local setMessageApp                           = guiBaseAppType:get_method(
--   "setMessageApp(via.gui.Text, app.MessageDef.DIRECT, System.String, System.Func`2<System.String,System.String>)")
-- local setTextColor                            = guiUtilAppType:get_method("setTextColor")
-- local getText                                 = messageUtilType:get_method("getText(System.Guid, System.Int32)")

-- variables
local selectedHunterId                        = ""
local memberAwardStats                        = {}
local showAwardWindow                         = false
local config                                  = { enabled = true, debug = true, cache = {} }

local AWARD_UNIT                              = { COUNT = 0, TIME = 1, NONE = 2 }
local SESSION_TYPE                            = { LOBBY = 1, QUEST = 2, LINK = 3 }
local CONFIG_PATH                             = "better_hunter_highlights.json"
local DAMAGE_AWARD_ID                         = 4
local SUBMENU_CHAR_LIMIT                      = 35
local COLORS                                  = {
  0x50e580f5, -- pink
  0x500000ff, -- red
  0x5049cff5, -- yellow
  0x50a4ffa4, -- green
  0xCC666666, -- gray
}

-- Log debug message
local function logDebug(message)
  if config.debug then
    log.debug("[Better Hunter Highlights] " .. message)
  end
end

-- Log error message
local function logError(message)
  logDebug("[Better Hunter Highlights] ERROR: " .. message)
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
--- @param fn function The function to call
--- @return any|nil The result if successful
local function safeCall(fn)
  local ok, result = pcall(fn)
  if not ok then
    logError("SafeCall: " .. tostring(result))
  end
  return ok and result or nil
end

--- Get meta information about an award by its awardId
--- @param awardId number The ID of the award
--- @return table Table containing award metadata
local function getAwardMeta(awardId)
  -- Helper to resolve GUIDs to text
  local function guidToText(guid, fallbackPrefix)
    if not guid then
      return string.format("%s_%d", fallbackPrefix, awardId)
    end
    local text = safeCall(function()
      return getTextHelper:call(nil, guid, 0)
    end)
    return text or string.format("%s_%d", fallbackPrefix, awardId)
  end

  -- guid return values (name, explain)
  local nameGuid = safeCall(function()
    return getAwardNameHelper:call(nil, awardId)
  end)
  local explainGuid = safeCall(function()
    return getAwardExplainHelper:call(nil, awardId)
  end)

  -- non guid return values (threshold, unit, weight)
  local threshold = safeCall(function()
    return getAwardThresholdHelper:call(nil, awardId)
  end) or -1

  local unit = safeCall(function()
    return getAwardUnitHelper:call(nil, awardId)
  end) or -1

  local weight = safeCall(function()
    return getAwardWeightHelper:call(nil, awardId)
  end) or -1

  return {
    awardId = awardId,
    name = guidToText(nameGuid, "Award"),
    explain = guidToText(explainGuid, "Explain"),
    threshold = threshold,
    unit = unit,
    weight = weight,
  }
end

--- Extracts awardsArray from a sync packet
--- @param packet userdata The cQuestAwardSync packet
--- @return table[] Table of awardId to awardsArray
local function extractAwardStats(packet)
  local awardsArray = {}

  -- award01 is special case, its type is System.UInt32[]
  local award01Count = safeCall(function()
    local award01Array = packet["award01"]
    if not award01Array then return 0 end
    -- sum up all 4 elements of the array (It's always 4)
    return award01Array:get_Item(0) + award01Array:get_Item(1) + award01Array:get_Item(2) + award01Array:get_Item(3)
  end)

  -- insert award01
  local meta0 = getAwardMeta(0)
  meta0.count = award01Count
  table.insert(awardsArray, meta0)

  -- awards 02 to 30
  for i = 2, 30 do
    local raw = safeCall(function()
      return packet[string.format("award%02d", i)]
    end)
    local meta = getAwardMeta(i - 1)
    meta.count = raw and math.floor(raw) or 0
    table.insert(awardsArray, meta)
  end
  return awardsArray
end

--- Helper function to get the damage award count by ID
--- @param awards table[] The awards array from a player
--- @return number The count of damage awards
local function getDamageCount(awards)
  for _, award in ipairs(awards) do
    if award.awardId == DAMAGE_AWARD_ID then
      return award.count or 0
    end
  end
  return 0
end

--- Prints member award stats and damage to main target table
local function printMemberAwardStats()
  logDebug(" --- Player Awards ---")
  -- Print all award stats per member
  for _, data in pairs(memberAwardStats) do
    local awardsStr = {}
    for _, award in ipairs(data.awards) do
      table.insert(awardsStr, string.format("%s: %d(%d)", award.name, award.count, award.threshold))
    end
    logDebug(string.format("  -> %s(%d): %s", data.username or "unknown", data.memberIndex or -1,
      table.concat(awardsStr, ", ")))
  end

  logDebug(" --- Damage to Main Target Large Monster ---")

  -- Sort memberAwardStats by damage count
  table.sort(memberAwardStats, function(a, b)
    return getDamageCount(a.awards) > getDamageCount(b.awards)
  end)

  -- Print each player's damage and percentage
  for _, data in ipairs(memberAwardStats) do
    logDebug(string.format("  -> %s(%d): %d dmg (%.2f%%)", data.username or "unknown", data.memberIndex or -1,
      data.damage, data.damagePercentage))
  end
end

--- Handler for syncQuestAwardInfo hook
--- @param args table Hook arguments
--- @return sdk.PreHookResult|nil
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
  local statsArray = extractAwardStats(cQuestAwardSync)
  local slot = userIndex + 1
  memberAwardStats[slot] = memberAwardStats[slot] or { memberIndex = userIndex }
  memberAwardStats[slot].awards = statsArray

  local parts = {}
  for _, award in ipairs(statsArray) do
    table.insert(parts, string.format("(%d|%d)", award.awardId, award.count))
  end
  logDebug(string.format("Player %d: Awards: %s", userIndex, table.concat(parts, ", ")))
end

--- Handler when entering quest reward state
--- @param args table Hook arguments
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

  -- Calculate total damage for percentage calculation
  local totalDamage = 0
  for _, data in ipairs(memberAwardStats) do
    totalDamage = totalDamage + getDamageCount(data.awards)
  end
  -- complete memberAwardStats with user info and damage stats
  for i = 0, memberNum - 1 do
    logDebug(string.format("Member %s is at index %d", userInfoArray[i]:get_PlName(), i + 1))
    local entry = memberAwardStats[i + 1] or { memberIndex = i, awards = {} }
    local damage = getDamageCount(entry.awards)
    local damagePercentage = totalDamage > 0 and (damage / totalDamage) * 100 or 0

    entry.username = userInfoArray[i]:get_PlName()
    entry.shortHunterId = userInfoArray[i]:get_ShortHunterId()
    entry.isSelf = userInfoArray[i]:get_IsSelf()
    entry.damageTotal = totalDamage
    entry.damagePercentage = damagePercentage
    entry.damage = damage

    memberAwardStats[i + 1] = entry
  end

  -- Print all member award stats with dmg table
  printMemberAwardStats()

  -- Cache the latest memberAwardStats
  config.cache = memberAwardStats
  saveConfig()
  logDebug("Cached memberAwardStats in config")
end

--- Handler for when sub menus open
--- @param args table Hook arguments
local function onRequestSubMenu(args)
  if not config.enabled then
    return sdk.PreHookResult.SKIP_ORIGINAL
  end

  local owner = sdk.to_managed_object(args[3])
  local subMenu = sdk.to_managed_object(args[4])

  logDebug("RequestSubMenu called for " .. tostring(owner:get_type_definition():get_full_name()))

  if subMenu == nil then
    logDebug("requestSubMenu subMenu is nil")
    return sdk.PreHookResult.SKIP_ORIGINAL
  end

  -- skip all submenus except the one for parts list
  if owner:get_type_definition():get_full_name() ~= "app.GUI070003PartsList" then
    return sdk.PreHookResult.SKIP_ORIGINAL
  end

  local item0 = subMenu:getItem(0)
  local item1 = subMenu:getItem(1)
  local item2 = subMenu:getItem(2)

  item0:clear()
  item0:set_IsEnable(true)
  item0:set_IsChecked(true)
  item1:clear()
  item1:set_IsEnable(true)
  item1:set_IsChecked(true)
  item2:clear()
  item2:set_IsEnable(true)
  item2:set_IsChecked(true)

  local emptyAction = sdk.create_instance(sdk.typeof("System.Action"))
  item0:set_ExecuteAction(emptyAction)
  item1:set_ExecuteAction(emptyAction)
  item2:set_ExecuteAction(emptyAction)

  -- find memberAwardStats element with hunterId matching selectedHunterId
  local memberAward = nil
  for i = 1, #memberAwardStats do
    local data = memberAwardStats[i]
    if data and data.shortHunterId == selectedHunterId then
      memberAward = data
      break
    end
  end

  if not memberAward then
    logDebug("No member award found for selected hunter ID: " .. tostring(selectedHunterId))
    return sdk.PreHookResult.SKIP_ORIGINAL
  end

  local awardCount = memberAward and #memberAward.awards or 0
  if awardCount == 0 then
    logDebug("No awards found for selected hunter ID: " .. tostring(selectedHunterId))
    return sdk.PreHookResult.SKIP_ORIGINAL
  end

  -- sort awards list to ensure damage award is first
  table.sort(memberAward.awards, function(a, b)
    if a.awardId == DAMAGE_AWARD_ID then return true end
    if b.awardId == DAMAGE_AWARD_ID then return false end
    return a.awardId < b.awardId
  end)

  -- add a custom item for each award to the sub menu
  for i = 1, awardCount do
    local award = memberAward.awards[i]
    -- skip awards that are 0
    if award and award.count and award.count > 0 then
      local guid = newGuid:call(nil)
      -- check if damage award
      local itemText
      if award.awardId == DAMAGE_AWARD_ID then
        itemText = string.format("Damage: %d (%.2f%%)", award.count, memberAward.damagePercentage)
      else
        -- get explain text but limit to #SUBMENU_CHAR_LIMIT characters
        local explainText = award.explain or ""
        if #explainText > SUBMENU_CHAR_LIMIT then
          explainText = explainText:sub(1, SUBMENU_CHAR_LIMIT) .. "..."
        end
        -- check if time unit
        if award.unit == AWARD_UNIT.TIME then
          -- change it to format 00'00
          local minutes = math.floor(award.count / 60)
          local seconds = award.count % 60
          itemText = string.format("%s: %02d'%02d", explainText, minutes, seconds)
        else
          -- default to count unit
          itemText = string.format("%s: %d", explainText, award.count or 0)
        end
      end
      addSubMenuItem:call(subMenu, itemText, guid, guid, true, false, emptyAction)
      logDebug(string.format("Added sub menu item: %s (ID: %d)", itemText, award.awardId))
    end
  end

  return sdk.PreHookResult.CALL_ORIGINAL
end


--- Handler for fluent scroll list index change
--- @param args table Hook arguments
--- @return sdk.PreHookResult|nil
local function onIndexChange(args)
  if not config.enabled then
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  local guiInputCtrlFluentScrollList = sdk.to_managed_object(args[2])
  if not guiInputCtrlFluentScrollList then
    logError("Invalid guiInputCtrlFluentScrollList in onIndexChange.")
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  -- get SelectedItem field
  local selectedItem = guiInputCtrlFluentScrollList:call("getSelectedItem")
  if not selectedItem then
    logError("SelectedItem is nil in onIndexChange.")
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  -- beware: this is a hardcoded path to the text element in the hunter highlights menu. I know this is ugly...
  local panelType = sdk.typeof("via.gui.Panel")
  local textType = sdk.typeof("via.gui.Text")

  local panel1Children = selectedItem:call("getChildren", panelType)
  if not panel1Children then
    logError("Panel1Children is nil in onIndexChange.")
    return sdk.PreHookResult.CALL_ORIGINAL
  end
  local panel1Child = panel1Children[2]
  if not panel1Child then
    logError("Panel1Child is nil in onIndexChange with #children = " .. tostring(#panel1Children))
    return sdk.PreHookResult.CALL_ORIGINAL
  end
  local panel2Children = panel1Child:call("getChildren", panelType)
  if not panel2Children then
    logError("Panel2Children is nil in onIndexChange.")
    return sdk.PreHookResult.CALL_ORIGINAL
  end
  local panel2Child = panel2Children[0]
  if not panel2Child then
    logError("Panel2Child is nil in onIndexChange with #children = " .. tostring(#panel2Children))
    return sdk.PreHookResult.CALL_ORIGINAL
  end
  local panel3Children = panel2Child:call("getChildren", panelType)
  if not panel3Children then
    logError("Panel3Children is nil in onIndexChange.")
    return sdk.PreHookResult.CALL_ORIGINAL
  end
  local panel3Child = panel3Children[1]
  if not panel3Child then
    logError("Panel3Child is nil in onIndexChange with #children = " .. tostring(#panel3Children))
    return sdk.PreHookResult.CALL_ORIGINAL
  end
  local textChildren = panel3Child:call("getChildren", textType)
  if not textChildren then
    logError("TextChildren panel3 is nil in onIndexChange.")
    return sdk.PreHookResult.CALL_ORIGINAL
  end
  local textChild = textChildren[0]
  if not textChild then
    logError("TextChild is nil in onIndexChange with #children = " .. tostring(#textChildren))
    return sdk.PreHookResult.CALL_ORIGINAL
  end
  local hunterId = textChild:call("get_Message")
  logDebug("Selected Hunter ID: " .. tostring(hunterId))
  selectedHunterId = hunterId
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

    imgui.indent(20)

    -- Use cached stats if live stats are empty
    if #memberAwardStats == 0 and config.cache then
      memberAwardStats = config.cache
    end

    -- only show button if memberAwardStats has data
    local buttonText = showAwardWindow and "Close Hunter Highlights Window" or "Show Hunter Highlights Window"
    if #memberAwardStats > 0 then
      if imgui.button(buttonText) then
        showAwardWindow = not showAwardWindow
      end
    else
      imgui.text("No hunter highlights available yet")
    end

    imgui.unindent(20)

    -- checkbox for debug mode
    if imgui.checkbox("Debug Mode", config.debug) then
      config.debug = not config.debug
      logDebug("Config set debug mode to " .. tostring(config.debug))
    end

    imgui.tree_pop()
  end


  if showAwardWindow then
    local openFlag = { true }

    if imgui.begin_window("Better Hunter Highlights - Awards", openFlag, 64) then
      local hasValidData = memberAwardStats and #memberAwardStats > 0 and memberAwardStats[1].awards

      if not hasValidData then
        imgui.text("No award data available.")
      else
        local colCount = 3 + #memberAwardStats
        local tableFlags = imgui.TableFlags.Borders | imgui.TableFlags.SizingFixedFit | imgui.TableFlags.RowBg |
            imgui.TableFlags.ScrollY | imgui.TableFlags.Sortable | imgui.TableFlags.Resizable

        if imgui.begin_table("awards_table", colCount, tableFlags) then
          -- Header setup
          imgui.table_setup_column("ID")
          imgui.table_setup_column("Title")
          imgui.table_setup_column("Description")

          imgui.table_next_row()
          for i = 1, #memberAwardStats do
            imgui.table_setup_column(memberAwardStats[i].username or ("Player " .. tostring(i)), nil, 130)
          end

          imgui.table_headers_row()

          for awardIndex = 1, #(memberAwardStats[1].awards or {}) do
            local firstAward = memberAwardStats[1].awards[awardIndex]
            if firstAward then
              imgui.table_next_row()

              imgui.table_set_column_index(0)
              imgui.text(tostring(awardIndex))

              imgui.table_set_column_index(1)
              imgui.text(firstAward.name or ("Award " .. tostring(awardIndex)))

              imgui.table_set_column_index(2)
              imgui.text(firstAward.explain or "")

              -- columns per player
              for playerIndex = 1, #memberAwardStats do
                local player = memberAwardStats[playerIndex]
                local award = player.awards and player.awards[awardIndex]
                imgui.table_set_column_index(2 + playerIndex)

                local count = award and award.count or 0
                local valueStr = tostring(count)

                -- add percentage if it's the damage award
                if award and award.awardId == DAMAGE_AWARD_ID then
                  local percent = player.damagePercentage or 0
                  valueStr = string.format("%d (%.2f%%)", count, percent)
                end

                if award.unit == AWARD_UNIT.TIME then
                  -- change it to format 00'00
                  local minutes = math.floor(award.count / 60)
                  local seconds = award.count % 60
                  valueStr = string.format("%02d'%02d", minutes, seconds)
                end

                -- highlight non-zero values
                if valueStr ~= "0" and valueStr ~= "" and valueStr ~= "00'00" then
                  imgui.table_set_bg_color(3, COLORS[playerIndex % #COLORS], imgui.table_get_column_index())
                  imgui.text(valueStr)
                else
                  imgui.text(valueStr)
                end
              end
            end
          end
          imgui.end_table()
        end
      end
      imgui.end_window()
    end

    if not openFlag[1] then
      showAwardWindow = false
    end
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

  -- Called when a fluent scroll list index changes, used to update the selected index in the hunter highlights menu
  registerHook(guiInputCtrlFluentScrollListIndexChange, onIndexChange, nil)
end

logDebug("Better Hunter Highlights initialized successfully!")
