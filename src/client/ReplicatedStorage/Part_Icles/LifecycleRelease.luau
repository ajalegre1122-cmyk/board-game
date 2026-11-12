--[[
	LifecycleRelease Mixin  -  end-of-life helpers shared by Engine reclaim paths and finishAnimate:
	_fireOnDeath / _fireOnDestruction (event dispatch) and _releaseOrDestroy (pool release vs Destroy).
	Split from Lifecycle.luau for the 500-line cap.
]]

local TypeRegistry = require(script.Parent.TypeRegistry)
local Events = require(script.Parent.Events)
local Pool = require(script.Parent.Pool)
local VisualHost = require(script.Parent.VisualHost)

return function(Particle)

	-- Bookkeeping every ActiveEmits removal route runs (Engine death / one-shot finish /
	-- Deactivate, Disable sweep, PlayHandle:Disable, cancelAnimation, cap-reject): flips the
	-- nested-alive flag so pending nested closures and duration loops stop. Callers still pop the entry from ActiveEmits themselves.
	-- Animate pData whose VisualPart IS the source's live RenderTemplate. Every destroy path
	-- (Deactivate, cap-reject, PlayHandle / Disable sweeps) must restore it, never Destroy it.
	function Particle:_isLiveRTAnimate(pData)
		if not pData.IsAnimate then return false end
		local t = pData.Type
		return t == "Part" or t == "Attachment" or t == "Beam" or t == "Model" or t == "Highlight" or t == "TrailEmitter"
	end

	function Particle:_reclaimPData(pData)
		if pData._nestedAlive then pData._nestedAlive[1] = false end
	end

	-- OnDeath fire helper; manual Kill suppresses unless fireOnDeath=true.
	function Particle:_fireOnDeath(pData)
		if pData.Events and pData.Events.OnDeath
			and (not pData._killedManually or pData._fireOnDeathOverride) then
			Events.fire(self, pData, "OnDeath", pData.EventChainCtx, nil)
		end
	end

	-- OnDestruction fire helper for Heartbeat destroy paths + finishAnimate.
	function Particle:_fireOnDestruction(pData, visualPart)
		if not (pData.Events and pData.Events.OnDestruction) then return end
		-- Clone-backed types need the visual still parented; VisualPart-less types (CameraShake,
		-- Distortion) resolve their origin through Events.getWorldCF instead.
		local hasOrigin = (visualPart and visualPart.Parent) or (not visualPart and Events.getWorldCF(pData) ~= nil)
		if hasOrigin then
			Events.fire(self, pData, "OnDestruction", pData.EventChainCtx, nil)
		end
	end

	-- Release visual to pool when eligible, else Destroy. Animate visuals never pool.
	-- The carrier (if any) is released only after the visual has been destroyed or re-parented
	-- into the pool: destroying the carrier first would take a pooled child with it.
	function Particle:_releaseOrDestroy(pData, visualPart)
		self:_releaseVisual(pData, visualPart)
		if pData._carrier then
			VisualHost.releaseCarrier(pData._carrier)
			pData._carrier = nil
		end
	end

	function Particle:_releaseVisual(pData, visualPart)
		-- Fan-out clones (Lightning per-segment lights) always destroy — never pool.
		-- Runs before the early returns so a dead visualPart still sweeps its extras.
		if pData._extraLights then
			for _, extraLight in ipairs(pData._extraLights) do
				pcall(function() extraLight:Destroy() end)
			end
			pData._extraLights = nil
		end
		if pData._impactDisk then
			pcall(function() pData._impactDisk:Destroy() end)
			pData._impactDisk = nil
		end
		if self:_isLiveRTAnimate(pData) then
			if pData.AnimateItem then self:_cancelAnimation(pData.AnimateItem) end
			return
		end
		if not visualPart then return end
		if not visualPart.Parent then return end
		if pData.IsAnimate or not pData._sourceRT or not pData._poolKind then
			Pool.dropCloneMap(visualPart)
			pcall(function() visualPart:Destroy() end)
			return
		end
		-- Live Rate read so pool cap tracks emitter rate.
		local rate
		local source = pData._sourceItem
		if source and source.Parent then
			local cfg = TypeRegistry.getConfig(source)
			if cfg then rate = cfg:GetAttribute("Rate") end
		end
		Pool.release(visualPart, pData._sourceRT, pData._poolKind, rate)
	end

end
