-- TexturePin  -  keeps texture assets resident in GPU memory so they don't redecode on first use.
-- 1×1 ImageLabel at ImageTransparency=0.99 parented to a hidden ScreenGui keeps the asset decoded
-- (fully transparent / invisible images get evicted). Owner-counted: pin survives until last owner
-- releases. Ref: https://devforum.roblox.com/t/preloading-images-and-keeping-them-loaded/2998098

local ContentProvider = game:GetService("ContentProvider")
local GuiHost = require(script.Parent.GuiHost)

local TexturePin = {}

local _gui = nil            -- hidden ScreenGui hosting every pin ImageLabel
local _pinned = {}          -- assetId -> ImageLabel
local _ownersOf = {}        -- assetId -> {[owner]=true,...}
local _assetsByOwner = {}   -- owner   -> {[assetId]=true,...}  reverse index for O(pins held) release
local _ANON = newproxy()    -- sentinel for pin() without owner; only clear() releases anonymous pins

local function ensureGui()
	if _gui and _gui.Parent then return _gui end
	local host = GuiHost.resolveContainer()
	if not host then return nil end  -- server context: pin no-ops
	_gui = Instance.new("ScreenGui")
	_gui.Name = "PartIclesTexturePin"
	_gui.Archivable = false
	_gui.DisplayOrder = -999
	_gui.IgnoreGuiInset = true
	_gui.ResetOnSpawn = false
	_gui.Parent = host
	return _gui
end

-- Resolve string ID or texture-bearing Instance to a Content ID; nil means skip.
local function _resolveAssetId(entry)
	if typeof(entry) == "string" then return entry ~= "" and entry or nil end
	if typeof(entry) ~= "Instance" then return nil end
	if entry:IsA("Decal") or entry:IsA("Texture") or entry:IsA("ParticleEmitter") or entry:IsA("Beam") or entry:IsA("Trail") then
		local t = entry.Texture; return (t and t ~= "") and t or nil
	elseif entry:IsA("ImageLabel") or entry:IsA("ImageButton") then
		local t = entry.Image; return (t and t ~= "") and t or nil
	elseif entry:IsA("SpecialMesh") then
		-- SpecialMesh.TextureId (lowercase d).
		local t = entry.TextureId; return (t and t ~= "") and t or nil
	elseif entry:IsA("MeshPart") then
		-- MeshPart.TextureID (uppercase D); checked AFTER Beam etc.
		local t = entry.TextureID; return (t and t ~= "") and t or nil
	end
end

-- SurfaceAppearance carries 4 PBR slots; pin all four. Other entries use _resolveAssetId.
local function _appendAssetIds(entry, list)
	if entry:IsA("SurfaceAppearance") then
		for _, prop in ipairs({"ColorMap", "NormalMap", "MetalnessMap", "RoughnessMap"}) do
			local ok, t = pcall(function() return entry[prop] end)
			if ok and t and t ~= "" then table.insert(list, t) end
		end
		return
	end
	local id = _resolveAssetId(entry)
	if id then table.insert(list, id) end
end

-- Pin one or many assets for `owner`. De-duped via `_pinned`; owner defaults to anonymous.
function TexturePin.pin(input, owner)
	if not input then return end
	owner = owner or _ANON
	local items = (type(input) == "table") and input or { input }
	local newPins = {}
	for _, entry in ipairs(items) do
		local assetId = _resolveAssetId(entry)
		if assetId then
			if not _pinned[assetId] then
				local gui = ensureGui()
				if not gui then break end  -- server context: skip remaining pins entirely
				local img = Instance.new("ImageLabel")
				img.Name = "Pin"; img.Image = assetId
				img.Size = UDim2.fromOffset(1, 1); img.Position = UDim2.fromOffset(0, 0)
				img.BackgroundTransparency = 1; img.ImageTransparency = 0.99 -- 1.0 culls and evicts
				img.BorderSizePixel = 0; img.ZIndex = 1
				img.Parent = gui
				_pinned[assetId] = img
				table.insert(newPins, img)
			end
			local owners = _ownersOf[assetId]; if not owners then owners = {}; _ownersOf[assetId] = owners end
			owners[owner] = true
			local assets = _assetsByOwner[owner]; if not assets then assets = {}; _assetsByOwner[owner] = assets end
			assets[assetId] = true
		end
	end
	if #newPins > 0 then task.spawn(function() pcall(ContentProvider.PreloadAsync, ContentProvider, newPins) end) end
end

-- Pin every texture-bearing descendant of `root`; owner = root.
function TexturePin.pinSubtree(root)
	if not root then return end
	local ids = {}
	_appendAssetIds(root, ids)
	local ok, descendants = pcall(root.GetDescendants, root)
	if ok then
		for _, d in ipairs(descendants) do _appendAssetIds(d, ids) end
	end
	if #ids > 0 then TexturePin.pin(ids, root) end
end

function TexturePin.isPinned(assetId) return _pinned[assetId] ~= nil end

function TexturePin.count()
	local n = 0; for _ in pairs(_pinned) do n += 1 end; return n
end

-- Drop owner's claim. Pin destroyed only when zero owners remain.
function TexturePin.unpin(input, owner)
	if not input then return end
	owner = owner or _ANON
	local items = (type(input) == "table") and input or { input }
	for _, entry in ipairs(items) do
		local assetId = _resolveAssetId(entry)
		if assetId and _pinned[assetId] then
			local owners = _ownersOf[assetId]
			if owners then owners[owner] = nil end
			local assets = _assetsByOwner[owner]
			if assets then assets[assetId] = nil end
			local anyOwner = false; if owners then for _ in pairs(owners) do anyOwner = true; break end end
			if not anyOwner then
				pcall(_pinned[assetId].Destroy, _pinned[assetId])
				_pinned[assetId] = nil; _ownersOf[assetId] = nil
			end
		end
	end
end

-- Release every pin this owner holds; hooked into DescendantRemoving for auto-cleanup.
function TexturePin.releaseOwner(owner)
	if not owner then return end
	local assets = _assetsByOwner[owner]; if not assets then return end
	for assetId in pairs(assets) do
		local owners = _ownersOf[assetId]
		if owners then owners[owner] = nil end
		local anyOwner = false; if owners then for _ in pairs(owners) do anyOwner = true; break end end
		if not anyOwner and _pinned[assetId] then
			pcall(_pinned[assetId].Destroy, _pinned[assetId])
			_pinned[assetId] = nil; _ownersOf[assetId] = nil
		end
	end
	_assetsByOwner[owner] = nil
end

-- Mirror of pinSubtree; other owners' shares persist.
function TexturePin.unpinSubtree(root)
	if not root then return end
	local ids = {}
	_appendAssetIds(root, ids)
	local ok, descendants = pcall(root.GetDescendants, root)
	if ok then
		for _, d in ipairs(descendants) do _appendAssetIds(d, ids) end
	end
	if #ids > 0 then TexturePin.unpin(ids, root) end
end

-- Destroy every pin + the host ScreenGui. Called on plugin toggle-off / Deactivate.
function TexturePin.clear()
	_pinned = {}; _ownersOf = {}; _assetsByOwner = {}
	if _gui then pcall(_gui.Destroy, _gui); _gui = nil end
end

return TexturePin
