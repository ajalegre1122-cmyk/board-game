--[[
	CameraShake/Apply  -  module-level camera-offset accumulator.
	Every live CameraShake pData adds its frame contribution via accumulate();
	Engine calls applyFrame() ONCE per step after the update loop, composing
	cam.CFrame = cam.CFrame * prevApplied:Inverse() * newOffset.

	Removal ALWAYS composes, even when something else moved the camera since our
	last write. Studio's edit-mode camera controller builds each new pose on the
	current CFrame (our offset baked in), so unconditional removal is what keeps
	the camera level after the shake. Never compare CFrames for equality here:
	the engine orthonormalizes on write, so read-back is not bit-identical and an
	equality guard skips removal every frame (offsets then random-walk into a
	permanent tilt). Play-mode camera scripts rewrite the camera wholesale each
	frame BEFORE us (priority 200 vs our Last+1), so the stale removal there is a
	bounded one-frame error the next rewrite wipes.
]]

local Apply = {}

local sumX, sumY, sumZ = 0, 0, 0
local rotX, rotY, rotZ = 0, 0, 0
local prevApplied = CFrame.identity
local hasApplied = false
local appliedCam = nil

-- Translation in studs (camera-local), rotation in radians.
function Apply.accumulate(dx, dy, dz, rx, ry, rz)
	sumX += dx; sumY += dy; sumZ += dz
	rotX += rx; rotY += ry; rotZ += rz
end

local function clearState()
	sumX, sumY, sumZ, rotX, rotY, rotZ = 0, 0, 0, 0, 0, 0
	prevApplied = CFrame.identity
	hasApplied = false
	appliedCam = nil
end

function Apply.applyFrame()
	local active = sumX ~= 0 or sumY ~= 0 or sumZ ~= 0 or rotX ~= 0 or rotY ~= 0 or rotZ ~= 0
	if not hasApplied and not active then return end
	local cam = workspace.CurrentCamera
	if not cam then
		clearState()
		return
	end
	-- Camera swapped since our last write: the offset lives on the OLD camera.
	-- Remove it there; never compose the stale inverse on the new one.
	if appliedCam and appliedCam ~= cam then
		if hasApplied and appliedCam.Parent then
			pcall(function() appliedCam.CFrame = appliedCam.CFrame * prevApplied:Inverse() end)
		end
		prevApplied = CFrame.identity
		hasApplied = false
	end
	local newOffset = CFrame.new(sumX, sumY, sumZ) * CFrame.fromOrientation(rotX, rotY, rotZ)
	cam.CFrame = cam.CFrame * prevApplied:Inverse() * newOffset
	prevApplied = newOffset
	hasApplied = active
	appliedCam = cam
	sumX, sumY, sumZ, rotX, rotY, rotZ = 0, 0, 0, 0, 0, 0
end

-- Synchronous restore + full clear. Engine Deactivate calls this; after it the
-- accumulator is cold and applyFrame's idle early-out costs a few compares.
function Apply.reset()
	if hasApplied and appliedCam and appliedCam.Parent then
		pcall(function() appliedCam.CFrame = appliedCam.CFrame * prevApplied:Inverse() end)
	end
	clearState()
end

return Apply
