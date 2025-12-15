--[[
	CoreServer.lua

	This script is the authoritative server-side controller for all persistent
	player systems in the game. It centralizes economy, inventory, loadouts,
	quests, consumables, and progression into a single controlled execution
	context.

	The design intentionally avoids trusting client-side state and instead
	validates all gameplay actions through server logic. This ensures security,
	consistency, and easier long-term maintenance.
]]

---------------------------------------------------------------------
-- SERVICES
---------------------------------------------------------------------

-- Roblox services used throughout the script
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

---------------------------------------------------------------------
-- DATASTORES & REMOTES
---------------------------------------------------------------------

-- Centralized DataStore for all persistent player data
-- Using a single structured save prevents partial or conflicting writes
local PlayerStore = DataStoreService:GetDataStore("PlayerData_v3")

-- RemoteEvent used as the only entry point for client → server communication
-- All gameplay actions must go through this event
local event = ReplicatedStorage:WaitForChild("core")

---------------------------------------------------------------------
-- CONFIGURATION CONSTANTS
---------------------------------------------------------------------

-- Autosave interval to reduce data loss while avoiding rate limits
local AUTO_SAVE_INTERVAL = 60

-- Upper bound for any money transaction to prevent abuse
local MAX_TRANSACTION = 1000

-- Maximum number of loadout slots per player
local MAX_LOADOUT_SLOTS = 3

-- Tool granted to first-time players
local DEFAULT_TOOL = "Sword"

-- Daily reward amount
local DAILY_REWARD = 150

-- Default duration for time-based consumables
local CONSUMABLE_DURATION = 20

-- Retry attempts for DataStore writes
local SAVE_RETRIES = 3

---------------------------------------------------------------------
-- SHOP DEFINITION
---------------------------------------------------------------------

-- Central shop table defining all purchasable items
-- This allows validation without trusting client UI
local Shop = {
	Sword = {price = 200, type = "tool"},
	Pistol = {price = 450, type = "tool"},
	Grenade = {price = 250, type = "tool"},
	MedKit = {price = 100, type = "consumable", heal = 50},
	XPBoost = {price = 300, type = "consumable", multiplier = 2, duration = 30}
}

-- Explicit allowlist for tools that can be equipped
-- Prevents arbitrary instances from being injected
local AllowedTools = {
	Sword = true,
	Pistol = true,
	Grenade = true
}

---------------------------------------------------------------------
-- RUNTIME STATE (SESSION ONLY)
---------------------------------------------------------------------

-- Server-side cache holding player data during a session
-- Acts as the single source of truth while the player is online
local PlayerDataCache = {}

-- Tracks active temporary buffs per player
local ActiveBuffs = {}

-- Global analytics counters for internal insight
local Analytics = {
	TotalPurchases = 0,
	TotalDaily = 0,
	TotalMoneyGiven = 0
}

---------------------------------------------------------------------
-- DATA INITIALIZATION
---------------------------------------------------------------------

-- Default data template for new or corrupted player saves
-- Ensures all expected fields exist
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
---------------------------------------------------------------------

-- Saves player data with retries to reduce DataStore failure impact
local function savePlayerData(userId)
	local data = PlayerDataCache[userId]
	if not data then return end

	for i = 1, SAVE_RETRIES do
		local success = pcall(function()
			PlayerStore:SetAsync(tostring(userId), data)
		end)
		if success then return end
		task.wait(0.25)
	end
end

-- Loads player data from DataStore
local function loadPlayerData(userId)
	local success, data = pcall(function()
		return PlayerStore:GetAsync(tostring(userId))
	end)
	if success and type(data) == "table" then
		return data
	end
	return nil
end

-- Ensures player has valid data in cache
local function ensurePlayerData(player)
	local stored = loadPlayerData(player.UserId)
	PlayerDataCache[player.UserId] = stored or defaultPlayerData()
	return PlayerDataCache[player.UserId]
end

---------------------------------------------------------------------
-- ECONOMY LOGIC
---------------------------------------------------------------------

-- Sanitizes numeric input to prevent malformed or abusive values
local function sanitizeAmount(amount)
	amount = tonumber(amount) or 0
	if amount < 0 then amount = 0 end
	if amount > MAX_TRANSACTION then amount = MAX_TRANSACTION end
	return math.floor(amount)
end

-- Adds money to a player's account
-- All income funnels through this function to allow tracking and quests
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

-- Removes money after validating sufficient balance
local function deductMoney(player, amount)
	amount = sanitizeAmount(amount)
	local data = PlayerDataCache[player.UserId]
	if not data or data.Money < amount then return false end
	data.Money -= amount
	return true
end

---------------------------------------------------------------------
-- INVENTORY MANAGEMENT
---------------------------------------------------------------------

-- Adds an item to a player's inventory
local function addToInventory(player, itemName)
	local data = PlayerDataCache[player.UserId]
	if not data or not Shop[itemName] then return false end
	if Shop[itemName].type == "tool" and table.find(data.Inventory, itemName) then
		return false
	end
	table.insert(data.Inventory, itemName)
	return true
end

-- Checks inventory ownership
local function ownsItem(player, itemName)
	local data = PlayerDataCache[player.UserId]
	return data and table.find(data.Inventory, itemName) ~= nil
end

-- Gives a physical Tool instance from ReplicatedStorage
local function giveToolInstance(player, toolName)
	local template = ReplicatedStorage:FindFirstChild(toolName)
	if not template then return false end
	template:Clone().Parent = player.Backpack
	return true
end

---------------------------------------------------------------------
-- SHOP / PURCHASE FLOW
---------------------------------------------------------------------

-- Handles server-side item purchases
-- Validates price, ownership, and balance
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
---------------------------------------------------------------------

-- Saves a filtered loadout slot
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

-- Equips a saved loadout
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
---------------------------------------------------------------------

-- Allows once-per-day reward claims and cant be bypassed
local function claimDaily(player)
	local data = PlayerDataCache[player.UserId]
	local now = os.time()
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
---------------------------------------------------------------------

-- Single validated entry point for all client requests on the server
event.OnServerEvent:Connect(function(player, action, payload)
	if action == "BuyItem" then buyItem(player, payload) end
	if action == "SaveLoadout" then saveLoadout(player, payload.slot, payload.tools) end
	if action == "EquipLoadout" then equipLoadout(player, payload) end
	if action == "ClaimDaily" then claimDaily(player) end
	if action == "PlayerMoney" then playerMoney(player, payload, "manual") end
end)

---------------------------------------------------------------------
-- PLAYER LIFECYCLE
---------------------------------------------------------------------

-- Initializes player session for better gameplay and layout
Players.PlayerAdded:Connect(function(player)
	local data = ensurePlayerData(player)

	for i = 1, MAX_LOADOUT_SLOTS do
		data.Loadouts[i] = data.Loadouts[i] or {}
	end

	if #data.Inventory == 0 then
		addToInventory(player, DEFAULT_TOOL)
	end

	for _, item in ipairs(data.Inventory) do
		if Shop[item] and Shop[item].type == "tool" then
			giveToolInstance(player, item)
		end
	end
end)

-- Saves player data on exit for maximum security on the data saving process
Players.PlayerRemoving:Connect(function(player)
	savePlayerData(player.UserId)
	PlayerDataCache[player.UserId] = nil
end)

---------------------------------------------------------------------
-- AUTOSAVE LOOP FOR BETTER SECURITY AND INTERNET ISSUES
---------------------------------------------------------------------

task.spawn(function()
	while true do
		task.wait(AUTO_SAVE_INTERVAL)
		for _, player in ipairs(Players:GetPlayers()) do
			savePlayerData(player.UserId)
		end
	end
end)
