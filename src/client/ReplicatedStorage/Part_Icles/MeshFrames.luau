--[[
	MeshFrames  -  mesh sequence playback for Part visuals (a flipbook of MeshParts).

	A MeshFrames Folder under the item holds frames named 1..N: MeshParts, or Parts with a SpecialMesh.
	Each frame carries a mesh id and, optionally, a texture id. The visual steps through them on the
	particle's own clock (pData._effectiveElapsed, so Timescale / Pause / FreezeTime / reverse apply);
	the Size graph keeps driving the visual's size and every frame is fitted into that box.

	Two routes, chosen by the visual:
	  MeshPart          MeshPart:ApplyMesh with the frame instance (the only runtime-legal mesh change).
	                    ApplyMesh copies TextureID with the mesh, so a textured frame wins and an untextured
	                    frame gets the visual's current texture written back after the swap. The frame
	                    instances must exist in the place; the folder under the item guarantees that.
	  Part + SpecialMesh  SpecialMesh.MeshId and the frame's texture are written together: the texture goes
	                    to the RenderTemplate's first Decal / Texture (so a Neon part keeps glowing), else to
	                    SpecialMesh.TextureId. DecalLayers leaves that first decal's flipbook to this module.
	data.MeshFramesTextured (any frame with a texture) tells Emit to skip the legacy texture flipbook.

	Config attributes: MeshFrameMode ("None" / OneShot / Loop / PingPong), MeshFrameFramerate
	(NumberRange), MeshFrameStartRandom, MeshFrameReverse.

	Mutates the clone (Emit) or the LIVE RT (Animate: a backup of the mesh and texture taken at attach,
	restore() puts it back on finish and cancel). refresh() re-reads the settings per AnimateLoop cycle.
	The frame task allocates nothing per tick.
]]

local ContentProvider = game:GetService("ContentProvider")
local RangeMod = require(script.Parent.Range)
local MeshFlipMod = require(script.Parent.Flipbook)
local VisualHost = require(script.Parent.VisualHost)
local Log = require(script.Parent.Log)

local MeshFrames = {}

local MODES = { OneShot = true, Loop = true, PingPong = true }
local preloadedCount = setmetatable({}, { __mode = "k" })
local warnedUnsupported = false

-- Shared with the plugin's Mesh Frames panel and inventory insert so all three agree on what a frame is.
local function isFrame(inst)
	return inst:IsA("MeshPart") or (inst:IsA("BasePart") and inst:FindFirstChildOfClass("SpecialMesh") ~= nil)
end
MeshFrames.isFrame = isFrame

local function firstDecal(part)
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("Decal") or child:IsA("Texture") then return child end
	end
	return nil
end

-- Mesh id and texture id a frame carries ("" when untextured).
local function frameIds(frame)
	if frame:IsA("MeshPart") then return frame.MeshId, frame.TextureID end
	local mesh = frame:FindFirstChildOfClass("SpecialMesh")
	local decal = firstDecal(frame)
	local texture = (decal and decal.Texture ~= "" and decal.Texture) or mesh.TextureId
	return mesh.MeshId, texture
end

-- Frames under the folder sorted by numeric name; preloaded whenever the count changes.
function MeshFrames.readFrames(folder)
	local frames = {}
	if not folder then return frames end
	for _, child in ipairs(folder:GetChildren()) do
		if isFrame(child) then table.insert(frames, child) end
	end
	table.sort(frames, function(a, b)
		return (tonumber(a.Name) or 0) < (tonumber(b.Name) or 0)
	end)
	if #frames > 0 and preloadedCount[folder] ~= #frames then
		preloadedCount[folder] = #frames
		task.spawn(function()
			pcall(function() ContentProvider:PreloadAsync(frames) end)
		end)
	end
	return frames
end

-- GetData hook.
function MeshFrames.readInto(data, item, config)
	data.MeshFrames = MeshFrames.readFrames(item:FindFirstChild("MeshFrames"))
	data.MeshFrameMeshIds = {}
	data.MeshFrameTextures = {}
	data.MeshFramesTextured = false
	for index, frame in ipairs(data.MeshFrames) do
		local meshId, texture = frameIds(frame)
		data.MeshFrameMeshIds[index] = meshId
		data.MeshFrameTextures[index] = texture
		if texture ~= "" then data.MeshFramesTextured = true end
	end
	local mode = config:GetAttribute("MeshFrameMode")
	if typeof(mode) == "EnumItem" then mode = mode.Name end
	data.MeshFrameMode = MODES[mode] and mode or "None"
	data.MeshFrameFramerate = config:GetAttribute("MeshFrameFramerate") or NumberRange.new(24)
	data.MeshFrameStartRandom = config:GetAttribute("MeshFrameStartRandom") == true
	data.MeshFrameReverse = config:GetAttribute("MeshFrameReverse") == true
end

local function isActive(data)
	return data.MeshFrames ~= nil and #data.MeshFrames > 0 and data.MeshFrameMode ~= "None"
end

local function buildState(data, visualPart)
	local framerate = RangeMod.RandomValueFromRange(data.MeshFrameFramerate)
	local state = MeshFlipMod.layerState(visualPart, data.MeshFrames, data.MeshFrameMode, framerate,
		data.MeshFrameStartRandom, data.MeshFrameReverse)
	state.meshIds = data.MeshFrameMeshIds
	state.textures = data.MeshFrameTextures
	return state
end

-- Where the SpecialMesh route writes the frame texture: the first decal, else the mesh itself.
local function textureSlot(visualPart, specialMesh)
	local decal = firstDecal(visualPart)
	if decal then return decal, "Texture" end
	return specialMesh, "TextureId"
end

local function applyFrame(state, visual, index)
	pcall(function()
		if state.specialMesh then
			state.specialMesh.MeshId = state.meshIds[index]
			local texture = state.textures[index]
			if texture ~= "" then state.textureTarget[state.textureProp] = texture end
			return
		end
		local frame = state.frames[index]
		local currentTexture = visual.TextureID
		visual:ApplyMesh(frame)
		if frame.TextureID == "" and currentTexture ~= "" then visual.TextureID = currentTexture end
	end)
end

-- Steps the sequence until the particle is reclaimed (or, for clones, the wall-clock cap).
local function runTask(pData, state, lifetime, liveSource)
	local startTime = os.clock()
	task.spawn(function()
		while not state.stopped do
			local visual = pData.VisualPart
			if not visual or not visual.Parent then break end
			if pData._nestedAlive and not pData._nestedAlive[1] then break end
			if not liveSource and os.clock() - startTime > lifetime * 4 then break end
			local elapsed = pData._effectiveElapsed or (os.clock() - startTime)
			local frameIndex = MeshFlipMod.frameIndex(state, elapsed, pData.LifeTime or lifetime)
			if frameIndex ~= state.lastFrame then
				state.lastFrame = frameIndex
				applyFrame(state, visual, frameIndex)
			end
			task.wait()
		end
		if state.stopped or liveSource or state.mode == "Loop" or state.mode == "PingPong" then return end
		local visual = pData.VisualPart
		if visual and visual.Parent then applyFrame(state, visual, MeshFlipMod.finalFrame(state)) end
	end)
end

-- A pooled clone may still carry the previous emit's last frame: put the template's mesh back.
local function resetToTemplate(visualPart, specialMesh, rt)
	if not rt then return end
	if specialMesh then
		local rtMesh = rt:FindFirstChildOfClass("SpecialMesh")
		if rtMesh and specialMesh.MeshId ~= rtMesh.MeshId then pcall(function() specialMesh.MeshId = rtMesh.MeshId end) end
	elseif rt:IsA("MeshPart") and visualPart.MeshId ~= rt.MeshId then
		pcall(function() visualPart:ApplyMesh(rt) end)
	end
end

-- Bind the sequence to the visual: show the start frame now, then step it on the particle's clock.
-- liveSource = Animate on the RT itself: keep a backup for restore() and never time-cap the task.
function MeshFrames.attach(pData, data, visualPart, lifetime, liveSource)
	pData.MeshFrames = nil
	local active = isActive(data)
	local specialMesh = (not visualPart:IsA("MeshPart")) and visualPart:FindFirstChildOfClass("SpecialMesh") or nil
	if not visualPart:IsA("MeshPart") and not specialMesh then
		if active and not warnedUnsupported then
			warnedUnsupported = true
			Log.warn(("[Part-Icles] Mesh Frames need a MeshPart or a Part with a SpecialMesh as RenderTemplate; %s is a %s."):format(
				visualPart:GetFullName(), visualPart.ClassName))
		end
		return
	end
	if not active then
		if not liveSource then resetToTemplate(visualPart, specialMesh, data.RenderTemplate) end
		return
	end
	local state = buildState(data, visualPart)
	if specialMesh then
		state.specialMesh = specialMesh
		state.textureTarget, state.textureProp = textureSlot(visualPart, specialMesh)
	end
	if liveSource then
		if specialMesh then
			state.backup = { meshId = specialMesh.MeshId, texture = state.textureTarget[state.textureProp] }
		else
			local backup = visualPart:Clone()
			for _, child in ipairs(backup:GetChildren()) do child:Destroy() end
			backup.Name = "_MeshFrameBackup"
			backup.Archivable = false
			backup.Parent = VisualHost.getPoolFolder()
			state.backup = backup
		end
	end
	pData.MeshFrames = state
	runTask(pData, state, lifetime, liveSource)
end

-- Animate finish / cancel: stop stepping and put the RT's own mesh (and texture) back.
function MeshFrames.restore(pData)
	local state = pData.MeshFrames
	if not state then return end
	state.stopped = true
	local backup = state.backup
	if not backup then return end
	state.backup = nil
	local visual = pData.VisualPart
	if state.specialMesh then
		pcall(function()
			state.specialMesh.MeshId = backup.meshId
			state.textureTarget[state.textureProp] = backup.texture
		end)
		return
	end
	if visual and visual.Parent then pcall(function() visual:ApplyMesh(backup) end) end
	pcall(function() backup:Destroy() end)
end

-- AnimateLoop cycle: re-read the settings and frames for the next cycle.
function MeshFrames.refresh(pData, freshData)
	local state = pData.MeshFrames
	if not state or not freshData or not isActive(freshData) then return end
	local fresh = buildState(freshData, state.target)
	state.frames, state.n, state.mode = fresh.frames, fresh.n, fresh.mode
	state.meshIds, state.textures = fresh.meshIds, fresh.textures
	state.frameDelay, state.startOffset, state.reverse = fresh.frameDelay, fresh.startOffset, fresh.reverse
	state.lastFrame = -1
end

return MeshFrames
