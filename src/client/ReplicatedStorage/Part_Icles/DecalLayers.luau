--[[
	DecalLayers  -  per-decal appearance + flipbook for Part visuals ("decal layers").

	Each Decal / Texture directly under the RenderTemplate is a layer, identified by its name (an
	occurrence index breaks ties). Layer settings are attributes on that RT decal:
	  LayerTransparency / LayerColor / LayerBrightness  graphs over life (nil = 0 / authored Color3 / 1)
	  LayerFlipbook       name of a MeshFlipbooks sub-folder; nil = the first layer inherits the legacy
	                      flat frames, "None" = no flipbook
	  LayerFlipbookMode / LayerFlipbookFramerate / LayerFlipbookStartRandom / LayerFlipbookReverse
	                      nil = inherit the part-level Flipbook settings
	  LayerActive         inventory insert target (UI only)
	On a Part + SpecialMesh visual with textured mesh frames the first decal's texture is written by
	Modules/Part/MeshFrames per mesh frame, so that layer runs no flipbook of its own.
	MeshFlipbooks holds one sub-folder of numbered frames per flipbook; numbered frames directly in the
	folder are the legacy single flipbook (set "").

	Config attribute DecalLayers (Transform stamps true; Migrate promotes legacy items) selects the mode:
	true = the part's Transparency / Color / Brightness graphs drive the MESH and layers drive their
	decals; false / nil = legacy (part graphs drive the first decal). Emit / EmitAnimate / Update branch
	on data.DecalLayersMode / pData.DecalLayersMode.

	Mutates clone decals (Emit) or the LIVE RT decals (Animate: snapshot at attach, restore() on finish
	and cancel). refresh() re-reads graphs per AnimateLoop cycle. write() allocates nothing but the
	Color3 it assigns.
]]

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local MeshFlipMod = require(script.Parent.Flipbook)

local DecalLayers = {}

local WHITE = Color3.new(1, 1, 1)

local function isLayerInstance(inst)
	return inst:IsA("Decal") or inst:IsA("Texture")
end

-- Ordered layer descriptors from the RT's direct Decal / Texture children.
local function readLayers(rt)
	local layers = {}
	if not rt then return layers end
	local seen = {}
	for _, child in ipairs(rt:GetChildren()) do
		if not isLayerInstance(child) then continue end
		seen[child.Name] = (seen[child.Name] or 0) + 1
		local color = child:GetAttribute("LayerColor")
		if typeof(color) ~= "ColorSequence" then color = ColorSequence.new(child.Color3) end
		table.insert(layers, {
			name = child.Name,
			occurrence = seen[child.Name],
			texture = child.Texture,
			transparency = child:GetAttribute("LayerTransparency"),
			color = color,
			brightness = child:GetAttribute("LayerBrightness"),
			flipbook = child:GetAttribute("LayerFlipbook"),
			mode = child:GetAttribute("LayerFlipbookMode"),
			framerate = child:GetAttribute("LayerFlipbookFramerate"),
			startRandom = child:GetAttribute("LayerFlipbookStartRandom"),
			reverse = child:GetAttribute("LayerFlipbookReverse"),
		})
	end
	return layers
end

-- GetData hook: mode flag, flipbook sets, layer descriptors. CachedMeshTextures keeps the flat set
-- (or the first sub-folder by name) for SurfaceAppearance, MeshPart and legacy targets.
function DecalLayers.readInto(data, item, config)
	data.DecalLayersMode = config:GetAttribute("DecalLayers") == true
	data.MeshFlipbooks = item:FindFirstChild("MeshFlipbooks")
	data.MeshFlipbookSets = data.MeshFlipbooks and MeshFlipMod.GetFlipbookSets(data.MeshFlipbooks) or {}
	data.CachedMeshTextures = data.MeshFlipbookSets[""]
	if not data.CachedMeshTextures then
		local names = {}
		for name in pairs(data.MeshFlipbookSets) do table.insert(names, name) end
		table.sort(names)
		if names[1] then data.CachedMeshTextures = data.MeshFlipbookSets[names[1]] end
	end
	data.DecalLayers = data.DecalLayersMode and readLayers(item:FindFirstChild("RenderTemplate")) or {}
end

-- Frames for a layer: its assigned sub-folder, or the legacy flat set for an unassigned first layer.
local function framesFor(data, layer, index)
	local key = layer.flipbook
	if key == "None" then return nil end
	if key == nil or key == "" then
		if index == 1 then return data.MeshFlipbookSets[""] end
		return nil
	end
	return data.MeshFlipbookSets[key]
end

-- Bind descriptors to the visual's decals (name + occurrence), write t=0 and start the flipbooks.
-- liveSource = Animate on the RT itself: snapshot for restore(), never cycle textures on it.
function DecalLayers.attach(pData, data, visualPart, lifetime, liveSource)
	pData.Layers = nil
	local descriptors = data.DecalLayers
	if not data.DecalLayersMode or not descriptors or #descriptors == 0 then return end
	local particle = data.ParticleData
	local byKey = {}
	for index, desc in ipairs(descriptors) do byKey[desc.name .. "#" .. desc.occurrence] = index end
	local meshFramesOwnFirst = data.MeshFramesTextured == true and visualPart:FindFirstChildOfClass("SpecialMesh") ~= nil
	local seen = {}
	local layers = {}
	for _, child in ipairs(visualPart:GetChildren()) do
		if not isLayerInstance(child) then continue end
		seen[child.Name] = (seen[child.Name] or 0) + 1
		local index = byKey[child.Name .. "#" .. seen[child.Name]]
		local desc = index and descriptors[index]
		if not desc then continue end
		local entry = {
			decal = child,
			transparency = desc.transparency, color = desc.color, brightness = desc.brightness,
			transparencySeed = GraphMod.GenerateSeed(desc.transparency),
			brightnessSeed = GraphMod.GenerateSeed(desc.brightness),
		}
		if liveSource then
			entry.snapshot = { transparency = child.Transparency, color = child.Color3, texture = child.Texture }
		elseif meshFramesOwnFirst and index == 1 then
			-- Texture written per mesh frame by MeshFrames.
		else
			local frames = framesFor(data, desc, index)
			local mode = desc.mode or (particle.FlipbookMode and particle.FlipbookMode.Name) or "None"
			if frames and #frames > 0 and mode ~= "None" then
				local framerate = RangeMod.RandomValueFromRange(desc.framerate or particle.FlipbookFramerate or NumberRange.new(30))
				local startRandom = desc.startRandom
				if startRandom == nil then startRandom = particle.FlipbookStartRandom end
				local reverse = desc.reverse
				if reverse == nil then reverse = particle.FlipbookReverse end
				entry.flip = MeshFlipMod.layerState(child, frames, mode, framerate, startRandom, reverse)
			else
				-- A pooled clone may still show the previous emit's last frame.
				child.Texture = desc.texture
			end
		end
		table.insert(layers, entry)
	end
	if #layers == 0 then return end
	pData.Layers = layers
	DecalLayers.write(pData, 0)
	if not liveSource then MeshFlipMod.FlipLayers(pData, layers, lifetime) end
end

-- Stepped write at normalized life t; honours the event payload's SkipTransparency / SkipColor.
function DecalLayers.write(pData, t)
	local layers = pData.Layers
	if not layers then return end
	for i = 1, #layers do
		local layer = layers[i]
		local decal = layer.decal
		local trans = layer.transparency and GraphMod.QueryPointsWithTime(t, layer.transparency, layer.transparencySeed) or 0
		local bright = layer.brightness and GraphMod.QueryPointsWithTime(t, layer.brightness, layer.brightnessSeed) or 1
		local color = layer.color and GraphMod.QueryColorPointWithTime(t, layer.color) or WHITE
		if not pData.SkipTransparency then decal.Transparency = trans end
		if not pData.SkipColor then
			decal.Color3 = Color3.fromRGB(color.R * 255 * bright, color.G * 255 * bright, color.B * 255 * bright)
		end
	end
end

-- Animate finish / cancel: put the live RT decals back exactly as attach() found them.
function DecalLayers.restore(pData)
	local layers = pData.Layers
	if not layers then return end
	for i = 1, #layers do
		local layer = layers[i]
		local snap = layer.snapshot
		if snap and layer.decal.Parent then
			pcall(function()
				layer.decal.Transparency = snap.transparency
				layer.decal.Color3 = snap.color
				layer.decal.Texture = snap.texture
			end)
		end
	end
end

-- AnimateLoop cycle: re-read the graphs (and roll fresh envelope seeds) for the bound decals.
function DecalLayers.refresh(pData, freshData)
	local layers = pData.Layers
	if not layers or not freshData.DecalLayers then return end
	local byKey = {}
	for _, desc in ipairs(freshData.DecalLayers) do byKey[desc.name .. "#" .. desc.occurrence] = desc end
	local seen = {}
	for i = 1, #layers do
		local layer = layers[i]
		local name = layer.decal.Name
		seen[name] = (seen[name] or 0) + 1
		local desc = byKey[name .. "#" .. seen[name]]
		if desc then
			layer.transparency, layer.color, layer.brightness = desc.transparency, desc.color, desc.brightness
			layer.transparencySeed = GraphMod.GenerateSeed(desc.transparency)
			layer.brightnessSeed = GraphMod.GenerateSeed(desc.brightness)
		end
	end
end

return DecalLayers
