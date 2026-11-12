--[[
	NestedEmit - source-walk dispatcher for nested transformed Part-Icles.

	Walks SOURCE RenderTemplate (never clones nested-source subtrees). Each
	transformed leaf fires via particle:EnableEmit with link=clonedRoot, which
	EmitPart's link branch consumes for both initial spawn pose and per-frame
	tracking. parentAlive cancels nested closures on parent pData reclaim.
]]

local Pool = require(script.Parent.Pool)
local Constants = require(script.Parent.PartConstants)

local NestedEmit = {}

-- Nearest ancestor with a world frame (BasePart / Attachment / Model / Bone), stopping at the RT root.
local function nearestFrameAncestor(node, sourceRT)
	local cur = node.Parent
	while cur and cur ~= sourceRT do
		if cur:IsA("BasePart") or cur:IsA("Attachment") or cur:IsA("Model") then return cur end
		cur = cur.Parent
	end
	return sourceRT
end

-- Walk source RT, fire each Transformed leaf. scaleNode (optional) is the parent-Model scale
-- chain node every leaf inherits as descCtx.ParentScale: a Model passes its own node, a
-- Part/Attachment forwards the node it inherited. _parentCloneMap forwards Pool's
-- source-to-clone map so nested Trail/Beam can rebind Attachment0/1.
-- _linkLocal is the leaf's parent-node offset from the RT root, so a leaf under a Model sub-part
-- spawns and tracks at that sub-part (LinkCF applies it to every link frame); nil at the root, which
-- keeps depth-1 children of a Part RT spawning at the clone itself. _sourceParentCF lets the spawn
-- rotation compose relative to that parent node instead of doubling the parent's world rotation.
function NestedEmit.walk(particle, sourceRT, clonedRoot, parentAlive, emitCtx, scaleNode)
	if parentAlive and parentAlive[1] == false then return end
	local parentCloneMap = Pool._cloneMaps and Pool._cloneMaps[clonedRoot]
	-- Chain to the grandparent's map so a leaf resolves attachments authored one level up.
	-- Pool hits reuse the map, so the chain is refreshed rather than set once.
	local grandMap = emitCtx and emitCtx._parentCloneMap
	if parentCloneMap and grandMap and grandMap ~= parentCloneMap then
		local mt = getmetatable(parentCloneMap)
		if mt then mt.__index = grandMap else setmetatable(parentCloneMap, { __index = grandMap }) end
	end
	local leaves = {}
	local function visit(node)
		if node:GetAttribute("Transformed") then
			leaves[#leaves + 1] = node
			return
		end
		for _, child in node:GetChildren() do visit(child) end
	end
	visit(sourceRT)
	if #leaves == 0 then return end
	local rootCF = Constants.resolveLinkCFrame(sourceRT)
	local function fire(node)
		local descCtx = { ParentScale = scaleNode }
		local parentNode = nearestFrameAncestor(node, sourceRT)
		local parentCF = (parentNode == sourceRT) and rootCF or Constants.resolveLinkCFrame(parentNode)
		descCtx._sourceParentCF = parentCF
		if parentNode ~= sourceRT then descCtx._linkLocal = rootCF:ToObjectSpace(parentCF) end
		if emitCtx then
			descCtx.ChainCtx  = emitCtx.ChainCtx
			descCtx.EmitIndex = emitCtx.EmitIndex
			descCtx.EmitCount = emitCtx.EmitCount
			-- Forward the ghost play token so nested particles belong to the same play
			-- (PlayHandle:Disable / SetTimescale / GetParticles reach them too).
			descCtx._playToken = emitCtx._playToken
		end
		descCtx._parentAlive = parentAlive
		descCtx._parentCloneMap = parentCloneMap
		particle:EnableEmit(node, clonedRoot, descCtx)
	end
	-- Attachment emitters first: EmitAttachment registers its visual in the map, so sibling
	-- Beams / Trails fired in the same walk bind their ends to the emitted attachment, and
	-- stock Beams / Trails in the parent copy are bound as each attachment registers.
	for _, node in ipairs(leaves) do
		if node:IsA("Attachment") then fire(node) end
	end
	for _, node in ipairs(leaves) do
		if not node:IsA("Attachment") then fire(node) end
	end
end


-- Clone-side parent for a nested visual: the parent's copyBare clone of the source's nearest
-- BasePart ancestor, else the parent clone root when it is a BasePart. nil when not nested-driven
-- or nothing suitable was cloned (rig parents build per-segment copies and keep no map).
-- Consumer: EmitAttachment (visual parent). Keeps emitted visuals inside the parent
-- clone instead of the source RenderTemplate, where a later copyBare would template them.
function NestedEmit.resolveCloneParent(sourceNode, link, emitCtx)
	if not emitCtx then return nil end
	local map = emitCtx._parentCloneMap
	if map then
		local node = sourceNode.Parent
		while node and node ~= workspace do
			local clone = map[node]
			if clone then
				if clone:IsA("BasePart") then return clone end
				break
			end
			node = node.Parent
		end
	end
	if emitCtx._parentAlive and link and link:IsA("BasePart") then return link end
	return nil
end

return NestedEmit
