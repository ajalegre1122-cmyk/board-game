-- Graph  -  sampling primitives for NumberSequence + ColorSequence graphs.
-- Seed shape: {[keypointIndex] = number}. Single intensity per seed correlates drift
-- across keypoints (adjacent points drift together instead of jittering independently).

local function clamp(x, a, b) if x < a then return a end if x > b then return b end return x end
local function lerp(a, b, t) return a + (b - a) * t end

local Graph = {}

-- Roll a fresh envelope seed; each keypoint gets ±intensity*Envelope (one intensity, one sign).
function Graph.GenerateSeed(graph: NumberSequence?)
	local seed = {}
	-- Legacy items can lack newly-added graphs; empty seed → QueryPointsWithTime falls through.
	if not graph or typeof(graph) ~= "NumberSequence" then return seed end
	local kp = graph.Keypoints
	local intensity = math.random()
	local isPositive = math.random() >= 0.5
	for i = 1, #kp do
		if kp[i].Envelope > 0 then
			if isPositive then
				seed[i] = intensity * kp[i].Envelope
			else
				seed[i] = -intensity * kp[i].Envelope
			end
		end
	end
	return seed
end

function Graph.GenerateSeeds(graph: NumberSequence, NoOfSeeds: number)
	local seeds = {}
	for i = 1, NoOfSeeds do
		seeds[i] = Graph.GenerateSeed(graph)
	end
	return seeds
end

-- Sample a NumberSequence at t∈[0,1] with optional envelope seed.
function Graph.QueryPointsWithTime(t: number, graph: NumberSequence, seed: {number})
	t = math.clamp(t, 0, 1)
	local keypoints = graph.Keypoints
	local n = #keypoints

	if n == 1 then return keypoints[1].Value + (seed[1] or 0) end

	local lo, hi = 1, n
	while lo < hi - 1 do
		local mid = (lo + hi) // 2
		if keypoints[mid].Time <= t then lo = mid else hi = mid end
	end
	local k1 = keypoints[lo]
	local k2 = keypoints[lo + 1]
	local span = k2.Time - k1.Time
	local point = span > 0 and (t - k1.Time) / span or 0
	local k1value = k1.Value + (seed[lo] or 0)
	local k2value = k2.Value + (seed[lo + 1] or 0)
	return k1value + ((k2value - k1value) * point)
end

-- Sample a ColorSequence at t∈[0,1]. ColorSequences have no envelope, so no seed.
function Graph.QueryColorPointWithTime(t: number, graph: ColorSequence)
	t = math.clamp(t, 0, 1)
	local kp = graph.Keypoints
	local n = #kp
	if n == 0 then return Color3.new(1, 1, 1) end
	if n == 1 then return kp[1].Value end
	if t <= kp[1].Time then return kp[1].Value end

	local lo, hi = 1, n
	while lo < hi - 1 do
		local mid = (lo + hi) // 2
		if kp[mid].Time <= t then lo = mid else hi = mid end
	end
	local k1 = kp[lo]
	local k2 = kp[lo + 1]
	local span = k2.Time - k1.Time
	local point = span > 0 and (t - k1.Time) / span or 0
	return k1.Value:Lerp(k2.Value, point)
end

-- Trapezoidal integral of a NumberSequence over [0, t]. Used by TextureSpeed.
function Graph.IntegrateUpTo(t: number, sequence: NumberSequence, seed: {number}): number
	t = math.clamp(t, 0, 1)
	local keypoints = sequence.Keypoints
	local n = #keypoints
	if n == 0 then return 0 end
	if n == 1 then return (keypoints[1].Value + (seed[1] or 0)) * t end

	local total = 0
	for i = 1, n - 1 do
		local k1 = keypoints[i]
		local k2 = keypoints[i + 1]
		if t <= k1.Time then break end

		local v1 = k1.Value + (seed[i] or 0)
		local v2 = k2.Value + (seed[i + 1] or 0)
		local segEnd = math.min(t, k2.Time)
		local segLength = segEnd - k1.Time
		local span = k2.Time - k1.Time
		local alpha = span > 0 and (segEnd - k1.Time) / span or 0
		local vEnd = v1 + (v2 - v1) * alpha

		total = total + (v1 + vEnd) / 2 * segLength
		if t <= k2.Time then break end
	end
	return total
end

-- True if the sequence produces a constant value (single keypoint zero-envelope or all-equal).
function Graph.IsStatic(sequence: NumberSequence): boolean
	if not sequence then return true end
	local kps = sequence.Keypoints
	-- Non-zero envelope → per-particle randomness, so not static.
	if #kps == 1 then return kps[1].Envelope == 0 end
	local val = kps[1].Value
	if kps[1].Envelope ~= 0 then return false end
	for i = 2, #kps do
		if kps[i].Value ~= val or kps[i].Envelope ~= 0 then return false end
	end
	return true
end

function Graph.GetStaticValue(sequence: NumberSequence, defaultValue: number): number
	if not sequence or #sequence.Keypoints == 0 then
		return defaultValue
	end
	return sequence.Keypoints[1].Value
end

-- Merge unique sorted times from two NumberSequence or ColorSequence (both expose Keypoints[].Time).
local function _mergeSequenceTimes(seqA, seqB)
	local times = {}
	local seen = {}
	for _, seq in ipairs({seqA, seqB}) do
		for _, kp in ipairs(seq.Keypoints) do
			if not seen[kp.Time] then
				seen[kp.Time] = true
				table.insert(times, kp.Time)
			end
		end
	end
	table.sort(times)
	return times
end

function Graph.BlendGraphWithTime(GraphA: NumberSequence, GraphB: NumberSequence, SpeedGraph: NumberSequence, alpha: number)
	alpha = clamp(alpha or 1, 0, 1)
	local times = _mergeSequenceTimes(GraphA, GraphB)
	local blendFactor = Graph.QueryPointsWithTime(alpha, SpeedGraph, {})

	local newKps = {}
	for _, t in ipairs(times) do
		local valA = Graph.QueryPointsWithTime(t, GraphA, {})
		local valB = Graph.QueryPointsWithTime(t, GraphB, {})
		table.insert(newKps, NumberSequenceKeypoint.new(t, lerp(valA, valB, blendFactor)))
	end
	return NumberSequence.new(newKps)
end

function Graph.BlendColorGraphWithTime(GraphA: ColorSequence, GraphB: ColorSequence, SpeedGraph: NumberSequence, alpha: number)
	alpha = clamp(alpha or 1, 0, 1)
	local times = _mergeSequenceTimes(GraphA, GraphB)
	local blendFactor = Graph.QueryPointsWithTime(alpha, SpeedGraph, {})

	local newKps = {}
	for _, t in ipairs(times) do
		local colorA = Graph.QueryColorPointWithTime(t, GraphA)
		local colorB = Graph.QueryColorPointWithTime(t, GraphB)
		table.insert(newKps, ColorSequenceKeypoint.new(t, colorA:Lerp(colorB, blendFactor)))
	end
	return ColorSequence.new(newKps)
end

-- Linear blend between two NumberSequences at alpha (no speed graph). Beam graph blender.
function Graph.LerpGraph(GraphA: NumberSequence, GraphB: NumberSequence, alpha: number): NumberSequence
	alpha = clamp(alpha or 0, 0, 1)
	local times = _mergeSequenceTimes(GraphA, GraphB)
	local newKps = {}
	for _, t in ipairs(times) do
		local valA = Graph.QueryPointsWithTime(t, GraphA, {})
		local valB = Graph.QueryPointsWithTime(t, GraphB, {})
		table.insert(newKps, NumberSequenceKeypoint.new(t, lerp(valA, valB, alpha)))
	end
	return NumberSequence.new(newKps)
end

function Graph.LerpColorGraph(GraphA: ColorSequence, GraphB: ColorSequence, alpha: number): ColorSequence
	alpha = clamp(alpha or 0, 0, 1)
	local times = _mergeSequenceTimes(GraphA, GraphB)
	local newKps = {}
	for _, t in ipairs(times) do
		local colorA = Graph.QueryColorPointWithTime(t, GraphA)
		local colorB = Graph.QueryColorPointWithTime(t, GraphB)
		table.insert(newKps, ColorSequenceKeypoint.new(t, colorA:Lerp(colorB, alpha)))
	end
	return ColorSequence.new(newKps)
end

-- Cache merged times once at emit time so per-frame LerpGraphFast skips the merge.
function Graph.PrecomputeMergedTimes(GraphA: NumberSequence, GraphB: NumberSequence): {number}
	return _mergeSequenceTimes(GraphA, GraphB)
end

function Graph.PrecomputeMergedColorTimes(GraphA: ColorSequence, GraphB: ColorSequence): {number}
	return _mergeSequenceTimes(GraphA, GraphB)
end

-- Endpoint short-circuit: alpha 0/1 returns the source sequence to skip per-frame allocation.
function Graph.LerpGraphFast(GraphA: NumberSequence, GraphB: NumberSequence, alpha: number, mergedTimes: {number}): NumberSequence
	alpha = clamp(alpha or 0, 0, 1)
	if alpha == 0 then return GraphA end
	if alpha == 1 then return GraphB end
	local newKps = {}
	for _, t in ipairs(mergedTimes) do
		local valA = Graph.QueryPointsWithTime(t, GraphA, {})
		local valB = Graph.QueryPointsWithTime(t, GraphB, {})
		table.insert(newKps, NumberSequenceKeypoint.new(t, lerp(valA, valB, alpha)))
	end
	return NumberSequence.new(newKps)
end

function Graph.LerpColorGraphFast(GraphA: ColorSequence, GraphB: ColorSequence, alpha: number, mergedTimes: {number}): ColorSequence
	alpha = clamp(alpha or 0, 0, 1)
	if alpha == 0 then return GraphA end
	if alpha == 1 then return GraphB end
	local newKps = {}
	for _, t in ipairs(mergedTimes) do
		local colorA = Graph.QueryColorPointWithTime(t, GraphA)
		local colorB = Graph.QueryColorPointWithTime(t, GraphB)
		table.insert(newKps, ColorSequenceKeypoint.new(t, colorA:Lerp(colorB, alpha)))
	end
	return ColorSequence.new(newKps)
end

-- Collect Beam GraphBlender states from Configuration children (Time/Transparency/Color attrs).
-- A state's optional Transition graph eases the blend INTO it (x = linear segment alpha).
function Graph.CollectGraphStates(graphBlender)
	local transStates, colorStates = {}, {}
	if not graphBlender then return transStates, colorStates end

	for _, child in pairs(graphBlender:GetChildren()) do
		if not child:IsA("Configuration") then continue end
		local time = child:GetAttribute("Time")
		if time == nil then
			local num = tonumber(string.match(child.Name, "%d+"))
			time = num and (num - 1) or 0
		end
		local transition = child:GetAttribute("Transition")
		if typeof(transition) ~= "NumberSequence" then transition = nil end
		local trans = child:GetAttribute("Transparency")
		if trans and typeof(trans) == "NumberSequence" then
			table.insert(transStates, {Time = time, Graph = trans, Transition = transition})
		end
		local color = child:GetAttribute("Color")
		if color and typeof(color) == "ColorSequence" then
			table.insert(colorStates, {Time = time, Graph = color, Transition = transition})
		end
	end

	table.sort(transStates, function(a, b) return a.Time < b.Time end)
	table.sort(colorStates, function(a, b) return a.Time < b.Time end)
	-- Normalize fallback values into 0-1 range.
	for _, states in ipairs({transStates, colorStates}) do
		if #states > 1 and states[#states].Time > 1 then
			local maxTime = states[#states].Time
			if maxTime > 0 then for _, s in ipairs(states) do s.Time = s.Time / maxTime end end
		end
	end

	return transStates, colorStates
end

-- Initial _effectiveElapsed for a particle whose Timescale starts negative.
-- ts(0) < 0 → start at end of life (i=1), rewind to 0; otherwise start at 0.
function Graph.InitialEffectiveElapsed(graph, seed, lifeTime)
	if not graph or typeof(graph) ~= "NumberSequence" then return 0 end
	-- Empty seed fallback: i=0 is deterministic on the first keypoint regardless of envelope.
	local ts0 = Graph.QueryPointsWithTime(0, graph, seed or {})
	return (ts0 < 0) and lifeTime or 0
end

-- Scale a NumberSequence: values *= factor, envelopes *= abs(factor).
function Graph.ScaleSequence(seq, factor)
	if not seq or typeof(seq) ~= "NumberSequence" then return seq end
	local kps = seq.Keypoints
	local new = {}
	local absFactor = math.abs(factor)
	for _, kp in ipairs(kps) do
		table.insert(new, NumberSequenceKeypoint.new(kp.Time, kp.Value * factor, kp.Envelope * absFactor))
	end
	return NumberSequence.new(new)
end

return Graph
