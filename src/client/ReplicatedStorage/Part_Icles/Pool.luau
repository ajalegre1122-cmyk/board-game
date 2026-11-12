--[[
	Pool  -  emission-driven object pool for emitted particle visuals.
	Per-source LIFO with hard cap + ring-buffer overflow + TTL eviction. Cap = rate*TTL*1.25 + 8.
	Generational invalidation via `_PoolGen` attribute (TypeRegistry.write bumps on edit).
	Animate mode skips pooling (visual IS the live source).
]]

local PoolHide = require(script.Parent.PoolHide)
local VisualHost = require(script.Parent.VisualHost)
local Log = require(script.Parent.Log)

local Pool = {}

-- Idle-pool destination folder (VisualHost owns it). Live emit clones stay in `EmittedPartsUsingPart_icle`
-- (Particle:GetFolder); only entries that finished an emit cycle land here.
local function _getPoolFolder()
	return VisualHost.getPoolFolder()
end

-- Weak-key so a destroyed RenderTemplate's pool entry can gc instead of leaking
-- the source instance + cached visuals across un-transform / re-transform cycles.
Pool._pools = setmetatable({}, {__mode = "k"})  -- [sourceRT] = {entries, gen, cap, peakSize, hits, misses, evictions}
Pool._totalSize = 0
Pool._lastSweepAt = 0
Pool._lastReportAt = 0
-- Bumped per release; particles capture it at emit so a recycled clone is no longer their link.
Pool._releaseGen = setmetatable({}, {__mode = "k"})

Pool.MAX_POOL_TOTAL = 2048
Pool.TTL = 5
Pool.SWEEP_INTERVAL = 2
Pool.REPORT_INTERVAL = 0        -- 0 disables the periodic Output print
Pool.MIN_CAP = 8
Pool.CAP_SAFETY = 1.25

local function estimateCap(rate)
	local r = math.max(rate or 0, 0)
	return math.ceil(r * Pool.TTL * Pool.CAP_SAFETY) + Pool.MIN_CAP
end

local function getOrInitPool(source)
	local p = Pool._pools[source]
	if p then return p end
	p = {
		entries = {},                              -- LIFO of {instance, pooledAt}
		gen = source:GetAttribute("_PoolGen") or 0,
		cap = Pool.MIN_CAP,
		peakSize = 0,
		hits = 0, misses = 0, evictions = 0,
	}
	Pool._pools[source] = p
	return p
end

-- Luau weak keys are not ephemerons: a map whose value references its own key (map[rt] = clone)
-- never collects, so every Destroy path drops the clone's map explicitly.
function Pool.dropCloneMap(instance)
	if instance and Pool._cloneMaps then Pool._cloneMaps[instance] = nil end
end

local function destroyEntry(entry)
	if entry and entry.instance then
		Pool.dropCloneMap(entry.instance)
		pcall(function() entry.instance:Destroy() end)
	end
end

local function discardAllEntries(pool)
	for i = 1, #pool.entries do destroyEntry(pool.entries[i]) end
	Pool._totalSize = math.max(0, Pool._totalSize - #pool.entries)
	pool.entries = {}
end

-- Pop a live entry or nil. Caller restores all visual properties (same as fresh Clone).
function Pool.acquire(source, kind)
	if not source then return nil end
	local pool = getOrInitPool(source)
	local sourceGen = source:GetAttribute("_PoolGen") or 0
	if sourceGen ~= pool.gen then
		-- Generation drifted; flush all entries.
		discardAllEntries(pool)
		pool.gen = sourceGen
	end
	while #pool.entries > 0 do
		local entry = table.remove(pool.entries)
		Pool._totalSize = math.max(0, Pool._totalSize - 1)
		local inst = entry.instance
		if inst and inst.Parent then
			PoolHide.show(inst, kind)
			pool.hits += 1
			return inst
		end
	end
	pool.misses += 1
	return nil
end

-- Push an instance back. Global cap → Destroy instead. Per-source full → ring-evict oldest.
function Pool.release(instance, source, kind, rate)
	if not instance or not source then return end
	if not instance.Parent then return end
	local pool = getOrInitPool(source)
	if rate then pool.cap = estimateCap(rate) end
	if Pool._totalSize >= Pool.MAX_POOL_TOTAL then
		Pool.dropCloneMap(instance)
		pcall(function() instance:Destroy() end)
		return
	end
	while #pool.entries >= pool.cap do
		local oldest = table.remove(pool.entries, 1)  -- O(n) shift, n <= cap
		Pool._totalSize = math.max(0, Pool._totalSize - 1)
		destroyEntry(oldest)
		pool.evictions += 1
	end
	PoolHide.hide(instance, kind)
	Pool._releaseGen[instance] = (Pool._releaseGen[instance] or 0) + 1
	-- Re-parent idle entry into the visible pool folder so the user can see, at any moment,
	-- which clones are recyclable. PoolHide already teleported / disabled it; reparent now
	-- so the Explorer reflects the idle state.
	pcall(function() instance.Parent = _getPoolFolder() end)
	pool.entries[#pool.entries + 1] = { instance = instance, pooledAt = os.clock() }
	Pool._totalSize += 1
	if #pool.entries > pool.peakSize then pool.peakSize = #pool.entries end
end

function Pool.linkGen(instance)
	return Pool._releaseGen[instance] or 0
end

-- TTL sweep with 64-entry budget. Budget caps frame-time on huge pools.
function Pool.tickSweep(now)
	if (now - Pool._lastSweepAt) < Pool.SWEEP_INTERVAL then return end
	Pool._lastSweepAt = now
	local budget = 64
	-- Collect drained sources to drop after iteration; mutating Pool._pools while
	-- iterating it would skip / double-visit entries. A pool is droppable when its
	-- entries list is empty AND its source RT has been destroyed (no Parent), so
	-- live RTs that just hit a quiet stretch keep their stats.
	local toDrop = nil
	for source, pool in pairs(Pool._pools) do
		local i = 1
		while i <= #pool.entries and budget > 0 do
			local entry = pool.entries[i]
			local inst = entry.instance
			local stale = (now - entry.pooledAt) > Pool.TTL or not inst or not inst.Parent
			if stale then
				destroyEntry(entry)
				local n = #pool.entries
				if i < n then pool.entries[i] = pool.entries[n] end
				pool.entries[n] = nil
				Pool._totalSize = math.max(0, Pool._totalSize - 1)
				pool.evictions += 1
				budget -= 1
				-- Don't advance i; current slot now holds what was at the end.
			else
				i += 1
			end
		end
		if #pool.entries == 0 and (not source or not source.Parent) then
			toDrop = toDrop or {}
			toDrop[#toDrop + 1] = source
		end
	end
	if toDrop then
		for _, source in ipairs(toDrop) do
			Pool._pools[source] = nil
		end
	end
end

-- Called from TypeRegistry.write to invalidate stale-look pool entries.
function Pool.bumpGen(source)
	if not source then return end
	local cur = source:GetAttribute("_PoolGen") or 0
	pcall(function() source:SetAttribute("_PoolGen", cur + 1) end)
end

-- Drop one source's pool when its RT is destroyed.
function Pool.flushSource(source)
	local pool = Pool._pools[source]
	if not pool then return end
	discardAllEntries(pool)
	Pool._pools[source] = nil
end

-- Drop every pool; called from Particle:Deactivate.
function Pool.flushAll()
	for _, pool in pairs(Pool._pools) do
		discardAllEntries(pool)
	end
	Pool._pools = setmetatable({}, {__mode = "k"})
	Pool._totalSize = 0
	Pool._cloneMaps = setmetatable({}, {__mode = "k"})
end

-- Aggregate diagnostics print, gated by REPORT_INTERVAL.
function Pool.tickReport(now)
	if Pool.REPORT_INTERVAL <= 0 then return end
	if (now - Pool._lastReportAt) < Pool.REPORT_INTERVAL then return end
	Pool._lastReportAt = now
	local poolCount, totalEntries, totalHits, totalMisses, totalEvictions, peakAcross = 0, 0, 0, 0, 0, 0
	for _ in pairs(Pool._pools) do poolCount += 1 end
	for _, pool in pairs(Pool._pools) do
		totalEntries += #pool.entries
		totalHits += pool.hits
		totalMisses += pool.misses
		totalEvictions += pool.evictions
		if pool.peakSize > peakAcross then peakAcross = pool.peakSize end
	end
	local hitRate = (totalHits + totalMisses) > 0 and (totalHits / (totalHits + totalMisses) * 100) or 0
	Log.print(string.format(
		"[Part-Icles Pool] sources=%d entries=%d/%d peak=%d hits=%d misses=%d (%.1f%% hit) evictions=%d",
		poolCount, totalEntries, Pool.MAX_POOL_TOTAL, peakAcross, totalHits, totalMisses, hitRate, totalEvictions
	))
end

-- Acquire or Clone. Stamps _PartIcleEmit so downstream readers recognize the instance.
-- `pooled=false` forces a fresh clone every time and skips the release path; nested
-- Trails/PEs inside the visual then always reflect their authored RT properties.
function Pool.acquireOrClone(rt, kind, pooled)
	local inst
	if pooled == false then
		inst = rt:Clone()
	else
		inst = Pool.acquire(rt, kind) or rt:Clone()
	end
	inst:SetAttribute("_PartIcleEmit", true)
	return inst
end

local END_PROPERTIES = { "Attachment0", "Attachment1" }

-- Clone map -> { { clone, property, source }, ... }: stock Beam / Trail ends authored against
-- a transformed Attachment. The copy skips that attachment (it is emitted later), so the end
-- waits here until Pool.registerEmitted binds it.
local lateEnds = setmetatable({}, { __mode = "k" })

-- Rebuild RT subtree via Instance.fromExisting, skipping Transformed branches
-- (nested SOURCE Part-Icles - fired separately by NestedEmit). Builds a source-to
-- -clone map for the rebuilt subtree.
local function copyBare(source, map, isRoot)
	map = map or {}
	local bare = Instance.fromExisting(source)
	map[source] = bare
	for _, child in ipairs(source:GetChildren()) do
		-- Skip nested sources (fired separately) and any live emitted visual that landed here.
		if not child:GetAttribute("Transformed") and not child:GetAttribute("_PartIcleEmit") then
			copyBare(child, map, false).Parent = bare
		end
	end
	-- Rebind intra-subtree Trail/Beam Attachment0/1. fromExisting copies refs
	-- verbatim; only Instance:Clone auto-rebinds. An end on a transformed Attachment is
	-- queued in lateEnds; any other map miss (an attachment outside the subtree) keeps
	-- its authored reference.
	if isRoot == nil or isRoot then
		local late = nil
		for src, clone in pairs(map) do
			if src:IsA("Trail") or src:IsA("Beam") then
				for _, property in ipairs(END_PROPERTIES) do
					local authored = src[property]
					if authored and map[authored] then
						clone[property] = map[authored]
					elseif authored and authored:GetAttribute("Transformed") then
						late = late or {}
						table.insert(late, { clone = clone, property = property, source = authored })
					end
				end
			end
		end
		lateEnds[map] = late
	end
	return bare, map
end
Pool.copyBare = copyBare

-- Records `visual` as the emitted copy of the transformed `source` in a parent's clone map
-- and binds the stock Beam / Trail ends that were waiting for it. Writes own entries only:
-- the map may chain to a grandparent's. Consumer: EmitAttachment.
function Pool.registerEmitted(map, source, visual)
	rawset(map, source, visual)
	local late = lateEnds[map]
	if not late then return end
	for _, entry in ipairs(late) do
		if entry.source == source then entry.clone[entry.property] = visual end
	end
end

-- A reused clone starts like a fresh copy: late ends back on their authored attachment and
-- the previous cycle's emitted attachments forgotten.
local function resetLateEnds(map)
	local late = lateEnds[map]
	if not late then return end
	for _, entry in ipairs(late) do
		entry.clone[entry.property] = entry.source
		rawset(map, entry.source, nil)
	end
end

-- Weak-keyed by clone root. Map auto-GC's with the clone; pool-hits reuse it
-- until _PoolGen drifts (mutation evicts pool entry, next acquire rebuilds).
Pool._cloneMaps = setmetatable({}, {__mode = "k"})

function Pool.acquireOrCopyBare(rt, kind, pooled)
	local inst, map
	if pooled == false then
		inst, map = copyBare(rt)
	else
		inst = Pool.acquire(rt, kind)
		if inst then
			map = Pool._cloneMaps[inst]
			if map then resetLateEnds(map) end
		else
			inst, map = copyBare(rt)
		end
	end
	if map then Pool._cloneMaps[inst] = map end
	inst:SetAttribute("_PartIcleEmit", true)
	return inst
end

-- Call AFTER writing new spawn CFrame + parent. Defers Trail.Enabled flip by one
-- Heartbeat so Roblox's renderer has applied the new attachment positions before the
-- Trail starts emitting; otherwise the first segment can be drawn from a stale cached
-- position (the prior emit's death pose) to the new spawn pose, leaving a visible
-- streak. No-op on fresh clones (no `_pooledTrailEnabled` snapshot to restore).
function Pool.restoreTrails(instance, kind)
	task.delay(0, function()
		if not instance or not instance.Parent then return end
		PoolHide.restoreTrails(instance, kind)
	end)
end

-- Heartbeat hook; both subsystems gate on their own intervals.
function Pool.tick(now)
	Pool.tickSweep(now)
	Pool.tickReport(now)
end

function Pool.stats()
	local out = { totalSize = Pool._totalSize, sources = {} }
	for source, pool in pairs(Pool._pools) do
		out.sources[source] = {
			size = #pool.entries, peakSize = pool.peakSize, cap = pool.cap, gen = pool.gen,
			hits = pool.hits, misses = pool.misses, evictions = pool.evictions,
		}
	end
	return out
end

return Pool
