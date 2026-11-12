--[[
	Lifecycle Mixin  -  cancelAnimation, Particle:Disable, EmitAnimate, EnableEmit.
	`_emitGen` attribute: each EnableEmit bumps + captures locally; delayed closures
	bail when live attribute has moved on. Disable also bumps to cancel pending closures.
]]

local Selection = game:GetService("Selection")
local RunService = game:GetService("RunService")
local IS_STUDIO = RunService:IsStudio()
-- Probe Plugin capability via Selection:Get; gates IsEdit + Selection sites below.
local IS_PLUGIN = pcall(function() return Selection:Get() end)
-- loopBody emit yield: PreRender on client so the resumed emit lands after Roblox's
-- attachment-transform propagation completes for the frame; Trail's first sample then
-- reads the clean spawn pose. Server falls back to Heartbeat (PreRender client-only).
local LOOP_YIELD_EVENT = RunService:IsClient() and RunService.PreRender or RunService.Heartbeat
local TypeRegistry = require(script.Parent.TypeRegistry)
local ParticlesMod = require(script.Parent.Particles)
local Events = require(script.Parent.Events)
local EvenCycle = require(script.Parent.EvenCycle)
local EngineAttr = require(script.Parent.EngineAttr)
local Log = require(script.Parent.Log)
local DecalLayersMod = require(script.Parent.DecalLayers)
local MeshFramesMod = require(script.Parent.MeshFrames)

return function(Particle)
	-- Cancel an in-flight Animate cycle: restore position, clean up, remove from ActiveEmits.
	-- Beam restores via snapshot + Enabled=false (no InitialAnchorCF on Beam pData).
	local function cancelAnimation(self, item)
		local existing = self.ActiveAnimates[item]
		if not existing then return end
		-- Snapshot-restore runs BEFORE the CFrame write below: with the inverse order,
		-- one Heartbeat frame could render the visual at initial-pose still carrying the
		-- final-cycle Width/Color/Transparency = visible 1-frame pop on cancel.
		if (existing.Type == "Beam" or existing.Type == "Highlight" or existing.Type == "TrailEmitter")
			and existing.VisualPart and existing.VisualPart.Parent then
			local snap = existing.BeamSnapshot or existing.HighlightSnapshot or existing.TrailEmitterSnapshot
			if snap then
				pcall(function()
					for name, value in pairs(snap) do existing.VisualPart[name] = value end
				end)
			end
			existing.VisualPart.Enabled = false
		end
		if existing.InitialAnchorCF and existing.VisualPart and existing.VisualPart.Parent then
			if existing.Type == "Model" then
				existing.VisualPart:PivotTo(existing.InitialAnchorCF)
				if existing.InitialScale then
					pcall(function() existing.VisualPart:ScaleTo(existing.InitialScale) end)
				end
			elseif existing.Type ~= "Beam" then
				existing.VisualPart.CFrame = existing.InitialAnchorCF
			end
		end
		-- Part/Attachment hide via Transparency=1 (mirrors finishAnimate in init.luau).
		if (existing.Type == "Part" or existing.Type == "Attachment") and existing.VisualPart and existing.VisualPart.Parent then
			DecalLayersMod.restore(existing)
			MeshFramesMod.restore(existing)
			pcall(function()
				existing.VisualPart.Transparency = 1
				if existing.HasDecal then
					local d = existing.VisualPart:FindFirstChildOfClass("Decal")
					if d then d.Transparency = 1 end
				end
			end)
		end
		if (existing.Type == "Screen" or existing.Type == "ImageLabel" or existing.Type == "Lightning" or existing.Type == "Rocks" or existing.Type == "Rope") and existing.VisualPart then
			-- Lightning / Rocks / Rope are clone-animate: source RT never mutated, nothing to restore.
			pcall(function() existing.VisualPart:Destroy() end)
			if existing._impactDisk then pcall(function() existing._impactDisk:Destroy() end) end
		end
		-- Native PE/Trail children clean themselves up via gen-token; no manual disable here.
		self:_reclaimPData(existing)
		for idx = #self.ActiveEmits, 1, -1 do
			if self.ActiveEmits[idx] == existing then
				local n = #self.ActiveEmits
				if idx < n then self.ActiveEmits[idx] = self.ActiveEmits[n] end
				self.ActiveEmits[n] = nil
				break
			end
		end
		self.ActiveAnimates[item] = nil
	end

	-- Public wrapper for Particle:Deactivate.
	function Particle:_cancelAnimation(item)
		cancelAnimation(self, item)
	end

	-- Stop new emission on `item`. hard=true restores Animate sources now (cancelAnimation)
	-- and hard-cancels raw descendants; hard=false soft-stops them (Enabled=false) so live
	-- particles finish their Lifetime. Order matters: cancelAnimation before cfg.Enabled.
	local function haltEmission(self, item, hard)
		if Particle.ActiveLoops[item] then
			task.cancel(Particle.ActiveLoops[item])
			Particle.ActiveLoops[item] = nil
		end
		local chainBucket = Particle.ActiveChainLoops[item]
		if chainBucket then
			for _, t in ipairs(chainBucket) do pcall(task.cancel, t) end
			Particle.ActiveChainLoops[item] = nil
		end
		EngineAttr.write(item, "AnimateLoop", false)
		local gen = (item:GetAttribute("_emitGen") or 0) + 1
		EngineAttr.write(item, "_emitGen", gen)
		if hard then cancelAnimation(self, item) end
		local config = TypeRegistry.getConfig(item)
		if config then EngineAttr.write(config, "Enabled", false) end
		EngineAttr.write(item, "_PartIclePlaying", nil)
		-- Reset this emitter's rolling cycle so the next emission restarts at idx 1.
		-- Transformed descendants clear their own keys via the recursion below.
		EvenCycle.clear(self._evenCycleStore, item:GetAttribute("_EvenCycleId") or item)
		for _, desc in ipairs(item:GetDescendants()) do
			if desc:GetAttribute("Transformed") then
				if hard then self:Disable(desc) else self:SoftDisable(desc) end
			elseif TypeRegistry.isInsideRenderTemplate(desc, item) then
				-- RenderTemplate natives are template state copied verbatim into clones; Transform owns them.
			elseif desc:IsA("ParticleEmitter") or desc:IsA("Trail") then
				if hard then ParticlesMod.CancelNative(desc) else pcall(function() desc.Enabled = false end) end
			elseif desc:IsA("Beam") or desc:IsA("Highlight") then
				pcall(function() desc.Enabled = false end)
			end
		end
	end

	-- Hard stop: halt emission AND reclaim every live clone now (sweep ActiveEmits + finish
	-- linger). Waypoint pair (Studio edit only; standalone-runtime skips it) makes the whole
	-- disable one undo step.
	function Particle:Disable(item)
		if not item then return end
		-- Inside the Heartbeat loop (event Modules run there): queue so the ActiveEmits sweep cannot
		-- pull entries out from under the step. Engine drains _afterStep after the loop.
		if self._inStep then
			self._afterStep = self._afterStep or {}
			table.insert(self._afterStep, function() self:Disable(item) end)
			return
		end
		local CHS = IS_PLUGIN and game:GetService("RunService"):IsEdit() and game:GetService("ChangeHistoryService") or nil
		if CHS then CHS:SetWaypoint("Part-Icles: Before Disable") end
		haltEmission(self, item, true)
		-- Reclaim live one-shots (backward walk = swap-and-pop safe); _releaseOrDestroy pools
		-- eligible visuals instead of cold-destroying them.
		local active = self.ActiveEmits
		for idx = #active, 1, -1 do
			local pData = active[idx]
			if pData and pData._sourceItem == item then
				if pData.VisualPart and pData.VisualPart.Parent then
					self:_releaseOrDestroy(pData, pData.VisualPart)
				end
				self:_reclaimPData(pData)
				-- _releaseOrDestroy may already have popped a live-RT Animate entry via cancelAnimation.
				if active[idx] == pData then
					local n = #active
					if idx < n then active[idx] = active[n] end
					active[n] = nil
				end
			end
		end
		-- Finish PartLife linger clones early; _lingerCounted guards a double-decrement.
		if self._lingerByItem and self._lingerByItem[item] then
			for _, visualPart in ipairs(self._lingerByItem[item]) do
				if visualPart then
					local counted = false
					pcall(function() counted = visualPart:GetAttribute("_lingerCounted") == true end)
					if counted then
						self._lingerVisualCount = math.max(0, (self._lingerVisualCount or 0) - 1)
						EngineAttr.write(visualPart, "_lingerCounted", nil)
					end
					if visualPart.Parent then
						pcall(function() visualPart:Destroy() end)
					end
				end
			end
			self._lingerByItem[item] = nil
		end
		if CHS then CHS:SetWaypoint("Part-Icles: Disable") end
	end

	-- Skip descendants under a nested Transformed item (recursion reaches them separately).
	local function _hasTransformedAncestor(desc, root)
		local p = desc.Parent
		while p and p ~= root do
			if p:GetAttribute("Transformed") then return true end
			p = p.Parent
		end
		return false
	end

	-- Recursive enable. Walks `item` + descendants:
	--   - Transformed item → cfg.Enabled=true + :Enable(math.huge). Sets _PartIclePlaying
	--     first so the EnabledLoop listener bails (prevents double-Enable / 1-frame pop).
	--   - Raw PE / Trail / Beam → .Enabled=true.
	--   - Container → walks descendants once, recurses children with `_parentCovered` so raw
	--     descendants don't double-toggle.
	function Particle:AbsoluteEnable(item, _parentCovered)
		if not item then return end
		if item:GetAttribute("Transformed") then
			-- Set _PartIclePlaying BEFORE flipping cfg.Enabled so EnabledLoop.handleToggle
			-- bails on the attribute change (it gates on _PartIclePlaying). Otherwise the
			-- direct Enable below and the listener's handleToggle both spawn loopBody,
			-- causing a cancel+restart pop on every AbsoluteEnable call (visible 1-frame
			-- artifact on Animate mode, off-by-one emit shift on Emit mode). Particle:Disable
			-- clears the attribute on the matching AbsoluteDisable.
			EngineAttr.write(item, "_PartIclePlaying", true)
			local config = TypeRegistry.getConfig(item)
			if config then EngineAttr.write(config, "Enabled", true) end
			-- Direct Enable call covers standalone-runtime (no listener to react to attribute).
			self:Enable(item, nil, math.huge)
			return
		end
		if item:IsA("ParticleEmitter") or item:IsA("Trail") or item:IsA("Beam") then
			if _parentCovered then return end
			pcall(function() item.Enabled = true end)
			return
		end
		local shouldCover = (item:IsA("BasePart") or item:IsA("Attachment") or item:IsA("Model")) and not _parentCovered
		if shouldCover then
			for _, desc in ipairs(item:GetDescendants()) do
				if (desc:IsA("ParticleEmitter") or desc:IsA("Trail") or desc:IsA("Beam"))
					and not desc:GetAttribute("Transformed")
					and not _hasTransformedAncestor(desc, item) then
					pcall(function() desc.Enabled = true end)
				end
			end
		end
		local covered = shouldCover or _parentCovered
		for _, child in item:GetChildren() do
			if item:IsA("BasePart") and child:IsA("BasePart") and not child:GetAttribute("Transformed") then
				continue
			end
			self:AbsoluteEnable(child, covered)
		end
	end

	-- Soft stop: halt new emission but leave live clones for the Heartbeat to age out (no
	-- ActiveEmits sweep, no linger destroy, no cancelAnimation) so on-screen clones finish
	-- their Lifetime instead of vanishing this frame.
	function Particle:SoftDisable(item)
		if not item then return end
		local CHS = IS_PLUGIN and game:GetService("RunService"):IsEdit() and game:GetService("ChangeHistoryService") or nil
		if CHS then CHS:SetWaypoint("Part-Icles: Before Soft Disable") end
		haltEmission(self, item, false)
		if CHS then CHS:SetWaypoint("Part-Icles: Soft Disable") end
	end

	-- Recursive disable. Walks `item` + descendants, soft-stopping each:
	--   - Transformed item → :SoftDisable (stop new emission, live particles finish Lifetime).
	--   - Raw PE / Trail / Beam → .Enabled=false (native soft stop).
	--   - Container → walks descendants once, recurses children with `_parentCovered` flag.
	-- For an instant scene-clear that reclaims live clones, call :Disable per item instead.
	function Particle:AbsoluteDisable(item, _parentCovered)
		if not item then return end
		if item:GetAttribute("Transformed") then
			self:SoftDisable(item)
			return
		end
		if item:IsA("ParticleEmitter") or item:IsA("Trail") or item:IsA("Beam") then
			if _parentCovered then return end
			pcall(function() item.Enabled = false end)
			return
		end
		local shouldCover = (item:IsA("BasePart") or item:IsA("Attachment") or item:IsA("Model")) and not _parentCovered
		if shouldCover then
			for _, desc in ipairs(item:GetDescendants()) do
				if (desc:IsA("ParticleEmitter") or desc:IsA("Trail") or desc:IsA("Beam"))
					and not desc:GetAttribute("Transformed")
					and not _hasTransformedAncestor(desc, item) then
					pcall(function() desc.Enabled = false end)
				end
			end
		end
		local covered = shouldCover or _parentCovered
		for _, child in item:GetChildren() do
			if item:IsA("BasePart") and child:IsA("BasePart") and not child:GetAttribute("Transformed") then
				continue
			end
			self:AbsoluteDisable(child, covered)
		end
	end

	-- Start one Animate cycle. 3D = animate source in-place; Screen/ImageLabel = singleton clone.
	function Particle:EmitAnimate(item, link, emitCtx)
		self:_warnIfNotActivated("EmitAnimate")
		local isCloneAnimate = item:IsA("BlurEffect")
			or item:IsA("BloomEffect")
			or item:IsA("ColorCorrectionEffect")
			or item:IsA("Atmosphere")
			or item:IsA("ImageLabel")
			or Particle._isLightning(item)
			or Particle._isCameraShake(item)
			or Particle._isRocks(item)
			or Particle._isRope(item)
			or Particle._isDistortion(item)
		if isCloneAnimate and self.ActiveAnimates[item] then return end
		cancelAnimation(self, item)
		-- Cap check here, not in _registerEmit: Animate paths mutate the live RT before registering,
		-- so a reject there could not restore it.
		local cap = self.MAX_ACTIVE_PARTICLES or 1000
		if #self.ActiveEmits + (self._lingerVisualCount or 0) >= cap then
			local now = os.clock()
			if now - (self._capWarnLastAt or 0) >= 1 then
				self._capWarnLastAt = now
				Log.warn(("[Part-Icles] active particle cap (%d) reached  -  new emits skipped (user Module code still runs)."):format(cap))
			end
			return
		end
		if item:IsA("Beam") then self:EmitBeamAnimate(item, link, emitCtx)
		elseif item:IsA("Trail") and item:FindFirstChild("PartIcleProperties") then self:EmitTrailAnimate(item, link, emitCtx)
		elseif item:IsA("Highlight") then self:EmitHighlightAnimate(item, link, emitCtx)
		elseif item:IsA("Attachment") then self:EmitAttachmentAnimate(item, link, emitCtx)
		elseif item:IsA("Model") then self:EmitModelAnimate(item, link, emitCtx)
		elseif item:IsA("BlurEffect") then self:EmitBlurAnimate(item, link, emitCtx)
		elseif item:IsA("BloomEffect") then self:EmitBloomAnimate(item, link, emitCtx)
		elseif item:IsA("ColorCorrectionEffect") then self:EmitColorCorrectionAnimate(item, link, emitCtx)
		elseif item:IsA("Atmosphere") then self:EmitAtmosphereAnimate(item, link, emitCtx)
		elseif item:IsA("ImageLabel") then self:EmitImageLabelAnimate(item, link, emitCtx)
		elseif Particle._isLightning(item) then self:EmitLightningAnimate(item, link, emitCtx)
		elseif Particle._isCameraShake(item) then self:EmitCameraShakeAnimate(item, link, emitCtx)
		elseif Particle._isRocks(item) then self:EmitRocksAnimate(item, link, emitCtx)
		elseif Particle._isRope(item) then self:EmitRopeAnimate(item, link, emitCtx)
		elseif Particle._isDistortion(item) then self:EmitDistortionAnimate(item, link, emitCtx)
		elseif item:IsA("BasePart") then self:EmitPartAnimate(item, link, emitCtx) end
	end

	-- Emit honoring EmitCount + EmitDelay + EmitDuration. Animate mode: EmitDuration bounds AnimateLoop.
	function Particle:EnableEmit(item, link, emitCtx)
		self:_warnIfNotActivated("EnableEmit")
		local emissionMode = item:GetAttribute('EmissionMode') or "Emit"
		-- Zero-as-zero: missing EmitCount → default 1; explicit 0 → no emission.
		local rawEmitCount = item:GetAttribute('EmitCount')
		local emitCount = rawEmitCount == nil and 1 or rawEmitCount
		-- An event firing its EmitTarget is an explicit demand: a target left at 0 still
		-- emits one burst. Authored counts >= 1 win unchanged.
		if emitCount <= 0 and emitCtx and emitCtx.EventDriven then emitCount = 1 end
		local emitDelay = item:GetAttribute('EmitDelay') or 0
		-- EmitDuration: number or "min,max" range string.
		local emitDuration = ParticlesMod.parseDuration(item:GetAttribute('EmitDuration')) or 0
		-- Per-play overrides (EmitAt options Count / Delay / Duration) replace the authored
		-- attributes for this call only; nothing is written to the source.
		local overrides = emitCtx and emitCtx.Overrides
		if overrides then
			if overrides.Count ~= nil then emitCount = overrides.Count end
			if overrides.Delay ~= nil then emitDelay = overrides.Delay end
			if overrides.Duration ~= nil then emitDuration = ParticlesMod.parseDuration(overrides.Duration) or 0 end
		end
		-- Animate items with default 0/0 still reach EmitAnimate (AnimateLoop drives them).
		if emissionMode ~= "Animate" and emitCount <= 0 and emitDuration <= 0 then return end

		-- Skip _emitGen serialization for: chain-driven (N parallel chains), nested-driven
		-- (one chain per parent particle  -  multiple parents must coexist), and instant
		-- bursts. Nested-driven detected via emitCtx._parentAlive set by NestedEmit.walk.
		local isChainDriven = emitCtx and emitCtx.ChainCtx ~= nil
		local isNestedDriven = emitCtx and emitCtx._parentAlive ~= nil
		-- Play-driven (EmitAt) Emit plays coexist on one source, each stopped by its own token.
		-- Animate keeps one cycle per source, so it stays serialized.
		local isPlayDriven = emitCtx ~= nil and emitCtx._playToken ~= nil and emissionMode ~= "Animate"
		local skipGenSerialization = isChainDriven or isNestedDriven or isPlayDriven or emitDuration <= 0
		-- Top-level emit: backfill _EvenCycleId on this authored emitter + its nested
		-- emitters so clones inherit a shared rolling-cycle key (no-op once stamped).
		if not (isChainDriven or isNestedDriven) then EvenCycle.ensureIds(item) end
		local startGen
		if not skipGenSerialization then
			startGen = (item:GetAttribute("_emitGen") or 0) + 1
			EngineAttr.write(item, "_emitGen", startGen)
		end
		-- Engine-session gen invalidates closures past Activate/Deactivate.
		local engineGen = self._engineGen or 0
		local function genStillCurrent()
			if self.Connection == nil then return false end
			if (self._engineGen or 0) ~= engineGen then return false end
			if not item.Parent then return false end
			if not skipGenSerialization and (item:GetAttribute("_emitGen") or 0) ~= startGen then
				return false
			end
			-- Nested-emit cancellation: parent's Engine cleanup flips _parentAlive[1].
			if emitCtx and emitCtx._parentAlive and not emitCtx._parentAlive[1] then return false end
			-- Play-driven: PlayHandle:Disable flips token.Alive.
			if emitCtx and emitCtx._playToken and emitCtx._playToken.Alive == false then return false end
			return true
		end

		if emissionMode == "Animate" then
			local function doAnimate()
				if not genStillCurrent() then return end
				if emitDuration > 0 then
					EngineAttr.write(item, "AnimateLoop", true)
					task.delay(emitDuration, function()
						-- Own guard: the window must close even after a nested parent died (genStillCurrent
						-- would bail and leave AnimateLoop=true persisted on the source).
						if self.Connection == nil or (self._engineGen or 0) ~= engineGen or not item.Parent then return end
						if not skipGenSerialization and (item:GetAttribute("_emitGen") or 0) ~= startGen then return end
						if item:GetAttribute("AnimateLoop") then EngineAttr.write(item, "AnimateLoop", false) end
					end)
				end
				self:EmitAnimate(item, link, emitCtx)
			end
			if emitDelay > 0 then task.delay(emitDelay, doAnimate) else doAnimate() end
			return
		end

		local config = TypeRegistry.getConfig(item)

		local function doEmit()
			if not genStillCurrent() then return end
			-- Advance the rolling cycle ONCE per emission (this whole burst), then offset
			-- every particle's even spread by it. Keyed by _EvenCycleId so the next burst
			-- and nested re-emits keep rolling the same shared counter.
			local hasPosEven, hasRotEven = EvenCycle.evenFlags(config)
			local cyPI, cyPN, cyRI, cyRN = 1, 0, 1, 0
			if hasPosEven or hasRotEven then
				local cycleKey = item:GetAttribute("_EvenCycleId") or item
				local currentRate = (config and config:GetAttribute("Rate")) or 10
				cyPI, cyPN, cyRI, cyRN = EvenCycle.advance(self._evenCycleStore, cycleKey, config, currentRate, hasPosEven, hasRotEven)
			end
			for i = 1, emitCount do
				self:Emit(item, link, Events.withEvenOffset(emitCtx, i, emitCount, cyPI, cyPN, cyRI, cyRN))
			end
			if emitDuration > 0 then
				if isChainDriven or isNestedDriven or isPlayDriven then
					-- Chain-, nested- or play-driven: independent parallel loop. Don't flip
					-- cfg.Enabled  -  nested-driven must not touch the user's standalone
					-- Enabled state on the nested item, since each parent particle has its
					-- own _parentAlive lifetime; cfg.Enabled is reserved for user intent.
					self:Enable(item, link, emitDuration, emitCtx)
				else
					-- User-driven duration emit: flip cfg.Enabled so the engine listener
					-- treats this as the canonical Enable cycle, schedule shared cleanup.
					-- Claim the item so a separate Part module instance skips its auto-Enable.
					EngineAttr.write(item, "_PartIclePlaying", true)
					if config then EngineAttr.write(config, "Enabled", true) end
					self:Enable(item, link, emitDuration, emitCtx)
					task.delay(emitDuration, function()
						if not genStillCurrent() then return end
						if config and config.Parent then EngineAttr.write(config, "Enabled", false) end
						EngineAttr.write(item, "_PartIclePlaying", nil)
					end)
				end
			end
		end

		if emitDelay > 0 then task.delay(emitDelay, doEmit) else doEmit() end
	end

	-- Continuous emit loop until duration / cfg.Enabled / parent / engine-gen drift.
	-- Animate mode short-circuits to AnimateLoop=true + EmitAnimate.
	function Particle:Enable(item, link, duration, emitCtx)
		self:_warnIfNotActivated("Enable")
		local data = self:GetData(item)
		if not data then return end
		local emissionMode = item:GetAttribute('EmissionMode') or "Emit"
		if emissionMode == "Animate" then
			EngineAttr.write(item, "AnimateLoop", true)
			self:EmitAnimate(item, link, emitCtx)
			return
		end
		local loopDuration = duration or math.huge
		local config = TypeRegistry.getConfig(item)
		-- Chain-driven AND nested-driven loops run parallel (own bucket); user-driven
		-- cancel-and-replace. Nested-driven means each parent particle gets its OWN
		-- independent task whose lifetime tracks _parentAlive[1].
		local isChainDriven = emitCtx and emitCtx.ChainCtx ~= nil
		local isNestedDriven = emitCtx and emitCtx._parentAlive ~= nil
		-- Play-driven: an AbsoluteEmitAt ghost play. Runs parallel (own bucket) so concurrent
		-- plays on ONE shared source coexist instead of cancel-and-replacing via ActiveLoops.
		-- The PlayHandle stops it by flipping token.Alive and cancels its task via token.Loops.
		local playToken = emitCtx and emitCtx._playToken
		local isPlayDriven = playToken ~= nil
		local isParallel = isChainDriven or isNestedDriven or isPlayDriven
		local engineGenAtStart = self._engineGen or 0
		local function loopBody()
			local startTime = os.clock()
			local emitAccum = 0 -- sub-frame Rate carry
			-- Persistent rolling cycle, keyed by _EvenCycleId so this loop, discrete bursts,
			-- and nested re-emits share + advance one counter (resets on Disable, not on a
			-- bare cfg.Enabled re-toggle). Direction follows sign of N (+ forward, - reverse).
			local cycleKey = item:GetAttribute("_EvenCycleId") or item
			while true do
				if isParallel and (self._engineGen or 0) ~= engineGenAtStart then break end
				-- Nested-driven: bail when this parent particle dies. Sibling parents'
				-- loops are independent (different _parentAlive table per parent emit).
				if isNestedDriven and emitCtx._parentAlive and not emitCtx._parentAlive[1] then break end
				-- Play-driven: bail when the PlayHandle disables this play (token.Alive flipped).
				if isPlayDriven and not playToken.Alive then break end
				if not item or not item.Parent then
					if not isParallel then Particle.ActiveLoops[item] = nil end; break
				end
				if os.clock() - startTime >= loopDuration then
					if not isParallel then Particle.ActiveLoops[item] = nil end; break
				end
				if not isParallel and not data.CheckEnabled() then
					Particle.ActiveLoops[item] = nil; break
				end
				local dt = LOOP_YIELD_EVENT:Wait()
				-- Re-check after the yield: the parent particle or engine may have died during the frame.
				if isParallel and (self._engineGen or 0) ~= engineGenAtStart then break end
				if isNestedDriven and emitCtx._parentAlive and not emitCtx._parentAlive[1] then break end
				if isPlayDriven and not playToken.Alive then break end
				-- Studio-unfocused pause; runtime always passes (Selection:Get is editor-only).
				if IS_STUDIO and IS_PLUGIN and not Particle._focused then
					local sel = Selection:Get()
					if #sel == 0 or (Particle._unfocusedAt > 0 and os.clock() - Particle._unfocusedAt > 600) then emitAccum = 0; continue end
				end
				local currentRate = config and config:GetAttribute("Rate") or 10
				if currentRate <= 0 then emitAccum = 0; continue end
				local interval = 1 / currentRate
				emitAccum = emitAccum + dt
				local hasPosEven = (data.PosXEven or data.PosYEven or data.PosZEven) == true
				local hasRotEven = (data.RotXEven or data.RotYEven or data.RotZEven) == true
				while emitAccum >= interval do
					emitAccum = emitAccum - interval
					if hasPosEven or hasRotEven then
						-- One particle per emission: i=1,count=1; the cycle is pure offset.
						local cyPI, cyPN, cyRI, cyRN = EvenCycle.advance(self._evenCycleStore, cycleKey, config, currentRate, hasPosEven, hasRotEven)
						self:Emit(item, link, Events.withEvenOffset(emitCtx, 1, 1, cyPI, cyPN, cyRI, cyRN))
					else
						self:Emit(item, link, emitCtx)
					end
				end
			end
		end
		if isParallel then
			-- Bucket per-item so Disable can cancel; task self-removes its entry on
			-- completion. Nested-driven and chain-driven share this bucket: both are
			-- independent parallel tasks that must coexist (one per parent particle
			-- for nested-driven; one per chain stagger for chain-driven).
			local chainTask = task.spawn(function()
				loopBody()
				local selfThread = coroutine.running()
				local bucket = Particle.ActiveChainLoops[item]
				if not bucket then return end
				for i = #bucket, 1, -1 do
					if bucket[i] == selfThread then table.remove(bucket, i); break end
				end
				if #bucket == 0 then Particle.ActiveChainLoops[item] = nil end
			end)
			local bucket = Particle.ActiveChainLoops[item]
			if not bucket then bucket = {}; Particle.ActiveChainLoops[item] = bucket end
			table.insert(bucket, chainTask)
			-- Register with the play so PlayHandle:Disable/SoftDisable cancels exactly this task.
			if isPlayDriven then table.insert(playToken.Loops, chainTask) end
		else
			if Particle.ActiveLoops[item] then task.cancel(Particle.ActiveLoops[item]) end
			Particle.ActiveLoops[item] = task.spawn(loopBody)
		end
	end

	-- Particle:EnableEmitAt / AbsoluteEmitAt live in EmitAt.luau (mixin): origin-override emits with a PlayHandle.

	-- Particle:_registerEmit lives in RegisterEmit.luau (mixin) — split out to keep this file
	-- under the 500-line cap. It is the universal pData insertion chokepoint + play-token stamp.

	-- _fireOnDeath / _fireOnDestruction / _releaseOrDestroy live in LifecycleRelease.luau (mixin).

	-- Engine-session predicate; ParticlesMod delayed closures bail on _engineGen drift.
	function Particle:_makeAliveCheck()
		local engineGen = self._engineGen or 0
		return function()
			return self.Connection ~= nil and (self._engineGen or 0) == engineGen
		end
	end

	-- AnimateLoop cycle restart: re-seed OnHit + fire OnEmit. EmitIndex nil for re-fires.
	function Particle:_fireAnimateCycleRestartEvents(pData)
		if pData.Events and pData.Events.OnHit then
			pData.LastHitCheckPos = Events.getWorldPosition(pData)
			pData.LastHitCheckTime = nil
		end
		if pData.Events and pData.Events.OnEmit then
			local payload = Events.makePayload(self, pData, "OnEmit", { ChainCtx = pData.EventChainCtx, EmitIndex = nil })
			Events.fire(self, pData, "OnEmit", pData.EventChainCtx, payload)
		end
	end

	-- payload.Kill flags-only; Heartbeat death branch destroys + restores. PartLife=0 forces immediate.
	-- Animate also flips AnimateLoop=false + cfg.Enabled=false so death branch goes to animate-finish.
	function Particle:_killParticle(pData, opts)
		opts = opts or {}
		pData._killedManually = true
		pData._fireOnDeathOverride = opts.fireOnDeath == true
		pData._forceDead = true
		pData.PartLife = 0
		if pData.IsAnimate then
			local source = pData._sourceItem
			if source then
				pcall(function()
					EngineAttr.write(source, "AnimateLoop", false)
					-- Enabled is on Configuration, not item; route through config.
					local cfg = TypeRegistry.getConfig(source)
					if cfg then EngineAttr.write(cfg, "Enabled", false) end
				end)
			end
		end
	end
end
