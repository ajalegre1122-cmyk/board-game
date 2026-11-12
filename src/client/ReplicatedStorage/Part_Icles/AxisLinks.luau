--[[
	AxisLinks  -  graph-axis alias pass shared between EmitPart and AnimateLoop refresh.
	When two axes are linked, the follower's graph + seed point at the primary's, so they track
	tick-for-tick. `sanitize` is the chokepoint that filters cross-group / self / chain / cycle.
]]

local AxisLinks = {}

local GRAPH_FOLLOWERS = {"SizeX","SizeY","SizeZ","RotSpeedX","RotSpeedY","RotSpeedZ","PosOffsetX","PosOffsetY","PosOffsetZ"}

-- Same-group axis link metadata. Cross-group links rejected at sanitize.
local AXIS_GROUPS = {
	{"SizeX","SizeY","SizeZ"},
	{"RotSpeedX","RotSpeedY","RotSpeedZ"},
	{"PosOffsetX","PosOffsetY","PosOffsetZ"},
	{"RotX","RotY","RotZ"},
	{"PosX","PosY","PosZ"},
}
local AXIS_GROUP_OF = {}
for _, group in ipairs(AXIS_GROUPS) do
	local set = {}
	for _, a in ipairs(group) do set[a] = true end
	for _, a in ipairs(group) do AXIS_GROUP_OF[a] = set end
end

-- Resolve a follower's link target. Returns nil for no-link / self-link / cross-group / chain / cycle.
local function resolveAxisLink(raw, follower)
	local primary = raw and raw[follower] or nil
	if not primary or primary == "" or primary == follower then return nil end
	local group = AXIS_GROUP_OF[follower]
	if not group or not group[primary] then return nil end
	local primaryLink = raw[primary]
	if primaryLink and primaryLink ~= "" and primaryLink ~= primary and group[primaryLink] then return nil end
	return primary
end

-- Sanitize raw {axisKey -> rawAttrString} into resolved {follower -> primary or nil}.
function AxisLinks.sanitize(raw)
	local resolved = {}
	for _, group in ipairs(AXIS_GROUPS) do
		for _, a in ipairs(group) do resolved[a] = resolveAxisLink(raw, a) end
	end
	return resolved
end

function AxisLinks.applyGraphAxisAliases(graphs, seeds, axisLinks)
	if not axisLinks or not graphs or not seeds then return end
	for _, follower in ipairs(GRAPH_FOLLOWERS) do
		local primary = axisLinks[follower]
		if primary and primary ~= follower and graphs[primary] and seeds[primary] then
			graphs[follower] = graphs[primary]
			seeds[follower] = seeds[primary]
		end
	end
end

-- Range-axis sampler. Primary axes sampled once, linked followers reuse primary's scalar.
-- EvenDistribution: `{axis}Even` + emitCtx → base spread t = i/count (skips Min so circular
-- ranges don't collide at 0/360); count==1 with NO active cycle → midpoint. A per-emission
-- rolling-cycle OFFSET (EvenOffsetIdx/N_Pos or _Rot) shifts the whole spread by
-- (offIdx-1)/(N*count) each emission — a gap/N step that fills the gaps over N emissions,
-- wrapping mod 1. When a cycle IS active, idx 1 (off==0) must NOT take the midpoint shortcut:
-- it flows through the formula to t=1 (the edge) so the rolling sweep stays continuous.
function AxisLinks.sampleRangeAxes(data, axisLinks, axes, RangeMod, emitCtx)
	local emitIndex = emitCtx and emitCtx.EmitIndex
	local emitCount = emitCtx and emitCtx.EmitCount
	local first = axes[1] or ""
	local prefix = first:sub(1, 3)
	local offIdx, offN
	if prefix == "Pos" then
		offIdx = emitCtx and emitCtx.EvenOffsetIdx_Pos
		offN = emitCtx and emitCtx.EvenOffsetN_Pos
	elseif prefix == "Rot" then
		offIdx = emitCtx and emitCtx.EvenOffsetIdx_Rot
		offN = emitCtx and emitCtx.EvenOffsetN_Rot
	end
	local hasEvenCtx = emitIndex and emitCount and emitCount > 0
	local sampled = {}
	for _, k in ipairs(axes) do
		local primary = axisLinks and axisLinks[k]
		if not primary then
			local even = data[k .. "Even"] == true
			if even and hasEvenCtx then
				local r = data[k]
				local t
				local off = (offN and offN > 0) and ((offIdx - 1) / (offN * emitCount)) or 0
				local cycleActive = offN ~= nil and offN > 0
				if emitCount == 1 and off == 0 and not cycleActive then
					t = 0.5
				else
					t = emitIndex / emitCount + off
					if t > 1 then t = t - 1 end -- t < 2 guaranteed; single wrap to [0,1)
				end
				sampled[k] = r.Min + (r.Max - r.Min) * t
			else
				sampled[k] = RangeMod.RandomValueFromRange(data[k])
			end
		end
	end
	for _, k in ipairs(axes) do
		if sampled[k] == nil then
			local primary = axisLinks and axisLinks[k]
			sampled[k] = (primary and sampled[primary]) or RangeMod.RandomValueFromRange(data[k])
		end
	end
	return sampled
end

-- AnimateLoop refresh: rebuild Graphs from freshData, re-roll seeds, re-apply axis aliases.
function AxisLinks.refreshLoopGraphsAndSeeds(pData, freshData, GraphMod)
	if not pData.Graphs then return end
	for k, _ in pairs(pData.Graphs) do
		if freshData[k] ~= nil then pData.Graphs[k] = freshData[k] end
	end
	if pData.Seeds then for k, _ in pairs(pData.Seeds) do
		if pData.Graphs[k] then pData.Seeds[k] = GraphMod.GenerateSeed(pData.Graphs[k]) end
	end end
	AxisLinks.applyGraphAxisAliases(pData.Graphs, pData.Seeds, freshData.AxisLinks)
end

return AxisLinks
