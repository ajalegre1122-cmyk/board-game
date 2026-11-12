-- Flipbook  -  texture cycling for Part meshes, Beams, and ImageLabels.
-- Reads numbered Decal/Texture children from a Flipbooks folder, sorted by name.
-- frameIndex / finalFrame are the one frame clock shared with MeshFrames (mesh sequences).

local ContentProvider = game:GetService("ContentProvider")
local RangeMod = require(script.Parent.Range)
local Log = require(script.Parent.Log)
local MeshFlipbook = {}

-- Read + sort once at emit time, cache in data.CachedMeshTextures. Stray non-Decal/Texture children skipped.
function MeshFlipbook.GetSortedTextures(flipbookFolder: Folder): {string}
	local decalObjects = {}
	for _, child in pairs(flipbookFolder:GetChildren()) do
		if child:IsA("Decal") or child:IsA("Texture") then
			table.insert(decalObjects, child)
		end
	end
	if #decalObjects == 0 then return {} end

	table.sort(decalObjects, function(a, b)
		return (tonumber(a.Name) or 0) < (tonumber(b.Name) or 0)
	end)

	local textures = {}
	for _, obj in ipairs(decalObjects) do
		table.insert(textures, obj.Texture)
	end

	-- Preload textures so frame swaps are instant.
	if #textures > 0 then
		task.spawn(function()
			ContentProvider:PreloadAsync(textures)
		end)
	end

	return textures
end

-- Same as GetSortedTextures but Decal-only (Beam flipbook folders).
function MeshFlipbook.GetSortedBeamTextures(flipbookFolder: Folder): {string}
	local decalObjects = {}
	for _, child in pairs(flipbookFolder:GetChildren()) do
		if child:IsA("Decal") then
			table.insert(decalObjects, child)
		end
	end
	if #decalObjects == 0 then return {} end

	table.sort(decalObjects, function(a, b)
		return (tonumber(a.Name) or 0) < (tonumber(b.Name) or 0)
	end)

	local textures = {}
	for _, obj in ipairs(decalObjects) do
		table.insert(textures, obj.Texture)
	end

	if #textures > 0 then
		task.spawn(function()
			ContentProvider:PreloadAsync(textures)
		end)
	end

	return textures
end

-- One-time warn for SurfaceAppearance.ColorMap write fails (PluginSecurity in runtime).
local _surfaceColorMapWarned = false
local function _writeFrame(target, prop, value)
	local ok, err = pcall(function() target[prop] = value end)
	if not ok and prop == "ColorMap" and not _surfaceColorMapWarned then
		_surfaceColorMapWarned = true
		Log.warn(("[Part-Icles] SurfaceAppearance flipbook ColorMap write failed (%s). " ..
			"ColorMap is PluginSecurity  -  SurfaceAppearance flipbooks only animate in plugin context. " ..
			"For runtime games, use Decal / Texture flipbooks instead."):format(tostring(err)))
	end
end

-- SurfaceAppearance writes to ColorMap; MeshPart writes to TextureID;
-- Decal/Texture/Beam write to Texture.
local function _texProp(target)
	if target and target:IsA("SurfaceAppearance") then return "ColorMap" end
	if target and target:IsA("MeshPart") then return "TextureID" end
	return "Texture"
end

-- Playback state for one target. mode: "Loop" / "PingPong" / anything else = OneShot (an
-- EnumItem is accepted). framerate clamps to 0.1 so 0 can't divide.
function MeshFlipbook.layerState(target, frames, mode, framerate, startRandom, reverse)
	if typeof(mode) == "EnumItem" then mode = mode.Name end
	if not framerate or framerate < 0.1 then framerate = 0.1 end
	local n = #frames
	return {
		target = target, frames = frames, n = n, mode = mode,
		frameDelay = 1 / framerate,
		startOffset = startRandom and math.random(0, n - 1) or 0,
		reverse = reverse == true,
		lastFrame = -1,
	}
end

-- Frame shown at `elapsed` seconds. Loop cycles at the framerate, PingPong runs forward then
-- back at the framerate, OneShot spreads the sequence once over `lifetime`. startOffset and
-- reverse apply on top.
function MeshFlipbook.frameIndex(state, elapsed, lifetime)
	local n = state.n
	local frameIndex
	if state.mode == "Loop" then
		frameIndex = (math.floor(elapsed / state.frameDelay) + state.startOffset) % n + 1
	elseif state.mode == "PingPong" and n > 1 then
		local period = 2 * n - 2
		local k = (math.floor(elapsed / state.frameDelay) + state.startOffset) % period
		if k >= n then k = period - k end
		frameIndex = k + 1
	else
		frameIndex = math.min(math.floor(elapsed / math.max(lifetime, 0.001) * n) + 1, n)
		frameIndex = (frameIndex - 1 + state.startOffset) % n + 1
	end
	if state.reverse then frameIndex = n - frameIndex + 1 end
	return frameIndex
end

-- The frame a OneShot sequence must end on.
function MeshFlipbook.finalFrame(state)
	local n = state.n
	local frameIndex = (n - 1 + state.startOffset) % n + 1
	if state.reverse then frameIndex = n - frameIndex + 1 end
	return frameIndex
end

local function _isOneShot(state)
	return state.mode ~= "Loop" and state.mode ~= "PingPong"
end

-- One task cycling `target` off pData._effectiveElapsed so Timescale, FreezeTime, Pause and
-- signed-reverse all affect playback. Wall-clock cap is the safety exit; primary teardown is
-- the Heartbeat destroying the visual. OneShot lands on its final frame before death.
local function _run(pData, particle, decals, target, lifetime, mode)
	if #decals == 0 then return end
	local framerate = RangeMod.RandomValueFromRange(particle.FlipbookFramerate)
	local state = MeshFlipbook.layerState(target, decals, mode, framerate, particle.FlipbookStartRandom, particle.FlipbookReverse)
	local startTime = os.clock()
	local prop = _texProp(target)

	task.spawn(function()
		while os.clock() - startTime < lifetime * 4 do
			if not target or not target.Parent then return end
			if pData and (not pData.VisualPart or not pData.VisualPart.Parent) then break end
			local elapsed = (pData and pData._effectiveElapsed) or (os.clock() - startTime)
			local frameIndex = MeshFlipbook.frameIndex(state, elapsed, lifetime)
			if frameIndex ~= state.lastFrame then
				_writeFrame(target, prop, decals[frameIndex])
				state.lastFrame = frameIndex
			end
			task.wait()
		end
		if _isOneShot(state) and target and target.Parent then
			_writeFrame(target, prop, decals[MeshFlipbook.finalFrame(state)])
		end
	end)
end

local function _playable(mode)
	return mode == Enum.ParticleFlipbookMode.Loop or mode == Enum.ParticleFlipbookMode.OneShot
		or mode == Enum.ParticleFlipbookMode.PingPong
end

-- Target is Decal (Texture) or SurfaceAppearance (ColorMap); _texProp picks the slot.
-- pData is required for Timescale/FreezeTime/Pause/reverse-Timescale-aware frame indexing;
-- nil pData falls back to wall-clock elapsed for backwards compat.
function MeshFlipbook.Flip(pData, particle, decals: {string}, target, lifetime)
	if not particle or not _playable(particle.FlipbookMode) then return end
	_run(pData, particle, decals, target, lifetime, particle.FlipbookMode.Name)
end

-- Every flipbook set under a MeshFlipbooks folder: sub-folders keyed by name, numbered frames
-- directly in the folder under "" (the legacy single flipbook).
function MeshFlipbook.GetFlipbookSets(folder: Folder)
	local sets = {}
	local flat = MeshFlipbook.GetSortedTextures(folder)
	if #flat > 0 then sets[""] = flat end
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Folder") then
			local textures = MeshFlipbook.GetSortedTextures(child)
			if #textures > 0 then sets[child.Name] = textures end
		end
	end
	return sets
end

-- One task per particle steps every layer's flipbook off pData._effectiveElapsed;
-- OneShot layers land on their final frame when the loop ends.
function MeshFlipbook.FlipLayers(pData, layers, lifetime)
	local active = {}
	for _, layer in ipairs(layers) do
		if layer.flip then table.insert(active, layer.flip) end
	end
	if #active == 0 then return end
	local startTime = os.clock()
	task.spawn(function()
		while os.clock() - startTime < lifetime * 4 do
			if not pData.VisualPart or not pData.VisualPart.Parent then return end
			local elapsed = pData._effectiveElapsed or (os.clock() - startTime)
			for i = 1, #active do
				local state = active[i]
				if state.target.Parent then
					local frameIndex = MeshFlipbook.frameIndex(state, elapsed, lifetime)
					if frameIndex ~= state.lastFrame then
						_writeFrame(state.target, "Texture", state.frames[frameIndex])
						state.lastFrame = frameIndex
					end
				end
			end
			task.wait()
		end
		for i = 1, #active do
			local state = active[i]
			if _isOneShot(state) and state.target.Parent then
				_writeFrame(state.target, "Texture", state.frames[MeshFlipbook.finalFrame(state)])
			end
		end
	end)
end

function MeshFlipbook.FlipBeam(pData, flipbookParticle, decals: {string}, beam, lifetime)
	if not flipbookParticle or not decals or not _playable(flipbookParticle.FlipbookMode) then return end
	_run(pData, flipbookParticle, decals, beam, lifetime, flipbookParticle.FlipbookMode.Name)
end

return MeshFlipbook
