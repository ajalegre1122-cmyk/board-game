--[[
	UpdateAttachment Mixin  -  per-frame update for Attachment particles, split from Update.luau
	for the 500-line cap. Composes in the visual parent's space (LinkCF.attachmentParentFrame).
	Hot-path zero-allocation contract: no CFrame/Vector3/table creation in step loops.
]]

local GraphMod = require(script.Parent.Graph)
local Constants = require(script.Parent.PartConstants)
local EventsCollision = require(script.Parent.EventsCollision)
local LinkCF = require(script.Parent.LinkCF)
local UpdateCommon = require(script.Parent.UpdateCommon)
local DirectionVectors = Constants.DirectionVectors
local _posOffsetFrameDelta = UpdateCommon._posOffsetFrameDelta
local _composeLocalDelta = UpdateCommon._composeLocalDelta

return function(Particle)

-- Attachment update: parent-local motion. No Size graph (Attachments drive child instances).
function Particle:UpdateAttachment(pData, dt, currentTime)
	-- Signed-reverse Timescale: see UpdatePart. SetTimescale override wins for its window.
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
	local atForwardEnd = newEff >= lifeTime
	local atBackwardEnd = newEff <= 0
	local elapsedTime = newEff
	local i = elapsedTime / lifeTime
	if not pData.VisualPart or not pData.VisualPart.Parent then return true end
	if pData.TotalKeyFrames <= 0 then return true end
	local graphFinished = real_i >= 1
	if pData._collisionStopped then return graphFinished and (atForwardEnd or atBackwardEnd) end

	-- Nested-Model scale (see UpdatePart): motionFactor scales the spatial delta, rotFactor
	-- scales RotSpeed via rotDamp, sizeFactor scales Size. 1 when not nested.
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
		local spinRate = pData._spinRate
		if spinRate and (spinRate.X ~= 0 or spinRate.Y ~= 0 or spinRate.Z ~= 0) then
			pData._spinAccumX = (pData._spinAccumX or 0) + spinRate.X * frameDT
			pData._spinAccumY = (pData._spinAccumY or 0) + spinRate.Y * frameDT
			pData._spinAccumZ = (pData._spinAccumZ or 0) + spinRate.Z * frameDT
		end
		local speedMult = pData.SpeedMultiplier or 1

		-- actualParent-local link CFrame; identity when no link.
		local parentCF_now, useVOS = LinkCF.attachmentParentFrame(pData)

		if pData.InvertMotion then
			pData.CurrentStep = targetStep
			local reverseStep = pData.TotalKeyFrames - targetStep
			local localCF = pData.SimLocalCFrames[reverseStep] or pData.SimLocalCFrames[0]
			pData.VisualPart.CFrame = parentCF_now * localCF
			pData.LocalCF = localCF
			pData._localWorldCF = localCF

		-- POSITION: Forward, FULL iteration (VelocityVectored)
		elseif pData.NeedsFullIteration then
			local hasDrag = pData.HasDrag
			local hasAccel = pData.HasAccel
			local accelVel = pData._accelVel or Vector3.zero
			local sx = pData._spinAccumX or 0
			local sy = pData._spinAccumY or 0
			local sz = pData._spinAccumZ or 0
			local rotOrder = pData.RotOrder or "Global"
			for step = prevStep + stepDir, targetStep, stepDir do
				local si = step / pData.TotalKeyFrames
				local elapsedSec = si * pData.LifeTime

				local speed = pData._speedOverride or ((pData._staticSpeed or GraphMod.QueryPointsWithTime(si, pData.Graphs.Speed, pData.Seeds.Speed)) * speedMult)
				local draggedSpeed = hasDrag and (speed * math.exp(-pData.Drag * elapsedSec)) or speed

				local displacement
				if hasAccel then
					local effA = Constants.applyContactAccel(pData.Acceleration, pData, perStepDT)
					accelVel = accelVel + effA * perStepDT
					displacement = (pData.BaseDirection * draggedSpeed + accelVel) * perStepDT
				else
					displacement = pData.BaseDirection * (draggedSpeed * perStepDT)
				end

				-- PosOffset per-step delta. _composeLocalDelta VOS's only the world velocity into
				-- link-local; a Local-mode offset is already link-local and added as-is.
				local posDelta, posIsLL = _posOffsetFrameDelta(pData, si, useVOS)
				local stepDelta = _composeLocalDelta(parentCF_now, useVOS, displacement, posDelta, posIsLL, motionFactor)
				pData.LocalCF = CFrame.new(stepDelta) * pData.LocalCF

				-- Rotation
				local rotDamp = (pData._settleRotDamp or 1) * rotFactor
				local rotSpeedX = (pData._staticRotSpeedX or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedX, pData.Seeds.RotSpeedX)) * rotDamp
				local rotSpeedY = (pData._staticRotSpeedY or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedY, pData.Seeds.RotSpeedY)) * rotDamp
				local rotSpeedZ = (pData._staticRotSpeedZ or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedZ, pData.Seeds.RotSpeedZ)) * rotDamp

				local rotationCFrame
				if pData.RotMode == "Speed" then
					pData.AccRotX = pData.AccRotX + rotSpeedX * perStepDT
					pData.AccRotY = pData.AccRotY + rotSpeedY * perStepDT
					pData.AccRotZ = pData.AccRotZ + rotSpeedZ * perStepDT
					rotationCFrame = Constants.composeRotation(rotOrder, pData.AccRotX + sx, pData.AccRotY + sy, pData.AccRotZ + sz)
				else
					rotationCFrame = Constants.composeRotation(rotOrder, rotSpeedX + sx, rotSpeedY + sy, rotSpeedZ + sz)
				end

				pData.VisualPart.CFrame = parentCF_now * pData.LocalCF * rotationCFrame
				pData._localWorldCF = pData.LocalCF * rotationCFrame

				local rotatedCF = pData.VisualPart.CFrame * pData.SpreadRotation
				local dirInfo = DirectionVectors[pData.EmissionDirection] or DirectionVectors[Enum.NormalId.Top]
				pData.BaseDirection = rotatedCF[dirInfo.vector] * dirInfo.multiplier
			end
			pData._accelVel = accelVel
			pData.CurrentStep = targetStep

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
			local posDelta, posIsLL = _posOffsetFrameDelta(pData, targetStep / pData.TotalKeyFrames, useVOS)
			local stepDelta = _composeLocalDelta(parentCF_now, useVOS, totalDisplacement, posDelta, posIsLL, motionFactor)
			pData.LocalCF = CFrame.new(stepDelta) * pData.LocalCF
			local sx = pData._spinAccumX or 0
			local sy = pData._spinAccumY or 0
			local sz = pData._spinAccumZ or 0
			local rotationCFrame = Constants.composeRotation(pData.RotOrder or "Global", pData.AccRotX + sx, pData.AccRotY + sy, pData.AccRotZ + sz)

			pData.VisualPart.CFrame = parentCF_now * pData.LocalCF * rotationCFrame
			pData._localWorldCF = pData.LocalCF * rotationCFrame
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
			local posDelta, posIsLL = _posOffsetFrameDelta(pData, targetStep / pData.TotalKeyFrames, useVOS)
			local stepDelta = _composeLocalDelta(parentCF_now, useVOS, totalDisplacement, posDelta, posIsLL, motionFactor)
			pData.LocalCF = CFrame.new(stepDelta) * pData.LocalCF

			local steppedI = targetStep / pData.TotalKeyFrames
			local rotDamp = (pData._settleRotDamp or 1) * rotFactor
			local rotX = (pData._staticRotSpeedX or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.RotSpeedX, pData.Seeds.RotSpeedX)) * rotDamp + (pData._spinAccumX or 0)
			local rotY = (pData._staticRotSpeedY or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.RotSpeedY, pData.Seeds.RotSpeedY)) * rotDamp + (pData._spinAccumY or 0)
			local rotZ = (pData._staticRotSpeedZ or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.RotSpeedZ, pData.Seeds.RotSpeedZ)) * rotDamp + (pData._spinAccumZ or 0)
			local rotationCFrame = Constants.composeRotation(pData.RotOrder or "Global", rotX, rotY, rotZ)

			pData.VisualPart.CFrame = parentCF_now * pData.LocalCF * rotationCFrame
			pData._localWorldCF = pData.LocalCF * rotationCFrame
			pData.CurrentStep = targetStep
		end
	end

	return isDying
end

end
