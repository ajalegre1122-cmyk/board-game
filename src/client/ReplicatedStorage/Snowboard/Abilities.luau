--[[
	Abilities (client): what each ability actually DOES to your ride (the gameplay side).
	AbilityVFX plays how it looks (effects + animation); this module plays what it does. Both run when you press
	a slot: SnowboardClient hooks them up to the ability bar.

	Working so far
	  Deku  Skill1  Jump Boost: launches you JumpHeight x as high as a normal jump (Config.Abilities > Deku > Skill1),
	                at the push-off in his Jump animation (Config.AbilityVFX.Timings.JumpPushOff), when the leap burst fires.
	                The board physics side is Controller:SuperJump.
	  Deku  Skill2  One For All Dash: a burst of DashSpeed extra speed for DashTime seconds (Config.Abilities > Deku >
	                Skill2; easing in Config.Dash), at the push in his dash animation (AbilityVFX.Timings.DashPush).
	                The board physics side is Controller:Dash.
	  Deku  Ultimate  Speed Boost: you ride SpeedMultiplier x as fast for Duration seconds (Config.Abilities > Deku >
	                Ultimate; easing in / out in Config.SpeedBoost). The board physics side is Controller:SpeedBoost.
	  Dio   Skill1  Time Skip: a DashSpeed burst for DashTime seconds that snaps in / out (DashRampIn / DashFadeOut).
	Everything else: effects only for now.

	API
	  Abilities.new()
	  abilities:Use(characterId, slot, rider)   rider = SnowboardClient's current rider { Controller, Character, ... }
	  Abilities.BusyTime(characterId, slot)     seconds using this ability locks the other slots (the ability bar and
	                                            the server both use it)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(script.Parent:WaitForChild("Config"))

local Abilities = {}
Abilities.__index = Abilities

-- the ability's entry in Config.Abilities (Name, Duration, JumpHeight...)
local function findAbility(characterId, slot)
	local A = Config.Abilities
	for _, character in ipairs(A and A.Characters or {}) do
		if character.Id == characterId then
			return character[slot]
		end
	end
	return nil
end

-- shared with the effects, so the gameplay lands on the same beat as the animation
local function timing(name, default)
	local V = Config.AbilityVFX
	return V and V.Timings and V.Timings[name] or default
end

-- still riding (not respawned, not dead) a moment later?
local function riding(rider)
	local c = rider and rider.Controller
	return c ~= nil and c.Root ~= nil and c.Root.Parent ~= nil and c.Humanoid ~= nil and c.Humanoid.Health > 0
end

-- an ability animation's length (from its saved animation) and whether it's saved as a loop
local lengths = {}
local function animationLength(animName)
	local known = lengths[animName]
	if known then
		return known.Length, known.Looped
	end
	local V = Config.AbilityVFX or {}
	local assets = ReplicatedStorage:FindFirstChild("BoardAssets")
	local rigs = assets and assets:FindFirstChild("Rigs")
	local rig = rigs and rigs:FindFirstChild(V.AnimationRig or "AbilitiesBoard")
	local saves = rig and rig:FindFirstChild("AnimSaves")
	local kfs = saves and saves:FindFirstChild(animName)
	local length = 0
	if kfs then
		for _, kf in ipairs(kfs:GetChildren()) do
			if kf:IsA("Keyframe") then
				length = math.max(length, kf.Time)
			end
		end
	end
	lengths[animName] = { Length = length, Looped = kfs ~= nil and kfs.Loop }
	return length, kfs ~= nil and kfs.Loop
end

-- while an ability is being used (its animation is playing), the other slots are locked: no spamming skills back to
-- back. How long: the ability's BusyTime if it has one, else its animation's length (a looping one, like Chidori's
-- charge, for its Duration), else Config.Abilities.Busy.NoAnimation. Lasting effects don't count (Speed Boost's 7 s,
-- auras...): only the move itself.
function Abilities.BusyTime(characterId, slot)
	local ability = findAbility(characterId, slot)
	if not ability then
		return 0
	end
	if ability.BusyTime then
		return ability.BusyTime
	end
	local B = (Config.Abilities and Config.Abilities.Busy) or {}
	if ability.Anim then
		local length, looped = animationLength(ability.Anim)
		if looped and ability.Duration then
			length = ability.Duration
		end
		if length > 0 then
			return length + (B.Extra or 0)
		end
	end
	return B.NoAnimation or 0.3
end

local HANDLERS = {
	Naruto = {
		-- Chakra Mode: a speed boost for a few seconds (no animation)
		Skill1 = function(_, ability, rider)
			rider.Controller:SpeedBoost(ability.SpeedMultiplier or 1.5, ability.Duration or 3)
		end,
		-- Kunai Throw / Rasen Shuriken hit other riders: the server works that out (AbilityServer, Config.Hits)
	},
	Sasuke = {
		-- Chidori: a speed boost while the lightning's out (touching someone stuns them: the server checks that)
		Skill1 = function(_, ability, rider)
			rider.Controller:SpeedBoost(ability.SpeedMultiplier or 1.5, ability.Duration or 2)
		end,
		-- Sharingan Copy: a little speed boost when you use it (the copied move comes back from the server; Sharingan's
		-- dodging is server-side)
		Ultimate = function(_, ability, rider)
			rider.Controller:SpeedBoost(ability.SpeedMultiplier or 1.2, ability.SpeedTime or 5)
		end,
	},
	Deku = {
		-- Jump Boost: a really high jump, launched when Deku pushes off in the Jump animation
		Skill1 = function(_, ability, rider)
			task.delay(ability.LaunchDelay or timing("JumpPushOff", 0.4), function()
				if riding(rider) then
					rider.Controller:SuperJump(ability.JumpHeight or 10)
				end
			end)
		end,
		-- One For All Dash: a quick burst forward, at the push in his dash animation
		Skill2 = function(_, ability, rider)
			task.delay(ability.LaunchDelay or timing("DashPush", 0.1), function()
				if riding(rider) then
					rider.Controller:Dash(ability.DashSpeed or 70, ability.DashTime or 0.3)
				end
			end)
		end,
		-- Speed Boost: double speed for a while, straight away (no animation)
		Ultimate = function(_, ability, rider)
			rider.Controller:SpeedBoost(ability.SpeedMultiplier or 2, ability.Duration or 5)
		end,
	},
	Dio = {
		-- Time Skip: a huge burst forward that snaps in and out (you're invisible while it happens: AbilityVFX), straight away
		Skill1 = function(_, ability, rider)
			rider.Controller:Dash(ability.DashSpeed or 250, ability.DashTime or 0.14, ability.DashRampIn or 0.02, ability.DashFadeOut or 0.12, true) -- (a blink: uncapped)
		end,
		-- Knives (stun whoever they hit) and Za Warudo (freezes everyone else) are the server's call: AbilityServer
	},
}

function Abilities.new()
	return setmetatable({}, Abilities)
end

-- does this ability do anything yet (besides its effects)?
function Abilities:Has(characterId, slot)
	return HANDLERS[characterId] ~= nil and HANDLERS[characterId][slot] ~= nil
end

function Abilities:Use(characterId, slot, rider)
	local handler = HANDLERS[characterId] and HANDLERS[characterId][slot]
	local ability = findAbility(characterId, slot)
	if not handler or not ability or not riding(rider) then
		return false
	end
	local ok, err = pcall(handler, self, ability, rider)
	if not ok then
		warn(("[Abilities] %s %s: %s"):format(characterId, slot, tostring(err)))
	end
	return ok
end

return Abilities
