--[[
	AbilityBar (client UI): your character's 3 ability slots, bottom-middle of the screen (just under the run timer).
	    [ Skill 1 ]   [  ULTIMATE  ]   [ Skill 2 ]        keys Q / F / E (Config.Abilities.Keys)
	The ultimate sits in the middle and is bigger. Hover a slot to read what it does.

	UI ONLY for now: pressing a key or tapping a slot plays the press animation, starts that slot's cooldown
	(test values: Config.Abilities.Cooldowns, 5 s skills / 10 s ultimate) and fires
	AbilityBar.Activated(characterId, slot, ability) for the ability system to hook into later.
	While a slot is cooling down it's darkened with a countdown and pressing it just wiggles; it pops when ready.
	The ultimate charges up instead (Config.Abilities.UltCharge): the server keeps the % on you (the "UltCharge"
	attribute), the slot shows it ("57%") and the bar under it fills; at 100% it pops and glows.
	Characters and their abilities are in Config.Abilities.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Config = require(script.Parent:WaitForChild("Config"))
local Abilities = require(script.Parent:WaitForChild("Abilities"))

local AbilityBar = {}
AbilityBar.__index = AbilityBar

local PANEL = Color3.fromRGB(16, 24, 40)
local TEXT = Color3.fromRGB(235, 242, 250)
local MUTED = Color3.fromRGB(150, 168, 195)
local OUTLINE = Color3.fromRGB(14, 22, 38)
local SLOTS = { "Skill1", "Ultimate", "Skill2" } -- left to right
local POP = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local QUICK = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function make(className, props, parent)
	local obj = Instance.new(className)
	for k, v in pairs(props) do
		obj[k] = v
	end
	obj.Parent = parent
	return obj
end

-- "Rasen Shuriken" -> "RS" (the slot shows this until it has an icon)
local function initials(ability)
	if ability.Short then
		return ability.Short
	end
	local letters = {}
	for word in ability.Name:gmatch("%S+") do
		table.insert(letters, word:sub(1, 1):upper())
		if #letters == 2 then
			break
		end
	end
	return table.concat(letters)
end

local function keyText(keyCode)
	return keyCode and keyCode.Name or ""
end

function AbilityBar.new()
	local A = Config.Abilities
	if not A or not A.Enabled or not A.Characters or #A.Characters == 0 then
		return nil
	end
	local self = setmetatable({}, AbilityBar)
	self.Activated = Instance.new("BindableEvent") -- (characterId, slot, ability): hook the ability system here later
	self.CharacterChanged = Instance.new("BindableEvent") -- (characterId): the bar switched character
	self.CopiedUsed = Instance.new("BindableEvent") -- (characterId, slot): the copied move in a slot was used (Sharingan Copy)
	self.Temporary = {} -- slot -> a copied move sitting in it for a while
	self.Slots = {}
	self.Connections = {}
	self.UltCharge = Config.Abilities.UltCharge and 0 or 1
	self.Cooldowns = {} -- slot -> { Ends = os.clock() time, Total = seconds }

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild("AbilityBar")
	if old then
		old:Destroy()
	end
	local gui = make("ScreenGui", { Name = "AbilityBar", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 3 }, playerGui)
	self.Gui = gui

	-- the whole bar: character name on top, the 3 slots below
	local bar = make("Frame", {
		Name = "Bar", AnchorPoint = A.AnchorPoint or Vector2.new(0.5, 1), Position = A.Position, BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY,
	}, gui)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical, HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8),
	}, bar)
	self.Bar = bar

	-- character name + rarity badge (+ arrows to flip through characters while testing in Studio)
	local header = make("Frame", {
		Name = "Header", LayoutOrder = 1, BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X,
	}, bar)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8),
	}, header)
	local switcher = A.TestSwitcher and RunService:IsStudio() and #A.Characters > 1
	local function arrow(text, order, step)
		local b = make("TextButton", {
			Name = "Arrow", LayoutOrder = order, Size = UDim2.fromOffset(24, 24), AutoButtonColor = false,
			BackgroundColor3 = PANEL, BackgroundTransparency = 0.25, Font = Enum.Font.GothamBlack, TextSize = 12,
			TextColor3 = MUTED, Text = text,
		}, header)
		make("UICorner", { CornerRadius = UDim.new(1, 0) }, b)
		table.insert(self.Connections, b.Activated:Connect(function()
			self:Cycle(step)
		end))
	end
	if switcher then
		arrow("<", 1, -1)
	end
	self.NameLabel = make("TextLabel", {
		Name = "CharacterName", LayoutOrder = 2, BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 26),
		AutomaticSize = Enum.AutomaticSize.X, Font = Enum.Font.GothamBlack, TextSize = 20, TextColor3 = TEXT, Text = "",
	}, header)
	make("UIStroke", { Color = OUTLINE, Thickness = 2, Transparency = 0.2 }, self.NameLabel)
	self.NameGradient = make("UIGradient", { Rotation = 90 }, self.NameLabel)
	self.RarityBadge = make("TextLabel", {
		Name = "Rarity", LayoutOrder = 3, Size = UDim2.fromOffset(0, 18), AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBlack, TextSize = 11, TextColor3 = OUTLINE, Text = "",
	}, header)
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, self.RarityBadge)
	make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, self.RarityBadge)
	if switcher then
		arrow(">", 4, 1)
	end

	-- the 3 slots, lined up along the bottom so the bigger ultimate rises above the other two
	local row = make("Frame", {
		Name = "Slots", LayoutOrder = 2, BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY,
	}, bar)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Bottom,
		HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6),
	}, row)
	for order, slot in ipairs(SLOTS) do
		self:BuildSlot(row, slot, order)
	end

	-- hover tooltip: name, which key, what it does
	local tip = make("Frame", {
		Name = "Tooltip", AnchorPoint = Vector2.new(0, 1), BackgroundColor3 = PANEL, BackgroundTransparency = 0.08,
		Size = UDim2.fromOffset(250, 0), AutomaticSize = Enum.AutomaticSize.Y, Visible = false, ZIndex = 10,
	}, gui)
	make("UICorner", { CornerRadius = UDim.new(0, 10) }, tip)
	self.TipStroke = make("UIStroke", { Thickness = 1.5, Transparency = 0.3 }, tip)
	make("UIPadding", {
		PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12),
	}, tip)
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }, tip)
	self.TipTitle = make("TextLabel", {
		LayoutOrder = 1, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), Font = Enum.Font.GothamBlack, TextSize = 16,
		TextColor3 = TEXT, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 10, Text = "",
	}, tip)
	self.TipTag = make("TextLabel", {
		LayoutOrder = 2, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 14), Font = Enum.Font.GothamBold, TextSize = 11,
		TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 10, Text = "",
	}, tip)
	self.TipText = make("TextLabel", {
		LayoutOrder = 3, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = TEXT, TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 10, Text = "",
	}, tip)
	self.Tip = tip

	-- same size feel on any screen: scales with the screen height (Config.Abilities.UiScale)
	local barScale = make("UIScale", { Scale = 1 }, bar)
	local tipScale = make("UIScale", { Scale = 1 }, tip)
	local function fit()
		local S = A.UiScale or { RefHeight = 900, Min = 0.7, Max = 1.25 }
		local height = gui.AbsoluteSize.Y
		if height > 1 then
			local s = math.clamp(height / S.RefHeight, S.Min, S.Max)
			barScale.Scale, tipScale.Scale = s, s
		end
	end
	table.insert(self.Connections, gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit))
	fit()

	-- keys (UI only for now: just the press animation + the Activated event)
	table.insert(self.Connections, UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		for _, slot in ipairs(SLOTS) do
			if input.KeyCode == A.Keys[slot] then
				self:Press(slot)
			end
		end
	end))
	-- cooldown countdowns, and the ultimate glows softly while it's ready
	table.insert(self.Connections, RunService.RenderStepped:Connect(function()
		self:UpdateCooldowns()
		local ult = self.Slots.Ultimate
		if ult and ult.Glow then
			local ready = self.UltCharge >= 1 and not ult.CoolingDown
			ult.Glow.Transparency = ready and (0.35 + 0.35 * math.sin(os.clock() * 4)) or 1
		end
	end))

	local start = 1
	for i, character in ipairs(A.Characters) do
		if character.Id == A.DefaultCharacter then
			start = i
		end
	end
	self:SetCharacter(A.Characters[start].Id)
	return self
end

function AbilityBar:BuildSlot(parent, slot, order)
	local A = Config.Abilities
	local isUlt = slot == "Ultimate"
	local size = isUlt and A.UltSize or A.SlotSize
	local width = size + 30
	local holder = make("Frame", {
		Name = slot, LayoutOrder = order, BackgroundTransparency = 1, Size = UDim2.fromOffset(width, size + (isUlt and 44 or 34)),
	}, parent)

	-- "ULTIMATE" ribbon over the middle slot
	local ribbon
	if isUlt then
		ribbon = make("TextLabel", {
			Name = "Ribbon", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.fromOffset(0, 16),
			AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBlack, TextSize = 10,
			TextColor3 = OUTLINE, Text = "ULTIMATE", ZIndex = 4,
		}, holder)
		make("UICorner", { CornerRadius = UDim.new(1, 0) }, ribbon)
		make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, ribbon)
	end

	-- soft glow ring behind the ultimate (pulses while it's ready)
	local glow
	if isUlt then
		local ring = make("Frame", {
			Name = "Glow", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, -4), Size = UDim2.fromOffset(size + 8, size + 8),
			BackgroundTransparency = 1, ZIndex = 1,
		}, holder)
		make("UICorner", { CornerRadius = UDim.new(0, 22) }, ring)
		glow = make("UIStroke", { Thickness = 4, Transparency = 1 }, ring)
	end

	local button = make("TextButton", {
		Name = "Button", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.fromOffset(size, size),
		AutoButtonColor = false, Text = "", BackgroundColor3 = PANEL, BackgroundTransparency = 0.1, ZIndex = 2,
	}, holder)
	make("UICorner", { CornerRadius = UDim.new(0, isUlt and 18 or 14) }, button)
	local scale = make("UIScale", { Scale = 1 }, button)
	local stroke = make("UIStroke", { Thickness = isUlt and 3 or 2, Transparency = 0.15, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, button)
	local fill = make("UIGradient", { Rotation = 90 }, button) -- tinted top, dark bottom

	local icon = make("ImageLabel", {
		Name = "Icon", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.72, 0.72),
		BackgroundTransparency = 1, Image = "", Visible = false, ZIndex = 3,
	}, button)
	local glyph = make("TextLabel", {
		Name = "Glyph", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.8, 0.6),
		BackgroundTransparency = 1, Font = Enum.Font.GothamBlack, TextScaled = true, TextColor3 = Color3.new(1, 1, 1), Text = "", ZIndex = 3,
	}, button)
	make("UITextSizeConstraint", { MaxTextSize = isUlt and 34 or 24 }, glyph)
	local glyphStroke = make("UIStroke", { Color = OUTLINE, Thickness = 1.5, Transparency = 0.2 }, glyph)
	local glyphGradient = make("UIGradient", { Rotation = 90 }, glyph)

	-- cooldown: darkens from the top down as it counts, with the seconds left
	local cooldown = make("Frame", {
		Name = "Cooldown", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0),
		BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.35, BorderSizePixel = 0, Visible = false, ZIndex = 4,
	}, button)
	make("UICorner", { CornerRadius = UDim.new(0, isUlt and 18 or 14) }, cooldown)
	local cooldownText = make("TextLabel", {
		Name = "CooldownText", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Font = Enum.Font.GothamBlack,
		TextSize = isUlt and 30 or 22, TextColor3 = TEXT, Text = "", Visible = false, ZIndex = 5,
	}, button)
	make("UIStroke", { Color = OUTLINE, Thickness = 2.5 }, cooldownText)

	-- key badge in the top-left corner
	local key = make("TextLabel", {
		Name = "Key", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(4, 4), Size = UDim2.fromOffset(22, 22),
		BackgroundColor3 = OUTLINE, Font = Enum.Font.GothamBlack, TextSize = 12, TextColor3 = TEXT,
		Text = keyText(A.Keys[slot]), ZIndex = 6,
	}, button)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, key)
	local keyStroke = make("UIStroke", { Thickness = 1.5, Transparency = 0.2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, key)

	-- ultimate charge bar, just under the ultimate
	local chargeFill
	if isUlt then
		local back = make("Frame", {
			Name = "Charge", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, size + 5), Size = UDim2.fromOffset(size - 12, 5),
			BackgroundColor3 = OUTLINE, BackgroundTransparency = 0.2, BorderSizePixel = 0,
		}, holder)
		make("UICorner", { CornerRadius = UDim.new(1, 0) }, back)
		chargeFill = make("Frame", { Name = "Fill", Size = UDim2.fromScale(1, 1), BorderSizePixel = 0 }, back)
		make("UICorner", { CornerRadius = UDim.new(1, 0) }, chargeFill)
	end

	-- ability name under the slot
	local name = make("TextLabel", {
		Name = "AbilityName", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, 0), Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = isUlt and 13 or 12, TextColor3 = TEXT,
		TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Text = "",
	}, holder)
	make("UIStroke", { Color = OUTLINE, Thickness = 1.5, Transparency = 0.25 }, name)

	local info = {
		Button = button, Scale = scale, Stroke = stroke, Fill = fill, Icon = icon, Glyph = glyph, GlyphGradient = glyphGradient, GlyphStroke = glyphStroke,
		Cooldown = cooldown, CooldownText = cooldownText, Key = key, KeyStroke = keyStroke, Name = name,
		Ribbon = ribbon, Glow = glow, ChargeFill = chargeFill, IsUlt = isUlt,
	}
	self.Slots[slot] = info

	table.insert(self.Connections, button.Activated:Connect(function()
		self:Press(slot)
	end))
	table.insert(self.Connections, button.MouseEnter:Connect(function()
		TweenService:Create(scale, QUICK, { Scale = 1.06 }):Play()
		self:ShowTip(slot)
	end))
	table.insert(self.Connections, button.MouseLeave:Connect(function()
		TweenService:Create(scale, QUICK, { Scale = 1 }):Play()
		if self.TipSlot == slot then
			self.Tip.Visible = false
			self.TipSlot = nil
		end
	end))
end

function AbilityBar:GetCharacter(id)
	for i, character in ipairs(Config.Abilities.Characters) do
		if character.Id == id then
			return character, i
		end
	end
	return nil
end

-- shows a character's abilities on the bar
function AbilityBar:SetCharacter(id)
	local A = Config.Abilities
	local character = self:GetCharacter(id)
	if not character then
		warn("[AbilityBar] No character called " .. tostring(id) .. " in Config.Abilities.Characters")
		return
	end
	self.Character = character
	self.Cooldowns = {} -- a new character starts with everything ready
	self.Temporary = {}
	self.WaitingCopy = nil
	self.NoCooldownUntil = nil
	self.CharacterChanged:Fire(character.Id)
	self.UltSpentAt = nil
	if not Config.Abilities.UltCharge then
		self:SetUltCharge(1)
	end
	local accent = character.Color or Color3.fromRGB(120, 210, 255)
	local rarityColor = character.Rarity and A.Rarities[character.Rarity]

	self.NameLabel.Text = string.upper(character.Name)
	self.NameGradient.Color = ColorSequence.new(Color3.new(1, 1, 1), accent:Lerp(Color3.new(1, 1, 1), 0.25))
	self.RarityBadge.Visible = rarityColor ~= nil
	if rarityColor then
		self.RarityBadge.Text = string.upper(character.Rarity)
		self.RarityBadge.BackgroundColor3 = rarityColor
	end

	for _, slot in ipairs(SLOTS) do
		local info = self.Slots[slot]
		local ability = character[slot] or { Name = "?", Description = "" }
		local tint = (info.IsUlt and rarityColor) or accent -- the ultimate is framed in the rarity colour
		info.Stroke.Color = tint
		info.KeyStroke.Color = accent
		info.Fill.Color = ColorSequence.new(accent:Lerp(PANEL, 0.55), PANEL)
		info.GlyphGradient.Color = ColorSequence.new(Color3.new(1, 1, 1), accent)
		info.Glyph.Text = initials(ability)
		local hasIcon = ability.Icon ~= nil and ability.Icon ~= ""
		info.Icon.Image = hasIcon and ability.Icon or ""
		info.Icon.Visible = hasIcon
		info.Glyph.Visible = not hasIcon
		info.Name.Text = ability.Name
		if info.Ribbon then
			info.Ribbon.BackgroundColor3 = tint
		end
		if info.Glow then
			info.Glow.Color = tint
		end
		if info.ChargeFill then
			info.ChargeFill.BackgroundColor3 = tint
		end
		self:SetCooldown(slot, 0, 1)
	end
	if self.TipSlot then
		self:ShowTip(self.TipSlot)
	end
end

function AbilityBar:Cycle(step)
	local list = Config.Abilities.Characters
	local _, index = self:GetCharacter(self.Character and self.Character.Id)
	index = ((index or 1) - 1 + step) % #list + 1
	self:SetCharacter(list[index].Id)
end

function AbilityBar:ShowTip(slot)
	local character = self.Character
	local temp = self.Temporary and self.Temporary[slot]
	local ability = temp and temp.Ability or (character and character[slot])
	if not ability then
		return
	end
	local info = self.Slots[slot]
	local keyName = keyText(Config.Abilities.Keys[slot])
	self.TipSlot = slot
	self.TipTitle.Text = ability.Name
	self.TipTitle.TextColor3 = info.Stroke.Color
	self.TipTag.Text = (temp and "COPIED" or (info.IsUlt and "ULTIMATE" or "SKILL")) .. (keyName ~= "" and ("  ·  key " .. keyName) or "")
	self.TipText.Text = ability.Description or ""
	self.TipStroke.Color = info.Stroke.Color
	-- beside the bar (right side, or left if there's no room), lined up with its bottom: keeps the timer and track clear
	local barPos, barSize = self.Bar.AbsolutePosition, self.Bar.AbsoluteSize
	local guiSize = self.Gui.AbsoluteSize
	local tipWidth = self.Tip.AbsoluteSize.X > 0 and self.Tip.AbsoluteSize.X or 250
	if barPos.X + barSize.X + 12 + tipWidth <= guiSize.X then
		self.Tip.AnchorPoint = Vector2.new(0, 1)
		self.Tip.Position = UDim2.fromOffset(barPos.X + barSize.X + 12, barPos.Y + barSize.Y)
	else
		self.Tip.AnchorPoint = Vector2.new(1, 1)
		self.Tip.Position = UDim2.fromOffset(barPos.X - 12, barPos.Y + barSize.Y)
	end
	self.Tip.Visible = true
end

-- how long a slot's cooldown is: the ability's own Cooldown if it has one, otherwise Config.Abilities.Cooldowns
function AbilityBar:CooldownFor(slot)
	if slot == "Ultimate" and Config.Abilities.UltCharge then
		return 0 -- it charges up instead (UpdateCooldowns)
	end
	local ability = self.Character and self.Character[slot]
	local defaults = Config.Abilities.Cooldowns or {}
	return (ability and ability.Cooldown) or defaults[slot] or 0
end

function AbilityBar:StartCooldown(slot, seconds)
	if seconds and seconds > 0 then
		self.Cooldowns[slot] = { Ends = os.clock() + seconds, Total = seconds }
		self:UpdateCooldowns()
	end
end

-- counts the cooldowns down (every frame); a slot pops when it's ready again
function AbilityBar:UpdateCooldowns()
	local now = os.clock()
	-- a copied move waiting in a slot: the bar under the ultimate drains as its time runs out
	for slot, temp in pairs(self.Temporary or {}) do
		local remaining = temp.Ends - now
		if remaining <= 0 then
			self:ClearTemporary(slot) -- not used in time: gone, and the slot's cooldown starts
		elseif slot == "Ultimate" then
			self:SetUltCharge(remaining / temp.Total)
		end
	end
	if self.WaitingCopy and now - (self.WaitingCopyAt or now) > 3 then
		self:CopyFailed(self.WaitingCopy) -- no answer from the server
	end
	-- the ultimate's charge: the server's % (your UltCharge attribute)
	if Config.Abilities.UltCharge and not (self.Temporary and self.Temporary.Ultimate) then
		local pct = Players.LocalPlayer:GetAttribute("UltCharge") or 0
		if self.WaitingCopy == "Ultimate" or (self.UltSpentAt and now - self.UltSpentAt < 0.8 and pct >= 99) then
			pct = 0 -- just used: empty straight away (the server's 0 arrives a moment later)
		end
		self:ShowUltCharge(pct)
	end
	for slot, cd in pairs(self.Cooldowns) do
		local remaining = cd.Ends - now
		if remaining <= 0 then
			self.Cooldowns[slot] = nil
			self:SetCooldown(slot, 0, cd.Total)
			if slot == "Ultimate" then
				self:SetUltCharge(1)
			end
			self:ReadyPop(slot)
		else
			self:SetCooldown(slot, remaining, cd.Total)
			if slot == "Ultimate" then
				self:SetUltCharge(1 - remaining / cd.Total)
			end
		end
	end
end

-- ready again: a quick pop and a bright flash of the frame
function AbilityBar:ReadyPop(slot)
	local info = self.Slots[slot]
	if not info then
		return
	end
	info.Scale.Scale = 1.14
	TweenService:Create(info.Scale, POP, { Scale = 1 }):Play()
	info.Stroke.Transparency = 0
	TweenService:Create(info.Stroke, TweenInfo.new(0.5), { Transparency = 0.15 }):Play()
end

-- still cooling down: a little wiggle instead of a press
function AbilityBar:Deny(slot)
	local info = self.Slots[slot]
	if not info then
		return
	end
	local button = info.Button
	local step = TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local a = TweenService:Create(button, step, { Rotation = -7 })
	local b = TweenService:Create(button, step, { Rotation = 7 })
	local c = TweenService:Create(button, step, { Rotation = 0 })
	a.Completed:Once(function()
		b:Play()
	end)
	b.Completed:Once(function()
		c:Play()
	end)
	a:Play()
end

-- press: plays the press animation, starts the cooldown and fires Activated (for the ability system later).
-- While the slot is still cooling down it only wiggles.
function AbilityBar:Press(slot)
	local info = self.Slots[slot]
	if not info or not self.Character then
		return
	end
	-- stunned (hit by a Rasen Shuriken...): no abilities until it wears off
	if self.IsLocked and self.IsLocked() then
		self:Deny(slot)
		return
	end
	if self.Cooldowns[slot] then
		self:Deny(slot)
		return
	end
	-- the ultimate needs to be fully charged (unless a copied move is sitting in the slot)
	if slot == "Ultimate" and Config.Abilities.UltCharge and not (self.Temporary and self.Temporary.Ultimate) and self.UltCharge < 1 then
		self:Deny(slot)
		return
	end
	-- still using another ability (its animation): wait for it to finish (Abilities.BusyTime)
	if os.clock() < (self.BusyUntil or 0) or self.WaitingCopy == slot then
		self:Deny(slot)
		return
	end
	local down = TweenService:Create(info.Scale, QUICK, { Scale = 0.86 })
	down.Completed:Once(function()
		TweenService:Create(info.Scale, POP, { Scale = 1 }):Play()
	end)
	down:Play()
	info.Stroke.Transparency = 0
	TweenService:Create(info.Stroke, TweenInfo.new(0.35), { Transparency = 0.15 }):Play()
	-- a copied move sitting in the slot (Sharingan Copy): use it, and the slot goes back (and starts its cooldown)
	local temp = self.Temporary and self.Temporary[slot]
	if temp then
		self:ClearTemporary(slot)
		self.BusyUntil = os.clock() + Abilities.BusyTime(temp.CharacterId, temp.Slot)
		self.CopiedUsed:Fire(temp.CharacterId, temp.Slot)
		return
	end
	local ability = self.Character[slot]
	if ability and ability.Copy then
		-- Sharingan Copy: no cooldown yet; it starts once the copied move is used (or runs out)
		self.WaitingCopy = slot
		self.WaitingCopyAt = os.clock()
	elseif slot ~= "Ultimate" and os.clock() < (self.NoCooldownUntil or 0) then
		-- 500 IQ: no cooldowns on the skills right now
	else
		self:StartCooldown(slot, self:CooldownFor(slot))
	end
	if slot == "Ultimate" then
		self.UltSpentAt = os.clock()
	end
	self.BusyUntil = os.clock() + Abilities.BusyTime(self.Character.Id, slot)
	self.Activated:Fire(self.Character.Id, slot, self.Character[slot])
end

-- shows `ability` in a slot (`accent` colours it; the frame is drawn in `tint`)
function AbilityBar:ShowAbility(slot, ability, accent, tint)
	local info = self.Slots[slot]
	if not info then
		return
	end
	ability = ability or { Name = "?", Description = "" }
	tint = tint or accent
	info.Stroke.Color = tint
	info.KeyStroke.Color = accent
	info.Fill.Color = ColorSequence.new(accent:Lerp(PANEL, 0.55), PANEL)
	info.GlyphGradient.Color = ColorSequence.new(Color3.new(1, 1, 1), accent)
	info.Glyph.Text = initials(ability)
	local hasIcon = ability.Icon ~= nil and ability.Icon ~= ""
	info.Icon.Image = hasIcon and ability.Icon or ""
	info.Icon.Visible = hasIcon
	info.Glyph.Visible = not hasIcon
	info.Name.Text = ability.Name
	if info.Ribbon then
		info.Ribbon.BackgroundColor3 = tint
	end
	if info.Glow then
		info.Glow.Color = tint
	end
	if info.ChargeFill then
		info.ChargeFill.BackgroundColor3 = tint
	end
end

-- a copied move sitting in a slot for `seconds` (Sharingan Copy): pressing the slot uses it (CopiedUsed); used or run
-- out, the slot goes back to its own ability and starts its cooldown
function AbilityBar:SetTemporary(slot, characterId, abilitySlot, seconds)
	local owner = self:GetCharacter(characterId)
	local ability = owner and owner[abilitySlot]
	if not (ability and self.Slots[slot]) then
		self:CopyFailed(slot)
		return
	end
	self.WaitingCopy = nil
	self.Temporary[slot] = { CharacterId = characterId, Slot = abilitySlot, Ability = ability, Ends = os.clock() + seconds, Total = seconds }
	self.Cooldowns[slot] = nil
	self:SetCooldown(slot, 0, 1)
	local accent = owner.Color or Color3.fromRGB(120, 210, 255)
	self:ShowAbility(slot, ability, accent, accent)
	if slot == "Ultimate" then
		self:SetUltCharge(1)
	end
	self:ReadyPop(slot)
	if self.TipSlot == slot then
		self:ShowTip(slot)
	end
end

function AbilityBar:ClearTemporary(slot)
	if not (self.Temporary and self.Temporary[slot]) then
		return
	end
	self.Temporary[slot] = nil
	local character = self.Character
	local accent = character.Color or Color3.fromRGB(120, 210, 255)
	local rarityColor = character.Rarity and Config.Abilities.Rarities[character.Rarity]
	self:ShowAbility(slot, character[slot], accent, (self.Slots[slot].IsUlt and rarityColor) or accent)
	self:StartCooldown(slot, self:CooldownFor(slot))
	if self.TipSlot == slot then
		self:ShowTip(slot)
	end
end

-- 500 IQ: no cooldowns on the skills until `untilClock` (an os.clock() time); the ones running now end straight away
function AbilityBar:SetNoCooldowns(untilClock)
	self.NoCooldownUntil = untilClock
	for _, slot in ipairs({ "Skill1", "Skill2" }) do
		if self.Cooldowns[slot] then
			self.Cooldowns[slot] = nil
			self:SetCooldown(slot, 0, 1)
			self:ReadyPop(slot)
		end
	end
end

-- Sharingan Copy found nobody to copy: the slot just goes on cooldown
function AbilityBar:CopyFailed(slot)
	if self.WaitingCopy == slot then
		self.WaitingCopy = nil
	end
	self:StartCooldown(slot, self:CooldownFor(slot))
end

-- for the ability system later: remaining seconds of a slot's cooldown (0 = ready)
function AbilityBar:SetCooldown(slot, remaining, total, text)
	local info = self.Slots[slot]
	if not info then
		return
	end
	local cooling = remaining > 0
	if cooling ~= info.CoolingDown then
		-- fade the letters / icon while cooling down so the countdown is easy to read
		info.Glyph.TextTransparency = cooling and 0.75 or 0
		info.GlyphStroke.Transparency = cooling and 0.85 or 0.2
		info.Icon.ImageTransparency = cooling and 0.6 or 0
	end
	info.CoolingDown = cooling
	info.Cooldown.Visible = cooling
	info.CooldownText.Visible = cooling
	if cooling then
		info.Cooldown.Size = UDim2.fromScale(1, math.clamp(remaining / math.max(total or remaining, 0.01), 0, 1))
		info.CooldownText.Text = text or (remaining >= 10 and tostring(math.ceil(remaining)) or string.format("%.1f", remaining))
	end
end

-- for the ability system later: how charged the ultimate is (0-1). Full = ready (glows)
function AbilityBar:SetUltCharge(charge)
	self.UltCharge = math.clamp(charge, 0, 1)
	local info = self.Slots.Ultimate
	if info and info.ChargeFill then
		info.ChargeFill.Size = UDim2.fromScale(self.UltCharge, 1)
	end
end

-- the ultimate's charge as a % (0-100): darkened with the % on it while it charges, pops and glows at 100%
function AbilityBar:ShowUltCharge(pct)
	local charge = math.clamp(pct / 100, 0, 1)
	self:SetUltCharge(charge)
	if charge >= 1 then
		self:SetCooldown("Ultimate", 0, 1)
		if not self.UltWasFull then
			self.UltWasFull = true
			self:ReadyPop("Ultimate")
		end
	else
		self.UltWasFull = false
		self:SetCooldown("Ultimate", 1 - charge, 1, math.floor(pct) .. "%")
	end
end

-- how far the top of the bar is from the bottom of the screen (pixels), as it's drawn (after the screen-size scaling)
function AbilityBar:TopFromBottom()
	local screenHeight = self.Gui.AbsoluteSize.Y
	local position, anchor = self.Bar.Position, self.Bar.AnchorPoint
	local anchorY = screenHeight * position.Y.Scale + position.Y.Offset
	local top = anchorY - self.Bar.AbsoluteSize.Y * anchor.Y
	return screenHeight - top
end

function AbilityBar:Destroy()
	for _, c in ipairs(self.Connections) do
		c:Disconnect()
	end
	self.Activated:Destroy()
	self.CopiedUsed:Destroy()
	self.CharacterChanged:Destroy()
	self.Gui:Destroy()
end

return AbilityBar
