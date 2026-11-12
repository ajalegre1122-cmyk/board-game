--[[
	RemoteRiders (client): shows the OTHER riders' board animations on your screen while those animations are still
	Studio saves.

	Why: Roblox only shows a player's animations to the other players when they're published animation assets. Then
	each rider's own client plays them and Roblox shows them to everyone automatically, and this module leaves those
	poses alone. The board poses are still KeyframeSequences saved in BoardAssets.Rigs, which only the client that
	loads them can see, so until they're published each client plays the other riders' poses itself. It works them
	out from how each board moves (speed, turning, in the air, jumps, landings), which every client can already see.
	Nothing is sent over the network for this, so there's nothing for an exploiter to send.

	Publish the board animations and put the ids in Config.AnimationIds, and this turns itself off.

	API
	  RemoteRiders.new()
	  remoteRiders:Update(dt)   every frame
]]

local Players = game:GetService("Players")

local Config = require(script.Parent:WaitForChild("Config"))
local Animator = require(script.Parent:WaitForChild("Animator"))

local RemoteRiders = {}
RemoteRiders.__index = RemoteRiders

local JUMP_KICK = 20 -- a jump: a sudden kick upward of at least this much (studs/s) in one frame, on or just off the snow...
local JUMP_GAIN = 5 -- ...that also makes them faster overall (a ramp lip only turns them upward, it doesn't add speed)

local function damp(a, b, rate, dt)
	return a + (b - a) * (1 - math.exp(-rate * dt))
end

local function flat(v)
	local f = Vector3.new(v.X, 0, v.Z)
	return f.Magnitude > 1e-3 and f.Unit or nil
end

function RemoteRiders.new()
	local self = setmetatable({}, RemoteRiders)
	self.Riders = {} -- player -> what we know about their rider
	self.Enabled = Animator.NeedsLocalPlayback()
	if not self.Enabled then
		return self -- everything's published: Roblox shows everyone's poses already
	end
	self.RayParams = RaycastParams.new()
	self.RayParams.FilterType = Enum.RaycastFilterType.Exclude
	self.RayParams.IgnoreWater = true
	self.RayParams.RespectCanCollide = true
	local function watch(player)
		if player == Players.LocalPlayer then
			return
		end
		player.CharacterAdded:Connect(function(character)
			self:Track(player, character)
		end)
		player.CharacterRemoving:Connect(function()
			self:Untrack(player)
		end)
		if player.Character then
			self:Track(player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(player)
		self:Untrack(player)
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		watch(player)
	end
	return self
end

function RemoteRiders:Track(player, character)
	self:Untrack(player)
	local rider = {}
	self.Riders[player] = rider
	task.spawn(function()
		local root = character:WaitForChild("HumanoidRootPart", 10)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if not (root and humanoid) or self.Riders[player] ~= rider or not character.Parent then
			return
		end
		local proxy = { -- looks like a board Controller to the Animator
			Grounded = true, AirTime = 0, Steer = 0, Speed = 0,
			Jumped = Instance.new("BindableEvent"), Landed = Instance.new("BindableEvent"),
		}
		local ok, animator = pcall(Animator.new, character, proxy, nil, { RemoteOnly = true })
		if not ok then
			warn("[RemoteRiders] " .. tostring(animator))
			proxy.Jumped:Destroy()
			proxy.Landed:Destroy()
			return
		end
		if self.Riders[player] ~= rider then -- left / respawned while loading
			animator:Destroy()
			proxy.Jumped:Destroy()
			proxy.Landed:Destroy()
			return
		end
		rider.Character = character
		rider.Root = root
		rider.Proxy = proxy
		rider.Animator = animator
		rider.Look = flat(root.CFrame.LookVector) or Vector3.zAxis
		rider.LastVy = 0
		rider.YawRate = 0
	end)
end

function RemoteRiders:Untrack(player)
	local rider = self.Riders[player]
	if not rider then
		return
	end
	self.Riders[player] = nil
	if rider.Animator then
		rider.Animator:Destroy()
	end
	if rider.Proxy then
		rider.Proxy.Jumped:Destroy()
		rider.Proxy.Landed:Destroy()
	end
end

-- someone's Za Warudo froze these characters for `duration` seconds: their poses stay exactly as they are until then
function RemoteRiders:Freeze(characters, duration)
	self.FrozenUntil = self.FrozenUntil or setmetatable({}, { __mode = "k" })
	for _, character in ipairs(characters) do
		self.FrozenUntil[character] = math.max(self.FrozenUntil[character] or 0, os.clock() + duration)
	end
end

function RemoteRiders:Update(dt)
	if not self.Enabled or dt <= 0 then
		return
	end
	dt = math.min(dt, 1 / 20)
	local now = os.clock()
	for player, rider in pairs(self.Riders) do
		if rider.Root then
			local frozen = self.FrozenUntil and rider.Character and now < (self.FrozenUntil[rider.Character] or 0)
			if frozen then
				continue -- held in their pose (AbilityVFX pauses it) until time moves again
			end
			if rider.Root.Parent then
				self:Step(rider, dt)
			else
				self:Untrack(player)
			end
		end
	end
end

-- one rider: read how their board is moving, and pose them to match (same rules as your own Animator)
function RemoteRiders:Step(rider, dt)
	local root, p = rider.Root, rider.Proxy
	local v = root.AssemblyLinearVelocity
	-- on the snow? (same reach as the board's own ground check)
	self.RayParams.FilterDescendantsInstances = { rider.Character, workspace.CurrentCamera }
	local reach = Config.HoverHeight + Config.SnapDistance + 1.5
	local grounded = workspace:Raycast(root.Position, Vector3.new(0, -reach, 0), self.RayParams) ~= nil
	local now = os.clock()
	local kick = v.Y - rider.LastVy > JUMP_KICK and v.Magnitude - (rider.LastSpeed or 0) > JUMP_GAIN
	if kick and p.AirTime < 0.2 and now - (rider.JumpedAt or 0) > 0.5 then
		rider.JumpedAt = now
		p.Jumped:Fire()
	elseif grounded and not p.Grounded and p.AirTime > 0.25 then
		p.Landed:Fire(math.clamp(-rider.LastVy / 90, 0, 1))
	end
	p.AirTime = grounded and 0 or p.AirTime + dt
	p.Grounded = grounded
	rider.LastVy = v.Y
	rider.LastSpeed = v.Magnitude
	-- turning: how fast the board's heading swings, as a share of how fast a board can turn at this speed (= steer)
	local look = flat(root.CFrame.LookVector) or rider.Look
	local turned = math.atan2(rider.Look:Cross(look).Y, rider.Look:Dot(look))
	rider.Look = look
	rider.YawRate = damp(rider.YawRate, turned / dt, 8, dt)
	local speed = v.Magnitude
	local speedT = math.clamp(speed / Config.TurnSpeedRef, 0, 1)
	local turnRate = Config.TurnRateSlow + (Config.TurnRateFast - Config.TurnRateSlow) * speedT
	p.Steer = math.clamp(-rider.YawRate / math.max(turnRate, 0.01), -1, 1)
	p.Speed = speed
	rider.Animator:Update(p)
end

return RemoteRiders
