--[[
	Animator (client): plays the board animations (Luffy / Board2 rig by default), one pose at a time with a crossfade.
	  on the snow: Left / Right while carving, Forward while riding straight, Idle when slow
	  in the air:  Float, with a Jump shot on takeoff and a Land shot on touchdown
	Which animation is used for each slot is in Config.AnimationSources / Config.AnimationIds.
	The board tester can pass a different board (an entry from Config.TestBoards): then that board's rig
	animations are used instead (Studio only).

	Note: saved KeyframeSequences only play in Studio, and only for the client that loads them: other players can't
	see them on your rider. For the live game (and so everyone sees everyone's poses), publish them and paste the
	ids into Config.AnimationIds: then your client plays them and Roblox shows them to everyone. Until then
	RemoteRiders plays the other riders' poses on each client (Studio only).
	The board hangs off the HumanoidRootPart, and each saved animation is fitted to it when loaded (BoardRig), so the
	board moves exactly as in the animation and blends smoothly between poses. Published ids are used as they are.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local Config = require(script.Parent:WaitForChild("Config"))
local BoardRig = require(script.Parent:WaitForChild("BoardRig"))

local Animator = {}
Animator.__index = Animator

local SLOTS = { "Idle", "Forward", "Left", "Right", "Jump", "Float", "Land" }
local LOOPS = { "Idle", "Forward", "Left", "Right", "Float" }
-- the looping poses share one priority so they crossfade cleanly; one-shots play over them
local PRIORITY = {
	Idle = Enum.AnimationPriority.Movement, Forward = Enum.AnimationPriority.Movement,
	Left = Enum.AnimationPriority.Movement, Right = Enum.AnimationPriority.Movement,
	Float = Enum.AnimationPriority.Movement,
	Jump = Enum.AnimationPriority.Action, Land = Enum.AnimationPriority.Action,
}

local cache = {} -- registered Studio ids ("Rig/Animation" -> id), shared between respawns and board swaps

-- the saved animation (KeyframeSequence) in BoardAssets.Rigs.<rigName>.AnimSaves
local function findSequence(rigName, animName)
	local rigs = ReplicatedStorage:FindFirstChild("BoardAssets") and ReplicatedStorage.BoardAssets:FindFirstChild("Rigs")
	local rig = rigs and rigs:FindFirstChild(rigName)
	local saves = rig and rig:FindFirstChild("AnimSaves")
	return saves and saves:FindFirstChild(animName)
end

local fittedFolder -- the fitted copies (client only)
local function register(rigName, animName, target)
	local key = rigName .. "/" .. animName .. "|" .. BoardRig.Signature(target)
	if cache[key] then
		return cache[key]
	end
	local sequence = findSequence(rigName, animName)
	if sequence and RunService:IsStudio() then
		-- a copy fitted to this rider's board (the saved animation itself is left alone; see BoardRig)
		local fitted = BoardRig.Retarget(sequence, sequence.Parent.Parent, target)
		if not fittedFolder then
			fittedFolder = Instance.new("Folder")
			fittedFolder.Name = "BoardRigCache"
			fittedFolder.Parent = ReplicatedStorage
		end
		fitted.Name = rigName .. "_" .. animName
		fitted.Parent = fittedFolder
		local ok, registered = pcall(function()
			return KeyframeSequenceProvider:RegisterKeyframeSequence(fitted)
		end)
		if ok then
			cache[key] = registered
			return registered
		end
	end
	return nil
end

-- where a slot's animation comes from: { rig, animation name } (or a published id for the normal board)
local function sourceFor(slot, board)
	if board and not board.Default then
		local entry = board.AnimNames and board.AnimNames[slot]
		if type(entry) == "table" then
			return nil, entry[1], entry[2] -- borrowed from another rig, e.g. { "Board5", "Jump" }
		end
		return nil, board.Rig, entry or slot
	end
	local id = Config.AnimationIds[slot]
	if id and id ~= "" then
		return id
	end
	local source = Config.AnimationSources[slot]
	if source then
		return nil, source[1], source[2]
	end
	return nil
end

local function resolveId(slot, board, target)
	local id, rigName, animName = sourceFor(slot, board)
	if id then
		return id
	end
	return rigName and register(rigName, animName, target)
end

-- slots a board has no animation for (used by the board tester to show e.g. "no air anims")
function Animator.MissingSlots(board)
	local missing = {}
	for _, slot in ipairs(SLOTS) do
		local id, rigName, animName = sourceFor(slot, board)
		if not id and not (rigName and findSequence(rigName, animName)) then
			table.insert(missing, slot)
		end
	end
	return missing
end

-- true while some board pose is only a Studio save (not published): other players can't see those on your rider, so
-- each client plays the other riders' poses itself (RemoteRiders)
function Animator.NeedsLocalPlayback()
	if not RunService:IsStudio() then
		return false
	end
	for _, slot in ipairs(SLOTS) do
		local id, rigName = sourceFor(slot, nil)
		if not id and rigName then
			return true
		end
	end
	return false
end

-- board: optional entry from Config.TestBoards (nil = the normal board on StarterCharacter)
-- opts.RemoteOnly: for another player's rider (RemoteRiders): only the poses that aren't published (Roblox already shows
-- the published ones), and no warnings
function Animator.new(character, controller, board, opts)
	local self = setmetatable({}, Animator)
	local humanoid = character:WaitForChild("Humanoid")
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	self.Tracks = {}
	self.Weights = {}
	self.Missing = {}
	-- the board these animations are fitted to (the tester's swapped board, or the normal one)
	local target = BoardRig.BoardJoint(character, board and not board.Default and board.Part or nil)
	for _, slot in ipairs(SLOTS) do
		local skip = opts and opts.RemoteOnly and sourceFor(slot, board) ~= nil -- published: Roblox already shows it
		local id = not skip and resolveId(slot, board, target) or nil
		if skip then
			-- nothing to load
		elseif id then
			local animation = Instance.new("Animation")
			animation.AnimationId = id
			local ok, track = pcall(function()
				return animator:LoadAnimation(animation)
			end)
			if ok and track then
				track.Priority = PRIORITY[slot] or Enum.AnimationPriority.Action
				track.Looped = table.find(LOOPS, slot) ~= nil
				self.Tracks[slot] = track
			else
				table.insert(self.Missing, slot)
			end
		else
			table.insert(self.Missing, slot)
		end
	end
	if #self.Missing > 0 and not (opts and opts.RemoteOnly) then
		if board and not board.Default then
			warn("[Snowboard] " .. board.Name .. " board has no " .. table.concat(self.Missing, ", ") .. " animation(s) in Rigs." .. board.Rig .. ".AnimSaves")
		else
			warn("[Snowboard] Animations not loaded: " .. table.concat(self.Missing, ", ") .. " (publish them and set Config.AnimationIds)")
		end
	end
	for _, slot in ipairs(LOOPS) do
		local track = self.Tracks[slot]
		if track then
			local weight = slot == "Idle" and 1 or 0.001
			track:Play(0.2, weight, 1)
			self.Weights[slot] = weight
		end
	end
	self.State = "Idle"
	self.Connections = {}
	if controller then
		table.insert(self.Connections, controller.Jumped.Event:Connect(function()
			self:PlayOnce("Jump", 1.2)
		end))
		table.insert(self.Connections, controller.Landed.Event:Connect(function()
			self:PlayOnce("Land", 1.8)
		end))
	end
	return self
end

function Animator:PlayOnce(slot, speed)
	local track = self.Tracks[slot]
	if track then
		track:Play(0.06, 1, speed or 1)
		self.Shot, self.ShotAt = slot, os.clock() -- shown on the board tester's "Playing" line
	end
end

-- crossfade to one looping pose
function Animator:SetState(state)
	if state == self.State or not self.Tracks[state] then
		return
	end
	self.State = state
	local fade = Config.Animation.Fade
	for _, slot in ipairs(LOOPS) do
		local track = self.Tracks[slot]
		if track then
			track:AdjustWeight(slot == state and 1 or 0.001, fade)
		end
	end
end

function Animator:Update(controller)
	local A = Config.Animation
	local state
	if not controller.Grounded and controller.AirTime > 0.15 then
		state = "Float"
	elseif controller.Steer > A.SteerThreshold then
		state = "Right"
	elseif controller.Steer < -A.SteerThreshold then
		state = "Left"
	elseif controller.Speed > A.RideSpeed then
		state = "Forward"
	else
		state = "Idle"
	end
	self:SetState(state)
end

function Animator:Destroy()
	for _, c in ipairs(self.Connections) do
		c:Disconnect()
	end
	for _, track in pairs(self.Tracks) do
		track:Stop(0.1)
	end
end

return Animator
