--[[
	HUD (client): speed readout (mph, bottom middle of the screen, no background box), run timer and the controls hint.
	The timer starts when you first get moving and resets when you respawn (R).
]]

local Players = game:GetService("Players")

local HUD = {}
HUD.__index = HUD

local STUDS_TO_MPH = 0.626 -- 1 stud = 0.28 m, so 1 stud/s = 0.626 mph
local OUTLINE = Color3.fromRGB(14, 22, 38) -- dark outline so the white text stays readable on bright snow

local function make(className, props, parent)
	local obj = Instance.new(className)
	for k, v in pairs(props) do
		obj[k] = v
	end
	obj.Parent = parent
	return obj
end

function HUD.new()
	local self = setmetatable({}, HUD)
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild("SnowboardHUD")
	if old then
		old:Destroy()
	end
	local gui = make("ScreenGui", { Name = "SnowboardHUD", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 1 }, playerGui) -- above the SpeedFX lines
	self.Gui = gui

	-- speed readout: bottom middle of the screen (just above the controls line), no background box
	local panel = make("Frame", {
		Name = "Speedometer", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -56), Size = UDim2.fromOffset(220, 92),
		BackgroundTransparency = 1,
	}, gui)
	self.Panel = panel
	-- number + "MPH" side by side, centred as one group
	-- hidden for now (kept, not removed): set Visible = true here and on SpeedBar below to bring the speedometer back
	local row = make("Frame", { Name = "SpeedRow", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 52), Visible = false }, panel)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Bottom, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
	}, row)
	self.SpeedLabel = make("TextLabel", {
		Name = "Speed", LayoutOrder = 1, BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 52),
		Font = Enum.Font.GothamBlack, TextSize = 46, TextColor3 = Color3.new(1, 1, 1), Text = "0",
	}, row)
	make("UIStroke", { Color = OUTLINE, Thickness = 2, Transparency = 0.3 }, self.SpeedLabel)
	local unit = make("TextLabel", {
		Name = "Unit", LayoutOrder = 2, BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 44),
		Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = Color3.fromRGB(150, 210, 255),
		TextYAlignment = Enum.TextYAlignment.Bottom, Text = "MPH",
	}, row)
	make("UIStroke", { Color = OUTLINE, Thickness = 1.5, Transparency = 0.3 }, unit)
	make("UIPadding", { PaddingBottom = UDim.new(0, 8) }, unit) -- lifts "MPH" onto the number's baseline
	local barBack = make("Frame", {
		Name = "SpeedBar", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 60), Size = UDim2.new(1, -40, 0, 6),
		BackgroundColor3 = Color3.fromRGB(40, 54, 80), BackgroundTransparency = 0.35, BorderSizePixel = 0,
		Visible = false, -- hidden for now (kept, not removed)
	}, panel)
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, barBack)
	self.SpeedBar = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, barBack)
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, self.SpeedBar)
	make("UIGradient", { Color = ColorSequence.new(Color3.fromRGB(120, 220, 255), Color3.fromRGB(255, 120, 200)) }, self.SpeedBar)
	self.TimerLabel = make("TextLabel", {
		Name = "Timer", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 68), Size = UDim2.new(1, 0, 0, 20),
		Font = Enum.Font.GothamMedium, TextSize = 15, TextColor3 = Color3.fromRGB(235, 242, 250),
		TextXAlignment = Enum.TextXAlignment.Center, Text = "0:00.00",
	}, panel)
	make("UIStroke", { Color = OUTLINE, Thickness = 1.5, Transparency = 0.35 }, self.TimerLabel)

	make("TextLabel", {
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 24, 1, -24), Size = UDim2.fromOffset(560, 22),
		BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 15,
		TextColor3 = Color3.new(1, 1, 1), TextStrokeTransparency = 0.6, TextXAlignment = Enum.TextXAlignment.Left,
		Text = "A / D  carve     W  tuck / push     S  brake     Space  jump     R  restart",
	}, gui)

	self.StartedAt = nil
	return self
end

-- moves the speed / timer group up so its bottom sits this many pixels above the bottom of the screen
-- (the client uses it to keep the timer just above the ability bar)
function HUD:SetBottomOffset(pixels)
	self.Panel.Position = UDim2.new(0.5, 0, 1, -pixels)
end

function HUD:ResetTimer()
	self.StartedAt = nil
	self.TimerLabel.Text = "0:00.00"
end

function HUD:Update(controller)
	local speed = controller.Speed
	self.SpeedLabel.Text = tostring(math.floor(speed * STUDS_TO_MPH + 0.5))
	self.SpeedBar.Size = UDim2.fromScale(math.clamp(speed / 150, 0, 1), 1)
	if not self.StartedAt and speed > 15 then
		self.StartedAt = os.clock()
	end
	if self.StartedAt then
		local t = os.clock() - self.StartedAt
		self.TimerLabel.Text = string.format("%d:%05.2f", math.floor(t / 60), t % 60)
	end
end

function HUD:Destroy()
	self.Gui:Destroy()
end

return HUD
