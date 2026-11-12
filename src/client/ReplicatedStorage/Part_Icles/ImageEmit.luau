-- ImageEmit  -  Emit/Animate/Update for ImageLabel emitters.
-- 2D screen-space motion + flipbook (own Heartbeat branch, Type="ImageLabel").
-- Position = (Speed*direction + envVel) * dt; Acceleration + Drag drive envVel.

local ContentProvider = game:GetService("ContentProvider")
local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local ScreenHost = require(script.Parent.ScreenHost)
local Pool = require(script.Parent.Pool)
local StaticPass = require(script.Parent.StaticPass)
local Log = require(script.Parent.Log)

return function(Particle)

-- Dedup keyed on Image asset ID so a noisy emit (rate=100/s) prints once per session.
local _warnedSheets = {}

-- Parent priority: EmitParent > the parent clone's copy of the source Gui (nested-driven) >
-- nearest _PartIcleEmit ancestor (ImageLabel-in-ImageLabel clone walk) > ScreenHost.
local function resolveImageParent(data, source, emitCtx)
	if data.EmitParent then return data.EmitParent end
	local map = emitCtx and emitCtx._parentCloneMap
	if map and source and source.Parent and map[source.Parent] then return map[source.Parent] end
	if source then
		local cur = source.Parent
		while cur and cur ~= game do
			if cur:GetAttribute("_PartIcleEmit") then return source.Parent end
			cur = cur.Parent
		end
	end
	return ScreenHost.get()
end

-- Sorted Decal children of ImageFlipbooks (numeric name).
local function gatherFlipbookDecals(folder)
	if not folder then return nil end
	local list = {}
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Decal") then table.insert(list, child) end
	end
	table.sort(list, function(a, b)
		local an, bn = tonumber(a.Name), tonumber(b.Name)
		if an and bn then return an < bn end
		return a.Name < b.Name
	end)
	return #list > 0 and list or nil
end

-- Fire-and-forget PreloadAsync; ContentProvider de-dupes.
local function preloadEmitAssets(data, decals)
	local assetList = {}
	if decals then for _, d in ipairs(decals) do table.insert(assetList, d) end end
	if data.Image and data.Image ~= "" then table.insert(assetList, data.Image) end
	if #assetList == 0 then return end
	task.spawn(function() pcall(ContentProvider.PreloadAsync, ContentProvider, assetList) end)
end

-- Yielding PreloadAsync on first emit per RT. Memoized on Particle._preloadedAssets
-- so subsequent emits of the same source skip the yield.
local function preloadAndWait(particle, rt, data, decals)
	if not particle or not rt then return end
	local cache = particle._preloadedAssets
	if not cache then return end
	if cache[rt] then return end
	local assetList = {}
	if decals then for _, d in ipairs(decals) do table.insert(assetList, d) end end
	if data.Image and data.Image ~= "" then table.insert(assetList, data.Image) end
	cache[rt] = true  -- mark before yield so concurrent emits don't double-wait
	if #assetList == 0 then return end
	pcall(ContentProvider.PreloadAsync, ContentProvider, assetList)
end

-- Frame index per FlipbookMode. OneShot/PingPong scale across Lifetime; Loop uses framerate;
-- Random picks one per interval (per-pData state). StartRandom only affects Loop.
local function resolveFrame(pData, n, elapsed)
	if n <= 0 then return 0 end
	local mode = pData.FlipbookMode
	local frame
	if mode == Enum.ParticleFlipbookMode.OneShot then
		local t = pData.LifeTime > 0 and math.min(1, elapsed / pData.LifeTime) or 1
		frame = math.min(math.floor(t * n), n - 1)
	elseif mode == Enum.ParticleFlipbookMode.PingPong then
		local t = pData.LifeTime > 0 and math.min(1, elapsed / pData.LifeTime) or 1
		local cyc = t * 2
		if cyc <= 1 then frame = math.floor(cyc * n) else frame = math.floor((2 - cyc) * n) end
		frame = math.max(0, math.min(frame, n - 1))
	elseif mode == Enum.ParticleFlipbookMode.Random then
		local fr = pData.FlipbookFramerate or 24
		local interval = (fr > 0) and (1 / fr) or 1
		local intervalIdx = math.floor(elapsed / interval)
		if pData._lastRandomInterval ~= intervalIdx then
			pData._lastRandomInterval = intervalIdx
			pData._currentRandomFrame = math.random(0, n - 1)
		end
		frame = pData._currentRandomFrame or math.random(0, n - 1)
	else -- Loop (default)
		local raw = elapsed * pData.FlipbookFramerate + (pData.FlipbookStartOffset or 0) * n
		frame = math.floor(raw) % n
	end
	if pData.FlipbookReverse then frame = n - 1 - frame end
	return frame
end

-- Decals: swap .Image; Spritesheet: shift ImageRectOffset across a grid.
-- lastFrame dedup: skip the property write when frame index hasn't changed.
local function applyFlipbookFrame(pData, elapsed)
	if not pData.FlipbookFramerate or pData.FlipbookFramerate <= 0 then return end
	if pData.FlipbookSource == "Decals" and pData.FlipbookDecals then
		local n = #pData.FlipbookDecals
		if n == 0 then return end
		local frame = resolveFrame(pData, n, elapsed)
		if frame == pData._lastFlipbookFrame then return end
		pData._lastFlipbookFrame = frame
		local dec = pData.FlipbookDecals[frame + 1]
		if dec and dec.Texture then pData.VisualPart.Image = dec.Texture end
	elseif pData.FlipbookSource == "Spritesheet" then
		local cols = math.max(1, pData.GridCols or 1)
		local rows = math.max(1, pData.GridRows or 1)
		local total = cols * rows
		local frame = resolveFrame(pData, total, elapsed)
		local sheet = pData.SheetSize
		if not sheet then return end
		if frame == pData._lastFlipbookFrame then return end
		pData._lastFlipbookFrame = frame
		local fw, fh = sheet.X / cols, sheet.Y / rows
		pData.VisualPart.ImageRectSize = Vector2.new(fw, fh)
		pData.VisualPart.ImageRectOffset = Vector2.new((frame % cols) * fw, math.floor(frame / cols) * fh)
	end
end

-- Forward-integrate 2D motion over Lifetime and return final (endX, endY, endVelX,
-- endVelY). Mirrors UpdateImageLabel's per-frame math (Speed graph × 100 + Accel
-- × 100 + Drag decay), at coarse 60-step granularity. Used to seed InvertMotion's
-- spawn pose: position = end-pos, EnvVel = end-vel. Negative-dt integration then
-- retraces the forward trajectory exactly (accel-driven motion only reverses
-- correctly when starting EnvVel is the forward end-state, not zero).
local function _simulateForward2D(data, dirX, dirY, lifetime, seeds)
	local steps = 60
	local stepDt = lifetime / steps
	local accelX = (data.ImgAcceleration or Vector2.new()).X
	local accelY = (data.ImgAcceleration or Vector2.new()).Y
	local drag = data.ImgDrag or 0
	local posX, posY = 0, 0
	local envX, envY = 0, 0
	for s = 1, steps do
		local t = s / steps
		local speed = 0
		if data.ImgSpeed then
			speed = GraphMod.QueryPointsWithTime(t, data.ImgSpeed, seeds.ImgSpeed) * 100
		end
		envX += accelX * 100 * stepDt
		envY += accelY * 100 * stepDt
		if drag > 0 then
			local decay = math.max(0, 1 - drag * stepDt)
			envX *= decay; envY *= decay
		end
		posX += (speed * dirX + envX) * stepDt
		posY += (speed * dirY + envY) * stepDt
	end
	return posX, posY, envX, envY
end

-- Expose so Engine.luau's AnimateLoop replay can re-seed end-state per cycle.
Particle._computeImageLabelEndState = function(_self, data, dirX, dirY, lifetime, seeds)
	return _simulateForward2D(data, dirX, dirY, lifetime, seeds)
end

-- Build pData from data; shared by Emit + Animate.
local function buildImageLabelPData(data, visual, item, isAnimate)
	-- One walk + sort of ImageFlipbooks per emit; reused by frame-0 setup + pData stamp.
	local flipbookDecals = gatherFlipbookDecals(data.ImageFlipbooks)
	-- EmissionAngle: 0=right, 90=up, 180=left, 270=down. GUI Y is inverted.
	local ea = data.ImgEmissionAngle or 90
	local sp = data.ImgSpreadAngle or 0
	local angle = ea + (math.random() * 2 - 1) * sp
	local rad = math.rad(angle)
	local dx, dy = math.cos(rad), -math.sin(rad)
	-- InvertMotion: spawn at trajectory's END position + flip dt sign per frame so
	-- motion retraces backward to the original start. Don't flip dx/dy  -  velocity
	-- direction stays forward; the dt sign is what reverses traversal.

	local safeLife = RangeMod.RandomValueFromRange(data.Lifetime)
	if safeLife <= 0 then safeLife = 0.001 end

	local seeds = {
		ImageTransparency      = data.ImageTransparency and GraphMod.GenerateSeed(data.ImageTransparency) or {},
		BackgroundTransparency = data.BackgroundTransparency and GraphMod.GenerateSeed(data.BackgroundTransparency) or {},
		ImgSpeed               = data.ImgSpeed and GraphMod.GenerateSeed(data.ImgSpeed) or {},
		ImgRotSpeed            = data.ImgRotSpeed and GraphMod.GenerateSeed(data.ImgRotSpeed) or {},
		SizeScaleX             = data.SizeScaleX and GraphMod.GenerateSeed(data.SizeScaleX) or {},
		SizeScaleY             = data.SizeScaleY and GraphMod.GenerateSeed(data.SizeScaleY) or {},
		Timescale              = data.ImgTimescale and GraphMod.GenerateSeed(data.ImgTimescale) or {},
	}

	local initialRot = RangeMod.RandomValueFromRange(data.ImgRotRange or NumberRange.new(0))
	local baseSize = data.ImgSizeUDim or UDim2.fromOffset(100, 100)

	-- Frame 0 sample to avoid pop.
	if data.ImageTransparency then visual.ImageTransparency = GraphMod.QueryPointsWithTime(0, data.ImageTransparency, seeds.ImageTransparency) end
	if data.BackgroundTransparency then visual.BackgroundTransparency = GraphMod.QueryPointsWithTime(0, data.BackgroundTransparency, seeds.BackgroundTransparency) end
	if data.ImageColor3 then visual.ImageColor3 = GraphMod.QueryColorPointWithTime(0, data.ImageColor3) end
	if data.BackgroundColor3 then visual.BackgroundColor3 = GraphMod.QueryColorPointWithTime(0, data.BackgroundColor3) end
	visual.Image = data.Image or ""
	visual.ScaleType = data.ImgScaleType or Enum.ScaleType.Stretch
	visual.ResampleMode = data.ImgResampleMode or Enum.ResamplerMode.Default
	visual.AnchorPoint = data.ImgAnchorPoint or Vector2.new(0.5, 0.5)
	visual.ZIndex = data.ImgZIndex or 1
	visual.Rotation = initialRot
	local sx0 = data.SizeScaleX and GraphMod.QueryPointsWithTime(0, data.SizeScaleX, seeds.SizeScaleX) or 1
	local sy0 = data.SizeScaleY and GraphMod.QueryPointsWithTime(0, data.SizeScaleY, seeds.SizeScaleY) or 1
	visual.Size = UDim2.new(baseSize.X.Scale * sx0, baseSize.X.Offset * sx0, baseSize.Y.Scale * sy0, baseSize.Y.Offset * sy0)
	visual.Position = data.ImgPosition or UDim2.fromScale(0.5, 0.5)

	local framerate = 10
	if data.ImgFlipbookFramerate then framerate = RangeMod.RandomValueFromRange(data.ImgFlipbookFramerate) end

	-- StartRandom is Loop-only (resolveFrame ignores FlipbookStartOffset for
	-- OneShot / PingPong / Random). One shared start frame for visual setup +
	-- Loop runtime offset so the first Heartbeat doesn't snap to a different frame.
	local mode = data.ImgFlipbookMode or Enum.ParticleFlipbookMode.Loop
	local applyStartRandom = data.ImgFlipbookStartRandom and mode == Enum.ParticleFlipbookMode.Loop
	local startFrame = 0
	local startFrameOffset = 0

	-- Sheet size missing → whole-sheet render. Decals mode ignores SheetSize.
	local sheetSize = data.SheetSize

	-- Frame-0 flipbook setup so first tick isn't stuck on base Image.
	local source = data.ImgFlipbookSource or "Decals"
	-- Spritesheet mode silently no-ops both crop paths when SheetSize is nil (HTTP fetchAndStamp
	-- pending, denied, or worker 404). Warn once per asset so user gets an actionable diagnostic
	-- instead of staring at a full-sheet emit.
	if source == "Spritesheet" and not sheetSize and data.Image and data.Image ~= "" and not _warnedSheets[data.Image] then
		_warnedSheets[data.Image] = true
		Log.warn(string.format("Part-Icles: Spritesheet flipbook  -  sheet dimensions unknown for %s. Emit will render full sheet until dimensions resolve.", data.Image))
	end
	if source == "Decals" then
		-- Reset lingering Spritesheet crop.
		visual.ImageRectSize = Vector2.new(0, 0); visual.ImageRectOffset = Vector2.new(0, 0)
		if flipbookDecals and #flipbookDecals > 0 then
			local n = #flipbookDecals
			if applyStartRandom then
				startFrame = math.random(0, n - 1)
				startFrameOffset = startFrame / n
			end
			local dec = flipbookDecals[startFrame + 1]
			if dec and dec.Texture and dec.Texture ~= "" then visual.Image = dec.Texture end
		end
	elseif source == "Spritesheet" and sheetSize then
		local cols = math.max(1, data.ImgGridCols or 1)
		local rows = math.max(1, data.ImgGridRows or 1)
		local total = cols * rows
		if applyStartRandom and total > 0 then
			startFrame = math.random(0, total - 1)
			startFrameOffset = startFrame / total
		end
		local fw, fh = sheetSize.X / cols, sheetSize.Y / rows
		visual.ImageRectSize = Vector2.new(fw, fh)
		visual.ImageRectOffset = Vector2.new((startFrame % cols) * fw, math.floor(startFrame / cols) * fh)
	end

	local pData = {
		Type = "ImageLabel",
		VisualPart = visual,
		StartTime = os.clock(),
		LifeTime = safeLife,
		TotalKeyFrames = math.max(1, data.TotalKeyFrames or 100),
		CurrentStep = 0,
		PartLife = data.PartLife or 0,

		BasePosition = data.ImgPosition or UDim2.fromScale(0.5, 0.5),
		BaseSize = baseSize,
		DirX = dx, DirY = dy,
		EnvVelX = 0, EnvVelY = 0,
		PosX = 0,  PosY = 0,
		AccelX = (data.ImgAcceleration or Vector2.new()).X,
		AccelY = (data.ImgAcceleration or Vector2.new()).Y,
		Drag = data.ImgDrag or 0,

		InitialRotation = initialRot,
		RotMode = data.ImgRotMode or "OverLife",
		AccRot = 0,
		InvertMotion = data.ImgInvertMotion or false,

		Graphs = {
			ImageTransparency      = data.ImageTransparency,
			BackgroundTransparency = data.BackgroundTransparency,
			ImgSpeed               = data.ImgSpeed,
			ImgRotSpeed            = data.ImgRotSpeed,
			SizeScaleX             = data.SizeScaleX,
			SizeScaleY             = data.SizeScaleY,
			ImageColor3            = data.ImageColor3,
			BackgroundColor3       = data.BackgroundColor3,
			Timescale              = data.ImgTimescale,
		},
		Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.ImgTimescale, seeds.Timescale, safeLife),

		FlipbookSource   = data.ImgFlipbookSource or "Decals",
		FlipbookMode     = data.ImgFlipbookMode or Enum.ParticleFlipbookMode.Loop,
		FlipbookFramerate = framerate,
		FlipbookStartOffset = startFrameOffset,
		FlipbookReverse  = data.ImgFlipbookReverse or false,
		FlipbookDecals   = flipbookDecals,
		SheetSize = sheetSize,
		GridCols = data.ImgGridCols or 8,
		GridRows = data.ImgGridRows or 1,

		IsAnimate = isAnimate or nil,
		AnimateItem = isAnimate and item or nil,
	}

	-- InvertMotion: seed PosX/PosY + EnvVelX/Y to the forward trajectory's end-state
	-- and run elapsed counter from lifeTime back to 0 via per-frame _invertDtSign.
	-- EnvVel seed is required for accel-driven motion to reverse correctly  -  with
	-- EnvVel=0 the negative-dt integration accumulates accel in the wrong direction
	-- and doesn't retrace the forward path.
	if data.ImgInvertMotion then
		local endX, endY, endVelX, endVelY = _simulateForward2D(data, dx, dy, safeLife, seeds)
		pData.PosX, pData.PosY = endX, endY
		pData.EnvVelX, pData.EnvVelY = endVelX, endVelY
		pData._effectiveElapsed = safeLife
		pData._invertDtSign = -1
	end

	-- Static-graph short-circuit via shared StaticPass module. Constant-valued
	-- NumberSequence graphs nil out of pData.Graphs + stamp pData._static<Name>.
	-- Frame-0 setup already wrote the visual for ImageTransparency / BackgroundTransparency,
	-- so the nil'd-graph short-circuits the per-step write. Speed / RotSpeed / SizeScale
	-- store the constant on pData._static<Name>; UpdateImageLabel reads it instead of
	-- sampling. ColorSequence graphs not covered (ColorSequence has no IsStatic helper;
	-- color writes are already step-quantized).
	StaticPass.apply(pData)
	-- SizeScale both-axes-static collapse: when X and Y both constant, nil their static
	-- fields too so the per-frame Size block short-circuits entirely (frame-0 captured
	-- the visual Size). Mixed (one static, one dynamic) keeps the static field so the
	-- block samples only the dynamic axis.
	if pData._staticSizeScaleX and pData._staticSizeScaleY then
		pData._staticSizeScaleX = nil
		pData._staticSizeScaleY = nil
	end

	return pData
end

function Particle:EmitImageLabel(item, link, emitCtx)
	local data = self:GetEmitData(item, emitCtx)
	if not data or not data.RenderTemplate then return end

	-- First-emit-per-RT preload yield; subsequent emits short-circuit on the memo.
	preloadAndWait(self, data.RenderTemplate, data, nil)

	-- Pool reuse: fresh clones strip ImageFlipbooks (textures come from pData.FlipbookDecals);
	-- pooled clones already have it stripped from prior acquire.
	local visual = Pool.acquireOrClone(data.RenderTemplate, "ImageLabel", data.Pool)
	visual.Archivable = false
	visual.Visible = true
	local cloneFF = visual:FindFirstChild("ImageFlipbooks")
	if cloneFF then cloneFF:Destroy() end

	local pData = buildImageLabelPData(data, visual, item, false)
	pData.Link = link
	pData._sourceItem = item
	Particle._seedTsOverride(pData, item)
	pData.Events = data.Events
	if data.Pool ~= false then pData._sourceRT, pData._poolKind = data.RenderTemplate, "ImageLabel" end
	preloadEmitAssets(data, pData.FlipbookDecals)
	visual.Parent = resolveImageParent(data, item, emitCtx)
	self:_registerEmit(pData, emitCtx)

	-- Nested ImageLabels parent next to source via _PartIcleEmit ancestry; UDim2 Scale stays relative.
	for _, desc in visual:GetDescendants() do
		if desc:GetAttribute("Transformed") and desc:IsA("ImageLabel") then
			self:EnableEmit(desc, nil, emitCtx)
		end
	end
end

-- Singleton clone-animate; refuses duplicate emits while active.
function Particle:EmitImageLabelAnimate(item, link, emitCtx)
	if self.ActiveAnimates[item] then return end
	local data = self:GetEmitData(item, emitCtx)
	if not data or not data.RenderTemplate then return end

	-- First-emit-per-RT preload yield (see EmitImageLabel).
	preloadAndWait(self, data.RenderTemplate, data, nil)

	local visual = data.RenderTemplate:Clone()
	visual.Archivable = false
	visual.Visible = true
	visual:SetAttribute("_PartIcleEmit", true)
	local cloneFF = visual:FindFirstChild("ImageFlipbooks"); if cloneFF then cloneFF:Destroy() end

	local pData = buildImageLabelPData(data, visual, item, true)
	pData.Link = link
	pData._sourceItem = item
	Particle._seedTsOverride(pData, item)
	pData.Events = data.Events
	preloadEmitAssets(data, pData.FlipbookDecals)
	visual.Parent = resolveImageParent(data, item, emitCtx)
	self.ActiveAnimates[item] = pData
	self:_registerEmit(pData, emitCtx)

	for _, desc in visual:GetDescendants() do
		if desc:GetAttribute("Transformed") and desc:IsA("ImageLabel") then
			self:EnableEmit(desc, nil, emitCtx)
		end
	end
end

-- Per-frame update; returns true when lifetime ends.
function Particle:UpdateImageLabel(pData, dt, currentTime)
	local visual = pData.VisualPart
	if not visual or not visual.Parent then return true end
	if pData.TotalKeyFrames <= 0 then return true end

	-- Timescale v2 (signed reverse): see Update.luau UpdatePart. SetTimescale override wins for its window.
	local real_i = math.min(math.max((currentTime - pData.StartTime) / pData.LifeTime, 0), 1)
	local ts
	if pData._tsOverride ~= nil and currentTime < (pData._tsOverrideUntil or 0) then
		ts = pData._tsOverride
	else
		ts = pData.Graphs.Timescale and GraphMod.QueryPointsWithTime(real_i, pData.Graphs.Timescale, pData.Seeds.Timescale) or 1
	end
	dt = dt * ts
	-- InvertMotion: flip dt sign so elapsed counter walks back from lifeTime → 0
	-- (seeded at lifeTime in buildImageLabelPData). PosX/PosY were seeded to the
	-- trajectory's END so the negative-dt integration retraces backward.
	if pData._invertDtSign then dt = dt * pData._invertDtSign end
	local lifeTime = pData.LifeTime
	local priorEff = pData._effectiveElapsed or 0
	local newEff = priorEff + (pData._timeFrozen and 0 or dt)
	if newEff < 0 then newEff = 0 end
	if newEff > lifeTime then newEff = lifeTime end
	pData._effectiveElapsed = newEff
	-- After-clamp dt: boundary frames see partial step instead of overshooting.
	dt = newEff - priorEff
	local atForwardEnd = newEff >= lifeTime
	local atBackwardEnd = newEff <= 0
	local elapsed = newEff
	local i = elapsed / lifeTime
	local graphFinished = real_i >= 1
	local isDying = graphFinished and (atForwardEnd or atBackwardEnd)
	if i > 1 then i = 1 end
	if i < 0 then i = 0 end

	-- All motion + rotation + size + color/transparency writes gate on step advance
	-- (TotalKeyFrames quantization), matching Part / Beam / Highlight / etc. Sub-step
	-- frames accumulate dt into pData.AccumulatedDT; on step transition the accumulated
	-- delta drives one integration pass + one visual write batch. Flipbook stays per-frame
	-- because its cadence is FlipbookFramerate, independent of TKF.
	local graphs = pData.Graphs
	local seeds = pData.Seeds
	pData.AccumulatedDT = (pData.AccumulatedDT or 0) + dt

	local targetStep = math.floor(i * pData.TotalKeyFrames)
	if targetStep ~= pData.CurrentStep then
		local frameDT = pData.AccumulatedDT
		pData.AccumulatedDT = 0
		pData.CurrentStep = targetStep
		local t = targetStep / pData.TotalKeyFrames

		-- Speed sampled at step boundary. Drag decay still references continuous elapsed
		-- (math.exp closed form, identical to per-frame variant; not dt-dependent).
		local speed = 0
		if pData._staticImgSpeed then
			speed = pData._staticImgSpeed * 100
		elseif graphs.ImgSpeed then
			speed = GraphMod.QueryPointsWithTime(t, graphs.ImgSpeed, seeds.ImgSpeed) * 100
		end
		if speed ~= 0 and pData.Drag > 0 then speed = speed * math.exp(-pData.Drag * elapsed) end

		-- EnvVel integrates Acceleration over the cross-frame batch (frameDT). Drag decay
		-- linear-approx — frameDT bounded by step-interval (1/(TKF/LifeTime)) so for typical
		-- TKF=100 still small.
		pData.EnvVelX += pData.AccelX * 100 * frameDT
		pData.EnvVelY += pData.AccelY * 100 * frameDT
		if pData.Drag > 0 then
			local decay = math.max(0, 1 - pData.Drag * frameDT)
			pData.EnvVelX *= decay; pData.EnvVelY *= decay
		end

		local vx = speed * pData.DirX + pData.EnvVelX
		local vy = speed * pData.DirY + pData.EnvVelY
		pData.PosX += vx * frameDT
		pData.PosY += vy * frameDT
		local bp = pData.BasePosition
		visual.Position = UDim2.new(bp.X.Scale, bp.X.Offset + pData.PosX, bp.Y.Scale, bp.Y.Offset + pData.PosY)

		-- Rotation. OverLife = absolute angle; Speed = deg/sec accumulator. Both add InitialRotation.
		local rs
		if pData._staticImgRotSpeed then
			rs = pData._staticImgRotSpeed
		elseif graphs.ImgRotSpeed then
			rs = GraphMod.QueryPointsWithTime(t, graphs.ImgRotSpeed, seeds.ImgRotSpeed)
		end
		if rs then
			local newRot
			if pData.RotMode == "Speed" then
				pData.AccRot += rs * frameDT
				newRot = pData.InitialRotation + pData.AccRot
			else
				newRot = pData.InitialRotation + rs
			end
			if newRot ~= pData._lastRotation then
				visual.Rotation = newRot
				pData._lastRotation = newRot
			end
		end

		-- Size scale.
		local hasSizeX = pData._staticSizeScaleX or graphs.SizeScaleX
		local hasSizeY = pData._staticSizeScaleY or graphs.SizeScaleY
		if (hasSizeX or hasSizeY) and not pData.SkipSize then
			local sx = pData._staticSizeScaleX
				or (graphs.SizeScaleX and GraphMod.QueryPointsWithTime(t, graphs.SizeScaleX, seeds.SizeScaleX))
				or 1
			local sy = pData._staticSizeScaleY
				or (graphs.SizeScaleY and GraphMod.QueryPointsWithTime(t, graphs.SizeScaleY, seeds.SizeScaleY))
				or 1
			if sx ~= pData._lastSizeX or sy ~= pData._lastSizeY then
				local bs = pData.BaseSize
				visual.Size = UDim2.new(bs.X.Scale * sx, bs.X.Offset * sx, bs.Y.Scale * sy, bs.Y.Offset * sy)
				pData._lastSizeX, pData._lastSizeY = sx, sy
			end
		end

		-- Color / transparency. Gate on SkipColor / SkipTransparency for runtime overrides
		-- via payload.SetSkipColor / SetSkipTransparency.
		if graphs.ImageTransparency and not pData.SkipTransparency then visual.ImageTransparency = GraphMod.QueryPointsWithTime(t, graphs.ImageTransparency, seeds.ImageTransparency) end
		if graphs.BackgroundTransparency and not pData.SkipTransparency then visual.BackgroundTransparency = GraphMod.QueryPointsWithTime(t, graphs.BackgroundTransparency, seeds.BackgroundTransparency) end
		if graphs.ImageColor3 and not pData.SkipColor then visual.ImageColor3 = GraphMod.QueryColorPointWithTime(t, graphs.ImageColor3) end
		if graphs.BackgroundColor3 and not pData.SkipColor then visual.BackgroundColor3 = GraphMod.QueryColorPointWithTime(t, graphs.BackgroundColor3) end
	end

	-- Flipbook independent of TKF (uses FlipbookFramerate); runs per-frame with internal lastFrame dedup.
	applyFlipbookFrame(pData, elapsed)

	return isDying
end

-- AnimateLoop refresh: non-spatial fields only (spatial accumulators reset by replay).
function Particle:_refreshImageLabelAnimateNonSpatial(pData, freshData)
	if not freshData then return end
	local ea = freshData.ImgEmissionAngle or 90
	local sp = freshData.ImgSpreadAngle or 0
	local angle = ea + (math.random() * 2 - 1) * sp
	local rad = math.rad(angle)
	local dx, dy = math.cos(rad), -math.sin(rad)
	-- InvertMotion no longer flips dx/dy here. Engine's AnimateLoop branch handles
	-- inversion by seeding PosX/PosY to the trajectory's end + per-frame negative dt.
	pData.DirX = dx; pData.DirY = dy
	if freshData.ImgAcceleration then
		pData.AccelX = freshData.ImgAcceleration.X
		pData.AccelY = freshData.ImgAcceleration.Y
	end
	if freshData.ImgDrag ~= nil then pData.Drag = freshData.ImgDrag end
	if freshData.ImgPosition then pData.BasePosition = freshData.ImgPosition end
	if freshData.ImgSizeUDim then pData.BaseSize = freshData.ImgSizeUDim end
	if freshData.ImgRotMode then pData.RotMode = freshData.ImgRotMode end
	if freshData.ImgRotRange then pData.InitialRotation = RangeMod.RandomValueFromRange(freshData.ImgRotRange) end
	if freshData.ImgFlipbookSource then pData.FlipbookSource = freshData.ImgFlipbookSource end
	if freshData.ImgFlipbookMode then pData.FlipbookMode = freshData.ImgFlipbookMode end
	if freshData.ImgFlipbookFramerate then pData.FlipbookFramerate = RangeMod.RandomValueFromRange(freshData.ImgFlipbookFramerate) end
	if freshData.ImgFlipbookReverse ~= nil then pData.FlipbookReverse = freshData.ImgFlipbookReverse end
	if freshData.ImgGridCols then pData.GridCols = freshData.ImgGridCols end
	if freshData.ImgGridRows then pData.GridRows = freshData.ImgGridRows end
	if freshData.SheetSize ~= nil then pData.SheetSize = freshData.SheetSize end
	if freshData.ImageFlipbooks then pData.FlipbookDecals = gatherFlipbookDecals(freshData.ImageFlipbooks) end
	if freshData.ImgTimescale and pData.Graphs then pData.Graphs.Timescale = freshData.ImgTimescale; pData.Seeds.Timescale = GraphMod.GenerateSeed(freshData.ImgTimescale) end
end

end
