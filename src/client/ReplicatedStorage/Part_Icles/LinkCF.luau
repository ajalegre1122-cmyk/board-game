--[[
	LinkCF  -  the one place LinkMode semantics are applied.
	Modes (read in GetData.luau): Follow / Pivot inherit the link POSITION only; Weld /
	WeldWithoutRotation inherit the full frame; RigidLocal inherits the frame snapshotted at emit
	(pData._rigidLocalParentCF) and ignores live link motion. Follow and Pivot differ only at spawn:
	Follow drops the link rotation, Pivot composes it (spawnFrame).
	Every emit / update / replay / bounce / preview site composes through these helpers; no other
	file branches on the mode strings (LinkService keeps its own reduced Weld/Follow set).
	Per-axis inheritance (item attrs LinkPosX..Z / LinkRotX..Z, absent = on): a masked axis never takes
	the link's value. For a user link it keeps the emitter's own position / rotation from spawn onward; a
	nested link masks against the link frame captured at emit. Rotation splits on a fixed YXZ order.
]]

local Constants = require(script.Parent.PartConstants)
local Pool = require(script.Parent.Pool)

local LinkCF = {}

-- Link frame with the nested parent-node offset applied (NestedEmit sets pData/emitCtx._linkLocal).
local function linkFrame(link, linkLocal)
	local cf = Constants.resolveLinkCFrame(link)
	if linkLocal then return cf * linkLocal end
	return cf
end

local LINK_AXIS_ATTRS = { "LinkPosX", "LinkPosY", "LinkPosZ", "LinkRotX", "LinkRotY", "LinkRotZ" }

-- Per-axis masks from the item; nil when every axis inherits (the common case, no per-frame cost).
function LinkCF.readAxes(item)
	local axes = nil
	for _, name in ipairs(LINK_AXIS_ATTRS) do
		local on = item:GetAttribute(name) ~= false
		if not on then axes = axes or {} end
		if axes then axes[name] = on end
	end
	if axes then
		for _, name in ipairs(LINK_AXIS_ATTRS) do
			if axes[name] == nil then axes[name] = true end
		end
	end
	return axes
end

-- Masked axes take the reference frame; enabled axes follow the live link.
local function maskFrame(liveCF, refCF, axes)
	local livePos, emitPos = liveCF.Position, refCF.Position
	local pos = Vector3.new(
		axes.LinkPosX and livePos.X or emitPos.X,
		axes.LinkPosY and livePos.Y or emitPos.Y,
		axes.LinkPosZ and livePos.Z or emitPos.Z)
	local rot = liveCF.Rotation
	if not (axes.LinkRotX and axes.LinkRotY and axes.LinkRotZ) then
		local lx, ly, lz = liveCF:ToEulerAnglesYXZ()
		local ex, ey, ez = refCF:ToEulerAnglesYXZ()
		rot = CFrame.fromEulerAnglesYXZ(axes.LinkRotX and lx or ex, axes.LinkRotY and ly or ey, axes.LinkRotZ and lz or ez)
	end
	return CFrame.new(pos) * rot
end

-- Reference frame for masked axes: the emitter's own frame for a user link, the link frame at emit
-- for a nested link (the source template's frame means nothing at the clone).
local function maskReference(pData, linkCF)
	local source = pData._sourceItem
	if pData._nestedDriven or not source or not source.Parent then return linkCF end
	return Constants.resolveLinkCFrame(source)
end

-- Emit-time reference for masked particles (RegisterEmit, after _nestedDriven). worldFrame captures lazily on replay.
function LinkCF.captureEmitFrame(pData)
	if pData.LinkAxes and pData.Link then
		pData._linkMaskRefCF = maskReference(pData, linkFrame(pData.Link, pData._linkLocal))
	end
end

-- Masks for the spawn-time helpers: user links only (nested links mask per frame against their emit frame).
function LinkCF.spawnAxes(data, emitCtx)
	if emitCtx and emitCtx._parentAlive ~= nil then return nil end
	return data.LinkAxes
end

-- Link frame with the spawn masks applied against the emitter's own frame.
local function maskedLinkFrame(link, linkLocal, axes, refCF)
	local frame = linkFrame(link, linkLocal)
	if axes and refCF then return maskFrame(frame, refCF, axes) end
	return frame
end

-- Follow / Pivot inherit position only; the Weld family inherits the full frame.
function LinkCF.positionOnly(mode)
	return mode == "Follow" or mode == "Pivot"
end

-- Motion is expressed in link space (VectorToObjectSpace) for the Weld family only.
function LinkCF.usesLinkSpace(mode, link)
	return (mode == "Weld" or mode == "WeldWithoutRotation" or mode == "RigidLocal") and link ~= nil
end

-- Reduce a link frame to what the mode inherits.
function LinkCF.applyPositionRule(mode, frame)
	if LinkCF.positionOnly(mode) then return CFrame.new(frame.Position) end
	return frame
end

-- Spawn frame under a link: Follow keeps the emitter's own rotation; a self-link IS the emitter
-- frame (composing both would apply its rotation twice); otherwise link rotation composes with the
-- emitter's rotation RELATIVE to its source parent (sourceParentCF, nested) or its world rotation.
-- Mirrored by MotionPreview so the preview matches the live spawn.
function LinkCF.spawnFrame(mode, link, emitter, sourceCF, linkLocal, sourceParentCF, axes)
	local linkCF = linkFrame(link, linkLocal)
	local frame
	if mode == "Follow" then
		frame = CFrame.new(linkCF.Position) * sourceCF.Rotation
	elseif link == emitter then
		frame = sourceCF
	else
		local relRot = sourceParentCF and (sourceParentCF.Rotation:Inverse() * sourceCF.Rotation) or sourceCF.Rotation
		frame = CFrame.new(linkCF.Position) * linkCF.Rotation * relRot
	end
	-- Masked axes spawn at the emitter's own pose (spawnAxes is nil for nested links).
	if axes then return maskFrame(frame, sourceCF, axes) end
	return frame
end

-- Origin frame for an emitter whose START rides a user link and is re-read through its life
-- (Lightning/Endpoints, every roll). Follow takes the link's position and keeps the emitter's own
-- rotation; Weld adds the link's rotation; Pivot takes that rotation once, at the first read;
-- RigidLocal stays where the link was at the first read. WeldWithoutRotation has no offset to
-- rotate here and reads as Follow. A link that is gone holds the last frame (nil if never read).
function LinkCF.originFrame(pData, link, emitter, sourceCF)
	local mode = pData.LinkMode
	if mode == "WeldWithoutRotation" then mode = "Follow" end
	if mode == "RigidLocal" and pData._originLinkCF then return pData._originLinkCF end
	if not link or link.Parent == nil then return pData._originLinkCF end
	local frame
	if mode == "Pivot" and pData._originPivotRot then
		local followed = LinkCF.spawnFrame("Follow", link, emitter, sourceCF, nil, nil, pData.LinkAxes)
		frame = CFrame.new(followed.Position) * pData._originPivotRot
	else
		frame = LinkCF.spawnFrame(mode, link, emitter, sourceCF, nil, nil, pData.LinkAxes)
		if mode == "Pivot" then pData._originPivotRot = frame.Rotation end
	end
	pData._originLinkCF = frame
	return frame
end

-- Parent frame from a LIVE link at emit time (no snapshot exists yet). Identity without a link.
function LinkCF.emitParentFrame(mode, link, linkLocal, axes, refCF)
	if not link then return CFrame.new() end
	return LinkCF.applyPositionRule(mode, maskedLinkFrame(link, linkLocal, axes, refCF))
end

-- Attachment visuals compose in their parent's space: a BasePart's CFrame, or an Attachment's
-- WorldCFrame (Animate visuals live under the source Attachment). Anything else is world space.
function LinkCF.toParentSpace(worldCF, visualParent)
	local convCF = CFrame.new()
	if visualParent then
		if visualParent:IsA("BasePart") then
			convCF = visualParent.CFrame
		elseif visualParent:IsA("Attachment") then
			convCF = visualParent.WorldCFrame
		end
	end
	return convCF:ToObjectSpace(worldCF)
end

-- Attachment variant of emitParentFrame, in `visualParent`-local space.
function LinkCF.emitAttachmentParentFrame(mode, link, visualParent, linkLocal, axes, refCF)
	if not link then return CFrame.new() end
	return LinkCF.applyPositionRule(mode, LinkCF.toParentSpace(maskedLinkFrame(link, linkLocal, axes, refCF), visualParent))
end

-- RigidLocal snapshot taken at emit: the frame the particle stays welded to. nil for other modes.
function LinkCF.rigidSnapshot(mode, link, frame)
	if mode == "RigidLocal" and link then return frame end
	return nil
end

-- Attachment snapshots keep the WORLD link frame; per-frame readers convert to parent space.
function LinkCF.rigidWorldSnapshot(mode, link, linkLocal, axes, refCF)
	if mode == "RigidLocal" and link then return maskedLinkFrame(link, linkLocal, axes, refCF) end
	return nil
end

-- A link is live while it is parented and the pool has not recycled it since this particle
-- captured it (pData._linkGen, stamped by RegisterEmit).
function LinkCF.isValid(pData, link)
	if not link or link.Parent == nil then return false end
	return Pool.linkGen(link) == (pData._linkGen or 0)
end

-- Link lost: keep the last good frame so the particle carries on from where its parent died
-- instead of collapsing onto the world origin. Readers see the frozen frame through parentFrame.
function LinkCF.freeze(pData)
	pData._frozenLinkCF = pData._lastLinkCF or CFrame.new()
	pData.Link = nil
end

-- World frame of the link as this particle sees it: the emit snapshot for RigidLocal (never
-- freezes), the live link otherwise. Records the frame so freeze() can keep it.
function LinkCF.worldFrame(pData, link)
	if pData.LinkMode == "RigidLocal" then
		return pData._rigidLocalParentCF or CFrame.new()
	end
	local cf = linkFrame(link, pData._linkLocal)
	local axes = pData.LinkAxes
	if axes then
		if not pData._linkMaskRefCF then pData._linkMaskRefCF = maskReference(pData, cf) end
		cf = maskFrame(cf, pData._linkMaskRefCF, axes)
	end
	pData._lastLinkCF = cf
	return cf
end

-- Live, frozen or snapshot frame for the per-frame readers; nil when the particle never had a link.
local function currentFrame(pData)
	if pData.LinkMode == "RigidLocal" then return pData._rigidLocalParentCF end
	local link = pData.Link
	if link then
		if LinkCF.isValid(pData, link) then return LinkCF.worldFrame(pData, link) end
		LinkCF.freeze(pData)
	end
	return pData._frozenLinkCF
end

-- Per-frame parent frame for Part / Model. Returns (parentCF, useVOS); identity when there never was a link.
function LinkCF.parentFrame(pData)
	local worldCF = currentFrame(pData)
	if not worldCF then return CFrame.new(), false end
	if LinkCF.positionOnly(pData.LinkMode) then return CFrame.new(worldCF.Position), false end
	return worldCF, true
end

-- Per-frame parent frame for Attachment, in visual-parent-local space. Returns (parentCF, useVOS, hasLink).
function LinkCF.attachmentParentFrame(pData)
	local worldCF = currentFrame(pData)
	if not worldCF then return CFrame.new(), false, false end
	local visualParent = pData.VisualPart and pData.VisualPart.Parent
	if not visualParent then return CFrame.new(), false, false end
	local linkLocalCF = LinkCF.toParentSpace(worldCF, visualParent)
	if LinkCF.positionOnly(pData.LinkMode) then return CFrame.new(linkLocalCF.Position), false, true end
	return linkLocalCF, true, true
end

-- LinkTrack reapply for Part / Model: WeldWithoutRotation rotates only the offset and keeps the
-- particle's own rotation; Follow / Pivot translate; Weld composes fully. Attachments have no
-- WeldWithoutRotation variant (LinkTrack applies applyPositionRule to them).
function LinkCF.reapplyFrame(mode, linkCF, localCF)
	if mode == "WeldWithoutRotation" then
		local worldOffset = linkCF:VectorToWorldSpace(localCF.Position)
		local rotOnly = localCF - localCF.Position
		return CFrame.new(linkCF.Position + worldOffset) * rotOnly
	end
	if LinkCF.positionOnly(mode) then return CFrame.new(linkCF.Position) * localCF end
	return linkCF * localCF
end

return LinkCF
