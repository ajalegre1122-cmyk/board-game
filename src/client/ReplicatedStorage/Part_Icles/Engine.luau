--[[
	Engine mixin  -  per-frame engine step + Activate / Deactivate / GetFolder / GetPoolFolder.

	Activate connects the per-frame step that walks ActiveEmits → UpdateX, handles
	death, replays AnimateLoop cycles, and runs the OnHit raycast pass. On clients
	(incl. Studio edit) the step runs in the RENDER phase after camera + character
	updates so welded links read this frame's final pose; servers use Heartbeat.
	Deactivate is the symmetric teardown.
]]

local RunService = game:GetService('RunService')
local UIS = game:GetService('UserInputService')

local EventsMod = require(script.Parent.Events)
local EventsCollision = require(script.Parent.EventsCollision)
local Pool = require(script.Parent.Pool)
local CameraShakeApply = require(script.Parent.CameraShake.Apply)
local VisualHost = require(script.Parent.VisualHost)
local EngineAttr = require(script.Parent.EngineAttr)
-- Distortion canvas composes AFTER the shake write so the plane rides the
-- shaken camera in the same frame (order is load-bearing).
local DistortionCanvas = require(script.Parent.Distortion.Canvas)
local Log = require(script.Parent.Log)
local DecalLayersMod = require(script.Parent.DecalLayers)
local MeshFramesMod = require(script.Parent.MeshFrames)

-- Unique BindToRenderStep names: plugin engine + ReplicatedStorage runtime module can
-- both be active in one client DataModel. The serial alone is NOT unique across
-- module instances (each starts at 1, and UnbindFromRenderStep removes every
-- binding sharing the name  -  one engine's Deactivate would kill the other's
-- step); the per-instance token disambiguates.
local _bindSerial = 0
local _instanceToken = tostring({}):match("0x(%x+)") or tostring(math.random(1e9))

return function(Particle)

-- Start the per-frame step. Each tick walks ActiveEmits → UpdateX; replay on AnimateLoop, swap-pop on death.
function Particle:Activate()
	if self.Connection then return end

	-- Bump engine-session gen so pending closures from prior sessions bail.
	self._engineGen = (self._engineGen or 0) + 1

	-- Reset the not-activated warning latch so a Deactivate → Emit cycle re-warns
	-- on each new Activate session.
	self._notActivatedWarned = false

	-- Reconnect focus listeners (disconnected in Deactivate). Client-only.
	if RunService:IsClient() then
		if not self._focusConn then
			self._focusConn = UIS.WindowFocused:Connect(function()
				self._focused = true
				self._unfocusedAt = 0
			end)
		end
		if not self._blurConn then
			self._blurConn = UIS.WindowFocusReleased:Connect(function()
				self._focused = false
				self._unfocusedAt = os.clock()
			end)
		end
	end

	-- Pin textures for PreloadTexture=true items already in scene.
	for _, service in ipairs({
		workspace,
		game:GetService("Lighting"),
		game:GetService("ReplicatedStorage"),
		game:GetService("StarterGui"),
		game:GetService("StarterPack"),
		game:GetService("ReplicatedFirst"),
	}) do
		pcall(function() self:Preload(service, false) end)
	end

	local step = function(dt)
		EventsMod.tickFrame()
		-- Pool tick before the empty-emits early-return so idle pools still TTL-evict.
		local currentTime = os.clock()
		Pool.tick(currentTime)
		-- Carriers mirror their anchor part before any particle reads its parent frame.
		VisualHost.tick()
		local emits = self.ActiveEmits
		-- Flush before the early return: the frame after the last shake dies must
		-- still remove its applied camera offset (idle cost = a few compares).
		if #emits == 0 then
			CameraShakeApply.applyFrame()
			DistortionCanvas.applyFrame()
			return
		end
		local camPos; do local cam = workspace.CurrentCamera; if cam then camPos = cam.CFrame.Position end end
		-- Disable calls made from inside the loop (event Modules) queue on _afterStep instead of
		-- sweeping ActiveEmits under the iteration (Particle:Disable / PlayHandle:Disable check this).
		self._inStep = true
		local i = 1

		while i <= #emits do
			local pData = emits[i]
			-- _forceDead (payload.Kill) short-circuits the per-type Update for immediate death.
			local isDead = pData._forceDead == true
			-- Capture step pre-Update so the post-Update cache refresh detects step advance for unlinked particles.
			local prevStep = pData.CurrentStep

			if not isDead then
				if pData.Type == "Part" then
					isDead = self:UpdatePart(pData, dt, currentTime)
				elseif pData.Type == "Beam" then
					isDead = self:UpdateBeam(pData, dt, currentTime)
				elseif pData.Type == "PointLight" then
					isDead = self:UpdatePointLight(pData, dt, currentTime)
				elseif pData.Type == "Highlight" then
					isDead = self:UpdateHighlight(pData, dt, currentTime)
				elseif pData.Type == "TrailEmitter" then
					isDead = self:UpdateTrail(pData, dt, currentTime)
				elseif pData.Type == "Attachment" then
					isDead = self:UpdateAttachment(pData, dt, currentTime)
				elseif pData.Type == "Model" then
					isDead = self:UpdateModel(pData, dt, currentTime)
				elseif pData.Type == "Screen" then
					isDead = self:UpdateScreen(pData, dt, currentTime)
				elseif pData.Type == "ImageLabel" then
					isDead = self:UpdateImageLabel(pData, dt, currentTime)
				elseif pData.Type == "Lightning" then
					isDead = self:UpdateLightning(pData, dt, currentTime)
				elseif pData.Type == "CameraShake" then
					isDead = self:UpdateCameraShake(pData, dt, currentTime)
				elseif pData.Type == "Sound" then
					isDead = self:UpdateSound(pData, dt, currentTime)
				elseif pData.Type == "Rocks" then
					isDead = self:UpdateRocks(pData, dt, currentTime)
				elseif pData.Type == "Rope" then
					isDead = self:UpdateRope(pData, dt, currentTime)
				elseif pData.Type == "Distortion" then
					isDead = self:UpdateDistortion(pData, dt, currentTime)
				end
			end

			-- Per-frame passes run outside the step gate for smooth tracking between keyframes.
			-- Skip on dead particles to avoid one extra wasted frame + last-frame flicker.
			-- `_postUpdateCF` caches the pre-overlay base CFrame so Orientation and ZOffset
			-- can apply as ABSOLUTE overlays. Refresh whenever Update wrote a fresh CFrame
			-- this frame (CurrentStep advanced) or ReapplyLink writes one (every frame for
			-- linked particles). Unlinked between-step frames retain the last step's cache
			-- as the correct overlay base.
			if not isDead then
				if pData.Link then self:ReapplyLink(pData) end
				-- Settle pass post-Update so gravity-torque composes after step rotation.
				local t = pData.Type
				if pData._settleEngaged and not pData._collisionStopped
					and (t == "Part" or t == "Model" or t == "Attachment") then
					EventsCollision.applySettle(pData, dt)
				end
				-- Only Part / Model / Attachment consume `_postUpdateCF` via overlays. Beam,
				-- PointLight, Screen, ImageLabel have no `.CFrame` property  -  gate the cache
				-- write to the consumer types so a Beam with Link doesn't error every Heartbeat.
				if (t == "Part" or t == "Model" or t == "Attachment") and (pData.Link or pData.CurrentStep ~= prevStep) then pData._postUpdateCF = (t == "Model") and pData.VisualPart:GetPivot() or pData.VisualPart.CFrame end
				if pData.Orientation and pData.Orientation ~= "None" then self:ApplyOrientation(pData, dt, camPos) end
				if pData.ZOffset and pData.ZOffset ~= 0 then self:ApplyZOffset(pData, camPos) end
			end

			-- OnHit raycast: AFTER all visual-pass CFrame writes (ReapplyLink + Orientation
			-- + ZOffset), so the segment matches the rendered position rather than the
			-- mid-pass intermediate. Internal pData.Events.OnHit gate makes this a cheap
			-- no-op when not configured. Runs even on death frame so fast particles don't
			-- have a blind segment between last-update and removal.
			EventsMod.afterUpdate(self, pData, isDead, currentTime)

			if isDead then
				-- OnDeath fires before any swap-and-pop / animate restart. AnimateLoop
				-- replay also fires OnDeath every cycle boundary; replay branch resets
				-- _killedManually after this fire so the new cycle starts clean.
				self:_fireOnDeath(pData)
				if pData.IsAnimate then
					-- A soft-disabled play (PlayHandle:SoftDisable) finishes its cycle and does not replay.
					local playStopped = pData._playToken ~= nil and pData._playToken.Alive == false
					if not playStopped and pData.AnimateItem and pData.AnimateItem.Parent and pData.AnimateItem:GetAttribute("AnimateLoop") then
						-- Cycle reset + replay body lives in EngineReplay.luau (500-line cap split).
						self:_replayAnimateCycle(pData, currentTime)
						i += 1
					else
						-- One-shot animate finish. PartLife keeps the visual at its last frame for N
						-- seconds before position reset + hide.
						local visualPart = pData.VisualPart
						local pType = pData.Type
						local initialAnchorCF = pData.InitialAnchorCF
						local initialScale = pData.InitialScale
						local hasDecal = pData.HasDecal
						local animateItem = pData.AnimateItem
						local partLife = pData.PartLife or 0
						local isSharedRT = self:_isLiveRTAnimate(pData)
						-- Per-cycle finish token. Each Animate cycle bumps `_animateFinishGen`
						-- on the source item; this finish closure captures the value at schedule
						-- time and bails if a newer cycle has armed its own finish since.
						local finishGen
						if animateItem then
							finishGen = (animateItem:GetAttribute("_animateFinishGen") or 0) + 1
							EngineAttr.write(animateItem, "_animateFinishGen", finishGen)
						end
						local function finishAnimate()
							if not visualPart or not visualPart.Parent then return end
							if isSharedRT and animateItem and self.ActiveAnimates[animateItem] then return end
							if animateItem and animateItem.Parent and finishGen and animateItem:GetAttribute("_animateFinishGen") ~= finishGen then return end
							-- OnDestruction fires JUST BEFORE the visual is restored/destroyed/hidden.
							-- AnimateLoop replay doesn't reach here (death-handler restarts cycle
							-- without calling finishAnimate), so this is genuinely terminal.
							self:_fireOnDestruction(pData, visualPart)
							if initialAnchorCF then
								if pType == "Model" then
									pcall(function() visualPart:PivotTo(initialAnchorCF) end)
									if initialScale then pcall(function() visualPart:ScaleTo(initialScale) end) end
								else pcall(function() visualPart.CFrame = initialAnchorCF end) end
							end
							if pType == "Screen" or pType == "ImageLabel" or pType == "Lightning" or pType == "Rocks" or pType == "Rope" then
								pcall(function() visualPart:Destroy() end)
							elseif pType == "Beam" or pType == "Highlight" or pType == "TrailEmitter" then
								local snap = pData.BeamSnapshot or pData.HighlightSnapshot or pData.TrailEmitterSnapshot
								if snap then
									pcall(function() for k, v in pairs(snap) do visualPart[k] = v end end)
								end
								pcall(function() visualPart.Enabled = false end)
							else
								DecalLayersMod.restore(pData)
								MeshFramesMod.restore(pData)
								pcall(function()
									visualPart.Transparency = 1
									if hasDecal then local d = visualPart:FindFirstChildOfClass("Decal"); if d then d.Transparency = 1 end end
									local sa = pData._initialSAColor and visualPart:FindFirstChildOfClass("SurfaceAppearance")
									if sa then sa.Color = pData._initialSAColor end
									if pData._initialPartColor and visualPart:IsA("BasePart") then visualPart.Color = pData._initialPartColor end
								end)
							end
						end
						-- Clear ActiveAnimates BEFORE running finishAnimate (see prior comment block).
						self.ActiveAnimates[animateItem] = nil
						if partLife > 0 then task.delay(partLife, finishAnimate) else finishAnimate() end
						self:_reclaimPData(pData)
						-- A cancelAnimation raised from inside the loop may already have popped this entry.
						if emits[i] == pData then
							local n = #emits
							if i < n then emits[i] = emits[n] end
							emits[n] = nil
						end
					end
				else
					-- Normal emit: destroy visual, swap-and-pop. OnDestruction fires JUST
					-- BEFORE destroy (immediate path) or inside the deferred closure (linger
					-- path) so user scripts read the final pose pre-destroy.
					local visualPart = pData.VisualPart
					if pData.PartLife and pData.PartLife > 0 then
						-- Track this visualPart in self._lingerByItem so Particle:Disable
						-- can destroy linger clones early when Stop fires. Also bump the
						-- linger visual counter so MAX_ACTIVE_PARTICLES reflects rendered
						-- linger clones; flag the visual so each path that destroys it
						-- decrements at most once.
						local source = pData._sourceItem
						if source and visualPart then
							self._lingerByItem = self._lingerByItem or {}
							local list = self._lingerByItem[source] or {}
							table.insert(list, visualPart)
							self._lingerByItem[source] = list
							pcall(function() visualPart:SetAttribute("_lingerCounted", true) end)
							self._lingerVisualCount += 1
						end
						-- Stamp linger start so OnDestruction's payload.LingerElapsed
						-- can report actual time-in-linger when fired (early-Disable
						-- destroys mid-linger; full PartLife when delay completes).
						pData._lingerStartTime = os.clock()
						task.delay(pData.PartLife, function()
							self:_fireOnDestruction(pData, visualPart)
							if visualPart then
								local counted = false
								pcall(function() counted = visualPart:GetAttribute("_lingerCounted") == true end)
								if counted then
									self._lingerVisualCount = math.max(0, (self._lingerVisualCount or 0) - 1)
									pcall(function() visualPart:SetAttribute("_lingerCounted", nil) end)
								end
								-- Pool-eligible if non-animate and pData has source RT stamps
								-- (Emit.luau / EmitModel.luau / PointLight.luau set them).
								self:_releaseOrDestroy(pData, visualPart)
							end
							if source and self._lingerByItem and self._lingerByItem[source] then
								local list = self._lingerByItem[source]
								for k = #list, 1, -1 do
									if list[k] == visualPart then
										local n = #list
										if k < n then list[k] = list[n] end
										list[n] = nil
									end
								end
								if #list == 0 then self._lingerByItem[source] = nil end
							end
						end)
					else
						-- PartLife=0: OnDestruction same-frame as OnDeath, then release/destroy.
						self:_fireOnDestruction(pData, visualPart)
						self:_releaseOrDestroy(pData, visualPart)
					end
					self:_reclaimPData(pData)
					-- A cancelAnimation raised from inside the loop may already have popped this entry.
					if emits[i] == pData then
						local n = #emits
						if i < n then emits[i] = emits[n] end
						emits[n] = nil
					end
				end
			else
				i += 1
			end
		end

		self._inStep = false
		local queued = self._afterStep
		if queued then
			self._afterStep = nil
			for _, fn in ipairs(queued) do
				local ok, err = pcall(fn)
				if not ok then Log.warn("[Part-Icles] deferred Disable failed: " .. tostring(err)) end
			end
		end

		-- Single camera write per frame: summed shake offsets, delta-composed so the
		-- prior frame's offset removes cleanly (CameraShake/Apply.luau).
		CameraShakeApply.applyFrame()
		DistortionCanvas.applyFrame()
	end

	if RunService:IsClient() then
		-- Render phase AFTER camera (200) + character (300) scripts: camera/character-
		-- welded links read this frame's final pose instead of lagging one frame.
		-- Trade-off: links to physics-simulated parts read the prior simulation step.
		_bindSerial += 1
		self._renderStepName = "PartIclesEngine_" .. _instanceToken .. "_" .. _bindSerial
		local ok = pcall(function()
			RunService:BindToRenderStep(self._renderStepName, Enum.RenderPriority.Last.Value + 1, step)
		end)
		if ok then
			self.Connection = "RenderStep" -- truthy sentinel; consumers only truth-check
		else
			self._renderStepName = nil
			self.Connection = RunService.RenderStepped:Connect(step)
		end
	else
		self.Connection = RunService.Heartbeat:Connect(step)
	end
end

-- Shut down the engine. Unbinds/disconnects the frame step, destroys every live clone, cancels
-- loops, restores animate sources, and clears texture pins. Safe to call multiple times.
function Particle:Deactivate()
	-- Bump engine-session generation FIRST. Any pending EnableEmit / Enable
	-- task.delay closure that captured the prior gen will now bail via
	-- genStillCurrent's `self._engineGen == engineGen` check, instead of
	-- spawning particles after teardown disconnected the Heartbeat.
	self._engineGen = (self._engineGen or 0) + 1
	if self.Connection then
		if self._renderStepName then
			pcall(function() RunService:UnbindFromRenderStep(self._renderStepName) end)
			self._renderStepName = nil
		elseif typeof(self.Connection) == "RBXScriptConnection" then
			self.Connection:Disconnect()
		end
		self.Connection = nil
	end
	-- Disconnect UIS focus tracking  -  module reload would otherwise leak the two
	-- WindowFocused/WindowFocusReleased connections firing on dead-module closures.
	if self._focusConn then self._focusConn:Disconnect(); self._focusConn = nil end
	if self._blurConn then self._blurConn:Disconnect(); self._blurConn = nil end
	-- The step no longer runs; remove any applied camera-shake offset NOW or the
	-- camera stays tilted forever.
	CameraShakeApply.reset()
	DistortionCanvas.reset()
	if self._lingerByItem then table.clear(self._lingerByItem) end
	if self._evenCycleStore then table.clear(self._evenCycleStore) end
	-- Pending PartLife linger closures hold no engineGen guard, so they continue
	-- decrementing past Deactivate. Zero the counter here so a quick Off→On toggle
	-- doesn't see an inflated _lingerVisualCount restricting fresh emits via the cap
	-- check. The math.max(0, ... - 1) guard in the closure tolerates the reset.
	self._lingerVisualCount = 0
	-- Clean up all active particles. Skip live-RT animate pData (their VisualPart IS the source's
	-- RenderTemplate; _cancelAnimation below restores them instead).
	-- Flush pool BEFORE iterating ActiveEmits  -  pool entries are non-active clones we
	-- own; their Destroy is bookkeeping-light and short-circuits the workspace sweep
	-- below from finding them (the sweep matches on _PartIcleEmit attribute, which
	-- pooled entries still carry).
	Pool.flushAll()
	for i = #self.ActiveEmits, 1, -1 do
		local pData = self.ActiveEmits[i]
		local skip = self:_isLiveRTAnimate(pData)
		if not skip and pData.VisualPart then
			Pool.dropCloneMap(pData.VisualPart)
			pcall(function() pData.VisualPart:Destroy() end)
		end
		self:_reclaimPData(pData)
		self.ActiveEmits[i] = nil
	end
	-- Reset animate items via cancelAnimation (restores source RT to authored state).
	local animateKeys = {}
	for item in pairs(self.ActiveAnimates) do table.insert(animateKeys, item) end
	for _, item in ipairs(animateKeys) do
		pcall(function() self:_cancelAnimation(item) end)
	end
	table.clear(self.ActiveAnimates)
	for item, thread in pairs(self.ActiveLoops) do
		pcall(function() task.cancel(thread) end)
		self.ActiveLoops[item] = nil
	end
	-- Cancel chain-driven duration loops + clear buckets so the map doesn't sit
	-- pinned until module reload. `_engineGen` drift above also makes the threads
	-- self-terminate; this just frees the table refs.
	if self.ActiveChainLoops then for _, bucket in pairs(self.ActiveChainLoops) do for _, t in ipairs(bucket) do pcall(task.cancel, t) end end; table.clear(self.ActiveChainLoops) end
	VisualHost.reset()
	-- Sweep workspace + Lighting + the auto-managed CoreGui ScreenGui for any emitted items that
	-- escaped normal tracking (PointLights parent to original part; PartLife-delayed items removed
	-- from ActiveEmits early; screen effects live in Lighting; ImageLabels live in our ScreenHost).
	local function sweep(root) for _, desc in root:GetDescendants() do if desc:GetAttribute("_PartIcleEmit") then pcall(desc.Destroy, desc) end end end
	sweep(workspace); sweep(game:GetService("Lighting"))
	local ScreenHost = require(script.Parent.ScreenHost)
	if ScreenHost.exists() then sweep(ScreenHost.get()); ScreenHost.destroy() end
	local TexturePin = require(script.Parent.TexturePin)
	TexturePin.clear()
	-- Tear down Events compile cache: disconnects every Source/AncestryChanged signal +
	-- destroys every `_CompiledEventModule` clone so toggle-off-on cycles don't leak
	-- signal connections firing on dead-module closures.
	EventsMod.cleanup()
	-- LinkService owns an independent per-frame PreRender / Heartbeat connection +
	-- Anchored snapshot table. Deactivate disconnects + restores so toggle cycles
	-- don't leak link tracking or strand parts in Anchored=true state.
	if self.LinkService and self.LinkService.Deactivate then
		pcall(function() self.LinkService:Deactivate() end)
	end
end

-- Runtime folders live where VisualHost puts them: under workspace.CurrentCamera for a client or
-- the editor (local, out of Team Create replication and the place file), under Terrain on a server.
function Particle:GetFolder()
	return VisualHost.getFolder()
end

-- Idle-pool bucket. Pool.release re-parents released visuals here so authoring users can see
-- exactly which clones are recyclable vs. actively emitting (in the GetFolder bucket).
function Particle:GetPoolFolder()
	return VisualHost.getPoolFolder()
end

end
