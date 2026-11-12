--[[
	LinkTrack Mixin  -  per-frame link transform reapply for Part / Model / Attachment.
	Runs every Heartbeat (outside the step gate) so linked particles track their link every frame.
	`pData._localWorldCF` is the link-relative composed CFrame stashed by UpdatePart/Model/Attachment.
	Attachment composes in actualParent-local space, mirroring getAttachmentLinkCF in Update.luau.
]]

local LinkCF = require(script.Parent.LinkCF)

return function(Particle)

-- Per-frame link-CFrame writer. Composes `pData._localWorldCF` against the live link
-- target and writes the result to `pData.VisualPart` so linked particles track their
-- link every Heartbeat. No-op when pData.Link is nil or destroyed.
function Particle:ReapplyLink(pData)
	local link = pData.Link
	if not link then return end
	-- Destroyed or pool-recycled link: freeze the last good frame (LinkCF) so per-step
	-- updates keep composing from where the parent died; nothing to reapply per frame.
	if not LinkCF.isValid(pData, link) then
		LinkCF.freeze(pData)
		return
	end
	local lcf = pData._localWorldCF
	if not lcf then return end
	if not pData.VisualPart or not pData.VisualPart.Parent then return end
	local t = pData.Type
	if t ~= "Part" and t ~= "Model" and t ~= "Attachment" then return end

	if t == "Attachment" then
		local visualParent = pData.VisualPart.Parent
		if not visualParent then return end
		-- Attachments compose in their parent's space and have no WeldWithoutRotation variant.
		local linkLocalCF = LinkCF.toParentSpace(LinkCF.worldFrame(pData, link), visualParent)
		pData.VisualPart.CFrame = LinkCF.applyPositionRule(pData.LinkMode, linkLocalCF) * lcf
		return
	end

	local newCF = LinkCF.reapplyFrame(pData.LinkMode, LinkCF.worldFrame(pData, link), lcf)

	if t == "Model" then
		pData.VisualPart:PivotTo(newCF)
	else
		pData.VisualPart.CFrame = newCF
	end
end

end
