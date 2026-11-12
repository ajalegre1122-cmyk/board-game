--[[
	ZOffset Mixin  -  per-frame position shift along particle→camera line for Part / Model / Attachment.
	Positive = closer to camera. Runs after Orientation so velocity derivation uses pre-shifted position.
]]

return function(Particle)

local EPS = 1e-3

function Particle:ApplyZOffset(pData, camPos)
	local zo = pData.ZOffset
	if not zo or zo == 0 then return end
	if not camPos then return end
	if not pData.VisualPart or not pData.VisualPart.Parent then return end
	local t = pData.Type
	if t ~= "Part" and t ~= "Model" and t ~= "Attachment" then return end

	local isModel = t == "Model"
	local isAttachment = t == "Attachment"
	-- Use the pre-overlay base CFrame so ZOffset is an absolute shift; reading live would compound each frame.
	local currentCF = pData._postUpdateCF or (isModel and pData.VisualPart:GetPivot() or pData.VisualPart.CFrame)

	-- Attachment.CFrame is parent-local; convert to world for the camera shift, back to local on write.
	local parentPart
	if isAttachment then
		parentPart = pData.VisualPart.Parent
		if parentPart and parentPart:IsA("BasePart") then
			currentCF = parentPart.CFrame * currentCF
		else
			parentPart = nil
		end
	end

	local pos = currentCF.Position
	local toCam = camPos - pos
	local mag = toCam.Magnitude
	if mag < EPS then return end
	local newPos = pos + (toCam / mag) * zo
	local newCF = CFrame.new(newPos) * (currentCF - pos)

	if parentPart then
		newCF = parentPart.CFrame:ToObjectSpace(newCF)
	end

	if isModel then
		pData.VisualPart:PivotTo(newCF)
	else
		pData.VisualPart.CFrame = newCF
	end
end

end
