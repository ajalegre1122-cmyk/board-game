--[[
	EmitOverrides  -  Particle:GetEmitData: GetData plus the play's overrides (emitCtx.Overrides from
	EmitAt options). LinkMode and EmitParent replace the authored values on the fresh data table, so
	nothing is written to the source. Emit paths that read Link / LinkMode / EmitParent call this;
	types without link semantics keep GetData. EnableEmit applies Count / Delay / Duration itself.
]]

return function(Particle)

-- Fresh data table for `item` with the play's LinkMode / EmitParent applied.
function Particle:GetEmitData(item, emitCtx)
	local data = self:GetData(item)
	local overrides = emitCtx and emitCtx.Overrides
	if not data or not overrides then return data end
	if overrides.LinkMode ~= nil then data.LinkMode = overrides.LinkMode end
	if overrides.EmitParent ~= nil then data.EmitParent = overrides.EmitParent end
	return data
end

end
