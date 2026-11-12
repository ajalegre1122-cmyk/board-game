--[[
	TrailGraphBlender  -  multi-state interpolation for Trail emitter properties.
	Mirrors Graph.CollectGraphStates structure but adds a third Width track alongside
	Transparency + Color. Configuration children under the GraphBlender folder each
	carry Time + Width + Transparency + Color attributes; this collector returns three
	sorted state lists. The actual per-frame pair-state interpolation reuses Graph's
	PrecomputeMergedTimes + LerpGraphFast / LerpColorGraphFast.
]]

local Graph = require(script.Parent.Graph)

local TrailGraphBlender = {}

-- Collect blender states from a GraphBlender folder into three time-sorted lists
-- (width / transparency / color). Returned lists feed Graph.PrecomputeMergedTimes + LerpGraphFast
-- at runtime for per-frame interpolation between authored Configuration states.
function TrailGraphBlender.CollectStates(graphBlender)
	local widthStates, transStates, colorStates = {}, {}, {}
	if not graphBlender then return widthStates, transStates, colorStates end

	for _, child in pairs(graphBlender:GetChildren()) do
		if not child:IsA("Configuration") then continue end
		local time = child:GetAttribute("Time")
		if time == nil then
			local num = tonumber(string.match(child.Name, "%d+"))
			time = num and (num - 1) or 0
		end
		local transition = child:GetAttribute("Transition")
		if typeof(transition) ~= "NumberSequence" then transition = nil end
		local width = child:GetAttribute("Width")
		if width and typeof(width) == "NumberSequence" then
			table.insert(widthStates, {Time = time, Graph = width, Transition = transition})
		end
		local trans = child:GetAttribute("Transparency")
		if trans and typeof(trans) == "NumberSequence" then
			table.insert(transStates, {Time = time, Graph = trans, Transition = transition})
		end
		local color = child:GetAttribute("Color")
		if color and typeof(color) == "ColorSequence" then
			table.insert(colorStates, {Time = time, Graph = color, Transition = transition})
		end
	end

	-- Sort each list by Time + normalize fallback values into 0-1 range.
	for _, states in ipairs({widthStates, transStates, colorStates}) do
		table.sort(states, function(a, b) return a.Time < b.Time end)
		if #states > 1 and states[#states].Time > 1 then
			local maxTime = states[#states].Time
			if maxTime > 0 then for _, s in ipairs(states) do s.Time = s.Time / maxTime end end
		end
	end

	return widthStates, transStates, colorStates
end

-- Reuse Graph's existing math; Trail blender doesn't need new sequence-merge primitives.
TrailGraphBlender.PrecomputeMergedTimes = Graph.PrecomputeMergedTimes
TrailGraphBlender.PrecomputeMergedColorTimes = Graph.PrecomputeMergedColorTimes
TrailGraphBlender.LerpGraphFast = Graph.LerpGraphFast
TrailGraphBlender.LerpColorGraphFast = Graph.LerpColorGraphFast

return TrailGraphBlender
