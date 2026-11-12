--[[
	Lightning/Endpoints  -  spawn-shape sampling + live endpoint resolution.
	Split from Lightning/init (500-line cap). Pure pData readers/writers; no
	engine or pool knowledge.
	Origin, in order: an event's origin override, the emitted parent clone of a nested bolt
	(_parentLink), the authored Link by LinkMode (_userLink, through LinkCF.originFrame), the
	source part itself.
]]

local Constants = require(script.Parent.Parent.PartConstants)
local LinkCF = require(script.Parent.Parent.LinkCF)

local Endpoints = {}

-- Resolve a DisplacementMode-framed vector into world space at the current origin.
-- Local = per-bolt rotated frame (origin × RotXYZ); RigidLocal = origin frame only.
local function resolveDispFrame(pData, startCF, vec)
	local mode = pData._dispMode
	if mode == "Local" then
		local frame = pData._originRot and (startCF.Rotation * pData._originRot) or startCF
		return frame:VectorToWorldSpace(vec)
	elseif mode == "RigidLocal" then
		return startCF.Rotation:VectorToWorldSpace(vec)
	end
	return vec
end

-- Sample the spawn Shape once per bolt: local-frame offset (start scatter) and, in
-- Directional mode, the outward normal as the bolt direction (ShapeInOut applied).
-- Stored shape-local; resolveEndpoints re-applies against the LIVE frame each roll.
function Endpoints.sampleShape(pData, data, item)
	pData._shapeLocalOffset = nil
	pData._shapeDirLocal = nil
	pData._shapeUsesPart = nil
	if not data.UseShape then return end
	local shapeFunc = Constants.shapeFunctions[data.Shape]
	local shapePart = data.ShapePart
	local shapeSrc = (shapePart and shapePart:IsA("BasePart")) and shapePart
		or (item and item:IsA("BasePart") and item or nil)
	if not shapeFunc or not shapeSrc then return end
	local offset, _, outwardDir = shapeFunc(shapeSrc, { ShapePartial = data.ShapePartial or 0 })
	pData._shapeLocalOffset = offset
	pData._shapeUsesPart = shapeSrc ~= item and shapeSrc or nil
	-- Radial only when explicitly chosen; Emitter mode keeps the authored
	-- Direction ± Spread (shape scatters starts only).
	if data.ShapeDirection == "Radial" and pData._endpointMode == "Directional" and outwardDir then
		local sio = data.ShapeInOut
		if sio == Enum.ParticleEmitterShapeInOut.Inward then
			outwardDir = -outwardDir
		elseif sio == Enum.ParticleEmitterShapeInOut.InAndOut and math.random() < 0.5 then
			outwardDir = -outwardDir
		end
		pData._shapeDirLocal = outwardDir
	end
end

-- Seek (Kutsuna arc-grounding): cast SEEK_RAYS random directions from the
-- current origin, collect surface hits within _seekRadius, keep one at RANDOM
-- (nearest would collapse every bolt onto the same object). SeekBias skews the
-- pick toward closer hits: 0 = uniform, 1 = near-always the nearest. No hit →
-- cache a fallback direction so the bolt arcs into open air at half radius.
-- _seekNewHit flags a fresh acquisition; Lightning/init fires OnHit from it.
local SEEK_RAYS = 8
local function seekScan(pData, startPos)
	local rayFn = pData._seekRayFn
	if not rayFn then return end
	local radius = pData._seekRadius or 30
	local hits = {}
	for _ = 1, SEEK_RAYS do
		local dir = Vector3.new(math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1)
		if dir.Magnitude > 1e-3 then
			local hit = rayFn(startPos, dir.Unit * radius)
			if hit then
				hits[#hits + 1] = { hit = hit, dist = (hit.Position - startPos).Magnitude }
			end
		end
	end
	if #hits > 0 then
		table.sort(hits, function(a, b) return a.dist < b.dist end)
		-- Skewed index: random^(1+bias*8) compresses toward 0 as bias rises,
		-- so the sorted-nearest hits win more often without ever excluding the far ones.
		local bias = pData._seekBias or 0
		local skew = math.random() ^ (1 + bias * 8)
		local hit = hits[math.clamp(math.floor(skew * #hits) + 1, 1, #hits)].hit
		pData._seekHit = { Position = hit.Position, Normal = hit.Normal, Instance = hit.Instance }
		pData._seekNewHit = true
	else
		pData._seekHit = nil
		local dir = Vector3.new(math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1)
		pData._seekFallbackDir = dir.Magnitude > 1e-3 and dir.Unit or Vector3.yAxis
	end
end

-- Advance the glide strike point toward the goal by RetargetSpeed * dt.
-- Returns true when it moved (UpdateLightning re-rolls a frozen-jitter bolt on it).
function Endpoints.glideStep(pData, dt)
	local cur, goal = pData._seekCurrentPos, pData._seekGoalPos
	if (pData._retargetSpeed or 0) <= 0 or not cur or not goal then return false end
	local delta = goal - cur
	local dist = delta.Magnitude
	if dist <= 1e-3 then return false end
	local step = pData._retargetSpeed * dt
	pData._seekCurrentPos = step >= dist and goal or cur + delta * (step / dist)
	return true
end

-- Glide arrival check: OnHit holds until the strike point reaches the goal
-- (the impact lands where the zap lands). Instant mode always counts as arrived.
function Endpoints.glideArrived(pData)
	if (pData._retargetSpeed or 0) <= 0 then return true end
	local cur, goal = pData._seekCurrentPos, pData._seekGoalPos
	if not cur or not goal then return true end
	return (cur - goal).Magnitude <= 1e-2
end

-- Live endpoint resolution, used at emit AND every jitter roll so moving sources /
-- targets / ShapeParts track. Destroyed instances freeze at their last known pose.
-- Returns (startCF for pivot rotation, startPos, endPos).
function Endpoints.resolveEndpoints(pData)
	local startCF
	local link = pData._parentLink
	if pData._startCFOverride then
		startCF = pData._startCFOverride
	elseif link and link.Parent then
		-- Nested emit: origin rides the emitted parent clone (re-resolved every
		-- roll, so a moving parent carries its bolts). resolveLinkCFrame handles
		-- Model/Attachment/Bone clone roots.
		startCF = Constants.resolveLinkCFrame(link)
	else
		local src = pData._sourceItem
		local sourceCF = (src and src.Parent) and src.CFrame or pData._lastStartCF or CFrame.new()
		if pData._userLink then
			startCF = LinkCF.originFrame(pData, pData._userLink, src, sourceCF)
		end
		startCF = startCF or sourceCF
	end
	pData._lastStartCF = startCF

	-- Spawn Shape: apply the per-bolt local offset in the live shape frame.
	local startPos = startCF.Position
	local dirFrame = startCF
	if pData._shapeLocalOffset then
		local sp = pData._shapeUsesPart
		local frame = (sp and sp.Parent and sp.CFrame) or startCF
		startPos = (frame * CFrame.new(pData._shapeLocalOffset)).Position
		dirFrame = frame
	end

	-- Spawn Pos offset (even-distribution aware, rolled per bolt). Rotation applies
	-- FIRST: Local offsets live in the per-bolt rotated frame (origin frame × RotXYZ)
	-- so Rot-even sweeps + Pos offsets compose into rings/spirals, and the whole
	-- pattern rides moving sources/links. PosMode Global = raw world axes.
	local off = pData._originOffset
	if off then
		if pData._originOffsetGlobal then
			startPos = startPos + off
		else
			local frame = pData._originRot and (startCF.Rotation * pData._originRot) or startCF
			startPos = startPos + frame:VectorToWorldSpace(off)
		end
	end

	-- Origin motion: accumulated Speed/Accel drift (world) + PosOffset displacement
	-- graphs + Turbulence wander, the latter two in the DisplacementMode frame.
	-- All maintained by UpdateLightning.
	local motion = pData._motionOffset
	if motion and motion ~= Vector3.zero then
		startPos = startPos + motion
	end
	local disp = pData._dispRaw
	if disp then
		startPos = startPos + resolveDispFrame(pData, startCF, disp)
	end
	local turb = pData._turbRaw
	if turb then
		startPos = startPos + resolveDispFrame(pData, startCF, turb)
	end

	-- Sag droop axis: frame down in the DisplacementMode frame (world down when
	-- Global). Re-resolved every roll so rotating sources carry their arch.
	pData._sagDirWorld = resolveDispFrame(pData, startCF, Vector3.yAxis)

	local endPos
	if pData._endpointMode == "Point" then
		local target = pData._target
		if target and target.Parent then
			endPos = Constants.resolveLinkCFrame(target).Position
		else
			endPos = pData._lastEndPos or startPos
		end
		local dvec = endPos - startPos
		if dvec.Magnitude > 1e-4 then pData._lastDirWorld = dvec.Unit end
	elseif pData._endpointMode == "Seek" then
		-- Scan on first resolve; re-scan every roll when Retarget (the flicker).
		-- An in-flight glide finishes before the next re-scan, so the zap drags
		-- A → B → C instead of wandering between switching goals.
		local glideBusy = not Endpoints.glideArrived(pData)
		if (pData._seekRetarget and not glideBusy) or (not pData._seekHit and not pData._seekFallbackDir) then
			seekScan(pData, startPos)
		end
		local goal
		if pData._seekHit then
			goal = pData._seekHit.Position
		else
			goal = startPos + pData._seekFallbackDir * ((pData._seekRadius or 30) * 0.5)
		end
		-- RetargetSpeed > 0: the strike point GLIDES toward the goal (advanced per
		-- frame by UpdateLightning's glide block — the continuous destructive zap);
		-- 0 = instant snap. First acquisition always snaps so a newborn bolt
		-- appears already struck.
		pData._seekGoalPos = goal
		if (pData._retargetSpeed or 0) <= 0 or not pData._seekCurrentPos then
			pData._seekCurrentPos = goal
		end
		endPos = pData._seekCurrentPos
		local dvec = endPos - startPos
		if dvec.Magnitude > 1e-4 then pData._lastDirWorld = dvec.Unit end
	else
		local dirVec
		if pData._shapeDirLocal then
			dirVec = dirFrame:VectorToWorldSpace(pData._shapeDirLocal)
		elseif pData._dirGlobal then
			dirVec = pData._dirLocalVec
		else
			dirVec = startCF.Rotation:VectorToWorldSpace(pData._dirLocalVec)
		end
		-- Cached for UpdateLightning's Speed-along-direction origin motion.
		pData._lastDirWorld = dirVec
		endPos = startPos + dirVec * pData._length
	end
	pData._lastStartPos = startPos
	pData._lastEndPos = endPos
	return startCF, startPos, endPos
end

return Endpoints
