--[[
	RegisterEmit Mixin  -  Particle:_registerEmit, the universal pData insertion chokepoint.
	Every EmitX type funnels fresh pData through here: cap check, chain-id stamp, ActiveEmits
	insert, OnHit raycast seed, OnEmit fire. Also stamps the per-play "ghost" token
	(emitCtx._playToken) onto pData so AbsoluteEmitAt's PlayHandle can scope Disable /
	SetTimescale / GetParticles to one play, and inherits that play's live timescale window
	onto new emits without writing _tsOverride attributes to the shared source.

	Split out of Lifecycle.luau to keep that file under the 500-line code cap. Must be applied
	(require(script.RegisterEmit)(Particle)) before any emit runs.
]]

local Events = require(script.Parent.Events)
local Pool = require(script.Parent.Pool)
local LinkCF = require(script.Parent.LinkCF)

return function(Particle)

	-- Register fresh pData: stamp chain id + play token, insert ActiveEmits, seed OnHit raycast, fire OnEmit.
	function Particle:_registerEmit(pData, emitCtx)
		-- Active-particle cap (counts ActiveEmits + linger visuals).
		local cap = self.MAX_ACTIVE_PARTICLES or 1000
		if #self.ActiveEmits + (self._lingerVisualCount or 0) >= cap then
			-- 3D Animate uses LIVE source RT; can't destroy. Clone-Animate (Screen/ImageLabel) destroys.
			local liveRTAnimate = self:_isLiveRTAnimate(pData)
			if pData.IsAnimate and pData._sourceItem then self.ActiveAnimates[pData._sourceItem] = nil end
			-- Emitters create _nestedAlive before registering; flipping it here makes their nested walk a no-op.
			self:_reclaimPData(pData)
			if not liveRTAnimate and pData.VisualPart and pData.VisualPart.Parent then
				-- Cap-reject: route through _releaseOrDestroy so the visual enters the pool.
				self:_releaseOrDestroy(pData, pData.VisualPart)
			end
			return
		end
		-- Root emits with no incoming emitCtx still get a fresh ChainCtx so OnEmit /
		-- OnDeath / OnHit on the same particle share identity (otherwise OnDeath would fire
		-- under a NEW root chain and chain-tracking across lifetime would break).
		pData.EventChainCtx = (emitCtx and emitCtx.ChainCtx) or pData.EventChainCtx or Events.newChainCtx()

		-- Per-play ghost token: tags this particle so PlayHandle can sweep / timescale only
		-- this play. New emits during an active play-timescale window inherit it here, so the
		-- override never has to be written to the shared source item's attributes.
		local token = emitCtx and emitCtx._playToken
		if token then
			pData._playToken = token
			if token.TsOverride ~= nil and token.TsUntil and os.clock() < token.TsUntil then
				pData._tsOverride = token.TsOverride
				pData._tsOverrideUntil = token.TsUntil
			end
		end

		-- Play-scoped authoring survives AnimateLoop cycles (EngineReplay re-reads the source).
		if emitCtx then
			pData._playOverrides = emitCtx.Overrides
			pData._playLink = emitCtx._playLink
		end

		-- Link generation: the pool bumps it on every release, so a recycled clone stops being a
		-- valid link for particles that captured it earlier (LinkCF.isValid).
		if pData.Link then pData._linkGen = Pool.linkGen(pData.Link) end
		if emitCtx and emitCtx._parentAlive ~= nil then pData._nestedDriven = true end
		LinkCF.captureEmitFrame(pData)
		table.insert(self.ActiveEmits, pData)
		if pData.Events and pData.Events.OnHit then
			pData.LastHitCheckPos = Events.getWorldPosition(pData)
			pData.HitParams = Events.makeHitParams(pData)
			pData._hitFired = false
		end
		if pData.Events and pData.Events.OnEmit then
			-- Build payload explicitly so EmitIndex (per-burst index) reaches user scripts.
			-- Events.fire's nil-payload fallback can't synthesize EmitIndex because it
			-- doesn't see emitCtx.
			local payload = Events.makePayload(self, pData, "OnEmit", emitCtx)
			Events.fire(self, pData, "OnEmit", pData.EventChainCtx, payload)
		end
	end

end
