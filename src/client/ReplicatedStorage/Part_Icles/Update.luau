--[[
	Update Mixin  -  per-frame update for Part / Beam (Attachment lives in UpdateAttachment.luau).
	Returns true when Lifetime expires (swap-and-pop or animate-loop reset).
	Hot-path zero-allocation contract: no CFrame/Vector3/table creation in step loops.
]]

local GraphMod = require(script.Parent.Graph)
local DecalLayersMod = require(script.Parent.DecalLayers)
local Constants = require(script.Parent.PartConstants)
local LinkCF = require(script.Parent.LinkCF)
local UpdateCommon = require(script.Parent.UpdateCommon)
local EventsCollision = require(script.Parent.EventsCollision)
local Turbulence = require(script.Parent.Turbulence)
local DirectionVectors = Constants.DirectionVectors
local _posOffsetFrameDelta = UpdateCommon._posOffsetFrameDelta
local _composeLocalDelta = UpdateCommon._composeLocalDelta

-- World position for target-accel; nil for destroyed / no-Position types.
-- Bone before BasePart (Bone IS-A BasePart but .Position is bind pose, not live).
local function getTargetPosition(target)
	if not target or not target.Parent then return nil end
	if target:IsA("Bone") then return target.TransformedWorldCFrame.Position end
	if target:IsA("BasePart") then return target.Position end
	if target:IsA("Attachment") then return target.WorldPosition end
	if target:IsA("Camera") then return target.CFrame.Position end
	if target:IsA("Model") then local ok, cf = pcall(target.GetPivot, target); if ok and cf then return cf.Position end end
	return nil
end

return function(Particle)

-- Part update: position (4 branches), rotation, size, color/transparency, flipbook.
-- Branches: Inverted reads precomputed CFrames; VelocityVectored needs full per-step iteration;
-- fast paths skip ahead with no accel/drag.
function Particle:UpdatePart(pData, dt, currentTime)
	-- Signed-reverse Timescale: ts sampled at real_i (not effective i) so it progresses
	-- monotonically through keypoints regardless of effective-time direction. ts(0)<0 →
	-- particle starts at end of life and rewinds; ts(0)>=0 → starts forward.
	-- SetTimescale override (Lifecycle.luau) wins over the graph for its window.
	local real_i = math.min(math.max((currentTime - pData.StartTime) / pData.LifeTime, 0), 1)
	local ts
	if pData._tsOverride ~= nil and currentTime < (pData._tsOverrideUntil or 0) then
		ts = pData._tsOverride
	else
		ts = pData.Graphs.Timescale and GraphMod.QueryPointsWithTime(real_i, pData.Graphs.Timescale, pData.Seeds.Timescale) or 1
	end
	dt = dt * ts
	local lifeTime = pData.LifeTime
	local priorEff = pData._effectiveElapsed or 0
	local newEff = priorEff + (pData._timeFrozen and 0 or dt)
	if dt < 0 and pData._hitHistory and #pData._hitHistory > 0 then
		EventsCollision.restoreHitsOnReverse(pData, priorEff, newEff)
	end
	if newEff < 0 then newEff = 0 end
	if newEff > lifeTime then newEff = lifeTime end
	pData._effectiveElapsed = newEff
	-- After-clamp dt: boundary frames see partial step instead of overshooting.
	dt = newEff - priorEff
	pData._lastEffectiveDt = dt
	-- Particle dies when effective sits at a boundary AND the graph has finished playing.
	local atForwardEnd = newEff >= lifeTime
	local atBackwardEnd = newEff <= 0
	local elapsedTime = newEff
	local i = elapsedTime / lifeTime

	if not pData.VisualPart or not pData.VisualPart.Parent then return true end
	if pData.TotalKeyFrames <= 0 then return true end
	local graphFinished = real_i >= 1
	-- OnHit Collision=Stop (or auto-settle freeze): skip motion/step work, age normally.
	if pData._collisionStopped then return graphFinished and (atForwardEnd or atBackwardEnd) end

	-- Nested-Model scale: fold the parent Model's current scale into nested-particle motion.
	-- motionFactor scales the spatial delta (Speed/Accel/PosOffset) when ScaleMotion; rotFactor
	-- scales RotSpeed (via rotDamp) when ScaleRotation; sizeFactor scales Size. 1 when not nested.
	local sizeFactor, motionFactor, rotFactor = 1, 1, 1
	if pData.ParentScale then
		sizeFactor = Constants.getParentScaleFactor(pData.ParentScale, currentTime, GraphMod)
		motionFactor = Constants.getParentScaleFactor(pData.ParentScale, currentTime, GraphMod, "motion")
		rotFactor = Constants.getParentScaleFactor(pData.ParentScale, currentTime, GraphMod, "rotation")
	end
	local isDying = graphFinished and (atForwardEnd or atBackwardEnd)
	i = math.min(math.max(i, 0), 1)

	pData.AccumulatedDT += dt
	local targetStep = math.floor(i * pData.TotalKeyFrames)

	if targetStep ~= pData.CurrentStep then
		local prevStep = pData.CurrentStep
		local stepDir = (targetStep > prevStep) and 1 or -1
		local stepsToProcess = math.abs(targetStep - prevStep)
		local perStepDT = pData.AccumulatedDT / stepsToProcess
		local frameDT = pData.AccumulatedDT
		pData.AccumulatedDT = 0

		-- Collision spin (deg/sec) into _spinAccum (degrees); composes with both rotation modes.
		local spinRate = pData._spinRate
		if spinRate and (spinRate.X ~= 0 or spinRate.Y ~= 0 or spinRate.Z ~= 0) then
			pData._spinAccumX = (pData._spinAccumX or 0) + spinRate.X * frameDT
			pData._spinAccumY = (pData._spinAccumY or 0) + spinRate.Y * frameDT
			pData._spinAccumZ = (pData._spinAccumZ or 0) + spinRate.Z * frameDT
		end
		local speedMult = pData.SpeedMultiplier or 1

		-- POSITION: Inverted
		if pData.InvertMotion then
			pData.CurrentStep = targetStep
			local reverseStep = pData.TotalKeyFrames - targetStep
			local localCF = pData.SimLocalCFrames[reverseStep] or pData.SimLocalCFrames[0]
			local parentCF_now = LinkCF.parentFrame(pData)
			pData.VisualPart.CFrame = parentCF_now * localCF
			pData._localWorldCF = localCF
			pData.CurrentPosition = pData.VisualPart.Position

		-- POSITION: Forward, FULL iteration (VelocityVectored)
		elseif pData.NeedsFullIteration then
			-- parentCF_now / dirInfo hoisted outside the loop; final CFrame written once at batch end.
			local hasDrag = pData.HasDrag
			local hasAccel = pData.HasAccel
			local parentCF_now, useVOS = LinkCF.parentFrame(pData)
			local dirInfo = DirectionVectors[pData.EmissionDirection] or DirectionVectors[Enum.NormalId.Top]
			local localCF = pData.LocalCF
			local accRotX, accRotY, accRotZ = pData.AccRotX, pData.AccRotY, pData.AccRotZ
			local baseDir = pData.BaseDirection
			local accelVel = pData._accelVel or Vector3.zero
			local targetVel = pData.TargetVel
			-- Seed simPos from live VisualPart.Position (overlays moved CFrame since CurrentPosition write).
			local simPos = pData.VisualPart.Position
			local rotMode = pData.RotMode
			local rotOrder = pData.RotOrder or "Global"
			local lastWorldCF, lastLocalWorldCF
			for step = prevStep + stepDir, targetStep, stepDir do
				local si = step / pData.TotalKeyFrames
				local elapsedSec = si * pData.LifeTime

				local speed = pData._speedOverride or ((pData._staticSpeed or GraphMod.QueryPointsWithTime(si, pData.Graphs.Speed, pData.Seeds.Speed)) * speedMult)
				local draggedSpeed = hasDrag and (speed * math.exp(-pData.Drag * elapsedSec)) or speed

				local displacement
				if hasAccel then
					local effA = Constants.applyContactAccel(pData.Acceleration, pData, perStepDT)
					accelVel = accelVel + effA * perStepDT
					displacement = (baseDir * draggedSpeed + accelVel) * perStepDT
				else
					displacement = baseDir * (draggedSpeed * perStepDT)
				end

				-- Target accel: Euler integration; reads simPos for mid-substep tracking.
				if pData.HasTargetAccel then
					local tPos = getTargetPosition(pData.AccelTarget)
					if tPos then
						local toTarget = tPos - simPos
						local dist = toTarget.Magnitude
						if dist > 1e-4 then
							local mag = pData._staticAccelStrength or GraphMod.QueryPointsWithTime(si, pData.Graphs.AccelStrength, pData.Seeds.AccelStrength)
							if mag and mag ~= 0 then
								targetVel = targetVel + toTarget * (mag * perStepDT / dist)
								displacement = displacement + targetVel * perStepDT
							end
						end
					end
				end

				-- PosOffset per-step delta. Telescoping sums integrate to the absolute-offset
				-- change. _composeLocalDelta VOS's only the velocity; a Local-mode offset is
				-- already link-local and added as-is (else a spinning Weld precesses it).
				local posDelta, posIsLL = _posOffsetFrameDelta(pData, si, useVOS)
				local parentLocalDelta = _composeLocalDelta(parentCF_now, useVOS, displacement, posDelta, posIsLL, motionFactor)
				localCF = CFrame.new(parentLocalDelta) * localCF

				local rotDamp = (pData._settleRotDamp or 1) * rotFactor
				local rotSpeedX = (pData._staticRotSpeedX or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedX, pData.Seeds.RotSpeedX)) * rotDamp
				local rotSpeedY = (pData._staticRotSpeedY or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedY, pData.Seeds.RotSpeedY)) * rotDamp
				local rotSpeedZ = (pData._staticRotSpeedZ or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedZ, pData.Seeds.RotSpeedZ)) * rotDamp

				local rotationCFrame
				local sx = pData._spinAccumX or 0
				local sy = pData._spinAccumY or 0
				local sz = pData._spinAccumZ or 0
				if rotMode == "Speed" then
					accRotX = accRotX + rotSpeedX * perStepDT
					accRotY = accRotY + rotSpeedY * perStepDT
					accRotZ = accRotZ + rotSpeedZ * perStepDT
					rotationCFrame = Constants.composeRotation(rotOrder, accRotX + sx, accRotY + sy, accRotZ + sz)
				else
					rotationCFrame = Constants.composeRotation(rotOrder, rotSpeedX + sx, rotSpeedY + sy, rotSpeedZ + sz)
				end

				lastWorldCF = (parentCF_now * localCF) * rotationCFrame
				lastLocalWorldCF = localCF * rotationCFrame
				simPos = lastWorldCF.Position

				local rotatedCF = lastWorldCF * pData.SpreadRotation
				baseDir = rotatedCF[dirInfo.vector] * dirInfo.multiplier
			end
			pData.LocalCF = localCF
			pData.AccRotX, pData.AccRotY, pData.AccRotZ = accRotX, accRotY, accRotZ
			pData.BaseDirection = baseDir
			pData._accelVel = accelVel
			pData.TargetVel = targetVel
			pData.CurrentPosition = simPos
			pData.CurrentStep = targetStep
			if lastWorldCF then
				pData.VisualPart.CFrame = lastWorldCF
				pData._localWorldCF = lastLocalWorldCF
			end

		-- POSITION: Forward, SPEED ROTATION
		elseif pData.NeedsRotAccum then
			local hasDrag = pData.HasDrag
			local hasAccel = pData.HasAccel
			local totalScalarDisp = 0
			local totalAccelDisp = Vector3.zero
			local accelVel = pData._accelVel or Vector3.zero

			for step = prevStep + stepDir, targetStep, stepDir do
				local si = step / pData.TotalKeyFrames
				local elapsedSec = si * pData.LifeTime
				local speed = pData._speedOverride or ((pData._staticSpeed or GraphMod.QueryPointsWithTime(si, pData.Graphs.Speed, pData.Seeds.Speed)) * speedMult)
				if hasDrag then speed = speed * math.exp(-pData.Drag * elapsedSec) end
				totalScalarDisp = totalScalarDisp + speed * perStepDT
				if hasAccel then
					local effA = Constants.applyContactAccel(pData.Acceleration, pData, perStepDT)
					accelVel = accelVel + effA * perStepDT
					totalAccelDisp = totalAccelDisp + accelVel * perStepDT
				end

				local rotDamp = (pData._settleRotDamp or 1) * rotFactor
				local rotSpeedX = (pData._staticRotSpeedX or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedX, pData.Seeds.RotSpeedX)) * rotDamp
				local rotSpeedY = (pData._staticRotSpeedY or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedY, pData.Seeds.RotSpeedY)) * rotDamp
				local rotSpeedZ = (pData._staticRotSpeedZ or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedZ, pData.Seeds.RotSpeedZ)) * rotDamp
				pData.AccRotX = pData.AccRotX + rotSpeedX * perStepDT
				pData.AccRotY = pData.AccRotY + rotSpeedY * perStepDT
				pData.AccRotZ = pData.AccRotZ + rotSpeedZ * perStepDT
			end
			pData._accelVel = accelVel

			local totalDisplacement = pData.BaseDirection * totalScalarDisp + totalAccelDisp

			-- Target accel: frame-granularity (mid-frame si).
			if pData.HasTargetAccel then
				local tPos = getTargetPosition(pData.AccelTarget)
				if tPos then
					local toTarget = tPos - pData.VisualPart.Position
					local dist = toTarget.Magnitude
					if dist > 1e-4 then
						local frameDT2 = perStepDT * (targetStep - prevStep)
						local midSI = ((prevStep + 1 + targetStep) * 0.5) / pData.TotalKeyFrames
						local mag = pData._staticAccelStrength or GraphMod.QueryPointsWithTime(midSI, pData.Graphs.AccelStrength, pData.Seeds.AccelStrength)
						if mag and mag ~= 0 then
							pData.TargetVel = pData.TargetVel + toTarget * (mag * frameDT2 / dist)
							totalDisplacement = totalDisplacement + pData.TargetVel * frameDT2
						end
					end
				end
			end

			-- PosOffsetX/Y/Z over-life position graphs. _composeLocalDelta VOS's only the
			-- world velocity; a Local-mode offset is already link-local and added as-is so a
			-- spinning Weld lets the radius shrink instead of precessing the offset.
			local parentCF_now, useVOS = LinkCF.parentFrame(pData)
			local posDelta, posIsLL = _posOffsetFrameDelta(pData, targetStep / pData.TotalKeyFrames, useVOS)
			local parentLocalDelta = _composeLocalDelta(parentCF_now, useVOS, totalDisplacement, posDelta, posIsLL, motionFactor)
			pData.LocalCF = CFrame.new(parentLocalDelta) * pData.LocalCF
			local sx = pData._spinAccumX or 0
			local sy = pData._spinAccumY or 0
			local sz = pData._spinAccumZ or 0
			local rotationCFrame = Constants.composeRotation(pData.RotOrder or "Global", pData.AccRotX + sx, pData.AccRotY + sy, pData.AccRotZ + sz)

			pData.VisualPart.CFrame = (parentCF_now * pData.LocalCF) * rotationCFrame
			pData._localWorldCF = pData.LocalCF * rotationCFrame
			pData.CurrentPosition = pData.VisualPart.Position
			pData.CurrentStep = targetStep

		-- POSITION: Forward, FAST
		else
			local hasDrag = pData.HasDrag
			local hasAccel = pData.HasAccel
			local totalScalarDisp = 0
			local totalAccelDisp = Vector3.zero
			local accelVel = pData._accelVel or Vector3.zero

			-- Drag-free closed form: speed integral + (accelVel*Δt + 0.5*accel*Δt²).
			if not hasDrag then
				local invTKF = 1 / pData.TotalKeyFrames
				local prevT = prevStep * invTKF
				local targetT = targetStep * invTKF
				local override = pData._speedOverride
				if override then
					totalScalarDisp = override * (targetT - prevT) * pData.LifeTime
				elseif pData._staticSpeed then
					-- Constant Speed integrates to value × duration.
					totalScalarDisp = pData._staticSpeed * speedMult * (targetT - prevT) * pData.LifeTime
				else
					totalScalarDisp = pData.LifeTime * speedMult * (GraphMod.IntegrateUpTo(targetT, pData.Graphs.Speed, pData.Seeds.Speed) - GraphMod.IntegrateUpTo(prevT, pData.Graphs.Speed, pData.Seeds.Speed))
				end
				if hasAccel then
					local deltaSec = (targetT - prevT) * pData.LifeTime
					local effA = Constants.applyContactAccel(pData.Acceleration, pData, deltaSec)
					totalAccelDisp = accelVel * deltaSec + effA * (deltaSec * deltaSec * 0.5)
					accelVel = accelVel + effA * deltaSec
				end
			else
				-- Drag fallback: per-step loop.
				for step = prevStep + stepDir, targetStep, stepDir do
					local si = step / pData.TotalKeyFrames
					local elapsedSec = si * pData.LifeTime
					local speed = pData._speedOverride or ((pData._staticSpeed or GraphMod.QueryPointsWithTime(si, pData.Graphs.Speed, pData.Seeds.Speed)) * speedMult)
					speed = speed * math.exp(-pData.Drag * elapsedSec)
					totalScalarDisp = totalScalarDisp + speed * perStepDT
					if hasAccel then
						local effA = Constants.applyContactAccel(pData.Acceleration, pData, perStepDT)
						accelVel = accelVel + effA * perStepDT
						totalAccelDisp = totalAccelDisp + accelVel * perStepDT
					end
				end
			end
			pData._accelVel = accelVel

			local totalDisplacement = pData.BaseDirection * totalScalarDisp + totalAccelDisp

			-- Target accel: frame-granularity sample.
			if pData.HasTargetAccel then
				local tPos = getTargetPosition(pData.AccelTarget)
				if tPos then
					local toTarget = tPos - pData.VisualPart.Position
					local dist = toTarget.Magnitude
					if dist > 1e-4 then
						local frameDT = perStepDT * (targetStep - prevStep)
						local midSI = ((prevStep + 1 + targetStep) * 0.5) / pData.TotalKeyFrames
						local mag = pData._staticAccelStrength or GraphMod.QueryPointsWithTime(midSI, pData.Graphs.AccelStrength, pData.Seeds.AccelStrength)
						if mag and mag ~= 0 then
							pData.TargetVel = pData.TargetVel + toTarget * (mag * frameDT / dist)
							totalDisplacement = totalDisplacement + pData.TargetVel * frameDT
						end
					end
				end
			end

			-- PosOffset over-life graphs. _composeLocalDelta VOS's only the velocity; a Local-mode
			-- offset is link-local and added as-is (no precession on a spinning Weld).
			local parentCF_now, useVOS = LinkCF.parentFrame(pData)
			local posDelta, posIsLL = _posOffsetFrameDelta(pData, targetStep / pData.TotalKeyFrames, useVOS)
			local parentLocalDelta = _composeLocalDelta(parentCF_now, useVOS, totalDisplacement, posDelta, posIsLL, motionFactor)
			pData.LocalCF = CFrame.new(parentLocalDelta) * pData.LocalCF

			local steppedI = targetStep / pData.TotalKeyFrames
			local rotDamp = (pData._settleRotDamp or 1) * rotFactor
			local rotX = (pData._staticRotSpeedX or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.RotSpeedX, pData.Seeds.RotSpeedX)) * rotDamp + (pData._spinAccumX or 0)
			local rotY = (pData._staticRotSpeedY or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.RotSpeedY, pData.Seeds.RotSpeedY)) * rotDamp + (pData._spinAccumY or 0)
			local rotZ = (pData._staticRotSpeedZ or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.RotSpeedZ, pData.Seeds.RotSpeedZ)) * rotDamp + (pData._spinAccumZ or 0)
			local rotationCFrame = Constants.composeRotation(pData.RotOrder or "Global", rotX, rotY, rotZ)

			pData.VisualPart.CFrame = (parentCF_now * pData.LocalCF) * rotationCFrame
			pData._localWorldCF = pData.LocalCF * rotationCFrame
			pData.CurrentPosition = pData.VisualPart.Position
			pData.CurrentStep = targetStep
		end

		-- SIZE  -  gated by pData.SkipSize (set via payload.SetSkipSize).
		local steppedI = targetStep / pData.TotalKeyFrames
		if not pData.SkipSize then
			local sizex = pData._staticSizeX or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.SizeX, pData.Seeds.SizeX)
			local sizey = pData._staticSizeY or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.SizeY, pData.Seeds.SizeY)
			local sizez = pData._staticSizeZ or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.SizeZ, pData.Seeds.SizeZ)

			-- Nested-Model scale on Size (always-on; independent of ScaleMotion). sizeFactor
			-- hoisted once at function top via Constants.getParentScaleFactor.
			if sizeFactor ~= 1 then
				sizex = sizex * sizeFactor
				sizey = sizey * sizeFactor
				sizez = sizez * sizeFactor
			end

			if pData.SpecialMesh then
				pData.SpecialMesh.Scale = Vector3.new(sizex, sizey, sizez)
			else
				pData.VisualPart.Size = Vector3.new(sizex, sizey, sizez)
			end
		end

		-- VISUAL
		local transparency = pData._staticTransparency or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.Transparency, pData.Seeds.Transparency)

		if pData.SurfaceAppearance then
			-- Color graph tints SA.Color raw; Brightness graph drives SA.EmissiveTint only.
			-- EmissiveTint write pcall-guarded for older Studio builds without the property.
			local brightness = pData._staticBrightness or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.Brightness, pData.Seeds.Brightness)
			local color = GraphMod.QueryColorPointWithTime(steppedI, pData.Graphs.Color)
			if not pData.SkipTransparency then pData.VisualPart.Transparency = transparency end
			if not pData.SkipColor then
				pData.VisualPart.Color = Color3.fromRGB(color.R * 255, color.G * 255, color.B * 255)
				pData.SurfaceAppearance.Color = Color3.fromRGB(color.R * 255, color.G * 255, color.B * 255)
				pcall(function() pData.SurfaceAppearance.EmissiveTint = Color3.new(color.R * brightness, color.G * brightness, color.B * brightness) end)
			end
		elseif pData.HasDecal and not pData.DecalLayersMode then
			local brightness = pData._staticBrightness or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.Brightness, pData.Seeds.Brightness)
			local color = GraphMod.QueryColorPointWithTime(steppedI, pData.Graphs.Color)
			if not pData.SkipTransparency then pData.Decal.Transparency = transparency end
			if not pData.SkipColor then pData.Decal.Color3 = Color3.fromRGB(color.R * 255 * brightness, color.G * 255 * brightness, color.B * 255 * brightness) end
		else
			-- Mesh: Brightness scales the mesh colour in decal-layers mode; legacy plain meshes ignore it.
			local color = GraphMod.QueryColorPointWithTime(steppedI, pData.Graphs.Color)
			local brightness = 1
			if pData.DecalLayersMode then
				brightness = pData._staticBrightness or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.Brightness, pData.Seeds.Brightness)
			end
			if not pData.SkipTransparency then pData.VisualPart.Transparency = transparency end
			if not pData.SkipColor then pData.VisualPart.Color = Color3.fromRGB(color.R * 255 * brightness, color.G * 255 * brightness, color.B * 255 * brightness) end
			if pData.Layers then DecalLayersMod.write(pData, steppedI) end
		end
	end

	return isDying
end

end
