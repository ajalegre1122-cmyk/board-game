--[[
	BoardTester (client, testing only): a small collapsible panel at the bottom-left, just above the controls line.
	  click the header (or press B) to open / close it
	  click a board (or press 1-5 while it's open) to ride it: the board model, its animations and its effects
	  (BoardAssets.VFXBoards) swap on your character
	The "Playing" line shows which animation is on right now, so you can check each one.
	Only you see the swap (it's made on your screen only). The list of boards is Config.TestBoards;
	turn the panel off with Config.BoardTester.Enabled = false.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(script.Parent:WaitForChild("Config"))
local BoardRig = require(script.Parent:WaitForChild("BoardRig"))
local Animator = require(script.Parent:WaitForChild("Animator"))

local BoardTester = {}
BoardTester.__index = BoardTester

-- colours match the HUD
local PANEL = Color3.fromRGB(16, 24, 40)
local ROW = Color3.fromRGB(34, 48, 76)
local ACCENT = Color3.fromRGB(120, 210, 255)
local TEXT = Color3.fromRGB(235, 242, 250)
local MUTED = Color3.fromRGB(150, 168, 195)
local WIDTH = 220
local ROW_HEIGHT = 26

local BODY = {
	HumanoidRootPart = true, Torso = true, Head = true,
	["Left Arm"] = true, ["Right Arm"] = true, ["Left Leg"] = true, ["Right Leg"] = true,
}
local NUMBER_KEYS = {
	Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five,
	Enum.KeyCode.Six, Enum.KeyCode.Seven, Enum.KeyCode.Eight, Enum.KeyCode.Nine,
}

local function make(className, props, parent)
	local obj = Instance.new(className)
	for k, v in pairs(props) do
		obj[k] = v
	end
	obj.Parent = parent
	return obj
end

local function isJoint(obj)
	return obj:IsA("JointInstance") or obj:IsA("WeldConstraint")
end

-- finds a PART by name (the rigs also have joints with the same names as their parts, e.g. Motor6D "Nimbus")
local function findPart(root, name)
	if not (root and name) then
		return nil
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == name then
			return d
		end
	end
	return nil
end

-- every part of a board: the board part plus everything jointed to it (but not the body)
local function boardGroup(model, rootPart)
	local set, list = { [rootPart] = true }, { rootPart }
	local joints = {}
	for _, d in ipairs(model:GetDescendants()) do
		if isJoint(d) then
			table.insert(joints, d)
		end
	end
	local grew = true
	while grew do
		grew = false
		for _, j in ipairs(joints) do
			local a, b = j.Part0, j.Part1
			if a and b then
				if set[a] and not set[b] and not BODY[b.Name] then
					set[b] = true
					table.insert(list, b)
					grew = true
				elseif set[b] and not set[a] and not BODY[a.Name] then
					set[a] = true
					table.insert(list, a)
					grew = true
				end
			end
		end
	end
	for _, d in ipairs(rootPart:GetDescendants()) do
		if d:IsA("BasePart") and not set[d] then
			set[d] = true
			table.insert(list, d)
		end
	end
	return list, set
end

-- the Motor6Ds from the Torso to a board part (e.g. the LuffyBoard built into StarterCharacter)
local function boardJoints(model)
	local torso = model:FindFirstChild("Torso")
	local root = model:FindFirstChild("HumanoidRootPart")
	local found = {}
	if torso then
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("Motor6D") and (d.Part0 == torso or (root and d.Part0 == root)) and d.Part1 and not BODY[d.Part1.Name] then
				table.insert(found, d)
			end
		end
	end
	return found
end

-- copies a board off its rig (BoardAssets.Rigs) onto the character, joined to the Torso exactly like on the rig,
-- so the rig's animations pose it the same way. Returns the folder, the joint and the part for the snow spray.
local function cloneBoard(board, character)
	local assets = ReplicatedStorage:FindFirstChild("BoardAssets")
	local rigs = assets and assets:FindFirstChild("Rigs")
	local rig = rigs and rigs:FindFirstChild(board.Rig)
	local rigTorso = rig and rig:FindFirstChild("Torso")
	local part = findPart(rig, board.Part)
	local torso = character:FindFirstChild("Torso")
	if not (rigTorso and part and part:IsA("BasePart") and torso) then
		warn("[BoardTester] Can't find " .. tostring(board.Part) .. " in BoardAssets.Rigs." .. tostring(board.Rig))
		return nil
	end
	local joint
	for _, d in ipairs(rig:GetDescendants()) do
		if d:IsA("Motor6D") and d.Part0 == rigTorso and d.Part1 == part then
			joint = d
			break
		end
	end

	local list, set = boardGroup(rig, part)
	local folder = Instance.new("Folder")
	folder.Name = "TestBoard"
	local map = {} -- rig part -> copy
	for _, original in ipairs(list) do
		if not set[original.Parent] then -- top of a branch: its children come along with the copy
			local copy = original:Clone()
			map[original] = copy
			local from, to = original:GetDescendants(), copy:GetDescendants()
			for i, d in ipairs(from) do
				if to[i] and to[i].Name == d.Name then
					map[d] = to[i]
				end
			end
			copy.Parent = folder
		end
	end
	for _, copy in pairs(map) do
		-- joints between separate pieces (e.g. Kurapika's chains) still point at the rig: point them at the copies
		if isJoint(copy) then
			if copy.Part0 and map[copy.Part0] then
				copy.Part0 = map[copy.Part0]
			end
			if copy.Part1 and map[copy.Part1] then
				copy.Part1 = map[copy.Part1]
			end
		end
		if copy:IsA("BasePart") then
			copy.Anchored = false
			copy.CanCollide = false
			copy.CanTouch = false
			copy.CanQuery = false
			copy.Massless = true
			if copy.ClassName == "Part" and copy.Transparency > 0 then
				copy.Transparency = 1 -- see-through helper parts (like Kurapika's Handle) are hidden
			end
		end
	end

	local motor = Instance.new("Motor6D")
	motor.Name = joint and joint.Name or board.Part -- animations find the board by this name
	motor.C0 = joint and joint.C0 or CFrame.new(0, -Config.BoardBelowRoot, 0)
	motor.C1 = joint and joint.C1 or CFrame.new()
	motor.Part0 = torso
	motor.Part1 = map[part]
	folder.Parent = character
	motor.Parent = torso
	BoardRig.Attach(motor, character) -- hang it off the root like the normal board (see BoardRig)
	local fxPart = findPart(folder, board.FxPart) or map[part]
	return folder, motor, fxPart
end

-- puts a board's effects (BoardAssets.VFXBoards.<board.Vfx>) on the copied board: the trail, glows, auras, beams and
-- particles. In those models the effect holder parts (EndStuff etc.) sit around the board's deck mesh, and loose
-- attachments / trails / emitters belong on the deck itself, so everything is placed the same way around our copy
-- of the deck (board.VfxDeck names the deck in the VFX model) and welded to it. Copies of the board's own meshes
-- that are in the VFX model are skipped (the board is already there).
local function attachVfx(board, folder)
	local assets = ReplicatedStorage:FindFirstChild("BoardAssets")
	local library = assets and assets:FindFirstChild("VFXBoards")
	local source = board.Vfx and library and library:FindFirstChild(board.Vfx)
	if not source then
		if board.Vfx then
			warn("[BoardTester] No effects called " .. board.Vfx .. " in BoardAssets.VFXBoards")
		end
		return
	end
	-- the board's own parts (copied from its rig), by mesh
	local ownByMesh = {}
	for _, d in ipairs(folder:GetDescendants()) do
		if d:IsA("MeshPart") and d.MeshId ~= "" and not ownByMesh[d.MeshId] then
			ownByMesh[d.MeshId] = d
		end
	end
	local copy = source:Clone()
	local vfxDeck = findPart(copy, board.VfxDeck)
	local deck = vfxDeck and vfxDeck:IsA("MeshPart") and ownByMesh[vfxDeck.MeshId]
	if not deck then
		warn("[BoardTester] Can't line up " .. board.Vfx .. " with the " .. board.Name .. " board (VfxDeck = " .. tostring(board.VfxDeck) .. ")")
		copy:Destroy()
		return
	end
	local base = vfxDeck.CFrame
	-- 1) where every effect part goes (worked out before anything moves)
	local placed = {}
	for _, p in ipairs(copy:GetDescendants()) do
		if p:IsA("BasePart") and not (p:IsA("MeshPart") and ownByMesh[p.MeshId]) then
			table.insert(placed, { p, deck.CFrame * base:ToObjectSpace(p.CFrame) })
		end
	end
	for _, item in ipairs(placed) do
		local p = item[1]
		p.CFrame = item[2]
		p.Anchored = false
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.Massless = true
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = deck
		weld.Part1 = p
		weld.Parent = p
	end
	-- 2) move it all onto our deck: effect parts, plus loose attachments / trails / emitters from the model
	for _, child in ipairs(copy:GetChildren()) do
		if child:IsA("MeshPart") and ownByMesh[child.MeshId] then
			-- a copy of the board itself: keep anything hanging off it, drop the mesh
			for _, sub in ipairs(child:GetChildren()) do
				if not sub:IsA("JointInstance") and not sub:IsA("WeldConstraint") then
					sub.Parent = deck
				end
			end
			child:Destroy()
		else
			child.Parent = deck
		end
	end
	copy:Destroy()
end

-- short note next to a board's name about missing animations
local function noteFor(missing)
	if #missing == 0 then
		return ""
	end
	local air = { Jump = true, Float = true, Land = true }
	local onlyAir = true
	for _, slot in ipairs(missing) do
		if not air[slot] then
			onlyAir = false
		end
	end
	if onlyAir and #missing == 3 then
		return "no air anims"
	end
	return "no " .. string.lower(table.concat(missing, "/"))
end

-- onPick(board) runs when you pick a board. Returns nil when the panel is turned off in Config.
function BoardTester.new(onPick)
	local settings = Config.BoardTester
	local boards = Config.TestBoards or {}
	if not settings or not settings.Enabled or #boards == 0 then
		return nil
	end
	if settings.StudioOnly and not RunService:IsStudio() then
		return nil
	end

	local self = setmetatable({}, BoardTester)
	self.Boards = boards
	self.Selected = boards[1]
	for _, board in ipairs(boards) do
		if board.Default then
			self.Selected = board
			break
		end
	end
	self.OnPick = onPick
	self.Saved = {} -- { instance, property, old value } for the hidden normal board
	self.Rows = {}
	self.Connections = {}

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild("BoardTester")
	if old then
		old:Destroy()
	end
	local gui = make("ScreenGui", { Name = "BoardTester", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 2 }, playerGui)
	self.Gui = gui

	-- bottom-left, just above the controls line. Opening grows it upward; the header stays where it is.
	local panel = make("Frame", {
		Name = "Panel", AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 24, 1, -54),
		Size = UDim2.fromOffset(WIDTH, 0), AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = PANEL, BackgroundTransparency = 0.2, BorderSizePixel = 0,
	}, gui)
	make("UICorner", { CornerRadius = UDim.new(0, 10) }, panel)
	make("UIStroke", { Color = ACCENT, Transparency = 0.7, Thickness = 1 }, panel)
	make("UIPadding", {
		PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 2), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4),
	}, panel)
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }, panel)

	-- the board list (hidden while collapsed)
	local list = make("Frame", {
		Name = "List", LayoutOrder = 1, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
	}, panel)
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 3) }, list)
	self.List = list

	for i, board in ipairs(boards) do
		local row = make("TextButton", {
			Name = board.Name, LayoutOrder = i, AutoButtonColor = false, Text = "",
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT), BackgroundColor3 = ROW, BackgroundTransparency = 0.35, BorderSizePixel = 0,
		}, list)
		make("UICorner", { CornerRadius = UDim.new(0, 6) }, row)
		local stroke = make("UIStroke", { Color = ACCENT, Thickness = 1.5, Transparency = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, row)
		make("TextLabel", {
			Name = "Key", BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 0), Size = UDim2.new(0, 14, 1, 0),
			Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left,
			Text = i <= #NUMBER_KEYS and tostring(i) or "",
		}, row)
		local name = make("TextLabel", {
			Name = "BoardName", BackgroundTransparency = 1, Position = UDim2.fromOffset(24, 0), Size = UDim2.new(1, -30, 1, 0),
			Font = Enum.Font.GothamMedium, TextSize = 14, TextColor3 = TEXT, TextXAlignment = Enum.TextXAlignment.Left,
			Text = board.Name,
		}, row)
		make("TextLabel", {
			Name = "Note", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0, 0),
			Size = UDim2.new(0, 96, 1, 0), Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = MUTED,
			TextXAlignment = Enum.TextXAlignment.Right, Text = noteFor(Animator.MissingSlots(board)),
		}, row)
		table.insert(self.Connections, row.MouseEnter:Connect(function()
			if board ~= self.Selected then
				row.BackgroundTransparency = 0.1
			end
		end))
		table.insert(self.Connections, row.MouseLeave:Connect(function()
			self:Refresh()
		end))
		table.insert(self.Connections, row.Activated:Connect(function()
			self:Pick(board)
		end))
		self.Rows[board] = { Button = row, Stroke = stroke, Name = name }
	end

	-- which animation is playing right now
	self.Status = make("TextLabel", {
		Name = "Playing", LayoutOrder = 100, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20),
		Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left,
		RichText = true, Text = "",
	}, list)
	make("UIPadding", { PaddingLeft = UDim.new(0, 8) }, self.Status)

	self.Divider = make("Frame", {
		Name = "Divider", LayoutOrder = 2, Size = UDim2.new(1, -8, 0, 1), BackgroundColor3 = ACCENT,
		BackgroundTransparency = 0.75, BorderSizePixel = 0,
	}, panel)

	-- header: click to open / close
	local header = make("TextButton", {
		Name = "Header", LayoutOrder = 3, AutoButtonColor = false, Text = "", BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 28),
	}, panel)
	make("TextLabel", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 0), Size = UDim2.new(0, 50, 1, 0),
		Font = Enum.Font.GothamBlack, TextSize = 11, TextColor3 = ACCENT, TextXAlignment = Enum.TextXAlignment.Left,
		Text = "BOARD",
	}, header)
	self.Current = make("TextLabel", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(58, 0), Size = UDim2.new(1, -110, 1, 0),
		Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = TEXT, TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd, Text = "",
	}, header)
	local keyName = settings.ToggleKey and settings.ToggleKey.Name or ""
	self.Arrow = make("TextLabel", {
		BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0, 0), Size = UDim2.new(0, 50, 1, 0),
		Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Right, Text = "",
	}, header)
	self.KeyName = keyName
	table.insert(self.Connections, header.Activated:Connect(function()
		self:SetOpen(not self.Open)
	end))

	table.insert(self.Connections, UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if settings.ToggleKey and input.KeyCode == settings.ToggleKey then
			self:SetOpen(not self.Open)
		elseif self.Open then
			local i = table.find(NUMBER_KEYS, input.KeyCode)
			if i and boards[i] then
				self:Pick(boards[i])
			end
		end
	end))

	self:SetOpen(settings.StartOpen == true)
	self:Refresh()
	return self
end

function BoardTester:SetOpen(open)
	self.Open = open
	self.List.Visible = open
	self.Divider.Visible = open
	self.Arrow.Text = (self.KeyName ~= "" and ("[" .. self.KeyName .. "]  ") or "") .. (open and "▼" or "▲")
end

function BoardTester:Pick(board)
	if board == self.Selected then
		return
	end
	self.Selected = board
	self:Refresh()
	if self.OnPick then
		self.OnPick(board)
	end
end

function BoardTester:Refresh()
	for board, row in pairs(self.Rows) do
		local on = board == self.Selected
		row.Button.BackgroundColor3 = on and ACCENT or ROW
		row.Button.BackgroundTransparency = on and 0.72 or 0.35
		row.Stroke.Transparency = on and 0.25 or 1
		row.Name.Font = on and Enum.Font.GothamBold or Enum.Font.GothamMedium
	end
	self.Current.Text = self.Selected.Name
end

-- puts the picked board on the character (hides the normal board, copies the test board on).
-- Returns the part the snow spray should sit on (nil = the normal LuffyBoard).
function BoardTester:Apply(character, board)
	board = board or self.Selected
	self:Restore()
	if board.Default then
		return nil
	end
	-- hide the normal board (and switch off its particles / beams / trails) on this screen only
	for _, joint in ipairs(boardJoints(character)) do
		for _, part in ipairs((boardGroup(character, joint.Part1))) do
			self:Set(part, "Transparency", 1)
			for _, d in ipairs(part:GetDescendants()) do
				if d:IsA("Decal") or d:IsA("Texture") then
					self:Set(d, "Transparency", 1)
				elseif d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") or d:IsA("Light") then
					self:Set(d, "Enabled", false)
					if d:IsA("ParticleEmitter") then
						d:Clear()
					end
				end
			end
		end
	end
	local folder, motor, fxPart = cloneBoard(board, character)
	if not folder then
		self:Restore() -- couldn't build it: keep the normal board
		return nil
	end
	self.Folder, self.Motor = folder, motor
	attachVfx(board, folder) -- the board's own trail, aura, beams and particles
	return fxPart
end

function BoardTester:Set(obj, prop, value)
	table.insert(self.Saved, { obj, prop, obj[prop] })
	obj[prop] = value
end

-- brings the normal board back and removes the test board
function BoardTester:Restore()
	for i = #self.Saved, 1, -1 do
		local s = self.Saved[i]
		pcall(function()
			s[1][s[2]] = s[3]
		end)
	end
	self.Saved = {}
	if self.Folder then
		self.Folder:Destroy()
		self.Folder = nil
	end
	if self.Motor then
		self.Motor:Destroy()
		self.Motor = nil
	end
end

-- updates the "Playing" line (call every frame with the current Animator)
function BoardTester:Update(animator)
	if not self.Open then
		return
	end
	local text = animator and animator.State or "-"
	if animator and animator.Shot and os.clock() - animator.ShotAt < 0.5 then
		text = text .. " + " .. animator.Shot
	end
	if text ~= self.ShownText then
		self.ShownText = text
		self.Status.Text = 'Playing  <font color="#78D2FF"><b>' .. text .. "</b></font>"
	end
end

function BoardTester:Destroy()
	for _, c in ipairs(self.Connections) do
		c:Disconnect()
	end
	self:Restore()
	self.Gui:Destroy()
end

return BoardTester
