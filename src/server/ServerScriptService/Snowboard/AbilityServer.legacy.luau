-- AbilityServer
-- Handles ability requests, cooldowns, targeting, and server-side effects.
-- Set the script's Log attribute to true to debug accepted and rejected requests.
-- Connected Discord-GitHub
-- By ZevinSero (chosen9122)Yumi



local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Snowboard = ReplicatedStorage:WaitForChild("Snowboard")
local Config = require(Snowboard:WaitForChild("Config"))
local Abilities = require(Snowboard:WaitForChild("Abilities"))
local abilityRemote = Snowboard:WaitForChild("AbilityRemote")

local abilityConfig = Config.Abilities
local networkConfig = (abilityConfig and abilityConfig.Network) or {}
local validSlots = { Skill1 = true, Skill2 = true, Ultimate = true }

local lastAbilityUse = {} -- player -> slot -> os.clock() of the last accepted use
local messageBudget = {} -- player -> { Tokens, At }: how many messages they can still send right now
local abilityBusyUntil = {} -- player -> os.clock() when their current ability's move is over

local function debugLog(...)
	if script:GetAttribute("Log") then
		print("[AbilityServer]", ...)
	end
end

local function findCharacter(id)
	for _, character in ipairs(abilityConfig.Characters or {}) do
		if character.Id == id then
			return character
		end
	end
	return nil
end

-- Rate limit ability requests per player.
local function allowMessage(player)
	local now = os.clock()
	local bucket = messageBudget[player]
	if not bucket then
		bucket = { Tokens = networkConfig.Burst or 6, At = now }
		messageBudget[player] = bucket
	end
	bucket.Tokens = math.min(networkConfig.Burst or 6, bucket.Tokens + (now - bucket.At) * (networkConfig.PerSecond or 3))
	bucket.At = now
	if bucket.Tokens < 1 then
		return false
	end
	bucket.Tokens -= 1
	return true
end

local function isAlive(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0 and character:FindFirstChild("HumanoidRootPart") ~= nil
end


-- Targeting and hit detection
-- The server picks projectile targets and verifies hits.
local effectsConfig = Config.AbilityVFX or {}
local hitConfig = Config.Hits or {}
local stunExpiresAt = {} -- player -> os.clock() when their stun wears off (no abilities until then)
local dodgeExpiresAt = {} -- player -> os.clock() when their Sharingan dodge runs out
local freeSkillsUntil = {} -- player -> os.clock(): 500 IQ, no cooldowns on their skills until then
local lastBasicSlot = {} -- player -> their last used basic move (Skill1 / Skill2), for Sharingan Copy
local freezeExpiresAt = {} -- player -> os.clock() when time moves again for them (someone's Za Warudo)
local anchoredDummies = {} -- frozen dummy's root -> os.clock() when it's let go

local function isFrozen(player)
	return freezeExpiresAt[player] ~= nil and os.clock() < freezeExpiresAt[player]
end


-- Ultimate charge
local ultimateConfig = abilityConfig and abilityConfig.UltCharge
local ultimateCharge = {} -- player -> 0-100
local chargePausedUntil = {} -- player -> os.clock(): no charging until then (their own ultimate is still going)

local function setCharge(player, value)
	value = math.clamp(value, 0, 100)
	ultimateCharge[player] = value
	player:SetAttribute("UltCharge", math.floor(value * 10 + 0.5) / 10)
end

-- Pause ability timing when this player is frozen.
local function waitOwnTime(player, seconds)
	local left = seconds or 0
	while left > 0 do
		local dt = task.wait()
		if not isFrozen(player) then
			left -= dt
		end
	end
end

local targets = {} -- models with a Humanoid (riders, dummies), kept up to date as they come and go
local function trackTargets()
	local function added(d)
		if d:IsA("Humanoid") and d.Parent and d.Parent:IsA("Model") then
			targets[d.Parent] = true
		end
	end
	workspace.DescendantAdded:Connect(added)
	workspace.DescendantRemoving:Connect(function(d)
		if d:IsA("Humanoid") and d.Parent then
			targets[d.Parent] = nil
		end
	end)
	for _, d in ipairs(workspace:GetDescendants()) do
		added(d)
	end
end

-- Find the nearest valid target inside the aim cone.
local function findClosestTarget(character, range, ahead)
	local myRoot = character:FindFirstChild("HumanoidRootPart")
	if not myRoot then
		return nil
	end
	local v = myRoot.AssemblyLinearVelocity
	local forward = v.Magnitude > 5 and v.Unit or myRoot.CFrame.LookVector
	local cone = math.cos(math.rad(effectsConfig.AimCone or 70))
	local best, bestDistance
	local function consider(model)
		if not model or not model.Parent or model == character or model:IsDescendantOf(character) then
			return
		end
		if CollectionService:HasTag(model, "IgnoreAbilities") then
			return
		end
		local parentModel = model.Parent:IsA("Model") and model.Parent
		if parentModel and parentModel:FindFirstChildOfClass("Humanoid") then
			return -- a board rig on someone: aim at the someone
		end
		local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
		if not (root and root:IsA("BasePart") and root:IsDescendantOf(workspace)) then
			return
		end
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health <= 0 then
			return
		end
		local offset = root.Position - myRoot.Position
		local distance = offset.Magnitude
		if distance > range then
			return
		end
		if ahead and distance > 1 and offset.Unit:Dot(forward) < cone then
			return
		end
		if not bestDistance or distance < bestDistance then
			best, bestDistance = root, distance
		end
	end
	for model in pairs(targets) do
		consider(model)
	end
	for _, model in ipairs(CollectionService:GetTagged("AbilityTarget")) do
		consider(model)
	end
	return best
end

local function applyHit(model, kind, attacker, fromSlot)
	local hit = hitConfig[kind]
	if not hit then
		return
	end
	local victim = Players:GetPlayerFromCharacter(model)
	local dodge = victim and dodgeExpiresAt[victim] -- Sharingan: basic moves (or everything) miss
	if dodge and os.clock() < dodge.Until and not (dodge.BaseOnly and fromSlot == "Ultimate") then
		debugLog(model.Name, "dodged", kind, "from", attacker.Name)
		abilityRemote:FireAllClients("Dodged", model, attacker)
		return
	end
	if victim then
		local from = math.max(os.clock(), freezeExpiresAt[victim] or 0) -- hit while frozen: the stun starts when time moves again
		stunExpiresAt[victim] = math.max(stunExpiresAt[victim] or 0, from + (hit.StunTime or 0))
	end
	debugLog(attacker.Name, "hit", model.Name, "with", kind)
	abilityRemote:FireAllClients("Hit", model, kind, attacker)
end

-- Move a projectile toward its target, checking for a hit.
local function launchProjectile(player, ability, fromSlot)
	local spec = ability.Hit
	waitOwnTime(player, (effectsConfig.Timings and effectsConfig.Timings[spec.Release]) or 0)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and isAlive(player)) then
		return
	end
	if stunExpiresAt[player] and os.clock() < stunExpiresAt[player] then
		return -- stunned mid-launchProjectile: it doesn't come out
	end
	local target = findClosestTarget(character, effectsConfig.TargetRange or 160, spec.Ahead ~= false)
	if not target then
		return debugLog(player.Name, "threw", spec.Kind, "at nobody")
	end
	local speed = (effectsConfig[spec.Speed] or 150) + root.AssemblyLinearVelocity.Magnitude
	local pos = root.Position + Vector3.new(0, spec.Height or 1.5, 0)
	local maxFlight = (effectsConfig.ThrowRange or 140) * 1.6
	local radius = spec.Radius or 2
	local flown = 0
	while flown < maxFlight do
		local dt = task.wait()
		if not target:IsDescendantOf(workspace) then
			return
		end
		if isFrozen(player) then
			continue -- thrown before someone's Za Warudo: it hangs in the air until time moves again
		end
		local to = target.Position - pos
		local step = speed * dt
		if to.Magnitude <= step + radius then
			local model = target.Parent
			local humanoid = model and model:FindFirstChildOfClass("Humanoid")
			if model and (not humanoid or humanoid.Health > 0) then
				applyHit(model, spec.Kind, player, fromSlot)
			end
			return
		end
		pos += to.Unit * step
		flown += step
	end
end

-- Deal touch damage once per target during the skill.
local function handleTouchAttack(player, ability, characterId, slot)
	local spec = ability.Touch
	local done = {}
	local endsAt = os.clock() + (ability.Duration or 2)
	local function ended(hit) -- tell everyone it's over (hit = the strike; otherwise it fizzled)
		abilityRemote:FireAllClients("Ended", player, characterId, slot, hit)
	end
	while os.clock() < endsAt do
		local dt = task.wait(0.05)
		if isFrozen(player) then
			endsAt += dt -- frozen mid-Chidori: it waits with you
			continue
		end
		if not isAlive(player) or (stunExpiresAt[player] and os.clock() < stunExpiresAt[player]) then
			ended(false) -- knocked out of it
			return
		end
		local character = player.Character
		local root = character.HumanoidRootPart
		for model in pairs(targets) do
			if not done[model] and model ~= character and model.Parent then
				local r = model:FindFirstChild("HumanoidRootPart")
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				if r and (not humanoid or humanoid.Health > 0) and not CollectionService:HasTag(model, "IgnoreAbilities")
					and (r.Position - root.Position).Magnitude <= (spec.Radius or 7) then
					done[model] = true
					applyHit(model, spec.Kind, player, slot)
					if spec.EndOnHit then
						abilityBusyUntil[player] = os.clock() + 0.2 -- the move is over: the other slots free up again
						ended(true)
						return
					end
				end
			end
		end
	end
end

-- Swap positions with the closest valid target.
local function swapPlaces(player, ability)
	local spec = ability.Swap
	waitOwnTime(player, (effectsConfig.Timings and effectsConfig.Timings[spec.Release or "Clap"]) or 0.28)
	if not isAlive(player) or (stunExpiresAt[player] and os.clock() < stunExpiresAt[player]) then
		return
	end
	local character = player.Character
	local root = character.HumanoidRootPart
	local best, bestRoot, bestDistance
	for model in pairs(targets) do
		if model ~= character and model.Parent and not CollectionService:HasTag(model, "IgnoreAbilities") then
			local r = model:FindFirstChild("HumanoidRootPart")
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			local parentModel = model.Parent:IsA("Model") and model.Parent
			if r and r:IsDescendantOf(workspace) and (not humanoid or humanoid.Health > 0)
				and not (parentModel and parentModel:FindFirstChildOfClass("Humanoid")) then
				local d = (r.Position - root.Position).Magnitude
				if d <= (spec.Range or 60) and (not bestDistance or d < bestDistance) then
					best, bestRoot, bestDistance = model, r, d
				end
			end
		end
	end
	if not best then
		return debugLog(player.Name, "Boogie Woogie: nobody in range")
	end
	local mine, theirs = root.CFrame, bestRoot.CFrame
	local myNew = CFrame.new(theirs.Position) * mine.Rotation -- each keeps facing their own way: only the places swap
	local theirNew = CFrame.new(mine.Position) * theirs.Rotation
	local other = Players:GetPlayerFromCharacter(best)
	abilityRemote:FireClient(player, "Teleport", myNew)
	if other then
		abilityRemote:FireClient(other, "Teleport", theirNew)
	else
		local offset = theirs:ToObjectSpace(best:GetPivot())
		best:PivotTo(theirNew * offset)
	end
	debugLog(player.Name, "swapped places with", best.Name, string.format("(%.0f studs)", bestDistance))
	abilityRemote:FireAllClients("Swapped", player, best)
end

-- Freeze nearby players and NPCs for the skill duration.
local function freezeTime(player, ability)
	local spec = ability.Freeze
	waitOwnTime(player, (effectsConfig.Timings and effectsConfig.Timings[spec.Release or "ZaWarudo"]) or 0.55)
	if not isAlive(player) or (stunExpiresAt[player] and os.clock() < stunExpiresAt[player]) then
		return
	end
	local character = player.Character
	local root = character.HumanoidRootPart
	local duration = ability.Duration or 5
	local range = spec.Range or 0
	local untilTime = os.clock() + duration
	local frozen = {}
	for model in pairs(targets) do
		if model ~= character and model.Parent and not CollectionService:HasTag(model, "IgnoreAbilities") then
			local r = model:FindFirstChild("HumanoidRootPart")
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			local parentModel = model.Parent:IsA("Model") and model.Parent
			if r and r:IsA("BasePart") and r:IsDescendantOf(workspace) and (not humanoid or humanoid.Health > 0)
				and not (parentModel and parentModel:FindFirstChildOfClass("Humanoid"))
				and (range <= 0 or (r.Position - root.Position).Magnitude <= range) then
				table.insert(frozen, model)
				local victim = Players:GetPlayerFromCharacter(model)
				if victim then
					freezeExpiresAt[victim] = math.max(freezeExpiresAt[victim] or 0, untilTime)
				elseif not r.Anchored or anchoredDummies[r] then
					-- a dummy / NPC: held in place here until it's over
					anchoredDummies[r] = math.max(anchoredDummies[r] or 0, untilTime)
					r.Anchored = true
					task.delay(duration + 0.05, function()
						if anchoredDummies[r] and os.clock() >= anchoredDummies[r] then
							anchoredDummies[r] = nil
							if r.Parent then
								r.Anchored = false
							end
						end
					end)
				end
			end
		end
	end
	debugLog(player.Name, "Za Warudo froze", #frozen, "for", duration, "s")
	abilityRemote:FireAllClients("Frozen", player, frozen, duration)
end

local runServerEffects -- (defined below: Copy uses it for the copied move)

-- Copy a nearby player's basic skill for a short time.
local activeCopies = {} -- player -> { Id, Slot, Ability, Expires, FromSlot }
local previousCopy = {} -- player -> "Character/Slot" they copied last
local function prepareCopiedMove(player, ability, fromSlot)
	local spec = ability.Copy
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local people = {}
	for model in pairs(targets) do
		if model ~= character and model.Parent then
			local owner = Players:GetPlayerFromCharacter(model)
			local id = owner and owner:GetAttribute("AbilityCharacter") or model:GetAttribute("AbilityCharacter")
			local r = model:FindFirstChild("HumanoidRootPart")
			local who = type(id) == "string" and findCharacter(id)
			if who and r and (r.Position - root.Position).Magnitude <= (spec.Range or 160) then
				local slots = {}
				for _, s in ipairs({ "Skill1", "Skill2" }) do
					if who[s] then
						table.insert(slots, s)
					end
				end
				if #slots > 0 then
					table.insert(people, { Model = model, Id = id, Slots = slots })
				end
			end
		end
	end
	if #people == 0 then
		debugLog(player.Name, "Sharingan Copy: nobody close enough to copy")
		lastAbilityUse[player] = lastAbilityUse[player] or {}
		lastAbilityUse[player][fromSlot] = os.clock() -- straight onto cooldown
		if ultimateConfig and fromSlot == "Ultimate" then -- (a charged ultimate: given back, Config.Abilities.UltCharge.CopyFailRefund)
			chargePausedUntil[player] = nil
			setCharge(player, (ultimateCharge[player] or 0) + (ultimateConfig.CopyFailRefund or 0))
		end
		abilityRemote:FireClient(player, "CopyFailed")
		return
	end
	local person, slot
	for _ = 1, 6 do
		person = people[math.random(#people)]
		slot = person.Slots[math.random(#person.Slots)]
		if person.Id .. "/" .. slot ~= previousCopy[player] then
			break
		end
	end
	previousCopy[player] = person.Id .. "/" .. slot
	local copied = findCharacter(person.Id)[slot]
	local window = spec.Window or 20
	activeCopies[player] = { Id = person.Id, Slot = slot, Ability = copied, Expires = os.clock() + window, FromSlot = fromSlot }
	debugLog(player.Name, "copied", person.Id, slot, "(" .. copied.Name .. ") from", person.Model.Name)
	abilityRemote:FireClient(player, "Copy", person.Id, slot, window)
end

-- Activate a stored copied skill.
local function activateCopiedMove(player)
	local copy = activeCopies[player]
	if not copy then
		return debugLog(player.Name, "ignored: no copied move")
	end
	local now = os.clock()
	if now > copy.Expires + (networkConfig.CooldownLeeway or 0.3) then
		activeCopies[player] = nil
		return debugLog(player.Name, "ignored: the copied move ran out")
	end
	if not isAlive(player) then
		return
	end
	if stunExpiresAt[player] and now < stunExpiresAt[player] - (networkConfig.BusyLeeway or 0.15) then
		return debugLog(player.Name, "ignored: stunned")
	end
	if freezeExpiresAt[player] and now < freezeExpiresAt[player] - (networkConfig.BusyLeeway or 0.15) then
		return debugLog(player.Name, "ignored: frozen (Za Warudo)")
	end
	if abilityBusyUntil[player] and now < abilityBusyUntil[player] then
		return debugLog(player.Name, "ignored: still using another ability")
	end
	activeCopies[player] = nil
	lastAbilityUse[player] = lastAbilityUse[player] or {}
	lastAbilityUse[player][copy.FromSlot] = now -- the Sharingan Copy cooldown starts now
	abilityBusyUntil[player] = now + math.max(Abilities.BusyTime(copy.Id, copy.Slot) - (networkConfig.BusyLeeway or 0.15), 0)
	debugLog(player.Name, "used the copied", copy.Id, copy.Slot)
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			abilityRemote:FireClient(other, "Used", player, copy.Id, copy.Slot)
		end
	end
	runServerEffects(player, copy.Ability, copy.Slot, copy.Id)
end

-- Dispatch server-side parts of each ability.
function runServerEffects(player, ability, fromSlot, characterId)
	if type(ability.Hit) == "table" and hitConfig[ability.Hit.Kind] then
		task.spawn(launchProjectile, player, ability, fromSlot)
	end
	if type(ability.Touch) == "table" and hitConfig[ability.Touch.Kind] then
		task.spawn(handleTouchAttack, player, ability, characterId, fromSlot)
	end
	if type(ability.Swap) == "table" then
		task.spawn(swapPlaces, player, ability)
	end
	if ability.NoCooldowns then
		freeSkillsUntil[player] = os.clock() + Abilities.BusyTime(characterId or "", fromSlot or "") + ability.NoCooldowns
	end
	if ability.Dodge then
		dodgeExpiresAt[player] = { Until = os.clock() + (ability.Duration or 6), BaseOnly = ability.Dodge == "Base" }
	end
	if type(ability.Copy) == "table" and fromSlot then
		task.spawn(prepareCopiedMove, player, ability, fromSlot)
	end
	if type(ability.Freeze) == "table" then
		task.spawn(freezeTime, player, ability)
	end
end

local function activateAbility(player, slot, characterId)
	if type(slot) ~= "string" or not validSlots[slot] then
		return debugLog(player.Name, "ignored: not a slot")
	end
	local current = player:GetAttribute("AbilityCharacter")
	if characterId ~= current then
		return debugLog(player.Name, "ignored:", tostring(characterId), "isn't their character (", tostring(current), ")")
	end
	local character = findCharacter(current)
	local ability = character and character[slot]
	if not ability then
		return debugLog(player.Name, "ignored: no", slot, "for", tostring(current))
	end
	if not isAlive(player) then
		return debugLog(player.Name, "ignored: not alive")
	end
	local now = os.clock()
	if stunExpiresAt[player] and now < stunExpiresAt[player] - (networkConfig.BusyLeeway or 0.15) then
		return debugLog(player.Name, "ignored: stunned")
	end
	if freezeExpiresAt[player] and now < freezeExpiresAt[player] - (networkConfig.BusyLeeway or 0.15) then
		return debugLog(player.Name, "ignored: frozen (Za Warudo)")
	end
	-- holding a copied move (Sharingan Copy): that slot is taken until it's used or runs out
	local copy = activeCopies[player]
	if copy and now > copy.Expires then
		activeCopies[player] = nil
		lastAbilityUse[player] = lastAbilityUse[player] or {}
		lastAbilityUse[player][copy.FromSlot] = copy.Expires -- ran out: the cooldown started then
		copy = nil
	end
	if copy and copy.FromSlot == slot then
		return debugLog(player.Name, "ignored: holding a copied move in", slot)
	end
	local used = lastAbilityUse[player]
	if not used then
		used = {}
		lastAbilityUse[player] = used
	end
	local cooldown = ability.Cooldown or (abilityConfig.Cooldowns and abilityConfig.Cooldowns[slot]) or 5
	local noCooldowns = slot ~= "Ultimate" and freeSkillsUntil[player] and now < freeSkillsUntil[player] + (networkConfig.CooldownLeeway or 0.3)
	local charged = slot == "Ultimate" and ultimateConfig ~= nil -- the ultimate charges up instead of a cooldown
	if charged then
		if (ultimateCharge[player] or 0) < 100 - (ultimateConfig.Leeway or 0.5) then
			return debugLog(player.Name, "ignored: ultimate only", string.format("%.0f%%", ultimateCharge[player] or 0), "charged")
		end
	elseif used[slot] and not noCooldowns and now - used[slot] < cooldown - (networkConfig.CooldownLeeway or 0.3) then
		return debugLog(player.Name, "ignored:", slot, "still cooling down")
	end
	if abilityBusyUntil[player] and now < abilityBusyUntil[player] then
		return debugLog(player.Name, "ignored: still using another ability")
	end
	used[slot] = now
	abilityBusyUntil[player] = now + math.max(Abilities.BusyTime(current, slot) - (networkConfig.BusyLeeway or 0.15), 0)
	if charged then
		setCharge(player, 0) -- spent
		if ultimateConfig.PauseWhileActive ~= false then -- no charging while it's still going
			chargePausedUntil[player] = now + math.max(Abilities.BusyTime(current, slot), ability.Duration or 0)
		end
	elseif ultimateConfig and (slot == "Skill1" or slot == "Skill2") and not noCooldowns then
		setCharge(player, (ultimateCharge[player] or 0) + cooldown * (ultimateConfig.SkillBonus or 0)) -- a few % for using a skill
	end
	debugLog(player.Name, "used", current, slot, ultimateConfig and string.format("(ult %.0f%%)", ultimateCharge[player] or 0) or "")
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			abilityRemote:FireClient(other, "Used", player, current, slot)
		end
	end
	if slot == "Skill1" or slot == "Skill2" then
		lastBasicSlot[player] = slot
	end
	runServerEffects(player, ability, slot, current)
end

-- Character switching is limited outside Studio.
local function canSwitchCharacter(player)
	if not abilityConfig.TestSwitcher then
		return false
	end
	if RunService:IsStudio() then
		return true
	end
	if table.find(abilityConfig.Testers or {}, player.UserId) then
		return true
	end
	if game.CreatorType == Enum.CreatorType.Group then
		local ok, rank = pcall(function()
			return player:GetRankInGroup(game.CreatorId)
		end)
		return ok and rank >= (abilityConfig.TesterRank or 254)
	end
	return player.UserId == game.CreatorId
end

-- Handle character selection for authorized testers.
local function switchCharacter(player, characterId)
	if not canSwitchCharacter(player) then
		if characterId ~= player:GetAttribute("AbilityCharacter") then
			abilityRemote:FireClient(player, "SelectRefused", player:GetAttribute("AbilityCharacter")) -- the bar goes back to who you are
		end
		return debugLog(player.Name, "ignored: not allowed to switch characters here (Config.Abilities.TesterRank / Testers)")
	end
	if type(characterId) ~= "string" or not findCharacter(characterId) then
		return debugLog(player.Name, "ignored: unknown character")
	end
	if player:GetAttribute("AbilityCharacter") ~= characterId then
		player:SetAttribute("AbilityCharacter", characterId)
		lastAbilityUse[player] = {} -- a new character starts with everything ready (same as the ability bar)
		activeCopies[player] = nil
		freeSkillsUntil[player] = nil
		if ultimateConfig then -- a new character starts at StartAt (Studio's test arrows: full, to try ultimates straight away)
			chargePausedUntil[player] = nil
			setCharge(player, (ultimateConfig.StudioFillOnSwitch and RunService:IsStudio()) and 100 or (ultimateConfig.StartAt or 0))
		end
		debugLog(player.Name, "now plays", characterId)
	end
end

if abilityConfig and abilityConfig.Enabled then
	trackTargets()
	abilityRemote.OnServerEvent:Connect(function(player, action, a, b)
		if not allowMessage(player) then
			return debugLog(player.Name, "ignored: too many messages")
		end
		if action == "Use" then
			activateAbility(player, a, b)
		elseif action == "UseCopy" then
			activateCopiedMove(player)
		elseif action == "Select" then
			switchCharacter(player, a)
		end
	end)

	local function setupPlayer(player)
		if player:GetAttribute("AbilityCharacter") == nil then
			player:SetAttribute("AbilityCharacter", abilityConfig.DefaultCharacter)
		end
		if ultimateConfig and ultimateCharge[player] == nil then
			setCharge(player, ultimateConfig.StartAt or 0)
		end
	end

-- Charge ultimates while the player is active.
	-- while your own ultimate is still going / you hold a copied move (UltCharge.PauseWhileActive)
	if ultimateConfig then
		local CHARGE_UPDATE_INTERVAL = 0.25
		local waited = 0
		RunService.Heartbeat:Connect(function(dt)
			waited += dt
			if waited < CHARGE_UPDATE_INTERVAL then
				return
			end
			local step = waited
			waited = 0
			local now = os.clock()
			for _, player in ipairs(Players:GetPlayers()) do
				local copy = activeCopies[player]
				if copy and now > copy.Expires + (networkConfig.CooldownLeeway or 0.3) then
					activeCopies[player] = nil -- the copied move ran out unused
					copy = nil
				end
				local charge = ultimateCharge[player]
				local paused = ultimateConfig.PauseWhileActive ~= false and (copy ~= nil or (chargePausedUntil[player] ~= nil and now < chargePausedUntil[player]))
				if charge and charge < 100 and not paused and isAlive(player) and not isFrozen(player) then
					setCharge(player, charge + (ultimateConfig.PerSecond or 0) * step)
				end
			end
		end)
	end
	Players.PlayerAdded:Connect(setupPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		setupPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastAbilityUse[player] = nil
		messageBudget[player] = nil
		abilityBusyUntil[player] = nil
		stunExpiresAt[player] = nil
		dodgeExpiresAt[player] = nil
		lastBasicSlot[player] = nil
		activeCopies[player] = nil
		previousCopy[player] = nil
		freeSkillsUntil[player] = nil
		freezeExpiresAt[player] = nil
		ultimateCharge[player] = nil
		chargePausedUntil[player] = nil
	end)
end
