--[[
	Events.Hit  -  mixin over Events: afterUpdate, the per-frame OnHit segment raycast
	(fires OnHit + delegates to EventsCollision).
]]

local EventsCollision = require(script.Parent.Parent.EventsCollision)

return function(Events)

	-- OnHit per-frame hook

	-- Min displacement for a raycast; filters ReapplyLink / Orientation jitter.
	local HIT_MIN_DIST = 0.05

	-- Per-frame OnHit raycast. _hitFired stays sticky on Stop / re-arms on clean miss.
	-- Reverse Timescale suppresses OnHit but updates LastHitCheckPos so forward resume gets a fresh segment.
	function Events.afterUpdate(particle, pData, isDead, currentTime)
		if not pData.Events or not pData.Events.OnHit then return end
		-- Rig types (Rocks, Lightning Seek) fire OnHit from their OWN sim and set
		-- _ownsOnHit (their PDataBuilders). Their Model pivots MOVE (live bbox center /
		-- per-roll WorldPivot), so the generic segment raycast + Collision actions here
		-- would snap-teleport the whole rig to the centroid hit and Kill it.
		if pData._ownsOnHit then return end
		if pData._lastEffectiveDt and pData._lastEffectiveDt < 0 then
			pData.LastHitCheckPos = Events.getWorldPosition(pData)
			pData.LastHitCheckTime = currentTime
			return
		end
		local newPos = Events.getWorldPosition(pData)
		if not newPos then return end
		if not pData.LastHitCheckPos then
			pData.LastHitCheckPos = newPos
			pData.LastHitCheckTime = currentTime
			return
		end

		-- HitCheckInterval throttle: LastHitCheckPos stays pinned, so the next segment spans the
		-- whole skipped window. A particle already past its own radius is checked now regardless,
		-- so fast movers cannot tunnel through a wall thinner than one window.
		local interval = pData.Events.OnHit.HitCheckInterval or 0
		if interval > 0 and currentTime - (pData.LastHitCheckTime or 0) < interval then
			if (newPos - pData.LastHitCheckPos).Magnitude <= (pData._sleepRadius or 1) then return end
		end

		local prevPos = pData.LastHitCheckPos
		local prevTime = pData.LastHitCheckTime or currentTime
		local segmentDT = currentTime - prevTime
		if segmentDT <= 0 then segmentDT = 1/60 end
		local dir = newPos - prevPos
		if dir.Magnitude > HIT_MIN_DIST then
			local hit = workspace:Raycast(prevPos, dir, pData.HitParams)
			if hit then
				if not pData._hitFired then
					local payload = Events.makePayload(particle, pData, "OnHit", nil)
					payload.HitInstance = hit.Instance
					payload.Other = hit.Instance
					payload.HitPosition = hit.Position
					payload.HitNormal = hit.Normal
					Events.fire(particle, pData, "OnHit", pData.EventChainCtx, payload)

					-- "snap" → helper updated LastHitCheckPos, caller returns. "off" → caller continues.
					if EventsCollision.handle(particle, pData, hit, dir, segmentDT) == "snap" then return end
				end
			else
				-- Clean miss → particle has cleared the previous surface. Re-arm so the next
				-- surface contact can fire OnHit again (Off-mode per-collision behavior).
				-- Stop mode keeps `_hitFired` sticky via `_collisionStopped` so a link-moved
				-- frozen particle doesn't re-fire after being explicitly halted.
				if not pData._collisionStopped then
					pData._hitFired = false
				end
			end
			pData.LastHitCheckPos = newPos
			pData.LastHitCheckTime = currentTime
		end
	end

end
