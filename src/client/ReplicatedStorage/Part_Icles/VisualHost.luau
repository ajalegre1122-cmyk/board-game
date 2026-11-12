--[[
	VisualHost  -  the one place that decides where runtime visuals live.
	Root = workspace.CurrentCamera: Team Create never replicates Camera descendants, so emitted
	clones, pooled clones, previews, screen effects and the distortion canvas stay local to the
	emitting user. A game server has a camera too and nothing under it reaches any player, so
	on a server the root is workspace.Terrain, which replicates; the same without a camera.
	Folders are re-parented, never recreated, when Studio swaps the camera, so live pData
	references stay valid. Anything parented elsewhere is user intent (EmitParent) or an engine
	constraint (Atmosphere renders only under Lighting).
	Carriers: invisible anchored Parts that mirror a user BasePart's CFrame every frame, so
	Attachment / Light visuals that used to live INSIDE the user's part keep parent-relative
	motion without replicating. Engine.step calls VisualHost.tick() before any particle update.
	Edit audio host: Studio plays a plugin's Sounds in edit mode only under a DockWidgetPluginGui.
	The plugin registers one (init.server.lua); games never do, so their Sounds stay positional.
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local VisualHost = {}

local LEGACY_ROOT = workspace.Terrain
local FOLDER_NAMES = { live = "EmittedPartsUsingPart_icle", pool = "Part_IclesPooled", preview = "MotionPreview" }

local _folders = {}
local _cameraConn = nil
local _carriers = {}
local _editAudioHost = nil

-- True where the code runs as a server only: a live server, Studio's Run mode and the server
-- side of a play test. Studio edit mode and Team Create editing count as a client.
local function isServerOnly()
	return RunService:IsServer() and not RunService:IsClient()
end

-- The camera for a client or the editor, else Terrain (a server, or no camera); both keep
-- Workspace ancestry so Beams, Trails and BulkMoveTo keep working.
function VisualHost.root()
	if isServerOnly() then return LEGACY_ROOT end
	local cam = workspace.CurrentCamera
	if cam then return cam end
	return LEGACY_ROOT
end

-- Blur / Bloom / ColorCorrection render under the Camera (player-local); Atmosphere is
-- Lighting-only, and so is everything a server emits, for the same reason as root().
function VisualHost.screenEffectParent(kind)
	if kind == "Atmosphere" or isServerOnly() then return Lighting end
	return workspace.CurrentCamera or Lighting
end

local function watchCamera()
	if _cameraConn then return end
	_cameraConn = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		VisualHost.rehome()
	end)
end

-- Move every cached folder under the current root (camera swap). Destroyed folders are dropped
-- so the next accessor rebuilds them.
function VisualHost.rehome()
	local root = VisualHost.root()
	for key, folder in pairs(_folders) do
		if folder.Parent == nil then
			_folders[key] = nil
		elseif folder.Parent ~= root then
			pcall(function() folder.Parent = root end)
		end
	end
end

-- Find-or-create a runtime folder under the root. A folder left under Terrain by an older
-- version (or by a session that died) is adopted and re-parented, so nothing is duplicated.
local function ensureFolder(key)
	local folder = _folders[key]
	if folder and folder.Parent then return folder end
	local name = FOLDER_NAMES[key]
	local root = VisualHost.root()
	folder = root:FindFirstChild(name) or LEGACY_ROOT:FindFirstChild(name)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Archivable = false
	end
	if folder.Parent ~= root then
		pcall(function() folder.Parent = root end)
	end
	_folders[key] = folder
	watchCamera()
	return folder
end

-- Live emit clones.
function VisualHost.getFolder()
	return ensureFolder("live")
end

-- Idle pool entries (Pool.release re-parents here so the Explorer shows what is recyclable).
function VisualHost.getPoolFolder()
	return ensureFolder("pool")
end

-- Motion Preview adornments.
function VisualHost.getPreviewFolder()
	return ensureFolder("preview")
end

-- Distortion canvas parts sit directly under the root.
function VisualHost.getCanvasParent()
	watchCamera()
	return VisualHost.root()
end

-- Set once by the plugin at load (init.server.lua); outlives Activate / Deactivate, so reset() keeps it.
function VisualHost.setEditAudioHost(host)
	_editAudioHost = host
end

-- The plugin's audio widget while it exists; nil in games (Sound emitters then play positionally).
function VisualHost.getEditAudioHost()
	if _editAudioHost and _editAudioHost.Parent then
		return _editAudioHost
	end
	return nil
end

-- Anchor pose: BasePart CFrame or Attachment WorldCFrame.
local function anchorCFrame(anchor)
	if anchor:IsA("Attachment") then return anchor.WorldCFrame end
	return anchor.CFrame
end

-- Carrier: an invisible anchored Part under the live folder that tracks `anchor` (BasePart or
-- Attachment) each frame. Released by _releaseOrDestroy through releaseCarrier; never pooled.
function VisualHost.acquireCarrier(anchor)
	local carrier = Instance.new("Part")
	carrier.Name = "_Carrier"
	carrier.Anchored = true
	carrier.CanCollide = false
	carrier.CanQuery = false
	carrier.CanTouch = false
	carrier.CastShadow = false
	carrier.Transparency = 1
	carrier.Size = anchor:IsA("BasePart") and anchor.Size or Vector3.new(1, 1, 1)
	carrier.CFrame = anchorCFrame(anchor)
	carrier.Archivable = false
	carrier:SetAttribute("_PartIcleEmit", true)
	carrier.Parent = VisualHost.getFolder()
	_carriers[carrier] = anchor
	return carrier
end

function VisualHost.releaseCarrier(carrier)
	if not carrier then return end
	_carriers[carrier] = nil
	pcall(function() carrier:Destroy() end)
end

-- Per-frame mirror. Runs before particle updates so parent-relative math reads this frame's pose.
-- A destroyed anchor freezes its carrier in place (the particle keeps its last parent frame).
function VisualHost.tick()
	if next(_carriers) == nil then return end
	for carrier, anchor in pairs(_carriers) do
		if carrier.Parent == nil then
			_carriers[carrier] = nil
		elseif anchor.Parent ~= nil then
			carrier.CFrame = anchorCFrame(anchor)
		end
	end
end

-- Deactivate: destroy every runtime folder + carrier and stop watching the camera.
function VisualHost.reset()
	if _cameraConn then
		_cameraConn:Disconnect()
		_cameraConn = nil
	end
	for carrier in pairs(_carriers) do
		pcall(function() carrier:Destroy() end)
	end
	table.clear(_carriers)
	for key, folder in pairs(_folders) do
		if folder.Parent then pcall(function() folder:Destroy() end) end
		_folders[key] = nil
	end
	-- Folders a previous version left under Terrain.
	for _, name in pairs(FOLDER_NAMES) do
		local stale = LEGACY_ROOT:FindFirstChild(name)
		if stale then pcall(function() stale:Destroy() end) end
	end
end

return VisualHost
