local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local remoteFolder = ReplicatedStorage:WaitForChild("AC_Remotes")
local heartbeat = remoteFolder:WaitForChild("AC_Heartbeat")
local requestKick = remoteFolder:WaitForChild("AC_RequestKick")

local MAX_SILENCE = 5
local lastPing = {}

-- ==========================
-- HEARTBEAT VÉRIFIÉ
-- ==========================
heartbeat.OnServerEvent:Connect(function(player, telemetry)
	if type(telemetry) ~= "table" then
		player:Kick("AntiCheat: Invalid heartbeat")
		return
	end

	
	if telemetry.requestKickMissing == true then
		player:Kick("AntiCheat: AC_RequestKick was removed from the client")
		return
	end

	lastPing[player] = tick()
end)

-- ==========================
-- ALERTES ANTI-CHEAT
-- ==========================
requestKick.OnServerEvent:Connect(function(player, payload)
	if type(payload) ~= "table" then
		player:Kick("AntiCheat: Invalid payload")
		return
	end

	if payload.type == "ACAlert" then
		local reason = payload.reason or "AntiCheat triggered"
		if payload.value then
			reason ..= " (" .. tostring(payload.value) .. ")"
		end
		player:Kick(reason)
	end
end)

-- ==========================
-- CHECK BYPASS
-- ==========================
Players.PlayerAdded:Connect(function(player)
	lastPing[player] = tick()

	task.spawn(function()
		while player.Parent do
			task.wait(1)
			if tick() - lastPing[player] > MAX_SILENCE then
				player:Kick("AntiCheat bypass detected")
				break
			end
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	lastPing[player] = nil
end)

print("[AC][SERVER] AntiCheat server initialized")
