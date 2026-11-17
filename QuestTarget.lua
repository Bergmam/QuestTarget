-- QuestTarget: a secure "target macro" button per quest, plus one for all quests.
--
-- For every quest with unfinished kill objectives (and, when Questie is loaded,
-- the mobs that drop unfinished quest items) we build:
--   /cleartarget
--   /target [noexists][dead] Mob A
--   /target [noexists][dead] Mob B
--   /cleartarget [dead]
-- Secure attributes can't change in combat, so updates are queued until it ends.

local ADDON, ns = ...
local MAX_ROWS = 10
local MAX_MACRO = 1000
local MAX_DROP_NPCS = 6 -- per quest item, when pulling drop sources from Questie
local ROW_HEIGHT = 18
local WIDTH = 220
local ICON = "Interface\\Icons\\Ability_Hunter_SniperShot"

BINDING_HEADER_QUESTTARGET = "Quest Target"
_G["BINDING_NAME_CLICK QuestTargetAll:LeftButton"] = "Target any quest mob"
for i = 1, MAX_ROWS do
	_G["BINDING_NAME_CLICK QuestTargetRow" .. i .. ":LeftButton"] = "Target mobs of quest #" .. i
end

local db -- account-wide: settings, custom mob names
local charDB -- per character: pins (questID -> keybind slot)
local pendingUpdate = false
local QueueUpdate

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffQuestTarget|r: " .. tostring(msg))
end

---------------------------------------------------------------------------
-- Quest log compatibility (Classic-style globals first, then C_QuestLog)
---------------------------------------------------------------------------

local function NumQuestEntries()
	if GetNumQuestLogEntries then
		return (GetNumQuestLogEntries())
	end
	return (C_QuestLog.GetNumQuestLogEntries())
end

-- returns title, isHeader, questID, isComplete
local function QuestEntry(i)
	if GetQuestLogTitle then
		local title, _, _, isHeader, _, isComplete, _, questID = GetQuestLogTitle(i)
		return title, isHeader, questID, isComplete == 1
	end
	local info = C_QuestLog.GetInfo(i)
	if not info then
		return
	end
	local complete = info.questID and C_QuestLog.IsComplete and C_QuestLog.IsComplete(info.questID)
	return info.title, info.isHeader, info.questID, complete
end

local function IsWatched(i, questID)
	if IsQuestWatched then
		return IsQuestWatched(i)
	end
	if C_QuestLog.GetQuestWatchType and questID then
		return C_QuestLog.GetQuestWatchType(questID) ~= nil
	end
	return true
end

-- list of { text, type, finished }
local function QuestObjectives(i, questID)
	if questID and C_QuestLog and C_QuestLog.GetQuestObjectives then
		local objs = C_QuestLog.GetQuestObjectives(questID)
		if objs and #objs > 0 then
			return objs
		end
	end
	local out = {}
	if GetNumQuestLeaderBoards then
		for j = 1, GetNumQuestLeaderBoards(i) or 0 do
			local text, objType, finished = GetQuestLogLeaderBoard(j, i)
			out[#out + 1] = { text = text, type = objType, finished = finished }
		end
	end
	return out
end

-- "Bloodfury Harpy slain: 3/8" / "3/8 Bloodfury Harpy slain" -> "Bloodfury Harpy"
local function MobNameFromObjective(text)
	if not text then
		return
	end
	local s = text
	s = s:gsub("^%s*%d+%s*/%s*%d+%s+", "")
	s = s:gsub("%s*:%s*%d+%s*/%s*%d+%s*$", "")
	s = s:gsub("%s+[Ss]lain$", ""):gsub("%s+[Kk]illed$", "")
	s = strtrim(s)
	if s == "" then
		return
	end
	return s
end

---------------------------------------------------------------------------
-- Optional Questie lookup: which mobs drop the items a quest still needs
---------------------------------------------------------------------------

local function GetQuestieDB()
	if not QuestieLoader or not QuestieLoader.ImportModule then
		return
	end
	local ok, QuestieDB = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestieDB")
	if ok and QuestieDB and type(QuestieDB.GetQuest) == "function" then
		return QuestieDB
	end
end
ns.GetQuestieDB = GetQuestieDB

local function QuestieMobNames(questID, objectives, add)
	local QuestieDB = GetQuestieDB()
	if not QuestieDB or not questID then
		return
	end
	local ok, quest = pcall(QuestieDB.GetQuest, questID)
	if not ok or not quest or not quest.ObjectiveData then
		return
	end
	for j, data in ipairs(quest.ObjectiveData) do
		local obj = objectives[j]
		if not (obj and obj.finished) and data.Id then
			if data.Type == "monster" then
				local okName, name = pcall(QuestieDB.QueryNPCSingle, data.Id, "name")
				if okName then
					add(name)
				end
			elseif data.Type == "item" and type(QuestieDB.QueryItemSingle) == "function" then
				local okDrops, drops = pcall(QuestieDB.QueryItemSingle, data.Id, "npcDrops")
				if okDrops and type(drops) == "table" then
					for k = 1, math.min(#drops, MAX_DROP_NPCS) do
						local okName, name = pcall(QuestieDB.QueryNPCSingle, drops[k], "name")
						if okName then
							add(name)
						end
					end
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- Collect quests -> mob names
---------------------------------------------------------------------------

local function CollectQuests()
	local quests = {}
	for i = 1, NumQuestEntries() do
		local title, isHeader, questID, isComplete = QuestEntry(i)
		if title and not isHeader and not isComplete and (not db.watchedOnly or IsWatched(i, questID)) then
			local names, seen = {}, {}
			local function add(name)
				if type(name) == "string" and name ~= "" and not seen[name] then
					seen[name] = true
					names[#names + 1] = name
				end
			end

			local objectives = QuestObjectives(i, questID)
			for _, obj in ipairs(objectives) do
				if obj.type == "monster" and not obj.finished then
					add(MobNameFromObjective(obj.text))
				end
			end
			QuestieMobNames(questID, objectives, add)
			for _, name in ipairs((questID and db.custom[questID]) or {}) do
				add(name)
			end

			if #names > 0 then
				quests[#quests + 1] = { title = title, questID = questID, names = names }
			end
		end
	end
	return quests
end

local function BuildMacro(names)
	local tail = "/cleartarget [dead]"
	local lines = { "/cleartarget" }
	local len = #lines[1] + #tail + 2
	for _, name in ipairs(names) do
		local line = "/target [noexists][dead] " .. name
		if len + #line + 1 > MAX_MACRO then
			break
		end
		lines[#lines + 1] = line
		len = len + #line + 1
	end
	lines[#lines + 1] = tail
	return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------

local panel = CreateFrame("Frame", "QuestTargetFrame", UIParent)
panel:SetSize(WIDTH, 20)
panel:SetMovable(true)
panel:SetClampedToScreen(true)

local header = CreateFrame("Frame", nil, panel)
header:SetPoint("TOPLEFT")
header:SetPoint("TOPRIGHT")
header:SetHeight(ROW_HEIGHT)
header:EnableMouse(true)
header:RegisterForDrag("LeftButton")
header:SetScript("OnDragStart", function()
	if not db.locked then
		panel:StartMoving()
	end
end)
header:SetScript("OnDragStop", function()
	panel:StopMovingOrSizing()
	local point, _, relPoint, x, y = panel:GetPoint()
	db.pos = { point, relPoint, x, y }
end)

local headerText = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
headerText:SetPoint("LEFT", ROW_HEIGHT + 4, 0)
headerText:SetText("Quest Targets")

local function ClickRegistration()
	local keyDown = GetCVarBool and GetCVarBool("ActionButtonUseKeyDown")
	return keyDown and "AnyDown" or "AnyUp"
end

local function ShowNamesTooltip(self)
	if not self.names then
		return
	end
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:AddLine(self.tooltipTitle or "Quest Target")
	for _, name in ipairs(self.names) do
		GameTooltip:AddLine(name, 1, 1, 1)
	end
	if self.questID then
		if self.pinned then
			GameTooltip:AddLine("Pinned to keybind #" .. self.slot, 1, 0.6, 0)
			GameTooltip:AddLine("Right-click: unpin", 0.6, 0.6, 0.6)
		else
			GameTooltip:AddLine("Right-click: pin to keybind #" .. self.slot, 0.6, 0.6, 0.6)
		end
		GameTooltip:AddLine("Shift-right-click: add mob names", 0.6, 0.6, 0.6)
	end
	GameTooltip:Show()
end

local function CreateTargetButton(name, parent)
	local b = CreateFrame("Button", name, parent, "SecureActionButtonTemplate")
	b:SetHeight(ROW_HEIGHT)
	b:RegisterForClicks(ClickRegistration())
	b:SetAttribute("type1", "macro")

	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetSize(ROW_HEIGHT, ROW_HEIGHT)
	icon:SetPoint("LEFT")
	icon:SetTexture(ICON)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.12)

	b:SetScript("OnEnter", ShowNamesTooltip)
	b:SetScript("OnLeave", GameTooltip_Hide)
	-- PostClick runs after the macro, so the target is already updated here.
	b:SetScript("PostClick", function(self, button)
		if button == "RightButton" then
			if not self.questID then
				return
			end
			if IsShiftKeyDown() then
				StaticPopup_Show("QUESTTARGET_EDIT", self.tooltipTitle, nil, self.questID)
			elseif self.pinned then
				charDB.pins[self.questID] = nil
				QueueUpdate()
			else
				for questID, slot in pairs(charDB.pins) do
					if slot == self.slot then
						charDB.pins[questID] = nil -- one quest per slot
					end
				end
				charDB.pins[self.questID] = self.slot
				QueueUpdate()
			end
			GameTooltip:Hide()
		elseif not UnitExists("target") then
			local msg = self.questID and ("No mobs nearby for " .. self.tooltipTitle) or "No quest mobs nearby"
			UIErrorsFrame:AddMessage(msg, 1, 0.1, 0.1, 1)
		end
	end)
	return b
end

local allButton = CreateTargetButton("QuestTargetAll", header)
allButton:SetAllPoints(header)
allButton.tooltipTitle = "All quest mobs"
-- keep the header draggable through the button
allButton:RegisterForDrag("LeftButton")
allButton:SetScript("OnDragStart", header:GetScript("OnDragStart"))
allButton:SetScript("OnDragStop", header:GetScript("OnDragStop"))

local rows = {}
for i = 1, MAX_ROWS do
	local row = CreateTargetButton("QuestTargetRow" .. i, panel)
	row.slot = i
	row:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -i * ROW_HEIGHT)
	row:SetPoint("RIGHT", panel, "RIGHT")
	local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("LEFT", ROW_HEIGHT + 4, 0)
	text:SetPoint("RIGHT")
	text:SetJustifyH("LEFT")
	text:SetWordWrap(false)
	row.text = text
	-- shown while your current target is one of this quest's mobs
	local active = row:CreateTexture(nil, "BACKGROUND")
	active:SetAllPoints()
	active:SetColorTexture(1, 0.82, 0, 0.25)
	active:Hide()
	row.active = active
	row:Hide()
	rows[i] = row
end

-- Plain textures, so this is safe to run in combat.
local function UpdateTargetHighlight()
	local name = UnitExists("target") and not UnitIsPlayer("target") and UnitName("target")
	for _, row in ipairs(rows) do
		local match = false
		if name and row.names then
			for _, mob in ipairs(row.names) do
				if mob == name then
					match = true
					break
				end
			end
		end
		row.active:SetShown(match)
	end
end

local function Update()
	if InCombatLockdown() then
		pendingUpdate = true
		return
	end
	pendingUpdate = false

	local quests = CollectQuests()

	-- Pinned quests take their slot; the rest fill the free slots in log order.
	local slots, lastSlot = {}, 0
	for _, q in ipairs(quests) do
		local slot = q.questID and charDB.pins[q.questID]
		if slot and slot <= MAX_ROWS and not slots[slot] then
			slots[slot] = q
			q.pinned = true
			lastSlot = math.max(lastSlot, slot)
		end
	end
	local nextSlot = 1
	for _, q in ipairs(quests) do
		if not q.pinned then
			while slots[nextSlot] do
				nextSlot = nextSlot + 1
			end
			if nextSlot > MAX_ROWS then
				break
			end
			slots[nextSlot] = q
			lastSlot = math.max(lastSlot, nextSlot)
		end
	end

	local all, seen = {}, {}
	for i, row in ipairs(rows) do
		local q = slots[i]
		if q then
			row.questID = q.questID
			row.names = q.names
			row.tooltipTitle = q.title
			row.pinned = q.pinned
			row.text:SetFormattedText(
				"%s%d.|r %s |cff999999(%d)|r",
				q.pinned and "|cffff9900" or "|cffffffff",
				i,
				q.title,
				#q.names
			)
			row:SetAttribute("macrotext1", BuildMacro(q.names))
			row:Show()
		else
			row.questID, row.names, row.pinned = nil, nil, nil
			row:SetAttribute("macrotext1", nil)
			row:Hide()
		end
	end
	for _, q in ipairs(quests) do
		for _, name in ipairs(q.names) do
			if not seen[name] then
				seen[name] = true
				all[#all + 1] = name
			end
		end
	end
	allButton.names = all
	ns.questMobs = seen -- name -> true, read by the arrow
	allButton:SetAttribute("macrotext1", #all > 0 and BuildMacro(all) or nil)
	headerText:SetFormattedText("Quest Targets |cff999999(%d)|r", #all)
	UpdateTargetHighlight()

	panel:SetHeight(ROW_HEIGHT * (lastSlot + 1))
	panel:SetShown(not db.hidden and #quests > 0)
end

local updateQueued = false
QueueUpdate = function()
	if updateQueued then
		return
	end
	updateQueued = true
	C_Timer.After(0.3, function()
		updateQueued = false
		Update()
	end)
end

local function RestorePosition()
	panel:ClearAllPoints()
	if db.pos then
		panel:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4])
	else
		panel:SetPoint("RIGHT", UIParent, "RIGHT", -260, 120)
	end
end

StaticPopupDialogs["QUESTTARGET_EDIT"] = {
	text = "Extra mob names for\n%s\n(comma separated)",
	button1 = ACCEPT,
	button2 = CANCEL,
	hasEditBox = 1,
	editBoxWidth = 260,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
	OnShow = function(self, questID)
		local eb = self.editBox or self.EditBox
		eb:SetText(table.concat(db.custom[questID] or {}, ", "))
		eb:HighlightText()
	end,
	OnAccept = function(self, questID)
		local eb = self.editBox or self.EditBox
		local list = {}
		for part in eb:GetText():gmatch("[^,]+") do
			part = strtrim(part)
			if part ~= "" then
				list[#list + 1] = part
			end
		end
		db.custom[questID] = #list > 0 and list or nil
		QueueUpdate()
	end,
	EditBoxOnEnterPressed = function(eb)
		local dialog = eb:GetParent()
		StaticPopupDialogs["QUESTTARGET_EDIT"].OnAccept(dialog, dialog.data)
		dialog:Hide()
	end,
	EditBoxOnEscapePressed = function(eb)
		eb:GetParent():Hide()
	end,
}

---------------------------------------------------------------------------
-- Events and slash command
---------------------------------------------------------------------------

local function AutoPinEnabled()
	return db.autoPin ~= false -- on by default
end

-- Killing a quest's mob pins that quest to the slot it's in right now.
-- Rows can't move during combat, so the current slot is the one the player sees.
local function AutoPinForKill(mobName)
	for _, row in ipairs(rows) do
		if row.questID and not row.pinned and row.names then
			for _, name in ipairs(row.names) do
				if name == mobName then
					charDB.pins[row.questID] = row.slot
					row.pinned = true
					QueueUpdate()
					break
				end
			end
		end
	end
end

local combatLog = CreateFrame("Frame")
combatLog:SetScript("OnEvent", function()
	local _, subevent, _, _, _, _, _, destGUID, destName = CombatLogGetCurrentEventInfo()
	-- PARTY_KILL: killing blow by you or your group. UNIT_DIED on your target
	-- also covers kills finished by pets or others.
	if subevent == "PARTY_KILL" or (subevent == "UNIT_DIED" and destGUID == UnitGUID("target")) then
		if destName then
			AutoPinForKill(destName)
		end
	end
end)

local function UpdateAutoPinListener()
	if AutoPinEnabled() then
		combatLog:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	else
		combatLog:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("QUEST_LOG_UPDATE")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_TARGET_CHANGED")
pcall(events.RegisterEvent, events, "QUEST_WATCH_LIST_CHANGED")
-- a pin lasts until the quest leaves the log (turned in or abandoned)
pcall(events.RegisterEvent, events, "QUEST_TURNED_IN")
pcall(events.RegisterEvent, events, "QUEST_REMOVED")
events:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON then
			QuestTargetDB = QuestTargetDB or {}
			db = QuestTargetDB
			db.custom = db.custom or {}
			ns.db = db
			QuestTargetCharDB = QuestTargetCharDB or {}
			charDB = QuestTargetCharDB
			charDB.pins = charDB.pins or {}
			RestorePosition()
			UpdateAutoPinListener()
		elseif arg1 == "Questie" and db then
			QueueUpdate()
		end
		return
	end
	if not db then
		return
	end
	if (event == "QUEST_TURNED_IN" or event == "QUEST_REMOVED") and arg1 then
		charDB.pins[arg1] = nil
	end
	if event == "PLAYER_TARGET_CHANGED" then
		UpdateTargetHighlight()
		return
	end
	if event == "PLAYER_REGEN_ENABLED" then
		if pendingUpdate then
			Update()
		end
		return
	end
	if event == "PLAYER_ENTERING_WORLD" then
		-- Questie builds its DB a few seconds after login
		C_Timer.After(5, QueueUpdate)
	end
	QueueUpdate()
end)

SLASH_QUESTTARGET1 = "/qt"
SLASH_QUESTTARGET2 = "/questtarget"
SlashCmdList.QUESTTARGET = function(msg)
	local cmd = strtrim(msg or ""):lower()
	if cmd == "lock" then
		db.locked = not db.locked
		Print(db.locked and "locked" or "unlocked (drag the header to move)")
	elseif cmd == "watched" then
		db.watchedOnly = not db.watchedOnly
		Print(db.watchedOnly and "showing watched quests only" or "showing all quests")
		QueueUpdate()
	elseif cmd == "reset" then
		db.pos = nil
		if not InCombatLockdown() then
			RestorePosition()
		end
		Print("position reset")
	elseif cmd == "autopin" then
		db.autoPin = not AutoPinEnabled()
		UpdateAutoPinListener()
		Print(db.autoPin and "auto-pin on: killing a quest's mob pins that quest" or "auto-pin off")
	elseif cmd == "arrow" then
		db.arrow = db.arrow == false
		if ns.RefreshArrow then
			ns.RefreshArrow()
		end
		Print(db.arrow and "arrow on" or "arrow off")
	elseif cmd == "unpin" then
		wipe(charDB.pins)
		QueueUpdate()
		Print("all quests unpinned")
	elseif cmd == "macro" then
		Print("\n" .. (allButton:GetAttribute("macrotext1") or "(no quest mobs)"))
	elseif cmd == "" or cmd == "toggle" then
		db.hidden = not db.hidden
		QueueUpdate()
		Print(db.hidden and "panel hidden (keybinds still work)" or "panel shown")
	else
		Print("/qt - show/hide panel | /qt lock | /qt watched | /qt reset | /qt autopin | /qt arrow | /qt unpin | /qt macro")
	end
end
