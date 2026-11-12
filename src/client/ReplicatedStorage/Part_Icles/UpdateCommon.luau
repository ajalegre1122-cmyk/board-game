--[[
	UpdateCommon  -  per-frame displacement helpers shared by the Part and Attachment update mixins
	(Update.luau, UpdateAttachment.luau). UpdateModel keeps its own variant.
]]

local GraphMod = require(script.Parent.Graph)
local Constants = require(script.Parent.PartConstants)
local Turbulence = require(script.Parent.Turbulence)

-- PosOffsetX/Y/Z over-life graph → per-frame delta added to displacement.
-- Difference-based: sample absolute offset at t_norm in the DisplacementMode
-- frame, subtract _prevWorldOff. LocalCF accumulator integrates correctly.
-- Three frames mirror DirMode (Speed direction):
--   Global     = world axes (no rotation applied)
--   Local      = SpawnRotation (post-RotXYZ particle frame; per-particle RotXYZ
--                rotates the path → fans / scatter / convergence patterns)
--   RigidLocal = SpawnEmitterRotation (emitter frame at spawn, pre-RotXYZ;
--                path follows emitter orientation but not particle tumble)
-- Returns (delta, isLinkLocal). isLinkLocal is true when the offset is already in
-- link-local space (Local mode under a useVOS link) and so must NOT be VOS'd again —
-- see _composeLocalDelta. Otherwise the delta is in world/emitter space like before.
local function _posOffsetFrameDelta(pData, steppedI, useVOS)
	if not (pData.HasPosOffsetGraphs or pData.HasTurbulence) then return Vector3.zero, false end
	local delta = Vector3.zero
	if pData.HasPosOffsetGraphs then
		local oX = pData._staticPosOffsetX or (pData.Graphs.PosOffsetX and GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.PosOffsetX, pData.Seeds.PosOffsetX)) or 0
		local oY = pData._staticPosOffsetY or (pData.Graphs.PosOffsetY and GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.PosOffsetY, pData.Seeds.PosOffsetY)) or 0
		local oZ = pData._staticPosOffsetZ or (pData.Graphs.PosOffsetZ and GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.PosOffsetZ, pData.Seeds.PosOffsetZ)) or 0
		local worldOff = Constants.resolveDisplacement(Vector3.new(oX, oY, oZ),
			pData.DisplacementMode or "Global", pData.SpawnRotation, pData.SpawnEmitterRotation,
			pData._displacementMirrorX, pData._displacementMirrorY, pData._displacementMirrorZ)
		delta = worldOff - pData._prevWorldOff
		pData._prevWorldOff = worldOff
	end
	-- Turbulence keeps its own telescoping accumulator (_prevTurbOff): OnHit Bounce
	-- mirrors re-baseline only _prevWorldOff, and noise never mirrors.
	if pData.HasTurbulence then
		delta = delta + Turbulence.frameDelta(pData, steppedI)
	end
	-- Local mode's SpawnRotation is captured link-local under a link, so the delta is
	-- already link-local. Flag it so the apply site skips the second VOS that would
	-- precess it around a spinning Weld instead of letting the radius shrink.
	local isLinkLocal = useVOS and (pData.DisplacementMode or "Global") == "Local"
	return delta, isLinkLocal
end

-- Stack a frame's displacement into a link-local LocalCF accumulator. The world-built
-- velocity is VOS'd into link-local when welded; a link-local PosOffset is added as-is.
-- motionFactor scales the whole spatial delta (Speed + Accel + PosOffset) by the parent
-- Model's scale for nested particles (1 otherwise) — applied to the sum so it stays coherent.
local function _composeLocalDelta(parentCF, useVOS, velWorld, posDelta, posIsLinkLocal, motionFactor)
	if not useVOS then return (velWorld + posDelta) * motionFactor end
	local velLocal = parentCF:VectorToObjectSpace(velWorld)
	local posLocal = posIsLinkLocal and posDelta or parentCF:VectorToObjectSpace(posDelta)
	return (velLocal + posLocal) * motionFactor
end

local UpdateCommon = {}
UpdateCommon._posOffsetFrameDelta = _posOffsetFrameDelta
UpdateCommon._composeLocalDelta = _composeLocalDelta

return UpdateCommon
