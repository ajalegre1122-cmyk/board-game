--!native
--[[
	SpeedFX (client): fullscreen speed / wind effect that kicks in as you speed up.
	Roblox has no custom fullscreen shaders, so this is a ScreenGui overlay.

	Style "Noise" (default): soft, cloudy white streaks bursting out from the middle of the screen, made the
	  same way as the After Effects reference (Fractal Noise -> Polar Coordinates -> Unmult). The game paints a
	  few of these streak pictures once when it starts (takes about a second, a little each frame so nothing
	  hitches), then keeps crossfading between them, twisting and zooming them outward so the wind rushes past.
	  A few sharp anime speed lines also flicker in from the edges on top (Config.SpeedFX.NoiseExtraLines).
	Style "Lines": the older sharp anime speed lines + soft wind wisps from the screen edges.
	  (Also used automatically if the streak pictures can't be made.)

	Strength grows with speed (Config.SpeedFX.StartSpeed -> FullSpeed), swells a little while you're gaining
	speed, and bursts when a boost hits. The middle of the screen stays clear.
	All numbers are in Config.SpeedFX.
]]

local Players = game:GetService("Players")
local AssetService = game:GetService("AssetService")

local Config = require(script.Parent:WaitForChild("Config"))

local SpeedFX = {}
SpeedFX.__index = SpeedFX

local rng = Random.new()
local TWO_PI = math.pi * 2
local GRID_ANGLES, GRID_RADII = 1024, 128 -- the noise is worked out on this round grid, then wrapped into the picture
local BUILD_BUDGET = 0.005 -- seconds of painting per frame while the streak pictures are being made

local function damp(a, b, rate, dt)
	return a + (b - a) * (1 - math.exp(-rate * dt))
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

local function make(className, props, parent)
	local obj = Instance.new(className)
	for k, v in pairs(props) do
		obj[k] = v
	end
	obj.Parent = parent
	return obj
end

--[[
	Paints the streak pictures, a few milliseconds per frame. For each picture:
	  1) fractal noise on a round grid (around the circle x out from the middle), like After Effects Fractal Noise
	     wrapped with Polar Coordinates: features are thin near the middle and fan out toward the edges
	  2) contrast / brightness, then "unmult": the picture is pure white and the noise sets how see-through it is
	onPicture(content) gets each finished picture; onFail(reason) runs if pictures can't be made on this device.
]]
local function paintStreaks(F, onPicture, onFail, alive)
	local N = math.clamp(math.floor(F.NoiseResolution or 512), 64, 1024)
	local NA, NR = GRID_ANGLES, GRID_RADII
	local octaves = math.clamp(math.floor(F.NoiseDetail or 5), 1, 8)
	local streaks, length, gain = F.NoiseStreaks, F.NoiseLength, 0.55
	local level, contrast = F.NoiseBrightness, F.NoiseContrast
	local holeR = F.ClearCenter / math.sqrt(2) -- picture units (1 = picture corner); see UpdateStreaks for the sizing
	local holeSoft = math.max(F.NoiseHoleSoftness, 0.01)

	local started = os.clock()
	local function breathe()
		if os.clock() - started > BUILD_BUDGET then
			task.wait()
			started = os.clock()
		end
	end

	-- where every pixel sits: angle around the middle, distance out, and the clear-middle mask (shared by all pictures)
	local pixels = N * N
	local angleAt = buffer.create(pixels * 4)
	local radiusAt = buffer.create(pixels * 4)
	local maskAt = buffer.create(pixels * 4)
	for y = 0, N - 1 do
		local dy = (y + 0.5) / N * 2 - 1
		for x = 0, N - 1 do
			local dx = (x + 0.5) / N * 2 - 1
			local q = (y * N + x) * 4
			local r = math.sqrt(dx * dx + dy * dy) / math.sqrt(2) -- 0 = middle, 1 = picture corner
			buffer.writef32(angleAt, q, (math.atan2(dy, dx) + math.pi) / TWO_PI * NA)
			buffer.writef32(radiusAt, q, r * (NR - 1))
			local t = math.clamp((r - holeR) / holeSoft, 0, 1)
			buffer.writef32(maskAt, q, t * t * (3 - 2 * t))
		end
		breathe()
	end
	local cosA, sinA = table.create(NA), table.create(NA)
	for i = 0, NA - 1 do
		local angle = i / NA * TWO_PI - math.pi
		cosA[i + 1], sinA[i + 1] = math.cos(angle), math.sin(angle)
	end

	local grid = buffer.create(NA * NR * 4)
	for picture = 1, math.max(1, math.floor(F.NoiseFrames)) do
		if not alive() then
			return
		end
		local ok, image = pcall(function()
			return AssetService:CreateEditableImage({ Size = Vector2.new(N, N) })
		end)
		if not ok or not image then
			if picture == 1 then
				onFail(ok and "no image memory left" or tostring(image))
			end
			return -- keep the pictures already made
		end
		local evo = picture * 1.37 -- each picture is a different "evolution" of the noise

		-- 1) fractal noise on the round grid (seamless all the way around)
		local sum, sumSq = 0, 0
		for j = 0, NR - 1 do
			local r = j / (NR - 1)
			for i = 1, NA do
				local c, s = cosA[i], sinA[i]
				local v, amp, k, f = 0, 1, streaks, length
				for o = 0, octaves - 1 do
					v += amp * math.noise(c * k + evo * 1.7 + o * 13.1, s * k + o * 7.3, r * f + evo * 0.6 + o * 3.7)
					amp *= gain
					k *= 2
					f *= 2
				end
				buffer.writef32(grid, (j * NA + i - 1) * 4, v)
				sum += v
				sumSq += v * v
			end
			breathe()
		end
		local count = NA * NR
		local mean = sum / count
		local scale = contrast / math.sqrt(math.max(sumSq / count - mean * mean, 1e-9))

		-- 2) wrap it into the square picture: white, with the noise as the see-through-ness ("unmult")
		local rgba = buffer.create(pixels * 4)
		for p = 0, pixels - 1 do
			local q = p * 4
			local ac = buffer.readf32(angleAt, q)
			local rc = buffer.readf32(radiusAt, q)
			local a0 = math.floor(ac)
			local wa = ac - a0
			a0 %= NA
			local a1 = (a0 + 1) % NA
			local r0 = math.floor(rc)
			local wr = rc - r0
			local r1 = math.min(r0 + 1, NR - 1)
			local v0 = buffer.readf32(grid, (r0 * NA + a0) * 4) * (1 - wa) + buffer.readf32(grid, (r0 * NA + a1) * 4) * wa
			local v1 = buffer.readf32(grid, (r1 * NA + a0) * 4) * (1 - wa) + buffer.readf32(grid, (r1 * NA + a1) * 4) * wa
			local v = v0 + (v1 - v0) * wr
			local alpha = math.clamp(level + (v - mean) * scale, 0, 1) * buffer.readf32(maskAt, q)
			buffer.writeu32(rgba, q, 0x00FFFFFF + math.floor(alpha * 255 + 0.5) * 0x1000000) -- R, G, B = 255, A = alpha
			if p % 4096 == 0 then
				breathe()
			end
		end
		image:WritePixelsBuffer(Vector2.zero, Vector2.new(N, N), rgba)
		onPicture(Content.fromObject(image), image)
		breathe()
	end
end

function SpeedFX.new()
	local self = setmetatable({}, SpeedFX)
	local F = Config.SpeedFX
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild("SpeedFX")
	if old then
		old:Destroy()
	end
	-- DisplayOrder 0: drawn under the HUD
	local gui = make("ScreenGui", { Name = "SpeedFX", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 0 }, playerGui)
	self.Gui = gui
	self.Style = F.Style or "Noise"

	-- dark edge glow (vignette): four soft gradients from the screen edges, so the white streaks pop on bright snow
	self.Vignette = {}
	for _, side in ipairs({
		{ AnchorPoint = Vector2.new(0, 0), Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(0.22, 1), Rotation = 0 },
		{ AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromScale(0.22, 1), Rotation = 180 },
		{ AnchorPoint = Vector2.new(0, 0), Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(1, 0.26), Rotation = 90 },
		{ AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0.26), Rotation = 270 },
	}) do
		local frame = make("Frame", {
			Name = "EdgeGlow", AnchorPoint = side.AnchorPoint, Position = side.Position, Size = side.Size,
			BorderSizePixel = 0, BackgroundColor3 = F.VignetteColor, BackgroundTransparency = 1, ZIndex = 1, Visible = false,
		}, gui)
		make("UIGradient", {
			Rotation = side.Rotation,
			Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) }),
		}, frame)
		table.insert(self.Vignette, frame)
	end

	-- soft noise streaks: a few full-screen pictures, each flowing outward in turn so the wind never stops moving
	self.Streaks = {}
	self.Pictures = {}
	self.Clock = 0
	self.Sway = 0
	local layers = math.clamp(math.floor(F.NoiseLayers or 3), 2, 6)
	for i = 1, layers do
		local label = make("ImageLabel", {
			Name = "WindStreaks", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
			BackgroundTransparency = 1, ImageTransparency = 1, ImageColor3 = F.NoiseColor, ZIndex = 2, Visible = false,
		}, gui)
		table.insert(self.Streaks, { Label = label, Offset = (i - 1) / layers, Picture = 0 })
	end
	if self.Style == "Noise" then
		task.spawn(paintStreaks, F, function(content, image)
			table.insert(self.Pictures, { Content = content, Image = image })
		end, function(reason)
			warn("[SpeedFX] Couldn't make the noise streaks (" .. reason .. "), using the speed lines instead")
			self.Style = "Lines"
		end, function()
			return self.Gui.Parent ~= nil
		end)
	end

	-- sharp speed lines (Style "Lines"): thin, brightest at the screen edge, fading toward the middle
	self.Lines = {}
	for _ = 1, F.Lines do
		local frame = make("Frame", {
			Name = "SpeedLine", AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0,
			BackgroundColor3 = F.LineColor, BackgroundTransparency = 1, ZIndex = 3, Visible = false,
		}, gui)
		make("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.5, 0.55),
				NumberSequenceKeypoint.new(1, 0),
			}),
		}, frame)
		table.insert(self.Lines, { Frame = frame, Age = 1, Life = 0 })
	end

	-- soft wind wisps (Style "Lines"): wide, rounded, very see-through, drifting outward
	self.Wisps = {}
	for _ = 1, F.Wisps do
		local frame = make("Frame", {
			Name = "WindWisp", AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0,
			BackgroundColor3 = F.WispColor, BackgroundTransparency = 1, ZIndex = 2, Visible = false,
		}, gui)
		make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, frame)
		make("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.35, 0.25),
				NumberSequenceKeypoint.new(0.7, 0.35),
				NumberSequenceKeypoint.new(1, 1),
			}),
		}, frame)
		table.insert(self.Wisps, { Frame = frame, Age = 1, Life = 0 })
	end

	self.Strength = 0
	self.Burst = 0
	self.Accel = 0
	self.LastSpeed = nil
	self.Hidden = true
	return self
end

-- listen for boosts on the current rider
function SpeedFX:Attach(controller)
	self:Detach()
	self.BoostConnection = controller.Boosted.Event:Connect(function(kind)
		-- a sidewall boost gets a smaller burst than a boost pad (Config.WallBoost.FxShare)
		local share = kind == "Wall" and Config.WallBoost.FxShare or 1
		self.Burst = math.max(self.Burst, Config.SpeedFX.BoostBurst * share)
	end)
	self.LastSpeed = nil
end

function SpeedFX:Detach()
	if self.BoostConnection then
		self.BoostConnection:Disconnect()
		self.BoostConnection = nil
	end
end

function SpeedFX:HideAll()
	if self.Hidden then
		return
	end
	self.Hidden = true
	for _, frame in ipairs(self.Vignette) do
		frame.Visible = false
	end
	for _, layer in ipairs(self.Streaks) do
		layer.Label.Visible = false
	end
	for _, line in ipairs(self.Lines) do
		line.Frame.Visible = false
		line.Age, line.Life = 1, 0
	end
	for _, wisp in ipairs(self.Wisps) do
		wisp.Frame.Visible = false
		wisp.Age, wisp.Life = 1, 0
	end
end

-- the soft noise streaks: several layers, evenly staggered. Each one fades softly in near the middle, flows outward
-- (slowly at first, then faster, like wind rushing past), twists a little and fades out, then comes back as a
-- different picture at a new angle. Because they overlap, the flow is continuous instead of popping.
-- The whole tunnel also leans a little with your carving, so it feels attached to the ride.
function SpeedFX:UpdateStreaks(F, s, clear, dt, cx, cy, controller)
	local count = #self.Pictures
	if count == 0 then
		for _, layer in ipairs(self.Streaks) do
			layer.Label.Visible = false
		end
		return
	end
	local life = lerp(F.NoiseLifeSlow, F.NoiseLifeFast, s)
	self.Clock += dt / math.max(life, 0.05)
	-- lean the whole tunnel against your carving (smoothed), so it sways with the ride instead of sitting dead still
	local yaw = controller and controller.YawRate or 0
	self.Sway = damp(self.Sway, math.clamp(-yaw / 2.2, -1, 1) * F.NoiseSway, 4, dt)
	local centre = UDim2.fromScale(0.5 + self.Sway, 0.5)
	-- the picture is sized off the screen diagonal; at low strength it's bigger, so only the outer streaks show
	local diagonal = math.sqrt(cx * cx + cy * cy) * 2
	local spread = clear / math.max(F.ClearCenter, 0.05)
	-- the layers overlap, so each one is a bit see-through to keep the overall strength the same
	local opacity = F.NoiseOpacity * math.min(1, s * 1.3) * math.min(1, 2 / #self.Streaks)
	for _, layer in ipairs(self.Streaks) do
		local phase = self.Clock + layer.Offset
		local cycle = math.floor(phase)
		local u = phase - cycle
		if cycle ~= layer.Cycle then
			layer.Cycle = cycle
			-- a picture none of the other layers is showing, at a new angle
			local pick = rng:NextInteger(1, count)
			for _ = 1, 10 do
				local used = false
				for _, other in ipairs(self.Streaks) do
					if other ~= layer and other.Picture == pick then
						used = true
					end
				end
				if not used and pick ~= layer.Picture then
					break
				end
				pick = rng:NextInteger(1, count)
			end
			layer.Picture = pick
			layer.Label.ImageContent = self.Pictures[pick].Content
			layer.Rotation = rng:NextNumber(0, 360)
			layer.Spin = rng:NextNumber(-1, 1) * F.NoiseSpin
		end
		local fade = math.sin(math.pi * u) -- soft in, soft out
		local grow = F.NoiseZoomFrom + (F.NoiseZoomTo - F.NoiseZoomFrom) * u ^ F.NoiseZoomEase -- speeds up as it flies out
		local size = diagonal * spread * grow
		layer.Label.Position = centre
		layer.Label.Size = UDim2.fromOffset(size, size)
		layer.Label.Rotation = layer.Rotation + layer.Spin * u
		layer.Label.ImageTransparency = 1 - fade * opacity
		layer.Label.Visible = true
	end
end

-- call every frame (render step). controller can be nil (no rider): the effect fades out.
function SpeedFX:Update(controller, dt)
	local F = Config.SpeedFX
	dt = math.min(dt, 1 / 20)
	local speed = controller and controller.Speed or 0

	-- how strong: speed sets the base level, gaining speed swells it, boosts burst it
	local accel = self.LastSpeed and (speed - self.LastSpeed) / math.max(dt, 1e-3) or 0
	self.LastSpeed = speed
	self.Accel = damp(self.Accel, math.max(accel, 0), 4, dt)
	self.Burst = damp(self.Burst, 0, F.BurstFade, dt)
	local speedT = math.clamp((speed - F.StartSpeed) / math.max(F.FullSpeed - F.StartSpeed, 1), 0, 1)
	local accelT = math.clamp(self.Accel / F.AccelRef, 0, 1) * F.AccelBoost
	local target = speedT > 0 and math.clamp(speedT + accelT + self.Burst, 0, 1) or math.clamp(self.Burst, 0, 1)
	self.Strength = damp(self.Strength, target, F.Smoothing, dt)
	local s = self.Strength

	local size = self.Gui.AbsoluteSize
	local cx, cy = size.X / 2, size.Y / 2
	if s < 0.01 or cx < 1 then
		self:HideAll()
		return
	end
	self.Hidden = false
	local clear = lerp(F.ClearCenterLow, F.ClearCenter, s) -- middle of the screen kept clear (0 = centre, 1 = edge)

	-- dark edge glow grows with the effect
	for _, frame in ipairs(self.Vignette) do
		frame.BackgroundTransparency = 1 - F.Vignette * s
		frame.Visible = F.Vignette > 0
	end

	local lineCount, wispCount = #self.Lines, #self.Wisps
	if self.Style == "Noise" then
		self:UpdateStreaks(F, s, clear, dt, cx, cy, controller)
		-- plus a few sharp anime speed lines over the soft streaks, for an exaggerated sense of speed
		lineCount, wispCount = math.min(F.NoiseExtraLines or 0, #self.Lines), 0
	else
		for _, layer in ipairs(self.Streaks) do
			layer.Label.Visible = false
		end
	end

	local scale = size.Y / 1000 -- line thickness follows the screen size

	-- a point on a screen-shaped ellipse: k = 0 is the centre, k = 1 the screen edge
	local function point(angle, k)
		return Vector2.new(cx + math.cos(angle) * cx * k, cy + math.sin(angle) * cy * k)
	end
	local function place(frame, angle, kIn, kOut, width)
		local a, b = point(angle, kIn), point(angle, kOut)
		local d = b - a
		frame.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
		frame.Size = UDim2.fromOffset(d.Magnitude, width)
		frame.Rotation = math.deg(math.atan2(d.Y, d.X))
	end

	-- speed lines: flicker in at random angles; faster = more of them, reaching further in
	local activeLines = math.floor(lineCount * s + 0.5)
	for i, line in ipairs(self.Lines) do
		if i <= activeLines then
			line.Age += dt
			if line.Age >= line.Life then
				line.Age = 0
				line.Life = rng:NextNumber(F.LineLifeMin, F.LineLifeMax)
				line.Angle = rng:NextNumber(0, math.pi * 2)
				-- most lines are short and hug the edges, a few long ones reach in toward the clear middle
				local r = rng:NextNumber()
				line.Inner = clear + (1 - clear) * (1 - r * r) * 0.92
				line.Width = rng:NextNumber(F.LineWidthMin, F.LineWidthMax) * scale
				line.Peak = rng:NextNumber(0.5, 1)
			end
			local u = line.Age / line.Life
			local alpha = math.sin(math.pi * u) * line.Peak * F.LineOpacity * math.min(1, s * 1.5)
			place(line.Frame, line.Angle, line.Inner - u * 0.06, 1.25, line.Width) -- streaks in a touch
			line.Frame.BackgroundTransparency = 1 - alpha
			line.Frame.Visible = true
		else
			line.Frame.Visible = false
			line.Age, line.Life = 1, 0
		end
	end

	-- wind wisps: soft streaks in the outer band that rush outward, like air flying past
	local activeWisps = math.floor(wispCount * s + 0.5)
	for i, wisp in ipairs(self.Wisps) do
		if i <= activeWisps then
			wisp.Age += dt
			if wisp.Age >= wisp.Life then
				wisp.Age = 0
				wisp.Life = rng:NextNumber(F.WispLifeMin, F.WispLifeMax)
				wisp.Angle = rng:NextNumber(0, math.pi * 2)
				wisp.Start = rng:NextNumber(math.max(clear, 0.5), 0.9)
				wisp.Length = rng:NextNumber(0.25, 0.5)
				wisp.Width = rng:NextNumber(F.WispWidthMin, F.WispWidthMax) * scale
			end
			local u = wisp.Age / wisp.Life
			local kIn = wisp.Start + u * F.WispDrift
			local alpha = math.sin(math.pi * u) * F.WispOpacity * s
			place(wisp.Frame, wisp.Angle, kIn, kIn + wisp.Length, wisp.Width)
			wisp.Frame.BackgroundTransparency = 1 - alpha
			wisp.Frame.Visible = true
		else
			wisp.Frame.Visible = false
			wisp.Age, wisp.Life = 1, 0
		end
	end
end

function SpeedFX:Destroy()
	self:Detach()
	self.Gui:Destroy()
	for _, picture in ipairs(self.Pictures) do
		picture.Image:Destroy()
	end
	self.Pictures = {}
end

return SpeedFX
