--[[
	Lightning/ImpactDisk  -  the flat disk at a bolt's strike point: a thin cylinder whose axis
	follows the surface normal, optionally textured (Decal on the outward face). It exists only
	while the strike ray hits a surface; a bolt that ends in the air shows no disk.

	Colour always follows the bolt tip: Color graph x Gradient at the far end of the arc.
	DiskMode "Follow": size = DiskSize x thickness ratio x (1 - bolt transparency); transparency
	and brightness come from the bolt graphs. "Manual": DiskSize / DiskTransparency /
	DiskBrightness graphs drive the disk directly.
	Reads pData._curThick / _curTrans / _curBright written by Lightning/init.luau writeVisuals.

	Normal: Seek bolts use the scan hit; Point / Directional cast one ray along the bolt from
	its origin and re-cast only after the strike point moved RAY_REFRESH_DIST (never per frame).
	Lifetime: pData._impactDisk is destroyed by LifecycleRelease._releaseVisual and by
	cancelAnimation; it lives beside the bolt Model (never inside a pooled Model).
]]

local GraphMod = require(script.Parent.Parent.Graph)
local EventsMod = require(script.Parent.Parent.Events)

local ImpactDisk = {}

local DISK_THICKNESS = 0.05
local RAY_REFRESH_DIST = 0.5
local RAY_OVERSHOOT = 1.05
local WHITE = Color3.new(1, 1, 1)

-- Raycast params for the strike ray (Seek bolts reuse their own seek params).
local function buildRayFn(particle, pData)
	local params = EventsMod.makeHitParams(pData)
	params.RespectCanCollide = true
	pcall(function()
		params:AddToFilter(particle:GetFolder())
		params:AddToFilter(particle:GetPoolFolder())
	end)
	pData._diskRayFn = function(origin, disp)
		return workspace:Raycast(origin, disp, params)
	end
end

-- Surface normal + disk position for the current endpoints; nil when the bolt hits nothing.
local function resolveSurface(pData, startPos, endPos)
	if pData._endpointMode == "Seek" then
		local hit = pData._seekHit
		if hit then return hit.Normal, endPos end
		return nil
	end
	local last = pData._diskRayPos
	if last and (endPos - last).Magnitude < RAY_REFRESH_DIST then
		return pData._diskNormal, pData._diskHitPos
	end
	pData._diskRayPos = endPos
	local span = endPos - startPos
	local rayFn = pData._seekRayFn or pData._diskRayFn
	local hit = rayFn and span.Magnitude > 1e-4 and rayFn(startPos, span * RAY_OVERSHOOT) or nil
	pData._diskNormal = hit and hit.Normal or nil
	pData._diskHitPos = hit and hit.Position or nil
	return pData._diskNormal, pData._diskHitPos
end

-- The visible surface: the decal on textured disks, the cylinder otherwise.
local function surfaceOf(pData)
	return pData._impactDecal or pData._impactDisk
end

-- Cylinder axis is +X: yaw lookAt's -Z onto the normal so the caps face along it.
function ImpactDisk.place(pData, startPos, endPos)
	local disk = pData._impactDisk
	if not disk or not startPos or not endPos then return end
	local normal, position = resolveSurface(pData, startPos, endPos)
	if not normal then
		if not pData._diskHidden then
			pData._diskHidden = true
			surfaceOf(pData).Transparency = 1
		end
		return
	end
	local lifted = position + normal * (pData._diskOffset or DISK_THICKNESS)
	disk.CFrame = CFrame.lookAt(lifted, lifted + normal) * CFrame.Angles(0, math.pi / 2, 0)
	if pData._diskHidden then
		pData._diskHidden = false
		ImpactDisk.write(pData, pData._diskLastT or 0)
	end
end

-- Graph writes at normalized life t (called from the bolt's stepped writeVisuals).
function ImpactDisk.write(pData, t)
	local disk = pData._impactDisk
	if not disk then return end
	pData._diskLastT = t
	if pData._diskHidden then return end
	local graphs, seeds = pData.Graphs, pData.Seeds
	local size = graphs.DiskSize and GraphMod.QueryPointsWithTime(t, graphs.DiskSize, seeds.DiskSize) or 2
	local trans, bright
	if pData._diskMode == "Manual" then
		trans = graphs.DiskTransparency and GraphMod.QueryPointsWithTime(t, graphs.DiskTransparency, seeds.DiskTransparency) or 0
		bright = graphs.DiskBrightness and GraphMod.QueryPointsWithTime(t, graphs.DiskBrightness, seeds.DiskBrightness) or 1
	else
		trans = pData._curTrans or 0
		bright = pData._curBright or 1
		local thick0 = pData._diskThick0 or 0
		local thickRatio = thick0 > 1e-4 and (pData._curThick or thick0) / thick0 or 1
		size = size * thickRatio * math.clamp(1 - trans, 0, 1)
	end
	disk.Size = Vector3.new(DISK_THICKNESS, math.max(0.05, size), math.max(0.05, size))

	local base = graphs.Color and GraphMod.QueryColorPointWithTime(t, graphs.Color) or pData._diskBaseColor or WHITE
	local tip = pData._diskTipTint
	local r, g, b = base.R * bright, base.G * bright, base.B * bright
	if tip then r, g, b = r * tip.R, g * tip.G, b * tip.B end
	local color = Color3.new(math.min(r, 1), math.min(g, 1), math.min(b, 1))
	local decal = pData._impactDecal
	if decal then
		decal.Transparency = trans
		decal.Color3 = color
	else
		disk.Transparency = trans
		disk.Color = color
	end
end

-- Create the disk for a bolt whose endpoints have already been rolled once (applyRoll at emit).
function ImpactDisk.attach(particle, pData, data)
	if not data.DiskEnabled or pData._impactDisk then return end
	local model = pData.VisualPart
	if not model or not model.Parent then return end
	local disk = Instance.new("Part")
	disk.Name = "ImpactDisk"
	disk.Shape = Enum.PartType.Cylinder
	disk.Anchored = true
	disk.CanCollide = false
	disk.CanQuery = false
	disk.CanTouch = false
	disk.Massless = true
	disk.CastShadow = false
	disk.Locked = true
	disk.Archivable = false
	disk.Size = Vector3.new(DISK_THICKNESS, 1, 1)
	local baseColor = WHITE
	pcall(function()
		disk.Material = data.RenderTemplate.Material
		baseColor = data.RenderTemplate.Color
	end)
	local texture = data.DiskTexture
	if type(texture) == "string" and texture ~= "" then
		local decal = Instance.new("Decal")
		decal.Name = "Face"
		decal.Face = Enum.NormalId.Right
		decal.Texture = texture
		decal.Parent = disk
		-- Textured disks show only the decal; the backing cylinder stays invisible.
		disk.Transparency = 1
		pData._impactDecal = decal
	end
	pData._impactDisk = disk
	pData._diskMode = data.DiskMode or "Follow"
	pData._diskOffset = data.DiskOffset or DISK_THICKNESS
	pData._diskThick0 = pData._curThick or 0.15
	pData._diskBaseColor = baseColor
	local gradient = pData.Graphs.Gradient
	pData._diskTipTint = gradient and GraphMod.QueryColorPointWithTime(1, gradient) or nil
	pData._diskHidden = false
	pData._diskLastT = 0
	pData._diskRayPos = nil
	pData._diskNormal = nil
	pData._diskHitPos = nil
	pData.Graphs.DiskSize = data.DiskSize
	pData.Graphs.DiskTransparency = data.DiskTransparency
	pData.Graphs.DiskBrightness = data.DiskBrightness
	pData.Seeds.DiskSize = data.DiskSize and GraphMod.GenerateSeed(data.DiskSize) or {}
	pData.Seeds.DiskTransparency = data.DiskTransparency and GraphMod.GenerateSeed(data.DiskTransparency) or {}
	pData.Seeds.DiskBrightness = data.DiskBrightness and GraphMod.GenerateSeed(data.DiskBrightness) or {}
	if pData._endpointMode ~= "Seek" then buildRayFn(particle, pData) end
	disk.Parent = model.Parent
	ImpactDisk.place(pData, pData._lastStartPos, pData._lastEndPos)
	ImpactDisk.write(pData, 0)
end

function ImpactDisk.detach(pData)
	local disk = pData._impactDisk
	if disk then pcall(function() disk:Destroy() end) end
	pData._impactDisk = nil
	pData._impactDecal = nil
	pData._diskRayFn = nil
	pData._diskTipTint = nil
end

-- AnimateLoop cycle refresh: rebuild against the fresh data (DiskEnabled / DiskMode may have flipped).
function ImpactDisk.refresh(particle, pData, freshData)
	ImpactDisk.detach(pData)
	ImpactDisk.attach(particle, pData, freshData)
end

return ImpactDisk
