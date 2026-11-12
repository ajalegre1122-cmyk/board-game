-- Particles  -  fires native ParticleEmitters/Trails inside a transformed item using the
-- EmitCount / EmitDelay / EmitDuration attributes. Per-instance gen tokens prevent stale
-- delayed-off closures from clobbering newer emit sessions.
local Range = require(script.Parent.Range)
local EngineAttr = require(script.Parent.EngineAttr)

local Particle = {}

-- EmitDuration is a number or a "min,max" range string; parse to scalar.
local function parseDuration(raw)
	if raw == nil then return nil end
	if typeof(raw) == "number" then return raw end
	local text = tostring(raw)
	local vals = {}
	for v in text:gmatch("[^,]+") do local n = tonumber(v:match("^%s*(.-)%s*$")); if n then table.insert(vals, n) end end
	if #vals == 0 then return nil end
	if #vals == 1 then return vals[1] end
	local mn, mx = math.min(vals[1], vals[2]), math.max(vals[1], vals[2])
	return Range.RandomValueFromRange(NumberRange.new(mn, mx))
end
Particle.parseDuration = parseDuration

-- Skip descendants under a nested Transformed item (sub-emitter handles those itself).
local function _hasTransformedAncestor(desc, root)
	local p = desc.Parent
	while p and p ~= root do
		if p:GetAttribute("Transformed") then return true end
		p = p.Parent
	end
	return false
end

-- alive: false when engine session ended; cancels delayed STARTS only.
local function _alive(alive)
	return (not alive) or alive()
end

-- Two gens, split responsibilities. CANCEL_GEN gates delayed starts (bumped by
-- CancelNative / Pool release / Disable). DURATION_GEN gates delayed-off closures
-- (bumped on each duration-window start) so a newer window can't be turned off
-- by an older one.
local CANCEL_GEN_ATTR = "_PartIcleNativeEmitGen"
local DURATION_GEN_ATTR = "_PartIcleNativeDurationGen"

local function _readCancelGen(v)
	return v:GetAttribute(CANCEL_GEN_ATTR) or 0
end
local function _bumpCancelGen(v)
	local gen = _readCancelGen(v) + 1
	EngineAttr.write(v, CANCEL_GEN_ATTR, gen)
	return gen
end
local function _cancelGenStillCurrent(v, gen)
	return v.Parent ~= nil and _readCancelGen(v) == gen
end

local function _readDurationGen(v)
	return v:GetAttribute(DURATION_GEN_ATTR) or 0
end
local function _bumpDurationGen(v)
	local gen = _readDurationGen(v) + 1
	EngineAttr.write(v, DURATION_GEN_ATTR, gen)
	return gen
end
local function _durationGenStillCurrent(v, gen)
	return v.Parent ~= nil and _readDurationGen(v) == gen
end

-- Enabled=true now, schedule Enabled=false in `duration`. Delayed-off owned by
-- duration gen so a later SetEnabledForDuration does not get clobbered.
Particle.SetEnabledForDuration = function(v, duration)
	local durGen = _bumpDurationGen(v)
	EngineAttr.writeProp(v, "Enabled", true)
	task.delay(duration, function()
		if _durationGenStillCurrent(v, durGen) then EngineAttr.writeProp(v, "Enabled", false) end
	end)
end

-- External API kept stable: ReadNativeGen / IsNativeGenCurrent address the
-- cancel token (delayed-start gating). Callers that want delayed-off ownership
-- use SetEnabledForDuration which handles its own duration token internally.
Particle.ReadNativeGen = _readCancelGen
Particle.IsNativeGenCurrent = _cancelGenStillCurrent

-- Bump cancel + duration gens + Enabled=false. Invalidates pending delayed
-- starts AND any pending delayed-off (which would otherwise re-toggle).
Particle.CancelNative = function(v)
	_bumpCancelGen(v)
	_bumpDurationGen(v)
	pcall(function() EngineAttr.writeProp(v, "Enabled", false) end)
end

-- Synchronous dispatch. cancelGen captured in caller's continuation so a Heartbeat
-- tick can't interleave between capture and the delayed-START closure's check.
Particle.EnableEmit = function(part, alive)
	for i, v in part:GetDescendants() do
		if _hasTransformedAncestor(v, part) then continue end
		if v:IsA('ParticleEmitter') then
			local count = v:GetAttribute('EmitCount') or 1
			local emitDelay = v:GetAttribute('EmitDelay') or 0
			local emitDuration = v:GetAttribute('EmitDuration') or 0
			if count <= 0 and emitDuration <= 0 then continue end
			local cancelGen = _readCancelGen(v)
			local function doEmit()
				if not _alive(alive) or not _cancelGenStillCurrent(v, cancelGen) then return end
				-- Roblox :Emit(0) falls back to 1; gate on count>0.
				if count > 0 then v:Emit(count) end
				if emitDuration > 0 then
					local durGen = _bumpDurationGen(v)
					EngineAttr.writeProp(v, "Enabled", true)
					-- Delayed-off uses duration gen (not alive) so cleanup survives engine death.
					task.delay(emitDuration, function()
						if _durationGenStillCurrent(v, durGen) then EngineAttr.writeProp(v, "Enabled", false) end
					end)
				end
			end
			if emitDelay > 0 then task.delay(emitDelay, doEmit) else doEmit() end
		end
		-- Skip TrailEmitter (Transformed)  -  the engine pipeline emits cloned visuals
		-- via TrailEmitter.EmitTrail; toggling the SOURCE Trail's Enabled here would
		-- render the unwanted source Trail at default Roblox properties (white) on
		-- top of the authored emit clones.
		if v:IsA('Trail') and not v:GetAttribute('Transformed') then
			local dur = parseDuration(v:GetAttribute('EmitDuration'))
			if dur and dur > 0 then
				local cancelGen = _readCancelGen(v)
				task.delay(v:GetAttribute('EmitDelay') or 0.001, function()
					if not _alive(alive) or not _cancelGenStillCurrent(v, cancelGen) then return end
					local durGen = _bumpDurationGen(v)
					EngineAttr.writeProp(v, "Enabled", true)
					task.delay(dur, function()
						if _durationGenStillCurrent(v, durGen) then EngineAttr.writeProp(v, "Enabled", false) end
					end)
				end)
			end
		end
		-- Raw Beam: native streak between authored attachments. Skip BeamNative
		-- (Transformed)  -  directAccess type handled by Particle:EnableEmit mixin.
		-- Same gen-token pattern as Trail: cancelGen gates delayed-on, durGen owns delayed-off.
		if v:IsA('Beam') and not v:GetAttribute('Transformed') then
			local emitDuration = tonumber(v:GetAttribute('EmitDuration')) or 0
			local emitDelay = tonumber(v:GetAttribute('EmitDelay')) or 0
			if emitDuration > 0 then
				local cancelGen = _readCancelGen(v)
				local function doEmit()
					if not _alive(alive) or not _cancelGenStillCurrent(v, cancelGen) then return end
					local durGen = _bumpDurationGen(v)
					EngineAttr.writeProp(v, "Enabled", true)
					task.delay(emitDuration, function()
						if _durationGenStillCurrent(v, durGen) then EngineAttr.writeProp(v, "Enabled", false) end
					end)
				end
				if emitDelay > 0 then task.delay(emitDelay, doEmit) else doEmit() end
			end
		end
	end
end

Particle.EnableEmitSingle = function(v: Instance, alive)
	-- A Transformed source has its own emit pipeline; enabling it here would render the
	-- source Trail in place / double-fire a nested PE.
	if v:GetAttribute('Transformed') then return end
	if v:IsA('Trail') then
		local dur = parseDuration(v:GetAttribute('EmitDuration'))
		if dur and dur > 0 then
			local cancelGen = _readCancelGen(v)
			local emitDelay = v:GetAttribute('EmitDelay') or 0
			local function doEnable()
				if not _alive(alive) or not _cancelGenStillCurrent(v, cancelGen) then return end
				local durGen = _bumpDurationGen(v)
				EngineAttr.writeProp(v, "Enabled", true)
				task.delay(dur, function()
					if _durationGenStillCurrent(v, durGen) then EngineAttr.writeProp(v, "Enabled", false) end
				end)
			end
			-- Synchronous enable when EmitDelay=0 so trail renders on the SAME
			-- frame as particle spawn. Prior `task.delay(EmitDelay or 0.001, ...)`
			-- forced a 1ms tick gap even with zero delay → trail invisible on
			-- frame 0, visible from frame 1+. For short-lived particles this is
			-- a noticeable gap in the trail head.
			if emitDelay > 0 then task.delay(emitDelay, doEnable) else doEnable() end
		end
	end
	if v:IsA('ParticleEmitter') then
		local count = v:GetAttribute('EmitCount') or 1
		local emitDelay = v:GetAttribute('EmitDelay') or 0
		local emitDuration = v:GetAttribute('EmitDuration') or 0
		if count <= 0 and emitDuration <= 0 then return end
		local cancelGen = _readCancelGen(v)
		local function doEmit()
			if not _alive(alive) or not _cancelGenStillCurrent(v, cancelGen) then return end
			if count > 0 then v:Emit(count) end
			if emitDuration > 0 then
				local durGen = _bumpDurationGen(v)
				EngineAttr.writeProp(v, "Enabled", true)
				task.delay(emitDuration, function()
					if _durationGenStillCurrent(v, durGen) then EngineAttr.writeProp(v, "Enabled", false) end
				end)
			end
		end
		if emitDelay > 0 then task.delay(emitDelay, doEmit) else doEmit() end
	end
end

Particle.EnableEmitChildrenAndRepeatForAttachments = function(part, alive)
	for i, v in part:GetChildren() do
		Particle.EnableEmitSingle(v, alive)
		if v:IsA('Attachment') and not v:GetAttribute('Transformed') then
			Particle.EnableEmitChildrenAndRepeatForAttachments(v, alive)
		end
	end
end

return Particle
