--[[
	HitFilter  -  type-level raycast filter for one emitter: a collision group + an exclude list,
	stored on PartIcleProperties as the HitFilterGroup attribute and the HitFilterExclude folder of
	ObjectValues. Read by Events.makeHitParams (OnHit), Rocks and Lightning Seek; written by the
	HitFilterPanel. Requires TypeRegistry only.
]]

local TypeRegistry = require(script.Parent.TypeRegistry)

local HitFilter = {}

local GROUP_ATTR = "HitFilterGroup"
local FOLDER_NAME = "HitFilterExclude"

local function getConfig(item)
	if not item then return nil end
	local typeDef = TypeRegistry.getTypeFor(item)
	if not typeDef or typeDef.directAccess then return nil end
	return TypeRegistry.getConfig(item)
end

local function readExcludes(folder, out)
	if not folder then return out end
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("ObjectValue") and child.Value then table.insert(out, child.Value) end
	end
	return out
end

-- Legacy location: the OnHit event cfg's CollisionGroup attribute + ExcludeList folder.
local function legacyEventCfg(config)
	local events = config:FindFirstChild("Events")
	local cfg = events and events:FindFirstChild("OnHit")
	if cfg and cfg:IsA("Configuration") then return cfg end
	return nil
end

--- Returns the group name ("" = unset) and an array of excluded Instances. Falls back to the
--- legacy per-event location until migrateFromEvent has run.
function HitFilter.read(item)
	local config = getConfig(item)
	if not config then return "", {} end
	local group = config:GetAttribute(GROUP_ATTR)
	if type(group) ~= "string" then group = "" end
	local excludes = readExcludes(config:FindFirstChild(FOLDER_NAME), {})
	if group == "" and #excludes == 0 then
		local legacy = legacyEventCfg(config)
		if legacy then
			local legacyGroup = legacy:GetAttribute("CollisionGroup")
			if type(legacyGroup) == "string" then group = legacyGroup end
			readExcludes(legacy:FindFirstChild("ExcludeList"), excludes)
		end
	end
	return group, excludes
end

--- "" or nil clears the group.
function HitFilter.setGroup(item, groupName)
	local config = getConfig(item)
	if not config then return false end
	if type(groupName) ~= "string" or groupName == "" then groupName = nil end
	config:SetAttribute(GROUP_ATTR, groupName)
	return true
end

local function excludeFolder(config, create)
	local folder = config:FindFirstChild(FOLDER_NAME)
	if folder or not create then return folder end
	folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = config
	return folder
end

function HitFilter.addExclude(item, inst)
	local config = getConfig(item)
	if not config or not inst then return false end
	local folder = excludeFolder(config, true)
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("ObjectValue") and child.Value == inst then return false end
	end
	local objectValue = Instance.new("ObjectValue")
	objectValue.Name = "Exclude"
	objectValue.Value = inst
	objectValue.Parent = folder
	return true
end

function HitFilter.removeExclude(item, inst)
	local config = getConfig(item)
	local folder = config and excludeFolder(config, false)
	if not folder then return false end
	local removed = false
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("ObjectValue") and child.Value == inst then
			child:Destroy()
			removed = true
		end
	end
	if #folder:GetChildren() == 0 then folder:Destroy() end
	return removed
end

--- Move a legacy per-event filter (OnHit cfg CollisionGroup + ExcludeList) to the type level.
--- Existing type-level values win. `cfg` defaults to the item's OnHit cfg. Returns true when
--- anything changed.
function HitFilter.migrateFromEvent(item, cfg)
	local config = getConfig(item)
	if not config then return false end
	cfg = cfg or legacyEventCfg(config)
	if not cfg then return false end
	local changed = false
	local legacyGroup = cfg:GetAttribute("CollisionGroup")
	if legacyGroup ~= nil then
		if type(legacyGroup) == "string" and legacyGroup ~= "" and config:GetAttribute(GROUP_ATTR) == nil then
			config:SetAttribute(GROUP_ATTR, legacyGroup)
		end
		cfg:SetAttribute("CollisionGroup", nil)
		changed = true
	end
	local legacy = cfg:FindFirstChild("ExcludeList")
	if legacy then
		for _, inst in ipairs(readExcludes(legacy, {})) do HitFilter.addExclude(item, inst) end
		legacy:Destroy()
		changed = true
	end
	return changed
end

return HitFilter
