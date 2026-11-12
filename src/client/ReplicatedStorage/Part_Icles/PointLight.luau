--[[
	Light mixin  -  Emit + Update for PointLight / SpotLight / SurfaceLight particles.
	Property-only animation (Range / Brightness / Color / Angle over life), no spatial motion.
]]

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local Pool = require(script.Parent.Pool)
local VisualHost = require(script.Parent.VisualHost)

return function(Particle)

function Particle:UpdatePointLight(pData, dt, currentTime)
	-- Timescale v2 (signed reverse): see Update.luau UpdatePart. SetTimescale override wins for its window.
	local real_i = math.min(math.max((currentTime - pData.StartTime) / pData.LifeTime, 0), 1)
	local ts
	if pData._tsOverride ~= nil and currentTime < (pData._tsOverrideUntil or 0) then
		ts = pData._tsOverride
	else
		ts = pData.Graphs.Timescale and GraphMod.QueryPointsWithTime(real_i, pData.Graphs.Timescale, pData.Seeds.Timescale) or 1
	end
	local dtTs = dt * ts
	local lifeTime = pData.LifeTime
	local priorEff = pData._effectiveElapsed or 0
	local newEff = priorEff + (pData._timeFrozen and 0 or dtTs)
	if newEff < 0 then newEff = 0 end
	if newEff > lifeTime then newEff = lifeTime end
	pData._effectiveElapsed = newEff
	local atForwardEnd = newEff >= lifeTime
	local atBackwardEnd = newEff <= 0
	local elapsedTime = newEff
	local i = elapsedTime / lifeTime

	if not pData.VisualPart or not pData.VisualPart.Parent then return true end
	if pData.TotalKeyFrames <= 0 then return true end
	-- Riding a parent visual: die when the parent pData reclaims (see EmitPointLight).
	if pData._parentAlive and not pData._parentAlive[1] then return true end
	local graphFinished = real_i >= 1
	local isDying = graphFinished and (atForwardEnd or atBackwardEnd)
	i = math.min(math.max(i, 0), 1)

	local targetStep = math.floor(i * pData.TotalKeyFrames)

	if targetStep ~= pData.CurrentStep then
		pData.CurrentStep = targetStep
		local steppedI = pData.CurrentStep / pData.TotalKeyFrames

		local range, brightness, color, angle
		if pData.Graphs.PLRange then
			range = GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.PLRange, pData.Seeds.PLRange)
			pData.VisualPart.Range = range
		end
		if pData.Graphs.PLBrightness and not pData.SkipTransparency then
			brightness = GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.PLBrightness, pData.Seeds.PLBrightness)
			pData.VisualPart.Brightness = brightness
		end
		if pData.Graphs.PLColor and not pData.SkipColor then
			color = GraphMod.QueryColorPointWithTime(steppedI, pData.Graphs.PLColor)
			pData.VisualPart.Color = color
		end
		if pData._hasCone and pData.Graphs.PLAngle then
			angle = GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.PLAngle, pData.Seeds.PLAngle)
			pData.VisualPart.Angle = angle
		end
		local extras = pData._extraLights
		if extras then
			for j = 1, #extras do
				local extraLight = extras[j]
				if range then extraLight.Range = range end
				if brightness then extraLight.Brightness = brightness end
				if color then extraLight.Color = color end
				if angle then extraLight.Angle = angle end
			end
		end
	end

	return isDying
end

function Particle:EmitPointLight(light, link, emitCtx)
	if not light or not light.Parent then return end
	local data = self:GetEmitData(light, emitCtx)
	if not data or not data.RenderTemplate then return end

	-- PoolHide flipped Enabled=false on release; flip back here.
	local visualLight = Pool.acquireOrClone(data.RenderTemplate, "PointLight", data.Pool)
	visualLight.Archivable = false
	visualLight.Enabled = true
	if data.Shadows ~= nil then visualLight.Shadows = data.Shadows end
	-- EmitParent (user intent) > link (a local clone) > a carrier mirroring the source's parent so
	-- the light never parents into the user's own part (Team Create replication).
	local parentPart = data.EmitParent or link
	local carrier = nil
	if not parentPart then
		local anchor = light.Parent
		if anchor and (anchor:IsA("BasePart") or anchor:IsA("Attachment")) then
			carrier = VisualHost.acquireCarrier(anchor)
			parentPart = carrier
		else
			parentPart = anchor
		end
	end
	-- Lights only render under a BasePart/Attachment. A Model link resolves to a
	-- BasePart child: middle part for Model emitters; ALL segments for Lightning
	-- bolts (per-segment clone fan-out below so the whole bolt glows).
	local boltParts = nil
	if parentPart and parentPart:IsA("Model") then
		local parts = nil
		for _, child in ipairs(parentPart:GetChildren()) do
			if child:IsA("BasePart") then
				parts = parts or {}
				parts[#parts + 1] = child
			end
		end
		if parts then
			if parentPart:GetAttribute("_lightningBolt") then
				boltParts = parts
				parentPart = parts[1]
			else
				parentPart = parts[math.ceil(#parts / 2)]
			end
		end
	end

	local safeLifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if safeLifeTime <= 0 then safeLifeTime = 0.001 end

	local seedRange = data.PLRange and GraphMod.GenerateSeed(data.PLRange) or {}
	local seedBright = data.PLBrightness and GraphMod.GenerateSeed(data.PLBrightness) or {}
	local seedAngle = data.PLAngle and GraphMod.GenerateSeed(data.PLAngle) or {}
	local seedTimescale = GraphMod.GenerateSeed(data.PLTimescale)

	-- Apply initial values before parenting (1-frame pop prevention).
	if data.PLRange then
		visualLight.Range = GraphMod.QueryPointsWithTime(0, data.PLRange, seedRange)
	end
	if data.PLBrightness then
		visualLight.Brightness = GraphMod.QueryPointsWithTime(0, data.PLBrightness, seedBright)
	end
	if data.PLColor then
		visualLight.Color = GraphMod.QueryColorPointWithTime(0, data.PLColor)
	end
	-- Spot / Surface lights carry a cone; PointLight has neither Angle nor Face.
	local hasCone = visualLight:IsA("SpotLight") or visualLight:IsA("SurfaceLight")
	if hasCone then
		if data.PLFace then visualLight.Face = data.PLFace end
		if data.PLAngle then visualLight.Angle = GraphMod.QueryPointsWithTime(0, data.PLAngle, seedAngle) end
	end

	visualLight.Parent = parentPart

	-- Lightning per-segment fan-out: clone the initialized light onto every other
	-- segment; UpdatePointLight drives clones with the same stepped values and
	-- _releaseOrDestroy destroys them (pooled bolts must not retain foreign lights).
	-- Archivable flips because Clone() returns nil on Archivable=false instances.
	local extraLights = nil
	if boltParts and #boltParts > 1 then
		visualLight.Archivable = true
		extraLights = table.create(#boltParts - 1)
		for j = 2, #boltParts do
			local extra = visualLight:Clone()
			extra.Archivable = false
			extra.Parent = boltParts[j]
			extraLights[j - 1] = extra
		end
		visualLight.Archivable = false
	end

	local pData = {
		Type = "PointLight",
		_carrier = carrier,
		_hasCone = hasCone,
		VisualPart = visualLight,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		LifeTime = safeLifeTime,
		PartLife = data.PartLife or 0,

		Graphs = {
			PLRange = data.PLRange,
			PLBrightness = data.PLBrightness,
			PLColor = data.PLColor,
			PLAngle = data.PLAngle,
			Timescale = data.PLTimescale,
		},
		Seeds = {
			PLRange = seedRange,
			PLBrightness = seedBright,
			PLAngle = seedAngle,
			Timescale = seedTimescale,
		},
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.PLTimescale, seedTimescale, safeLifeTime),
	}

	pData._sourceItem = light
	pData._extraLights = extraLights
	-- Parented INSIDE the emitted visual, the light must die with it, or a pooled
	-- parent carries live foreign lights back into the pool (ghost lights on
	-- reuse). EmitParent'd lights live elsewhere and keep their own lifetime.
	if emitCtx and emitCtx._parentAlive and not data.EmitParent then
		pData._parentAlive = emitCtx._parentAlive
	end
	Particle._seedTsOverride(pData, light)
	if data.Pool ~= false then pData._sourceRT, pData._poolKind = data.RenderTemplate, "PointLight" end
	self:_registerEmit(pData, emitCtx)
end

end
