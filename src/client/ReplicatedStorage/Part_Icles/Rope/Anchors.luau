--[[
	Rope/Anchors  -  live anchor resolution + pinning for the verlet chain.

	Start anchor: parent-clone link (nested emit) → source item → frozen last
	pose. End anchor (PinMode BothEnds): the Target ObjectValue's instance;
	Target destroyed mid-life degrades to StartOnly with a velocity kill so the
	freed end swings from its current pose instead of snapping.

	repin runs before EVERY substep (moving source/Target drags the rope  -  the
	core feature). A start-anchor jump > TELEPORT_DIST in one repin rigid-
	translates the whole chain (no cross-map whip).
]]

local Constants = require(script.Parent.Parent.PartConstants)
local VerletSim = require(script.Parent.VerletSim)

local TELEPORT_DIST = 50

local Anchors = {}

-- Spawn offset in the chosen frame: Local = base rotation × spawn RotXYZ
-- (rings/fans rotate the offset), Global = world axes.
local function applySpawnOff(pData, cf)
	local off = pData._spawnOff
	if not off or off.Magnitude == 0 then return cf end
	if pData._spawnOffMode == "Global" then
		return cf + off
	end
	local rot = pData._spawnRot
	if rot then
		return cf + (cf.Rotation * rot):VectorToWorldSpace(off)
	end
	return cf * CFrame.new(off)
end

-- Current start-anchor CFrame: override → live link → source → frozen last,
-- then the rolled spawn offset when SpawnTarget is Start. _lastStartCF caches
-- the PRE-offset base so per-cycle offset re-rolls apply against the live pose.
function Anchors.resolveStart(pData)
	local cf
	if pData._startCFOverride then
		cf = pData._startCFOverride
	else
		local link = pData._parentLink
		if link and link.Parent then
			cf = Constants.resolveLinkCFrame(link)
		else
			local src = pData._sourceItem
			cf = (src and src.Parent) and src.CFrame or (pData._lastStartCF or CFrame.new())
		end
		pData._lastStartCF = cf
	end
	if pData._spawnTarget ~= "End" then
		cf = applySpawnOff(pData, cf)
	end
	return cf
end

-- Current end-anchor position, or nil when unpinned. Launch mode pins to the
-- ballistic point (UpdateRope's closed-form _launchPos, clamped at full rope
-- extension) and never degrades. Destroyed Target flips the rope to StartOnly
-- permanently (velocity killed once at the flip).
function Anchors.resolveEnd(pData)
	if not pData._pinEnd then return nil end
	if pData._pinMode == "Launch" then
		return pData._launchPos or pData._launchOrigin
	end
	local target = pData._target
	if target and target.Parent then
		local cf = Constants.resolveLinkCFrame(target)
		if pData._spawnTarget == "End" then
			cf = applySpawnOff(pData, cf)
		end
		pData._lastEndPos = cf.Position
		return cf.Position
	end
	pData._pinEnd = false
	local rig = pData._rig
	VerletSim.calm(rig.posBuf, rig.prevPosBuf, pData._segCount)
	return nil
end

-- Pin anchor points into the buffers; teleport-guard on the start anchor.
-- The MotionTarget anchor gets _anchorOffWorld added (whips drive the START;
-- End with StartOnly is a no-op — nothing is pinned to offset).
function Anchors.repin(pData)
	local rig = pData._rig
	local pos = rig.posBuf
	local prev = rig.prevPosBuf
	local n = pData._segCount
	local off = pData._anchorOffWorld

	-- Release death mode: no pins at all — the whole rope falls free.
	if pData._pinStart ~= false then
		local startPos = Anchors.resolveStart(pData).Position
		if off and pData._motionTarget == "Start" then
			startPos = startPos + off
		end
		local jump = startPos - pos[1]
		if jump.Magnitude > TELEPORT_DIST then
			VerletSim.translate(pos, prev, n, jump)
		end
		pos[1] = startPos
		prev[1] = startPos
	end

	local endPos = Anchors.resolveEnd(pData)
	if endPos then
		if off and pData._motionTarget == "End" then
			endPos = endPos + off
		end
		pos[n + 1] = endPos
		prev[n + 1] = endPos
	end
end

-- Seed the initial pose: straight line start→end with a slack belly, a
-- straight hang for StartOnly, or a compressed coil along the launch direction
-- (unfolds cleanly as the end flies; stacking every point at one spot would
-- make relaxation explode in random directions). prev := pos = spawn calm.
function Anchors.seedPose(pData)
	local rig = pData._rig
	local pos = rig.posBuf
	local n = pData._segCount
	local startPos = Anchors.resolveStart(pData).Position

	-- GrowIn: seed as a compressed coil at the start — the animated rest length
	-- pays the rope out over the grow window.
	if (pData._growIn or 0) > 0 and pData._pinMode ~= "Launch" then
		local dir = pData._motionDir or Vector3.new(0, -1, 0)
		local spacing = pData._restLen * 0.02
		for i = 1, n + 1 do
			pos[i] = startPos + dir * (spacing * (i - 1))
		end
		VerletSim.calm(pos, rig.prevPosBuf, n)
		return
	end

	if pData._pinMode == "Launch" then
		local dir = pData._launchVel
		dir = (dir and dir.Magnitude > 1e-4) and dir.Unit or Vector3.yAxis
		local spacing = pData._restLen * 0.05
		for i = 1, n + 1 do
			pos[i] = startPos + dir * (spacing * (i - 1))
		end
		VerletSim.calm(pos, rig.prevPosBuf, n)
		return
	end

	local endPos = Anchors.resolveEnd(pData)

	if endPos then
		local chord = endPos - startPos
		-- Belly depth from the length surplus over the straight chord.
		local surplus = math.max(pData._restLen * n - chord.Magnitude, 0)
		for i = 1, n + 1 do
			local t = (i - 1) / n
			pos[i] = startPos + chord * t - Vector3.new(0, surplus * 0.5 * 4 * t * (1 - t), 0)
		end
	else
		-- StartOnly: seed EXTENDED along EmissionDirection ± SpreadAngle — the
		-- rope bursts out along it, then gravity settles it (whip spawn).
		local dir = pData._motionDir or Vector3.new(0, -1, 0)
		for i = 1, n + 1 do
			pos[i] = startPos + dir * (pData._restLen * (i - 1))
		end
	end
	VerletSim.calm(pos, rig.prevPosBuf, n)
end

return Anchors
