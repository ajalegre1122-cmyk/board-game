--[[
	PreSimulate Mixin  -  step-by-step forward motion pre-simulation, split from
	Transform.luau (500-line cap).
	  :PreSimulateForward / :PreSimulateAttachmentForward  -  return local CFrames per
	    step without emitting. Used by Motion Preview, by Emit for InvertMotion's
	    SimLocalCFrames cache, and by EngineReplay's per-cycle cache rebuild.
]]

local GraphMod = require(script.Parent.Graph)
local Constants = require(script.Parent.PartConstants)
local LinkCF = require(script.Parent.LinkCF)
local Turbulence = require(script.Parent.Turbulence)
local DirectionVectors = Constants.DirectionVectors

return function(Particle)

-- Walk a Part/Beam/Model emit's motion forward step-by-step and return the per-step local CFrames.
-- Called by Motion Preview to draw trajectory lines in the viewport; also reused inside Emit so
-- the live simulation matches the preview without re-deriving the math. The CFrames are local to
-- `parentCF` (Link target or world origin) so a moving Link naturally carries the path with it.
function Particle:PreSimulateForward(data, seeds, initialCF, baseDirection, spreadRotation, link, lifetime, previewMaxSteps, spawnEmitterRotation, linkLocal, maskRefCF)
	local linkMode = data.LinkMode or "Follow"
	-- maskRefCF (the emitter's own frame) engages the per-axis link masks exactly as the emit does.
	local parentCF = LinkCF.emitParentFrame(linkMode, link, linkLocal, maskRefCF and data.LinkAxes or nil, maskRefCF)
	local useVOS = LinkCF.usesLinkSpace(linkMode, link)
	-- previewMaxSteps caps preview callers; InvertMotion caps emit (per-particle CFrame allocation).
	local INVERT_MAX_STEPS = 500
	local totalKeyFrames = math.max(1, data.TotalKeyFrames)
	if previewMaxSteps and totalKeyFrames > previewMaxSteps then
		totalKeyFrames = previewMaxSteps
	elseif data.InvertMotion and totalKeyFrames > INVERT_MAX_STEPS then
		totalKeyFrames = INVERT_MAX_STEPS
	end
	local stepDT = lifetime / totalKeyFrames

	local currentPosition = initialCF.Position
	local localCF = parentCF:ToObjectSpace(initialCF)
	local baseDir = baseDirection
	local emissionDirection = data.EmissionDirection
	local rotMode = data.RotMode or "OverLife"
	local accRotX, accRotY, accRotZ = 0, 0, 0

	-- Snapshot AccelTarget pos at start; InvertMotion's cached CFrames can't track moving targets.
	local hasTargetAccel = data.AccelerationTowardsInstance == true and data.AccelTarget ~= nil and data.AccelStrength ~= nil and not data.InvertMotion
	local targetWorldPos
	if hasTargetAccel then
		local t = data.AccelTarget
		-- Type dispatch matches Update.getTargetPosition (Bone live pose, Model pivot, etc.).
		if t:IsA("Bone") then targetWorldPos = t.TransformedWorldCFrame.Position
		elseif t:IsA("BasePart") then targetWorldPos = t.Position
		elseif t:IsA("Attachment") then targetWorldPos = t.WorldPosition
		elseif t:IsA("Model") then local ok, cf = pcall(t.GetPivot, t); if ok and cf then targetWorldPos = cf.Position end
		end
		if not targetWorldPos then hasTargetAccel = false end
	end
	local targetVel = Vector3.zero
	local accelStrengthSeed = seeds.AccelStrength or {}

	-- PosOffset trajectory state for the precomputation loop. DisplacementMode +
	-- spawnEmitterRotation flow through Constants.resolveDisplacement below so the
	-- cached SimLocalCFrames honour the same frame the live Update.luau path uses.
	-- When spawnEmitterRotation is nil (preview path) it falls back to spawnRotation,
	-- degrading RigidLocal to Local for preview (preview is single-particle, no rotXYZ).
	local hasPosOffset = data.PosOffsetX ~= nil or data.PosOffsetY ~= nil or data.PosOffsetZ ~= nil
	-- Under a useVOS link, capture spawnRotation link-local (matches the live Update path,
	-- Emit.luau:598) so a Local-mode PosOffset is link-local and the no-VOS branch below
	-- mirrors Update._composeLocalDelta (F30 parity — keep these two copies in sync).
	local spawnRotation = useVOS and (parentCF:ToObjectSpace(initialCF)).Rotation or initialCF.Rotation
	local prevWorldOff = Vector3.zero

	-- Turbulence wander (F30 parity with Update._posOffsetFrameDelta's Turbulence
	-- branch). Seeds roll lazily INTO the shared seeds table so the live emit's
	-- Turbulence.buildInto reuses them  -  InvertMotion replay matches this pre-sim.
	local turbGraph = Turbulence.isLive(data.Turbulence)
	local prevTurbOff = Vector3.zero
	if turbGraph then
		seeds.Turbulence = seeds.Turbulence or GraphMod.GenerateSeed(turbGraph)
		seeds._turbSeed = seeds._turbSeed or (math.random() * 997 + 0.5)
		prevTurbOff = Constants.resolveDisplacement(
			Turbulence.sampleRaw(turbGraph, seeds.Turbulence, seeds._turbSeed, data.TurbulenceFrequency or 1, lifetime, 0),
			data.DisplacementMode or "Global", spawnRotation, spawnEmitterRotation or spawnRotation)
	end

	local localCFrames = {}
	localCFrames[0] = parentCF:ToObjectSpace(initialCF)

	for step = 1, totalKeyFrames do
		local steppedI = step / totalKeyFrames
		local elapsedSec = steppedI * lifetime

		local speed = GraphMod.QueryPointsWithTime(steppedI, data.Speed, seeds.Speed)
		local draggedSpeed = speed * math.exp(-data.ParticleData.Drag * elapsedSec)

		local accelVelocity = data.ParticleData.Acceleration * elapsedSec

		local displacement = (baseDir * draggedSpeed + accelVelocity) * stepDT

		if hasTargetAccel then
			local toTarget = targetWorldPos - currentPosition
			local dist = toTarget.Magnitude
			if dist > 1e-4 then
				local mag = GraphMod.QueryPointsWithTime(steppedI, data.AccelStrength, accelStrengthSeed)
				if mag and mag ~= 0 then
					targetVel = targetVel + toTarget * (mag * stepDT / dist)
					displacement = displacement + targetVel * stepDT
				end
			end
		end

		local posDelta = Vector3.zero
		if hasPosOffset then
			local oX = data.PosOffsetX and GraphMod.QueryPointsWithTime(steppedI, data.PosOffsetX, seeds.PosOffsetX) or 0
			local oY = data.PosOffsetY and GraphMod.QueryPointsWithTime(steppedI, data.PosOffsetY, seeds.PosOffsetY) or 0
			local oZ = data.PosOffsetZ and GraphMod.QueryPointsWithTime(steppedI, data.PosOffsetZ, seeds.PosOffsetZ) or 0
			local worldOff = Constants.resolveDisplacement(Vector3.new(oX, oY, oZ),
				data.DisplacementMode or "Global", spawnRotation,
				spawnEmitterRotation or spawnRotation)
			posDelta = worldOff - prevWorldOff
			prevWorldOff = worldOff
		end
		if turbGraph then
			local turbOff = Constants.resolveDisplacement(
				Turbulence.sampleRaw(turbGraph, seeds.Turbulence, seeds._turbSeed, data.TurbulenceFrequency or 1, lifetime, steppedI),
				data.DisplacementMode or "Global", spawnRotation, spawnEmitterRotation or spawnRotation)
			posDelta = posDelta + (turbOff - prevTurbOff)
			prevTurbOff = turbOff
		end

		-- F30 parity with Update._composeLocalDelta: VOS only the world velocity into
		-- link-local; a Local-mode offset is already link-local (spawnRotation captured
		-- link-local) so add it as-is — else a spinning Weld precesses it.
		local posIsLinkLocal = useVOS and (data.DisplacementMode or "Global") == "Local"
		local velLocal = useVOS and parentCF:VectorToObjectSpace(displacement) or displacement
		local posLocal = (useVOS and not posIsLinkLocal) and parentCF:VectorToObjectSpace(posDelta) or posDelta
		localCF = CFrame.new(velLocal + posLocal) * localCF

		local rotSpeedX = GraphMod.QueryPointsWithTime(steppedI, data.RotSpeedX, seeds.RotSpeedX)
		local rotSpeedY = GraphMod.QueryPointsWithTime(steppedI, data.RotSpeedY, seeds.RotSpeedY)
		local rotSpeedZ = GraphMod.QueryPointsWithTime(steppedI, data.RotSpeedZ, seeds.RotSpeedZ)

		local rotCF
		local rotOrder = data.RotOrder or "Global"
		if rotMode == "Speed" then
			accRotX = accRotX + rotSpeedX * stepDT
			accRotY = accRotY + rotSpeedY * stepDT
			accRotZ = accRotZ + rotSpeedZ * stepDT
			rotCF = Constants.composeRotation(rotOrder, accRotX, accRotY, accRotZ)
		else
			rotCF = Constants.composeRotation(rotOrder, rotSpeedX, rotSpeedY, rotSpeedZ)
		end

		local worldCF = (parentCF * localCF) * rotCF
		currentPosition = worldCF.Position

		if data.VelocityVectored then
			local dirInfo = DirectionVectors[emissionDirection] or DirectionVectors[Enum.NormalId.Top]
			baseDir = (worldCF * spreadRotation)[dirInfo.vector] * dirInfo.multiplier
		end

		localCFrames[step] = parentCF:ToObjectSpace(worldCF)
	end

	return localCFrames, totalKeyFrames
end

-- Attachment variant: no Link param, attachment-local space (initialCF doubles as localCF).
function Particle:PreSimulateAttachmentForward(data, seeds, initialCF, baseDirection, spreadRotation, lifetime, previewMaxSteps, spawnEmitterRotation)
	local INVERT_MAX_STEPS = 500
	local totalKeyFrames = math.max(1, data.TotalKeyFrames)
	if previewMaxSteps and totalKeyFrames > previewMaxSteps then
		totalKeyFrames = previewMaxSteps
	elseif data.InvertMotion and totalKeyFrames > INVERT_MAX_STEPS then
		totalKeyFrames = INVERT_MAX_STEPS
	end
	local stepDT = lifetime / totalKeyFrames

	local localCF = initialCF
	local baseDir = baseDirection
	local emissionDirection = data.EmissionDirection
	local rotMode = data.RotMode or "OverLife"
	local accRotX, accRotY, accRotZ = 0, 0, 0
	-- AccelerationTowardsInstance not integrated here (local-space mismatch with world target).
	-- Preview Attachment trajectories diverge from live emit when target accel is enabled.

	-- PosOffset trajectory state. Routes through Constants.resolveDisplacement with
	-- DisplacementMode + spawnEmitterRotation so cached frames match live Update path.
	local hasPosOffset = data.PosOffsetX ~= nil or data.PosOffsetY ~= nil or data.PosOffsetZ ~= nil
	local spawnRotation = initialCF.Rotation
	local prevWorldOff = Vector3.zero

	-- Turbulence wander; seed handling mirrors PreSimulateForward above.
	local turbGraph = Turbulence.isLive(data.Turbulence)
	local prevTurbOff = Vector3.zero
	if turbGraph then
		seeds.Turbulence = seeds.Turbulence or GraphMod.GenerateSeed(turbGraph)
		seeds._turbSeed = seeds._turbSeed or (math.random() * 997 + 0.5)
		prevTurbOff = Constants.resolveDisplacement(
			Turbulence.sampleRaw(turbGraph, seeds.Turbulence, seeds._turbSeed, data.TurbulenceFrequency or 1, lifetime, 0),
			data.DisplacementMode or "Global", spawnRotation, spawnEmitterRotation or spawnRotation)
	end

	local localCFrames = {}
	localCFrames[0] = initialCF

	for step = 1, totalKeyFrames do
		local steppedI = step / totalKeyFrames
		local elapsedSec = steppedI * lifetime

		local speed = GraphMod.QueryPointsWithTime(steppedI, data.Speed, seeds.Speed)
		local draggedSpeed = speed * math.exp(-data.ParticleData.Drag * elapsedSec)

		local accelVelocity = data.ParticleData.Acceleration * elapsedSec
		local displacement = (baseDir * draggedSpeed + accelVelocity) * stepDT

		if hasPosOffset then
			local oX = data.PosOffsetX and GraphMod.QueryPointsWithTime(steppedI, data.PosOffsetX, seeds.PosOffsetX) or 0
			local oY = data.PosOffsetY and GraphMod.QueryPointsWithTime(steppedI, data.PosOffsetY, seeds.PosOffsetY) or 0
			local oZ = data.PosOffsetZ and GraphMod.QueryPointsWithTime(steppedI, data.PosOffsetZ, seeds.PosOffsetZ) or 0
			local worldOff = Constants.resolveDisplacement(Vector3.new(oX, oY, oZ),
				data.DisplacementMode or "Global", spawnRotation,
				spawnEmitterRotation or spawnRotation)
			displacement = displacement + (worldOff - prevWorldOff)
			prevWorldOff = worldOff
		end
		if turbGraph then
			local turbOff = Constants.resolveDisplacement(
				Turbulence.sampleRaw(turbGraph, seeds.Turbulence, seeds._turbSeed, data.TurbulenceFrequency or 1, lifetime, steppedI),
				data.DisplacementMode or "Global", spawnRotation, spawnEmitterRotation or spawnRotation)
			displacement = displacement + (turbOff - prevTurbOff)
			prevTurbOff = turbOff
		end

		localCF = CFrame.new(displacement) * localCF

		-- Rotation
		local rotSpeedX = GraphMod.QueryPointsWithTime(steppedI, data.RotSpeedX, seeds.RotSpeedX)
		local rotSpeedY = GraphMod.QueryPointsWithTime(steppedI, data.RotSpeedY, seeds.RotSpeedY)
		local rotSpeedZ = GraphMod.QueryPointsWithTime(steppedI, data.RotSpeedZ, seeds.RotSpeedZ)

		local rotCF
		local rotOrder = data.RotOrder or "Global"
		if rotMode == "Speed" then
			accRotX = accRotX + rotSpeedX * stepDT
			accRotY = accRotY + rotSpeedY * stepDT
			accRotZ = accRotZ + rotSpeedZ * stepDT
			rotCF = Constants.composeRotation(rotOrder, accRotX, accRotY, accRotZ)
		else
			rotCF = Constants.composeRotation(rotOrder, rotSpeedX, rotSpeedY, rotSpeedZ)
		end

		local worldCF = localCF * rotCF

		if data.VelocityVectored then
			local dirVecInfo = DirectionVectors[emissionDirection] or DirectionVectors[Enum.NormalId.Top]
			baseDir = (worldCF * spreadRotation)[dirVecInfo.vector] * dirVecInfo.multiplier
		end

		localCFrames[step] = worldCF
	end

	return localCFrames, totalKeyFrames
end

end
