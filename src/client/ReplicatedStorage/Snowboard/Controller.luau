--[[
	Controller (client): snowboard physics for the local rider.

	How it moves
	  - The board has a HEADING (where it points). Steering turns the heading: stiff when slow, quicker the
	    faster you go (like SKI), and it builds up/settles smoothly, so there are no instant 90/180 snaps.
	  - Gravity pulls you down the slope. The part of that pull along the board speeds you up; the
	    sideways part is mostly held by the board's edge.
	  - Your travel direction follows the heading at a limited rate (grip). Clean carves keep their speed;
	    only sharp hard cuts bleed a tiny bit (Config.HardCut) and real skids scrub some off.
	  - Air drag sets a natural top speed for each slope; tucking (W) lowers drag, braking (S) slows you.
	    Once rolling, the board holds at least Cruise.BaseSpeed on flats and gentle slopes (a bit more crouched).
	  - The board hovers at a fixed height over the snow and tilts to match it, so banked walls and
	    curves tilt you naturally; on top of that the rider leans by how hard they're carving.
	  - Ramps launch you: when the snow ends under you, you're airborne with whatever speed you had.
	    In the air A / D gently bend your flight path (the board turns with it); momentum carries forward.
	  - Like SKI, A / D turn you at most TurnLimit.MaxAngle (90) away from straight downhill, so you stop
	    sideways across the hill instead of turning round. Turning sideways brakes you; on a downhill you
	    slow to a crawl (Brake.DownhillMinSpeed) but never fully stop. Flat ground lets you stop.
	  - Riding UP a slope (side banks, curve walls, hills) is pure momentum: only gravity slows you, so the
	    faster you come in, the further up you go (Config.Uphill). No crawling up.
	  - Side walls in curves are the exception: reaching one gives a little boost instead (Config.WallBoost).
	  - White snow can be ridden right up steep sidewalls (to vertical) while you're fast (Config.WallRide);
	    too slow and you peel off. Anything that isn't snow is a border once it's steep (Config.Border):
	    you can't ride up it, you slide along it instead.

	API
	  Controller.new(character)
	  controller:Step(dt)                 call every frame before physics (RunService.PreSimulation)
	  controller:Boost(speed)             instant push along the board (boost pads, abilities)
	  controller:SuperJump(times)         Jump Boost: launches you straight up, `times` x as high as a normal jump
	  controller:SpeedBoost(mult, secs)   Speed Boost: ride `mult` x as fast for `secs` seconds
	  controller:Dash(extra, secs)        One For All Dash: a quick burst of `extra` speed for `secs` seconds
	  controller:ApplyHit(hit)            got hit (a Config.Hits entry): slowed, or stunned then slowed while recovering
	  controller:Respawn()
	  controller.Landed / controller.Jumped  BindableEvents (Landed passes the landing impact 0-1)
	Read-only state for camera/animation/effects:
	  Speed, Velocity, Heading, Normal, Grounded, Steer, Lean, Tuck, Brake, AirTime, DownhillDir, SpeedMult, Stunned
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local Config = require(script.Parent:WaitForChild("Config"))

local Controller = {}
Controller.__index = Controller

local UP = Vector3.yAxis
local BORDER_RAY_ANGLES = { 0, 35, -35, 80, -80 } -- degrees off the way you're going: ahead, ahead-sides, sides
local UPHILL_DOT = -0.17 -- board pointing more than ~100 degrees from the fall line = riding up the slope

local function damp(a, b, rate, dt)
	return a + (b - a) * (1 - math.exp(-rate * dt))

end

local function dampVector(a, b, rate, dt)
	return a:Lerp(b, 1 - math.exp(-rate * dt))
end

local function flatten(v, normal)
	return v - normal * v:Dot(normal)
end

local function safeUnit(v, fallback)
	local m = v.Magnitude
	if m < 1e-4 then
		return fallback
	end
	return v / m
end

local function rotateAround(v, axis, angle)
	return CFrame.fromAxisAngle(axis, angle):VectorToWorldSpace(v)
end

-- scales the part of v that runs along `basis`'s plane (along the snow, or flat in the air) by k;
-- the part along `basis` (into / out of the snow, or up / down) is kept
local function scaleAlong(v, basis, k)
	local normalPart = basis * v:Dot(basis)
	return (v - normalPart) * k + normalPart
end

local function smooth(t)
	return t * t * (3 - 2 * t)
end

-- degrees from flat (0 = flat ground, 90 = vertical wall)
local function steepness(normal)
	return math.deg(math.acos(math.clamp(normal.Y, -1, 1)))
end

-- other riders aren't snow or walls
local function isCharacterPart(instance)
	local model = instance:FindFirstAncestorOfClass("Model")
	return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

-- what a ray hit: "snow" (white snow: rideable up sidewalls), "rideable" (boost ramps, parts tagged Rideable),
-- or "other" (rock, green ground, curbs...: rideable while gentle, a border once steep)
local function surfaceKind(result)
	local instance = result.Instance
	if instance:IsA("Terrain") then
		return Config.Snow.TerrainMaterials[result.Material.Name] and "snow" or "other"
	end
	if Config.Snow.PartMaterials[instance.Material.Name] or CollectionService:HasTag(instance, Config.Snow.Tag) then
		return "snow"
	end
	if CollectionService:HasTag(instance, "BoostPad") or CollectionService:HasTag(instance, Config.Border.RideableTag) then
		return "rideable"
	end
	return "other"
end

-- a steep surface that isn't snow: the edge of the track
local function isBorder(result)
	return Config.Border.Enabled
		and not isCharacterPart(result.Instance)
		and surfaceKind(result) == "other"
		and steepness(result.Normal) > Config.Border.Angle
end

-- gravity in the air right now, with a little glide (Config.Glide): once you've been up a moment, a short hang at
-- the top of the jump and a slightly slower fall. (A Jump Boost dive blends it out: see StepAir)
local function airGravity(vy, airTime)
	local g = Config.AirGravity
	local G = Config.Glide
	if not G or not G.Enabled or airTime < G.AfterAirTime then
		return g
	end
	if math.abs(vy) < G.ApexSpeed then
		return g * G.ApexGravityScale
	elseif vy < 0 then
		return g * G.FallGravityScale
	end
	return g
end

-- replays the air physics (same steps as StepAir, 60 fps) for a launch straight up at `vy`, moving forward at
-- `flatSpeed`: how high you get, and (fullFlight) how long until you're back down at the launch height.
-- `dragFree` = seconds with no air drag (right after a boost). Used to size Jump Boost.
local function simulateLaunch(vy, flatSpeed, fullFlight, dragFree)
	local dt = 1 / 60
	local y, top, t = 0, 0, 0
	local flat = flatSpeed
	while t < 30 do
		vy -= airGravity(vy, t) * dt
		if t >= (dragFree or 0) then
			local k = Config.Drag * math.sqrt(flat * flat + vy * vy) * dt
			flat *= 1 - math.min(1, Config.Drag * flat * dt * Config.AirForwardDrag)
			vy *= 1 - math.min(1, k)
		end
		y += vy * dt
		t += dt
		top = math.max(top, y)
		if vy <= 0 and (not fullFlight or y <= 0) then
			break
		end
	end
	return top, t
end

function Controller.new(character)
	local self = setmetatable({}, Controller)
	self.Character = character
	self.Humanoid = character:WaitForChild("Humanoid")
	self.Root = character:WaitForChild("HumanoidRootPart")
	self.Player = Players:GetPlayerFromCharacter(character)

	-- the humanoid stops driving the body; this controller does
	local humanoid = self.Humanoid
	humanoid.PlatformStand = true
	humanoid.AutoRotate = false
	for _, state in ipairs({
		Enum.HumanoidStateType.FallingDown, Enum.HumanoidStateType.Ragdoll, Enum.HumanoidStateType.GettingUp,
		Enum.HumanoidStateType.Jumping, Enum.HumanoidStateType.Climbing, Enum.HumanoidStateType.Swimming,
	}) do
		humanoid:SetStateEnabled(state, false)
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "SnowboardAlign"
	attachment.Parent = self.Root
	local align = Instance.new("AlignOrientation")
	align.Name = "SnowboardAlign"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.RigidityEnabled = false
	align.MaxTorque = math.huge
	align.MaxAngularVelocity = math.huge
	align.Responsiveness = Config.Responsiveness
	align.CFrame = self.Root.CFrame.Rotation
	align.Parent = self.Root
	self.Align = align

	-- cancel the engine's own gravity: this controller applies its own (Config.Gravity / AirGravity),
	-- otherwise workspace.Gravity gets added on top every frame and the rider runs away on steep snow
	local antiGravity = Instance.new("VectorForce")
	antiGravity.Name = "SnowboardAntiGravity"
	antiGravity.Attachment0 = attachment
	antiGravity.RelativeTo = Enum.ActuatorRelativeTo.World
	antiGravity.ApplyAtCenterOfMass = true
	antiGravity.Force = Vector3.zero
	antiGravity.Parent = self.Root
	self.AntiGravity = antiGravity

	self.RayParams = RaycastParams.new()
	self.RayParams.FilterType = Enum.RaycastFilterType.Exclude
	-- not your own body, and nothing under the camera (client-only visuals like ability effects aren't snow or walls)
	self.RayParams.FilterDescendantsInstances = { character, workspace.CurrentCamera }
	self.RayParams.IgnoreWater = true
	self.RayParams.RespectCanCollide = true -- wind zones, VFX parts etc. aren't snow

	local look = self.Root.CFrame.LookVector
	self.Heading = safeUnit(Vector3.new(look.X, 0, look.Z), -Vector3.zAxis)
	self.Normal = UP
	self.Velocity = Vector3.zero
	self.Speed = 0
	self.Grounded = false
	self.Steer = 0
	self.YawRate = 0
	self.Lean = 0
	self.Tuck = 0
	self.Brake = 0
	self.AirTime = 0
	self.LastGroundedAt = 0
	self.JumpedAt = -10
	self.JumpQueuedAt = -10
	self.Clock = 0
	self.SpawnCFrame = self.Root.CFrame
	self.SafePoints = {} -- recent spots on solid snow, for recovering after flying off the track
	self.LastSafeAt = -10
	self.DownhillDir = nil -- remembered "straight downhill" (flat), for the turn limit. nil until you reach a slope
	self.PeeledAt = -10 -- last time you peeled off a steep snow wall (too slow)
	self.OnBorder = false -- sliding along a border right now
	self.LastBorderAt = -10
	self.WallKickAt = -10 -- last sidewall boost kick
	self.WallArmed = true -- leave the wall before it can kick again
	self.OnWall = 0 -- 0-1, how much you're riding a side wall right now
	self.TakeoffSpeed = 0 -- speed when you last left the snow (a clean landing gives it back)
	self.SuperJumping = false -- in the air from a Jump Boost (cleared on landing)
	self.SuperJumpAirTime = 0 -- extra time allowed in the air for that jump
	self.Pitch = 0 -- nose-down tilt of the board (degrees): Jump Boost dive
	self.PitchTarget = 0
	self.Dive = 0 -- how far into a Jump Boost dive you are (0-1, eases in / out)
	self.DiveFlare = 1 -- 1 = high up, down to 0 just before the snow (the dive eases off: you swoop in)
	self.SpeedMult = 1 -- Speed Boost: how many times faster you're riding right now (1 = normal)
	self.SpeedBoostEndsAt = nil
	self.AppliedMult = 1 -- the multiplier applied when the rider last moved, and how (nil = all of it, UP = flat part only)
	self.AppliedBasis = nil
	self.AppliedExtra = Vector3.zero -- the dash burst (velocity) added when the rider last moved
	self.SpeedExtra = 0 -- One For All Dash: extra speed right now (studs/s)

	self.Landed = Instance.new("BindableEvent")
	self.Jumped = Instance.new("BindableEvent")
	self.RespawnedEvent = Instance.new("BindableEvent")
	self.Boosted = Instance.new("BindableEvent") -- passes "Pad" / "Ring" / other
	self.HitTaken = Instance.new("BindableEvent") -- passes the Config.Hits entry when you get hit (camera jolt...)
	self.HitState = nil -- slowed / stunned by a hit right now (ApplyHit)
	self.Stunned = false
	self.Frozen = false -- someone's Za Warudo stopped time for you (Freeze)
	self.FrozenUntil = nil
	self.BoostedAt = -10

	-- input
	self.Connections = {}

	-- no walking footsteps while on the board: Roblox's built-in character sounds (RbxCharacterSounds) keep
	-- starting the "Running" loop as the body moves, so mute those sounds until the board is removed
	self.MutedSounds = {}
	local function muteFootsteps(sound)
		if sound:IsA("Sound") and Config.MutedCharacterSounds[sound.Name] and not self.MutedSounds[sound] then
			self.MutedSounds[sound] = sound.Volume
			sound.Volume = 0
		end
	end
	for _, child in ipairs(self.Root:GetChildren()) do
		muteFootsteps(child)
	end
	table.insert(self.Connections, self.Root.ChildAdded:Connect(muteFootsteps)) -- the sounds can be created a moment after spawning
	table.insert(self.Connections, UserInputService.JumpRequest:Connect(function()
		self.JumpQueuedAt = self.Clock
	end))
	ContextActionService:BindAction("SnowboardReset", function(_, inputState)
		if inputState == Enum.UserInputState.Begin and not self:IsFrozen() then -- (no respawning out of Za Warudo)
			self:Respawn()
		end
		return Enum.ContextActionResult.Sink
	end, false, Config.ResetKey)

	local playerScripts = self.Player and self.Player:FindFirstChild("PlayerScripts")
	local ok, playerModule = pcall(function()
		return require(playerScripts:WaitForChild("PlayerModule", 5))
	end)
	self.Controls = ok and playerModule and playerModule:GetControls() or nil
	return self
end

-- steer: -1 left .. +1 right, throttle: +1 tuck/push (W), -1 brake (S)
function Controller:ReadInput()
	local steer, throttle = 0, 0
	if self.Controls then
		local move = self.Controls:GetMoveVector()
		steer, throttle = move.X, -move.Z
	else
		if UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left) then
			steer -= 1
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right) then
			steer += 1
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up) then
			throttle += 1
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down) then
			throttle -= 1
		end
	end
	if self.InputOverride then -- used by tests / cutscenes
		steer, throttle = self.InputOverride.Steer or 0, self.InputOverride.Throttle or 0
	end
	if self.Stunned then -- stunned (Rasen Shuriken...): no steering or pushing until it wears off
		steer, throttle = 0, 0
	end
	return math.clamp(steer, -1, 1), math.clamp(throttle, -1, 1)
end

-- steepest surface of each kind the board can ride (degrees from flat)
function Controller:MaxRideAngle(kind)
	local climbAngle = self.Climbing and Config.Climb.MaxAngle or 0 -- slowly climbing: crawl over short steep lips
	if kind == "snow" then
		return math.max(Config.WallRide.MaxAngle, climbAngle)
	elseif kind == "rideable" or not Config.Border.Enabled then
		return math.max(Config.MaxGroundAngle, climbAngle)
	end
	return Config.Border.Angle -- not snow: only while gentle, steeper is a border
end

-- casts 5 rays (center, nose, tail, both edges) and returns the averaged ground under the board
function Controller:ProbeGround(position, up)
	local heading = self.Heading
	local side = safeUnit(heading:Cross(up), Vector3.xAxis)
	local reach = Config.HoverHeight + Config.SnapDistance + 1.5
	local offsets = { Vector3.zero, heading * 2.4, -heading * 2.4, side * 1.1, -side * 1.1 }
	local normalSum = Vector3.zero
	local hits = 0
	local height
	local heightSum, heightCount = 0, 0
	local material
	local boostPad
	for i, offset in ipairs(offsets) do
		local origin = position + offset + up * 0.75
		local result = workspace:Raycast(origin, -up * (reach + 0.75), self.RayParams)
		if result and not isCharacterPart(result.Instance) and steepness(result.Normal) <= self:MaxRideAngle(surfaceKind(result)) then
			normalSum += result.Normal
			hits += 1
			local h = (position - result.Position):Dot(up)
			heightSum += h
			heightCount += 1
			if i == 1 then
				height = h
				material = result.Material
			end
			if not boostPad and CollectionService:HasTag(result.Instance, "BoostPad") then
				boostPad = result.Instance
			end
		end
	end
	if hits == 0 then
		return nil
	end
	return {
		Normal = safeUnit(normalSum, up),
		Height = height or heightSum / heightCount,
		Material = material,
		BoostPad = boostPad,
	}
end

-- speed burst along the way you're riding: you end up at least minSpeed, and at least `add` faster.
-- Speed above MaxSpeed bleeds off over the next second or so (Config.OverSpeedDecel).
-- `direction` (optional) aims the burst, e.g. through a ring. Used by boost pads, rings and abilities.
function Controller:Boost(add, minSpeed, direction, kind)
	local v = self.Root.AssemblyLinearVelocity
	local dir = direction or (v.Magnitude > 5 and v.Unit or self.Heading)
	local along = math.max(v:Dot(dir), 0)
	local target = math.max(along + (add or 0), minSpeed or 0)
	v = v - dir * v:Dot(dir) + dir * target
	if direction then
		local flat = Vector3.new(direction.X, 0, direction.Z)
		if flat.Magnitude > 0.1 then
			self.Heading = flat.Unit
		end
	end
	self.Root.AssemblyLinearVelocity = v
	if not self.Grounded then
		self.TakeoffSpeed = math.max(self.TakeoffSpeed, self:ToBase(v).Magnitude) -- boosted in the air (rings): land with that speed
	end
	self.BoostedAt = self.Clock
	self.Boosted:Fire(kind or "Boost")
end

-- Jump Boost (Deku): launches you straight up, `times` x as high as a normal jump would take you at your current
-- speed (air drag grows with speed, so the launch is worked out by replaying the air physics). Your speed along
-- the snow carries on through the jump and a clean landing gives it back. Works on the snow or in the air.
-- Returns how high it'll take you (studs).
function Controller:SuperJump(times)
	times = times or 10
	-- work in normal-speed terms (a Speed Boost / dash speeds up how fast the rider actually moves; see Step)
	local v = self:ToBase(self.Root.AssemblyLinearVelocity)
	local along = self.Grounded and flatten(v, self.Normal) or v -- on the snow: just the part along the snow
	local flat = Vector3.new(along.X, 0, along.Z)
	local flatSpeed = flat.Magnitude
	local dragFree = math.max(0, Config.Boost.AirDragFreeTime - (self.Clock - self.BoostedAt))
	-- how high a normal jump on flat snow goes at this speed, x times
	local jumpVy = Config.JumpSpeed * 1.2
	local goal = (simulateLaunch(jumpVy, flatSpeed) + jumpVy / 60) * times -- (a normal jump rises a frame before gravity kicks in)
	local low, high = 0, 4000
	for _ = 1, 32 do
		local mid = (low + high) / 2
		if simulateLaunch(mid, flatSpeed, false, dragFree) < goal then
			low = mid
		else
			high = mid
		end
	end
	local vy = math.max(high, along.Y)
	local _, hangTime = simulateLaunch(vy, flatSpeed, true, dragFree)
	if self.Grounded then
		self.TakeoffSpeed = along.Magnitude
	else
		self.TakeoffSpeed = math.max(self.TakeoffSpeed or 0, flatSpeed)
	end
	self.Root.AssemblyLinearVelocity = self:ToActual(Vector3.new(flat.X, vy, flat.Z))
	self.JumpedAt = self.Clock -- no snapping back onto the snow (and no normal jump straight after)
	self.JumpQueuedAt = -10
	self.Grounded = false
	self.SuperJumping = true
	self.SuperJumpAirTime = self.AirTime + hangTime -- the "flew off the track" timer allows for the whole flight
	return goal
end

-- Speed Boost (Deku's ultimate): for `duration` seconds you ride `multiplier` x as fast as you otherwise would.
-- The board physics keeps running at normal speed underneath and only your movement along the snow is scaled up,
-- so carving, braking, slopes and walls all work as usual, just faster. Jumps go further, not higher (the up / down
-- part isn't scaled). Eases in and back out (Config.SpeedBoost).
function Controller:SpeedBoost(multiplier, duration)
	self.SpeedBoostFrom = self.SpeedMult -- using it again mid-boost carries on from the current speed
	self.SpeedBoostTarget = math.max(multiplier or 2, 0.1)
	self.SpeedBoostStartedAt = self.Clock
	self.SpeedBoostEndsAt = self.Clock + (duration or 7)
	self.Boosted:Fire("SpeedBoost") -- FOV kick + speed lines burst
end

-- put the rider somewhere else, keeping their speed and heading (Boogie Woogie swaps: the server says where)
function Controller:Teleport(cf)
	local v = self.Root.AssemblyLinearVelocity
	self.Root.CFrame = cf
	self.Root.AssemblyLinearVelocity = v
	self.LastSafeAt = self.Clock
end

-- end a Speed Boost early (Chidori hit someone): it eases back to normal over Config.SpeedBoost.FadeOut
function Controller:EndSpeedBoost()
	if self.SpeedBoostEndsAt and self.Clock < self.SpeedBoostEndsAt then
		self.SpeedBoostEndsAt = self.Clock
	end
end

-- One For All Dash (Deku): a quick burst of `extra` speed (studs/s) in the way you're going, held for `holdTime`
-- seconds, then it fades back to your normal speed (Config.Dash). Like the Speed Boost it's added on top of the
-- physics (which carries on at your normal speed underneath), so the burst doesn't linger and stacks with a boost.
function Controller:Dash(extra, holdTime, rampIn, fadeOut, uncapped)
	self.DashFrom = self.SpeedExtra or 0 -- dashing again mid-dash carries on from the current burst
	self.DashTarget = math.max(extra or 70, 0)
	self.DashStartedAt = self.Clock
	self.DashEndsAt = self.Clock + (holdTime or 0.3)
	self.DashRampIn = rampIn -- (nil = Config.Dash) Time Skip snaps in and out much quicker than One For All Dash
	self.DashFadeOut = fadeOut
	self.DashUncapped = uncapped == true -- Time Skip's blink: not held to Config.SpeedBoost.MaxSpeed (CapBoost)
	self.Boosted:Fire("Dash") -- FOV kick + speed lines burst
end

-- Za Warudo (someone else's): time stops for you for `duration` seconds. You're held exactly where you are, can't
-- steer, jump, respawn or use abilities, and your own timers (boosts, stuns...) pause too. When time moves again you
-- carry on exactly as you were going: same speed, same direction
function Controller:Freeze(duration)
	local now = os.clock()
	if not self:IsFrozen() then
		self.FrozenCFrame = self.Root.CFrame
		self.FrozenVelocity = self.Root.AssemblyLinearVelocity
	end
	self.FrozenUntil = math.max(self.FrozenUntil or 0, now + (duration or 5))
	self.Frozen = true
end

function Controller:IsFrozen()
	return self.FrozenUntil ~= nil and os.clock() < self.FrozenUntil
end

-- got hit by an ability (the server decided: AbilityServer). `hit` is its Config.Hits entry: stunned for StunTime
-- (nearly stopped, can't steer, jump or use abilities), then slowed to SlowMultiplier for SlowTime, then back up to
-- full speed over RecoverTime (from RecoverFrom). Like the Speed Boost it scales how fast you actually move, so
-- your own speed is all still there when it wears off.
function Controller:ApplyHit(hit)
	self.HitState = {
		Started = self.Clock,
		Stun = hit.StunTime or 0,
		StunMult = hit.StunMultiplier or 0.1,
		Slow = hit.SlowTime or 0,
		SlowMult = hit.SlowMultiplier or 1,
		Recover = hit.RecoverTime or 0,
		From = hit.RecoverFrom or hit.SlowMultiplier or hit.StunMultiplier or 1,
	}
	self.HitTaken:Fire(hit)
end

-- this frame's Speed Boost multiplier (1 = none) and dash burst (studs/s, 0 = none)
function Controller:UpdateSpeedBoost()
	local mult = 1
	local endsAt = self.SpeedBoostEndsAt
	if endsAt then
		local S = Config.SpeedBoost
		local target = self.SpeedBoostTarget
		if self.Clock < endsAt then
			local t = math.clamp((self.Clock - self.SpeedBoostStartedAt) / math.max(S.RampIn, 1e-3), 0, 1)
			mult = self.SpeedBoostFrom + (target - self.SpeedBoostFrom) * smooth(t)
		else
			local t = (self.Clock - endsAt) / math.max(S.FadeOut, 1e-3)
			if t >= 1 then
				self.SpeedBoostEndsAt = nil
			else
				mult = target + (1 - target) * smooth(t)
			end
		end
	end
	local extra = 0
	local dashEnds = self.DashEndsAt
	if dashEnds then
		local D = Config.Dash
		if self.Clock < dashEnds then
			local t = math.clamp((self.Clock - self.DashStartedAt) / math.max(self.DashRampIn or D.RampIn, 1e-3), 0, 1)
			extra = self.DashFrom + (self.DashTarget - self.DashFrom) * smooth(t)
		else
			local t = (self.Clock - dashEnds) / math.max(self.DashFadeOut or D.FadeOut, 1e-3)
			if t >= 1 then
				self.DashEndsAt = nil
			else
				extra = self.DashTarget * (1 - smooth(t))
			end
		end
	end
	-- got hit (ApplyHit): stunned (nearly stopped, no steering / jumping / abilities), slowed, then back up to speed
	local hitMult = 1
	local h = self.HitState
	self.Stunned = false
	if h then
		local t = self.Clock - h.Started
		if t < h.Stun then
			hitMult = h.StunMult
			self.Stunned = true
			extra = 0 -- no dashing out of a stun
		elseif t < h.Stun + h.Slow then
			hitMult = h.SlowMult
		elseif t < h.Stun + h.Slow + h.Recover then
			local k = (t - h.Stun - h.Slow) / math.max(h.Recover, 1e-3)
			hitMult = h.From + (1 - h.From) * smooth(k)
		else
			self.HitState = nil
		end
	end
	mult *= hitMult
	self.SpeedMult = mult
	self.SpeedExtra = extra
	return mult, extra
end

-- speed from abilities never stacks (Config.SpeedBoost.NoStacking): a speed boost can't take you past its own multiplier
-- x your normal top speed (Deku's 2x Speed Boost: 200), a dash on its own past top speed + the dash. Boost pads, slopes
-- and a dash on top of a boost add nothing beyond that (2x a boost pad + the dash used to reach 250+). Only the boosted
-- part is trimmed (the multiplier, then the dash), so slopes and pads on their own work as before, and a slow / stun is
-- never touched. Time Skip's blink (an uncapped dash) still goes on top.
-- `v` = this frame's normal-speed velocity. Returns the multiplier and dash to actually use this frame.
function Controller:CapBoost(v, mult, extra)
	local S = Config.SpeedBoost or {}
	self.BoostLimit = nil
	if S.NoStacking == false or (mult <= 1 and extra <= 0) then
		return mult, extra
	end
	local top = Config.MaxSpeed or 100
	local boost = self.SpeedBoostEndsAt and self.SpeedBoostTarget or 1 -- this speed boost's own multiplier
	local dash = (self.DashEndsAt and not self.DashUncapped and self.DashTarget) or 0
	local cap = math.max(top * math.max(boost, 1), top + dash)
	local base = flatten(v, self.Grounded and self.Normal or UP).Magnitude
	local limit = math.max(cap, base)
	if mult > 1 and base * mult > limit then
		mult = base > 1e-3 and math.max(limit / base, 1) or 1
	end
	if extra > 0 and not self.DashUncapped then
		extra = math.clamp(limit - base * mult, 0, extra)
	end
	self.SpeedMult, self.SpeedExtra = mult, extra
	if not self.DashUncapped then
		self.BoostLimit = limit -- (boost pads / rings this frame are held to it too: Step)
	end
	return mult, extra
end

-- the rider's velocity in "normal speed" terms (what the physics works with), from the velocity they actually move
-- at: takes off the last Speed Boost scale-up and dash burst
function Controller:ToBase(v)
	v -= self.AppliedExtra or Vector3.zero
	local m = self.AppliedMult or 1
	if m ~= 1 then
		v = self.AppliedBasis and scaleAlong(v, self.AppliedBasis, 1 / m) or v / m
	end
	return v
end

-- and back: what the rider should actually move at for a normal-speed velocity (same scale-up and burst)
function Controller:ToActual(v)
	local m = self.AppliedMult or 1
	if m ~= 1 then
		v = self.AppliedBasis and scaleAlong(v, self.AppliedBasis, m) or v * m
	end
	return v + (self.AppliedExtra or Vector3.zero)
end

-- boost pads under the board and boost rings you fly through
function Controller:CheckBoosts(ground, position)
	local B = Config.Boost
	if self.Clock - (self.BoostedAt or -10) < B.Cooldown then
		return
	end
	if ground and ground.BoostPad then
		self:Boost(B.PadAdd, B.PadMinSpeed, nil, "Pad")
		return
	end
	for _, ring in ipairs(CollectionService:GetTagged("BoostRing")) do
		if ring:IsA("BasePart") then
			local offset = position - ring.Position
			if offset.Magnitude < ring.Size.X then
				local axis = ring.CFrame.UpVector -- the ring's hole points along its thin axis
				local along = offset:Dot(axis)
				local radial = (offset - axis * along).Magnitude
				if math.abs(along) < B.RingDepth and radial < ring.Size.X * 0.5 * B.RingHoleShare then
					local v = self.Root.AssemblyLinearVelocity
					local dir = v:Dot(axis) >= 0 and axis or -axis
					self:Boost(B.RingAdd, B.RingMinSpeed, (dir + Vector3.yAxis * B.RingLift).Unit, "Ring")
					return
				end
			end
		end
	end
end

-- fell off the track: put the rider back on the snow a couple of seconds back, keeping some speed
function Controller:Recover()
	local points = self.SafePoints
	local index = math.max(1, #points - Config.RecoverStepsBack)
	local point = points[index]
	if not point then
		self:Respawn()
		return
	end
	-- forget the spots after it, so falling off again from here goes back a bit further each time
	for i = #points, index + 1, -1 do
		table.remove(points, i)
	end
	self:Respawn(point.CFrame)
	self.Root.AssemblyLinearVelocity = point.CFrame.LookVector * math.min(point.Speed, Config.RecoverSpeed)
end

function Controller:Respawn(atCFrame)
	local spawnLocation = workspace:FindFirstChildOfClass("SpawnLocation")
	local cf = atCFrame or (spawnLocation and (spawnLocation.CFrame + Vector3.new(0, 4, 0))) or self.SpawnCFrame
	if not atCFrame then
		self.SafePoints = {}
		self.DownhillDir = nil -- back at the start: free to line up until you reach the slope
	end
	self.Root.AssemblyLinearVelocity = Vector3.zero
	self.Root.AssemblyAngularVelocity = Vector3.zero
	self.Root.CFrame = cf
	local look = cf.LookVector
	self.Heading = safeUnit(Vector3.new(look.X, 0, look.Z), -Vector3.zAxis)
	self.Normal = UP
	self.YawRate = 0
	self.Lean = 0
	self.Grounded = false
	self.Climbing = false
	self.AirTime = 0
	self.TakeoffSpeed = 0
	self.SuperJumping = false
	self.Pitch = 0
	self.PitchTarget = 0
	self.Dive = 0
	self.LastSafeAt = self.Clock
	self.Align.CFrame = CFrame.lookAt(Vector3.zero, self.Heading, UP)
	self.RespawnedEvent:Fire(atCFrame ~= nil) -- true = put back on the track mid-run, false = back to the start
end

function Controller:Step(dt)
	if dt <= 0 or not self.Root.Parent or self.Humanoid.Health <= 0 then
		return
	end
	dt = math.min(dt, 1 / 20)
	if self.FrozenUntil then
		local root = self.Root
		if os.clock() < self.FrozenUntil then
			-- Za Warudo: time has stopped for you. Held exactly where you were; the clock doesn't move, so your boosts,
			-- stuns and jump timers all wait too
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			root.CFrame = self.FrozenCFrame
			self.AntiGravity.Force = Vector3.new(0, root.AssemblyMass * workspace.Gravity, 0)
			self.Frozen = true
			return
		end
		-- time moves again: carry on exactly as you were going
		self.FrozenUntil = nil
		self.Frozen = false
		root.CFrame = self.FrozenCFrame
		root.AssemblyLinearVelocity = self.FrozenVelocity or Vector3.zero
		self.JumpQueuedAt = -10 -- a jump pressed while frozen doesn't fire the moment time resumes
		self.LastSafeAt = self.Clock
	end
	self.Clock += dt
	local root = self.Root
	local position = root.Position
	self.AntiGravity.Force = Vector3.new(0, root.AssemblyMass * workspace.Gravity, 0)
	-- flew off the track: fell too far, or in the air too long (a Jump Boost gets its flight time on top)
	local airLimit = Config.MaxAirTime + (self.SuperJumping and self.SuperJumpAirTime or 0)
	if position.Y < Config.KillY or (not self.Grounded and self.AirTime > airLimit) then
		self:Recover()
		return
	end

	local steerInput, throttle = self:ReadInput()
	self.Steer = damp(self.Steer, steerInput, Config.SteerSmoothing, dt)
	self.Tuck = damp(self.Tuck, math.max(throttle, 0), 6, dt)
	self.Brake = damp(self.Brake, math.max(-throttle, 0), 8, dt)

	local v = root.AssemblyLinearVelocity -- includes whatever collisions did last frame
	-- Speed Boost / dash: this frame's physics runs at normal speed (undo last frame's scale-up and burst; they're
	-- redone before moving)
	local speedMult, speedExtra = self:UpdateSpeedBoost()
	v = self:ToBase(v)
	local probeUp = self.Grounded and self.Normal or UP
	local ground = self:ProbeGround(position, probeUp)

	-- are we on the snow?
	local justJumped = self.Clock - self.JumpedAt < 0.22
	local grounded = false
	if ground and not justJumped and ground.Height <= Config.HoverHeight + Config.SnapDistance then
		if self.Grounded then
			grounded = true
		else
			-- landing: only when moving onto / along the snow, not up away from it
			grounded = v:Dot(ground.Normal) <= 8
		end
	end
	-- sidewall riding: snow steeper than MaxGroundAngle only holds you while you're fast. Too slow and you
	-- peel off the wall (and can't stick to a steep wall again for a moment). Slowly climbing a short lip is fine.
	if grounded then
		local W = Config.WallRide
		local angle = steepness(ground.Normal)
		if angle > Config.MaxGroundAngle then
			local climbingLip = self.Climbing and angle <= Config.Climb.MaxAngle
			local tooSlow = flatten(v, ground.Normal).Magnitude < W.MinSpeed and not climbingLip
			if tooSlow or self.Clock - self.PeeledAt < W.PeelTime then
				if tooSlow and self.Grounded then
					v += ground.Normal * W.PeelPush
					self.PeeledAt = self.Clock
				end
				grounded = false
			end
		end
	end

	if grounded and not self.Grounded then
		self:OnLand(ground, v)
		v = root.AssemblyLinearVelocity
	end
	if grounded then
		self.LastGroundedAt = self.Clock
		self.AirTime = 0
	else
		if self.Grounded then
			self.TakeoffSpeed = flatten(self:ToBase(self.Velocity), self.Normal).Magnitude -- just left the snow (ramp, crest...)
		end
		self.AirTime += dt
	end
	self.Grounded = grounded
	self.GroundMaterial = grounded and ground.Material or nil

	self.PitchTarget = 0 -- level board, unless StepAir says you're diving
	if grounded then
		v = self:StepGround(dt, v, ground, throttle)
	else
		v = self:StepAir(dt, v, throttle)
	end

	-- jump (buffered, with a little coyote time after leaving the snow, and a cooldown between jumps)
	local wantsJump = self.Clock - self.JumpQueuedAt <= Config.JumpBuffer
	local cooledDown = self.Clock - self.JumpedAt >= Config.JumpCooldown
	local canJump = cooledDown and not self.Stunned and (self.Grounded or (self.Clock - self.LastGroundedAt <= Config.CoyoteTime and not justJumped))
	if wantsJump and canJump then
		local n = self.Normal
		self.TakeoffSpeed = flatten(v, n).Magnitude
		v = flatten(v, n) + n * Config.JumpSpeed + UP * Config.JumpSpeed * 0.2
		self.JumpedAt = self.Clock
		self.JumpQueuedAt = -10
		self.Grounded = false
		self.Jumped:Fire()
	end

	v = self:ApplyBorder(v, position, dt)
	-- Speed Boost: move speedMult x as fast as the physics above says. On the snow all of it (the hover spring then
	-- follows the snow just as well at the higher speed); in the air only the flat part, so jumps go further, not higher
	local basis = (not self.Grounded) and UP or nil
	speedMult, speedExtra = self:CapBoost(v, speedMult, speedExtra) -- (abilities top out at Config.SpeedBoost.MaxSpeed)
	-- dash: the burst goes the way you're travelling (along the snow, or flat in the air; where the board points if stopped)
	local extraVec = Vector3.zero
	if speedExtra > 0 then
		local plane = self.Grounded and self.Normal or UP
		local along = flatten(v, plane)
		local dir = along.Magnitude > 2 and along.Unit or safeUnit(flatten(self.Heading, plane), self.Heading)
		extraVec = dir * speedExtra
	end
	if speedMult ~= 1 then
		v = basis and scaleAlong(v, basis, speedMult) or v * speedMult
	end
	v += extraVec
	self.AppliedMult, self.AppliedBasis, self.AppliedExtra = speedMult, basis, extraVec
	root.AssemblyLinearVelocity = v
	self:CheckBoosts(grounded and ground or nil, position)
	v = root.AssemblyLinearVelocity
	if self.BoostLimit then
		-- a boost pad / ring hit during an ability boost adds nothing past its limit either (Config.SpeedBoost.NoStacking)
		local plane = self.Grounded and self.Normal or UP
		local along = flatten(v, plane)
		if along.Magnitude > self.BoostLimit then
			v = along.Unit * self.BoostLimit + plane * v:Dot(plane)
			root.AssemblyLinearVelocity = v
		end
	end
	self.Velocity = v
	self.Speed = (self.Grounded and flatten(v, self.Normal) or v).Magnitude

	self:UpdateOrientation(dt)

	-- remember solid, fairly flat snow we were riding on
	if self.Grounded and self.Normal.Y > 0.75 and self.Speed > 15 and self.Clock - self.LastSafeAt > 0.5 then
		self.LastSafeAt = self.Clock
		local points = self.SafePoints
		table.insert(points, {
			CFrame = CFrame.lookAt(position, position + safeUnit(Vector3.new(self.Heading.X, 0, self.Heading.Z), -Vector3.zAxis)),
			Speed = self.Speed,
		})
		if #points > 12 then
			table.remove(points, 1)
		end
	end

	-- readable state for debugging / other local scripts
	local character = self.Character
	character:SetAttribute("SnowSpeed", math.floor(self.Speed + 0.5))
	character:SetAttribute("SnowGrounded", self.Grounded)
	character:SetAttribute("SnowSteer", math.floor(self.Steer * 100 + 0.5) / 100)
end

-- borders: steep surfaces that aren't snow (rock walls, green ground, curbs) are the edge of the track.
-- Looks a few studs ahead and to the sides, just above the snow. A border there redirects you to slide along it
-- (arcade style: a glancing scrape keeps nearly all your speed, a head-on hit loses Border.SpeedLoss and sends you
-- along the wall the way the course goes) and turns the board to run along it.
function Controller:ApplyBorder(v, position, dt)
	local B = Config.Border
	self.OnBorder = false
	if not B.Enabled then
		return v
	end
	local up = self.Grounded and self.Normal or UP
	local planar = flatten(v, up)
	local speed = planar.Magnitude
	local forward = speed > 2 and planar / speed or safeUnit(flatten(self.Heading, up), self.Heading)
	local origin = position - up * (self.Grounded and (Config.HoverHeight - B.RayHeight) or B.RayHeight)
	-- one averaged wall direction from every ray that found a border (bumpy rock gives jittery normals)
	local normalSum = Vector3.zero
	local closest
	for _, angle in ipairs(BORDER_RAY_ANGLES) do
		local dir = angle == 0 and forward or rotateAround(forward, up, math.rad(angle))
		local reach = B.Reach + (math.abs(angle) < 45 and (speed * (self.SpeedMult or 1) + (self.SpeedExtra or 0)) * dt * 2 or 0)
		local result = workspace:Raycast(origin, dir * reach, self.RayParams)
		if result and isBorder(result) then
			local wallNormal = safeUnit(flatten(result.Normal, up), -dir)
			normalSum += wallNormal * (1.2 - result.Distance / reach)
			local gap = result.Distance * math.max(-dir:Dot(wallNormal), 0)
			closest = closest and math.min(closest, gap) or gap
		end
	end
	if not closest then
		return v
	end
	self.OnBorder = true
	local wallNormal = safeUnit(flatten(normalSum, up), -forward)
	-- which way is "along the wall": the one closer to where you're going (or downhill, if you hit it head-on)
	local tangent = safeUnit(wallNormal:Cross(up), forward)
	local prefer = planar - wallNormal * planar:Dot(wallNormal)
	if prefer.Magnitude < speed * 0.2 then
		prefer = self.DownhillDir or self.Heading
	end
	if tangent:Dot(prefer) < 0 then
		tangent = -tangent
	end
	local into = -planar:Dot(wallNormal)
	if into > 0 then
		-- slide along it instead of into it. Only the first bump costs speed; scraping along it keeps your speed
		local newHit = self.Clock - self.LastBorderAt > 0.3
		local headOn = math.clamp(into / math.max(speed, 1), 0, 1)
		planar = tangent * speed * (newHit and 1 - B.SpeedLoss * headOn or 1)
	end
	self.LastBorderAt = self.Clock
	if closest < B.Gap then
		planar += wallNormal * (B.Gap - closest) * B.Push -- too close: ease back out
	end
	-- turn the board to run along the border instead of into it
	local heading = self.Heading
	if heading:Dot(wallNormal) < 0 then
		local along = heading:Dot(tangent) >= 0 and tangent or -tangent
		self.Heading = safeUnit(heading:Lerp(along, math.min(1, B.TurnAway * dt)), heading)
	end
	return planar + up * v:Dot(up)
end

-- does the slope under you show the way the course goes? Only when its fall line is roughly the old "downhill"
-- or roughly the way you're riding. A side bank's fall line points across the course, so riding along a bank
-- doesn't swing "downhill" sideways (which would make the board count as sideways and brake you).
function Controller:FallLineFollowsCourse(fallFlat, headingFlat)
	if fallFlat.Magnitude < 1e-3 then
		return false
	end
	local fall = fallFlat.Unit
	local limit = math.cos(math.rad(Config.TurnLimit.FollowMaxAngle))
	local current = self.DownhillDir
	return (current ~= nil and fall:Dot(current) >= limit)
		or (headingFlat.Magnitude > 1e-3 and fall:Dot(headingFlat.Unit) >= limit)
end

-- remembers which way is straight downhill (flat), smoothed so bumps don't jerk it around
function Controller:UpdateDownhill(fallFlat, dt)
	if fallFlat.Magnitude < 1e-3 then
		return
	end
	fallFlat = fallFlat.Unit
	local current = self.DownhillDir
	self.DownhillDir = current and safeUnit(dampVector(current, fallFlat, Config.TurnLimit.FollowRate, dt), fallFlat) or fallFlat
end

-- degrees between the board and straight downhill (0 = pointing down the hill, 90 = sideways), and which side it's on
function Controller:AngleFromDownhill(heading)
	local down = self.DownhillDir
	if not down then
		return 0, 1
	end
	local flat = safeUnit(Vector3.new(heading.X, 0, heading.Z), down)
	local angle = math.deg(math.acos(math.clamp(flat:Dot(down), -1, 1)))
	return angle, (down:Cross(flat).Y >= 0 and 1 or -1)
end

-- turns the board by yawRate, but (like SKI) never more than TurnLimit.MaxAngle away from straight downhill:
-- holding A / D stops you sideways across the hill instead of turning you round to face uphill
function Controller:ApplyTurn(heading, yawRate, up, dt)
	local L = Config.TurnLimit
	if not self.DownhillDir or L.MaxAngle >= 180 then
		return rotateAround(heading, up, yawRate * dt), yawRate
	end
	local angle, side = self:AngleFromDownhill(heading)
	if yawRate * side > 0 then -- turning further away from downhill: ease off near the limit
		yawRate *= math.clamp((L.MaxAngle - angle) / math.max(L.EaseZone, 0.001), 0, 1)
	end
	heading = rotateAround(heading, up, yawRate * dt)
	angle, side = self:AngleFromDownhill(heading)
	if angle > L.MaxAngle then
		-- past the limit (e.g. after a landing or a sharp crest): ease back toward it, no snapping
		local back = math.min(angle - L.MaxAngle, L.ReturnRate * dt)
		heading = rotateAround(heading, UP, -math.rad(back) * side)
		heading = safeUnit(flatten(heading, up), heading)
		if yawRate * side > 0 then
			yawRate = 0
		end
	end
	return heading, yawRate
end

function Controller:StepGround(dt, v, ground, throttle)
	local n = dampVector(self.Normal, ground.Normal, Config.NormalSmoothing, dt).Unit
	self.Normal = n

	-- velocity along the snow (the part into/out of the snow is replaced by the hover spring below)
	local vt = flatten(v, n)
	local speed = vt.Magnitude
	local entrySpeed = speed

	-- keep the heading on the snow's surface
	local heading = safeUnit(flatten(self.Heading, n), safeUnit(vt, self.Heading))

	-- which way is downhill here (along the snow), and is this a real slope or flat ground?
	local gravity = Vector3.new(0, -Config.Gravity, 0)
	local slopePull = flatten(gravity, n)
	local fallDir = safeUnit(slopePull, heading)
	local B = Config.Brake
	local onDownhill = math.deg(math.acos(math.clamp(n.Y, -1, 1))) >= B.DownhillAngle
	-- remember which way is downhill (the way the course goes), for the turn limit and sideways brake.
	-- Only while riding down at a decent speed: not while riding UP a slope (its fall line points back at you)
	-- and not while crawling slowly at the foot of a hill, so you can still turn to face a hill and climb it.
	local fallFlat = Vector3.new(slopePull.X, 0, slopePull.Z)
	local headingFlat = Vector3.new(heading.X, 0, heading.Z)
	local ridingUp = fallFlat.Magnitude > 1e-3 and headingFlat.Magnitude > 1e-3 and fallFlat.Unit:Dot(headingFlat.Unit) < UPHILL_DOT
	local slopeAngle = steepness(n)
	if slopeAngle > Config.MaxGroundAngle then
		-- riding a snow sidewall: "downhill" follows the way you're riding along the wall, so the turn limit
		-- doesn't fight the curve and you come off the wall lined up
		if headingFlat.Magnitude > 0.3 then
			self:UpdateDownhill(headingFlat, dt)
		end
	elseif onDownhill and (not self.DownhillDir or (not ridingUp and speed >= Config.TurnLimit.FollowMinSpeed
		and self:FallLineFollowsCourse(fallFlat, headingFlat))) then
		self:UpdateDownhill(fallFlat, dt)
	end

	-- steering: turn rate grows with speed (stiff at a crawl, quick at speed), and builds up smoothly
	local speedT = math.clamp(speed / Config.TurnSpeedRef, 0, 1)
	local turnRate = Config.TurnRateSlow + (Config.TurnRateFast - Config.TurnRateSlow) * speedT
	turnRate *= 1 + (Config.Tuck.TurnMultiplier - 1) * self.Tuck
	turnRate *= 1 + (Config.Brake.TurnMultiplier - 1) * self.Brake
	self.YawRate = damp(self.YawRate, -self.Steer * turnRate, Config.TurnResponse, dt)
	heading, self.YawRate = self:ApplyTurn(heading, self.YawRate, n, dt)
	-- on steep sidewalls gravity slowly swings the board back down the wall, so a wall ride arcs up and back down
	-- like a real one (you can steer against it)
	local arcT = math.clamp((slopeAngle - 50) / 40, 0, 1)
	if arcT > 0 and heading:Dot(fallDir) < 0.99 then
		local axis = safeUnit(heading:Cross(fallDir), n)
		local gap = math.acos(math.clamp(heading:Dot(fallDir), -1, 1))
		heading = safeUnit(flatten(rotateAround(heading, axis, math.min(gap, Config.WallRide.Arc * arcT * dt)), n), heading)
	end
	self.Heading = heading

	-- riding UP the slope under you (side banks, curve walls, hills)? 0 = not, 1 = going straight up it.
	-- Going up is pure momentum: no drag, friction, sideways brake, cruise or push, only gravity slows you.
	-- It's the way you're actually travelling that counts, not just where the board points: sliding backwards up
	-- a hill (knocked round by a wall) isn't pushed further up it, gravity just brings you back down
	local travel = speed > 2 and vt / speed or heading
	local upT = onDownhill and math.clamp((-travel:Dot(fallDir) - 0.05) / 0.25, 0, 1) or 0
	self.UpT = upT

	-- side wall (a steep slope off to the side of the course, like the wall of a curve) and riding along / up it?
	-- 0 = no, 1 = fully. Gets a little boost instead of slowing you down (Config.WallBoost)
	local WB = Config.WallBoost
	local wallT = 0
	if WB.Enabled and self.DownhillDir then
		local steepT = math.clamp((slopeAngle - WB.StartAngle) / math.max(WB.FullAngle - WB.StartAngle, 1), 0, 1)
		if steepT > 0 then
			local side = 1 -- near-vertical walls are always side walls
			if fallFlat.Magnitude > 1 then
				side = math.clamp((0.7 - math.abs(fallFlat.Unit:Dot(self.DownhillDir))) / 0.4, 0, 1)
			end
			local riding = math.clamp((0.35 - heading:Dot(fallDir)) / 0.35, 0, 1) -- along or up it, not coming down it
			wallT = steepT * side * riding
		end
	end
	self.OnWall = wallT
	if wallT < 0.2 then
		self.WallArmed = true
	end

	-- gravity along the slope: fully along the board, mostly held by the edge sideways
	local pullAlong = slopePull:Dot(heading)
	if pullAlong < 0 then
		-- climbing: how hard gravity slows you (1 = natural). Not at all on a side wall
		pullAlong *= Config.Uphill.GravityScale * (1 - wallT)
	end
	local along = heading * pullAlong
	local sideways = slopePull - along
	vt += (along + sideways * (1 - Config.EdgeHold)) * dt

	-- grip: travel direction swings toward where the board points (riding backwards if sliding back)
	speed = vt.Magnitude
	if speed > 0.05 then
		local dir = vt / speed
		local target = dir:Dot(heading) >= -0.2 and heading or -heading
		local angle = math.acos(math.clamp(dir:Dot(target), -1, 1))
		if angle > 1e-4 then
			local grip = Config.Grip + (Config.LowSpeedGrip - Config.Grip) * (1 - math.clamp(speed / 40, 0, 1))
			local step = math.min(angle, grip * dt)
			local axis = safeUnit(dir:Cross(target), n)
			dir = rotateAround(dir, axis, step)
			-- a clean carve (board lined up with where you're going) keeps its speed;
			-- only a real skid (sliding sideways, e.g. a crooked landing) scrubs some off
			if angle > math.rad(Config.SkidAngle) then
				speed *= 1 - (1 - math.cos(step)) * Config.SkidScrub
			end
		end
		vt = dir * speed
	end

	-- drag, friction, hard-cut bleed, braking
	local drag = Config.Drag * (1 + (Config.Tuck.DragMultiplier - 1) * self.Tuck)
	local boardAngle = self:AngleFromDownhill(heading)
	-- normal turns keep their speed; only a sharp hard cut bleeds a tiny bit: the board swung far from
	-- straight downhill AND still turning hard (just riding across the hill doesn't count)
	local H = Config.HardCut
	local turning = math.clamp(math.abs(self.YawRate) / math.max(turnRate, 0.001), 0, 1) -- 1 = turning as hard as you can right now
	local cutT = math.clamp((boardAngle - H.StartAngle) / math.max(H.FullAngle - H.StartAngle, 0.001), 0, 1) * turning
	-- braking: S, plus turning the board sideways across the hill (like SKI).
	-- On a downhill it eases off near the crawl speed, so you settle into a slow drift instead of stopping.
	local L = Config.TurnLimit
	-- sideways braking kicks in once the board has settled sideways (holding the turn at the stop),
	-- not while it's still swinging through a quick hard cut
	local sideT = math.clamp((boardAngle - L.SideBrakeStart) / math.max(L.MaxAngle - L.SideBrakeStart, 0.001), 0, 1)
	-- going up a slope: only gravity (above) and S slow you, so momentum decides how far up you get.
	-- Riding a side wall: nothing slows you at all (the wall boost below speeds you up instead)
	local free = 1 - math.max(upT, wallT)
	local brakeDecel = B.Decel * self.Brake + L.SideBrake * sideT * sideT * (1 - turning) * free
	if onDownhill then
		brakeDecel *= math.clamp((speed - B.DownhillMinSpeed) / math.max(B.DownhillBrakeFade, 0.001), 0, 1)
	end
	local decel = (drag * speed * speed
		+ Config.SnowFriction * Config.Gravity * math.max(n.Y, 0)
		+ H.Bleed * cutT * speed) * free
		+ brakeDecel
	local newSpeed = math.max(0, speed - decel * dt)

	-- W: push when slow (skating), small tuck acceleration when fast. No skating push up a slope,
	-- and none while sliding backwards (it would push you the wrong way)
	if throttle > 0 and travel:Dot(heading) > -0.2 then
		if newSpeed < Config.Push.MaxSpeed then
			newSpeed += Config.Push.Accel * throttle * free * dt
		else
			newSpeed += Config.Tuck.Accel * throttle * dt
		end
	end
	-- hard ceiling: slopes can't push past MaxSpeed (boosts can, and then bleed back down)
	if entrySpeed > Config.MaxSpeed and self.Brake < 0.5 then
		-- boosted: drag is ignored and the extra speed bleeds off at a steady rate
		newSpeed = math.max(Config.MaxSpeed, entrySpeed - Config.OverSpeedDecel * dt)
	elseif newSpeed > Config.MaxSpeed then
		newSpeed = Config.MaxSpeed
	end
	-- base speed (cruise): once rolling, hold at least Cruise.BaseSpeed on flats and gentle slopes.
	-- Below it, drag and friction don't slow you and the board speeds back up. S or turning the board
	-- sideways fades it out, so braking, the downhill crawl and stopping on flat ground still work.
	local C = Config.Cruise
	local cruiseSpeed = C.BaseSpeed + ((C.TuckSpeed or C.BaseSpeed) - C.BaseSpeed) * self.Tuck -- crouching (W) cruises faster
	if speed >= C.StartSpeed and newSpeed < cruiseSpeed then
		local w = math.clamp(1 - self.Brake * 2, 0, 1) * (1 - sideT) * free -- no cruise push up a slope
		if w > 0 then
			-- drag and friction don't slow you below base speed, but a sharp hard cut still bleeds its tiny bit
			-- (and the board waits until the cut is over before speeding back up)
			local cruising = math.max(newSpeed, speed) + C.Accel * (1 - cutT) * dt - H.Bleed * cutT * speed * dt
			cruising = math.min(cruiseSpeed, cruising)
			newSpeed += (cruising - newSpeed) * w
		end
	end
	-- sidewall boost: a small kick of speed as you reach a side wall, then gentle extra speed while you ride it
	if wallT > 0 and speed >= Config.Cruise.StartSpeed then
		local cap = math.max(WB.MaxSpeed, newSpeed)
		if wallT > 0.5 and self.WallArmed and self.Clock - self.WallKickAt > WB.Cooldown then
			self.WallArmed = false
			self.WallKickAt = self.Clock
			newSpeed = math.min(newSpeed + WB.Kick, cap)
			self.Boosted:Fire("Wall") -- small FOV kick + speed lines (camera / SpeedFX scale it by WallBoost.FxShare)
		end
		newSpeed = math.min(newSpeed + WB.Accel * wallT * dt, cap)
	end

	-- which way we're sliding (if stopped, along the board)
	local moveDir = speed > 0.05 and vt / speed or heading

	-- slow climb: pointing up a slope and holding W, you can always creep up it (just barely), even with
	-- no speed left; the steeper the slope, the slower. Let go of W and gravity slides you back down.
	local K = Config.Climb
	local climbing = false
	if K.Enabled and throttle > 0 and self.Brake < 0.3 and onDownhill and slopeAngle <= K.MaxAngle and heading:Dot(fallDir) < -K.Facing then
		local steepT = math.clamp((slopeAngle - B.DownhillAngle) / math.max(K.MaxAngle - B.DownhillAngle, 1), 0, 1)
		local climbSpeed = (K.Speed + (K.SteepSpeed - K.Speed) * steepT) * throttle
		if newSpeed < climbSpeed and (speed <= climbSpeed or moveDir:Dot(heading) > 0) then
			moveDir = heading
			newSpeed = climbSpeed
			climbing = true
		end
	end
	self.Climbing = climbing

	-- downhill creep: on a real slope you slow to a crawl but never fully stop.
	-- Flat ground (gentler than Brake.DownhillAngle) still lets you stop completely.
	if not climbing and onDownhill and newSpeed < B.DownhillMinSpeed then
		if speed <= 0.5 then
			moveDir = heading:Dot(fallDir) >= 0 and heading or -heading -- stopped: nose or tail, whichever points downhill
		end
		local downhill = moveDir:Dot(fallDir)
		if downhill > -0.1 then -- not climbing (momentum carrying you up a bank or ramp is left alone)
			-- always drift at least a little straight down the hill, so you never stall going across it
			moveDir = safeUnit(moveDir + fallDir * math.max(0, B.CreepDownhillShare - downhill), fallDir)
			newSpeed = B.DownhillMinSpeed
		end
	end
	vt = moveDir * newSpeed

	-- hover spring: hold the board at HoverHeight over the snow (gentle downward pull over crests)
	-- leaning tips the body over the board: drop the body a little so the board stays on the snow
	local hover = Config.HoverHeight - Config.BoardBelowRoot * (1 - math.cos(math.rad(self.Lean)))
	local heightError = hover - ground.Height
	-- stick: a little pull into the snow, much firmer on steep sidewalls so you hug the curve
	local stick = Config.StickForce + (Config.WallRide.StickForce - Config.StickForce) * math.clamp((slopeAngle - 45) / 45, 0, 1)
	local normalSpeed = math.clamp(heightError * 14, -Config.MaxDropSpeed, 40) - stick * dt
	return vt + n * normalSpeed
end

function Controller:StepAir(dt, v, throttle)
	self.Climbing = false
	-- Jump Boost dive (hold W): eases in and out so it flows (Config.SuperJump), and eases off again just before the
	-- snow (the flare) so you swoop into the landing instead of planting the nose
	local J = Config.SuperJump
	local wantDive = (self.SuperJumping and throttle and throttle > 0) and throttle or 0
	self.Dive = damp(self.Dive, wantDive, wantDive > self.Dive and J.DiveRampIn or J.DiveRampOut, dt)
	local dive = self.Dive
	self.DiveFlare = 1
	if dive > 0.01 and v.Y < 0 then
		local reach = math.max(-v.Y * J.FlareTime * 1.5, 12)
		local hit = workspace:Raycast(self.Root.Position, Vector3.new(0, -reach, 0), self.RayParams)
		if hit then
			local timeToSnow = math.max(self.Root.Position.Y - hit.Position.Y - Config.HoverHeight, 0) / -v.Y
			self.DiveFlare = math.clamp(timeToSnow / math.max(J.FlareTime, 1e-3), 0, 1)
		end
	end
	dive *= self.DiveFlare
	-- gravity: the glide blends out as the dive comes in, plus the dive's extra pull
	local g = airGravity(v.Y, self.AirTime)
	g += (Config.AirGravity - g) * dive + J.DiveGravity * dive
	v += Vector3.new(0, -g, 0) * dt
	if self.Clock - self.BoostedAt > Config.Boost.AirDragFreeTime then
		-- air drag: light on your forward motion (Config.AirForwardDrag) so momentum carries through the jump;
		-- falling is slowed as before, so jump heights don't change
		local k = Config.Drag * v.Magnitude * dt
		local flat = Vector3.new(v.X, 0, v.Z)
		-- forward drag only counts your forward speed (falling faster doesn't slow you down forward)
		flat *= 1 - math.min(1, Config.Drag * flat.Magnitude * dt * Config.AirForwardDrag)
		v = Vector3.new(flat.X, v.Y * (1 - math.min(1, k)), flat.Z)
	end
	-- the dive tips the board nose-down (DivePitchMin as it starts, steeper the steeper you're falling), easing in
	-- with the dive and levelling out with the flare. Without W (or holding S) you just come down at your regular speed
	if dive > 0.001 then
		local flatSpeed = Vector3.new(v.X, 0, v.Z).Magnitude * (self.SpeedMult or 1)
		local fallAngle = math.deg(math.atan2(math.max(-v.Y, 0), flatSpeed))
		self.PitchTarget = math.clamp(fallAngle, J.DivePitchMin, J.DivePitchMax) * dive
	end
	-- air control: A / D gently bend your flight path and the board turns with it, so you land lined up.
	-- The path is rotated, not pushed: speed and forward momentum are kept, it only bends a little.
	self.YawRate = damp(self.YawRate, -self.Steer * Config.AirTurnRate, Config.AirTurnResponse, dt)
	local before = self.Heading
	local heading
	heading, self.YawRate = self:ApplyTurn(before, self.YawRate, UP, dt) -- same turn limit in the air
	heading = safeUnit(Vector3.new(heading.X, 0, heading.Z), before)
	local turned = math.atan2(before:Cross(heading).Y, before:Dot(heading)) -- how far the board turned this frame
	local flatVel = Vector3.new(v.X, 0, v.Z)
	if flatVel.Magnitude > 1 then
		flatVel = rotateAround(flatVel, UP, turned)
		v = Vector3.new(flatVel.X, v.Y, flatVel.Z)
	end
	self.Heading = heading
	self.Normal = dampVector(self.Normal, UP, 3, dt).Unit
	return v
end

function Controller:OnLand(ground, v)
	local n = ground.Normal
	local vt = flatten(v, n)
	local impact = math.clamp(-v:Dot(n) / 90, 0, 1)
	if self.SuperJumping then
		-- coming down from a Jump Boost: on a slope that long fall would turn into a huge burst of speed (or a sideways
		-- skid on a bank), so only your forward motion carries on along the snow. The big fall still shakes the camera
		vt = flatten(Vector3.new(v.X, 0, v.Z), n)
		impact = math.min(impact, Config.SuperJump.LandingShake or 1) -- a softer bump, so a dive flows into the ride
	end
	local heading = safeUnit(flatten(self.Heading, n), self.Heading)
	local clean = true
	if vt.Magnitude > 10 then
		local off = math.deg(math.acos(math.clamp(math.abs(vt.Unit:Dot(heading)), -1, 1)))
		if off > Config.BadLandingAngle then
			vt *= Config.BadLandingSpeedKeep
			impact = math.max(impact, 0.7)
			clean = false
		end
	end
	-- a clean landing keeps your speed: landing on the snow only takes away the falling part of your speed, and
	-- that would make every ramp landing feel like hitting the brakes. So you land at least about as fast as you
	-- took off (Config.Landing), as long as you were still going that fast in the air
	if clean and Config.Landing then
		local target = math.min(v.Magnitude, self.TakeoffSpeed or 0) * Config.Landing.KeepTakeoffSpeed
		if target > vt.Magnitude then
			vt = (vt.Magnitude > 1 and vt.Unit or heading) * target
		end
	end
	self.SuperJumping = false
	self.Dive = 0
	self.Heading = heading
	self.Normal = n
	self.Root.AssemblyLinearVelocity = vt
	if self.AirTime > 0.25 then
		self.Landed:Fire(impact)
	end
end

function Controller:UpdateOrientation(dt)
	local up = self.Normal
	local forward = safeUnit(flatten(self.Heading, up), self.Heading)
	-- lean by how hard the board is actually carving (speed x turn rate), like Mario & Sonic:
	-- quick swerves at speed tip you right over, gentle turns and the sideways crawl barely lean
	local carve = math.clamp(self.Speed * -self.YawRate / Config.LeanCarveRef, -1, 1)
	local leanTarget = self.Grounded and carve * Config.MaxLean or self.Steer * 8
	self.Lean = damp(self.Lean, leanTarget, Config.LeanSmoothing, dt)
	-- nose-down tilt (Jump Boost dive); levels out quickly once you're back on the snow
	local J = Config.SuperJump
	self.Pitch = damp(self.Pitch, self.PitchTarget or 0, self.Grounded and J.PitchReturn or J.PitchResponse, dt)
	local base = CFrame.lookAt(Vector3.zero, forward, up)
	self.Align.CFrame = base * CFrame.Angles(math.rad(-self.Pitch), 0, 0) * CFrame.Angles(0, 0, math.rad(-self.Lean))
end

function Controller:Destroy()
	for _, c in ipairs(self.Connections) do
		c:Disconnect()
	end
	ContextActionService:UnbindAction("SnowboardReset")
	for sound, volume in pairs(self.MutedSounds) do -- off the board: footsteps back to normal
		if sound.Parent then
			sound.Volume = volume
		end
	end
	self.MutedSounds = {}
	if self.Align then
		self.Align:Destroy()
	end
	if self.AntiGravity then
		self.AntiGravity:Destroy()
	end
	self.Landed:Destroy()
	self.Jumped:Destroy()
	self.RespawnedEvent:Destroy()
	self.Boosted:Destroy()
	self.HitTaken:Destroy()
end

return Controller
