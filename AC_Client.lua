-- ==========================
-- AC_Client (LocalScript) - put in StarterPlayerScripts as AC_Client
-- Client collects telemetry and fires heartbeat remote regularly.
-- ==========================

if not game:IsLoaded() then
	wait(game:IsLoaded())
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Stats = game:GetService("Stats")

local player = Players.LocalPlayer
local remoteFolder = ReplicatedStorage:WaitForChild("AC_Remotes")
local heartbeat = remoteFolder:WaitForChild("AC_Heartbeat")
local requestKick = remoteFolder:WaitForChild("AC_RequestKick")
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")
local root = character:WaitForChild("HumanoidRootPart")
local torso = character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso")
local last = root.Position
local baseline = {}
local ALLOWED = {Freecam=true, TouchGui=true}
local posDist = (root.Position - last).Magnitude

-- Collecte des données du joueur
local function collectTelemetry()
	local char = player.Character
	if not char then return nil end
	local root = char:FindFirstChild("HumanoidRootPart")
	local humanoid = char:FindFirstChild("Humanoid")
	if not root or not humanoid then return nil end

	local pos = root.Position
	local vel = root.Velocity
	return {
		ts = tick(),
		pos = {x=pos.X, y=pos.Y, z=pos.Z},
		vel = {x=vel.X, y=vel.Y, z=vel.Z},
		ws = humanoid.WalkSpeed,
		jp = humanoid.JumpPower,
		hp = humanoid.Health,
		maxHp = humanoid.MaxHealth
	}
end

-- Heartbeat continue
spawn(function()
	while true do
		local tele = collectTelemetry()
		if tele then
			local payload = {
				type="Heartbeat",
				ts = tele.ts,
				ws = tele.ws,
				jp = tele.jp,
				hp = tele.hp,
				maxHp = tele.maxHp,
				pos = tele.pos
			}
			pcall(function()
				requestKick:FireServer(payload)
			end)
		end
		task.wait(1)
	end
end)

local function loopfct()
	task.spawn(function()
		while true do
			loopfct()
		end
	end)
end

-- Préparer baseline pour XRay detection
for _, v in ipairs(workspace:GetDescendants()) do
	if v:IsA("BasePart") and v.CanCollide then
		baseline[v] = {Transparency=v.Transparency, LTM=v.LocalTransparencyModifier}
	end
end


-- Heartbeat remote (1/sec)	
spawn(function()
	while true do
		local tele = collectTelemetry()
		if tele then
			pcall(function()
				heartbeat:FireServer(tele)
			end)
		end
		wait(1)
	end
end)



-- Vérifications côté client (envoie ACAlert au serveur)
task.spawn(function()
	while true do
		local tele = collectTelemetry()
		if not tele then task.wait(0.3) continue end

		-- WalkSpeed / JumpPower / Health / MaxHealth
		if humanoid.WalkSpeed ~= 16 or humanoid.JumpPower ~= 50 then
			requestKick:FireServer({type="ACAlert", reason="Spoof Detected", ws=humanoid.WalkSpeed, jp=humanoid.JumpPower})
			task.wait(0.3)
			loopfct()
		end

		if tele.ws > 16 then
			requestKick:FireServer({type="ACAlert", reason="WalkSpeed out of allowed range", value=tele.ws})
				loopfct()
			if tele.jp > 50 then
				requestKick:FireServer({type="ACAlert", reason="JumpPower out of allowed range", value=tele.jp})
				task.wait(0.3)
				loopfct()
			end
		end

		if tele.hp > 100 then
			requestKick:FireServer({type="ACAlert", reason="Suspicious Health", value=tele.hp})
				task.wait(0.3)
				loopfct()
			if tele.maxHp > 100 then
				requestKick:FireServer({type="ACAlert", reason="Suspicious MaxHealth", value=tele.maxHp})
				task.wait(0.3)
				loopfct()
			end
		end


		-- Infinite Jump
		humanoid.StateChanged:Connect(function(old,new)
			if (old==Enum.HumanoidStateType.Jumping and new==Enum.HumanoidStateType.Jumping) 
				or (old==Enum.HumanoidStateType.Freefall and new==Enum.HumanoidStateType.Jumping) then
				requestKick:FireServer({type="ACAlert", reason="Infinite Jump Detected"})
				task.wait(0.3)
				loopfct()
			end
		end)

		-- Noclip
		RunService.Heartbeat:Connect(function()
			local now = root.Position
			local delta = now - last
			local params = RaycastParams.new()
			params.FilterDescendantsInstances = {character}
			params.FilterType = Enum.RaycastFilterType.Exclude
			local hit = workspace:Raycast(last, delta, params)
			if hit and hit.Instance.CanCollide then
				requestKick:FireServer({type="ACAlert", reason="Noclip Detected"})
				task.wait(0.3)
				loopfct()
			end
			last = now
		end)


		for _, inst in ipairs(character:GetDescendants()) do
			if inst:IsA("BasePart") and inst.Name:find("Head") and inst.CanCollide == false then
				requestKick:FireServer({type="ACAlert", reason="Noclip Detected"})
				task.wait(0.3)
				loopfct()
			end
		end

		-- Fly detection
		if root:FindFirstChildWhichIsA("BodyVelocity") and humanoid.PlatformStand == true and humanoid.FloorMaterial == Enum.Material.Air then
			requestKick:FireServer({type="ACAlert", reason="Fly Detected", velY=root.AssemblyLinearVelocity.Y})
			task.wait(0.3)
			loopfct()
		end

		for _, inst in ipairs(character:GetDescendants()) do
			if inst:IsA("BasePart") and inst.Name:find("Head") and inst.Anchored == true and humanoid.PlatformStand == true and humanoid.FloorMaterial == Enum.Material.Air then
				requestKick:FireServer({type="ACAlert", reason="Cfly Detected"})
				task.wait(0.3)
				loopfct()
			end
		end
		-- Teleport Tool
		for _, plr in pairs(Players:GetPlayers()) do
			local backpack = plr:FindFirstChild("Backpack")
			if backpack and backpack:FindFirstChild("Teleport Tool") then
				requestKick:FireServer({type="ACAlert", reason="Teleport Tool Detected"})
				task.wait(0.3)
				loopfct()
			end
		end

		-- XRay / transparency hacks
		for part, data in pairs(baseline) do
			if part and part.Parent and not part:IsDescendantOf(player.Character) then
				if part.LocalTransparencyModifier > 0 and not part:IsA("Camera") then
					requestKick:FireServer({type="ACAlert", reason="XRay Detected"})
					task.wait(0.3)
					loopfct()
				end
			end
		end

		-- GUI interdite
		for _, gui in ipairs(player.PlayerGui:GetChildren()) do
			if gui:IsA("ScreenGui") and not ALLOWED[gui.Name]  then
				requestKick:FireServer({type="ACAlert", reason="Fobidden GUI Detected: "..gui.Name})
				task.wait(0.3)
				loopfct()
			end
		end

		for _, inst in ipairs(character:GetDescendants()) do
			if inst:IsA("BasePart") and inst.Size == Vector3.new(2, 0.2, 1.5) then
				requestKick:FireServer({type="ACAlert", reason="Floating Detected", distance=posDist})
				task.wait(0.3)
				loopfct()
			end
		end

		if root then
			if root:FindFirstChild("Spinning") then
				requestKick:FireServer({type="ACAlert", reason="Spin Detected"})
				task.wait(0.3)
				loopfct()
			end
		end

		root:GetPropertyChangedSignal("Velocity"):Connect(function()
			if root.Velocity.Magnitude >= 25 then
				requestKick:FireServer({type="ACAlert", reason="Velocity Detected", velY=root.AssemblyLinearVelocity.Y})
				task.wait(0.3)
				loopfct()
			end
		end)

		if humanoid:GetState() == Enum.HumanoidStateType.Swimming and humanoid.FloorMaterial == Enum.Material.Air then
			requestKick:FireServer({type="ACAlert", reason="Are u swimming on air???"})
				task.wait(0.3)
				loopfct()
		end

		root.ChildAdded:Connect(function(obj)
			if obj:IsA("BodyVelocity") or obj:IsA("BodyGyro") then
				requestKick:FireServer({type="ACAlert", reason="VFly Detected", velY=root.AssemblyLinearVelocity.Y})
				task.wait(0.3)
				loopfct()
			end
		end)

		for _, plr in pairs(Players:GetPlayers()) do
			local backpack = plr:FindFirstChild("Backpack")
			if backpack and backpack:FindFirstChild("Jerk Off") then
				requestKick:FireServer({type="ACAlert", reason="Nuh uh"})
				task.wait(0.3)
				loopfct()
			end
		end
		task.wait(0.3)
	end
end)

print("[AC][INFO][Server] AC Module initialized")
print("[AC_Client] Initialized for "..player.Name)
