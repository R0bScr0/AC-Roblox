-- Advanced_Roblox_AC_Module
-- Structure:
-- ReplicatedStorage/
--   ACModule (ModuleScript)
--   AC_Remotes (Folder) -> contains RemoteEvents created by AC
-- ServerScriptService/
--   AC_Server (Script)
-- StarterPlayerScripts/
--   AC_Client (LocalScript)
--
-- Installation:
-- 1) Place ACModule (this file's module code) into ReplicatedStorage.ACModule
-- 2) Add a Script to ServerScriptService named "AC_Server" that requires the module and starts the checks
-- 3) Add LocalScript to StarterPlayerScripts named "AC_Client"
-- 4) Tweak config inside the module to match game physics and allowed behaviour
--
-- Notes:
-- * This code is defensive only. It does not include anything that would help bypass protections.
-- * No client-side secret is trusted. All authoritative decisions are server-side.
-- * Client telemetry is used to improve detection sensitivity and reduce false positives, but server checks don't rely on client-signed secrets.
--
-- ==========================
-- ACModule (ModuleScript) - put in ReplicatedStorage.ACModule
-- ==========================
local AC = {}
AC.__index = AC

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

-- Folder to store AC-associated remotes
local REMOTE_FOLDER_NAME = "AC_Remotes"
local remoteFolder = ReplicatedStorage:FindFirstChild(REMOTE_FOLDER_NAME) or Instance.new("Folder", ReplicatedStorage)
remoteFolder.Name = REMOTE_FOLDER_NAME

-- Configuration (tweak per-game)
AC.Config = {
	MaxWalkSpeed = 24,            -- allowed WalkSpeed
	MaxJumpPower = 62,           -- allowed JumpPower
	MaxTeleportDistance = 40,    -- maximum distance allowed in a single second
	MovementSampleRate = 0.25,   -- seconds between movement validation checks per-player
	ClientHeartbeatInterval = 1, -- seconds client should send heartbeat
	ClientTimeout = 5,           -- seconds without heartbeat => suspect
	MaxAcceleration = 115,       -- arbitrary accel threshold (studs/s^2)
	AllowedVelocityError = 6,    -- allowed error between server calc and observed
	MaxRemoteRatePerSecond = 8,  -- default allowed remote calls per second per event
	BanThresholdScore = 1,       -- detection score to auto-ban
}

-- Internal state tables
local state = {
	players = {}, -- player -> state table
	remotes = {}, -- remoteName -> config
}

-- Utility functions
local function now()
	return tick()
end

local function safeIndex(t, k)
	if not t then return nil end
	return t[k]
end

local function makePlayerState(player)
	return {
		lastPos = nil,
		lastPosTime = nil,
		lastVelocity = Vector3.new(0,0,0),
		lastVelocityTime = nil,
		lastHeartbeat = now(),
		movementScore = 0,
		detections = {}, -- { {time, reason} }
		remoteCounters = {}, -- remoteName -> {count, windowStart}
		lastSanityCheck = now(),
		banned = false,
	}
end

-- Logging (replace with DataStore/HttpService logging as needed)
local function log(player, level, msg)
	local name = player and player.Name or "Server"
	print(string.format("[AC][%s][%s] %s", level, name, msg))
end

local function addDetection(player, reason, weight)
	local pstate = state.players[player]
	if not pstate then return end
	weight = weight or 1
	table.insert(pstate.detections, {time = now(), reason = reason, weight = weight})
	pstate.movementScore = pstate.movementScore + weight
	log(player, "DETECT", reason .. " (score +" .. tostring(weight) .. ")")
end

-- Movement validator (server authoritative checks)
function AC:_validateMovement(player, character)
	local pstate = state.players[player]
	if not pstate then return true end
	if not character then return true end

	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChild("Humanoid")
	if not root or not humanoid then return true end

	-- Ignore movement checks if the player is in FreeFall
	if humanoid:GetState() == Enum.HumanoidStateType.Freefall then
		local t = now()
		local pos = root.Position
		pstate.lastPos = pos
		pstate.lastPosTime = t
		pstate.lastVelocity = Vector3.new(0,0,0)
		pstate.lastVelocityTime = t
		return true
	end

	local pos = root.Position
	local t = now()

	if pstate.lastPos and pstate.lastPosTime then
		local dt = t - pstate.lastPosTime
		if dt > 0 then
			local distance = (pos - pstate.lastPos).Magnitude
			local speed = distance / dt

			-- Teleport / speed checks
			if speed > (self.Config.MaxTeleportDistance / math.max(dt, 0.001)) + 1 then
				addDetection(player, "Impossible speed/teleport: " .. string.format("%.2f studs/s", speed), 2)
			end

			-- WalkSpeed sanity
			local expectedSpeed = humanoid.WalkSpeed
			if expectedSpeed and expectedSpeed > self.Config.MaxWalkSpeed * 1.1 then
				addDetection(player, "WalkSpeed out of allowed range: " .. tostring(expectedSpeed), 2)
			end

			-- acceleration sanity (horizontal only)
			local vel = (pos - pstate.lastPos) / math.max(dt, 0.0001)

			local horizVel = Vector3.new(vel.X, 0, vel.Z)
			local horizLast = Vector3.new(
				pstate.lastVelocity.X,
				0,
				pstate.lastVelocity.Z
			)

			local accel = (horizVel - horizLast).Magnitude / math.max(dt, 0.0001)

			if accel > self.Config.MaxAcceleration then
				addDetection(player, "High horizontal acceleration: " .. tostring(accel), 1.5)
			end

			pstate.lastVelocity = vel
			pstate.lastVelocityTime = t
		end
	end

	pstate.lastPos = pos
	pstate.lastPosTime = t
	return true
end


-- Property watchers
function AC:_watchCharacter(player, character)
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid then return end

	-- immediate property checks
	if humanoid.WalkSpeed > self.Config.MaxWalkSpeed then
		addDetection(player, "WalkSpeed modified on spawn: " .. tostring(humanoid.WalkSpeed), 2)
	end
	if humanoid.JumpPower and humanoid.JumpPower > self.Config.MaxJumpPower then
		addDetection(player, "JumpPower modified on spawn: " .. tostring(humanoid.JumpPower), 2)
	end

	-- watch changes
	humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
		if humanoid.WalkSpeed > self.Config.MaxWalkSpeed then
			addDetection(player, "WalkSpeed changed: " .. tostring(humanoid.WalkSpeed), 2)
		end
	end)

	humanoid:GetPropertyChangedSignal("JumpPower"):Connect(function()
		if humanoid.JumpPower and humanoid.JumpPower > self.Config.MaxJumpPower then
			addDetection(player, "JumpPower changed: " .. tostring(humanoid.JumpPower), 2)
		end
	end)
end


-- Remote wrapping & validation
-- Usage: AC:RegisterRemote("FireAction", {rateLimit = 5, validate = function(player, args) return true, reason end}, handler)
function AC:RegisterRemote(remoteName, cfg, handler)
	assert(type(remoteName) == "string")
	cfg = cfg or {}
	cfg.rateLimit = cfg.rateLimit or self.Config.MaxRemoteRatePerSecond
	cfg.validate = cfg.validate or function() return true end

	state.remotes[remoteName] = cfg

	-- create or reuse RemoteEvent
	local ev = remoteFolder:FindFirstChild(remoteName)
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = remoteName
		ev.Parent = remoteFolder
	end

	ev.OnServerEvent:Connect(function(player, ...)
		if not Players:FindFirstChild(player.Name) then return end
		local pstate = state.players[player]
		if not pstate then return end

		-- rate-limit counting (sliding window simple)
		local rc = pstate.remoteCounters[remoteName]
		local t = now()
		if not rc or t - rc.windowStart > 1 then
			pstate.remoteCounters[remoteName] = {count = 0, windowStart = t}
			rc = pstate.remoteCounters[remoteName]
		end
		rc.count = rc.count + 1
		if rc.count > cfg.rateLimit then
			addDetection(player, "Remote rate limit exceeded: " .. remoteName, 1)
			return
		end

		-- basic validation (shape, types, short-circuit)
		local ok, reason = pcall(cfg.validate, player, {...})
		if not ok or ok == false then
			local r = reason or "Remote validation failed"
			addDetection(player, "Remote validation failed (" .. remoteName .. "): " .. tostring(r), 1.5)
			return
		end

		-- call handler in protected call
		local success, err = pcall(handler, player, ...)
		if not success then
			log(player, "ERROR", "Handler for " .. remoteName .. " error: " .. tostring(err))
		end
	end)
end

-- Challenge-response heartbeat system (non-cryptographic)
-- Server issues a challenge token occasionally and expects client to return certain telemetry quickly
function AC:_createHeartbeatRemote()
	local name = "AC_Heartbeat"
	local ev = remoteFolder:FindFirstChild(name)
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = name
		ev.Parent = remoteFolder
	end

	-- Create the AC_RequestKick RemoteEvent for client kick requests
	function AC:_createRequestKickRemote()
		local name = "AC_RequestKick"
		local ev = remoteFolder:FindFirstChild(name)
		if not ev then
			ev = Instance.new("RemoteEvent")
			ev.Name = name
			ev.Parent = remoteFolder
		end
	end


	ev.OnServerEvent:Connect(function(player, payload)
		local pstate = state.players[player]
		if not pstate then return end
		pstate.lastHeartbeat = now()

		if type(payload) ~= "table" or type(payload.ts) ~= "number" then
			addDetection(player, "Malformed payload", 1)
			return
		end

		local char = player.Character
		if not char or not char:FindFirstChild("HumanoidRootPart") then return end

		local root = char.HumanoidRootPart
		local serverPos = root.Position
		local serverVel = root.AssemblyLinearVelocity

		--print(player.Name .. " serverPos:", serverPos, "serverVel.Y:", serverVel.Y)

		-- Handle both array {x,y,z} AND object {x=1,y=2,z=3} formats
		local clientPos
		if payload.pos then
			if type(payload.pos) == "table" then
				if #payload.pos == 3 then
					clientPos = Vector3.new(payload.pos[1], payload.pos[2], payload.pos[3])
				elseif payload.pos.x then
					clientPos = Vector3.new(payload.pos.x, payload.pos.y, payload.pos.z)
				end
			end
		end

		if clientPos then
			local delta = (clientPos - serverPos).Magnitude
			--print(player.Name .. " delta:", delta, "clientPos:", clientPos)

			if delta > 25 then
				addDetection(player, "Position desync: " .. math.floor(delta), 1)
			end
		else
			print(player.Name .. " MISSING POS DATA!")
		end
	end)
end

-- Periodic sweeper to apply penalties if threshold crossed
function AC:_sweeper(dt)
	for _, player in ipairs(Players:GetPlayers()) do
		local pstate = state.players[player]
		if not pstate then
			state.players[player] = makePlayerState(player)
			pstate = state.players[player]
		end

		-- client heartbeat timeout
		if now() - (pstate.lastHeartbeat or 0) > self.Config.ClientTimeout then
			addDetection(player, "Client heartbeat timeout", 1)
		end

		-- escalate punishments
		if pstate.movementScore >= self.Config.BanThresholdScore and not pstate.banned then
			pstate.banned = true
			-- soft action first: log, freeze, then ban (configurable)
			log(player, "ACTION", "Auto-banning player due to detections (score=" .. tostring(pstate.movementScore) .. ")")
			-- you can replace the following kick with a ban system calling a DataStore of bans
			local success, err = pcall(function()
				player:Kick("You were kicked for suspecious activity")
			end)
			if not success then
				log(player, "ERROR", "Failed to kick: " .. tostring(err))
			end
		end
	end
end

-- Public init
function AC:Init()
	-- create heartbeat remote
	self:_createHeartbeatRemote()
	-- create request kick remote
	self:_createRequestKickRemote()
	-- players state initialisation
	Players.PlayerAdded:Connect(function(player)
		state.players[player] = makePlayerState(player)

		player.CharacterAdded:Connect(function(char)
			-- watch humanoid and start checks
			self:_watchCharacter(player, char)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		state.players[player] = nil
	end)

	-- periodic movement validation
	spawn(function()
		while true do
			local dt = self.Config.MovementSampleRate
			for _, player in ipairs(Players:GetPlayers()) do
				local pstate = state.players[player]
				if not pstate then
					state.players[player] = makePlayerState(player)
				end
				local char = player.Character
				if char then
					local s, err = pcall(function()
						self:_validateMovement(player, char)
					end)
					if not s then
						log(player, "ERROR", "Movement validation error: " .. tostring(err))
					end
				end
			end
			wait(dt)
		end
	end)

	-- sweeper
	spawn(function()
		while true do
			local t0 = now()
			local ok, err = pcall(function()
				self:_sweeper(1)
			end)
			if not ok then
				warn("AC sweeper error: ", err)
			end
			local elapsed = now() - t0
			wait(math.max(1 - elapsed, 0.2))
		end
	end)

	log(nil, "INFO", "AC Module initialized")
end

-- Convenience: helper to get RemoteEvent by name
function AC:GetRemote(remoteName)
	return remoteFolder:FindFirstChild(remoteName)
end

return AC
