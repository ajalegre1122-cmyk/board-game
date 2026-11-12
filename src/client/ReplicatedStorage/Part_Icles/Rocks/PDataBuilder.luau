--[[
	Rocks/PDataBuilder  -  per-burst pData construction + chunk rolls, shared by
	Emit + Animate + the AnimateLoop refresh. rollChunks resets EVERY rig slot
	(including parked ones) so no state survives a pooled prior life: rolled
	Sizes/CFrames are written to the anchored parts, spawn poses + launch
	velocities land in rig buffers as trajectory seeds (Rocks/init.luau
	buildTrajectories).
]]

local GraphMod = require(script.Parent.Parent.Graph)
local RangeMod = require(script.Parent.Parent.Range)
local Constants = require(script.Parent.Parent.PartConstants)

local DirectionVectors = Constants.DirectionVectors
local FAR_CFRAME = CFrame.new(1e9, 1e9, 1e9)

local PDataBuilder = {}

local function rollRange(r)
	return RangeMod.RandomValueFromRange(r)
end

-- EvenDistribution: chunk i of n samples a deterministic spread across the range.
local function rollAxis(r, even, i, n)
	if even and n > 0 then
		return r.Min + (r.Max - r.Min) * ((i - 0.5) / n)
	end
	return RangeMod.RandomValueFromRange(r)
end

-- Random unit vector.
local function randomAxis()
	local v = Vector3.new(math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1)
	if v.Magnitude < 1e-3 then return Vector3.yAxis end
	return v.Unit
end

-- Launch direction for chunk i of n in the emitter frame, returned in WORLD space.
-- Directional: authored EmissionDirection ± SpreadAngle. Ring: even azimuth around
-- the EmissionDirection axis, elevated by SpreadAngle.X degrees (ground-slam ring).
local function launchDir(data, originCF, i, n)
	local dirInfo = DirectionVectors[data.EmissionDirection] or DirectionVectors[Enum.NormalId.Top]
	local axis = CFrame.new()[dirInfo.vector] * dirInfo.multiplier
	if data.BurstMode == "Ring" then
		local u = axis:Cross(Vector3.xAxis)
		if u.Magnitude < 0.01 then u = axis:Cross(Vector3.zAxis) end
		u = u.Unit
		local v = axis:Cross(u)
		local az = ((i - 0.5) / n) * 2 * math.pi + (math.random() - 0.5) * 0.2
		local elev = math.rad(data.SpreadAngle.X)
		local dirLocal = (u * math.cos(az) + v * math.sin(az)) * math.cos(elev) + axis * math.sin(elev)
		return originCF.Rotation:VectorToWorldSpace(dirLocal)
	end
	local spread = data.SpreadAngle or Vector2.new(0, 0)
	local cf = CFrame.lookAt(Vector3.zero, axis)
	if spread.X > 0 or spread.Y > 0 then
		cf = cf * CFrame.Angles(
			math.rad((math.random() * 2 - 1) * spread.X),
			math.rad((math.random() * 2 - 1) * spread.Y), 0)
	end
	return originCF.Rotation:VectorToWorldSpace(cf.LookVector)
end

-- Roll + reset every chunk slot from the origin pose: spawn poses + launch
-- velocities are the SEEDS for the predetermined trajectories (Rocks/init.luau
-- buildTrajectories); rolled Sizes/CFrames are written to the anchored parts.
-- Slots past the rolled count park at FAR_CFRAME so pooled leftovers never show.
function PDataBuilder.rollChunks(pData, data, rig, originCF)
	local rtSize = (data.RenderTemplate and data.RenderTemplate:IsA("BasePart")) and data.RenderTemplate.Size or Vector3.new(1, 1, 1)
	local count = math.clamp(math.floor(rollRange(data.ChunkCount) + 0.5), 1, rig.chunkCap)
	pData._chunkCount = count
	local scale0 = data.Scale and GraphMod.QueryPointsWithTime(0, data.Scale, pData.Seeds.Scale) or 1
	pData._curScale = scale0
	for i = 1, rig.chunkCap do
		local chunk = rig.parts[i]
		if i <= count then
			local px = rollAxis(data.PosX, data.PosXEven, i, count)
			local py = rollAxis(data.PosY, data.PosYEven, i, count)
			local pz = rollAxis(data.PosZ, data.PosZEven, i, count)
			local pos
			if data.PosMode == "Global" then
				pos = originCF.Position + Vector3.new(px, py, pz)
			else
				pos = (originCF * CFrame.new(px, py, pz)).Position
			end
			rig.baseSize[i] = rtSize * rollRange(data.ChunkScale)
			rig.halfExt[i] = rig.baseSize[i] * 0.5
			-- Per-chunk launch speed: envelope seed = spawn-time variation.
			local speed = data.Speed and GraphMod.QueryPointsWithTime(0, data.Speed, GraphMod.GenerateSeed(data.Speed)) or 0
			local launchV = launchDir(data, originCF, i, count) * speed
			local axis = randomAxis()
			local tumble = math.rad(rollRange(data.TumbleSpeed)) * (math.random() < 0.5 and -1 or 1)
			local rot = CFrame.Angles(math.random() * 6.283, math.random() * 6.283, math.random() * 6.283)
			-- Trajectory seeds (Rocks/init.luau builds the full predetermined
			-- path from these at emit).
			rig.launchVel[i] = launchV
			rig.launchAng[i] = axis * tumble
			rig.spawnPos[i] = pos
			rig.spawnRot[i] = rot
			rig.trajs[i] = nil
			rig.bounciness[i] = math.clamp(rollRange(data.Bounciness), 0, 1)
			rig.gravity[i] = rollRange(data.Gravity)
			rig.friction[i] = math.clamp(rollRange(data.Friction), 0, 1)
			rig.touched[i] = false
			rig.writeCFs[i] = rot + pos
			pcall(function()
				chunk.Size = rig.baseSize[i] * math.max(scale0, 0.01)
				chunk.CFrame = rot + pos
			end)
		else
			pcall(function()
				chunk.Anchored = true
				chunk.CanCollide = false
				chunk.CanTouch = false
				chunk.CFrame = FAR_CFRAME
			end)
			rig.launchVel[i] = Vector3.zero
			rig.launchAng[i] = Vector3.zero
			rig.spawnPos[i] = FAR_CFRAME.Position
			rig.spawnRot[i] = CFrame.identity
			rig.trajs[i] = nil
			rig.touched[i] = false
			rig.writeCFs[i] = FAR_CFRAME
		end
	end
end

function PDataBuilder.build(item, data, model, rig, lifeTime, emitCtx, link)
	local seeds = {
		Scale = GraphMod.GenerateSeed(data.Scale),
		Brightness = GraphMod.GenerateSeed(data.Brightness),
		Transparency = GraphMod.GenerateSeed(data.Transparency),
		Timescale = GraphMod.GenerateSeed(data.Timescale),
	}
	local pData = {
		Type = "Rocks",
		VisualPart = model,
		_rig = rig,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		LifeTime = lifeTime,
		PartLife = data.PartLife or 0,
		_sourceItem = item,
		Graphs = {
			Scale = data.Scale,
			Brightness = data.Brightness,
			Transparency = data.Transparency,
			Timescale = data.Timescale,
			Color = data.Color,
		},
		Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.Timescale, seeds.Timescale, lifeTime),
		_sinkOut = data.SinkOut ~= false,
		_inheritFloor = data.InheritFloor == true,
		_hitPerChunk = data.HitPerChunk == true,
		_hitFired = false,
		-- OnHit fires from the precomputed first impact (Rocks/init.luau); the
		-- generic Events.afterUpdate raycast + Collision actions must skip this pData.
		_ownsOnHit = true,
	}

	-- Origin: event override → live parent clone (nested emit) → source pose.
	-- Sampled ONCE at emit; chunks fly world-space and never track the source after.
	local originCF
	if emitCtx then
		local oCF
		if emitCtx.EventOriginResolver then oCF = emitCtx.EventOriginResolver() end
		oCF = oCF or emitCtx.EventOriginCF
		if oCF then
			originCF = (emitCtx.UseFullOrigin and oCF) or CFrame.new(oCF.Position) * item.CFrame.Rotation
		end
	end
	if not originCF and link and link.Parent then
		originCF = Constants.resolveLinkCFrame(link)
	end
	-- The rig Model has no PrimaryPart, so an unset WorldPivot tracks the live bbox, which the
	-- 1e9-parked slots drag away; stamp the burst origin so nested links read it (Lightning does the same).
	pcall(function() model.WorldPivot = originCF or item.CFrame end)
	PDataBuilder.rollChunks(pData, data, rig, originCF or item.CFrame)
	return pData
end

return PDataBuilder
