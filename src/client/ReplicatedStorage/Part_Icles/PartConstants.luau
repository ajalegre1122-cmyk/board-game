--[[
	PartConstants  -  lookup tables and helpers shared by Emit / Update / Transform.
	  DirectionVectors[NormalId] → (axis, multiplier) for CFrame component reads.
	  shapeFunctions[ParticleEmitterShape] → (offset, rotation, direction) per shape.
	  resolveLinkCFrame, composeRotation, applyPositionOffset  -  see per-function comments.
]]

local PartConstants = {}

-- Type-dispatched world CFrame: Bone→TransformedWorldCFrame (animated pose), Attachment→WorldCFrame,
-- Model→GetPivot, else .CFrame. Bone inherits Attachment, so its test must run first.
function PartConstants.resolveLinkCFrame(link)
	if link:IsA("Bone") then return link.TransformedWorldCFrame end
	if link:IsA("Attachment") then return link.WorldCFrame end
	if link:IsA("Model") then return link:GetPivot() end
	return link.CFrame
end

-- Compounded scale factor of a nested particle's parent-Model CHAIN. `parentScale` is
-- `pData.ParentScale`, a linked list via `.Parent` (Model→Model→… ; Parts forward the same
-- node). Each node is { Owner = the Model's pData, ScaleMotion, ScaleRotation,
-- ScaleTextureLength, Parent }: the level's factor is the owner's `_ownScale`, published by
-- UpdateModel from its own timescaled step (so replay cycles and Timescale stay in sync), or
-- its Scale graph at its own elapsed time before the first step. nil → 1. GraphMod passed in
-- so PartConstants stays require-free. `gate`: nil = all levels (Size/visual); "motion" =
-- only levels with ScaleMotion; "rotation" = only levels with ScaleRotation.
function PartConstants.getParentScaleFactor(parentScale, currentTime, GraphMod, gate)
	local factor = 1
	local ps = parentScale
	while ps do
		local include = true
		if gate == "motion" then include = ps.ScaleMotion ~= false
		elseif gate == "rotation" then include = ps.ScaleRotation == true end
		if include then
			local owner = ps.Owner
			local levelF = owner and owner._ownScale
			if not levelF then
				if owner and owner._staticScale then
					levelF = owner._staticScale
				elseif owner and owner.Graphs and owner.Graphs.Scale then
					local pI = math.clamp((currentTime - owner.StartTime) / owner.LifeTime, 0, 1)
					levelF = GraphMod.QueryPointsWithTime(pI, owner.Graphs.Scale, owner.Seeds.Scale)
				else
					levelF = 1
				end
			end
			factor = factor * math.max(0.001, levelF)
		end
		ps = ps.Parent
	end
	return factor
end

-- LocalABC entries are intrinsic Tait-Bryan Euler (body-frame composition, left-to-right).
-- Global (default) is the legacy Y*X*Z composition around fixed world axes; preserved so
-- existing saves don't shift visually on update. When the emission axis aligns with a
-- rotation axis, intrinsic ordering can no-op that axis on the launch direction  -  Global
-- gives the typical spread-cone behaviour.
function PartConstants.composeRotation(order, rotXdeg, rotYdeg, rotZdeg)
	local rxCF = CFrame.Angles(math.rad(rotXdeg), 0, 0)
	local ryCF = CFrame.Angles(0, math.rad(rotYdeg), 0)
	local rzCF = CFrame.Angles(0, 0, math.rad(rotZdeg))
	if order == "LocalXYZ" then return rxCF * ryCF * rzCF end
	if order == "LocalXZY" then return rxCF * rzCF * ryCF end
	if order == "LocalYXZ" then return ryCF * rxCF * rzCF end
	if order == "LocalYZX" then return ryCF * rzCF * rxCF end
	if order == "LocalZXY" then return rzCF * rxCF * ryCF end
	if order == "LocalZYX" then return rzCF * ryCF * rxCF end
	return ryCF * rxCF * rzCF -- Global default
end

PartConstants.DirectionVectors = {
	[Enum.NormalId.Top]    = {vector = "UpVector",    multiplier = 1},
	[Enum.NormalId.Bottom] = {vector = "UpVector",    multiplier = -1},
	[Enum.NormalId.Front]  = {vector = "LookVector",  multiplier = 1},
	[Enum.NormalId.Back]   = {vector = "LookVector",  multiplier = -1},
	[Enum.NormalId.Left]   = {vector = "RightVector", multiplier = -1},
	[Enum.NormalId.Right]  = {vector = "RightVector", multiplier = 1},
}

-- Each shape returns (offset, lookAtRotation, outwardDirection).
-- rotation applied only when LookAtInitially is true; direction sign-modulated by ShapeInOut.
PartConstants.shapeFunctions = {
	[Enum.ParticleEmitterShape.Box] = function(p, emitter)
		local Px = (math.random() * 2 - 1) * p.Size.X / 2
		local Py = (math.random() * 2 - 1) * p.Size.Y / 2
		local Pz = (math.random() * 2 - 1) * p.Size.Z / 2
		-- Box has no radial; use offset.Unit (origin-aligned falls back to world up).
		local offset = Vector3.new(Px, Py, Pz)
		local dir = offset.Magnitude > 1e-4 and offset.Unit or Vector3.yAxis
		local sRot = offset.Magnitude > 1e-4 and CFrame.lookAt(Vector3.new(), -dir) or CFrame.new()
		return offset, sRot, dir
	end,
	[Enum.ParticleEmitterShape.Sphere] = function(p, emitter)
		local outerRadius = p.Size.X / 2
		local innerRadius = outerRadius * emitter.ShapePartial
		local randomRadius = (math.random() * (outerRadius^3 - innerRadius^3) + innerRadius^3)^(1/3)
		local theta = math.random() * 2 * math.pi
		local phi = math.acos((math.random() * 2) - 1)
		local direction = Vector3.new(
			math.sin(phi) * math.cos(theta),
			math.sin(phi) * math.sin(theta),
			math.cos(phi)
		)
		return direction * randomRadius, CFrame.lookAt(Vector3.new(), -direction), direction
	end,
	[Enum.ParticleEmitterShape.Cylinder] = function(p, emitter)
		local radius = p.Size.X / 2
		local height = p.Size.Y
		-- Area-uniform annulus radius: F^-1(u) = sqrt(u*(1-h^2) + h^2).
		local h = math.clamp(emitter.ShapePartial, 0, 1)
		local randomRadius = math.sqrt(math.random() * (1 - h * h) + h * h)
		local angle = math.random() * 2 * math.pi
		local x = randomRadius * radius * math.cos(angle)
		local y = (math.random() * 2 - 1) * (height / 2)
		local z = randomRadius * radius * math.sin(angle)
		local localOffset = Vector3.new(x, y, z)
		local direction
		if math.abs(y) > (height / 2) - 0.01 then
			direction = Vector3.new(0, math.sign(y), 0)
		else
			local lateral = Vector3.new(x, 0, z)
			if lateral.Magnitude < 0.0001 then
				direction = Vector3.new(0, 1, 0)
			else
				direction = lateral.Unit
			end
		end
		return localOffset, CFrame.lookAt(Vector3.new(), -direction), direction
	end,
	[Enum.ParticleEmitterShape.Disc] = function(p, emitter)
		local radius = p.Size.X / 2
		-- Area-uniform annulus; matches Cylinder.
		local h = math.clamp(emitter.ShapePartial, 0, 1)
		local randomRadiusRatio = math.sqrt(math.random() * (1 - h * h) + h * h)
		local angle = math.random() * 2 * math.pi
		local x = randomRadiusRatio * radius * math.cos(angle)
		local z = randomRadiusRatio * radius * math.sin(angle)
		local localOffset = Vector3.new(x, 0, z)
		if localOffset.Magnitude < 0.0001 then
			return localOffset, CFrame.new(), Vector3.yAxis
		end
		local direction = localOffset.Unit
		return localOffset, CFrame.lookAt(Vector3.new(), -direction), direction
	end,
}

-- Apply PosX/Y/Z range offset to simCF.
-- simFrameCF: WORLD CFrame of the frame the caller's simCF is in. nil = world-space
-- sim (Part/Model siblings). For Attachment Emit: walked-up BasePart's CFrame. For
-- Attachment Animate: source attachment's WorldCFrame (composes arbitrary nest depth).
function PartConstants.applyPositionOffset(simCF, data, link, item, RangeMod, AxisLinksMod, emitCtx, simFrameCF, scaleFactor)
	-- AxisLinks-aware sampling so linked Pos followers stay correlated; emitCtx drives
	-- PosXEven/PosYEven/PosZEven even spread. Independent sampling is the fallback.
	local pxS, pyS, pzS
	if AxisLinksMod and data.AxisLinks then
		local s = AxisLinksMod.sampleRangeAxes(data, data.AxisLinks, {"PosX","PosY","PosZ"}, RangeMod, emitCtx)
		pxS, pyS, pzS = s.PosX, s.PosY, s.PosZ
	else
		pxS = RangeMod.RandomValueFromRange(data.PosX or NumberRange.new(0))
		pyS = RangeMod.RandomValueFromRange(data.PosY or NumberRange.new(0))
		pzS = RangeMod.RandomValueFromRange(data.PosZ or NumberRange.new(0))
	end
	local px, py, pz = pxS, pyS, pzS
	-- Nested-Model scale: a 2x model spawns its particles' Pos spread 2x wider.
	if scaleFactor and scaleFactor ~= 1 then
		px, py, pz = px * scaleFactor, py * scaleFactor, pz * scaleFactor
	end
	if px == 0 and py == 0 and pz == 0 then return simCF end
	local posMode = data.PosMode or "Local"

	if posMode == "Local" then
		return simCF * CFrame.new(px, py, pz)
	end

	local offset = Vector3.new(px, py, pz)
	local worldOffset
	if posMode == "Global" then
		worldOffset = offset
	else -- RigidLocal: rotate by source's WORLD frame; composes through full nest chain.
		local rotCF
		if link then
			rotCF = PartConstants.resolveLinkCFrame(link)
		elseif item:IsA("Attachment") then
			rotCF = item.WorldCFrame
		elseif item:IsA("Model") then
			rotCF = item:GetPivot()
		else
			rotCF = item.CFrame
		end
		worldOffset = rotCF:VectorToWorldSpace(offset)
	end

	-- Convert world offset → caller's sim frame. nil = sim is world-space.
	local applyOffset = simFrameCF and simFrameCF:VectorToObjectSpace(worldOffset) or worldOffset
	return CFrame.new(simCF.Position + applyOffset) * simCF.Rotation
end

-- Resolve a PosOffset graph sample (rawOff) into world-frame displacement based on
-- DisplacementMode. Shared across all 6 emit paths (Part/Attachment/Model × normal/animate)
-- and Update.luau's per-frame _posOffsetFrameDelta. Three modes:
--   "Global"     → no rotation (world axes)
--   "RigidLocal" → rotated by emitterRot (emitter frame at spawn, pre-RotXYZ)
--   "Local" (or unknown) → rotated by spawnRot (post-RotXYZ particle frame)
--
-- Optional mirrorX/Y/Z axes apply a post-rotation orthogonal transform  -  used by
-- OnHit Bounce to reflect the PosOffset trajectory about hit normals. Each bounce
-- reflects all three axes about hit.Normal, accumulating as a single 3-vector basis
-- (det may flip to -1 after an odd number of bounces  -  valid for displacement).
-- nil mirror axes (default at spawn) skip the matrix application.
function PartConstants.resolveDisplacement(rawOff, mode, spawnRot, emitterRot, mirrorX, mirrorY, mirrorZ)
	local frameOff
	if mode == "Global" then
		frameOff = rawOff
	elseif mode == "RigidLocal" then
		frameOff = emitterRot:VectorToWorldSpace(rawOff)
	else
		frameOff = spawnRot:VectorToWorldSpace(rawOff)
	end
	if mirrorX then
		return mirrorX * frameOff.X + mirrorY * frameOff.Y + mirrorZ * frameOff.Z
	end
	return frameOff
end

-- Skip Coulomb cancellation when |a · n| below this  -  body parallel to surface
-- (vertical-wall-grazing case) shouldn't have its full gravity stripped.
local FREEFALL_THRESHOLD = 10

-- Coulomb contact-constraint shaping for gravity during settle. Strips normal
-- component (surface reaction force) + applies friction force on tangent vel
-- bounded by μ·|aN|. Yields standard inclined-plane dynamics: g·sinθ − μ·g·cosθ.
function PartConstants.applyContactAccel(accel, pData, dt)
	if not (pData._settleEngaged and pData._lastHitNormal) then return accel end
	local n = pData._lastHitNormal
	if n.Magnitude < 1e-4 then return accel end
	local aN_dot = accel:Dot(n)
	-- Surface only pushes (Newton's 3rd is one-directional). Gravity pointing
	-- AWAY from surface means no contact, no constraint.
	if aN_dot >= 0 then return accel end
	-- Vertical-wall escape: body parallel to surface normal has near-zero
	-- normal component. Skip constraint so gravity drags it along the wall.
	if math.abs(aN_dot) < FREEFALL_THRESHOLD then return accel end
	local aN = aN_dot * n
	local aT = accel - aN
	local mu = (pData.Events and pData.Events.OnHit and pData.Events.OnHit.Friction) or 0.2
	local vT = Vector3.zero
	if pData._accelVel then
		local av = pData._accelVel
		vT = av - av:Dot(n) * n
	end
	local vT_mag = vT.Magnitude
	local maxFrictionAccel = mu * math.abs(aN_dot)
	if vT_mag > 1e-4 then
		-- Kinetic regime: friction opposes tangent velocity, capped at Coulomb cone.
		-- Static-lock clamp prevents friction from reversing tangent vel in one step.
		local frictionAccel = (-vT.Unit) * maxFrictionAccel
		if maxFrictionAccel * (dt or 1/60) > vT_mag then
			frictionAccel = -vT / (dt or 1/60)
		end
		return aT + frictionAccel
	end
	-- Static regime: |aT| ≤ μ·|aN| means friction holds the body still
	-- (tan(θ) ≤ μ on a slope). |aT| > μ·|aN| means slope exceeds friction cone;
	-- body starts sliding at the residual tangent accel.
	local aT_mag = aT.Magnitude
	if aT_mag <= maxFrictionAccel then return Vector3.zero end
	return aT - aT.Unit * maxFrictionAccel
end

return PartConstants
