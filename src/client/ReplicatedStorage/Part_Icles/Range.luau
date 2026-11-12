-- Range  -  pick a random value from a NumberRange.
local Range = {}

function Range.RandomValueFromRange(range: NumberRange)
	if range.Min == range.Max then return range.Min end
	return range.Min + ((range.Max - range.Min) * math.random())
end

return Range
