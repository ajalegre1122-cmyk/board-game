--[[
	AbilityVFX (client): the visual effects for every character's 3 abilities.
	VFX ONLY for now: nothing here changes speed, stuns, swaps or cooldowns (that comes with the ability system).

	Where the effects come from
	  ReplicatedStorage.BoardAssets.SkillVFX  the ready-made effects (made with Part-Icles): one folder per character,
	                                          each with a demo dummy showing where every effect sits on the body
	  ReplicatedStorage.Part_Icles            plays those effects (timings, size curves, mesh particles, beams)
	  Built here (no ready-made effect): Sharingan eyes + rings, Deku's green Full Cowl aura, the kunai and Dio's
	  knives, the Rasen Shuriken's flight, Za Warudo's grey screen and 500 IQ's gold glow.

	Effects sit on the rider where they sit on the dummy (RasenCharge on the right arm, the clap in front of you...)
	and ride along with you at full speed. Thrown things fly ahead faster than you're riding and auto-aim at
	the closest dummy or other rider in front of you (who gets the stun-hit effect). The two ultimates (500 IQ, Za Warudo)
	play their camera-rig cutscene for a moment.

	API
	  local vfx = AbilityVFX.new()
	  vfx:Play(characterId, slot, rider)    rider = { Character = model, Controller = controller }
	  Another player's ability (passed on by the server): rider = { Character = theirs, Remote = true }. Same effects on
	  their rider, but their cutscene never takes your camera and Za Warudo's grey screen is off (RemoteScreenEffects).
	Tuning: Config.AbilityVFX, plus each ability's Duration in Config.Abilities.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local BoardRig = require(script.Parent:WaitForChild("BoardRig"))

local Config = require(script.Parent:WaitForChild("Config"))

local AbilityVFX = {}
AbilityVFX.__index = AbilityVFX

local ORANGE = Color3.fromRGB(255, 150, 40)
local GREEN = Color3.fromRGB(70, 255, 140)
local RED = Color3.fromRGB(255, 30, 45)
local GOLD = Color3.fromRGB(255, 200, 60)
local WHITE = Color3.new(1, 1, 1)
local RING = "rbxassetid://12444217105" -- shockwave ring texture (the one the SkillVFX effects use)
local SPARK = "rbxasset://textures/particles/sparkles_main.dds"

local R15 = { -- R6 limb -> closest R15 part, in case the rider is R15
	Torso = "UpperTorso", ["Right Arm"] = "RightHand", ["Left Arm"] = "LeftHand",
	["Right Leg"] = "RightFoot", ["Left Leg"] = "LeftFoot",
}

local function settings()
	return Config.AbilityVFX or {}
end

local function limbOf(character, name)
	if not character then return nil end
	return character:FindFirstChild(name) or (R15[name] and character:FindFirstChild(R15[name]))
end

local function abilityOf(characterId, slot)
	for _, character in ipairs((Config.Abilities and Config.Abilities.Characters) or {}) do
		if character.Id == characterId then return character[slot] end
	end
	return nil
end

-- ready-made effects ------------------------------------------------------------------------------------------

local skillFolder
-- effects are visuals only: some of the authored effect parts are solid (CanCollide / CanQuery on), and the emitted
-- copies would block the rider and count as walls for the board's rays. Switched off on this client's copy, once each.
local madeVisual = setmetatable({}, { __mode = "k" })
local function visualOnly(node)
	if madeVisual[node] then return end
	madeVisual[node] = true
	local parts = node:GetDescendants()
	table.insert(parts, node)
	for _, d in ipairs(parts) do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
end

local function template(path)
	skillFolder = skillFolder or ReplicatedStorage:WaitForChild("BoardAssets"):WaitForChild("SkillVFX")
	local node = skillFolder
	for name in path:gmatch("[^/]+") do
		node = node and node:FindFirstChild(name)
	end
	if not node then warn("[AbilityVFX] Missing effect: SkillVFX/" .. path) return nil end
	visualOnly(node)
	return node
end

-- the demo dummy next to an effect (same folder or a parent folder)
local function dummyOf(item)
	local folder = item.Parent
	while folder and folder ~= skillFolder do
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Model") and child:FindFirstChildOfClass("Humanoid") then return child end
		end
		folder = folder.Parent
	end
	return nil
end

-- where an effect sits on its dummy, relative to one of the dummy's limbs
local offsets = {}
local function dummyOffset(item, limbName)
	local key = item:GetFullName() .. "|" .. limbName
	if offsets[key] then return offsets[key] end
	local dummy = dummyOf(item)
	local limb = dummy and dummy:FindFirstChild(limbName)
	local offset = CFrame.identity
	if limb and item:IsA("PVInstance") then offset = limb.CFrame:ToObjectSpace(item:GetPivot()) end
	offsets[key] = offset
	return offset
end

-- a copy of an effect whose particles stay with it as it moves (otherwise at 60 mph they'd be left behind).
-- Lives on your screen only while playing, never saved.
local cache
local lockedCopies = {}
local function lockedCopy(item)
	local copy = lockedCopies[item]
	if copy and copy.Parent then return copy end
	if not cache then
		cache = Instance.new("Folder")
		cache.Name = "AbilityVFXCache"
		cache.Parent = ReplicatedStorage
	end
	copy = item:Clone()
	for _, d in ipairs(copy:GetDescendants()) do
		if d:IsA("ParticleEmitter") then d.LockedToPart = true end
	end
	copy.Parent = cache
	lockedCopies[item] = copy
	return copy
end

-- Effects that travel with a moving rider. Part-Icles leaves an effect's plain ParticleEmitters / Trails / Beams
-- on a copy anchored where the effect started, so at riding speed a burst (Todo's clap, Deku's dash...) was left
-- behind. Each effect is split once on this client (never saved): its plain emitters ride a copy welded to the
-- limb (locked to it), and only its Part-Icles pieces (marked Transformed) go through the engine, linked to the limb.
local split = {}

-- frozen models (someone's Za Warudo): model -> os.clock() when time moves again for it
local frozenUntil = setmetatable({}, { __mode = "k" })
-- effect copies welded onto someone from outside their model (rideOn, HoldOn): copy -> the limb it's on
local attached = setmetatable({}, { __mode = "k" })

-- a model's instances without its saved animations: the dummies each carry an AnimSaves with ~11,000 keyframes / poses,
-- and looking through all of that is what made Za Warudo hitch (it froze ~19 dummies)
local SKIP_CLASSES = { ObjectValue = true, KeyframeSequence = true, Keyframe = true, Pose = true }
local function lightDescendants(model)
	local list = {}
	local function walk(node)
		for _, child in ipairs(node:GetChildren()) do
			if not SKIP_CLASSES[child.ClassName] then
				table.insert(list, child)
				walk(child)
			end
		end
	end
	walk(model)
	return list
end

-- seconds before time moves again for whatever `part` belongs to (0 = not frozen)
local function frozenLeftOf(part)
	local model = part and part:FindFirstAncestorOfClass("Model")
	while model do
		local t = frozenUntil[model]
		if t then return math.max(t - os.clock(), 0) end
		model = model.Parent and model.Parent:FindFirstAncestorOfClass("Model")
	end
	return 0
end

local function cacheFolder()
	if not (cache and cache.Parent) then
		cache = Instance.new("Folder")
		cache.Name = "AbilityVFXCache"
		cache.Parent = ReplicatedStorage
	end
	return cache
end

local function isPlainEmitter(d)
	return (d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam")) and not d:GetAttribute("Transformed")
end

-- Part-Icles pieces with no place in the world (a screen GUI like the ScreenVign, a light): played at an origin the engine
-- can only play them where they sit (in a cache, where nothing shows) and warns, so effects played that way leave them out
local function placeless(d)
	return d:GetAttribute("Transformed") and (d:IsA("GuiObject") or d:IsA("Light"))
end

-- an effect without its placeless pieces (a copy made once, only if it has any)
local placed = {}
local function withoutPlaceless(item)
	local copy = placed[item]
	if copy and copy.Parent then return copy end
	local any = false
	for _, d in ipairs(item:GetDescendants()) do
		if placeless(d) then any = true break end
	end
	if not any then return item end
	copy = item:Clone()
	local drop = {}
	for _, d in ipairs(copy:GetDescendants()) do
		if placeless(d) then table.insert(drop, d) end
	end
	for _, d in ipairs(drop) do d:Destroy() end
	if not (cache and cache.Parent) then
		cache = Instance.new("Folder")
		cache.Name = "AbilityVFXCache"
		cache.Parent = ReplicatedStorage
	end
	copy.Name = item.Name .. "_Placed"
	copy.Parent = cache
	placed[item] = copy
	return copy
end

local function underTransformed(d, root)
	local p = d.Parent
	while p and p ~= root do
		if p:GetAttribute("Transformed") then return true end
		p = p.Parent
	end
	return false
end

local function splitEffect(item)
	local s = split[item]
	if s and (not s.raw or s.raw.Parent) and (not s.linked or s.linked.Parent) then return s end
	s = {}
	if item:GetAttribute("Transformed") then
		s.linked = item -- all Part-Icles: the engine moves it with the limb
	else
		-- plain half: no Part-Icles pieces, no joints (each part gets its own weld to the limb)
		local raw = item:Clone()
		local drop, emitters = {}, 0
		for _, d in ipairs(raw:GetDescendants()) do
			if d:GetAttribute("Transformed") or d:IsA("JointInstance") or d:IsA("WeldConstraint") then
				table.insert(drop, d)
			elseif isPlainEmitter(d) and not underTransformed(d, raw) then
				emitters += 1
				if d:IsA("ParticleEmitter") then d.LockedToPart = true end
			end
		end
		for _, d in ipairs(drop) do d:Destroy() end
		if emitters > 0 then
			raw.Name = item.Name .. "_Plain"
			raw.Parent = cacheFolder()
			s.raw = raw
		else
			raw:Destroy()
		end
		-- Part-Icles half: no plain emitters, so the engine has nothing left to anchor behind. Screen pieces (an
		-- ImageLabel like the 500 IQ ScreenVign) are left out: they have no place in the world to follow, and the
		-- rider's own screen gets them separately (ScreenFlipbook)
		local hasTransformed = false
		for _, d in ipairs(item:GetDescendants()) do
			if d:GetAttribute("Transformed") and not placeless(d) then hasTransformed = true break end
		end
		if hasTransformed then
			local linked = item:Clone()
			local drop2 = {}
			for _, d in ipairs(linked:GetDescendants()) do
				if (isPlainEmitter(d) and not underTransformed(d, linked)) or placeless(d) then
					table.insert(drop2, d)
				end
			end
			for _, d in ipairs(drop2) do d:Destroy() end
			linked.Name = item.Name .. "_Linked"
			linked.Parent = cacheFolder()
			s.linked = linked
		end
	end
	split[item] = s
	return s
end

-- the plain half of an effect on a copy welded to the limb (`offset` = where the effect's pivot sits relative to
-- the limb), so the whole burst travels with the rider until its particles fade
local function rideOn(engine, raw, limb, offset)
	if not limb.Parent then return end
	local copy = raw:Clone()
	local pivot = raw:GetPivot()
	local parts = copy:GetDescendants()
	table.insert(parts, copy)
	local welds = {}
	for _, p in ipairs(parts) do
		if p:IsA("BasePart") then table.insert(welds, { p, offset * pivot:ToObjectSpace(p.CFrame) }) end
	end
	for _, w in ipairs(welds) do
		local p, c0 = w[1], w[2]
		p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.Massless = false, false, false, false, true
		p.CFrame = limb.CFrame * c0
		local weld = Instance.new("Weld")
		weld.Name = "RideOn"
		weld.Part0 = limb
		weld.Part1 = p
		weld.C0 = c0
		weld.Parent = p
	end
	copy.Name = "AbilityRide_" .. raw.Name
	copy.Parent = workspace
	attached[copy] = limb
	local duration = engine:AbsoluteEmit(copy)
	-- played on someone frozen (Za Warudo): it hangs there with them until time moves again
	local hold = frozenLeftOf(limb)
	if hold > 0 then
		local scales = {}
		for _, d in ipairs(copy:GetDescendants()) do
			if d:IsA("ParticleEmitter") then
				scales[d] = d.TimeScale
				d.TimeScale = 0
			end
		end
		task.delay(hold, function()
			for d, s in pairs(scales) do
				if d.Parent then d.TimeScale = s end
			end
		end)
	end
	task.delay(math.min(duration or 10, 20) + 0.5 + hold, function() copy:Destroy() end)
end

-- plays an effect at `origin`, travelling with `limb` from then on
local function emitFollowing(engine, item, origin, limb)
	local s = splitEffect(item)
	-- each half on its own thread so a long effect never holds up the rest of the ability's effects
	if s.raw then task.spawn(rideOn, engine, s.raw, limb, limb.CFrame:ToObjectSpace(origin)) end
	if s.linked then task.spawn(function() engine:AbsoluteEmitAt(s.linked, origin, { Link = limb }) end) end
end

local function retint(sequence, tint)
	local hue = tint:ToHSV()
	local points = {}
	for _, k in ipairs(sequence.Keypoints) do
		local _, s, v = k.Value:ToHSV()
		table.insert(points, ColorSequenceKeypoint.new(k.Time, Color3.fromHSV(hue, s, v)))
	end
	return ColorSequence.new(points)
end

-- small helpers -------------------------------------------------------------------------------------------------

local function newPart(class, props)
	local p = Instance.new(class)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in pairs(props) do p[k] = v end
	return p
end

local function weldTo(part, limb)
	part.Anchored = false
	part.Massless = true
	local w = Instance.new("WeldConstraint")
	w.Part0 = limb
	w.Part1 = part
	w.Parent = part
end

-- the rider's position facing the way the board points (no lean)
local function flatFrame(rider)
	local root = rider.Character and rider.Character:FindFirstChild("HumanoidRootPart")
	if not root then return CFrame.identity end
	local h = (rider.Controller and rider.Controller.Heading) or root.CFrame.LookVector
	local flat = Vector3.new(h.X, 0, h.Z)
	if flat.Magnitude < 1e-3 then flat = Vector3.new(0, 0, -1) end
	return CFrame.lookAt(root.Position, root.Position + flat.Unit)
end

-- the way the rider is travelling (follows the slope) and how fast
local function travel(rider)
	local c = rider.Controller
	local root = rider.Character and rider.Character:FindFirstChild("HumanoidRootPart")
	-- another rider (no controller on this client): their root's velocity, which everyone can see
	local v = (c and c.Velocity) or (root and root.AssemblyLinearVelocity) or Vector3.zero
	if v.Magnitude > 5 then return v.Unit, v.Magnitude end
	local h = (c and c.Heading) or rider.Character.HumanoidRootPart.CFrame.LookVector
	return h.Unit, 0
end

local function fadeAway(model, time)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			TweenService:Create(d, TweenInfo.new(time), { Transparency = 1 }):Play()
		elseif d:IsA("Trail") or d:IsA("ParticleEmitter") or d:IsA("Beam") then
			d.Enabled = false
		elseif d:IsA("PointLight") then
			TweenService:Create(d, TweenInfo.new(time), { Brightness = 0 }):Play()
		end
	end
	task.delay(time + 0.4, function() model:Destroy() end)
end

-- kunai / knife, made of parts (points along -Z)
local BLADES = {
	Kunai = { scale = 1, blade = Color3.fromRGB(70, 74, 82), handle = Color3.fromRGB(25, 25, 28), trail = ORANGE, shine = 0.05 },
	Knife = { scale = 1.35, blade = Color3.fromRGB(215, 220, 230), handle = Color3.fromRGB(190, 140, 40), trail = GOLD, shine = 0.3 },
}
local function makeBlade(kind)
	local s = BLADES[kind] or BLADES.Kunai
	local k = s.scale
	local model = Instance.new("Model")
	model.Name = "Ability" .. kind
	local core = newPart("Part", { Name = "Blade", Size = Vector3.new(0.07, 0.34, 0.7) * k, Color = s.blade, Material = Enum.Material.Metal, Reflectance = s.shine })
	core.CFrame = CFrame.new(0, 0, -0.25 * k)
	core.Parent = model
	local tipTop = newPart("WedgePart", { Name = "Tip", Size = Vector3.new(0.07, 0.17, 0.5) * k, Color = s.blade, Material = Enum.Material.Metal, Reflectance = s.shine })
	tipTop.CFrame = CFrame.new(0, 0.085 * k, -0.85 * k)
	tipTop.Parent = model
	local tipBottom = tipTop:Clone()
	tipBottom.CFrame = CFrame.new(0, -0.085 * k, -0.85 * k) * CFrame.Angles(0, 0, math.pi)
	tipBottom.Parent = model
	local handle = newPart("Part", { Name = "Handle", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.85, 0.18, 0.18) * k, Color = s.handle, Material = Enum.Material.SmoothPlastic })
	handle.CFrame = CFrame.new(0, 0, 0.52 * k) * CFrame.Angles(0, math.pi / 2, 0)
	handle.Parent = model
	model.PrimaryPart = core
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 0.2 * k, 0.6 * k)
	a0.Parent = core
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -0.2 * k, 0.6 * k)
	a1.Parent = core
	local trail = Instance.new("Trail")
	trail.Attachment0, trail.Attachment1 = a0, a1
	trail.Lifetime = 0.18
	trail.LightEmission = 1
	trail.FaceCamera = true
	trail.Color = ColorSequence.new(s.trail)
	trail.Transparency = NumberSequence.new(0.1, 1)
	trail.Parent = core
	local light = Instance.new("PointLight")
	light.Color = s.trail
	light.Range = 6
	light.Brightness = 1.5
	light.Parent = core
	return model
end

-- the class -------------------------------------------------------------------------------------------------------

function AbilityVFX.new()
	local self = setmetatable({}, AbilityVFX)
	local folder = ReplicatedStorage:WaitForChild("Part_Icles", 10)
	local ok, engine = pcall(function() return folder and require(folder) end)
	if ok and engine then
		self.Engine = engine
		if not engine.Connection then engine:Activate() end
	else
		warn("[AbilityVFX] Part_Icles not found / failed to load: only the hand-made effects will play. " .. tostring(engine))
	end
	self.InCutscene = false
	self:StartAiming() -- start keeping the list of dummies / riders to aim at
	return self
end

-- runs fn after `seconds` without letting an error stop the other effects
function AbilityVFX:After(seconds, fn)
	task.delay(seconds, function()
		local ok, err = pcall(fn)
		if not ok then warn("[AbilityVFX] " .. tostring(err)) end
	end)
end

-- plays a ready-made effect where it sits on its dummy, on the same limb of the rider.
-- follow = true (default): rides along with you; false: stays where it was played (left behind).
-- facing (optional direction): turn the effect to face that way, e.g. at the target you're throwing at
function AbilityVFX:EmitOn(character, path, limbName, follow, facing)
	local item = template(path)
	local limb = limbOf(character, limbName)
	if not (item and limb and self.Engine) then return end
	local base = limb.CFrame
	if facing and Vector3.new(facing.X, 0, facing.Z).Magnitude > 0.01 then
		local flat = Vector3.new(facing.X, 0, facing.Z).Unit
		base = CFrame.lookAt(limb.Position, limb.Position + flat)
	end
	local origin = base * dummyOffset(item, limbName)
	local engine = self.Engine
	if follow == false then
		-- stays where it started (started on its own thread so a long effect never holds up the rest)
		local played = withoutPlaceless(item)
		task.spawn(function() engine:AbsoluteEmitAt(played, origin) end)
	else
		emitFollowing(engine, item, origin, limb)
	end
end

-- plays a ready-made effect at a spot in the world
function AbilityVFX:EmitAt(path, cframe)
	local item = template(path)
	if not (item and self.Engine) then return end
	local engine = self.Engine
	task.spawn(function() engine:AbsoluteEmitAt(item, cframe) end)
end

-- the authored white flash over the whole character (the dummies' "...Start" highlights)
function AbilityVFX:Flash(character, path)
	local hl = template(path)
	if hl and self.Engine and character then
		local engine = self.Engine
		task.spawn(function() pcall(function() engine:EnableEmit(hl, character) end) end)
	end
end

-- a coloured flash over the character that fades out
function AbilityVFX:Glow(model, color, time, fill)
	if not model then return end
	local h = Instance.new("Highlight")
	h.Name = "AbilityGlow"
	h.FillColor, h.OutlineColor = color, color
	h.FillTransparency = 1 - (fill or 0.6)
	h.OutlineTransparency = 0
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Adornee = model
	h.Parent = model
	local tween = TweenService:Create(h, TweenInfo.new(time or 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { FillTransparency = 1, OutlineTransparency = 1 })
	tween.Completed:Once(function() h:Destroy() end)
	tween:Play()
	task.delay((time or 0.4) + 0.3, function() if h.Parent then h:Destroy() end end) -- never left on
end

-- a pulsing coloured outline for `duration` seconds (a buff that's active)
function AbilityVFX:Outline(model, color, duration)
	if not model then return end
	local h = Instance.new("Highlight")
	h.Name = "AbilityOutline"
	h.FillColor, h.OutlineColor = color, color
	h.FillTransparency = 0.88
	h.OutlineTransparency = 0.2
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Adornee = model
	h.Parent = model
	local t0 = os.clock()
	local conn
	conn = RunService.RenderStepped:Connect(function()
		if not h.Parent then conn:Disconnect() return end
		local t = os.clock() - t0
		if t >= duration then
			conn:Disconnect()
			local tween = TweenService:Create(h, TweenInfo.new(0.35), { FillTransparency = 1, OutlineTransparency = 1 })
			tween.Completed:Once(function() h:Destroy() end)
			tween:Play()
			task.delay(0.6, function() if h.Parent then h:Destroy() end end)
			return
		end
		h.OutlineTransparency = 0.1 + 0.4 * (0.5 + 0.5 * math.sin(t * 7))
	end)
end

-- a quick ring / flash burst that stays on `part`
function AbilityVFX:Burst(part, texture, color, size, life, glow)
	if not part then return end
	local a = Instance.new("Attachment")
	a.Name = "AbilityBurst"
	a.Parent = part
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = texture
	pe.Color = ColorSequence.new(color)
	pe.LightEmission = glow == false and 0 or (glow == true and 1 or 0.35) -- not fully additive by default, so the colour still shows on white snow
	pe.Lifetime = NumberRange.new(life)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size * 0.15), NumberSequenceKeypoint.new(1, size) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(1, 1) })
	pe.Speed = NumberRange.new(0)
	pe.Rate = 0
	pe.LockedToPart = true
	pe.Enabled = false
	pe.Parent = a
	pe:Emit(1)
	task.delay(life + 0.3, function() a:Destroy() end)
end

-- the stun-hit effect on someone who got hit
-- a lasting effect held on a limb (Chidori's lightning on the hand): one copy welded where it sits on the effect's
-- dummy, its particles following the limb and emitting the whole time, then fading out after `duration`
function AbilityVFX:HoldOn(character, path, limbName, duration)
	local item = template(path)
	local limb = limbOf(character, limbName)
	if not (item and limb and item:IsA("BasePart")) then return nil end
	local copy = item:Clone()
	for _, d in ipairs(copy:GetDescendants()) do
		if d:IsA("JointInstance") or d:IsA("WeldConstraint") then
			d:Destroy()
		elseif d:IsA("BasePart") and d:FindFirstChild("PartIcleProperties") then
			d:Destroy() -- Part-Icles mesh flipbooks: emitted separately (EmitFlipbooks)
		end
	end
	local emitters = {}
	for _, d in ipairs(copy:GetDescendants()) do
		if d:IsA("ParticleEmitter") then
			d.LockedToPart = true -- stays on the hand at full speed
			d.Enabled = true
			table.insert(emitters, d)
		elseif d:IsA("Beam") or d:IsA("Trail") or d:IsA("Light") then
			d.Enabled = true
		end
	end
	copy.Anchored, copy.CanCollide, copy.CanQuery, copy.CanTouch, copy.Massless = false, false, false, false, true
	copy.Transparency = 1
	copy.Name = "AbilityHeld_" .. item.Name
	local weld = Instance.new("Weld")
	weld.Name = "HeldOn"
	weld.Part0 = limb
	weld.Part1 = copy
	weld.C0 = dummyOffset(item, limbName)
	weld.Parent = copy
	copy.Parent = workspace
	attached[copy] = limb
	local function stop()
		for _, pe in ipairs(emitters) do pe.Enabled = false end
		task.delay(0.7, function() copy:Destroy() end)
	end
	self:After(duration, stop)
	task.delay(duration + 2, function() if copy.Parent then copy:Destroy() end end) -- never left behind
	return copy, stop
end

-- abilities that can end early (Chidori when it hits): the server says "Ended" and EndAbility finishes it on that rider
function AbilityVFX:SetActive(character, characterId, slot, finish)
	self.Active = self.Active or setmetatable({}, { __mode = "k" })
	self.Active[character] = self.Active[character] or {}
	self.Active[character][characterId .. "/" .. slot] = finish
end

function AbilityVFX:EndAbility(character, characterId, slot, hit)
	local list = self.Active and self.Active[character]
	local key = characterId .. "/" .. slot
	local finish = list and list[key]
	if finish then
		list[key] = nil
		local ok, err = pcall(finish, hit)
		if not ok then warn("[AbilityVFX] ending " .. key .. ": " .. tostring(err)) end
	end
end

-- just the Part-Icles mesh flipbooks of an effect (no particle emitters), on a limb
local flipCopies = {}
function AbilityVFX:EmitFlipbooks(character, path, limbName)
	local item = template(path)
	local limb = limbOf(character, limbName)
	if not (item and limb and self.Engine) then return end
	local copy = flipCopies[item]
	if not (copy and copy.Parent) then
		copy = lockedCopy(item):Clone()
		for _, d in ipairs(copy:GetDescendants()) do
			if d:IsA("ParticleEmitter") or d:IsA("Beam") then d:Destroy() end
		end
		copy.Name = item.Name .. "_Flipbooks"
		copy.Parent = cache
		flipCopies[item] = copy
	end
	local origin = limb.CFrame * dummyOffset(item, limbName)
	local engine = self.Engine
	task.spawn(function() engine:AbsoluteEmitAt(copy, origin, { Link = limb }) end)
end

-- Sharingan Copy: the Sharingan flashes on your screen for `duration` seconds (a spinning eye with three tomoe over a
-- red wash). Screen only; Lighting isn't touched
function AbilityVFX:SharinganScreen(duration)
	if settings().ScreenEffects == false then return end
	duration = duration or 1
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then return end
	local old = playerGui:FindFirstChild("AbilitySharingan")
	if old then old:Destroy() end
	local gui = Instance.new("ScreenGui")
	gui.Name = "AbilitySharingan"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 3
	gui.ResetOnSpawn = false
	local fades = {} -- { object, property, shown value }
	local function circle(parent, size, color, z)
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(0.5, 0.5)
		f.Size = UDim2.fromScale(size, size)
		f.BackgroundColor3 = color
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.ZIndex = z
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = f
		f.Parent = parent
		table.insert(fades, { f, "BackgroundTransparency", 0 })
		return f
	end
	local wash = Instance.new("Frame")
	wash.Size = UDim2.fromScale(1, 1)
	wash.BackgroundColor3 = Color3.fromRGB(120, 0, 0)
	wash.BackgroundTransparency = 1
	wash.BorderSizePixel = 0
	wash.Parent = gui
	table.insert(fades, { wash, "BackgroundTransparency", 0.72 })
	local eye = Instance.new("Frame")
	eye.AnchorPoint = Vector2.new(0.5, 0.5)
	eye.Position = UDim2.fromScale(0.5, 0.5)
	eye.Size = UDim2.fromScale(0.36, 0.36)
	eye.BackgroundTransparency = 1
	eye.ZIndex = 2
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.DominantAxis = Enum.DominantAxis.Height
	ratio.Parent = eye
	eye.Parent = gui
	local iris = circle(eye, 1, Color3.fromRGB(205, 12, 22), 2)
	local rim = Instance.new("UIStroke")
	rim.Color = Color3.new(0, 0, 0)
	rim.Thickness = 5
	rim.Transparency = 1
	rim.Parent = iris
	table.insert(fades, { rim, "Transparency", 0 })
	local ring = circle(eye, 0.58, Color3.fromRGB(205, 12, 22), 3)
	local ringLine = Instance.new("UIStroke")
	ringLine.Color = Color3.fromRGB(70, 0, 0)
	ringLine.Thickness = 2
	ringLine.Transparency = 1
	ringLine.Parent = ring
	table.insert(fades, { ringLine, "Transparency", 0.2 })
	circle(eye, 0.2, Color3.new(0, 0, 0), 5) -- pupil
	local spinner = Instance.new("Frame")
	spinner.AnchorPoint = Vector2.new(0.5, 0.5)
	spinner.Position = UDim2.fromScale(0.5, 0.5)
	spinner.Size = UDim2.fromScale(1, 1)
	spinner.BackgroundTransparency = 1
	spinner.ZIndex = 4
	spinner.Parent = eye
	for i = 0, 2 do -- the three tomoe, on the inner ring
		local angle = math.rad(i * 120)
		local dot = circle(spinner, 0.15, Color3.new(0, 0, 0), 4)
		dot.Position = UDim2.fromScale(0.5 + math.sin(angle) * 0.29, 0.5 - math.cos(angle) * 0.29)
		local tail = circle(dot, 0.55, Color3.new(0, 0, 0), 4) -- a little tail, so they read as commas
		tail.Position = UDim2.fromScale(0.95, 0.15)
	end
	gui.Parent = playerGui
	for _, f in ipairs(fades) do
		TweenService:Create(f[1], TweenInfo.new(0.12), { [f[2]] = f[3] }):Play()
	end
	TweenService:Create(eye, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromScale(0.44, 0.44) }):Play()
	TweenService:Create(spinner, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Rotation = 300 }):Play()
	self:After(math.max(duration - 0.35, 0.1), function()
		for _, f in ipairs(fades) do
			TweenService:Create(f[1], TweenInfo.new(0.35), { [f[2]] = 1 }):Play()
		end
	end)
	task.delay(duration + 0.5, function() gui:Destroy() end) -- never left on screen
end

-- someone dodged a hit (Sharingan): a red flash and ring instead of the stun-hit
function AbilityVFX:ShowDodge(model)
	if not (model and model.Parent) then return end
	self.LastDodge = self.LastDodge or setmetatable({}, { __mode = "k" })
	if self.LastDodge[model] and os.clock() - self.LastDodge[model] < 0.3 then return end
	self.LastDodge[model] = os.clock()
	local root = model:FindFirstChild("HumanoidRootPart")
	self:Glow(model, RED, 0.3, 0.6)
	if root then
		self:Burst(root, RING, RED, 12, 0.3)
		self:After(0.08, function() self:Burst(root, RING, Color3.fromRGB(25, 0, 0), 9, 0.3, false) end)
	end
end

function AbilityVFX:Hit(targetRoot, ultimate)
	-- dodging (Sharingan dodges basic moves, not ultimates): no stun-hit burst
	local model = targetRoot and targetRoot.Parent
	if not ultimate and model and self.Dodging and self.Dodging[model] and os.clock() < self.Dodging[model] then
		self:ShowDodge(model)
		return
	end
	local item = template("StunVFX/Stunhit")
	if item and self.Engine and targetRoot and targetRoot.Parent then
		local engine = self.Engine
		emitFollowing(engine, item, targetRoot.CFrame, targetRoot)
	end
	-- the stun / slow itself (and its animation) comes from the server when it confirms the hit: ShowHit
end

-- what abilities auto-aim at: any dummy / NPC / other player (a model with a Humanoid), plus anything tagged
-- "AbilityTarget". Tag a model "IgnoreAbilities" to leave it out. Kept in a list as models appear and disappear,
-- so aiming never has to search the whole map.
local aimables = {}
local watching = false
local function watchAimables()
	if watching then return end
	watching = true
	local function added(d)
		if d:IsA("Humanoid") and d.Parent and d.Parent:IsA("Model") then aimables[d.Parent] = true end
	end
	workspace.DescendantAdded:Connect(added)
	workspace.DescendantRemoving:Connect(function(d)
		if d:IsA("Humanoid") and d.Parent then aimables[d.Parent] = nil end
	end)
	task.defer(function()
		for _, d in ipairs(workspace:GetDescendants()) do added(d) end
	end)
end

function AbilityVFX:StartAiming()
	watchAimables()
end

-- the closest dummy / rider within `range` (and in front of you, within Config.AbilityVFX.AimCone, when `ahead`)
function AbilityVFX:FindTarget(rider, range, ahead)
	watchAimables()
	local me = rider.Character
	local myRoot = me and me:FindFirstChild("HumanoidRootPart")
	if not myRoot then return nil end
	local forward = travel(rider)
	local cone = math.cos(math.rad(settings().AimCone or 70))
	local best, bestDistance
	local function consider(model)
		if not model or not model.Parent or model == me or model:IsDescendantOf(me) then return end
		if CollectionService:HasTag(model, "IgnoreAbilities") then return end
		local parentModel = model.Parent:IsA("Model") and model.Parent
		if parentModel and parentModel:FindFirstChildOfClass("Humanoid") then return end -- a board rig on someone: aim at the someone
		local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
		if not (root and root:IsA("BasePart") and root:IsDescendantOf(workspace)) then return end
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health <= 0 then return end
		local offset = root.Position - myRoot.Position
		local distance = offset.Magnitude
		if distance > range then return end
		if ahead and distance > 1 and offset.Unit:Dot(forward) < cone then return end
		if not bestDistance or distance < bestDistance then best, bestDistance = root, distance end
	end
	for model in pairs(aimables) do consider(model) end
	for _, model in ipairs(CollectionService:GetTagged("AbilityTarget")) do consider(model) end
	return best
end

-- chakra aura on the whole body for `duration` seconds (Naruto's, or recoloured with `tint`)
local AURA_LIMBS = { TorsoAura = "Torso", ["LeftArm Aura"] = "Left Arm", ["RightArm Aura"] = "Right Arm", ["LeftLeg Aura"] = "Left Leg", ["RightLeg Aura"] = "Right Leg" }
function AbilityVFX:Aura(character, duration, tint)
	local src = template("Naruto/NarutoAuraz/Auraaa")
	if not (src and character) then return end
	local aura = src:Clone()
	aura.Name = "AbilityAura"
	for _, part in ipairs(aura:GetChildren()) do
		if part:IsA("BasePart") then
			local limb = limbOf(character, AURA_LIMBS[part.Name] or "Torso")
			if limb then
				part.CanCollide, part.CanQuery, part.CanTouch, part.CastShadow = false, false, false, false
				part.CFrame = limb.CFrame
				weldTo(part, limb)
			else
				part:Destroy()
			end
		end
	end
	for _, pe in ipairs(aura:GetDescendants()) do
		if pe:IsA("ParticleEmitter") then
			pe.LockedToPart = not settings().AuraTrail
			if tint then pe.Color = retint(pe.Color, tint) end
			pe.Enabled = true
		end
	end
	aura.Parent = character
	self:After(duration, function()
		for _, pe in ipairs(aura:GetDescendants()) do
			if pe:IsA("ParticleEmitter") then pe.Enabled = false end
		end
		task.wait(1.2)
		aura:Destroy()
	end)
end

-- glowing red Sharingan eyes for `duration` seconds. The chase camera sees the back of your head, so the eyes
-- also stream red light trails back past it, and you get a pulsing red outline while it's on
function AbilityVFX:Sharingan(character, duration)
	local head = character and character:FindFirstChild("Head")
	if not head then return end
	self:Outline(character, RED, duration)
	for _, x in ipairs({ -0.22, 0.22 }) do
		local eye = newPart("Part", { Name = "SharinganEye", Shape = Enum.PartType.Ball, Size = Vector3.new(0.2, 0.2, 0.2), Material = Enum.Material.Neon, Color = RED })
		eye.CFrame = head.CFrame * CFrame.new(x, 0.12, -0.46)
		weldTo(eye, head)
		local light = Instance.new("PointLight")
		light.Color, light.Range, light.Brightness = RED, 3, 2
		light.Parent = eye
		local streak = Instance.new("ParticleEmitter")
		streak.Texture = SPARK
		streak.Color = ColorSequence.new(RED)
		streak.LightEmission = 1
		streak.Lifetime = NumberRange.new(0.45)
		streak.Rate = 70
		streak.Speed = NumberRange.new(0)
		streak.Size = NumberSequence.new(0.55, 0)
		streak.Transparency = NumberSequence.new(0.1, 1)
		streak.Parent = eye
		eye.Size = Vector3.new(0.02, 0.02, 0.02)
		TweenService:Create(eye, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = Vector3.new(0.2, 0.2, 0.2) }):Play()
		eye.Parent = character
		self:After(duration, function() fadeAway(eye, 0.3) end)
	end
end

-- the direction from the rider to a target (nil when there's no target)
local function towards(rider, target)
	local root = rider.Character and rider.Character:FindFirstChild("HumanoidRootPart")
	if not (root and target) then return nil end
	local d = target.Position - root.Position
	return d.Magnitude > 0.01 and d.Unit or nil
end

-- a kunai / knife thrown ahead (faster than you're riding), auto-aimed at `target` (or the closest dummy / rider in
-- front of you if not given)
function AbilityVFX:Throw(rider, kind, spreadDegrees, target)
	local root = rider.Character and rider.Character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local S = settings()
	local dir, riderSpeed = travel(rider)
	target = target or self:FindTarget(rider, S.TargetRange or 160, true)
	if target then dir = towards(rider, target) or dir end -- start off already heading at the target
	if spreadDegrees and spreadDegrees ~= 0 then
		dir = CFrame.fromAxisAngle(Vector3.yAxis, math.rad(spreadDegrees)):VectorToWorldSpace(dir)
	end
	local range = S.ThrowRange or 140
	local speed = (kind == "Knife" and (S.KnifeSpeed or 170) or (S.KunaiSpeed or 180)) + riderSpeed
	local blade = makeBlade(kind)
	-- it leaves the hand (the grip on the right arm), so it comes out of the throw
	local arm = limbOf(rider.Character, "Right Arm")
	local grip = arm and arm:FindFirstChild("RightGripAttachment")
	local pos = (grip and grip.WorldPosition) or (arm and (arm.CFrame * CFrame.new(0, -1, 0)).Position) or (root.Position + dir * 2 + Vector3.new(0, 1, 0))
	blade:PivotTo(CFrame.lookAt(pos, pos + dir))
	blade.Parent = workspace
	local flown = 0
	local maxFlight = target and range * 1.6 or range
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		if not blade.Parent then conn:Disconnect() return end
		if self:FrozenLeft(rider.Character) > 0 then return end -- thrown before someone's Za Warudo: hangs in the air
		local hit
		if target and target.Parent then
			local to = target.Position - pos
			if to.Magnitude <= speed * dt + 2 then hit = target end
			if to.Magnitude > 0.01 then dir = to.Unit end
		end
		local step = speed * dt
		pos += dir * step
		flown += step
		blade:PivotTo(CFrame.lookAt(pos, pos + dir))
		if hit or flown >= maxFlight then
			conn:Disconnect()
			if hit then self:Hit(hit) end
			fadeAway(blade, 0.15)
		end
	end)
end

-- Rasen Shuriken: spins over your head, then flies ahead and explodes (at the closest rider in front, if any)
function AbilityVFX:RasenShuriken(rider, holdTime)
	local src = template("Naruto/RasenShurikenVFX/rasenshuriken")
	local root = rider.Character and rider.Character:FindFirstChild("HumanoidRootPart")
	if not (src and root) then return end
	local S = settings()
	local disc = src:Clone()
	for _, d in ipairs(disc:GetDescendants()) do
		if d:IsA("JointInstance") or d:IsA("WeldConstraint") then
			d:Destroy()
		elseif d:IsA("ParticleEmitter") then
			d.LockedToPart = true
			d.Enabled = true
		elseif d:IsA("Beam") then
			-- Part-Icles animates the blades' width; played by hand here, so use the full width
			local w0 = math.max(d.Width0, tonumber(d:GetAttribute("Width0_Start")) or 0, tonumber(d:GetAttribute("Width0_End")) or 0)
			local w1 = math.max(d.Width1, tonumber(d:GetAttribute("Width1_Start")) or 0, tonumber(d:GetAttribute("Width1_End")) or 0)
			d.Width0, d.Width1 = w0, w1
			d.Enabled = true
		end
	end
	disc.Anchored, disc.CanCollide, disc.CanQuery, disc.CanTouch = true, false, false, false
	disc.Name = "AbilityRasenShuriken"
	disc.Parent = workspace
	local CENTRE = CFrame.new(0, 2.1, 0) -- the shuriken's centre sits 2.1 studs below its part (as made)
	local core = src:FindFirstChild("RasenShurikenCore")
	local HELD = CFrame.new(core and core:IsA("Attachment") and core.Position or Vector3.new(0, -2.1, 0)) -- its centre, in its own frame
	holdTime = holdTime or S.ShurikenHold or 0.75
	local range = S.ThrowRange or 140
	local spin, t0 = 0, os.clock()
	local flying, pos, dir, speed, flown, target = false, nil, nil, 0, 0, nil
	local hold -- the weld to his hand while he holds it
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		if not disc.Parent then conn:Disconnect() return end
		if self:FrozenLeft(rider.Character) > 0 then t0 += dt return end -- someone's Za Warudo: it stops dead, mid-air or in the hand
		spin += dt * 16
		if not flying then
			if not root.Parent then conn:Disconnect() disc:Destroy() return end
			-- held in his right hand the way it's rigged on the effect's dummy: welded to the arm with its centre just past
			-- the hand, so it moves with the arm through the animation (no lag behind it), spinning
			local arm = limbOf(rider.Character, "Right Arm")
			local centre
			if arm and arm.Parent then
				if not hold then
					disc.Anchored = false
					disc.Massless = true
					hold = Instance.new("Weld")
					hold.Name = "RasenShurikenHold"
					hold.Part0 = arm
					hold.Part1 = disc
					hold.Parent = disc
				end
				local grip = dummyOffset(src, "Right Arm") * HELD
				hold.C0 = grip * CFrame.Angles(0, spin, 0) * HELD:Inverse()
				centre = (arm.CFrame * grip).Position
			else
				centre = root.Position + Vector3.new(0, S.ShurikenHoldHeight or 6, 0)
				disc.CFrame = CFrame.new(centre) * CFrame.Angles(0, spin, 0) * CENTRE
			end
			if os.clock() - t0 >= holdTime then
				local d, riderSpeed = travel(rider)
				if hold then -- let go: it flies on its own from here
					hold:Destroy()
					hold = nil
					disc.Anchored = true
				end
				flying, pos, dir = true, centre, d
				speed = (S.ShurikenSpeed or 130) + riderSpeed
				target = self:FindTarget(rider, S.TargetRange or 160, true)
			end
			return
		end
		local hit
		if target and target.Parent then
			local to = target.Position - pos
			if to.Magnitude <= speed * dt + 3 then hit = target end
			if to.Magnitude > 0.01 then dir = to.Unit end
		end
		local step = speed * dt
		pos += dir * step
		flown += step
		disc.CFrame = CFrame.new(pos) * CFrame.Angles(0, spin, 0) * CENTRE
		if hit or flown >= range * (target and 1.6 or 1) then
			conn:Disconnect()
			local flat = Vector3.new(dir.X, 0, dir.Z)
			local facing = flat.Magnitude > 0.01 and CFrame.lookAt(pos, pos + flat) or CFrame.new(pos)
			self:EmitAt("Naruto/RasenShurikenVFX/RasenShurikenExplosion", facing)
			if hit then self:Hit(hit, true) end -- (an ultimate: Sharingan can't dodge it)
			for _, d in ipairs(disc:GetDescendants()) do
				if d:IsA("ParticleEmitter") or d:IsA("Beam") then d.Enabled = false end
			end
			task.delay(0.8, function() disc:Destroy() end)
		end
	end)
end

-- the ultimates' camera cutscene: the rig (camera + letterbox bars) follows you and plays its animation
local registered = {}
local function animationIdFor(kfs, name)
	local ids = settings().CutsceneAnimationIds or {}
	if ids[name] and ids[name] ~= "" then return ids[name] end
	if registered[kfs] then return registered[kfs] end
	local ok, id = pcall(function() return KeyframeSequenceProvider:RegisterKeyframeSequence(kfs) end)
	if ok then registered[kfs] = id return id end
	return nil -- live game without a published id: the cutscene is skipped
end

-- the cutscene rig's own screen pieces, copied from the effect (`src`) and placed in front of the camera each frame:
--   letterbox bars: the rig's black bars, moved by the cutscene animation (their joints in the hidden `rig`)
--   camera.ScreenStuff: flares, wind beams and speed lines welded in front of the lens
-- returns the folder (under the camera), { copy, function -> its place relative to the camera }, and whether it has bars
function AbilityVFX:CutsceneScreenKit(src, rig)
	local kit = Instance.new("Folder")
	kit.Name = "AbilityCutsceneScreen"
	local pieces, hasBars = {}, false
	local function prep(copy)
		for _, d in ipairs(copy:GetDescendants()) do
			if d:IsA("JointInstance") or d:IsA("WeldConstraint") then
				d:Destroy()
			elseif d:IsA("ParticleEmitter") then
				d.LockedToPart = true -- stays on the screen
				-- on for as long as it was made to be (its EmitDuration, after its EmitDelay), not the whole cutscene:
				-- matches the effect as made, and fewer particles in front of the lens
				local delay = tonumber(d:GetAttribute("EmitDelay")) or 0
				local duration = tonumber(d:GetAttribute("EmitDuration")) or 0
				local count = tonumber(d:GetAttribute("EmitCount")) or 0
				d.Enabled = delay <= 0 and (duration > 0 or count <= 0)
				task.delay(delay, function()
					if not d.Parent then return end
					if count > 0 then d:Emit(count) end
					if duration > 0 then
						d.Enabled = true
						task.delay(duration, function() if d.Parent then d.Enabled = false end end)
					elseif count > 0 then
						d.Enabled = false
					else
						d.Enabled = true -- (no timing on it: on throughout, as before)
					end
				end)
			elseif d:IsA("Beam") then
				-- Part-Icles animates beam widths; played by hand here, so use the full width
				d.Width0 = math.max(d.Width0, tonumber(d:GetAttribute("Width0_Start")) or 0, tonumber(d:GetAttribute("Width0_End")) or 0)
				d.Width1 = math.max(d.Width1, tonumber(d:GetAttribute("Width1_Start")) or 0, tonumber(d:GetAttribute("Width1_End")) or 0)
				d.Enabled = true
			elseif d:IsA("Trail") then
				d.Enabled = true
			end
		end
		copy.Anchored, copy.CanCollide, copy.CanQuery, copy.CanTouch, copy.CastShadow = true, false, false, false, false
	end
	for _, name in ipairs({ "letterboxtop", "letterboxbot" }) do
		local part = src:FindFirstChild(name)
		local live = rig:FindFirstChild(name)
		local motor = live and live:FindFirstChildOfClass("Motor6D")
		if part and part:IsA("BasePart") and part.Transparency < 1 and motor then
			local copy = part:Clone()
			prep(copy)
			copy.Parent = kit
			table.insert(pieces, { copy, function() return motor.C0 * motor.Transform * motor.C1:Inverse() end })
			hasBars = true
		end
	end
	local camSrc = src:FindFirstChild("camera")
	local stuff = camSrc and camSrc:FindFirstChild("ScreenStuff")
	if stuff then
		for _, p in ipairs(stuff:GetChildren()) do
			if p:IsA("BasePart") then
				local rel = camSrc.CFrame:ToObjectSpace(p.CFrame)
				local copy = p:Clone()
				prep(copy)
				copy.Parent = kit
				table.insert(pieces, { copy, function() return rel end })
			end
		end
	end
	kit.Parent = workspace.CurrentCamera
	return kit, pieces, hasBars
end

-- a screen effect made as a GUI flipbook (e.g. the 500 IQ clap's vignette): shown on your screen and played there
function AbilityVFX:ScreenFlipbook(path, lifetime)
	local item = template(path)
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not (item and item:IsA("GuiObject") and self.Engine and playerGui) then return end
	local gui = Instance.new("ScreenGui")
	gui.Name = "AbilityScreenFlipbook"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 4
	gui.ResetOnSpawn = false
	local copy = item:Clone()
	copy.Parent = gui
	gui.Parent = playerGui
	local engine = self.Engine
	task.spawn(function() engine:AbsoluteEmit(copy) end)
	task.delay(lifetime or 3, function() gui:Destroy() end)
end

-- Boogie Woogie swapped two riders (the server says who): a white flash and a ring on both
function AbilityVFX:ShowSwap(a, b)
	for _, m in ipairs({ a, b }) do
		if typeof(m) == "Instance" and m:IsA("Model") and m.Parent then
			self:Glow(m, WHITE, 0.35, 0.9)
			local root = m:FindFirstChild("HumanoidRootPart")
			if root then self:Burst(root, RING, Color3.fromRGB(150, 210, 255), 16, 0.35) end
		end
	end
end

function AbilityVFX:PlayCutscene(rider, rigPath, animName)
	local S = settings()
	if S.Cutscenes == false or self.InCutscene or rider.Remote then return end -- someone else's ultimate never takes your camera
	local src = template(rigPath)
	local root = rider.Character and rider.Character:FindFirstChild("HumanoidRootPart")
	local saves = src and src:FindFirstChild("AnimSaves")
	local kfs = saves and saves:FindFirstChild(animName)
	if not (root and kfs and src:FindFirstChild("RootPart") and src:FindFirstChild("camera")) then return end
	local animId = animationIdFor(kfs, animName)
	if not animId then return end
	local length = 0
	for _, kf in ipairs(kfs:GetChildren()) do
		if kf:IsA("Keyframe") then length = math.max(length, kf.Time) end
	end
	local dummy = dummyOf(src)
	local dummyRoot = dummy and dummy:FindFirstChild("HumanoidRootPart")
	local rootOffset = dummyRoot and dummyRoot.CFrame:ToObjectSpace(src.RootPart.CFrame) or CFrame.identity
	-- the rig only drives the camera: its parts stay hidden, and the letterbox is drawn as screen bars
	-- (3D bars right in front of a camera moving at 60 mph would jitter)
	local rig = src:Clone()
	for _, d in ipairs(rig:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanCollide, d.CanQuery, d.CanTouch, d.CastShadow, d.Massless = false, false, false, false, true
			d.Anchored = d.Name == "RootPart"
			d.Transparency = 1
		elseif d:IsA("Decal") or d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") then
			d:Destroy()
		end
	end
	local cameraJoint
	for _, j in ipairs(rig:GetDescendants()) do
		if j:IsA("Motor6D") and j.Part1 and j.Part1.Name == "camera" then cameraJoint = j end
	end
	rig.RootPart.CFrame = flatFrame(rider) * rootOffset
	rig.Name = "AbilityCutsceneRig"
	rig.Parent = workspace
	local animController = rig:FindFirstChildOfClass("AnimationController")
	if not (animController and cameraJoint) then rig:Destroy() return end
	local animator = animController:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = animController
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = animId
	local track = animator:LoadAnimation(anim)
	track.Looped = false
	track:Play(0)
	-- the rig's own screen pieces (letterbox bars, flares, wind / speed lines in front of the lens), as copies locked to
	-- the camera every frame (the rig itself stays hidden: parts it moves update a frame late and would jitter)
	local kit, screenParts, hasBars = self:CutsceneScreenKit(src, rig)
	-- letterbox bars (drawn on screen only if the rig has none of its own)
	local gui = Instance.new("ScreenGui")
	gui.Name = "AbilityLetterbox"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 2
	gui.ResetOnSpawn = false
	local bars = {}
	for i, anchor in ipairs({ 0, 1 }) do
		local bar = Instance.new("Frame")
		bar.BorderSizePixel = 0
		bar.BackgroundColor3 = Color3.new(0, 0, 0)
		bar.AnchorPoint = Vector2.new(0, anchor)
		bar.Position = UDim2.fromScale(0, anchor)
		bar.Size = UDim2.fromScale(1, 0)
		bar.Parent = gui
		bars[i] = bar
	end
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	if not hasBars then
		for _, bar in ipairs(bars) do
			TweenService:Create(bar, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromScale(1, 0.11) }):Play()
		end
	end
	self.InCutscene = true
	local camera = workspace.CurrentCamera
	local t0 = os.clock()
	local done = false
	local function finish()
		if done then return end
		done = true
		RunService:UnbindFromRenderStep("AbilityCutscene")
		rig:Destroy()
		kit:Destroy()
		self.InCutscene = false
		for _, bar in ipairs(bars) do
			TweenService:Create(bar, TweenInfo.new(0.2), { Size = UDim2.fromScale(1, 0) }):Play()
		end
		task.delay(0.25, function() gui:Destroy() end)
	end
	RunService:BindToRenderStep("AbilityCutscene", Enum.RenderPriority.Camera.Value + 2, function()
		if os.clock() - t0 >= length or not root.Parent or not rig.Parent then
			finish()
			return
		end
		local rootCF = flatFrame(rider) * rootOffset
		rig.RootPart.CFrame = rootCF
		-- the camera straight from the animated joint, so it's exactly where the animation puts it this frame
		local camCF = rootCF * cameraJoint.C0 * cameraJoint.Transform * cameraJoint.C1:Inverse()
		camera.CFrame = camCF
		for _, piece in ipairs(screenParts) do
			piece[1].CFrame = camCF * piece[2]()
		end
		camera.FieldOfView = S.CutsceneFov or 70
	end)
	-- safety net: never leave the camera stuck if rendering pauses or something goes wrong
	task.delay(length + 1, function()
		if self.InCutscene and rig.Parent then finish() end
	end)
end

-- Za Warudo: a negative flash, then the world goes grey for `duration` seconds (on your camera only)
function AbilityVFX:TimeStopScreen(duration)
	if settings().ScreenEffects == false then return end
	local camera = workspace.CurrentCamera
	local old = camera:FindFirstChild("AbilityTimeStop")
	if old then old:Destroy() end
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "AbilityTimeStop"
	cc.Contrast = -2 -- negative flash
	cc.Saturation = 0.4
	cc.TintColor = Color3.fromRGB(255, 235, 170)
	cc.Parent = camera
	self:After(0.35, function()
		TweenService:Create(cc, TweenInfo.new(0.25), { Contrast = 0.15, Saturation = -1, TintColor = Color3.fromRGB(205, 215, 255), Brightness = -0.03 }):Play()
	end)
	self:After(duration, function()
		local tween = TweenService:Create(cc, TweenInfo.new(0.5), { Contrast = 0, Saturation = 0, TintColor = WHITE, Brightness = 0 })
		tween.Completed:Once(function() cc:Destroy() end)
		tween:Play()
		task.delay(0.8, function() if cc.Parent then cc:Destroy() end end) -- never left grey
	end)
end

-- someone's Za Warudo: these riders / dummies stop dead for `duration` seconds (the server says who). Their animations
-- pause mid-pose and the effects on them (their particles, a Chidori in the hand...) hang in the air, then carry on. If
-- you're one of them, your screen goes grey while time is stopped
function AbilityVFX:ShowFrozen(models, duration)
	local untilTime = os.clock() + duration
	local me = Players.LocalPlayer.Character
	for _, model in ipairs(models) do
		if typeof(model) == "Instance" and model.Parent then
			local holding = self:FrozenLeft(model) > 0
			frozenUntil[model] = math.max(frozenUntil[model] or 0, untilTime)
			if not holding then
				task.spawn(self.HoldStill, self, model)
			end
			if model == me then
				self:TimeStopScreen(duration)
			end
		end
	end
end

-- seconds before time moves again for this model (0 = it isn't frozen)
function AbilityVFX:FrozenLeft(model)
	local t = model and frozenUntil[model]
	return t and math.max(t - os.clock(), 0) or 0
end

-- keeps one frozen model still until its time moves again
-- (one quick look through the model when it freezes, skipping its saved animations; anything that starts on it while it's
-- frozen is caught by events, so nothing runs every frame while time is stopped)
function AbilityVFX:HoldStill(model)
	local tracks = {} -- animation track -> the speed it was playing at
	local scales = {} -- particle emitter -> its TimeScale
	local connections = {}
	local function stopTrack(track)
		if tracks[track] == nil then
			tracks[track] = track.Speed
			track:AdjustSpeed(0)
		end
	end
	local function stopEmitter(emitter)
		if scales[emitter] == nil then
			scales[emitter] = emitter.TimeScale
			emitter.TimeScale = 0
		end
	end
	for _, d in ipairs(lightDescendants(model)) do
		if d:IsA("Animator") then
			for _, track in ipairs(d:GetPlayingAnimationTracks()) do
				stopTrack(track)
			end
			table.insert(connections, d.AnimationPlayed:Connect(function(track)
				task.defer(stopTrack, track) -- after it's started, so its own speed doesn't win
			end))
		elseif d:IsA("ParticleEmitter") then
			stopEmitter(d)
		end
	end
	table.insert(connections, model.DescendantAdded:Connect(function(d)
		if d:IsA("ParticleEmitter") then stopEmitter(d) end
	end))
	-- effects riding on it from outside the model (EmitOn / HoldOn copies welded to its limbs)
	for copy, limb in pairs(attached) do
		if copy.Parent and limb:IsDescendantOf(model) then
			for _, d in ipairs(copy:GetDescendants()) do
				if d:IsA("ParticleEmitter") then stopEmitter(d) end
			end
		end
	end
	-- until time moves again (another Za Warudo can stretch it)
	while model.Parent do
		local left = self:FrozenLeft(model)
		if left <= 0 then break end
		task.wait(left)
	end
	for _, c in ipairs(connections) do c:Disconnect() end
	for track, speed in pairs(tracks) do
		if track.IsPlaying then track:AdjustSpeed(speed) end
	end
	for emitter, scale in pairs(scales) do
		if emitter.Parent then emitter.TimeScale = scale end
	end
end

-- Time Skip: the rider turns invisible for `duration` seconds (every client hides them on its own screen)
function AbilityVFX:Vanish(model, duration)
	local hidden = {}
	for _, d in ipairs(lightDescendants(model)) do
		if (d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture")) and d.Transparency < 1 then
			hidden[d] = d.Transparency
			d.Transparency = 1
		end
	end
	self:After(duration, function()
		for d, t in pairs(hidden) do
			if d.Parent and d.Transparency == 1 then d.Transparency = t end
		end
	end)
end

-- ability animations ------------------------------------------------------------------------------------------------
-- The saved animations in BoardAssets.Rigs.AbilitiesBoard.AnimSaves (made on an R6 character + board). They move that rig's
-- "Board"; when one is loaded, a copy is fitted to the character's own board (LuffyBoard, Nimbus...: BoardRig), so the
-- board moves exactly as in the animation, from where it normally sits on the rider.

local LIMBS = { Torso = true, Head = true, HumanoidRootPart = true, ["Left Arm"] = true, ["Right Arm"] = true, ["Left Leg"] = true, ["Right Leg"] = true }

local animIds = {} -- "Animation|board joint" -> registered Studio id
local function abilityAnimationId(animName, character)
	local S = settings()
	local published = S.AnimationIds and S.AnimationIds[animName]
	if published and published ~= "" then return published end
	local joint = BoardRig.BoardJoint(character)
	local key = animName .. "|" .. BoardRig.Signature(joint)
	if animIds[key] then return animIds[key] end
	local rigs = ReplicatedStorage:FindFirstChild("BoardAssets") and ReplicatedStorage.BoardAssets:FindFirstChild("Rigs")
	local rig = rigs and rigs:FindFirstChild(S.AnimationRig or "AbilitiesBoard")
	local saves = rig and rig:FindFirstChild("AnimSaves")
	local kfs = saves and saves:FindFirstChild(animName)
	if not kfs then
		warn("[AbilityVFX] No animation called " .. animName .. " in Rigs." .. tostring(S.AnimationRig or "AbilitiesBoard") .. ".AnimSaves")
		return nil
	end
	if joint then
		-- fitted to this character's board, so it moves exactly like the board in the animation (see BoardRig)
		kfs = BoardRig.Retarget(kfs, rig, joint)
		if not cache then
			cache = Instance.new("Folder")
			cache.Name = "AbilityVFXCache"
			cache.Parent = ReplicatedStorage
		end
		kfs.Parent = cache
	end
	local ok, id = pcall(function() return KeyframeSequenceProvider:RegisterKeyframeSequence(kfs) end)
	if ok and id then
		animIds[key] = id
		return id
	end
	return nil -- live game without a published id: no animation, the effects still play
end

local trackCache = setmetatable({}, { __mode = "k" }) -- animator -> { id -> track }

-- plays an ability animation on a character (your rider, or a dummy that got hit), over the board animations.
-- opts: Looped, Duration (stop after this many seconds), Speed, Fade. Returns the track, or nil if it can't play.
function AbilityVFX:PlayAnim(character, animName, opts)
	opts = opts or {}
	if settings().Animations == false or not (character and animName) then return nil end
	local holder = character:FindFirstChildOfClass("Humanoid") or character:FindFirstChildOfClass("AnimationController")
	if not holder then return nil end
	-- someone else's own ability animation: once it's published, their client plays it and Roblox shows it to everyone
	-- (playing it here too would double it). Until then (Studio saves) it's played here, so you can still see it
	local owner = Players:GetPlayerFromCharacter(character)
	if owner and owner ~= Players.LocalPlayer and not opts.ForceLocal then
		local published = settings().AnimationIds and settings().AnimationIds[animName]
		if published and published ~= "" then return nil end
	end
	local animator = holder:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = holder
	end
	local id = abilityAnimationId(animName, character)
	if not id then return nil end
	trackCache[animator] = trackCache[animator] or {}
	local track = trackCache[animator][id]
	if not track then
		local anim = Instance.new("Animation")
		anim.AnimationId = id
		local ok, loaded = pcall(function() return animator:LoadAnimation(anim) end)
		if not ok or not loaded then return nil end
		track = loaded
		trackCache[animator][id] = track
	end
	track.Priority = Enum.AnimationPriority.Action3 -- over the riding poses and the jump / land shots
	track.Looped = opts.Looped == true
	track:Play(opts.Fade or 0.08, 1, opts.Speed or 1)
	if opts.Duration then
		task.delay(opts.Duration, function()
			if track.IsPlaying then track:Stop(0.15) end
		end)
	end
	return track
end

-- gets a character's abilities ready ahead of time (when you pick them, or spawn as them), so the first use doesn't
-- stutter: each ability animation is fitted to your board and loaded, the ultimate's cutscene camera is registered and
-- its effects split, and the effect textures are fetched. Spread over a few frames so it never hitches itself
function AbilityVFX:Prewarm(characterId, character)
	if not (characterId and character and character.Parent) then return end
	local holder = character:FindFirstChildOfClass("Humanoid")
	local animator = holder and holder:FindFirstChildOfClass("Animator")
	for _, slot in ipairs({ "Skill1", "Skill2", "Ultimate" }) do
		local ability = abilityOf(characterId, slot)
		if ability then
			if ability.Anim and animator and settings().Animations ~= false then
				local id = abilityAnimationId(ability.Anim, character)
				if id then
					trackCache[animator] = trackCache[animator] or {}
					if not trackCache[animator][id] then
						local anim = Instance.new("Animation")
						anim.AnimationId = id
						local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
						if ok and track then trackCache[animator][id] = track end
					end
				end
				task.wait()
			end
			local folder = ability.Vfx and template(ability.Vfx)
			if folder then
				for _, d in ipairs(folder:GetChildren()) do
					-- a cutscene camera rig: its saved camera moves, registered now
					local saves = d:IsA("Model") and d:FindFirstChild("camera") and d:FindFirstChild("AnimSaves")
					if saves then
						for _, kfs in ipairs(saves:GetChildren()) do
							if kfs:IsA("KeyframeSequence") then animationIdFor(kfs, kfs.Name) end
						end
					elseif d:IsA("BasePart") and not d:FindFirstChildOfClass("Humanoid") then
						splitEffect(d) -- the ready-made effects, split once now instead of on first use
					end
				end
				if self.Engine then
					pcall(function() self.Engine:Preload(folder) end)
				end
				task.wait()
			end
		end
	end
end

-- someone got hit: stun animation, then dazed (looping) for Config.AbilityVFX.StunTime seconds. Getting hit again
-- while dazed just makes it last longer
function AbilityVFX:Stun(model, duration)
	if not model then return end
	self.Stuns = self.Stuns or {}
	local stunTime = duration or settings().StunTime or 2
	local state = self.Stuns[model]
	if state then
		state.EndsAt = math.max(state.EndsAt, os.clock() + stunTime)
		self:PlayAnim(model, "StunAnim")
		return
	end
	state = { EndsAt = os.clock() + stunTime }
	self.Stuns[model] = state
	local stun = self:PlayAnim(model, "StunAnim")
	local head = model:FindFirstChild("Head")
	task.spawn(function()
		task.wait(stun and math.min(stun.Length > 0 and stun.Length or 0.5, 0.5) or 0.5)
		local dazed = self:PlayAnim(model, "DazedAnim", { Looped = true })
		local trails = template("StunVFX/StunTrails")
		if trails and head and self.Engine then
			local engine = self.Engine
			emitFollowing(engine, trails, head.CFrame * CFrame.new(0, 1, 0), head)
		end
		while os.clock() < state.EndsAt and model.Parent do task.wait(0.1) end
		if dazed and dazed.IsPlaying then dazed:Stop(0.25) end
		self.Stuns[model] = nil
	end)
end

-- someone got hit by a thrown ability (the server confirmed it; Config.Hits[kind]): the stun animation on them (stunned:
-- stun + dazed for StunTime; slowed: the stun animation once), and if it's you, the screen effect
function AbilityVFX:ShowHit(model, kind)
	local hit = Config.Hits and Config.Hits[kind]
	if not (hit and model and model.Parent) then return end
	if (hit.StunTime or 0) > 0 then
		self:Stun(model, hit.StunTime)
	else
		self:PlayAnim(model, hit.Animation or "StunAnim")
	end
	if hit.Screen and model == Players.LocalPlayer.Character then
		self:HitScreen(hit)
	end
end

-- you got stunned: a quick blue-white flash and a blur that clears as the stun wears off (camera only; Lighting isn't touched)
function AbilityVFX:HitScreen(hit)
	if settings().ScreenEffects == false then return end
	local camera = workspace.CurrentCamera
	for _, name in ipairs({ "AbilityHitScreen", "AbilityHitBlur" }) do
		local old = camera:FindFirstChild(name)
		if old then old:Destroy() end
	end
	local stun = hit.StunTime or 0.5
	local soft = hit.Screen == "Soft" -- (Chidori: a gentler version)
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "AbilityHitScreen"
	cc.TintColor = soft and Color3.fromRGB(205, 210, 255) or Color3.fromRGB(170, 220, 255)
	cc.Brightness = soft and 0.15 or 0.35
	cc.Contrast = soft and 0.08 or 0.2
	cc.Saturation = soft and -0.15 or -0.35
	cc.Parent = camera
	local blur = Instance.new("BlurEffect")
	blur.Name = "AbilityHitBlur"
	blur.Size = soft and 7 or 16
	blur.Parent = camera
	TweenService:Create(cc, TweenInfo.new(0.25), { Brightness = 0.05, TintColor = Color3.fromRGB(215, 232, 255) }):Play()
	TweenService:Create(blur, TweenInfo.new(stun, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = 4 }):Play()
	self:After(stun, function()
		TweenService:Create(cc, TweenInfo.new(0.4), { Brightness = 0, Contrast = 0, Saturation = 0, TintColor = WHITE }):Play()
		TweenService:Create(blur, TweenInfo.new(0.4), { Size = 0 }):Play()
	end)
	task.delay(stun + 0.9, function() -- never left blurred
		cc:Destroy()
		blur:Destroy()
	end)
end

-- seconds into an ability's animation when its effects fire (Config.AbilityVFX.Timings)
local function timing(name, default)
	local t = settings().Timings
	return (t and t[name]) or default
end

-- every ability: its animation, and its effects at the matching moments ----------------------------------------------

local SEQUENCES = {}

SEQUENCES.Naruto = {
	Skill1 = function(self, r, a) -- Chakra Mode (no animation): chakra aura while the boost lasts
		self:Glow(r.Character, ORANGE, 0.5, 0.7)
		self:Aura(r.Character, a.Duration or 3)
	end,
	Skill2 = function(self, r, a) -- Kunai Throw: the burst + kunai leave the hand at the release
		local c = r.Character
		self:PlayAnim(c, a.Anim or "KunaiThrow")
		self:After(timing("KunaiRelease", 0.38), function()
			local target = self:FindTarget(r, settings().TargetRange or 160, true)
			self:EmitOn(c, "Naruto/KunaiThrowVFX/ActualThrow", "HumanoidRootPart", true, towards(r, target))
			self:Throw(r, "Kunai", 0, target)
		end)
	end,
	Ultimate = function(self, r, a) -- Rasen Shuriken: charges while the hands form it, held overhead, thrown, explodes
		local c = r.Character
		self:PlayAnim(c, a.Anim or "RasenShuriken")
		self:Glow(c, Color3.fromRGB(120, 200, 255), 0.6, 0.5)
		self:EmitOn(c, "Naruto/RasenShurikenVFX/RasenCharge", "Right Arm")
		local formed = timing("RasenFormed", 0.45)
		local throw = timing("RasenThrow", 1.38)
		self:After(formed, function()
			self:EmitOn(c, "Naruto/RasenShurikenVFX/RasenFormed", "Right Arm")
			self:RasenShuriken(r, math.max(throw - formed, 0.1))
		end)
	end,
}

SEQUENCES.Deku = {
	Skill1 = function(self, r, a) -- Jump Boost: charge while crouching, the leap burst at the push-off
		local c = r.Character
		self:PlayAnim(c, a.Anim or "Jump")
		self:Flash(c, "Deku/DekuDashVFX/DekuDashDummy/DekStart")
		self:EmitOn(c, "Deku/DekuJump/DekuCharge", "HumanoidRootPart")
		self:After(timing("JumpPushOff", 0.4), function() self:EmitOn(c, "Deku/DekuJump/DekuLeapVFX", "HumanoidRootPart", false) end)
	end,
	Skill2 = function(self, r, a) -- One For All Dash: the burst on the push
		local c = r.Character
		self:PlayAnim(c, a.Anim or "DekuBoost") -- saved as a loop; played once for the dash
		self:Flash(c, "Deku/DekuDashVFX/DekuDashDummy/DekStart")
		self:After(timing("DashPush", 0.1), function() self:EmitOn(c, "Deku/DekuDashVFX/DashVFX", "HumanoidRootPart") end)
	end,
	Ultimate = function(self, r, a) -- Speed Boost (no animation): green Full Cowl aura while the boost lasts
		local c = r.Character
		local duration = a.Duration or 5
		self:Glow(c, GREEN, 0.5, 0.7)
		self:Flash(c, "Deku/DekuDashVFX/DekuDashDummy/DekStart")
		self:EmitOn(c, "Deku/DekuDashVFX/DashVFX", "HumanoidRootPart")
		self:Aura(c, duration, GREEN)
		self:Outline(c, GREEN, duration)
	end,
}

SEQUENCES.Sasuke = {
	Skill1 = function(self, r, a) -- Chidori: charge pose (looping) with the lightning held in his hand until it hits someone
		-- (the thrust: the server says so, EndAbility) or runs out (it fizzles)
		local c = r.Character
		local duration = math.max(a.Duration or 5, 0.6)
		local armAt = timing("ChidoriArm", 0.25)
		local state = { Done = false }
		-- the charge plays once and then holds its last pose (the hold position) until it hits or runs out
		local charge = self:PlayAnim(c, a.Anim or "ChidoriCharge", { Looped = false })
		if charge then
			local length = charge.Length > 0 and charge.Length or 0.75
			self:After(timing("ChidoriHold", math.max(length - 0.03, 0)), function()
				if not state.Done and charge.IsPlaying then charge:AdjustSpeed(0) end
			end)
		end
		self:Flash(c, "Sasuke/SasukeDummy/ChidoriStart")
		local stopHeld
		-- the lightning ball: welded to his right hand the way it sits on the effect's dummy, crackling the whole time
		self:After(armAt, function()
			if not state.Done then
				local _, stop = self:HoldOn(c, "Sasuke/ArmChidori", "Right Arm", duration - armAt + 0.1)
				stopHeld = stop
			end
		end)
		for t = armAt, duration - 0.2, 0.6 do -- the lightning-bolt flipbooks on top, every 0.6 s
			self:After(t, function()
				if not state.Done then self:EmitFlipbooks(c, "Sasuke/ArmChidori", "Right Arm") end
			end)
		end
		local function finish(hit)
			if state.Done then return end
			state.Done = true
			if charge and charge.IsPlaying then charge:Stop(0.12) end
			if stopHeld then stopHeld() end
			if hit then -- the strike
				self:PlayAnim(c, "ChidoriFinish")
				self:EmitOn(c, "Sasuke/Thrusttt", "HumanoidRootPart")
			end
		end
		self:SetActive(c, "Sasuke", "Skill1", finish)
		self:After(duration, function() finish(false) end) -- nobody touched in time: it fizzles out
	end,
	Skill2 = function(self, r, a) -- Sharingan (no animation): red eyes while the auto-dodge lasts
		local c = r.Character
		self.Dodging = self.Dodging or setmetatable({}, { __mode = "k" })
		self.Dodging[c] = os.clock() + (a.Duration or 6) -- (the server decides real dodges; this just avoids a stun burst)
		self:Glow(c, RED, 0.5, 0.5)
		self:Burst(c:FindFirstChild("HumanoidRootPart"), RING, RED, 14, 0.4)
		self:Sharingan(c, a.Duration or 6)
	end,
	Ultimate = function(self, r, a) -- Sharingan Copy (no animation): the Sharingan on your screen, red + black rings and the eyes
		local c = r.Character
		local root = c:FindFirstChild("HumanoidRootPart")
		if not r.Remote then self:SharinganScreen(1) end
		self:Glow(c, RED, 0.8, 0.8)
		self:Sharingan(c, a.Duration or 2.5)
		self:Burst(root, RING, RED, 28, 0.55)
		self:After(0.12, function() self:Burst(root, RING, Color3.fromRGB(25, 0, 0), 22, 0.5, false) end)
		self:After(0.24, function() self:Burst(root, RING, RED, 18, 0.45) end)
	end,
}

SEQUENCES.Todo = {
	Skill1 = function(self, r, a) -- Boogie Woogie: the clap with its effect (the swap flash comes from the server: ShowSwap)
		local c = r.Character
		self:PlayAnim(c, a.Anim or "Clap")
		self:Flash(c, "Todo/TodoClap/1stTodo/ClapStart")
		self:After(timing("Clap", 0.28), function() self:EmitOn(c, "Todo/TodoClap/ClapVFX", "HumanoidRootPart") end)
	end,
	Skill2 = function(self, r, a) -- Fake Clap: just the clap animation, no effects (so it can pass for a Boogie Woogie)
		self:PlayAnim(r.Character, a.Anim or "Clap")
	end,
	Ultimate = function(self, r, a) -- 500 IQ: cutscene + ult animation, the clap (and its screen vignette), then a gold glow
		-- while there are no cooldowns
		local c = r.Character
		local track = self:PlayAnim(c, a.Anim or "TodoUlts")
		self:Flash(c, "Todo/TodoCutscene/UltTodo/ClapStart")
		self:PlayCutscene(r, "Todo/TodoCutscene/CamRigWithLetterBox2", "TodoUltCam")
		self:After(timing("IQClap", 0.95), function()
			self:EmitOn(c, "Todo/TodoCutscene/CutsceneClap", "HumanoidRootPart")
			if not r.Remote then self:ScreenFlipbook("Todo/TodoCutscene/CutsceneClap/ScreenVign") end
		end)
		local length = (track and track.Length > 0) and track.Length or 1.53
		self:After(length, function() self:Outline(c, GOLD, a.NoCooldowns or a.Duration or 8) end)
	end,
}

SEQUENCES.Dio = {
	Skill1 = function(self, r, a) -- Time Skip: a burst where you vanish (left behind), gone while the dash carries you ~45 studs on,
		-- and a burst where you reappear. The authored screen flash plays on your own screen
		local c = r.Character
		local reappear = timing("TimeSkipReappear", 0.2)
		self:PlayAnim(c, a.Anim or "TimeSkip")
		self:Flash(c, "Dio/TimeSkip/1stDio/ClapStart")
		self:EmitOn(c, "Dio/TimeSkip/TimeSKipVFX", "HumanoidRootPart", false)
		if not r.Remote then self:ScreenFlipbook("Dio/TimeSkip/TimeSKipVFX/ScreenVign") end
		self:After(0.04, function() self:Vanish(c, math.max(reappear - 0.04, 0.05)) end) -- (the white flash shows first)
		self:After(reappear, function() self:EmitOn(c, "Dio/TimeSkip/TimeSKipVFX", "HumanoidRootPart") end)
	end,
	Skill2 = function(self, r, a) -- Knives: the throw burst and 3 knives in a fan, at the release
		local c = r.Character
		self:PlayAnim(c, a.Anim or "KnifeThrow")
		self:Flash(c, "Dio/KnifeThrow/2ndDio/ClapStart")
		self:After(timing("KnifeRelease", 0.3), function()
			local target = self:FindTarget(r, settings().TargetRange or 160, true)
			self:EmitOn(c, "Dio/KnifeThrow/ThrowingIt", "HumanoidRootPart", true, towards(r, target))
			for i, spread in ipairs({ -7, 0, 7 }) do
				self:After((i - 1) * 0.06, function() self:Throw(r, "Knife", spread, target) end)
			end
		end)
	end,
	Ultimate = function(self, r, a) -- Za Warudo: cutscene + ult animation. When the arms fling up (the camera cuts) the dome bursts,
		-- the authored vignette plays on your screen and the world goes grey for as long as time is stopped (Duration). Who
		-- freezes is the server's call ("Frozen": ShowFrozen)
		local c = r.Character
		self:PlayAnim(c, a.Anim or "TimeStopUlt")
		self:Flash(c, "Dio/TimeStop/3rdDio/ClapStart")
		self:PlayCutscene(r, "Dio/TimeStop/CamRigWithLetterBox3", "TimeStopCam")
		self:After(timing("ZaWarudo", 0.55), function()
			self:EmitOn(c, "Dio/TimeStop/TimeStopVFX", "HumanoidRootPart")
			if not r.Remote then self:ScreenFlipbook("Dio/TimeStop/TimeStopVFX/ScreenVign", 2.6) end
			if not r.Remote or settings().RemoteScreenEffects then self:TimeStopScreen(a.Duration or 5) end
		end)
	end,
}

function AbilityVFX:Play(characterId, slot, rider)
	if settings().Enabled == false then return end
	local sequence = SEQUENCES[characterId] and SEQUENCES[characterId][slot]
	if not (sequence and rider and rider.Character and rider.Character.Parent) then return end
	local ability = abilityOf(characterId, slot) or {}
	task.spawn(function()
		local ok, err = pcall(sequence, self, rider, ability)
		if not ok then warn("[AbilityVFX] " .. tostring(characterId) .. " " .. tostring(slot) .. ": " .. tostring(err)) end
	end)
end

return AbilityVFX
