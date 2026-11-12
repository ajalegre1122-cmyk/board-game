--[[
	Orientation Mixin  -  per-frame rotation overlay for Part / Model / Attachment.
	Modes mirror ParticleOrientation: None, FacingCamera, FacingCameraWorldUp,
	VelocityParallel, VelocityPerpendicular. Composes as `orient * existingRotation`.
]]

local Log = require(script.Parent.Log)

return function(Particle)

local EPS = 1e-3
local Y_AXIS = Vector3.yAxis
local X_AXIS = Vector3.xAxis
local DEFAULT_VEL = -Vector3.zAxis

function Particle:ApplyOrientation(pData, dt, camPos)
	local mode = pData.Orientation
	if not mode or mode == "None" then return end
	if not pData.VisualPart or not pData.VisualPart.Parent then return end
	local t = pData.Type
	if t ~= "Part" and t ~= "Model" and t ~= "Attachment" then return end

	local isModel = t == "Model"
	local isAttachment = t == "Attachment"
	-- Use pre-overlay base CFrame; reading live would compound previous frame's compose into existingRot.
	local currentCF = pData._postUpdateCF or (isModel and pData.VisualPart:GetPivot() or pData.VisualPart.CFrame)

	-- Attachment.CFrame is parent-local; work in world space for the lookAt, convert back on write.
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
	local existingRot = currentCF - pos

	local vel
	if pData._lastOrientPos then
		vel = (pos - pData._lastOrientPos) / math.max(dt, 1e-4)
	else
		vel = pData.BaseDirection or DEFAULT_VEL
	end
	pData._lastOrientPos = pos

	local orientRot
	if mode == "FacingCamera" then
		if not camPos then return end
		local toCam = camPos - pos
		if toCam.Magnitude < EPS then return end
		orientRot = CFrame.lookAt(Vector3.zero, toCam.Unit)
	elseif mode == "FacingCameraWorldUp" then
		-- Yaw-only: flatten camera direction onto XZ so mesh rotates around world Y only.
		if not camPos then return end
		local toCam = camPos - pos
		local flat = Vector3.new(toCam.X, 0, toCam.Z)
		if flat.Magnitude < EPS then return end
		orientRot = CFrame.lookAt(Vector3.zero, flat.Unit, Y_AXIS)
	elseif mode == "VelocityParallel" then
		-- DirMode=Local already aligns via LocalCF; overlaying here would double-rotate.
		if pData.VelocityVectored then return end
		-- forward = velocity, roll tracks camera so broadside stays visible.
		if vel.Magnitude < EPS then return end
		local upHint = camPos and (camPos - pos) or Y_AXIS
		if upHint.Magnitude < EPS then upHint = Y_AXIS end
		orientRot = CFrame.lookAt(Vector3.zero, vel.Unit, upHint.Unit)
	elseif mode == "VelocityPerpendicular" then
		-- up = velocity, forward fixed in world-horizontal plane.
		if vel.Magnitude < EPS then return end
		local upV = vel.Unit
		local fwd = upV:Cross(Y_AXIS)
		if fwd.Magnitude < EPS then fwd = upV:Cross(X_AXIS) end
		orientRot = CFrame.lookAt(Vector3.zero, fwd.Unit, upV)
	else
		-- Warn once per pData on unknown Orientation so typos don't fail silently.
		if not pData._orientWarned then
			pData._orientWarned = true
			Log.warn("Part-Icles: unknown Orientation '" .. tostring(pData.Orientation) .. "' on emitted particle  -  falling back to identity.")
		end
		return
	end

	local newCF = CFrame.new(pos) * orientRot * existingRot

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
