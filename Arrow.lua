-- Arrow toward the targeted quest mob when it's too far away to have a nameplate.
--
-- The game doesn't give addons the position of other units, so the arrow
-- points at the nearest known spawn point of that NPC (from Questie's database)
-- in the zone you're in. Without Questie, or without spawn data, no arrow shows.

local _, ns = ...

local UPDATE_INTERVAL = 0.05
local ARROW_TEXTURE = "Interface\\Minimap\\MinimapArrow"

local frame = CreateFrame("Frame", "QuestTargetArrow", UIParent)
frame:SetSize(56, 70)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
frame:Hide()

local arrow = frame:CreateTexture(nil, "ARTWORK")
arrow:SetSize(48, 48)
arrow:SetPoint("TOP")
arrow:SetTexture(ARROW_TEXTURE)

local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
label:SetPoint("TOP", arrow, "BOTTOM", 0, 2)

local function ArrowEnabled()
	return ns.db and ns.db.arrow ~= false -- on by default
end

---------------------------------------------------------------------------
-- Spawn points: npcID -> uiMapID -> { {x, y}, ... } with x, y in 0..1
---------------------------------------------------------------------------

local spawnCache = {}

local function GetZoneDB()
	if not QuestieLoader or not QuestieLoader.ImportModule then
		return
	end
	local ok, ZoneDB = pcall(QuestieLoader.ImportModule, QuestieLoader, "ZoneDB")
	if ok and ZoneDB and type(ZoneDB.GetUiMapIdByAreaId) == "function" then
		return ZoneDB
	end
end

local function SpawnsByMap(npcID)
	local cached = spawnCache[npcID]
	if cached ~= nil then
		return cached or nil
	end
	local QuestieDB = ns.GetQuestieDB and ns.GetQuestieDB()
	local ZoneDB = GetZoneDB()
	if not QuestieDB or not ZoneDB or type(QuestieDB.QueryNPCSingle) ~= "function" then
		return -- Questie not ready yet; don't cache the miss
	end
	local ok, spawns = pcall(QuestieDB.QueryNPCSingle, npcID, "spawns")
	local byMap = {}
	if ok and type(spawns) == "table" then
		for areaID, points in pairs(spawns) do
			local okMap, uiMapID = pcall(ZoneDB.GetUiMapIdByAreaId, ZoneDB, areaID)
			if okMap and uiMapID and type(points) == "table" then
				local list = byMap[uiMapID] or {}
				for _, p in ipairs(points) do
					if p[1] and p[2] and p[1] >= 0 and p[2] >= 0 then
						list[#list + 1] = { p[1] / 100, p[2] / 100 }
					end
				end
				byMap[uiMapID] = list
			end
		end
	end
	spawnCache[npcID] = next(byMap) and byMap or false
	return spawnCache[npcID] or nil
end

local function NpcIDFromGUID(guid)
	if not guid then
		return
	end
	local unitType, _, _, _, _, npcID = strsplit("-", guid)
	if unitType == "Creature" or unitType == "Vehicle" then
		return tonumber(npcID)
	end
end

local mapSizeCache = {}
local function MapSize(uiMapID)
	local size = mapSizeCache[uiMapID]
	if size then
		return size[1], size[2]
	end
	local w, h
	if C_Map.GetMapWorldSize then
		w, h = C_Map.GetMapWorldSize(uiMapID)
	end
	if not w or w == 0 or not h or h == 0 then
		w, h = 1, 2 / 3 -- most zone maps are about 3:2
	end
	mapSizeCache[uiMapID] = { w, h }
	return w, h
end

---------------------------------------------------------------------------
-- Update
---------------------------------------------------------------------------

-- returns angle (radians, counter-clockwise from north) and distance in yards
local function NearestSpawnDirection()
	local Plain = ns.Plain
	if not UnitExists("target") or Plain(UnitIsDead("target")) or Plain(UnitIsPlayer("target")) then
		return
	end
	if C_NamePlate and C_NamePlate.GetNamePlateForUnit("target") then
		return -- its nameplate is on screen, no arrow needed
	end
	local name = Plain(UnitName("target"))
	if not (ns.questMobs and name and ns.questMobs[name]) then
		return
	end
	local npcID = NpcIDFromGUID(Plain(UnitGUID("target")))
	local byMap = npcID and SpawnsByMap(npcID)
	if not byMap then
		return
	end
	local uiMapID = C_Map.GetBestMapForUnit("player")
	local points = uiMapID and byMap[uiMapID]
	if not points or #points == 0 then
		return
	end
	local pos = C_Map.GetPlayerMapPosition(uiMapID, "player")
	if not pos then
		return
	end
	local px, py = pos:GetXY()
	local w, h = MapSize(uiMapID)

	local bestEast, bestNorth, bestDist
	for _, p in ipairs(points) do
		local east = (p[1] - px) * w
		local north = (py - p[2]) * h -- map y grows southward
		local dist = east * east + north * north
		if not bestDist or dist < bestDist then
			bestEast, bestNorth, bestDist = east, north, dist
		end
	end
	return math.atan2(-bestEast, bestNorth), math.sqrt(bestDist)
end

local elapsedSince = 0
frame:SetScript("OnUpdate", function(self, elapsed)
	elapsedSince = elapsedSince + elapsed
	if elapsedSince < UPDATE_INTERVAL then
		return
	end
	elapsedSince = 0
	local angle, dist = NearestSpawnDirection()
	local facing = GetPlayerFacing and GetPlayerFacing()
	if not angle or not facing then
		self:Hide()
		return
	end
	arrow:SetRotation(angle - facing)
	if C_Map.GetMapWorldSize then
		label:SetFormattedText("~%d yd", dist)
	else
		label:SetText("")
	end
end)

-- The OnUpdate stops while hidden, so a small watcher decides when to show it.
local watcher = CreateFrame("Frame")
local function Refresh()
	if ArrowEnabled() and NearestSpawnDirection() then
		frame:Show()
	else
		frame:Hide()
	end
end
ns.RefreshArrow = Refresh

watcher:RegisterEvent("PLAYER_TARGET_CHANGED")
watcher:RegisterEvent("NAME_PLATE_UNIT_ADDED")
watcher:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
watcher:RegisterEvent("ZONE_CHANGED_NEW_AREA")
watcher:RegisterEvent("UNIT_HEALTH")
watcher:SetScript("OnEvent", function(_, event, unit)
	if event == "UNIT_HEALTH" and unit ~= "target" then
		return
	end
	-- nameplate events fire before the plate is fully attached; check next frame
	C_Timer.After(0, Refresh)
end)
