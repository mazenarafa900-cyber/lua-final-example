
--[[
	CoreServer.lua

	Authoritative server controller.
	This script is the single source of truth for all persistent gameplay systems.

	Responsibilities:
	- Economy & currency flow
	- Inventory and tool ownership
	- Loadout management
	- Daily rewards
	- Secure data persistence

	Design rules:
	- Clients may only REQUEST actions
	- Server validates, executes, and saves
	- No client-side state is trusted
]]

---------------------------------------------------------------------
-- SERVICES
-- Core Roblox services required for player lifecycle, storage, and timing
---------------------------------------------------------------------

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

---------------------------------------------------------------------
-- DATASTORE & REMOTE GATEWAY
-- One datastore, one RemoteEvent = predictable, auditable behavior
---------------------------------------------------------------------

-- Single structured datastore prevents partial or conflicting saves
local PlayerStore = DataStoreService:GetDataStore("PlayerData_v3")

-- Sole client → server entry point
-- Clients cannot perform actions directly; they may only request them
local event = ReplicatedStorage:WaitForChild("core")

---------------------------------------------------------------------
-- CONFIGURATION CONSTANTS
-- Tunables are centralized to avoid magic numbers
---------------------------------------------------------------------

local AUTO_SAVE_INTERVAL = 60          -- Seconds between autosaves
local MAX_TRANSACTION = 1000           -- Hard cap on money changes (anti-abuse)
local MAX_LOADOUT_SLOTS = 3             -- Prevents unbounded loadout growth
local DEFAULT_TOOL = "Sword"            -- Starter tool for new players
local DAILY_REWARD = 150                -- Daily reward payout
local CONSUMABLE_DURATION = 20          -- Default buff duration
local SAVE_RETRIES = 3                  -- DataStore retry attempts

---------------------------------------------------------------------
-- SHOP DEFINITION
-- Server-validated catalog; UI never defines gameplay rules
---------------------------------------------------------------------

local Shop = {
	Sword   = { price = 200, type = "tool" },
	Pistol  = { price = 450, type = "tool" },
	Grenade = { price = 250, type = "tool" },
	MedKit  = { price = 100, type = "consumable", heal = 50 },
	XPBoost = { price = 300, type = "consumable", multiplier = 2, duration = 30 }
}

-- Explicit allowlist prevents arbitrary tool injection
local AllowedTools = {
	Sword = true,
	Pistol = true,
	Grenade = true
}

---------------------------------------------------------------------
-- SESSION STATE (NON-PERSISTENT)
-- Exists only while the player is online
---------------------------------------------------------------------

-- Authoritative in-memory cache
-- This is the source of truth during gameplay
local PlayerDataCache = {}

-- Active temporary effects (not saved)
local ActiveBuffs = {}

-- Internal analytics for balancing and debugging
-- Never used for gameplay logic
local Analytics = {
	TotalPurchases = 0,
	TotalDaily = 0,
	TotalMoneyGiven = 0
}

---------------------------------------------------------------------
-- DATA INITIALIZATION
-- Guarantees structural integrity of player data
---------------------------------------------------------------------

local function defaultPlayerData()
	return {
		Money = 0,
		Inventory = {},
		Loadouts = {},
		Quests = {},
		Achievements = {},
		LastDaily = 0,
		Analytics = {
			Purchases = 0,
			MoneyEarned = 0
		}
	}
end

---------------------------------------------------------------------
-- DATA PERSISTENCE
-- Defensive saving with retries to survive throttling or outages
---------------------------------------------------------------------

local function savePlayerData(userId)
	local data = PlayerDataCache[userId]
	if not data then return end

	for _ = 1, SAVE_RETRIES do
		local success = pcall(function()
			PlayerStore:SetAsync(tostring(userId), data)
		end)
		if success then return end
		task.wait(0.25)
	end
end

local function loadPlayerData(userId)
	local success, data = pcall(function()
		return PlayerStore:GetAsync(tostring(userId))
	end)
	if success and type(data) == "table" then
		return data
	end
	return nil
end

local function ensurePlayerData(player)
	local stored = loadPlayerData(player.UserId)
	PlayerDataCache[player.UserId] = stored or defaultPlayerData()
	return PlayerDataCache[player.UserId]
end

---------------------------------------------------------------------
-- ECONOMY LOGIC
-- All currency changes flow through controlled functions
---------------------------------------------------------------------

-- Normalizes incoming numbers and enforces safety limits
local function sanitizeAmount(amount)
	amount = tonumber(amount) or 0
	if amount < 0 then amount = 0 end
	if amount > MAX_TRANSACTION then amount = MAX_TRANSACTION end
	return math.floor(amount)
end

-- Adds money after validation and tracking
local function playerMoney(player, amount, reason)
	amount = sanitizeAmount(amount)
	if amount <= 0 then return false end

	local data = PlayerDataCache[player.UserId]
	if not data then return false end

	data.Money += amount
	data.Analytics.MoneyEarned += amount
	Analytics.TotalMoneyGiven += amount

	return true
end

-- Removes money only if balance allows it
local function deductMoney(player, amount)
	amount = sanitizeAmount(amount)
	local data = PlayerDataCache[player.UserId]
	if not data or data.Money < amount then return false end
	data.Money -= amount
	return true
end

---------------------------------------------------------------------
-- INVENTORY MANAGEMENT
-- Ownership is tracked logically, tools are spawned physically
---------------------------------------------------------------------

local function addToInventory(player, itemName)
	local data = PlayerDataCache[player.UserId]
	if not data or not Shop[itemName] then return false end

	-- Prevent duplicate tool ownership
	if Shop[itemName].type == "tool" and table.find(data.Inventory, itemName) then
		return false
	end

	table.insert(data.Inventory, itemName)
	return true
end

local function ownsItem(player, itemName)
	local data = PlayerDataCache[player.UserId]
	return data and table.find(data.Inventory, itemName) ~= nil
end

local function giveToolInstance(player, toolName)
	local template = ReplicatedStorage:FindFirstChild(toolName)
	if not template then return false end
	template:Clone().Parent = player.Backpack
	return true
end

---------------------------------------------------------------------
-- SHOP / PURCHASE FLOW
-- Server validates price, ownership, and balance
---------------------------------------------------------------------

local function buyItem(player, itemName)
	local data = PlayerDataCache[player.UserId]
	local item = Shop[itemName]
	if not data or not item then return false end
	if data.Money < item.price then return false end
	if item.type == "tool" and ownsItem(player, itemName) then return false end

	deductMoney(player, item.price)
	addToInventory(player, itemName)

	data.Analytics.Purchases += 1
	Analytics.TotalPurchases += 1

	if item.type == "tool" then
		giveToolInstance(player, itemName)
	end

	return true
end

---------------------------------------------------------------------
-- LOADOUT SYSTEM
-- Only owned and explicitly allowed tools may be equipped
---------------------------------------------------------------------

local function saveLoadout(player, slot, tools)
	local data = PlayerDataCache[player.UserId]
	if not data or slot < 1 or slot > MAX_LOADOUT_SLOTS then return false end

	local clean = {}
	for _, name in ipairs(tools) do
		if AllowedTools[name] and ownsItem(player, name) then
			table.insert(clean, name)
		end
	end

	data.Loadouts[slot] = clean
	return true
end

local function equipLoadout(player, slot)
	local data = PlayerDataCache[player.UserId]
	local loadout = data and data.Loadouts[slot]
	if not loadout then return false end

	for _, toolName in ipairs(loadout) do
		giveToolInstance(player, toolName)
	end
	return true
end

---------------------------------------------------------------------
-- DAILY REWARD
-- Time-gated reward enforced strictly server-side
---------------------------------------------------------------------

local function claimDaily(player)
	local data = PlayerDataCache[player.UserId]
	local now = os.time()

	-- 24 hour cooldown, cannot be bypassed by rejoining
	if now - data.LastDaily >= 86400 then
		playerMoney(player, DAILY_REWARD, "daily")
		data.LastDaily = now
		Analytics.TotalDaily += 1
		return true
	end

	return false
end

---------------------------------------------------------------------
-- REMOTE EVENT HANDLER
-- Single validated request router
---------------------------------------------------------------------

event.OnServerEvent:Connect(function(player, action, payload)
	if action == "BuyItem" then buyItem(player, payload) end
	if action == "SaveLoadout" then saveLoadout(player, payload.slot, payload.tools) end
	if action == "EquipLoadout" then equipLoadout(player, payload) end
	if action == "ClaimDaily" then claimDaily(player) end
	if action == "PlayerMoney" then playerMoney(player, payload, "manual") end
end)

---------------------------------------------------------------------
-- PLAYER LIFECYCLE
-- Session bootstrap and teardown
---------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player)
	local data = ensurePlayerData(player)

	-- Ensure loadout slots always exist
	for i = 1, MAX_LOADOUT_SLOTS do
		data.Loadouts[i] = data.Loadouts[i] or {}
	end

	-- Grant starter item to new players
	if #data.Inventory == 0 then
		addToInventory(player, DEFAULT_TOOL)
	end

	-- Rebuild inventory safely
	for _, item in ipairs(data.Inventory) do
		if Shop[item] and Shop[item].type == "tool" then
			giveToolInstance(player, item)
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	savePlayerData(player.UserId)
	PlayerDataCache[player.UserId] = nil
end)

---------------------------------------------------------------------
-- AUTOSAVE LOOP
-- Periodic persistence to reduce data loss risk
---------------------------------------------------------------------

task.spawn(function()
	while true do
		task.wait(AUTO_SAVE_INTERVAL)
		for _, player in ipairs(Players:GetPlayers()) do
			savePlayerData(player.UserId)
		end
	end
end)
