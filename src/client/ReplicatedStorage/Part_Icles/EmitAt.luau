--[[
	EmitAt  -  mixin: Particle:EnableEmitAt (one item) and Particle:AbsoluteEmitAt (item + descendants),
	the origin-override emits. Both return a PlayHandle scoped to the call.
]]

local ParticlesMod = require(script.Parent.Particles)
local PlayHandle = require(script.Parent.PlayHandle)
local EventsSchema = require(script.Parent.EventsSchema)
local Constants = require(script.Parent.PartConstants)
local Log = require(script.Parent.Log)
local _Duration = require(script.Parent.Duration)

-- Warn once per key: rejected calls and in-place fallbacks are authoring errors, not per-frame noise.
local warned = {}
local function warnOnce(key, message)
	if warned[key] then return end
	warned[key] = true
	Log.warn(message)
end

-- A node that cannot take an origin still emits in place. EventsSchema.emitCapabilityReason is the
-- single source shared with Events/EmitTarget.
local function warnInPlace(node)
	local reason = EventsSchema.emitCapabilityReason(node)
	if not reason then return end
	warnOnce(node.ClassName .. ":" .. tostring(node:GetAttribute("EmissionMode")),
		("[Part-Icles] EmitAt: %s emits in place: %s"):format(node:GetFullName(), reason))
end

-- Origin forms: CFrame as given; Vector3 = position only (the emitter keeps its rotation); an
-- instance with a frame (BasePart / Model / Attachment / Bone / Camera) = its live frame, re-read
-- at spawn so a delayed emit follows it. Returns cf, resolver, fullPose; or nil, reason.
local function resolveOrigin(origin, options)
	local kind = typeof(origin)
	local fullPose = options.UseFullOrigin ~= false
	if kind == "CFrame" then return origin, options.OriginResolver, fullPose end
	if kind == "Vector3" then return CFrame.new(origin), options.OriginResolver, false end
	if kind == "Instance" and (origin:IsA("PVInstance") or origin:IsA("Attachment") or origin:IsA("Camera")) then
		local resolver = options.OriginResolver or function()
			if origin.Parent == nil then return nil end
			return Constants.resolveLinkCFrame(origin)
		end
		return Constants.resolveLinkCFrame(origin), resolver, fullPose
	end
	local got = kind == "Instance" and origin.ClassName or kind
	return nil, ("origin must be a CFrame, a Vector3 or an instance with a position (got %s)"):format(got)
end

-- The play's link: "camera" or an Instance. nil when absent, or when Persist writes it to the source.
local function playLink(options)
	if options.Persist == true then return nil end
	local link = options.Link
	if link == "camera" then return workspace.CurrentCamera end
	if typeof(link) == "Instance" then return link end
	return nil
end

-- Per-play overrides carried on emitCtx.Overrides: EnableEmit reads Count / Delay / Duration,
-- GetEmitData reads LinkMode / EmitParent. Nothing is written to the source item.
local function buildOverrides(options)
	local overrides = {}
	if options.Persist ~= true then
		if options.LinkMode ~= nil then
			overrides.LinkMode = options.LinkMode
		elseif options.Link ~= nil then
			overrides.LinkMode = "Weld"
		end
		if options.EmitParent ~= nil then overrides.EmitParent = options.EmitParent end
	end
	if typeof(options.Count) == "number" then overrides.Count = options.Count end
	if typeof(options.Delay) == "number" then overrides.Delay = options.Delay end
	if options.Duration ~= nil then overrides.Duration = options.Duration end
	if next(overrides) == nil then return nil end
	return overrides
end

-- Persist = true: write Link / EmitParent onto the source as authored state.
local function persistAuthoring(self, node, options)
	if options.Link ~= nil then self:SetLink(node, options.Link, options.LinkMode or "Weld") end
	if options.EmitParent ~= nil then self:SetEmitParent(node, options.EmitParent) end
end

return function(Particle)

-- Shared per-call state for both entry points; nil (after a warning) when the call is rejected.
local function beginPlay(self, item, origin, options, apiName)
	self:_warnIfNotActivated(apiName)
	options = options or {}
	if not item or not item.Parent then
		warnOnce(apiName .. ":item", ("[Part-Icles] %s: item is nil or has no parent; nothing emitted."):format(apiName))
		return nil
	end
	local originCF, resolver, fullPose = resolveOrigin(origin, options)
	if not originCF then
		warnOnce(apiName .. ":" .. tostring(resolver), ("[Part-Icles] %s: %s; nothing emitted."):format(apiName, tostring(resolver)))
		return nil
	end
	local overrides = buildOverrides(options)
	local totalDur = _Duration.computeMaxDuration(item, 0, overrides)
	-- Per-play "ghost": every particle spawned by THIS call carries token; the returned
	-- PlayHandle scopes Disable / SetTimescale / GetParticles to this play, not the shared
	-- source. token.Loops collects continuous-loop tasks; token.Clones collects branch-B
	-- raw clones. Threaded via emitCtx._playToken → _registerEmit stamps each pData.
	local token = { Alive = true, Loops = {}, Clones = {}, Duration = totalDur }
	return {
		options = options,
		originCF = originCF,
		resolver = resolver,
		fullPose = fullPose,
		overrides = overrides,
		token = token,
		handle = PlayHandle.new(self, token),
		totalDur = totalDur,
		link = playLink(options),
		-- LinkOverride: spawn at the LIVE link CFrame and ignore the origin, so a delayed / moving-link
		-- emit follows the link instead of trailing at the call-time origin.
		linkWins = options.LinkOverride == true and options.Link ~= nil,
	}
end

-- emitCtx for one node; `originCF` / `resolver` are that node's own (offset for containers).
local function buildCtx(play, originCF, resolver)
	local options = play.options
	local ctx = {
		ChainCtx      = options.ChainCtx,
		UseFullOrigin = play.fullPose,
		-- A play link beats IgnoreLink (Events set IgnoreLink with no link of their own).
		IgnoreLink    = options.IgnoreLink == true and play.link == nil,
		EventDriven   = options.EventDriven == true,
		Overrides     = play.overrides,
		_playToken    = play.token,
		_playLink     = play.link,
	}
	-- linkWins drops the origin so Emit's link branch spawns at the live link.
	if not play.linkWins then
		ctx.EventOriginCF = originCF
		ctx.EventOriginResolver = resolver
	end
	return ctx
end

-- Transformed root: persist authoring when asked, then fire the engine pipeline.
local function emitTransformedRoot(self, item, play)
	warnInPlace(item)
	if play.options.Persist == true then persistAuthoring(self, item, play.options) end
	self:EnableEmit(item, play.link, buildCtx(play, play.originCF, play.resolver))
	return play.handle, play.totalDur
end

-- One transformed item at an origin. Options and returns as AbsoluteEmitAt; containers are its job.
function Particle:EnableEmitAt(item, origin, options)
	local play = beginPlay(self, item, origin, options, "EnableEmitAt")
	if not play then return PlayHandle.inert(self), 0 end
	if not item:GetAttribute("Transformed") then
		warnOnce("EnableEmitAt:" .. item.ClassName, ("[Part-Icles] EnableEmitAt: %s is not a Part-Icle; use AbsoluteEmitAt for containers and raw emitters. Nothing emitted."):format(item:GetFullName()))
		return PlayHandle.inert(self), 0
	end
	return emitTransformedRoot(self, item, play)
end

-- Recursive :EnableEmitAt. Two-pass hybrid:
--
-- (A) `item` IS a transformed Part-Icle:
--   Emit via the existing engine pipeline with origin override threaded through
--   emitCtx. No clone of the source  -  engine handles nested transformed descendants
--   automatically via the standard emit pipeline.
--
-- (B) `item` is a non-transformed 3D container (BasePart / Model / Attachment):
--   Pass 1  -  every transformed Part-Icle descendant emits via engine pipeline with
--   per-node origin override (its authored offset from the container pivot, carried into
--   the origin). NO clone of any transformed item. Each Part-Icle's 60+ attributes /
--   RenderTemplate stay in place; only the engine's per-emit Pool.acquireOrClone is invoked.
--   Pass 2  -  clone the container WITHOUT its transformed descendants (stripped from
--   the clone) so only the non-transformed parts + raw PE / Trail / Beam survive.
--   Anchor + PivotTo the clone to the origin, parent into emit folder, fire raw
--   native dispatch on the clone, scheduled destroy after the clone's own duration.
--
-- Result: transformed Part-Icles use the lightweight engine-level origin override
-- (no 60+ attribute copy). Raw native emitters get their proper clone-and-place
-- treatment. Repeated calls are independent (each call clones a fresh raw subtree).
--
-- origin: CFrame; Vector3 (position only); or an instance with a frame, followed live.
--
-- options (optional table):
--   ChainCtx            event-chain context
--   OriginResolver      function() -> CFrame, evaluated at spawn time (live origin). On a
--                       container it is re-resolved per node so the layout survives EmitDelay
--   UseFullOrigin       bool; true carries the container layout + rotation into the origin
--                       (AtCFrame); false translates only, every node keeps its own rotation.
--                       Default true (a Vector3 origin is always position only)
--   IgnoreLink          bool; bypass authored Link. Default false. A play Link wins over it
--   Link                Instance or "camera"; every emitter this call fires links to it for
--                       this play only. nil = authored Link
--   LinkMode            string; "Follow" / "Pivot" / "Weld" / "WeldWithoutRotation" / "RigidLocal".
--                       Defaults to "Weld" when Link is set and LinkMode omitted
--   EmitParent          Instance; where this play's clones parent, this play only
--   Count / Delay / Duration
--                       per-play EmitCount / EmitDelay / EmitDuration for every transformed
--                       emitter this call fires (Duration takes a number or "min,max"); raw
--                       ParticleEmitters and nested emitters inside RenderTemplates keep theirs
--   Persist             bool; write Link / LinkMode / EmitParent onto the source with SetLink /
--                       SetEmitParent instead of keeping them per play. Default false
--   ApplyToAll          bool; with Persist on a container, also write Link / EmitParent to every
--                       transformed descendant. Default false
--   LinkOverride        bool; with Link set, spawn at the LIVE link CFrame (central) and
--                       ignore the origin. Fixes a delayed / moving-link emit trailing at the
--                       call-time origin. Collapses a multi-node container to the link center
--   EventDriven         bool; Events dispatch. EnableEmit floors EmitCount 0 to one burst
--
-- Returns the PlayHandle (inert after a rejected call, never nil) and the total real-time
-- duration (nil for infinite). Pair with handle:Wait() or .await(duration).
function Particle:AbsoluteEmitAt(item, origin, options)
	local play = beginPlay(self, item, origin, options, "AbsoluteEmitAt")
	if not play then return PlayHandle.inert(self), 0 end
	options = play.options
	local originCF = play.originCF
	local fullPose = play.fullPose
	local token = play.token
	local handle = play.handle
	local totalDur = play.totalDur

	-- (A) Transformed root.
	if item:GetAttribute("Transformed") then
		return emitTransformedRoot(self, item, play)
	end

	-- Raw Trail / Beam roots have no frame of their own: fire in place.
	if item:IsA("Trail") or item:IsA("Beam") then
		self:_absoluteEmitFire(item, nil, nil)
		return handle, totalDur
	end

	-- (B) Non-transformed 3D container (or a raw ParticleEmitter): hybrid two-pass.
	if not (item:IsA("BasePart") or item:IsA("Model") or item:IsA("Attachment") or item:IsA("ParticleEmitter")) then
		warnOnce("AbsoluteEmitAt:" .. item.ClassName, ("[Part-Icles] AbsoluteEmitAt: %s has no position; pass a Part / Model / Attachment / ParticleEmitter or a transformed item. Nothing emitted."):format(item:GetFullName()))
		return PlayHandle.inert(self), 0
	end

	-- Snapshot anchorCF so per-node origin (Pass 1) + clone reposition (Pass 2) both
	-- reference the same authored pivot baseline.
	local anchorCF
	if item:IsA("Model") then
		local ok, p = pcall(item.GetPivot, item); if ok then anchorCF = p end
	elseif item:IsA("BasePart") then anchorCF = item.CFrame
	elseif item:IsA("Attachment") then anchorCF = item.WorldCFrame
	elseif item:IsA("ParticleEmitter") then
		-- A raw emitter borrows its host's frame so the holder inherits the authored rotation.
		local host = item.Parent
		if host and host:IsA("BasePart") then anchorCF = host.CFrame
		elseif host and host:IsA("Attachment") then anchorCF = host.WorldCFrame end
	end

	local function readWorldCF(it)
		if it:IsA("Model") then local ok, cf = pcall(it.GetPivot, it); return ok and cf or nil end
		if it:IsA("Attachment") then return it.WorldCFrame end
		if it:IsA("BasePart") then return it.CFrame end
		return nil
	end

	-- Node origin inside `base`: full pose carries the authored layout into the origin frame;
	-- position-only translates it so every node keeps its own rotation (mirrors
	-- Events/EmitTarget.childOrigin; Pass 2 places the raw clone the same way).
	local function originFor(base, node)
		if not anchorCF then return base end
		local nodeCF = readWorldCF(node)
		if not nodeCF then return base end
		if fullPose then return base * anchorCF:ToObjectSpace(nodeCF) end
		return nodeCF + (base.Position - anchorCF.Position)
	end

	local function ctxFor(node)
		local resolver = play.resolver
		local nodeResolver
		if resolver then
			-- Re-resolve per node: a bare resolver would collapse every node onto the
			-- container origin once EmitDelay passes.
			nodeResolver = function()
				local live = resolver()
				if not live then return nil end
				return originFor(live, node)
			end
		end
		return buildCtx(play, originFor(originCF, node), nodeResolver)
	end

	-- Persist with ApplyToAll (or LinkOverride): write Link / EmitParent onto every transformed
	-- descendant before Pass 1 so each leaf's GetData read picks up the authoring.
	if options.Persist == true and (options.ApplyToAll or play.linkWins) then
		local function applyAuthoring(node)
			if node:GetAttribute("Transformed") then persistAuthoring(self, node, options) end
			for _, child in node:GetChildren() do applyAuthoring(child) end
		end
		applyAuthoring(item)
	end

	-- Pass 1: per-node origin override for transformed Part-Icles on the ORIGINAL.
	-- Walks down stopping at each transformed leaf (engine pipeline recurses inside
	-- the leaf's RenderTemplate during emit, so we don't recurse past it ourselves).
	local function walkTransformed(node)
		if node:GetAttribute("Transformed") then
			warnInPlace(node)
			self:EnableEmit(node, play.link, ctxFor(node))
			return
		end
		for _, child in node:GetChildren() do
			walkTransformed(child)
		end
	end
	walkTransformed(item)

	-- Internal SkipClone path: caller owns the cloneRoot lifecycle (pool acquire +
	-- positioning + release). Skip Pass 2's clone+anchor+pivot+destroy block; fire
	-- raw native PE/Trail/Beam descendants in-place on the caller's pre-positioned
	-- subtree. Events/EmitTarget.luau uses this so its pool reuse + Folder/PE wrappers stay
	-- intact while still picking up Pass 1's per-node origin override semantics.
	if options.SkipClone then
		ParticlesMod.EnableEmit(item, self:_makeAliveCheck())
		return handle, totalDur
	end

	-- Pass 2: detect raw native emitters not covered by Pass 1. Skip Pass 2 entirely
	-- when nothing raw exists (saves the clone cost for pure Part-Icle containers).
	local function _underTransformedAncestor(desc)
		local cur = desc.Parent
		while cur and cur ~= item do
			if cur:GetAttribute("Transformed") then return true end
			cur = cur.Parent
		end
		return false
	end
	local hasRawEmitter = item:IsA("ParticleEmitter")
	for _, desc in ipairs(item:GetDescendants()) do
		if (desc:IsA("ParticleEmitter") or desc:IsA("Trail") or desc:IsA("Beam"))
			and not desc:GetAttribute("Transformed")
			and not _underTransformedAncestor(desc) then
			hasRawEmitter = true; break
		end
	end
	if not hasRawEmitter then return handle, totalDur end

	local ok, clone = pcall(item.Clone, item)
	if not ok or not clone then return handle, totalDur end
	pcall(function() clone.Archivable = false end)

	-- Strip transformed descendants from the clone (Pass 1 fired them on the
	-- original; keeping them in the clone would double-fire + waste the clone of
	-- their 60+ attributes).
	for _, desc in ipairs(clone:GetDescendants()) do
		if desc:GetAttribute("Transformed") then pcall(function() desc:Destroy() end) end
	end
	-- The stripped clone holds only raw emitters, so its own window bounds the destroy
	-- (the container total can be nil through an infinite transformed sibling).
	local cloneDur = _Duration.computeMaxDuration(clone, 0) or 60

	-- Anchor every remaining BasePart in the clone so PivotTo holds.
	if clone:IsA("BasePart") then pcall(function() clone.Anchored = true end) end
	for _, desc in ipairs(clone:GetDescendants()) do
		if desc:IsA("BasePart") then pcall(function() desc.Anchored = true end) end
	end

	-- Compute target CFrame. UseFullOrigin=true → the origin as-is. UseFullOrigin=false
	-- → use the origin's position with the container's authored rotation.
	local targetCF = originCF
	if not fullPose and anchorCF then
		targetCF = CFrame.new(originCF.Position) * anchorCF.Rotation
	end
	if clone:IsA("Model") then
		pcall(function() clone:PivotTo(targetCF) end)
	elseif clone:IsA("BasePart") then
		-- PivotTo carries descendant parts along; the PivotOffset term lands the part's own
		-- CFrame (the anchor baseline) on targetCF.
		pcall(function() clone:PivotTo(targetCF * clone.PivotOffset) end)
	else
		-- Attachment / ParticleEmitter roots ride an invisible holder Part placed at targetCF.
		local holder = Instance.new("Part")
		holder.Name = "_EmitHolder"
		holder.Anchored = true
		holder.CanCollide = false
		holder.CanQuery = false
		holder.CanTouch = false
		holder.Massless = true
		holder.Transparency = 1
		holder.Size = Vector3.new(0.001, 0.001, 0.001)
		holder.Archivable = false
		-- Box-shaped emitters keep their authored emission area.
		if clone:IsA("ParticleEmitter") and item.Parent and item.Parent:IsA("BasePart") then
			holder.Size = item.Parent.Size
		end
		holder.CFrame = targetCF
		if clone:IsA("Attachment") then clone.CFrame = CFrame.new() end
		clone.Parent = holder
		clone = holder
	end

	clone.Parent = self:GetFolder()
	-- Track the raw clone on the play so PlayHandle:Disable tears it down early.
	table.insert(token.Clones, clone)
	-- Fire raw dispatch on the stripped clone. Transformed branch in _absoluteEmitFire
	-- is unreachable post-strip; only the raw PE / Trail / Beam / native-walk branches fire.
	self:_absoluteEmitFire(clone, nil, nil)

	task.delay(cloneDur, function()
		if clone and clone.Parent then pcall(function() clone:Destroy() end) end
	end)

	return handle, totalDur
end

end
