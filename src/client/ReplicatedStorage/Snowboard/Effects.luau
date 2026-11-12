--[[
	Effects (client): snow spray off the tail of the board and carve lines in the snow.
	Spray grows with speed, carving and braking; both only show while the board is on the snow.
	The board tester can pass the part to put them on (for swapped boards); otherwise the LuffyBoard is used.
]]

local Effects = {}
Effects.__index = Effects

local SMOKE = "rbxasset://textures/particles/smoke_main.dds"

local function findBoard(character)
	local torso = character:FindFirstChild("Torso")
	if torso then
		for _, c in ipairs(torso:GetChildren()) do
			if c:IsA("BasePart") and (c.Name == "LuffyBoard" or c.Name == "Board") then
				return c
			end
		end
	end
	return nil
end

function Effects.new(character, boardPart)
	local self = setmetatable({}, Effects)
	local board = boardPart or findBoard(character)
	self.Board = board
	self.Made = {} -- everything added to the board, removed again in Destroy (board swaps)
	if not board then
		return self
	end
	-- the board's long side is its X axis; +X is the tail
	local half = board.Size.X / 2
	local bottom = -board.Size.Y / 2 -- underside of the board
	local tail = Instance.new("Attachment")
	tail.Name = "SnowSpray"
	tail.Position = Vector3.new(half - 0.6, bottom - 0.015, 0)
	tail.Parent = board
	table.insert(self.Made, tail)

	local spray = Instance.new("ParticleEmitter")
	spray.Name = "SnowSpray"
	spray.Texture = SMOKE
	spray.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(210, 228, 245))
	spray.LightEmission = 0.25
	spray.LightInfluence = 0.6
	spray.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 2.6) })
	spray.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) })
	spray.Lifetime = NumberRange.new(0.35, 0.75)
	spray.Speed = NumberRange.new(6, 14)
	spray.SpreadAngle = Vector2.new(35, 35)
	spray.EmissionDirection = Enum.NormalId.Right -- backwards off the tail
	spray.Acceleration = Vector3.new(0, -25, 0)
	spray.Drag = 2
	spray.Rotation = NumberRange.new(0, 360)
	spray.RotSpeed = NumberRange.new(-90, 90)
	spray.Rate = 0
	spray.Parent = tail
	self.Spray = spray

	local a0 = Instance.new("Attachment")
	a0.Name = "CarveA"
	a0.Position = Vector3.new(half - 1.2, bottom + 0.005, 0.75)
	a0.Parent = board
	local a1 = Instance.new("Attachment")
	a1.Name = "CarveB"
	a1.Position = Vector3.new(half - 1.2, bottom + 0.005, -0.75)
	a1.Parent = board
	table.insert(self.Made, a0)
	table.insert(self.Made, a1)
	local trail = Instance.new("Trail")
	trail.Name = "CarveTrail"
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Color = ColorSequence.new(Color3.fromRGB(236, 242, 250))
	trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
	trail.Lifetime = 1.4
	trail.MinLength = 0.3
	trail.LightInfluence = 0.8
	trail.Enabled = false
	trail.Parent = board
	table.insert(self.Made, trail)
	self.Trail = trail
	return self
end

function Effects:Update(controller)
	if not self.Spray then
		return
	end
	local speed = controller.Speed
	local onSnow = controller.Grounded and speed > 12
	if onSnow then
		local carve = math.abs(controller.Steer)
		self.Spray.Rate = speed * 0.35 * (0.3 + carve * 1.7) + controller.Brake * 70
	else
		self.Spray.Rate = 0
	end
	self.Trail.Enabled = onSnow
end

function Effects:Destroy()
	if self.Spray then
		self.Spray.Rate = 0
	end
	for _, obj in ipairs(self.Made) do
		obj:Destroy()
	end
	self.Made = {}
	self.Spray = nil
end

return Effects
