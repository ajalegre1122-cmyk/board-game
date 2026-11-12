--[[
	Part-Icles Core  -  runtime engine.

	Call :Activate() once at script start to connect the Heartbeat loop.
	Call :Deactivate() at teardown to disconnect + clean up active emits.

	---- Emit (one item, no recursion) ----
	:Emit(item, link?, emitCtx?)
	   Fires one immediate emit on `item` (BasePart / Attachment / Model / Beam / etc.).
	   Use :AbsoluteEmit when you want children to fire too.

	:EmitAnimate(item, link?, emitCtx?)
	   Starts one Animate cycle on `item`. Visual animates in place (3D types) or
	   spawns a singleton clone (Screen / ImageLabel).

	:EnableEmit(item, link?, emitCtx?)
	   Honors authored EmitCount + EmitDelay + EmitDuration attributes. Fires the
	   burst then runs the loopBody for EmitDuration seconds.

	:EnableEmitAt(item, origin, options?) -> (handle: PlayHandle, duration: number?)
	   Like :EnableEmit but spawns from `origin` instead of `item`'s authored CFrame. One
	   transformed item; :AbsoluteEmitAt handles containers. Same origin forms, options and
	   handle as :AbsoluteEmitAt.

	---- Recursive emit (item + all descendants) ----
	:AbsoluteEmit(item, _parentFiredPE?, emitCtx?) -> duration: number?
	   Fires every emitter under `item` (transformed items via :EnableEmit, raw PE / Trail
	   / Beam via native APIs). Walks the descendant tree, deduping via _parentFiredPE.
	   Returns total real-time duration in seconds (or nil for infinite  -  AnimateLoop
	   unbounded, Timescale stuck at 0). Pair with .await(n) for an emit-and-wait pattern.

	:AbsoluteEmitAt(item, origin, options?) -> (handle: PlayHandle, duration: number?)
	   Recursive form of :EnableEmitAt. `origin` is a CFrame, a Vector3 (position only) or an
	   instance with a frame (followed live through EmitDelay). A transformed root spawns from
	   the origin; a container keeps its authored layout: every transformed descendant spawns
	   at origin x its offset from the container pivot, and raw PE / Trail / Beam ride a
	   stripped clone placed at the origin. UseFullOrigin=false translates only. Nodes without
	   a position (Beam / Trail / lights / screen types / Animate mode) warn once and emit in
	   place. options: Link / LinkMode / EmitParent apply to this play only (Persist=true
	   writes them to the source); Count / Delay / Duration override the authored attributes
	   for this play; OriginResolver, UseFullOrigin, IgnoreLink, LinkOverride, ChainCtx.
	   Returns a per-play ghost handle (:Disable / :SoftDisable / :SetTimescale /
	   :GetParticles / :IsAlive / :Wait, scoped to THIS play, never the shared source) and
	   the total duration (nil for infinite). A rejected call warns and returns an inert
	   handle, never nil.

	---- Enable / Disable (no emit  -  just on/off state) ----
	:Enable(item, link?, duration?, emitCtx?)
	   Starts the continuous-emit loopBody for `duration` seconds (defaults to math.huge).
	   Animate-mode short-circuits to AnimateLoop=true + :EmitAnimate.

	:Disable(item)
	   Hard stop on `item`: cancels loops, sets cfg.Enabled=false, cancels PE/Trail native
	   gens, AND reclaims every live clone now (sweeps ActiveEmits + finishes linger).

	:SoftDisable(item)
	   Soft stop on `item`: halt new emission but leave live clones to age out their Lifetime
	   on the Heartbeat (no ActiveEmits sweep, no linger destroy, no cancelAnimation).

	:AbsoluteEnable(item)
	   Recursive enable. Transformed item → cfg.Enabled=true + :Enable(math.huge), sets
	   _PartIclePlaying gate so the EnabledLoop listener doesn't double-fire. Raw PE / Trail
	   / Beam / Highlight descendants get Enabled=true. Containers (Folder, Model, BasePart)
	   walk children with the covered flag so descendants aren't double-toggled.

	:AbsoluteDisable(item)
	   Recursive SOFT disable. Transformed descendants → :SoftDisable (new emission stops,
	   live particles finish their Lifetime). Raw PE / Trail / Beam / Highlight descendants
	   get Enabled=false (native soft stop). For instant reclaim, call :Disable per item.

	---- Timescale (per-particle time distortion) ----
	:SetTimescale(item, scale, duration?, permanent?)
	   Override Timescale to `scale` for `duration` seconds (or until next ClearTimescale
	   if `permanent`). Wins over authored Timescale graph during its window.

	:ClearTimescale(item)
	   Remove the override; authored Timescale graph (or 1) resumes.

	:AbsoluteSetTimescale / :AbsoluteClearTimescale
	   Recursive variants over `item` + transformed descendants.

	---- Authoring / texture / state ----
	:Transform(part)                                  -  convert into a Part-Icle emitter
	:TransformModel(model, typeDef)                   -  Model variant
	:Preload(root, force?)                            -  pin textures for upcoming emit
	:Deload(root, force?)                             -  release texture pins
	:GetData(item)                                    -  flat data table read from config
	:GetFolder() / :GetPoolFolder()                   -  runtime folder accessors
	:ReapplyLink(pData)                               -  per-frame link CFrame writer

	---- Statics + sub-services ----
	.await(n)                                         -  yields task for n seconds; nil = no-op
	.parseDuration(raw)                               -  parse "min,max" range string to number
	.LinkService                                      -  standalone link-tracking service
	.TransformCompleted                               -  BindableEvent fired post-:Transform

	---- emitCtx ----
	emitCtx (optional table threaded through every emit path):
	  ChainCtx            = { ChainId, Depth } event-chain context
	  EmitIndex           = burst-index (set by EnableEmit's count loop)
	  EmitCount           = burst-count
	  EventOriginCF       = origin override (set by EnableEmitAt / AbsoluteEmitAt)
	  EventOriginResolver = live-resolver function fired at spawn time
	  UseFullOrigin       = bool; AtCFrame includes rotation
	  IgnoreLink          = bool; bypass authored Link weld
	  Overrides           = per-play Count / Delay / Duration / LinkMode / EmitParent (EmitAt options)
]]

local Log = require(script.Log)

local UIS = game:GetService('UserInputService')
local _RunService = game:GetService('RunService')
local ParticlesMod = require(script.Particles)

local Particle = {}
Particle.Beam = {}
-- Focus tracking; connections stored so Deactivate can release them. Client-only.
Particle._focused = true
Particle._unfocusedAt = 0
if _RunService:IsClient() then
	Particle._focusConn = UIS.WindowFocused:Connect(function() Particle._focused = true; Particle._unfocusedAt = 0 end)
	Particle._blurConn = UIS.WindowFocusReleased:Connect(function() Particle._focused = false; Particle._unfocusedAt = os.clock() end)
end

-- Engine state.
Particle.ActiveEmits = {}    -- pData array for live clones; Heartbeat walks this
Particle.ActiveLoops = {}    -- item → Enable-loop task thread
Particle.ActiveAnimates = {} -- item → pData (max 1 cycle per source)
-- Chain-driven duration loops run detached so parallel chain fires don't cancel each other.
Particle.ActiveChainLoops = {}
-- EvenDistribution rolling-cycle state, keyed by _EvenCycleId so all clones of one
-- authored emitter share + advance one counter across discrete + nested emissions.
Particle._evenCycleStore = {}
Particle.Connection = nil
Particle._engineGen = 0
-- Hard cap on concurrent particles; user Module code still runs at cap.
Particle.MAX_ACTIVE_PARTICLES = 1000
Particle._capWarnLastAt = 0
-- PartLife linger visuals (post-pData) count toward the cap.
Particle._lingerVisualCount = 0
-- First-emit-per-RT preload memo (ImageEmit). Weak-keyed so destroyed RT GCs cleanly.
Particle._preloadedAssets = setmetatable({}, {__mode = "k"})

-- Mixin pattern: sub-modules attach methods to Particle.
require(script.GetData)(Particle)
require(script.EmitOverrides)(Particle)
require(script.Transform)(Particle)
require(script.Update)(Particle)
require(script.UpdateAttachment)(Particle)
require(script.UpdateBeam)(Particle)
-- Timescale loaded before Emit mixins so Particle._seedTsOverride is attached when those emit-site seed calls run.
require(script.Timescale)(Particle)
require(script.Emit)(Particle)
require(script.EmitAttachment)(Particle)
require(script.EmitAnimate)(Particle)
require(script.EmitModel)(Particle)
require(script.UpdateModel)(Particle)
require(script.PointLight)(Particle)
require(script.Sound)(Particle)
require(script.Highlight)(Particle)
require(script.Lightning)(Particle)
require(script.CameraShake)(Particle)
require(script.Rocks)(Particle)
require(script.Rope)(Particle)
require(script.Distortion)(Particle)
require(script.TrailEmitter)(Particle)
require(script.ScreenEmit)(Particle)
require(script.ImageEmit)(Particle)
require(script.LinkTrack)(Particle)
require(script.Orientation)(Particle)
require(script.ZOffset)(Particle)
-- Engine mixin owns Activate / Deactivate / GetFolder / GetPoolFolder (big Heartbeat
-- callback split out to keep init.luau under the 500-line code cap).
require(script.Engine)(Particle)
-- EngineReplay owns _replayAnimateCycle (AnimateLoop reset + replay), split from Engine.
require(script.EngineReplay)(Particle)
-- PreSimulate owns PreSimulateForward/PreSimulateAttachmentForward, split from Transform.
require(script.PreSimulate)(Particle)
-- RegisterEmit owns Particle:_registerEmit (universal pData insertion chokepoint + play-token
-- stamp), split out of Lifecycle to keep both under the 500-line cap.
require(script.RegisterEmit)(Particle)
-- Lifecycle loaded last (touches earlier mixins).
require(script.Lifecycle)(Particle)
require(script.LifecycleRelease)(Particle)
require(script.EmitAt)(Particle)

-- Once-per-session warning fired when a public emit-creating method is called
-- before :Activate(). Particles will be created but the Heartbeat isn't connected,
-- so they'll never advance. Helps scripters spot the missing :Activate() call
-- instead of debugging invisible particles.
function Particle:_warnIfNotActivated(methodName)
	if self.Connection then return end
	if self._notActivatedWarned then return end
	self._notActivatedWarned = true
	Log.warn(string.format(
		"[Part-Icles] :%s() called before :Activate()  -  particles will not update until the engine is activated. Call Particle:Activate() once at startup.",
		methodName
	))
end

-- Apply Orientation + ZOffset on emit frame to avoid a 1-frame snap.
function Particle:_applyEmitVisualPasses(pData)
	local t = pData.Type
	if t ~= "Part" and t ~= "Model" and t ~= "Attachment" then return end
	local cam = workspace.CurrentCamera
	local camPos = cam and cam.CFrame.Position
	-- Seed _postUpdateCF from spawn pose so frame-1 overlays don't compound on themselves.
	local hasO = pData.Orientation and pData.Orientation ~= "None"
	local hasZ = pData.ZOffset and pData.ZOffset ~= 0
	if hasO or hasZ then pData._postUpdateCF = (t == "Model") and pData.VisualPart:GetPivot() or pData.VisualPart.CFrame end
	if hasO then self:ApplyOrientation(pData, 1/60, camPos) end
	if hasZ then self:ApplyZOffset(pData, camPos) end
end

-- Activate / Deactivate / GetFolder / GetPoolFolder live in Modules/Part/Engine.luau (mixin).

-- One-shot emit. Dispatches to the per-type EmitX. `link` is optional  -  for types that support
-- Linking (Parts / Attachment / Model), pass the instance whose CFrame the emit is tied to.
-- `emitCtx` is an optional context table propagated by the Events runtime + EnableEmitAt:
--   { ChainCtx = {ChainId, Depth}, EmitIndex = 1-based, EventOriginCF = CFrame, IgnoreLink = bool }
-- EventOriginCF + IgnoreLink are honoured by EmitPart / EmitAttachment / EmitModel for origin
-- override. Other types ignore those fields and emit at their authored CFrame.
function Particle:Emit(item, link, emitCtx)
	if not item or not item.Parent then return end
	self:_warnIfNotActivated("Emit")
	-- Hard cap on concurrent particles. Skip the visual emit but let Events.fire's
	-- user-Module spawn continue (Module is spawned separately, not from this dispatch).
	-- Once-per-second warn so a sustained overflow doesn't flood Output with one warn
	-- per dropped emit.
	-- Lingering visuals (PartLife > 0 path in Lifecycle) outlive their ActiveEmits entry
	-- but still consume world resources, so they count against the cap. _lingerVisualCount
	-- is incremented when a visual enters linger, decremented on destroy (or via
	-- _lingerCounted attribute idempotency).
	local cap = self.MAX_ACTIVE_PARTICLES or 1000
	if #self.ActiveEmits + (self._lingerVisualCount or 0) >= cap then
		local now = os.clock()
		if now - (self._capWarnLastAt or 0) >= 1 then
			self._capWarnLastAt = now
			Log.warn(("[Part-Icles] active particle cap (%d) reached  -  new emits skipped (user Module code still runs)."):format(cap))
		end
		return
	end
	if item:IsA("Beam") and item:FindFirstChild("PartIcleProperties") then
		self:EmitBeam(item, link, emitCtx)
	elseif item:IsA("Beam") or (item:IsA("Trail") and not item:FindFirstChild("PartIcleProperties")) then
		-- directAccess Beam (BeamNative) or directAccess Trail: no emit pipeline. Schedule the
		-- enable-for-Duration toggle that doEmitOnce uses so API-level Particle:Emit has parity.
		-- Trail's EmitDuration is sometimes a "min,max" string  -  take max for the schedule.
		local raw, d = item:GetAttribute("EmitDuration"), 0
		if typeof(raw) == "number" then d = raw
		elseif raw ~= nil then local m1, m2 = tostring(raw):match("([%-%.%d]+)%s*,%s*([%-%.%d]+)")
			d = (m1 and m2) and math.max(tonumber(m1) or 0, tonumber(m2) or 0) or (tonumber(tostring(raw)) or 0)
		end
		if d > 0 then
			task.delay(item:GetAttribute("EmitDelay") or 0, function()
				if not (item and item.Parent) then return end
				item.Enabled = true
				task.delay(d, function() if item and item.Parent then item.Enabled = false end end)
			end)
		end
	elseif item:IsA("Trail") then
		self:EmitTrail(item, link, emitCtx)
	elseif item:IsA("Light") then
		self:EmitPointLight(item, link, emitCtx)
	elseif item:IsA("Sound") then
		self:EmitSound(item, link, emitCtx)
	elseif item:IsA("Highlight") then
		self:EmitHighlight(item, link, emitCtx)
	elseif item:IsA("Attachment") then
		self:EmitAttachment(item, link, emitCtx)
	elseif item:IsA("Model") then
		self:EmitModel(item, link, emitCtx)
	elseif item:IsA("BlurEffect") then
		self:EmitBlur(item, link, emitCtx)
	elseif item:IsA("BloomEffect") then
		self:EmitBloom(item, link, emitCtx)
	elseif item:IsA("ColorCorrectionEffect") then
		self:EmitColorCorrection(item, link, emitCtx)
	elseif item:IsA("Atmosphere") then
		self:EmitAtmosphere(item, link, emitCtx)
	elseif item:IsA("ImageLabel") then
		self:EmitImageLabel(item, link, emitCtx)
	-- Lightning / CameraShake / Rocks / Rope before the BasePart fallback or they route to EmitPart.
	elseif Particle._isLightning(item) then
		self:EmitLightning(item, link, emitCtx)
	elseif Particle._isCameraShake(item) then
		self:EmitCameraShake(item, link, emitCtx)
	elseif Particle._isRocks(item) then
		self:EmitRocks(item, link, emitCtx)
	elseif Particle._isRope(item) then
		self:EmitRope(item, link, emitCtx)
	elseif Particle._isDistortion(item) then
		self:EmitDistortion(item, link, emitCtx)
	elseif item:IsA("BasePart") then
		self:EmitPart(item, link, emitCtx)
	end
	-- Unknown / unwired types silently no-op.
end

-- Particle:Enable, Particle:Disable, Particle:EmitAnimate, Particle:EnableEmit, and the
-- local cancelAnimation helper live in Modules/Part/Lifecycle.luau (loaded as a mixin above).

-- Recursive fire-everything-under-root. For a transformed item, runs EnableEmit (full emit timing).
-- For a raw ParticleEmitter / Trail, fires its native API directly. Walks descendants so one call
-- on a Folder/Model containing many emitters fires them all. `_parentFiredPE` is an internal flag
-- that prevents double-firing when an ancestor already covered a subtree's native PEs via
-- ParticlesMod.EnableEmit (which internally uses GetDescendants).
local _Duration = require(script.Duration)

-- Yield helper. Companion to Particle:AbsoluteEmit's duration return value.
-- Called as `Particle.await(n)` (no colon). Nil / non-positive durations are no-ops
-- so `Particle.await(Particle:AbsoluteEmit(item))` is safe for infinite-cycle emitters.
function Particle.await(n)
	if n == nil then return end
	if type(n) ~= "number" then return end
	if n <= 0 then return end
	task.wait(n)
end

-- _absoluteEmitFire dispatches the actual emit recursion; AbsoluteEmit wraps it +
-- computes the true wall-clock duration. Split keeps the recursive Activate-warn
-- to fire once at the top level instead of every nested descendant call.
function Particle:_absoluteEmitFire(item, _parentFiredPE, emitCtx)
	if item:GetAttribute("Transformed") then
		self:EnableEmit(item, nil, emitCtx)
		return
	end

	-- Engine-session predicate threaded into native PE/Trail helpers so a delayed
	-- :Emit / :Enable doesn't fire after Particle:Deactivate.
	local alive = self:_makeAliveCheck()

	-- Raw ParticleEmitter: fire directly. EmitCount defaults to 1 when the attribute is absent,
	-- matching the Studio Emit button's inline behavior. tonumber coerces string-typed attrs
	-- (e.g. EmitCount="5" set via Studio's attribute UI) so the `<= 0` comparison can't error.
	if item:IsA("ParticleEmitter") then
		if _parentFiredPE then return end
		local count = tonumber(item:GetAttribute("EmitCount")) or 1
		local emitDelay = tonumber(item:GetAttribute("EmitDelay")) or 0
		local emitDuration = tonumber(item:GetAttribute("EmitDuration")) or 0
		-- Zero-as-zero  -  see Modules/Part/Particles.luau.
		if count <= 0 and emitDuration <= 0 then return end
		-- Capture the native gen at schedule time so an AbsoluteDisable during EmitDelay
		-- invalidates this delayed start instead of resurrecting the emitter past the delay.
		local scheduledGen = ParticlesMod.ReadNativeGen(item)
		local function doEmit()
			if not alive() or not ParticlesMod.IsNativeGenCurrent(item, scheduledGen) then return end
			if count > 0 then item:Emit(count) end
			-- SetEnabledForDuration schedules a native-gen-tokened delayed-off so the
			-- cleanup still runs even after engine death, while a newer emit session
			-- bumping the gen prevents this closure from clobbering its window.
			if emitDuration > 0 then ParticlesMod.SetEnabledForDuration(item, emitDuration) end
		end
		if emitDelay > 0 then task.delay(emitDelay, doEmit) else doEmit() end
		return
	end

	-- Raw Trail: delegate to existing single-instance helper (parses EmitDuration range).
	if item:IsA("Trail") then
		if _parentFiredPE then return end
		ParticlesMod.EnableEmitSingle(item, alive)
		return
	end

	-- Raw Beam: continuous-streak rendering between authored Attachment0 / Attachment1.
	-- EmitDuration attribute gates a timed Enable-for-duration window; absent / zero leaves
	-- the authored Enabled state alone. No EmitCount semantic (Beams stream, not burst).
	if item:IsA("Beam") then
		if _parentFiredPE then return end
		local emitDuration = tonumber(item:GetAttribute("EmitDuration")) or 0
		local emitDelay = tonumber(item:GetAttribute("EmitDelay")) or 0
		if emitDuration > 0 then
			local scheduledGen = ParticlesMod.ReadNativeGen(item)
			local function doEmit()
				if not alive() or not ParticlesMod.IsNativeGenCurrent(item, scheduledGen) then return end
				ParticlesMod.SetEnabledForDuration(item, emitDuration)
			end
			if emitDelay > 0 then task.delay(emitDelay, doEmit) else doEmit() end
		end
		return
	end

	-- Fire native PEs for BaseParts and Attachments.
	-- Skip if a parent already called EnableEmit (which uses GetDescendants, so our PEs are already covered).
	local shouldFirePE = (item:IsA("BasePart") or item:IsA("Attachment") or item:IsA("Model")) and not _parentFiredPE
	if shouldFirePE then ParticlesMod.EnableEmit(item, alive) end

	-- Propagate the "covered" state: if we fired here OR an ancestor fired, children are already
	-- covered. The `or _parentFiredPE` term keeps a suppressed intermediate (e.g. an Attachment
	-- inside an already-fired Part) from clearing the flag  -  descendant PEs would double-fire.
	local firedCovered = shouldFirePE or _parentFiredPE
	for _, child in item:GetChildren() do
		if item:IsA("BasePart") and child:IsA("BasePart") and not child:GetAttribute("Transformed") then
			continue
		end
		self:_absoluteEmitFire(child, firedCovered, emitCtx)
	end
end

-- Recursive emit. Walks `item` + descendants firing every emitter:
--   - Transformed item → :EnableEmit (honors EmitCount + EmitDelay + EmitDuration).
--   - Raw ParticleEmitter → :Emit(count) + Enabled-for-duration window.
--   - Raw Trail → :EnableEmitSingle.
--   - Raw Beam → SetEnabledForDuration.
--   - BasePart / Attachment / Model → ParticlesMod.EnableEmit covers all native PE/Trail
--     descendants at once; recursion threads `firedCovered` so nested raw emitters
--     aren't double-fired.
-- Returns total real-time wallclock duration in seconds across every spawned effect
-- (EmitDelay + EmitDuration + Timescale-distorted Lifetime + PartLife, recursing
-- nested transformed descendants). Returns nil when any branch is effectively infinite
-- (AnimateLoop unbounded, Timescale=0, or Timescale terminal value with wrong sign).
-- Pair with .await(n) for emit-and-wait. emitCtx threads through (see file header).
function Particle:AbsoluteEmit(item, _parentFiredPE, emitCtx)
	self:_warnIfNotActivated("AbsoluteEmit")
	if not item then return 0 end
	self:_absoluteEmitFire(item, _parentFiredPE, emitCtx)
	return _Duration.computeMaxDuration(item, 0)
end

-- Particle:EnableEmitAt / AbsoluteEmitAt live in EmitAt.luau (mixin).

-- AbsoluteEnable / AbsoluteDisable live in Lifecycle.luau alongside Particle:Disable so the
-- single-item and recursive-state APIs share a file. Same recursion shape as AbsoluteEmit
-- (Transformed → engine path; raw PE/Trail → native .Enabled; container → walk descendants
-- skipping transformed sub-emitter RTs).

-- Preload / Deload API  -  texture-pin every texture-bearing item under `root`. Use `Preload` before
-- a skill cast so the first emit doesn't stutter on texture decode; `Deload` after the skill is
-- permanently retired to free GPU memory. Only items with `PreloadTexture=true` are touched unless
-- `force=true` is passed, in which case every transformed item / raw PE / raw Trail under root
-- gets pinned regardless of opt-in.
local _TexturePin = require(script.TexturePin)
local function _isPreloadable(i) return i:GetAttribute("Transformed") or i:IsA("ParticleEmitter") or i:IsA("Trail") end
local function _walk(root, force, action)
	if not root then return end
	local function visit(inst)
		if _isPreloadable(inst) and (force or inst:GetAttribute("PreloadTexture") == true) then action(inst) end
		for _, c in inst:GetChildren() do visit(c) end
	end
	visit(root)
end
-- Texture-pin every PreloadTexture=true descendant under `root` so the first emit
-- after Preload doesn't stall on texture decode. `force=true` pins every transformed
-- item / raw PE / raw Trail regardless of opt-in.
function Particle:Preload(root, force) _walk(root, force, _TexturePin.pinSubtree) end
-- Inverse of Preload; releases pinned textures so the engine can free GPU memory.
function Particle:Deload(root, force) _walk(root, force, _TexturePin.unpinSubtree) end

-- Standalone LinkService API. Reuses LinkMode dispatch on arbitrary BaseParts /
-- Models / Attachments  -  independent from the particle emit pipeline.
Particle.LinkService = require(script.LinkService)
-- Console gate: `Particle.Log.enabled = false` silences the runtime's prints / warns (plugin: Settings toggle).
Particle.Log = Log
Particle.parseDuration = ParticlesMod.parseDuration

-- Mutate the source item's authored Link/EmitParent. Use these for persistent
-- runtime wiring; per-call EnableEmitAt/AbsoluteEmitAt options are ephemeral unless Persist=true.

-- target: Instance -> Link.Value + LinkSource="Object"
--         "camera"  -> LinkSource="Camera"
--         nil       -> LinkSource="None" + clear Link.Value
-- mode: optional, "Follow" / "Pivot" / "Weld" / "WeldWithoutRotation"
function Particle:SetLink(item, target, mode)
	if not item or not item:GetAttribute("Transformed") then return end
	if target == "camera" then
		pcall(function() item:SetAttribute("LinkSource", "Camera") end)
	elseif target == nil then
		pcall(function() item:SetAttribute("LinkSource", "None") end)
		local lk = item:FindFirstChild("Link")
		if lk and lk:IsA("ObjectValue") then lk.Value = nil end
	elseif typeof(target) == "Instance" then
		local lk = item:FindFirstChild("Link")
		if not lk then
			lk = Instance.new("ObjectValue")
			lk.Name = "Link"
			lk.Parent = item
		end
		lk.Value = target
		pcall(function() item:SetAttribute("LinkSource", "Object") end)
	end
	if mode then pcall(function() item:SetAttribute("LinkMode", mode) end) end
end

-- parent: Instance -> EmitParent.Value (cloned visuals go there)
--         nil      -> remove EmitParent (engine default emit folder used)
function Particle:SetEmitParent(item, parent)
	if not item or not item:GetAttribute("Transformed") then return end
	if parent == nil then
		local ep = item:FindFirstChild("EmitParent")
		if ep then pcall(function() ep:Destroy() end) end
		return
	end
	if typeof(parent) ~= "Instance" then return end
	local ep = item:FindFirstChild("EmitParent")
	if not ep then
		ep = Instance.new("ObjectValue")
		ep.Name = "EmitParent"
		ep.Parent = item
	end
	ep.Value = parent
end

-- Luau autocomplete + IntelliSense: the mixin pattern `require(script.X)(Particle)`
-- attaches methods at runtime, which Luau's static analyzer cannot follow. The cast
-- below tells the analyzer the public shape so users typing `Part:` see every API.
-- Field types are conservative (Instance + any) since most accept multiple authoring
-- types via internal dispatch (BasePart / Attachment / Model / Beam / etc.).
export type ParticleAPI = {
	-- Lifecycle
	Activate: (self: ParticleAPI) -> (),
	Deactivate: (self: ParticleAPI) -> (),
	Enable: (self: ParticleAPI, item: Instance, link: Instance?, duration: number?, emitCtx: any?) -> (),
	Disable: (self: ParticleAPI, item: Instance) -> (),
	SoftDisable: (self: ParticleAPI, item: Instance) -> (),
	AbsoluteEnable: (self: ParticleAPI, item: Instance) -> (),
	AbsoluteDisable: (self: ParticleAPI, item: Instance) -> (),

	-- Emit
	Emit: (self: ParticleAPI, item: Instance, link: Instance?, emitCtx: any?) -> (),
	EmitAnimate: (self: ParticleAPI, item: Instance, link: Instance?, emitCtx: any?) -> (),
	EnableEmit: (self: ParticleAPI, item: Instance, link: Instance?, emitCtx: any?) -> (),
	EnableEmitAt: (self: ParticleAPI, item: Instance, origin: CFrame | Vector3 | Instance, options: {[string]: any}?) -> (any, number?),
	AbsoluteEmit: (self: ParticleAPI, item: Instance, _parentFiredPE: boolean?, emitCtx: any?) -> number?,
	AbsoluteEmitAt: (self: ParticleAPI, item: Instance, origin: CFrame | Vector3 | Instance, options: {[string]: any}?) -> (any, number?),

	-- Timescale
	SetTimescale: (self: ParticleAPI, item: Instance, scale: number, duration: number?, permanent: boolean?) -> (),
	ClearTimescale: (self: ParticleAPI, item: Instance) -> (),
	AbsoluteSetTimescale: (self: ParticleAPI, item: Instance, scale: number, duration: number?, permanent: boolean?) -> (),
	AbsoluteClearTimescale: (self: ParticleAPI, item: Instance) -> (),

	-- Authoring + utilities
	Transform: (self: ParticleAPI, part: Instance) -> (),
	TransformModel: (self: ParticleAPI, model: Model, typeDef: any) -> (),
	Preload: (self: ParticleAPI, root: Instance, force: boolean?) -> (),
	Deload: (self: ParticleAPI, root: Instance, force: boolean?) -> (),
	SetLink: (self: ParticleAPI, item: Instance, target: (Instance | string)?, mode: string?) -> (),
	SetEmitParent: (self: ParticleAPI, item: Instance, parent: Instance?) -> (),
	GetData: (self: ParticleAPI, item: Instance) -> any,
	GetFolder: (self: ParticleAPI) -> Folder,
	GetPoolFolder: (self: ParticleAPI) -> Folder,
	ReapplyLink: (self: ParticleAPI, pData: any) -> (),

	-- Statics
	await: (n: number?) -> (),
	parseDuration: (raw: any) -> number?,
	LinkService: typeof(require(script.LinkService)),
	TransformCompleted: BindableEvent,
	Beam: {[string]: any},
	MAX_ACTIVE_PARTICLES: number,
	ActiveEmits: {any},
	ActiveLoops: {[Instance]: thread},
	ActiveAnimates: {[Instance]: any},
}

return Particle :: ParticleAPI
