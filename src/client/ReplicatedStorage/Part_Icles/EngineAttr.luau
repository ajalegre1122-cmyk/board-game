--[[
	EngineAttr  -  the single path for engine-originated writes on user-authored instances
	(source items, their PartIcleProperties config, raw ParticleEmitters / Trails / Beams).
	The plugin's selection listeners (SelectionHandler) skip repopulating when the changed value is
	the one the engine just wrote, so emission bookkeeping (Enabled windows, _emitGen, AnimateLoop,
	native gens) no longer rebuilds the Properties panel and resets the Resize / Retime / Hue sliders
	every emit cycle. Value matching, not a re-entrancy flag: Studio fires signals deferred, so the
	listener runs after the write returned.
	Invariant: runtime code never sets an attribute or Enabled on a user instance directly; it goes
	through EngineAttr.write / writeProp. Writes to emitted clones are exempt (nothing listens to them).
]]

local EngineAttr = {}

local NIL = {}
local _expected = setmetatable({}, { __mode = "k" })

local function remember(instance, name, value)
	local names = _expected[instance]
	if not names then
		names = {}
		_expected[instance] = names
	end
	if value == nil then value = NIL end
	names[name] = value
end

-- Attribute write. Returns pcall's ok flag.
function EngineAttr.write(instance, name, value)
	remember(instance, name, value)
	return pcall(instance.SetAttribute, instance, name, value)
end

-- Property write (native Enabled on ParticleEmitter / Trail / Beam).
function EngineAttr.writeProp(instance, prop, value)
	remember(instance, prop, value)
	return pcall(function() instance[prop] = value end)
end

-- True when the instance's current attribute value is the one the engine last wrote.
function EngineAttr.isEngineWrite(instance, name)
	local names = _expected[instance]
	if not names then return false end
	local expected = names[name]
	if expected == nil then return false end
	local current = instance:GetAttribute(name)
	if current == nil then return expected == NIL end
	return current == expected
end

-- Property variant for .Changed listeners.
function EngineAttr.isEngineProp(instance, prop)
	local names = _expected[instance]
	if not names then return false end
	local expected = names[prop]
	if expected == nil then return false end
	local ok, current = pcall(function() return instance[prop] end)
	return ok and current == expected
end

return EngineAttr
