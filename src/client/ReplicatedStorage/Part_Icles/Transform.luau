--[[
	Transform Mixin  -  converts an Instance into a Part-Icles emitter.
	:Transform stamps attributes, creates PartIcleProperties Configuration + RenderTemplate,
	hides the source. PreSimulateForward / PreSimulateAttachmentForward live in PreSimulate.luau.
]]

local TypeRegistry = require(script.Parent.TypeRegistry)
local Constants = require(script.Parent.PartConstants)

return function(Particle)

-- TransformCompleted fires after Transform/TransformModel/transformDirectAccess; lazy create.
if not Particle.TransformCompleted then
	Particle.TransformCompleted = Instance.new("BindableEvent")
end

-- True when `inst` is `holder` or sits inside it.
local function isWithin(inst, holder)
	return inst == holder or inst:IsDescendantOf(holder)
end

-- Children a holder carries into its RenderTemplate so every emitted copy has them: native
-- emitters, lights, attachments and already transformed emitters. A Beam or Trail qualifies
-- only when both of its attachments sit inside the holder; one tied to another part stays put.
local function isNestedContent(child, holder)
	if child:GetAttribute("Transformed") or child:IsA("Attachment") then return true end
	if child:IsA("ParticleEmitter") or child:IsA("Light") then return true end
	if child:IsA("Beam") or child:IsA("Trail") then
		local attachment0 = child.Attachment0
		local attachment1 = child.Attachment1
		return (attachment0 == nil or isWithin(attachment0, holder)) and (attachment1 == nil or isWithin(attachment1, holder))
	end
	return false
end

-- Children a transformed Model owns itself; everything else belongs in its RenderTemplate.
local MODEL_INTERNALS = { EmitParent = true, Link = true, AccelTarget = true }
MODEL_INTERNALS[TypeRegistry.CONFIG_NAME] = true

-- Main dispatch. Plain directAccess Trail/Beam are promote-eligible: Transform stamps
-- PartIcleProperties + RenderTemplate so the item flips classCheck to TrailEmitter / Beam.
function Particle:Transform(part)
	if part:GetAttribute("Transformed") then return end
	local typeDef = TypeRegistry.getTypeFor(part)
	if not typeDef then
		-- Lightning / CameraShake dead zone: the discriminator attr is stamped BEFORE
		-- Transform runs, but both classChecks also require the config child (created
		-- below), so no type matches yet. Resolve explicitly.
		if part:IsA("BasePart") and part:GetAttribute("IsLightning") and TypeRegistry.Types.Lightning then
			typeDef = TypeRegistry.Types.Lightning
		elseif part:IsA("BasePart") and part:GetAttribute("IsCameraShake") and TypeRegistry.Types.CameraShake then
			typeDef = TypeRegistry.Types.CameraShake
		elseif part:IsA("BasePart") and part:GetAttribute("IsRocks") and TypeRegistry.Types.Rocks then
			typeDef = TypeRegistry.Types.Rocks
		elseif part:IsA("BasePart") and part:GetAttribute("IsRope") and TypeRegistry.Types.Rope then
			typeDef = TypeRegistry.Types.Rope
		elseif part:IsA("BasePart") and part:GetAttribute("IsDistortion") and TypeRegistry.Types.Distortion then
			typeDef = TypeRegistry.Types.Distortion
		else
			return
		end
	end
	local isLightning = typeDef == TypeRegistry.Types.Lightning
	local isCameraShake = typeDef == TypeRegistry.Types.CameraShake
	local isRocks = typeDef == TypeRegistry.Types.Rocks
	local isRope = typeDef == TypeRegistry.Types.Rope
	local isDistortion = typeDef == TypeRegistry.Types.Distortion

	-- Promoting a directAccess type: swap to the emitter typeDef before createConfig so the
	-- Configuration child carries TrailEmitter / Beam property defaults (not the directAccess shape).
	if typeDef.directAccess then
		if part:IsA("Trail") and TypeRegistry.Types.TrailEmitter then
			typeDef = TypeRegistry.Types.TrailEmitter
		elseif part:IsA("Beam") and TypeRegistry.Types.Beam then
			typeDef = TypeRegistry.Types.Beam
		else
			return
		end
	end

	if part:IsA("Model") then
		-- PrimaryPart not required. Model:GetPivot / PivotTo / ScaleTo work via the
		-- computed WorldPivot when PrimaryPart is unset.
		return self:TransformModel(part, typeDef)
	end

	local config = TypeRegistry.createConfig(part, typeDef)

	-- A Part (plain or rig) or an Attachment is a holder: its nested content is set aside for
	-- the clone and then parented into the RenderTemplate, so each emitted copy carries it and
	-- none is left on the source. CameraShake and Distortion emit no clone (nothing under their
	-- RenderTemplate ever fires), so their children stay on the source.
	local emitsNoClone = isCameraShake or isDistortion
	local nested = {}
	if (part:IsA("BasePart") and not emitsNoClone) or part:IsA("Attachment") then
		for _, child in ipairs(part:GetChildren()) do
			if isNestedContent(child, part) then table.insert(nested, child) end
		end
		for _, child in ipairs(nested) do
			child.Parent = nil
		end
	end

	local renderTemplate = part:Clone()
	renderTemplate.Name = "RenderTemplate"

	for _, child in renderTemplate:GetChildren() do
		if child:GetAttribute("Transformed") or child:IsA("Attachment") then continue end
		if child.Name == TypeRegistry.CONFIG_NAME or child.Name == "EmitParent" or child.Name == "Link" or child.Name == "AccelTarget" or child.Name == "Target" or child.Name == "ImageFlipbooks" then
			child:Destroy()
		elseif part:IsA("Light") or part:IsA("Highlight") or part:IsA("Sound") then
			child:Destroy()
		elseif part:IsA("Attachment") then
			-- Strip plugin internals; keep authored Trails/Beams/Decals.
			if child.Name == "MeshFlipbooks" or child.Name == "BeamFlipbooks" or child.Name == "GraphBlender" then
				child:Destroy()
			end
		elseif part:IsA("ImageLabel") then
			-- Keep UIComponent decorators (UIGradient/UICorner/UIStroke/UIPadding).
			if not child:IsA("UIComponent") then child:Destroy() end
		elseif not child:IsA("SpecialMesh") and not child:IsA("Decal") and not child:IsA("Texture") and not child:IsA("SurfaceAppearance") then
			-- SurfaceAppearance must survive; Emit reads it via FindFirstChildOfClass.
			child:Destroy()
		end
	end

	for _, child in ipairs(nested) do
		child.Parent = renderTemplate
	end

	-- Strip plugin attributes; preserve user-authored ones.
	for _, attrName in ipairs({"Transformed", "Qwinkle", "IsEmitter", "EmitCount", "EmitDuration", "EmitDelay", "EmissionMode", "AnimateLoop", "PreloadTexture", "LinkMode", "LinkSource"}) do
		renderTemplate:SetAttribute(attrName, nil)
	end

	if renderTemplate:IsA("BasePart") then
		renderTemplate.Anchored = true; renderTemplate.CanCollide = false; renderTemplate.CanQuery = false
		renderTemplate.CanTouch = false; renderTemplate.CastShadow = false; renderTemplate.Massless = true; renderTemplate.Locked = true
		renderTemplate.Transparency = 1
		for _, c in ipairs(renderTemplate:GetChildren()) do
			if c:IsA("Decal") or c:IsA("Texture") then c.Transparency = 1 end
		end
	end

	if renderTemplate:IsA("Attachment") then
		renderTemplate.CFrame = CFrame.new()
	end

	-- Silence native PEs/Trails on the RT (they ignore parent hidden state). Skip Transformed
	-- ones  -  directAccess Trails own .Enabled, and nested transformed PEs have their own lifecycle.
	for _, desc in ipairs(renderTemplate:GetDescendants()) do
		if (desc:IsA("ParticleEmitter") or desc:IsA("Trail"))
			and not desc:GetAttribute("Transformed")
		then desc.Enabled = false end
	end

	renderTemplate.Parent = part

	-- Capture authored visuals so emitter defaults reflect the source's pre-transform state.
	-- Size: SpecialMesh.Scale wins. Color / Transparency come from the part itself; decals keep
	-- their own look through decal layers (DecalLayers = true below).
	-- Read BEFORE the source strip below destroys the SpecialMesh/Decal children.
	if part:IsA("BasePart") and not part:IsA("Terrain") and not isCameraShake and not isDistortion then
		local sizeVec = part.Size
		local meshChild = part:FindFirstChildWhichIsA("SpecialMesh")
		if meshChild then sizeVec = meshChild.Scale end
		local colorVal = part.Color
		local transparencyVal = part.Transparency
		if isLightning or isRope then
			-- Lightning / Rope have no SizeXYZ graphs; segment cross-section comes from Thickness.
			config:SetAttribute("Thickness", NumberSequence.new(math.max(0.05, math.min(part.Size.X, part.Size.Y))))
		elseif not isRocks then
			-- Rocks has no SizeXYZ either; chunk size = RT Size × ChunkScale roll.
			config:SetAttribute("SizeX", NumberSequence.new(sizeVec.X))
			config:SetAttribute("SizeY", NumberSequence.new(sizeVec.Y))
			config:SetAttribute("SizeZ", NumberSequence.new(sizeVec.Z))
			config:SetAttribute("DecalLayers", true)
		end
		config:SetAttribute("Color", ColorSequence.new(colorVal))
		config:SetAttribute("Transparency", NumberSequence.new(transparencyVal))
	end

	-- Hide source: visual children moved to RT.
	if part:IsA("BasePart") then
		for _, child in ipairs(part:GetChildren()) do
			if child ~= renderTemplate and (child:IsA("SpecialMesh") or child:IsA("Decal") or child:IsA("Texture")) then child:Destroy() end
		end
		part.Transparency = 1
		-- Rocks chunks are native physics bodies spawning AT the source  -  a still-
		-- collidable invisible source would depenetrate them explosively.
		if isRocks then part.CanCollide = false end
	elseif part:IsA("Light") then
		part.Enabled = false
	elseif part:IsA("Sound") then
		part:Stop()
		part.Playing = false
	elseif part:IsA("Highlight") then
		part.Enabled = false
	elseif part:IsA("PostProcessEffect") then
		part.Enabled = false
	elseif part:IsA("ImageLabel") then
		part.Visible = false
	end

	if part:IsA("Light") then
		config:SetAttribute("PLRange", NumberSequence.new(part.Range))
		config:SetAttribute("PLBrightness", NumberSequence.new(part.Brightness))
		config:SetAttribute("PLColor", ColorSequence.new(part.Color))
		config:SetAttribute("Shadows", part.Shadows)
		if part:IsA("SpotLight") or part:IsA("SurfaceLight") then
			config:SetAttribute("PLAngle", NumberSequence.new(part.Angle))
			config:SetAttribute("PLFace", part.Face.Name)
		end
	end
	if part:IsA("Sound") then
		config:SetAttribute("SndVolume", NumberSequence.new(part.Volume))
		config:SetAttribute("SndPlaybackSpeed", NumberSequence.new(part.PlaybackSpeed))
		config:SetAttribute("RollOffMin", part.RollOffMinDistance)
		config:SetAttribute("RollOffMax", part.RollOffMaxDistance)
		config:SetAttribute("Looped", part.Looped)
		renderTemplate.Playing = false
	end

	-- Capture authored PostProcessEffect / Atmosphere into config as single-keypoint sequences.
	if part:IsA("BlurEffect") then
		config:SetAttribute("BlurSize", NumberSequence.new(part.Size))
	elseif part:IsA("BloomEffect") then
		config:SetAttribute("BloomIntensity", NumberSequence.new(part.Intensity))
		config:SetAttribute("BloomSize", NumberSequence.new(part.Size))
		config:SetAttribute("BloomThreshold", NumberSequence.new(part.Threshold))
	elseif part:IsA("ColorCorrectionEffect") then
		config:SetAttribute("CCBrightness", NumberSequence.new(part.Brightness))
		config:SetAttribute("CCContrast", NumberSequence.new(part.Contrast))
		config:SetAttribute("CCSaturation", NumberSequence.new(part.Saturation))
		config:SetAttribute("CCTintColor", ColorSequence.new(part.TintColor))
	elseif part:IsA("Atmosphere") then
		config:SetAttribute("AtmDensity", NumberSequence.new(part.Density))
		config:SetAttribute("AtmOffset", NumberSequence.new(part.Offset))
		config:SetAttribute("AtmGlare", NumberSequence.new(part.Glare))
		config:SetAttribute("AtmHaze", NumberSequence.new(part.Haze))
		config:SetAttribute("AtmColor", ColorSequence.new(part.Color))
		config:SetAttribute("AtmDecay", ColorSequence.new(part.Decay))
	elseif part:IsA("Highlight") then
		config:SetAttribute("HLFillColor", ColorSequence.new(part.FillColor))
		config:SetAttribute("HLFillTransparency", NumberSequence.new(part.FillTransparency))
		config:SetAttribute("HLOutlineColor", ColorSequence.new(part.OutlineColor))
		config:SetAttribute("HLOutlineTransparency", NumberSequence.new(part.OutlineTransparency))
		config:SetAttribute("HLDepthMode", part.DepthMode.Name)
		-- Adornee picker child: emit-time _resolveAdornee falls through to source.Adornee then
		-- source.Parent when this ObjectValue is unset. Picker UI binds to the ObjectValue's
		-- Value field  -  required for the user-facing Adornee picker.
		if not part:FindFirstChild("Adornee") then
			local ad = Instance.new("ObjectValue"); ad.Name = "Adornee"; ad.Value = nil; ad.Parent = part
		end
	end

	-- RT must never render live (both source + RT live in Lighting / GUI tree).
	if renderTemplate:IsA("PostProcessEffect") then renderTemplate.Enabled = false end

	if part:IsA("ImageLabel") then
		if renderTemplate:IsA("ImageLabel") then renderTemplate.Visible = false end
		-- Only force BG=1 from the default; preserve user-authored translucent backdrops.
		if part.BackgroundTransparency == 0 then
			part.BackgroundTransparency = 1
		end
		config:SetAttribute("Image", part.Image)
		config:SetAttribute("Position", part.Position)
		config:SetAttribute("ImgSize", part.Size)
		config:SetAttribute("AnchorPoint", part.AnchorPoint)
		config:SetAttribute("ZIndex", part.ZIndex)
		config:SetAttribute("ScaleType", part.ScaleType.Name)
		config:SetAttribute("ResampleMode", part.ResampleMode.Name)
		if not part:FindFirstChild("ImageFlipbooks") then
			local ff = Instance.new("Folder"); ff.Name = "ImageFlipbooks"; ff.Parent = part
		end
	end

	if part:IsA("BasePart") and not part:IsA("Terrain") and not isLightning and not isCameraShake and not isRocks and not isRope and not isDistortion then
		if not part:FindFirstChild("MeshFlipbooks") then
			local mf = Instance.new("Folder"); mf.Name = "MeshFlipbooks"; mf.Parent = part
		end
	end

	-- Trail promote-to-emitter: disable source + RT Trail (RT gets re-Enabled on each emit clone).
	-- The runtime writes the scalar graphs and TrailLife onto every clone each frame
	-- (TrailEmitter SCALAR_GRAPHS), so they are captured from the source Trail here.
	if part:IsA("Trail") then
		part.Enabled = false
		if renderTemplate:IsA("Trail") then renderTemplate.Enabled = false end
		config:SetAttribute("TEmitBrightness", NumberSequence.new(part.Brightness))
		config:SetAttribute("TEmitLightEmission", NumberSequence.new(part.LightEmission))
		config:SetAttribute("TEmitLightInfluence", NumberSequence.new(part.LightInfluence))
		config:SetAttribute("TEmitTextureLength", NumberSequence.new(part.TextureLength))
		config:SetAttribute("TEmitMinLength", NumberSequence.new(part.MinLength))
		config:SetAttribute("TEmitMaxLength", NumberSequence.new(part.MaxLength))
		config:SetAttribute("TEmitTrailLife", NumberRange.new(part.Lifetime))
		-- Default GraphBlender: state 1 seeds from source Trail's current Width / Transparency / Color
		-- so the emit immediately matches the visual the user authored before promoting.
		if not part:FindFirstChild("GraphBlender") then
			local gb = Instance.new("Folder"); gb.Name = "GraphBlender"
			local s1 = Instance.new("Configuration"); s1.Name = "1"
			s1:SetAttribute("Time", 0)
			s1:SetAttribute("Width", part.WidthScale or NumberSequence.new(1))
			s1:SetAttribute("Transparency", part.Transparency or NumberSequence.new(0))
			s1:SetAttribute("Color", part.Color or ColorSequence.new(Color3.new(1,1,1)))
			s1:SetAttribute("_AutoTime", true)
			s1.Parent = gb; gb.Parent = part
		end
		if not part:FindFirstChild("TrailFlipbooks") then
			local tf = Instance.new("Folder"); tf.Name = "TrailFlipbooks"; tf.Parent = part
		end
	end

	if part:IsA("Beam") then
		part.Enabled = false
		part.LightInfluence = 0 -- Unlit default
		if renderTemplate:IsA("Beam") then renderTemplate.Enabled = false; renderTemplate.LightInfluence = 0 end

		if not part:FindFirstChild("BeamFlipbooks") then
			local bf = Instance.new("Folder"); bf.Name = "BeamFlipbooks"; bf.Parent = part
		end

		config:SetAttribute("BeamBrightness", NumberSequence.new(part.Brightness))
		config:SetAttribute("CurveSize0", NumberSequence.new(part.CurveSize0))
		config:SetAttribute("CurveSize1", NumberSequence.new(part.CurveSize1))
		config:SetAttribute("Width0", NumberSequence.new(part.Width0))
		config:SetAttribute("Width1", NumberSequence.new(part.Width1))
		config:SetAttribute("LightEmission", NumberSequence.new(part.LightEmission))
		config:SetAttribute("BeamLightInfluence", NumberSequence.new(0))
		config:SetAttribute("Segments", NumberSequence.new(part.Segments))
		config:SetAttribute("TextureLength", NumberSequence.new(part.TextureLength))
		config:SetAttribute("TextureSpeed", NumberSequence.new(part.TextureSpeed))
		config:SetAttribute("FaceCamera", part.FaceCamera)
		config:SetAttribute("ZOffset", part.ZOffset)
		config:SetAttribute("BeamTextureMode", part.TextureMode.Name)

		-- _AutoTime marks states whose Time was set by Add State (vs user-edited via TimeBox).
		local gb = Instance.new("Folder"); gb.Name = "GraphBlender"
		local s1 = Instance.new("Configuration"); s1.Name = "1"
		s1:SetAttribute("Time", 0); s1:SetAttribute("Transparency", part.Transparency); s1:SetAttribute("Color", part.Color)
		s1:SetAttribute("_AutoTime", true)
		s1.Parent = gb; gb.Parent = part
	end

	if not part:FindFirstChild("EmitParent") then
		local ep = Instance.new("ObjectValue")
		ep.Name = "EmitParent"
		ep.Value = nil
		ep.Parent = part
	end

	if (part:IsA("BasePart") or part:IsA("Attachment")) and not isCameraShake and not isRocks and not isRope and not isDistortion and not part:FindFirstChild("Link") then
		local lk = Instance.new("ObjectValue")
		lk.Name = "Link"
		lk.Parent = part
	end

	if part:IsA("BasePart") and not isLightning and not isCameraShake and not isRocks and not isRope and not isDistortion and not part:FindFirstChild("AccelTarget") then
		local at = Instance.new("ObjectValue")
		at.Name = "AccelTarget"
		at.Value = nil
		at.Parent = part
	end

	-- ShapePart override: when UseShape=true, particles spawn within this BasePart's volume
	-- (using its Size + CFrame). Default Value = source itself so the picker UI shows the
	-- source explicitly; runtime `data.ShapePart or part` fallback handles unset values.
	-- Lightning uses it too (bolt-start scatter volume).
	if part:IsA("BasePart") and not isCameraShake and not isRocks and not isRope and not isDistortion and not part:FindFirstChild("ShapePart") then
		local sp = Instance.new("ObjectValue")
		sp.Name = "ShapePart"
		sp.Value = part
		sp.Parent = part
	end

	-- Lightning Point-mode endpoint / Rope end anchor: arcs from the source to this instance.
	if (isLightning or isRope) and not part:FindFirstChild("Target") then
		local tv = Instance.new("ObjectValue")
		tv.Name = "Target"
		tv.Value = nil
		tv.Parent = part
	end

	part:SetAttribute("Transformed", true)
	part:SetAttribute("Qwinkle", true)
	-- Stable per-emitter id. Clones inherit it, so all clones of one authored emitter
	-- share one EvenDistribution rolling-cycle counter (keyed by this in _evenCycleStore).
	part:SetAttribute("_EvenCycleId", game:GetService("HttpService"):GenerateGUID(false))
	-- Every type starts at one emission per Emit. Mirrored by Migrate's backfill and TransformModel.
	part:SetAttribute("EmitCount", 1)
	part:SetAttribute("EmitDuration", 0)
	part:SetAttribute("EmitDelay", 0)
	part:SetAttribute("IsEmitter", true)
	if part:IsA("BasePart") or part:IsA("Beam") or part:IsA("Trail") or part:IsA("ImageLabel") then
		part:SetAttribute("PreloadTexture", false)
	end
	-- Atmosphere is singleton-per-Lighting; default to Animate to avoid flickering Emit stacks.
	part:SetAttribute("EmissionMode", part:IsA("Atmosphere") and "Animate" or "Emit")
	part:SetAttribute("AnimateLoop", false)
	-- Link-driven types only. Highlight (Adornee-driven) + Trail (Attachment0/1-driven) +
	-- Rope (Target-driven) + CameraShake (no visual) skip these.
	if (part:IsA("BasePart") and not isCameraShake and not isRocks and not isRope and not isDistortion) or part:IsA("Beam") or part:IsA("Attachment") or part:IsA("Model") then
		part:SetAttribute("LinkMode", "Follow")
		part:SetAttribute("LinkSource", "None")
	end
	pcall(function() Particle.TransformCompleted:Fire(part) end)
end

-- PreSimulateForward / PreSimulateAttachmentForward live in PreSimulate.luau (500-line cap split).

-- Model Transform: the Model's own children move into the RenderTemplate (Motor6Ds and
-- AnimationControllers stay intact), so nothing is left beside it.
function Particle:TransformModel(model, typeDef)
	if model:GetAttribute("Transformed") then return end
	TypeRegistry.createConfig(model, typeDef)

	-- The pivot is read first: the PrimaryPart leaves with the children, and the emitter's
	-- origin (model:GetPivot) must not follow the RenderTemplate when Animate moves it.
	local pivot = model:GetPivot()
	local primaryPart = model.PrimaryPart
	local contents = {}
	for _, child in ipairs(model:GetChildren()) do
		if not MODEL_INTERNALS[child.Name] then table.insert(contents, child) end
	end
	for _, child in ipairs(contents) do
		child.Parent = nil
	end

	-- Cloned empty so the RenderTemplate keeps the Model's own properties and scale.
	local renderTemplate = model:Clone()
	renderTemplate.Name = "RenderTemplate"
	for _, child in renderTemplate:GetChildren() do
		child:Destroy()
	end
	for _, child in ipairs(contents) do
		child.Parent = renderTemplate
	end
	renderTemplate.PrimaryPart = primaryPart
	renderTemplate.WorldPivot = pivot
	model.WorldPivot = pivot

	for _, attrName in ipairs({"Transformed", "Qwinkle", "IsEmitter", "EmitCount", "EmitDuration", "EmitDelay", "EmissionMode", "AnimateLoop"}) do
		renderTemplate:SetAttribute(attrName, nil)
	end

	-- Anchor every BasePart; silence native PEs/Trails (they ignore parent hidden state). The
	-- parts stay unlocked: they are the only parts of the Model left to click on in the viewport.
	for _, desc in renderTemplate:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.Anchored = true; desc.CanCollide = false; desc.CanQuery = false
			desc.CanTouch = false; desc.CastShadow = false; desc.Massless = true
		elseif (desc:IsA("ParticleEmitter") or desc:IsA("Trail"))
			and not desc:GetAttribute("Transformed")
		then
			desc.Enabled = false
		end
	end

	renderTemplate.Parent = model

	if not model:FindFirstChild("EmitParent") then
		local ep = Instance.new("ObjectValue")
		ep.Name = "EmitParent"
		ep.Value = nil
		ep.Parent = model
	end

	if not model:FindFirstChild("Link") then
		local lk = Instance.new("ObjectValue")
		lk.Name = "Link"
		lk.Parent = model
	end

	model:SetAttribute("Transformed", true)
	model:SetAttribute("Qwinkle", true)
	model:SetAttribute("EmitCount", 1)
	model:SetAttribute("EmitDuration", 0)
	model:SetAttribute("EmitDelay", 0)
	model:SetAttribute("IsEmitter", true)
	model:SetAttribute("PreloadTexture", false)
	model:SetAttribute("EmissionMode", "Emit")
	model:SetAttribute("AnimateLoop", false)
	model:SetAttribute("LinkMode", "Follow")
	model:SetAttribute("LinkSource", "None")
	pcall(function() Particle.TransformCompleted:Fire(model) end)
end

end
