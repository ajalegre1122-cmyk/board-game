--[[
	CameraRig (client): chase camera for the snowboard.
	  - sits behind and above the rider, following the direction of travel with a lazy swing in turns,
	    so it keeps looking down the course while you swerve (like Mario & Sonic)
	  - pulls back smoothly as speed builds, and widens the FOV steadily with speed (up to boost speed)
	  - tilts a little with the rider's lean on carves
	  - pulls in when a wall or rock would block the view, and shakes briefly on hard landings
	  - Jump Boost dive (hold W): swings up behind the board and tips down with its nose, looking where you're diving
	  - speed feel: the FOV punches wider while you're gaining speed, the camera dollies in as the FOV widens
	    (so the world stretches past while the rider stays big), drops lower to the snow at speed, gets left
	    behind for a moment when you speed up or boost (then catches up), banks harder in carves, and a light
	    rumble builds at high speed
	All numbers are in Config.Camera.
]]

local Config = require(script.Parent:WaitForChild("Config"))
local C = Config.Camera

local CameraRig = {}
CameraRig.__index = CameraRig

local UP = Vector3.yAxis

local function damp(a, b, rate, dt)
	return a + (b - a) * (1 - math.exp(-rate * dt))
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

local function safeLerpDir(a, b, t)
	local v = a:Lerp(b, t)
	return v.Magnitude > 1e-3 and v.Unit or a
end

local function horizontal(v, fallback)
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude < 1e-3 then
		return fallback
	end
	return flat.Unit
end

function CameraRig.new()
	local self = setmetatable({}, CameraRig)
	self.Camera = workspace.CurrentCamera
	self.Position = nil
	self.Direction = nil
	self.Fov = C.FovSlow
	self.Roll = 0
	self.Shake = 0
	self.Pitch = 0
	self.Accel = 0
	self.Clock = 0
	return self
end

function CameraRig:Attach(controller)
	self.Controller = controller
	self.Camera = workspace.CurrentCamera
	self.Camera.CameraType = Enum.CameraType.Scriptable
	self.Position = nil
	self.Direction = nil
	self.RayParams = RaycastParams.new()
	self.RayParams.FilterType = Enum.RaycastFilterType.Exclude
	self.RayParams.FilterDescendantsInstances = { controller.Character }
	self.LandConnection = controller.Landed.Event:Connect(function(impact)
		self.Shake = math.max(self.Shake, impact * C.LandingShake)
	end)
	self.Kick = 0
	self.BoostConnection = controller.Boosted.Event:Connect(function(kind)
		-- a sidewall boost gets a smaller kick than a boost pad (Config.WallBoost.FxShare)
		local share = kind == "Wall" and Config.WallBoost.FxShare or 1
		self.Kick = math.max(self.Kick or 0, Config.Boost.FovKick * share)
		self.Shake = math.max(self.Shake, (C.BoostShake or 0.25) * share)
	end)
	self.RespawnConnection = controller.RespawnedEvent.Event:Connect(function()
		self.Position = nil
		self.Direction = nil
	end)
	-- got hit by an ability: a jolt (Config.Hits.<kind>.Shake)
	self.HitConnection = controller.HitTaken and controller.HitTaken.Event:Connect(function(hit)
		self.Shake = math.max(self.Shake, hit.Shake or 0.4)
	end)
end

function CameraRig:Detach()
	if self.LandConnection then
		self.LandConnection:Disconnect()
		self.RespawnConnection:Disconnect()
		self.BoostConnection:Disconnect()
		if self.HitConnection then
			self.HitConnection:Disconnect()
		end
	end
	self.Controller = nil
	self.Camera.CameraType = Enum.CameraType.Custom
	self.Camera.FieldOfView = 70
end

function CameraRig:Update(dt)
	local controller = self.Controller
	if not controller or not controller.Root.Parent then
		return
	end
	dt = math.min(dt, 1 / 20)
	local camera = self.Camera
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	local root = controller.Root
	local speed = controller.Speed
	local t = math.clamp(speed / C.SpeedRef, 0, 1)
	t = t * t * (3 - 2 * t) -- ease in/out

	-- which way the camera looks: travel direction when moving, board heading when slow
	local heading = horizontal(controller.Heading, Vector3.zAxis)
	local travel = horizontal(controller.Velocity, heading)
	local wanted = speed > 12 and safeLerpDir(travel, heading, C.HeadingShare or 0) or heading
	if not self.Direction then
		self.Direction = wanted
	else
		self.Direction = self.Direction:Lerp(wanted, 1 - math.exp(-C.TurnSharpness * dt))
		if self.Direction.Magnitude < 1e-3 then
			self.Direction = wanted
		end
		self.Direction = self.Direction.Unit
	end
	local dir = self.Direction

	-- follow the slope's pitch a little so steep drops are visible
	local slopePitch = 0
	if controller.Grounded and controller.Velocity.Magnitude > 5 then
		slopePitch = math.clamp(controller.Velocity.Unit.Y, -0.6, 0.3)
	end
	self.Pitch = damp(self.Pitch, slopePitch, 3, dt)

	-- how hard you're speeding up right now (smoothed): drives the FOV punch and the camera stretch
	local accel = self.LastSpeed and (speed - self.LastSpeed) / math.max(dt, 1e-3) or 0
	self.LastSpeed = speed
	self.Accel = damp(self.Accel, math.max(accel, 0), C.AccelSmoothing or 5, dt) -- smoothed so bumps don't jolt the camera
	local accelT = math.clamp(self.Accel / (C.FovAccelRef or 60), 0, 1)
	self.Kick = damp(self.Kick or 0, 0, 1.5, dt)
	local kickT = math.clamp(self.Kick / math.max(Config.Boost.FovKick, 1), 0, 1)

	-- dolly zoom: as the FOV widens, the camera moves in, so the rider stays a good size while the world
	-- stretches and rushes past (C.DollyZoom: 0 = off, 1 = rider stays exactly the same size)
	local fovRad = math.rad(math.clamp(self.Fov, 1, 120) / 2)
	local dolly = 1 - (C.DollyZoom or 0) * (1 - math.tan(math.rad(C.FovSlow / 2)) / math.tan(fovRad))
	local distance = lerp(C.DistanceSlow, C.DistanceFast, t) * math.clamp(dolly, 0.3, 1)
	-- the camera gets left behind a little when you speed up or a boost hits, then catches back up (whoosh)
	distance += accelT * (C.AccelPullBack or 0) + kickT * (C.BoostPullBack or 0)
	local height = lerp(C.HeightSlow, C.HeightFast, t)
	local focus = root.Position + UP * 2.2
	-- Jump Boost dive: the board tips nose-down (controller.Pitch), so the camera swings up behind it and looks down
	-- along its nose (C.DiveFollow = how much of the board's tilt the camera follows)
	local diveAngle = math.rad((controller.Pitch or 0) * (C.DiveFollow or 0))
	local diveTurn = CFrame.identity
	if diveAngle > 1e-3 then
		local right = dir:Cross(UP)
		if right.Magnitude > 1e-3 then
			diveTurn = CFrame.fromAxisAngle(right.Unit, -diveAngle)
		end
		distance += (C.DivePullBack or 0) * math.clamp(diveAngle / math.rad(45), 0, 1)
	end
	-- smooth the offset from the rider (not the world position), so the camera never trails
	-- further behind just because you're going fast
	local wantedOffset = diveTurn:VectorToWorldSpace(-dir * distance + UP * (height - self.Pitch * distance * 0.35))
	if not self.Offset or not self.Position then
		self.Offset = wantedOffset
	else
		self.Offset = self.Offset:Lerp(wantedOffset, 1 - math.exp(-C.FollowSharpness * dt))
	end
	local desired = focus + self.Offset

	-- don't let rocks/walls block the view
	local toCam = desired - focus
	local hit = workspace:Raycast(focus, toCam, self.RayParams)
	if hit then
		desired = hit.Position - toCam.Unit * 1.2
	end
	self.Position = desired

	local lookAt = focus + diveTurn:VectorToWorldSpace(dir * C.LookAhead + UP * (self.Pitch * C.LookAhead * 0.8))
	-- FOV widens steadily with speed all the way up to boost speed (not eased), so speeding up always feels faster,
	-- and punches wider still while you're gaining speed (C.FovAccelKick)
	local accelKick = accelT * (C.FovAccelKick or 0)
	local fovT = math.clamp(speed / C.FovSpeedRef, 0, 1)
	self.Fov = damp(self.Fov, math.min(lerp(C.FovSlow, C.FovFast, fovT) + self.Kick + accelKick, 120), C.FovSharpness, dt)
	local rollTarget = math.clamp(-controller.Lean * C.RollFactor, -C.MaxRoll, C.MaxRoll)
	self.Roll = damp(self.Roll, rollTarget, 4, dt)

	-- camera shake (same style as the first version):
	--  * landings and boosts: a short shake that dies away
	--  * speed rumble: a smooth shudder that builds with speed, from RumbleStart to full at RumbleFull
	self.Clock += dt
	local shakeOffset = Vector3.zero
	if self.Shake > 0.01 then
		shakeOffset = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * self.Shake
		self.Shake = damp(self.Shake, 0, 8, dt)
	end
	local rumbleRoll = 0
	local rumbleT = math.clamp((speed - (C.RumbleStart or 1e9)) / math.max((C.RumbleFull or 1) - (C.RumbleStart or 0), 1), 0, 1)
	if rumbleT > 0 then
		local tt = self.Clock * (C.RumbleSpeed or 18)
		shakeOffset += Vector3.new(math.noise(tt, 0.3, 1.7), math.noise(0.6, tt, 4.1), math.noise(2.2, 5.3, tt)) * (C.RumbleAmount or 0) * rumbleT
		rumbleRoll = math.noise(tt * 0.7, 9.1, 3.3) * (C.RumbleRoll or 0) * rumbleT
	end

	camera.FieldOfView = self.Fov
	camera.CFrame = CFrame.lookAt(self.Position + shakeOffset, lookAt) * CFrame.Angles(0, 0, math.rad(self.Roll + rumbleRoll))
end

return CameraRig
