--[[
	SnowboardServer: sets up each rider.
	  - dresses the R6 snowboard character (StarterPlayer.StarterCharacter) in the player's own avatar
	  - puts the body parts in a collision group that ignores the world, so only the root part hits
	    walls and the board glides cleanly (the movement itself runs on the player's client)
]]

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")

local BODY_GROUP = "SnowboardRiderBody"
PhysicsService:RegisterCollisionGroup(BODY_GROUP)
PhysicsService:CollisionGroupSetCollidable(BODY_GROUP, "Default", false)
PhysicsService:CollisionGroupSetCollidable(BODY_GROUP, BODY_GROUP, false)

local function setupCharacter(player, character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not humanoid or not root then
		return
	end
	-- the player's look on the R6 rider (the board isn't a body part, so it stays)
	task.spawn(function()
		local ok, description = pcall(function()
			return Players:GetHumanoidDescriptionFromUserId(math.max(1, player.UserId))
		end)
		if ok and description and character.Parent then
			pcall(function()
				humanoid:ApplyDescription(description)
			end)
		end
	end)
	local function sort(part)
		if part:IsA("BasePart") and part ~= root then
			part.CollisionGroup = BODY_GROUP
		end
	end
	for _, d in ipairs(character:GetDescendants()) do
		sort(d)
	end
	character.DescendantAdded:Connect(sort)
end

local function onPlayer(player)
	player.CharacterAdded:Connect(function(character)
		setupCharacter(player, character)
	end)
	if player.Character then
		setupCharacter(player, player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayer)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayer(player)
end
