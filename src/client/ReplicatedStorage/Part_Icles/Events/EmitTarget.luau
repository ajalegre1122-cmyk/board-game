--[[
	Events.EmitTarget  -  mixin over Events: emitTargetInstance, the one dispatch from an event fire
	to the engine. Every call is one chain hop (Depth + 1 against the firing event's limit).

	  AtTarget / nil                 target fires in place (EnableEmit / AbsoluteEmit).
	  AtPosition / AtSource / AtCFrame
	    Transformed Part-Icle        EnableEmitAt at the resolved origin.
	    Folder / raw Model           fan-out per child: each child spawns at origin x its authored
	                                 offset from the container pivot (Model pivot; Folder = first
	                                 framed child). Nested Folders keep the outer pivot.
	    raw Part / Attachment / PE   AbsoluteEmitAt (a clone placed at the origin).
	    Trail / Beam / no frame      in place.

	Cross-file: EventsSchema.emitCapabilityReason decides which targets honour origin modes; the
	Events UI badge and this dispatcher read the same function.
]]

local EventsSchema = require(script.Parent.Parent.EventsSchema)
local Log = require(script.Parent.Parent.Log)

return function(Events)

	-- Warn once per key; Events.cleanup clears the table.
	local function warnOnce(key, message)
		if Events._unsupportedOriginWarned[key] then return end
		Events._unsupportedOriginWarned[key] = true
		Log.warn(message)
	end

	local function inPlaceCtx(hopCtx)
		return { ChainCtx = hopCtx, EventDriven = true }
	end

	local function emitInPlace(particle, target, hopCtx)
		if target:GetAttribute("Transformed") then
			particle:EnableEmit(target, nil, inPlaceCtx(hopCtx))
			return
		end
		local ok, err = pcall(function() particle:AbsoluteEmit(target, false, inPlaceCtx(hopCtx)) end)
		if not ok then warnOnce("emit:" .. target.ClassName, "[Part-Icles Events] emit target failed: " .. tostring(err)) end
	end

	-- World frame of a node. A raw ParticleEmitter borrows its host's frame.
	local function frameOf(node)
		if node:IsA("BasePart") then return node.CFrame end
		if node:IsA("Attachment") then return node.WorldCFrame end
		if node:IsA("Model") then return node:GetPivot() end
		if node:IsA("ParticleEmitter") and node.Parent then return frameOf(node.Parent) end
		return nil
	end

	local function isContainer(inst)
		return inst:IsA("Folder") or (inst:IsA("Model") and not inst:GetAttribute("Transformed"))
	end

	-- Container pivot: Model pivot; Folder = position of its first framed child (identity rotation),
	-- skipping ForgeConverter's `_isAnchor` stubs. nil when nothing inside has a frame.
	local function containerPivot(container)
		if container:IsA("Model") then return container:GetPivot() end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Folder") then
				local nested = containerPivot(child)
				if nested then return nested end
			elseif not child:GetAttribute("_isAnchor") then
				local cf = frameOf(child)
				if cf then return CFrame.new(cf.Position) end
			end
		end
		return nil
	end

	-- AtCFrame carries the authored layout into the event frame; the other modes translate it so
	-- every child keeps its own rotation.
	local function childOrigin(originCF, pivotCF, childCF, fullPose)
		if fullPose then return originCF * pivotCF:ToObjectSpace(childCF) end
		return childCF + (originCF.Position - pivotCF.Position)
	end

	-- One node at a resolved origin. `resolver` re-resolves at spawn time (after EmitDelay).
	local function emitAt(particle, node, originCF, resolver, mode, hopCtx)
		local options = {
			ChainCtx = hopCtx,
			EventDriven = true,
			IgnoreLink = true,
			UseFullOrigin = (mode == "AtCFrame"),
			OriginResolver = resolver,
		}
		if node:GetAttribute("Transformed") then
			local reason = EventsSchema.emitCapabilityReason(node)
			if reason then
				warnOnce(tostring(mode) .. ":" .. node.ClassName, ("[Part-Icles Events] %s emits in place: %s"):format(node:GetFullName(), reason))
				particle:EnableEmit(node, nil, inPlaceCtx(hopCtx))
			else
				particle:EnableEmitAt(node, originCF, options)
			end
			return
		end
		if node:IsA("Trail") or node:IsA("Beam") then
			emitInPlace(particle, node, hopCtx)
			return
		end
		local ok, err = pcall(function() particle:AbsoluteEmitAt(node, originCF, options) end)
		if not ok then warnOnce("emitAt:" .. node.ClassName, "[Part-Icles Events] emit target failed: " .. tostring(err)) end
	end

	-- Per-child fan-out for Folder / raw Model targets.
	local function fanOut(particle, container, pivotCF, originCF, resolveLive, mode, hopCtx)
		local fullPose = (mode == "AtCFrame")
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Folder") then
				fanOut(particle, child, pivotCF, originCF, resolveLive, mode, hopCtx)
			else
				local childCF = frameOf(child)
				if childCF then
					local function resolver()
						return childOrigin(resolveLive(), pivotCF, frameOf(child) or childCF, fullPose)
					end
					emitAt(particle, child, childOrigin(originCF, pivotCF, childCF, fullPose), resolver, mode, hopCtx)
				elseif child:IsA("Trail") or child:IsA("Beam") or child:IsA("ParticleEmitter") then
					emitInPlace(particle, child, hopCtx)
				end
			end
		end
	end

	-- EmitTarget dispatcher; depthLimit is owned by the firing event's cfg.
	function Events.emitTargetInstance(particle, target, mode, payload, pData, chainCtx, depthLimit)
		if not target or not target.Parent then return end
		chainCtx = chainCtx or Events.newChainCtx()
		depthLimit = depthLimit or Events.DEFAULT_CHAIN_DEPTH_LIMIT
		-- The single chain hop: every dispatched target sits one level below the firing event.
		local hopCtx = { ChainId = chainCtx.ChainId, Depth = chainCtx.Depth + 1 }
		if hopCtx.Depth >= depthLimit then
			Events.dropDepth(payload and payload._eventName)
			return
		end

		if mode == nil or mode == "AtTarget" then
			emitInPlace(particle, target, hopCtx)
			return
		end
		local reason = EventsSchema.emitCapabilityReason(target)
		if reason then
			warnOnce(tostring(mode) .. ":" .. target.ClassName, ("[Part-Icles Events] %s emits in place: %s"):format(target:GetFullName(), reason))
			emitInPlace(particle, target, hopCtx)
			return
		end

		local originCF = Events.resolveEmitModeCF(mode, payload, pData)
		if not originCF then
			warnOnce(tostring(mode) .. ":" .. tostring(payload and payload._eventName), ("[Part-Icles Events] EmitMode %q has no resolvable origin; emitting in place"):format(tostring(mode)))
			emitInPlace(particle, target, hopCtx)
			return
		end
		local function resolveLive()
			return Events.resolveEmitModeCF(mode, payload, pData) or originCF
		end

		if isContainer(target) then
			fanOut(particle, target, containerPivot(target) or originCF, originCF, resolveLive, mode, hopCtx)
			return
		end
		emitAt(particle, target, originCF, resolveLive, mode, hopCtx)
	end

end
