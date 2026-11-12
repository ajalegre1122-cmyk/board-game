--[[
	PlayHandle  -  the per-play "ghost" returned by Particle:AbsoluteEmitAt.

	One AbsoluteEmitAt call spawns particles from a SHARED source without cloning it. The
	handle wraps a play token so a caller controls only THAT play, never the shared source:
	many callers can drive one emitter and stop / timescale / script their own play in
	isolation. No Instance is created (honors the no-duplication optimization) — the handle
	is a plain Lua object over { engine, token }.

	token = { Alive, Loops = {task,..}, Clones = {Instance,..}, TsOverride, TsUntil, Duration }.
	Particles of this play carry pData._playToken == token (stamped in RegisterEmit). The
	continuous loop (Lifecycle.Enable) breaks when token.Alive flips false and registers its
	task in token.Loops. Branch-B raw clones land in token.Clones for early teardown.

	API:
	  :Disable()      hard  -  stop new emission, reclaim live particles now, destroy clones.
	  :SoftDisable()  soft  -  stop new emission, live particles finish their Lifetime.
	  :SetTimescale(scale, duration, permanent)  -  per-play time warp; no source attr write.
	  :GetParticles() -> {VisualPart,..} live visuals of this play (script them directly).
	  :GetPDatas()    -> {pData,..} raw pData refs of live particles. ENGINE-INTERNAL
	                    layout: read LifeTime / StartTime / LocalCF / Graphs / Seeds /
	                    SkipSize / BaseDirection / etc. Mutations stick until the next
	                    Heartbeat reads them. NO STABILITY GUARANTEE between plugin
	                    versions  -  field renames will break callers.
	  :IsAlive()  /  .Active  -  any live particle or non-dead loop remains.
	  :Wait()         yield until the play ends: Duration elapsed, or disabled with nothing
	                  left alive. Returns the seconds waited. An infinite play waits for Disable.
	  .Duration   -  total real-time duration of the play (nil = infinite).
	  PlayHandle.inert(engine)  -  handle of a rejected call: never alive, controls nothing.
]]

local PlayHandle = {}

local Methods = {}

-- Hard stop: halt new emission, reclaim every live particle of this play now, destroy
-- branch-B clones. Mirrors Particle:Disable's swap-and-pop sweep, filtered by play token.
function Methods:Disable()
	local engine = self.engine
	-- Queue during the Heartbeat loop; Engine drains after the sweep (see Particle:Disable).
	if engine._inStep then
		engine._afterStep = engine._afterStep or {}
		table.insert(engine._afterStep, function() self:Disable() end)
		return
	end
	local token = self.token
	token.Alive = false
	for _, loopTask in ipairs(token.Loops) do pcall(task.cancel, loopTask) end
	token.Loops = {}

	local active = engine.ActiveEmits
	for idx = #active, 1, -1 do
		local pData = active[idx]
		if pData and pData._playToken == token then
			if pData.VisualPart and pData.VisualPart.Parent then
				engine:_releaseOrDestroy(pData, pData.VisualPart)
			end
			engine:_reclaimPData(pData)
			if active[idx] == pData then
				local n = #active
				if idx < n then active[idx] = active[n] end
				active[n] = nil
			end
		end
	end

	for _, clone in ipairs(token.Clones) do
		if clone and clone.Parent then pcall(function() clone:Destroy() end) end
	end
	token.Clones = {}
end

-- Soft stop: halt new emission; live particles finish their Lifetime and branch-B clones
-- expire on their own destroy delay. Cancels only the emission loop.
-- Engine's Animate replay reads token.Alive, so a looping Animate play ends after its current cycle.
function Methods:SoftDisable()
	local token = self.token
	token.Alive = false
	for _, loopTask in ipairs(token.Loops) do pcall(task.cancel, loopTask) end
	token.Loops = {}
end

-- Per-play timescale window. Patches this play's live particles and stores the window on the
-- token so the play's future emits inherit it (RegisterEmit). Never writes to the source item,
-- so other plays + the source stay at their own speed. permanent=true ignores duration;
-- duration<=0 (non-permanent) clears the override.
function Methods:SetTimescale(scale, duration, permanent)
	if typeof(scale) ~= "number" then return end
	local engine = self.engine
	local token = self.token
	local until_
	if permanent == true then
		until_ = math.huge
	elseif typeof(duration) == "number" and duration > 0 then
		until_ = os.clock() + duration
	else
		token.TsOverride = nil
		token.TsUntil = nil
		until_ = nil
	end
	token.TsOverride = until_ ~= nil and scale or nil
	token.TsUntil = until_
	local active = engine.ActiveEmits
	for i = 1, #active do
		local pData = active[i]
		if pData and pData._playToken == token then
			pData._tsOverride = token.TsOverride
			pData._tsOverrideUntil = until_
		end
	end
end

-- Live visuals of this play, for direct scripting of the emitted items.
function Methods:GetParticles()
	local out = {}
	local active = self.engine.ActiveEmits
	for i = 1, #active do
		local pData = active[i]
		if pData and pData._playToken == self.token and pData.VisualPart then
			out[#out + 1] = pData.VisualPart
		end
	end
	return out
end

-- Raw pData refs for live particles of this play. pData layout is engine-internal;
-- scripters use this to override anything (Graphs / Seeds / LocalCF / SkipSize /
-- LifeTime / etc) per-frame. Mutations land on the next Heartbeat read. No
-- stability guarantee between plugin versions.
function Methods:GetPDatas()
	local out = {}
	local active = self.engine.ActiveEmits
	for i = 1, #active do
		local pData = active[i]
		if pData and pData._playToken == self.token then
			out[#out + 1] = pData
		end
	end
	return out
end

-- True while any live particle carries the token or any emission loop is still running.
function Methods:IsAlive()
	local active = self.engine.ActiveEmits
	for i = 1, #active do
		if active[i] and active[i]._playToken == self.token then return true end
	end
	for _, loopTask in ipairs(self.token.Loops) do
		if coroutine.status(loopTask) ~= "dead" then return true end
	end
	return false
end

-- Yield until the play ends. Duration is the upper bound (spawns wait on EmitDelay, so liveness
-- alone cannot detect the end); an early Disable returns as soon as nothing is left alive.
function Methods:Wait()
	local start = os.clock()
	local duration = self.Duration
	while true do
		if duration ~= nil and os.clock() - start >= duration then break end
		if self.token.Alive == false and not Methods.IsAlive(self) then break end
		task.wait()
	end
	return os.clock() - start
end

local HandleMeta = {}
-- .Active resolves live; .Duration + methods are real fields / the Methods table.
HandleMeta.__index = function(handle, key)
	if key == "Active" then return Methods.IsAlive(handle) end
	return Methods[key]
end

function PlayHandle.new(engine, token)
	return setmetatable({ engine = engine, token = token, Duration = token.Duration }, HandleMeta)
end

-- Handle for a rejected call so callers can chain methods without nil checks.
function PlayHandle.inert(engine)
	return PlayHandle.new(engine, { Alive = false, Loops = {}, Clones = {}, Duration = 0 })
end

return PlayHandle
