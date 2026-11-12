--[[
	Distortion/Canvas  -  the singleton screen-canvas compositor
	(CameraShake/Apply.luau role, but for the shared glass plane).

	Every live Distortion pData pushes ONE contribution per frame via
	Canvas.accumulate (scalars into preallocated parallel arrays  -  zero-alloc).
	Engine calls Canvas.applyFrame() once per step AFTER CameraShakeApply so the
	plane rides the shaken camera in the same frame: it evaluates every
	contribution into the shared height buffer (Distortion/Field), camera-locks
	the plane, and performs one vertex write pass.

	One plane per client, ever: overlapping glass planes cull each other, and
	the recipe Highlight would eat the 31-Highlight engine cap. Cross-engine
	(plugin + runtime module) ownership is first-claimant-wins via a heartbeat
	attribute  -  a newcomer seeing a live foreign canvas goes dormant instead of
	destroying it.

	Strength model: each contribution carries its sampled Transparency graph
	value; the plane takes the MIN across contributions (strongest glass wins,
	lower T = stronger refraction down to ~0.5, below that = dark semi-mirror).
	Transparency>1 is the overdrive zone (engine quirk, effective ~4-10): via the
	Amplify prop it engages only when EVERY active contribution opted in
	(AllowOverdrive veto); via the Transparency graph the MIN composition is the
	veto (any effect below 1 wins the plane). Either path latches permanently
	back to safe if the engine ever clamps the write (unpatched-bug dependency).

	Idle/parked visibility: Glass at Transparency 1 still renders sheen and the
	recipe Highlight leaves outline residue (engine quirk), so every idle window
	swaps to SmoothPlastic + disabled Highlight (setDimmed) and back on wake.
]]

local Lighting = game:GetService("Lighting")

local Field = require(script.Parent.Field)
local PlaneBuilder = require(script.Parent.PlaneBuilder)
local VisualHost = require(script.Parent.Parent.VisualHost)
local Log = require(script.Parent.Parent.Log)

local Canvas = {}

-- Mesh plane hugs the camera (1 stud) so nearby world geometry rarely sits
-- between them; displacement is halfH-scaled so the look is distance-invariant.
-- Tile lenses stay farther out  -  at 1 stud their angular size would overlap
-- and overlapping glass culls itself.
local MESH_DIST = 1
local TILE_DIST = 3.5
local MESH_OFFSET = CFrame.new(0, 0, -MESH_DIST)
local MARGIN = 1.15
-- Vertex Z never exceeds this fraction of MESH_DIST toward the camera, so
-- extreme amplitudes cannot push the surface through the near-clip plane.
local HEIGHT_CLAMP = MESH_DIST * 0.45
-- Displacement tapers to zero across this UV band at the plane border: the
-- silhouette stays the flat covered rect, so edges never pull into view.
local EDGE_BAND = 0.12
-- Sun hole: glass refracts the SKYBOX, so a displaced field smears the sun
-- disc + bloom into a bright blob that reveals the plane. The field flattens
-- across a screen-space hole around the sun (flat glass there is invisible  -
-- verified). Squared radii; distances are aspect-corrected UV.
local SUN_HOLE_IN2 = 0.09 * 0.09
local SUN_HOLE_OUT2 = 0.26 * 0.26
-- Amplitude is authored in slope units; height = amp * halfH * SLOPE_K keeps
-- perceived refraction FOV- and resolution-invariant.
local SLOPE_K = 0.22
local IDLE_PARK_SECONDS = 2
local MAX_CONTRIB = 64
local BASE_TRANSPARENCY = 0.3
local HEARTBEAT_STALE = 1

-- Contribution parallel arrays (cursor reset every applyFrame).
local cKind = table.create(MAX_CONTRIB)
local cAmp = table.create(MAX_CONTRIB)
local cWavelength = table.create(MAX_CONTRIB)
local cPhase = table.create(MAX_CONTRIB)
local cDir = table.create(MAX_CONTRIB)
local cNoiseScale = table.create(MAX_CONTRIB)
local cLensRadius = table.create(MAX_CONTRIB)
local cEpicU = table.create(MAX_CONTRIB)
local cEpicV = table.create(MAX_CONTRIB)
local cSeed = table.create(MAX_CONTRIB)
local cAmplify = table.create(MAX_CONTRIB)
local cAllowOver = table.create(MAX_CONTRIB)
local cTrans = table.create(MAX_CONTRIB)
local cRes = table.create(MAX_CONTRIB)
local cursor = 0
local overflowWarned = false

-- Canvas state.
local meshCanvas = nil          -- PlaneBuilder.buildMesh result
local tileCanvas = nil          -- PlaneBuilder.buildTiles result
local building = false
local meshTierAvailable = nil   -- sticky probe result (nil = not probed yet)
local overdriveLatched = false  -- engine clamped a >1 write; stay safe forever
local idleSince = nil
local dormant = false           -- a foreign engine owns the canvas
local dormantWarned = false
local ownerSerial = math.floor((os.clock() % 1000) * 1000000)
local height = nil              -- sized per mesh build (resolution-dependent)
local tileHeight = table.create(PlaneBuilder.TILE_W * PlaneBuilder.TILE_H)
local baseU = nil               -- normalized coords, built lazily per tier
local baseV = nil
local tileU = nil
local tileV = nil
local edgeW = nil               -- per-vertex border taper (mesh tier)

local function buildNormCoords(w, h)
	local u = table.create(w * h)
	local v = table.create(w * h)
	for gy = 0, h - 1 do
		for gx = 0, w - 1 do
			local k = gy * w + gx + 1
			u[k] = gx / (w - 1)
			v[k] = gy / (h - 1)
		end
	end
	return u, v
end

-- Smoothstep taper from 0 at the UV border to 1 past EDGE_BAND.
local function buildEdgeWindow(u, v, count)
	local w = table.create(count)
	for k = 1, count do
		local d = math.min(u[k], 1 - u[k], v[k], 1 - v[k]) / EDGE_BAND
		if d > 1 then d = 1 end
		w[k] = d * d * (3 - 2 * d)
	end
	return w
end

-- Glass at Transparency 1 still renders sheen + Highlight outline residue
-- (engine quirk), so idle windows swap to SmoothPlastic with the Highlight off.
-- Transition-only writes; dimmed guard keeps this out of the per-frame path.
-- applyDimToMesh is unconditional so a freshly swapped-in mesh (resolution
-- upgrade) inherits the current dim state.
local dimmed = false
local function applyDimToMesh()
	if not meshCanvas then return end
	local part = meshCanvas.part
	part.Material = dimmed and Enum.Material.SmoothPlastic or Enum.Material.Glass
	if dimmed then part.Transparency = 1 end
	if meshCanvas.highlight then meshCanvas.highlight.Enabled = not dimmed end
end
local function setDimmed(on)
	if dimmed == on then return end
	dimmed = on
	applyDimToMesh()
	if tileCanvas then
		local mat = on and Enum.Material.SmoothPlastic or Enum.Material.Glass
		for i = 1, tileCanvas.count do
			tileCanvas.tiles[i].Material = mat
			if on then tileCanvas.tiles[i].Transparency = 1 end
			local hl = tileCanvas.highlights[i]
			if hl then hl.Enabled = not on end
		end
	end
end

-- kindId: 1 Ripple, 2 Wave, 3 Noise, 4 Bulge, 5 Pinch (Distortion/init maps).
-- Called every live frame (amp may be 0); atten pulls the transparency channel
-- toward 1 so distance/behind-camera fades stay continuous alongside amp.
-- res = requested mesh grid width; the plane is shared, so the HIGHEST active
-- request wins (async rebuild, never downgraded until teardown).
function Canvas.accumulate(kindId, amp, wavelength, phase, dirRad, noiseScale, lensRadius, epicU, epicV, seed, amplify, allowOver, trans, atten, res)
	if dormant then return end
	if cursor >= MAX_CONTRIB then
		if not overflowWarned then
			overflowWarned = true
			Log.warn("[Part-Icles] Distortion: more than " .. MAX_CONTRIB .. " simultaneous effects; extras dropped this frame")
		end
		return
	end
	cursor += 1
	cKind[cursor] = kindId
	cAmp[cursor] = amp
	cWavelength[cursor] = wavelength
	cPhase[cursor] = phase
	cDir[cursor] = dirRad
	cNoiseScale[cursor] = noiseScale
	cLensRadius[cursor] = lensRadius
	cEpicU[cursor] = epicU
	cEpicV[cursor] = epicV
	cSeed[cursor] = seed
	cAmplify[cursor] = amplify
	cAllowOver[cursor] = allowOver
	-- Graph values above 1 request overdrive directly; the atten pull toward 1
	-- works from both sides (1 - (1-t)*a fades 6 -> 1 as atten -> 0).
	local t = math.clamp(trans or BASE_TRANSPARENCY, 0, 10)
	local a = math.clamp(atten or 1, 0, 1)
	cTrans[cursor] = 1 - (1 - t) * a
	cRes[cursor] = res or PlaneBuilder.RES_W
end

-- A foreign live canvas (other engine) parents under the same root with a heartbeat.
local function foreignCanvasLive()
	local existing = VisualHost.root():FindFirstChild("__PartIclesDistortion")
	if not existing then return false end
	if existing:GetAttribute("_ownerSerial") == ownerSerial then return false end
	local hb = existing:GetAttribute("_hb")
	if typeof(hb) == "number" and (os.clock() - hb) < HEARTBEAT_STALE then
		return true
	end
	-- Stale heartbeat: prior owner died without cleanup. Take over.
	pcall(function() existing:Destroy() end)
	return false
end

local function goDormant()
	dormant = true
	if not dormantWarned then
		dormantWarned = true
		Log.warn("[Part-Icles] Distortion: another Part-Icles engine owns the screen canvas; this engine's distortions are disabled")
	end
end

-- Bumped by reset(); an async mesh build that resumes after a teardown must
-- discard its result instead of parenting an orphan the sweep already missed.
local buildGen = 0

-- Grid height from width, keeping the canonical 24:14 aspect.
local function deriveResH(resW)
	return math.max(4, math.floor(resW * PlaneBuilder.RES_H / PlaneBuilder.RES_W + 0.5))
end

-- Install a finished mesh build as the live canvas (initial build or resolution
-- upgrade swap): destroy-then-parent runs in one thread, so no frame renders
-- without a plane. Sizes the resolution-dependent buffers.
local function installMeshBuild(built)
	local old = meshCanvas
	meshCanvas = nil
	if old then
		pcall(function() old.part:Destroy() end)
		pcall(function() old.em:Destroy() end)
	end
	built.part:SetAttribute("_ownerSerial", ownerSerial)
	built.part:SetAttribute("_PartIcleEmit", true)
	built.part.Transparency = BASE_TRANSPARENCY
	built.part.Parent = VisualHost.getCanvasParent()
	meshCanvas = built
	local count = built.resW * built.resH
	baseU, baseV = buildNormCoords(built.resW, built.resH)
	edgeW = buildEdgeWindow(baseU, baseV, count)
	height = table.create(count)
	applyDimToMesh()
end

local function ensureCanvas(targetResW)
	if meshCanvas or tileCanvas or building then return end
	if foreignCanvasLive() then
		goDormant()
		return
	end
	if meshTierAvailable == nil then
		meshTierAvailable = PlaneBuilder.probeMesh()
	end
	building = true
	local myGen = buildGen
	task.spawn(function()
		if meshTierAvailable then
			local built = PlaneBuilder.buildMesh(targetResW, deriveResH(targetResW))
			-- CreateMeshPartAsync yields; reset() may have run meanwhile.
			if buildGen ~= myGen then
				if built then
					pcall(function() built.part:Destroy() end)
					pcall(function() built.em:Destroy() end)
				end
				return
			end
			if built then
				installMeshBuild(built)
				building = false
				return
			end
			-- Mid-session memory/permission failure: demote for the session.
			meshTierAvailable = false
		end
		if buildGen ~= myGen then return end
		local tiles = PlaneBuilder.buildTiles()
		tiles.model:SetAttribute("_ownerSerial", ownerSerial)
		tiles.model:SetAttribute("_PartIcleEmit", true)
		tiles.model.Parent = VisualHost.getCanvasParent()
		tileCanvas = tiles
		tileU, tileV = buildNormCoords(PlaneBuilder.TILE_W, PlaneBuilder.TILE_H)
		building = false
	end)
end

-- A higher-resolution request arrived while a lower-res mesh is live: build the
-- bigger grid in the background (old plane keeps rendering) and swap on
-- completion. Downgrades never happen until teardown (avoids rebuild thrash).
local function upgradeMesh(targetResW)
	building = true
	local myGen = buildGen
	task.spawn(function()
		local built = PlaneBuilder.buildMesh(targetResW, deriveResH(targetResW))
		if buildGen ~= myGen then
			if built then
				pcall(function() built.part:Destroy() end)
				pcall(function() built.em:Destroy() end)
			end
			return
		end
		if built then
			installMeshBuild(built)
		end
		building = false
	end)
end

-- Plane Transparency: overdrive via Amplify (MAX across contributions, engaged
-- only when EVERY one opted in), else MIN of the sampled per-effect Transparency
-- graphs. Graph values above 1 are direct overdrive requests; MIN keeps that
-- conservative automatically (any effect below 1 wins the plane). Never after a
-- clamp latch.
local function resolveTransparency()
	if cursor == 0 then return 1 end
	if not overdriveLatched then
		local allOver = true
		local maxAmplify = 0
		for i = 1, cursor do
			if not cAllowOver[i] then
				allOver = false
				break
			end
			if cAmplify[i] > maxAmplify then maxAmplify = cAmplify[i] end
		end
		if allOver and maxAmplify > 0 then return math.clamp(maxAmplify, 4, 10) end
	end
	local minT = 10
	for i = 1, cursor do
		if cTrans[i] < minT then minT = cTrans[i] end
	end
	if overdriveLatched and minT > 1 then return BASE_TRANSPARENCY end
	return math.clamp(minT, 0, 10)
end

local function evalContributions(buf, u, v, count, aspect, ampScale)
	Field.zero(buf, count)
	for i = 1, cursor do
		-- Zero-amp contributions carry only the transparency channel.
		if cAmp[i] ~= 0 then
			Field.accumulate(cKind[i], buf, u, v, count, aspect,
				cAmp[i] * ampScale, cWavelength[i], cPhase[i], cDir[i],
				cNoiseScale[i], cLensRadius[i], cEpicU[i], cEpicV[i], cSeed[i])
		end
	end
end

local function applyMesh(cam, wantT)
	local canvas = meshCanvas
	local halfH = MESH_DIST * math.tan(math.rad(cam.FieldOfView) * 0.5) * MARGIN
	local vps = cam.ViewportSize
	local aspect = vps.X / math.max(1, vps.Y)
	local halfW = halfH * aspect
	local part = canvas.part
	part.CFrame = cam.CFrame * MESH_OFFSET
	part:SetAttribute("_hb", os.clock())
	-- Coverage via Size X/Y (mesh XY is unit extents); Z stays 1:1 studs.
	part.Size = Vector3.new(halfW * 2, halfH * 2, canvas.meshSizeZ)
	-- Read-back latch: if the engine ever clamps a >1 write (bug patched),
	-- permanently fall back to the safe baseline for the session.
	part.Transparency = wantT
	if wantT > 1 and math.abs(part.Transparency - wantT) > 0.01 then
		overdriveLatched = true
		part.Transparency = BASE_TRANSPARENCY
	end
	local count = canvas.resW * canvas.resH
	evalContributions(height, baseU, baseV, count, aspect, halfH * SLOPE_K)

	-- Sun screen position for the hole mask. Plane-local V runs bottom-up while
	-- viewport Y runs top-down, so the sun V converts into baseV space.
	local sunOn = false
	local sunU, sunVbase = 0, 0
	local sunVp, sunInView = cam:WorldToViewportPoint(cam.CFrame.Position + Lighting:GetSunDirection() * 1000)
	if sunInView and sunVp.Z > 0 then
		sunOn = true
		sunU = sunVp.X / math.max(1, vps.X)
		sunVbase = 1 - sunVp.Y / math.max(1, vps.Y)
	end

	local em, ids, baseX, baseY = canvas.em, canvas.ids, canvas.baseX, canvas.baseY
	for i = 1, count do
		local z = height[i] * edgeW[i]
		if sunOn then
			local dx = (baseU[i] - sunU) * aspect
			local dy = baseV[i] - sunVbase
			local d2 = dx * dx + dy * dy
			if d2 < SUN_HOLE_OUT2 then
				if d2 <= SUN_HOLE_IN2 then
					z = 0
				else
					local t = (d2 - SUN_HOLE_IN2) / (SUN_HOLE_OUT2 - SUN_HOLE_IN2)
					z = z * t * t * (3 - 2 * t)
				end
			end
		end
		if z > HEIGHT_CLAMP then
			z = HEIGHT_CLAMP
		elseif z < -HEIGHT_CLAMP then
			z = -HEIGHT_CLAMP
		end
		em:SetPosition(ids[i], Vector3.new(baseX[i], baseY[i], z))
	end
end

local function applyTiles(cam)
	local canvas = tileCanvas
	local count = canvas.count
	local vps = cam.ViewportSize
	local aspect = vps.X / math.max(1, vps.Y)
	evalContributions(tileHeight, tileU, tileV, count, aspect, 1)
	canvas.model:SetAttribute("_hb", os.clock())
	-- Transparency graphs on this tier scale tile opacity: minT 1 = faded out.
	local minT = 1
	for i = 1, cursor do
		if cTrans[i] < minT then minT = cTrans[i] end
	end
	local transFactor = 1 - math.clamp(minT, 0, 1)
	local camCF = cam.CFrame
	for i = 1, count do
		local dirCF = camCF * CFrame.Angles(canvas.pitchAng[i], canvas.yawAng[i], 0)
		canvas.writeCFs[i] = CFrame.lookAt(camCF.Position + dirCF.LookVector * TILE_DIST, camCF.Position)
		-- Idle tile invisible (T=1); strength pulls toward the verified sweet
		-- spot 0.5. Sign is lost on this tier (documented).
		local mag = math.clamp(math.abs(tileHeight[i]) * 2, 0, 1)
		canvas.tiles[i].Transparency = 1 - mag * 0.5 * transFactor
	end
	workspace:BulkMoveTo(canvas.tiles, canvas.writeCFs, Enum.BulkMoveMode.FireCFrameChanged)
end

-- Same-frame camera weld: the RenderStep write alone lags native camera motion
-- (Studio editor camera, fast play-mode moves) by one frame, which reads as the
-- pane unsticking. The CFrame property signal fires on every camera write  -
-- including CameraShakeApply's  -  so the pane re-locks the instant the camera
-- moves. Mesh tier only (per-signal BulkMoveTo would be too heavy for tiles).
local camConn = nil
local camConnCam = nil
local function relockToCam()
	if meshCanvas and camConnCam and meshCanvas.part.Parent then
		meshCanvas.part.CFrame = camConnCam.CFrame * MESH_OFFSET
	end
end
local function ensureCamWeld(cam)
	if camConnCam == cam then return end
	if camConn then camConn:Disconnect() end
	camConnCam = cam
	camConn = cam:GetPropertyChangedSignal("CFrame"):Connect(relockToCam)
end
local function dropCamWeld()
	if camConn then
		camConn:Disconnect()
		camConn = nil
	end
	camConnCam = nil
end

local function parkCanvas()
	dropCamWeld()
	if meshCanvas then
		pcall(function() meshCanvas.part.Parent = nil end)
	end
	if tileCanvas then
		pcall(function() tileCanvas.model.Parent = nil end)
	end
end

-- Reparent throws if the instance was Destroy()ed externally (other engine's
-- _PartIcleEmit sweep, Explorer delete): drop the ref so ensureCanvas rebuilds
-- instead of wedging applyFrame with a per-frame Parent-locked error.
local function unparkCanvas()
	if meshCanvas and not meshCanvas.part.Parent then
		local ok = pcall(function() meshCanvas.part.Parent = VisualHost.getCanvasParent() end)
		if not ok then
			pcall(function() meshCanvas.em:Destroy() end)
			meshCanvas = nil
		end
	end
	if tileCanvas and not tileCanvas.model.Parent then
		local ok = pcall(function() tileCanvas.model.Parent = VisualHost.getCanvasParent() end)
		if not ok then
			tileCanvas = nil
		end
	end
end

function Canvas.applyFrame()
	local hadWork = cursor > 0
	local cam = workspace.CurrentCamera
	if not cam then
		cursor = 0
		return
	end
	if not hadWork then
		-- Idle: keep the parked countdown honest and the plane camera-locked
		-- (a frozen world-space pane reads as a stale glass sheet) with the
		-- field zeroed exactly once.
		local live = (meshCanvas and meshCanvas.part.Parent) or (tileCanvas and tileCanvas.model.Parent)
		if live then
			if meshCanvas then ensureCamWeld(cam) end
			if idleSince == nil then
				idleSince = os.clock()
				if meshCanvas then applyMesh(cam, 1) else applyTiles(cam) end
				setDimmed(true)
			elseif os.clock() - idleSince >= IDLE_PARK_SECONDS then
				parkCanvas()
			else
				if meshCanvas then
					meshCanvas.part.CFrame = cam.CFrame * MESH_OFFSET
					meshCanvas.part:SetAttribute("_hb", os.clock())
				elseif tileCanvas then
					applyTiles(cam)
				end
			end
		end
		return
	end
	idleSince = nil
	-- Dormancy retries: when the foreign owner is gone (torn down, or parked
	-- forever and thus invisible), this engine reclaims the screen instead of
	-- staying silent for the session.
	if dormant then
		if foreignCanvasLive() then
			cursor = 0
			return
		end
		dormant = false
	end
	-- Wake ownership re-check: a parked (nil-Parent) canvas is invisible to the
	-- other engine's foreignCanvasLive probe, so a foreign canvas may have gone
	-- live during our idle window. First-claimant-wins: yield while it lives.
	local parked = (meshCanvas and not meshCanvas.part.Parent)
		or (tileCanvas and not tileCanvas.model.Parent)
	if parked and foreignCanvasLive() then
		goDormant()
		cursor = 0
		return
	end
	unparkCanvas()
	-- Highest active resolution request wins the shared plane.
	local targetRes = PlaneBuilder.RES_W
	for i = 1, cursor do
		if cRes[i] > targetRes then targetRes = cRes[i] end
	end
	ensureCanvas(targetRes)
	-- `building` alone does not bail: during a resolution upgrade the old plane
	-- keeps rendering until the swap.
	if dormant or (not meshCanvas and not tileCanvas) then
		cursor = 0
		return
	end
	if meshCanvas and not building and meshCanvas.resW < targetRes then
		upgradeMesh(targetRes)
	end
	local wantT = resolveTransparency()
	-- Every contribution faded to 1: keep vertices/CFrame live but dim the pane
	-- (Glass at T=1 still sheens  -  the idle quirk applies mid-life too).
	setDimmed(wantT >= 0.999 and wantT <= 1)
	if meshCanvas then
		ensureCamWeld(cam)
		applyMesh(cam, wantT)
	else
		applyTiles(cam)
	end
	cursor = 0
end

-- Engine teardown: destroy everything, clear the sticky probe so the next
-- Activate re-probes (permissions can change between sessions).
function Canvas.reset()
	dropCamWeld()
	if meshCanvas then
		pcall(function() meshCanvas.part:Destroy() end)
		pcall(function() meshCanvas.em:Destroy() end)
		meshCanvas = nil
	end
	if tileCanvas then
		pcall(function() tileCanvas.model:Destroy() end)
		tileCanvas = nil
	end
	cursor = 0
	building = false
	buildGen += 1
	meshTierAvailable = nil
	overdriveLatched = false
	idleSince = nil
	dimmed = false
	dormant = false
	dormantWarned = false
	overflowWarned = false
end

return Canvas
