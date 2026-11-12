--[[
	TypeRegistry  -  schema source of truth for every Part-Icle type.
	TypeData.luau + TypeDataScreen.luau hold per-type tables; this file is generic read/write.
	Enums serialize by Name (string) and deserialize via Enum[enumType][name].
]]

local TypeData = require(script.TypeData)

export type TypeDef = {
	classCheck: (Instance) -> boolean,
	pDataType: string,
	uiSection: string,
	properties: {[string]: {[string]: any}},
	resize: {[string]: any}?,
	retime: {[string]: any}?,
	clipboard: {any}?,
	directAccess: boolean?,
}

local TypeRegistry = {}

TypeRegistry.CONFIG_NAME = "PartIcleProperties"
TypeRegistry.Types = TypeData.Types

-- Returns (typeDef, typeName) or (nil, nil).
function TypeRegistry.getTypeFor(item): (TypeDef?, string?)
	for typeName, typeDef in pairs(TypeRegistry.Types) do
		if typeDef.classCheck(item) then
			return typeDef, typeName
		end
	end
	return nil, nil
end

function TypeRegistry.getTypeName(item): string?
	local _, name = TypeRegistry.getTypeFor(item)
	return name
end

function TypeRegistry.getConfig(item)
	return item:FindFirstChild(TypeRegistry.CONFIG_NAME)
end

-- Resolve attrName overrides (BeamBrightness, PLRange, etc.); falls back to propName.
function TypeRegistry.getAttrName(typeDef, propName): string
	local propDef = typeDef.properties[propName]
	if propDef and propDef.attrName then
		return propDef.attrName
	end
	return propName
end

-- Read property value; enum returns EnumItem (not string).
-- A scalar saved before the property became a graph or a range reads as the flat equivalent.
local function promoteScalar(propDef, raw)
	if type(raw) ~= "number" then return raw end
	if propDef.type == "NumberSequence" then return NumberSequence.new(raw) end
	if propDef.type == "NumberRange" then return NumberRange.new(raw) end
	return raw
end

function TypeRegistry.read(item, propName): any
	local typeDef = TypeRegistry.getTypeFor(item)
	if not typeDef then return nil end
	local propDef = typeDef.properties[propName]
	if not propDef then return nil end

	if typeDef.directAccess then
		if propDef.attribute then
			local attrName = propDef.attrName or propName
			local raw = item:GetAttribute(attrName)
			-- Explicit nil-check so stored `false` round-trips correctly.
			if raw ~= nil then return raw end
			return propDef.default
		end
		local ok, val = pcall(function() return item[propName] end)
		if ok and val ~= nil then return val end
		return propDef.default
	end

	local config = TypeRegistry.getConfig(item)
	if not config then return nil end

	local attrName = TypeRegistry.getAttrName(typeDef, propName)
	local raw = config:GetAttribute(attrName)

	if raw == nil then return propDef.default end
	raw = promoteScalar(propDef, raw)

	if propDef.type == "enum" and type(raw) == "string" then
		-- Enum[type][name] raises on invalid names; pcall-wrap.
		local ok, enumVal = pcall(function() return Enum[propDef.enumType][raw] end)
		if ok and enumVal then return enumVal end
		return propDef.default
	end

	return raw
end

-- Bump RT _PoolGen so Pool flushes stale-look entries on next acquire. Inlined to keep
-- TypeRegistry's no-upward-dependency invariant (would otherwise require Pool).
local function _bumpPoolGen(item)
	local rt = item:FindFirstChild("RenderTemplate")
	if not rt then return end
	local cur = rt:GetAttribute("_PoolGen") or 0
	pcall(function() rt:SetAttribute("_PoolGen", cur + 1) end)
end

-- Bump RenderTemplate's _PoolGen so pooled visuals invalidate. UI paths that
-- mutate RT directly (Material, Beam Texture, Attachment0/1) call this.
function TypeRegistry.bumpPoolGen(item)
	if not item then return end
	_bumpPoolGen(item)
end

-- Clamp NumberSequence so each keypoint Value >= 0 and Envelope <= Value.
local function _clampNonNegativeSeq(value)
	if typeof(value) ~= "NumberSequence" then return value end
	local kps = value.Keypoints
	local needsClamp = false
	for _, kp in ipairs(kps) do
		if kp.Value < 0 or kp.Envelope > kp.Value then needsClamp = true; break end
	end
	if not needsClamp then return value end
	local clamped = {}
	for _, kp in ipairs(kps) do
		local v = math.max(0, kp.Value)
		local e = math.max(0, math.min(kp.Envelope, v))
		table.insert(clamped, NumberSequenceKeypoint.new(kp.Time, v, e))
	end
	return NumberSequence.new(clamped)
end

-- NaN/invalid guard: refuse writes that would persist garbage (NaN keypoints, infinite
-- numbers, malformed NumberSequence). Runtime guards degrade gracefully but stale-invalid
-- attrs survive across sessions and silently misbehave; reject at the write boundary so
-- the prior good value stays intact.
local function _isInvalidNumber(n)
	return type(n) == "number" and (n ~= n or n == math.huge or n == -math.huge)
end
local function _isInvalidValue(value)
	if type(value) == "number" then return _isInvalidNumber(value) end
	if typeof(value) == "NumberRange" then return _isInvalidNumber(value.Min) or _isInvalidNumber(value.Max) end
	if typeof(value) == "NumberSequence" then
		for _, kp in ipairs(value.Keypoints) do
			if _isInvalidNumber(kp.Time) or _isInvalidNumber(kp.Value) or _isInvalidNumber(kp.Envelope) then
				return true
			end
			if kp.Time < 0 or kp.Time > 1 then return true end
		end
	end
	return false
end

-- Write property value; enum stored as Name string (config) or EnumItem (direct).
function TypeRegistry.write(item, propName, value)
	if _isInvalidValue(value) then
		warn("[Part-Icles] TypeRegistry.write rejected invalid value for " .. tostring(propName))
		return
	end
	local typeDef = TypeRegistry.getTypeFor(item)
	if not typeDef then return end
	local propDef = typeDef.properties[propName]
	if not propDef then return end

	if typeDef.directAccess then
		if propDef.nonNegative then
			value = _clampNonNegativeSeq(value)
		end
		if propDef.attribute then
			local attrName = propDef.attrName or propName
			item:SetAttribute(attrName, value)
		else
			pcall(function() item[propName] = value end)
		end
		_bumpPoolGen(item)
		return
	end

	local config = TypeRegistry.getConfig(item)
	if not config then return end

	local attrName = TypeRegistry.getAttrName(typeDef, propName)

	if propDef.type == "enum" then
		if typeof(value) == "EnumItem" then
			config:SetAttribute(attrName, value.Name)
		else
			config:SetAttribute(attrName, tostring(value))
		end
	else
		-- nonNegative: clamp NumberSequence Value AND Envelope so Value + rand[-E,+E] >= 0.
		if propDef.nonNegative and typeof(value) == "NumberSequence" then
			local kps = value.Keypoints
			local needsClamp = false
			for _, kp in ipairs(kps) do
				if kp.Value < 0 or kp.Envelope > kp.Value then needsClamp = true; break end
			end
			if needsClamp then
				local clamped = {}
				for _, kp in ipairs(kps) do
					local v = math.max(0, kp.Value)
					local e = math.max(0, math.min(kp.Envelope, v))
					table.insert(clamped, NumberSequenceKeypoint.new(kp.Time, v, e))
				end
				value = NumberSequence.new(clamped)
			end
		end
		config:SetAttribute(attrName, value)
	end
	_bumpPoolGen(item)
end

-- Read every property into a flat table (generic GetData).
function TypeRegistry.readAll(item): {[string]: any}?
	local typeDef = TypeRegistry.getTypeFor(item)
	if not typeDef then return nil end
	local config = TypeRegistry.getConfig(item)
	if not config then return nil end

	local data = {}
	for propName, propDef in pairs(typeDef.properties) do
		local attrName = TypeRegistry.getAttrName(typeDef, propName)
		local raw = config:GetAttribute(attrName)
		if raw == nil then
			data[propName] = propDef.default
		elseif propDef.type == "enum" and type(raw) == "string" then
			data[propName] = Enum[propDef.enumType][raw]
		else
			data[propName] = promoteScalar(propDef, raw)
		end
	end
	return data
end

-- Stamp every default property; called by Transform.
function TypeRegistry.writeDefaults(config, typeDef)
	for propName, propDef in pairs(typeDef.properties) do
		local attrName = propDef.attrName or propName
		local value = propDef.default
		if propDef.type == "enum" then
			config:SetAttribute(attrName, value.Name)
		else
			config:SetAttribute(attrName, value)
		end
	end
end

-- New Configuration with defaults stamped; parented to item.
function TypeRegistry.createConfig(item, typeDef)
	local config = Instance.new("Configuration")
	config.Name = TypeRegistry.CONFIG_NAME
	TypeRegistry.writeDefaults(config, typeDef)
	config.Parent = item
	return config
end

function TypeRegistry.isGraph(propDef): boolean
	return propDef.type == "NumberSequence" or propDef.type == "ColorSequence"
end

function TypeRegistry.isNonNegative(propDef): boolean
	return propDef.nonNegative == true
end

function TypeRegistry.getPropDef(typeName, propName)
	local typeDef = TypeRegistry.Types[typeName]
	if not typeDef then return nil end
	return typeDef.properties[propName]
end

-- Type-aware default lookup; required because pairs() over Types isn't order-stable.
function TypeRegistry.getDefault(typeName, propName)
	local typeDef = TypeRegistry.Types[typeName]
	if not typeDef then return nil end
	local propDef = typeDef.properties[propName]
	if not propDef then return nil end
	return propDef.default
end

-- True when `desc` sits under a RenderTemplate between itself and `root` (exclusive).
-- Lifecycle.haltEmission skips such natives: they are template state, not live emission.
function TypeRegistry.isInsideRenderTemplate(desc, root)
	local node = desc.Parent
	while node and node ~= root do
		if node.Name == "RenderTemplate" then return true end
		node = node.Parent
	end
	return false
end

return TypeRegistry
