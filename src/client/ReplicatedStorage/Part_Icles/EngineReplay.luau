--[[
	EngineReplay Mixin  -  AnimateLoop cycle reset + replay, split from Engine.luau
	(500-line cap). Engine's death branch calls _replayAnimateCycle when the source
	item still has AnimateLoop=true; the body re-reads properties so live edits take
	effect each cycle, resets motion/collision/graph state, re-fires nested emits,
	and restarts the cycle clock. Caller keeps the pData in ActiveEmits.
]]

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local Constants = require(script.Parent.PartConstants)
local LinkCF = require(script.Parent.LinkCF)
local Pool = require(script.Parent.Pool)
local StaticPass = require(script.Parent.StaticPass)
local AxisLinksMod = require(script.Parent.AxisLinks)
local NestedEmitMod = require(script.Parent.NestedEmit)
local Turbulence = require(script.Parent.Turbulence)
local DecalLayersMod = require(script.Parent.DecalLayers)
local MeshFramesMod = require(script.Parent.MeshFrames)

return function(Particle)

-- Reset every per-cycle field and replay one AnimateLoop cycle. Must mirror the
-- emit-time setup in the per-type Emit paths; Engine.luau is the only caller.
function Particle:_replayAnimateCycle(pData, currentTime)
	-- Reset and replay  -  re-read properties so live edits take effect.
	pData.StartTime = currentTime
	pData.CurrentStep = 0
	if pData.AccumulatedDT then pData.AccumulatedDT = 0 end
	if pData.InitialLocalCF then pData.LocalCF = pData.InitialLocalCF end
	if pData.AccRotX then pData.AccRotX = 0; pData.AccRotY = 0; pData.AccRotZ = 0 end
	-- Reset accumulated target-acceleration velocity so each loop iteration
	-- starts fresh from the base trajectory.
	if pData.TargetVel then pData.TargetVel = Vector3.zero end
	-- Reset OnHit Collision-mode state so each cycle replays from a clean
	-- slate (otherwise _collisionStopped / spin / SpeedMultiplier / reflected
	-- _accelVel compound across cycles). BaseDirection restored from the
	-- emit-time snapshot.
	pData._collisionStopped = false
	pData._spinRate = Vector3.zero
	pData._spinAccumX = 0
	pData._spinAccumY = 0
	pData._spinAccumZ = 0
	pData.SpeedMultiplier = 1
	if pData._accelVel then pData._accelVel = Vector3.zero end
	if pData._prevWorldOff then
		pData._prevWorldOff = Vector3.zero
		-- Drop OnHit-bounce mirror axes so each AnimateLoop cycle starts
		-- with un-mirrored trajectory state matching emit-time baseline.
		pData._displacementMirrorX = nil
		pData._displacementMirrorY = nil
		pData._displacementMirrorZ = nil
		-- Apply PosOffset(0) so cycle restart matches emit-time spawn pose
		-- (front-loaded curves would otherwise pop on the first step).
		if pData.HasPosOffsetGraphs and pData.Graphs and pData.SpawnRotation then
			local oX = pData.Graphs.PosOffsetX and GraphMod.QueryPointsWithTime(0, pData.Graphs.PosOffsetX, pData.Seeds.PosOffsetX) or 0
			local oY = pData.Graphs.PosOffsetY and GraphMod.QueryPointsWithTime(0, pData.Graphs.PosOffsetY, pData.Seeds.PosOffsetY) or 0
			local oZ = pData.Graphs.PosOffsetZ and GraphMod.QueryPointsWithTime(0, pData.Graphs.PosOffsetZ, pData.Seeds.PosOffsetZ) or 0
			if oX ~= 0 or oY ~= 0 or oZ ~= 0 then
				local worldOff = Constants.resolveDisplacement(Vector3.new(oX, oY, oZ),
					pData.DisplacementMode or "Global", pData.SpawnRotation, pData.SpawnEmitterRotation)
				pData._prevWorldOff = worldOff
				pData.LocalCF = pData.LocalCF + worldOff
				if pData.VisualPart and pData.VisualPart.Parent then
					if pData.Type == "Model" then
						pcall(function() pData.VisualPart:PivotTo(pData.VisualPart:GetPivot() + worldOff) end)
					else
						pData.VisualPart.CFrame = pData.VisualPart.CFrame + worldOff
					end
				end
			end
		end
	end
	-- Stale-data fallback; the freshData path below re-rolls via Turbulence.buildInto.
	Turbulence.reprime(pData)
	if pData._initialBaseDirection then pData.BaseDirection = pData._initialBaseDirection end
	pData._lastOrientPos = nil
	-- Reset LinkTrack base (`_localWorldCF`) and overlay base (`_postUpdateCF`)
	-- so that on the first no-step frames of the new cycle, ApplyOrientation /
	-- ApplyZOffset compose against the replay's initial pose, not the last
	-- cycle's terminal pose.
	pData._localWorldCF, pData._postUpdateCF = pData.InitialLocalCF, pData.InitialLocalCF
	-- Clear GraphBlender state-search caches so next frame's monotonic-t search
	-- restarts from index 1. Otherwise the cached lastIdx points past the new
	-- t≈0, the search no-ops, and LerpGraph extrapolates with a negative alpha.
	pData._lastTransIdx = nil; pData._lastColorIdx = nil
	-- Stale-data fallback if freshData is nil. Fresh-data path overrides
	-- this AFTER the per-cycle refresh so the new Timescale + LifeTime apply.
	pData._effectiveElapsed = GraphMod.InitialEffectiveElapsed(pData.Graphs and pData.Graphs.Timescale, pData.Seeds and pData.Seeds.Timescale, pData.LifeTime)
	pData._hitHistory = nil
	if pData.Type == "ImageLabel" then pData.PosX = 0; pData.PosY = 0; pData.EnvVelX = 0; pData.EnvVelY = 0; pData.AccRot = 0 end
	local freshData = self:GetEmitData(pData.AnimateItem, pData._playOverrides and { Overrides = pData._playOverrides } or nil)
	if freshData then
		pData.Events = freshData.Events
		pData._killedManually = false
		pData._fireOnDeathOverride = false
		pData._hitFired = false
		pData.LifeTime = RangeMod.RandomValueFromRange(freshData.Lifetime)
		if pData.LifeTime <= 0 then pData.LifeTime = 0.001 end
		pData.TotalKeyFrames = math.max(1, freshData.TotalKeyFrames)
		if freshData.ParticleData then
			pData.Acceleration = freshData.ParticleData.Acceleration
			pData.Drag = freshData.ParticleData.Drag
			pData.HasDrag = freshData.ParticleData.Drag ~= 0
			pData.HasAccel = freshData.ParticleData.Acceleration.Magnitude > 0
		end
		-- Refresh cached flags that affect simulation behavior. Loop-restart honors
		-- live edits to AccelerationTowardsInstance / AccelTarget / InvertMotion.
		-- Target-accel is frame-granularity in branches 3/4 (one sample per
		-- Heartbeat) so it doesn't force NeedsFullIteration; only VelocityVectored
		-- does, because direction feedback requires per-step CFrame writes.
		pData.InvertMotion = freshData.InvertMotion or false
		pData.AccelTarget = freshData.AccelTarget
		pData.HasTargetAccel = freshData.AccelerationTowardsInstance == true and freshData.AccelTarget ~= nil and freshData.AccelStrength ~= nil and not pData.InvertMotion
		pData.TargetVel = Vector3.zero
		if freshData.VelocityVectored ~= nil then pData.VelocityVectored = freshData.VelocityVectored end
		pData.NeedsFullIteration = pData.VelocityVectored or false
		if freshData.RotMode then pData.RotMode = freshData.RotMode; pData.NeedsRotAccum = (freshData.RotMode == "Speed") and not (pData.VelocityVectored or false) end
		-- Refresh Link + LinkMode so a mid-loop LinkSource flip (None → Camera)
		-- takes effect on the next animate cycle. ReapplyLink reads pData.Link
		-- per frame, so updating it here is enough.
		-- Nested-driven pData keep their link (and a frozen frame if the parent already died).
		if not pData._nestedDriven then
			pData.Link = pData._playLink or freshData.Link
			pData._frozenLinkCF = nil
		end
		pData.LinkMode = freshData.LinkMode
		pData.LinkAxes = freshData.LinkAxes
		pData._linkMaskRefCF = nil
		if pData.Link then pData._linkGen = Pool.linkGen(pData.Link) end
		LinkCF.captureEmitFrame(pData)
		-- RigidLocal: re-snapshot the link's current pose so each new cycle
		-- locks to where the emitter is NOW, not where it was at first emit.
		if pData.Link and pData.Link.Parent then
			pData._rigidLocalParentCF = LinkCF.rigidWorldSnapshot(pData.LinkMode, pData.Link, pData._linkLocal, pData.LinkAxes, pData._linkMaskRefCF) or pData._rigidLocalParentCF
		end
		-- Refresh non-spatial setup fields via the per-type helpers. Spatial
		-- LocalCF rebuild (3D) and image-display refresh (2D) live in those helpers.
		if pData.Type == "ImageLabel" then
			self:_refreshImageLabelAnimateNonSpatial(pData, freshData)
		elseif pData.Type == "Lightning" then
			-- Also nils pData.Link (the generic assignment above set it).
			self:_refreshLightningAnimate(pData, freshData)
		elseif pData.Type == "CameraShake" then
			-- No VisualPart; the generic non-spatial refresh would index it.
			self:_refreshCameraShakeAnimate(pData, freshData)
		elseif pData.Type == "Rocks" then
			self:_refreshRocksAnimate(pData, freshData)
		elseif pData.Type == "Rope" then
			-- Pose-preserving: point buffers survive unless the chain layout changed.
			self:_refreshRopeAnimate(pData, freshData)
		elseif pData.Type == "Distortion" then
			-- No VisualPart; per-kind phase policy (Noise/Wave continuous, Ripple restarts).
			self:_refreshDistortionAnimate(pData, freshData)
		else
			self:_refreshAnimateNonSpatial(pData, freshData)
		end
		-- Restore any graphs the prior cycle's StaticPass nil'd so refreshLoopGraphsAndSeeds'
		-- pairs(pData.Graphs) iteration picks them up. Static-pass at end of block
		-- re-detects + re-nils as appropriate.
		StaticPass.restoreFromFreshData(pData, freshData)
		AxisLinksMod.refreshLoopGraphsAndSeeds(pData, freshData, GraphMod)
		-- Re-read Turbulence per cycle (0→nonzero edits take effect). Non-invert
		-- items re-roll the noise seed each cycle; InvertMotion items keep the
		-- Seeds._turbSeed the pre-sim rolled so the rebuilt cache stays in sync.
		if pData.Type == "Part" or pData.Type == "Attachment" or pData.Type == "Model" then
			Turbulence.buildInto(pData, freshData)
		end
		-- Re-detect static graphs from fresh pData.Graphs. Idempotent: clears
		-- stale _static<Name> fields so a graph switched from static→dynamic mid-
		-- cycle re-arms the per-frame sample path. ImageLabel SizeScale both-axes-
		-- static collapse mirrored from buildImageLabelPData so the per-frame Size
		-- block short-circuits (frame-0 wrote the constant Size).
		StaticPass.apply(pData)
		if pData.Type == "ImageLabel"
			and pData._staticSizeScaleX and pData._staticSizeScaleY then
			pData._staticSizeScaleX = nil
			pData._staticSizeScaleY = nil
		end
		-- Must run after fresh Timescale graph + LifeTime are in place.
		pData._effectiveElapsed = GraphMod.InitialEffectiveElapsed(pData.Graphs and pData.Graphs.Timescale, pData.Seeds and pData.Seeds.Timescale, pData.LifeTime)
		-- Distortion phase reseed reads the recompute above (Distortion/init.luau).
		if pData.Type == "Distortion" then
			self:_reseedDistortionPhase(pData)
		end
		-- ImageLabel InvertMotion: re-seed end-state for next cycle (mirrors the
		-- emit-time setup in buildImageLabelPData) so each cycle integrates from
		-- the inverted end-pose with negative dt.
		if pData.Type == "ImageLabel" then
			-- ImgInvertMotion lives under its raw attribute name (GetData reads it
			-- directly, no TypeRegistry attrName mapping into freshData.InvertMotion).
			pData.InvertMotion = freshData.ImgInvertMotion or false
			if pData.InvertMotion then
				local endX, endY, endVelX, endVelY = self:_computeImageLabelEndState(freshData, pData.DirX or 0, pData.DirY or 0, pData.LifeTime, pData.Seeds)
				pData.PosX, pData.PosY = endX, endY
				pData.EnvVelX, pData.EnvVelY = endVelX, endVelY
				pData._effectiveElapsed = pData.LifeTime
				pData._invertDtSign = -1
			else
				pData._invertDtSign = nil
			end
		end
		-- Rebuild SimLocalCFrames whenever InvertMotion is true. Loop restart
		-- can land on a different InvertMotion / TotalKeyFrames than the last
		-- cycle, and inverted UpdatePart indexes the cache by step. Drop the
		-- cache on InvertMotion=false so a later flip-on triggers a fresh build.
		if pData.InvertMotion and pData.AnimateItem and pData.AnimateItem.Parent then
			local restartCF
			local isAttachment = pData.Type == "Attachment"
			if pData.Type == "Model" then
				local ok, cf = pcall(function() return pData.AnimateItem:GetPivot() end)
				if ok then restartCF = cf end
			elseif isAttachment then
				-- Parent-local; matches EmitAnimate's `localCF = attachment.CFrame`.
				restartCF = pData.AnimateItem.CFrame
			elseif pData.AnimateItem:IsA("BasePart") then
				restartCF = pData.AnimateItem.CFrame
			end
			if restartCF then
				local ok2, sim, effTKF = pcall(function()
					if isAttachment then
						return self:PreSimulateAttachmentForward(freshData, pData.Seeds, restartCF, pData.BaseDirection, pData.SpreadRotation, pData.LifeTime, nil, pData.SpawnEmitterRotation)
					else
						return self:PreSimulateForward(freshData, pData.Seeds, restartCF, pData.BaseDirection, pData.SpreadRotation, pData.Link, pData.LifeTime, nil, pData.SpawnEmitterRotation, pData._linkLocal)
					end
				end)
				if ok2 then
					pData.SimLocalCFrames = sim
					if effTKF then pData.TotalKeyFrames = effTKF end
				end
			end
		elseif not pData.InvertMotion then
			pData.SimLocalCFrames = nil
		end
		-- Beam: rebuild AnimatedProps + GraphBlender states from fresh data. Also
		-- refresh cached _baseWidth0/Width1/CurveSize0/CurveSize1/TextureLength/
		-- Segments from the source's CURRENT values so live edits to non-animated
		-- graph props propagate into the next animate-loop iteration.
		if pData.Type == "Beam" and freshData.BeamProps then
			local vb = pData.VisualPart
			local ap = {}
			for name, sequence in pairs(freshData.BeamProps) do
				if sequence then
					if GraphMod.IsStatic(sequence) then
						if vb then vb[name] = GraphMod.GetStaticValue(sequence, vb[name]) end
					else ap[name] = { Sequence = sequence, Seed = GraphMod.GenerateSeed(sequence) } end
				end
			end
			pData.AnimatedProps = ap
			if vb then
				pData._baseWidth0 = vb.Width0
				pData._baseWidth1 = vb.Width1
				pData._baseCurveSize0 = vb.CurveSize0
				pData._baseCurveSize1 = vb.CurveSize1
				pData._baseTextureLength = vb.TextureLength
				pData._baseSegments = vb.Segments
			end
			if ap.TextureSpeed and vb then vb.TextureSpeed = 0 end
			if freshData.GraphBlender then
				local ts, cs = GraphMod.CollectGraphStates(freshData.GraphBlender)
				pData.TransStates = ts; pData.ColorStates = cs
				local tmt = {}; for idx = 1, #ts - 1 do tmt[idx] = GraphMod.PrecomputeMergedTimes(ts[idx].Graph, ts[idx+1].Graph) end
				local cmt = {}; for idx = 1, #cs - 1 do cmt[idx] = GraphMod.PrecomputeMergedColorTimes(cs[idx].Graph, cs[idx+1].Graph) end
				pData.TransMergedTimes = tmt; pData.ColorMergedTimes = cmt
				if #ts > 0 and vb then vb.Transparency = ts[1].Graph end
				if #cs > 0 and vb then vb.Color = cs[1].Graph end
			end
		end
		if freshData.PLRange then pData.PLRange = freshData.PLRange end
		if freshData.PLBrightness then pData.PLBrightness = freshData.PLBrightness end
		if freshData.PLColor then pData.PLColor = freshData.PLColor end
	end
	-- Animate-loop replay reset target: read source's CURRENT CFrame each cycle so
	-- parent moves carry through (cached InitialAnchorCF would freeze at emit-time pose).
	-- Lightning / Rocks / CameraShake / Rope skipped: their VisualPart is a rig Model or
	-- nil (the un-pcall'd BasePart-source write below would error) and their per-type
	-- refresh already re-rolled from the source's current pose.
	if pData.Type ~= "Lightning" and pData.Type ~= "Rocks" and pData.Type ~= "CameraShake" and pData.Type ~= "Rope" and pData.Type ~= "Distortion"
		and pData.AnimateItem and pData.AnimateItem.Parent and pData.VisualPart and pData.VisualPart.Parent then
		if pData.Type == "Model" then
			local ok, sourceCF = pcall(function() return pData.AnimateItem:GetPivot() end)
			if ok and sourceCF then pData.VisualPart:PivotTo(sourceCF) end
		elseif pData.AnimateItem:IsA("BasePart") then
			pData.VisualPart.CFrame = pData.AnimateItem.CFrame
		elseif pData.AnimateItem:IsA("Attachment") then
			-- RT is a CHILD of the source Attachment; identity preserves the
			-- parent-local invariant established by Transform.luau:96. Writing
			-- source.CFrame here bakes the source's own offset INTO the RT.
			pData.VisualPart.CFrame = CFrame.new()
		end
	end
	-- Nested re-emit on AnimateLoop cycle restart. Per-iteration re-fire is required because
	-- nested children's emit cycle is finite (EmissionMode=Emit) or replaces its pData
	-- (EmissionMode=Animate). Nested-driven, so _emitGen is bypassed and prior cycles' nested
	-- closures keep flying (the parent's _nestedAlive stays true across cycles).
	if pData.AnimateItem and pData.VisualPart and pData.VisualPart.Parent then
		-- Rebuild the ctx so cycle 2+ children stay in the same chain and play as cycle 1.
		local replayCtx = { ChainCtx = pData.EventChainCtx, _playToken = pData._playToken }
		if pData.Type == "Lightning" or pData.Type == "Rocks" or pData.Type == "Rope" then
			-- Rig clones strip Transformed children (copyBare); nested emitters live
			-- in the SOURCE RT and fire against the rig Model as link.
			local freshLn = self:GetData(pData.AnimateItem)
			if freshLn and freshLn.RenderTemplate then
				NestedEmitMod.walk(self, freshLn.RenderTemplate, pData.VisualPart, pData._nestedAlive, replayCtx, pData._scaleNode or pData.ParentScale)
			end
		elseif pData.Type == "Part" or pData.Type == "Attachment" or pData.Type == "Model" then
			-- Live RT is both source and link; pruned, nested-driven like the first cycle.
			NestedEmitMod.walk(self, pData.VisualPart, pData.VisualPart, pData._nestedAlive, replayCtx, pData._scaleNode or pData.ParentScale)
		end
	end
	self:_fireAnimateCycleRestartEvents(pData)
end

-- AnimateLoop refresh of non-spatial fields. Spatial state stays (full rebuild is per-type).
function Particle:_refreshAnimateNonSpatial(pData, freshData)
	if not freshData then return end
	if freshData.EmissionDirection then pData.EmissionDirection = freshData.EmissionDirection end
	if freshData.Orientation then pData.Orientation = freshData.Orientation end
	if freshData.ZOffset ~= nil then pData.ZOffset = freshData.ZOffset end
	if freshData.RotOrder then pData.RotOrder = freshData.RotOrder end
	if freshData.PartLife ~= nil then pData.PartLife = freshData.PartLife end
	DecalLayersMod.refresh(pData, freshData)
	MeshFramesMod.refresh(pData, freshData)
	-- Timescale attrName variants per type; exactly one is set.
	local tsG = freshData.Timescale or freshData.BeamTimescale or freshData.AtmTimescale or freshData.PLTimescale
	if tsG and pData.Graphs then pData.Graphs.Timescale = tsG; pData.Seeds.Timescale = GraphMod.GenerateSeed(tsG) end
	if freshData.ParticleData and freshData.ParticleData.SpreadAngle then
		local sa = freshData.ParticleData.SpreadAngle
		local rx, ry = 0, 0
		if sa.X > 0 or sa.Y > 0 then
			rx = (math.random() * 2 - 1) * sa.X
			ry = (math.random() * 2 - 1) * sa.Y
		end
		pData.SpreadRotation = CFrame.Angles(math.rad(rx), math.rad(ry), 0)
	end
end

end
