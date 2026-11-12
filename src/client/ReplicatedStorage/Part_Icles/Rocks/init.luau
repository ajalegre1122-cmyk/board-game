--[[
	Rocks Mixin  -  Emit + Animate + Update for debris bursts.

	FULLY PREDETERMINED playback (Rocks/Trajectory.luau) in edit AND running
	games: the complete path  -  arcs, bounces, roll-out, exact rest pose  -  is
	computed once at emit with ~a dozen raycasts per chunk; every frame just
	evaluates pose(t) and BulkMoveTo's. Nothing integrates, so jitter and
	unpredicted end poses are impossible, Timescale (including reverse) replays
	the path exactly, and the game's physics engine never touches the chunks.

	Path building is spread over frames (TRAJ_BUILD_BUDGET chunks per frame); a chunk flies a
	ballistic placeholder until its own path lands, so a 32-chunk burst never spikes one frame.

	OnHit fires from the precomputed first impact (once per burst, or per chunk with HitPerChunk). The generic Events.afterUpdate
	raycast must NOT run here: the Model pivot is the LIVE bounding-box center
	(no PrimaryPart), so it moves with the chunks — pData._ownsOnHit gates it off
	(set in Rocks/PDataBuilder; consumer check at the top of Events.afterUpdate).
]]

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local Pool = require(script.Parent.Pool)
local EventsMod = require(script.Parent.Events)
local NestedEmit = require(script.Parent.NestedEmit)
local ParticlesMod = require(script.Parent.Particles)
local Constants = require(script.Parent.PartConstants)
local Trajectory = require(script.Trajectory)
local PDataBuilder = require(script.PDataBuilder)

local MAX_CHUNKS = 32
-- Chunk paths built per frame; each build costs up to ~18 raycasts.
local TRAJ_BUILD_BUDGET = 8
local FAR_CFRAME = CFrame.new(1e9, 1e9, 1e9)
-- Rested chunks sink through the floor over the last 15% of life (SinkOut).
local SINK_START = 0.85

-- Weak-keyed by burst Model so rig buffers survive pool release/acquire cycles.
local Rigs = setmetatable({}, { __mode = "k" })

return function(Particle)

-- Rocks discriminator; shared by init.luau Emit dispatch + Lifecycle EmitAnimate dispatch.
function Particle._isRocks(item)
	return item:IsA("BasePart") and item:GetAttribute("IsRocks") == true
end

-- One chunk part cloned from the RT. copyBare strips Transformed children (nested
-- source Part-Icles fire once per BURST via NestedEmit.walk, never per chunk).
-- Chunks stay ANCHORED for life  -  trajectory playback drives their CFrames.
local function buildChunk(rt)
	local chunk = Pool.copyBare(rt)
	chunk.Anchored = true
	chunk.CanCollide = false
	chunk.CanQuery = false
	chunk.CanTouch = false
	chunk.Massless = false
	chunk.Locked = true
	chunk.Archivable = false
	chunk.CastShadow = true
	chunk.Transparency = 0
	local decal = chunk:FindFirstChildWhichIsA("Decal") or chunk:FindFirstChildWhichIsA("Texture")
	return chunk, decal
end

local function chunkCapFor(data)
	return math.clamp(math.floor((data.ChunkCount and data.ChunkCount.Max or 10) + 0.5), 1, MAX_CHUNKS)
end

local function buildRig(data)
	local cap = chunkCapFor(data)
	local model = Instance.new("Model")
	model.Name = "RockBurst"
	model.Archivable = false
	local rig = {
		chunkCap = cap,
		parts = table.create(cap),
		decals = table.create(cap),
		baseSize = table.create(cap),
		halfExt = table.create(cap),
		bounciness = table.create(cap),
		gravity = table.create(cap),
		friction = table.create(cap),
		-- Trajectory seeds + playback buffers.
		launchVel = table.create(cap),
		launchAng = table.create(cap),
		spawnPos = table.create(cap),
		spawnRot = table.create(cap),
		trajs = table.create(cap),
		touched = table.create(cap),
		hitDone = table.create(cap),
		writeCFs = table.create(cap),
	}
	for i = 1, cap do
		local chunk, decal = buildChunk(data.RenderTemplate)
		chunk.Name = "Chunk" .. i
		chunk.CFrame = FAR_CFRAME
		chunk.Parent = model
		rig.parts[i] = chunk
		rig.decals[i] = decal
		rig.baseSize[i] = chunk.Size
		rig.writeCFs[i] = FAR_CFRAME
	end
	Rigs[model] = rig
	return model, rig
end

-- Pool acquire with defensive rig re-check (foreign / layout-drifted / engine-
-- destroyed-chunk models rebuild).
local function acquireRocks(data)
	local expected = chunkCapFor(data)
	if data.Pool ~= false then
		local model = Pool.acquire(data.RenderTemplate, "Rocks")
		if model then
			local rig = Rigs[model]
			if rig and rig.chunkCap == expected and rig.parts[1] and rig.parts[1].Parent == model then
				model:SetAttribute("_PartIcleEmit", true)
				return model, rig
			end
			pcall(function() model:Destroy() end)
		end
	end
	local model, rig = buildRig(data)
	model:SetAttribute("_PartIcleEmit", true)
	return model, rig
end

-- Step-gated visual write: transparency/color/brightness on every chunk + decal,
-- Scale graph multiplies baseSize.
local function writeVisuals(pData, t)
	local graphs, seeds = pData.Graphs, pData.Seeds
	local trans = graphs.Transparency and GraphMod.QueryPointsWithTime(t, graphs.Transparency, seeds.Transparency) or 0
	if pData.SkipTransparency then trans = pData._curTrans or trans end
	local bright = graphs.Brightness and GraphMod.QueryPointsWithTime(t, graphs.Brightness, seeds.Brightness) or 1
	local color
	if graphs.Color and not pData.SkipColor then
		local c = GraphMod.QueryColorPointWithTime(t, graphs.Color)
		color = Color3.new(math.min(c.R * bright, 1), math.min(c.G * bright, 1), math.min(c.B * bright, 1))
	end
	local scale = graphs.Scale and GraphMod.QueryPointsWithTime(t, graphs.Scale, seeds.Scale)
	local rig = pData._rig
	local scaleChanged = scale and scale ~= pData._curScale
	if scale then pData._curScale = scale end
	pData._curTrans = trans
	for i = 1, rig.chunkCap do
		local chunk = rig.parts[i]
		chunk.Transparency = trans
		if color then chunk.Color = color end
		local decal = rig.decals[i]
		if decal then
			decal.Transparency = trans
			if color then decal.Color3 = color end
		end
		if scaleChanged then
			chunk.Size = rig.baseSize[i] * math.max(scale, 0.01)
		end
	end
end

-- Edit-path raycast params: makeHitParams filter pattern (source/RT/EmitParent/
-- user OnHit cfg) + both engine folders by ancestry + RespectCanCollide so rocks
-- pass through non-collidable decoration.
local function buildRockParams(self, pData)
	local p = EventsMod.makeHitParams(pData)
	p.RespectCanCollide = true
	pcall(function()
		p:AddToFilter(self:GetFolder())
		p:AddToFilter(self:GetPoolFolder())
	end)
	pData._rockParams = p
	pData._raycastFn = function(origin, disp)
		return workspace:Raycast(origin, disp, p)
	end
end

-- Build the next `budget` chunk paths (all raycast cost lives here). Running first-impact /
-- rest accumulators finalize once every chunk is built; until then the write gate stays open.
local function buildTrajectories(pData, budget)
	local rig = pData._rig
	local rayFn = pData._raycastFn
	local scale = pData._curScale or 1
	local first = pData._trajBuilt + 1
	local last = math.min(pData._chunkCount, pData._trajBuilt + budget)
	for i = first, last do
		local traj = Trajectory.build(rig.spawnPos[i], rig.launchVel[i], rig.spawnRot[i], rig.launchAng[i],
			rig.halfExt[i], scale, rig.gravity[i], rig.bounciness[i], rig.friction[i], rayFn)
		rig.trajs[i] = traj
		if traj.impactT and traj.impactT < pData._firstImpactT then
			pData._firstImpactT = traj.impactT
			pData._firstHitInfo = traj.hit
		end
		-- A chunk that never rests (no ground in reach) must keep the write gate
		-- open for its whole life; latching at the max FINITE rest would freeze it
		-- mid-air and snap it far away when the sink phase re-opens the gate.
		if traj.restT == math.huge then
			pData._trajAnyEndless = true
		elseif traj.restT > pData._trajMaxRest then
			pData._trajMaxRest = traj.restT
		end
	end
	pData._trajBuilt = last
	if last >= pData._chunkCount then
		pData._maxRestT = (pData._trajMaxRest > 0 and not pData._trajAnyEndless) and pData._trajMaxRest or math.huge
	end
end

-- Per-burst path setup, shared by Emit / Animate / loop refresh: every chunk starts on a
-- ballistic placeholder, the first budget of real paths lands now, Update builds the rest.
local function startPhysics(self, pData)
	buildRockParams(self, pData)
	local rig = pData._rig
	pData._trajBuilt = 0
	pData._firstImpactT = math.huge
	pData._firstHitInfo = nil
	pData._trajMaxRest = 0
	pData._trajAnyEndless = false
	pData._maxRestT = math.huge
	pData._restWritten = false
	pData._hitsPending = pData._hitPerChunk and pData._chunkCount or 0
	for i = 1, pData._chunkCount do
		rig.trajs[i] = Trajectory.ballistic(rig.spawnPos[i], rig.launchVel[i], rig.spawnRot[i], rig.launchAng[i])
		rig.hitDone[i] = false
	end
	buildTrajectories(pData, TRAJ_BUILD_BUDGET)
end

local function fireChunkHit(self, pData, hit)
	local payload = EventsMod.makePayload(self, pData, "OnHit", nil)
	payload.HitInstance = hit.Instance
	payload.Other = hit.Instance
	payload.HitPosition = hit.Position
	payload.HitNormal = hit.Normal
	EventsMod.fire(self, pData, "OnHit", pData.EventChainCtx, payload)
end

-- Spawn one debris burst.
function Particle:EmitRocks(item, link, emitCtx)
	if not item or not item.Parent then return end
	local data = self:GetEmitData(item, emitCtx)
	if not data or not data.RenderTemplate then return end

	local lifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if lifeTime <= 0 then lifeTime = 0.001 end

	local model, rig = acquireRocks(data)
	local pData = PDataBuilder.build(item, data, model, rig, lifeTime, emitCtx, link)

	Particle._seedTsOverride(pData, item)
	if data.Pool ~= false then
		pData._sourceRT, pData._poolKind = data.RenderTemplate, "Rocks"
	end

	writeVisuals(pData, 0)
	model.Parent = data.EmitParent or self:GetFolder()
	startPhysics(self, pData)
	Pool.restoreTrails(model, "Rocks")
	ParticlesMod.EnableEmit(model, self:_makeAliveCheck())

	pData._nestedAlive = { true }
	self:_registerEmit(pData, emitCtx)
	NestedEmit.walk(self, data.RenderTemplate, model, pData._nestedAlive, emitCtx)
end

-- Animate mode: singleton looping burst per source (fresh rig, never pooled).
function Particle:EmitRocksAnimate(item, link, emitCtx)
	if not item or not item.Parent then return end
	if self.ActiveAnimates[item] then return end
	local data = self:GetEmitData(item, emitCtx)
	if not data or not data.RenderTemplate then return end

	local lifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if lifeTime <= 0 then lifeTime = 0.001 end

	local model, rig = buildRig(data)
	model:SetAttribute("_PartIcleEmit", true)
	local pData = PDataBuilder.build(item, data, model, rig, lifeTime, emitCtx, link)
	pData.IsAnimate = true
	pData.AnimateItem = item
	pData._animateLink = link

	Particle._seedTsOverride(pData, item)
	writeVisuals(pData, 0)
	model.Parent = data.EmitParent or self:GetFolder()
	startPhysics(self, pData)
	ParticlesMod.EnableEmit(model, self:_makeAliveCheck())

	pData._nestedAlive = { true }
	self.ActiveAnimates[item] = pData
	self:_registerEmit(pData, emitCtx)
	NestedEmit.walk(self, data.RenderTemplate, model, pData._nestedAlive, emitCtx)
end

-- Per-frame update: evaluate the predetermined paths at effective time (any
-- Timescale, any direction) + one BulkMoveTo; idles once everything is at rest.
function Particle:UpdateRocks(pData, dt, currentTime)
	-- Signed-reverse timescale header: see Lightning/init.luau UpdateLightning.
	local real_i = math.min(math.max((currentTime - pData.StartTime) / pData.LifeTime, 0), 1)
	local ts
	if pData._tsOverride ~= nil and currentTime < (pData._tsOverrideUntil or 0) then
		ts = pData._tsOverride
	else
		ts = pData.Graphs.Timescale and GraphMod.QueryPointsWithTime(real_i, pData.Graphs.Timescale, pData.Seeds.Timescale) or 1
	end
	local dtTs = dt * ts
	local lifeTime = pData.LifeTime
	local newEff = (pData._effectiveElapsed or 0) + (pData._timeFrozen and 0 or dtTs)
	if newEff < 0 then newEff = 0 end
	if newEff > lifeTime then newEff = lifeTime end
	pData._effectiveElapsed = newEff

	local model = pData.VisualPart
	if not model or not model.Parent then return true end
	if pData.TotalKeyFrames <= 0 then return true end
	local isDying = real_i >= 1 and (newEff >= lifeTime or newEff <= 0)

	if not isDying then
		local rig = pData._rig
		if pData._trajBuilt < pData._chunkCount then buildTrajectories(pData, TRAJ_BUILD_BUDGET) end
		local sinkPhase = pData._sinkOut and (newEff / lifeTime) > SINK_START
		if newEff < pData._maxRestT or sinkPhase or not pData._restWritten then
			local sinkEase = 0
			if sinkPhase then
				local e = ((newEff / lifeTime) - SINK_START) / (1 - SINK_START)
				sinkEase = e * e
			end
			for i = 1, pData._chunkCount do
				local traj = rig.trajs[i]
				if traj then
					local cf = Trajectory.evaluate(traj, newEff, rig.gravity[i])
					if sinkEase > 0 and newEff > traj.restT then
						-- Full burial along the rest surface normal: largest dimension
						-- (scaled) × 1.5 clears the surface with margin.
						local sz = rig.baseSize[i]
						local depth = math.max(sz.X, sz.Y, sz.Z) * math.max(pData._curScale or 1, 0.01) * 1.5
						cf = cf.Rotation + (cf.Position - (traj.restNormal or Vector3.yAxis) * (depth * sinkEase))
					end
					rig.writeCFs[i] = cf
					-- InheritFloor lands the moment the path says it does.
					if pData._inheritFloor and not rig.touched[i] and traj.impactT and newEff >= traj.impactT and traj.hit then
						rig.touched[i] = true
						local part = rig.parts[i]
						pcall(function()
							part.Material = traj.hit.Instance.Material
							part.Color = traj.hit.Instance.Color
						end)
						pData.SkipColor = true
					end
				end
			end
			workspace:BulkMoveTo(rig.parts, rig.writeCFs, Enum.BulkMoveMode.FireCFrameChanged)
			-- One flush past rest, then idle until sink or reversed time.
			pData._restWritten = newEff >= pData._maxRestT and not sinkPhase
		end
		-- OnHit from the precomputed impacts: once per burst at the earliest, or per chunk.
		if pData.Events and pData.Events.OnHit then
			if pData._hitPerChunk then
				if pData._hitsPending > 0 then
					for i = 1, pData._chunkCount do
						local traj = rig.trajs[i]
						if not rig.hitDone[i] and traj.impactT and traj.hit and newEff >= traj.impactT then
							rig.hitDone[i] = true
							pData._hitsPending -= 1
							fireChunkHit(self, pData, traj.hit)
						end
					end
				end
			elseif not pData._hitFired and pData._trajBuilt >= pData._chunkCount
				and pData._firstHitInfo and newEff >= pData._firstImpactT then
				pData._hitFired = true
				fireChunkHit(self, pData, pData._firstHitInfo)
			end
		end
	end

	local targetStep = math.floor(math.min(math.max(newEff / lifeTime, 0), 1) * pData.TotalKeyFrames)
	if targetStep ~= pData.CurrentStep then
		pData.CurrentStep = targetStep
		writeVisuals(pData, targetStep / pData.TotalKeyFrames)
	end

	return isDying
end

-- AnimateLoop per-cycle refresh (EngineReplay dispatch): re-roll every chunk from
-- the source's CURRENT pose, rebuild paths, restart physics; rebuild the rig on
-- layout change.
function Particle:_refreshRocksAnimate(pData, freshData)
	-- Generic replay assigns pData.Link from freshData; Rocks never links post-emit.
	pData.Link = nil
	pData._sinkOut = freshData.SinkOut ~= false
	pData._inheritFloor = freshData.InheritFloor == true
	pData._hitPerChunk = freshData.HitPerChunk == true
	pData._hitFired = false
	pData.SkipColor = nil

	local expected = chunkCapFor(freshData)
	if expected ~= pData._rig.chunkCap and freshData.RenderTemplate then
		local oldModel = pData.VisualPart
		local parent = oldModel and oldModel.Parent
		local model, rig = buildRig(freshData)
		model:SetAttribute("_PartIcleEmit", true)
		pData.VisualPart = model
		pData._rig = rig
		model.Parent = parent or self:GetFolder()
		if oldModel then pcall(function() oldModel:Destroy() end) end
	end

	local link = pData._animateLink
	local originCF
	if link and link.Parent then
		originCF = Constants.resolveLinkCFrame(link)
	end
	local src = pData.AnimateItem
	if not originCF and src and src.Parent then originCF = src.CFrame end
	-- Rebuilt rigs need the same WorldPivot stamp PDataBuilder.build gives fresh ones.
	if originCF then pcall(function() pData.VisualPart.WorldPivot = originCF end) end

	local rig = pData._rig
	PDataBuilder.rollChunks(pData, freshData, rig, originCF or CFrame.new())
	writeVisuals(pData, 0)
	startPhysics(self, pData)
end

end
