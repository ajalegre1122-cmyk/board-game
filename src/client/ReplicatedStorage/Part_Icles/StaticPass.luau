-- StaticPass  -  detect constant-valued NumberSequence graphs at emit / AnimateLoop
-- replay time. Constant graphs nil out of pData.Graphs and their value stamps onto
-- pData._static<Name>. Per-frame Update sites read the static value, skipping the
-- QueryPointsWithTime call. Idempotent: clears stale static fields before re-detecting,
-- so a graph switched from static→dynamic mid-cycle correctly re-arms the per-frame
-- sample path.
--
-- ColorSequence not handled  -  Graph.IsStatic is NumberSequence-only. Color graphs
-- remain per-frame sampled (cost is real but step-quantized).
local Graph = require(script.Parent.Graph)

local StaticPass = {}

-- Per-type list of { graphName, staticFieldName, default }.
-- Add a graph here, then add `pData._static<Name> or ` to the matching Update sample
-- site. Field name must match between the table entry and the Update read.
local FIELDS = {
	Part = {
		{ "Speed",         "_staticSpeed",         0 },
		{ "Brightness",    "_staticBrightness",    1 },
		{ "Transparency",  "_staticTransparency",  0 },
		{ "SizeX",         "_staticSizeX",         1 },
		{ "SizeY",         "_staticSizeY",         1 },
		{ "SizeZ",         "_staticSizeZ",         1 },
		{ "RotSpeedX",     "_staticRotSpeedX",     0 },
		{ "RotSpeedY",     "_staticRotSpeedY",     0 },
		{ "RotSpeedZ",     "_staticRotSpeedZ",     0 },
		{ "PosOffsetX",    "_staticPosOffsetX",    0 },
		{ "PosOffsetY",    "_staticPosOffsetY",    0 },
		{ "PosOffsetZ",    "_staticPosOffsetZ",    0 },
		{ "AccelStrength", "_staticAccelStrength", 0 },
	},
	Attachment = {
		{ "Speed",         "_staticSpeed",         0 },
		{ "RotSpeedX",     "_staticRotSpeedX",     0 },
		{ "RotSpeedY",     "_staticRotSpeedY",     0 },
		{ "RotSpeedZ",     "_staticRotSpeedZ",     0 },
		{ "PosOffsetX",    "_staticPosOffsetX",    0 },
		{ "PosOffsetY",    "_staticPosOffsetY",    0 },
		{ "PosOffsetZ",    "_staticPosOffsetZ",    0 },
	},
	Model = {
		{ "Speed",         "_staticSpeed",         0 },
		{ "Scale",         "_staticScale",         1 },
		{ "RotSpeedX",     "_staticRotSpeedX",     0 },
		{ "RotSpeedY",     "_staticRotSpeedY",     0 },
		{ "RotSpeedZ",     "_staticRotSpeedZ",     0 },
		{ "PosOffsetX",    "_staticPosOffsetX",    0 },
		{ "PosOffsetY",    "_staticPosOffsetY",    0 },
		{ "PosOffsetZ",    "_staticPosOffsetZ",    0 },
	},
	ImageLabel = {
		{ "ImageTransparency",      "_staticImageTransparency",      0 },
		{ "BackgroundTransparency", "_staticBackgroundTransparency", 0 },
		{ "ImgSpeed",               "_staticImgSpeed",               0 },
		{ "ImgRotSpeed",            "_staticImgRotSpeed",            0 },
		{ "SizeScaleX",             "_staticSizeScaleX",             1 },
		{ "SizeScaleY",             "_staticSizeScaleY",             1 },
	},
	-- Beam props live under pData.BeamProps / pData.AnimatedProps, not pData.Graphs.
	-- Beam keeps its inline static-pass in Emit.luau / EmitAnimate.luau / Engine.luau.
}

-- Walk the type's FIELDS table. For each entry: if pData.Graphs[name] is a constant
-- NumberSequence, stamp pData[staticField] and nil the graph. Otherwise clear any
-- stale static field (covers graph→dynamic transitions between AnimateLoop cycles).
function StaticPass.apply(pData)
	if not pData or not pData.Type then return end
	local list = FIELDS[pData.Type]
	if not list then return end
	local g = pData.Graphs
	if not g then return end
	for _, entry in ipairs(list) do
		local graphName, staticField, default = entry[1], entry[2], entry[3]
		local seq = g[graphName]
		if seq and Graph.IsStatic(seq) then
			pData[staticField] = Graph.GetStaticValue(seq, default)
			g[graphName] = nil
		else
			-- Graph absent or dynamic: clear stale static field from prior cycle.
			pData[staticField] = nil
		end
	end
end

-- AnimateLoop replay support. Prior cycle's StaticPass.apply nil'd constant graphs
-- from pData.Graphs. AxisLinks.refreshLoopGraphsAndSeeds iterates `pairs(pData.Graphs)`,
-- so nil keys aren't repopulated from freshData. Call this BEFORE refresh to put the
-- absent keys back, then refresh runs normally, then StaticPass.apply re-detects.
function StaticPass.restoreFromFreshData(pData, freshData)
	if not pData or not freshData or not pData.Type then return end
	local list = FIELDS[pData.Type]
	if not list then return end
	local g = pData.Graphs
	if not g then return end
	for _, entry in ipairs(list) do
		local graphName = entry[1]
		if g[graphName] == nil and freshData[graphName] then
			g[graphName] = freshData[graphName]
		end
	end
end

return StaticPass
