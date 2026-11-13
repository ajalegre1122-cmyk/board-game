--[[
	Testing: tick the "Log" attribute on this script to print every accepted / ignored use in the output.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Snowboard = ReplicatedStorage:WaitForChild("Snowboard")
local Config = require(Snowboard:WaitForChild("Config"))
local Abilities = require(Snowboard:WaitForChild("Abilities"))
local remote = Snowboard:WaitForChild("AbilityRemote")

local A = Config.Abilities
local N = (A and A.Network) or {}
local SLOTS = { Skill1 = true, Skill2 = true, Ultimate = true }

local lastUsed = {} -- player -> slot -> os.clock() of the last accepted use
local budget = {} -- player -> { Tokens, At }: how many messages they can still send right now
local busyUntil = {} -- player -> os.clock() when their current ability's move is over

local function log(...)
	if script:GetAttribute("Log") then
		print("[AbilityServer]", ...)
	end
end

local function findCharacter(id)
	for _, character in ipairs(A.Characters or {}) do
		if character.Id == id then
			return character
		end
	end
	return nil
end

-- spam guard: a few messages a second (refills over time), anything over that is ignored
local function allow(player)
	local now = os.clock()
	local b = budget[player]
	if not b then
		b = { Tokens = N.Burst or 6, At = now }
		budget[player] = b
	end
	b.Tokens = math.min(N.Burst or 6, b.Tokens + (now - b.At) * (N.PerSecond or 3))
	b.At = now
	if b.Tokens < 1 then
		return false
	end
	b.Tokens -= 1
	return true
end

local function alive(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0 and character:FindFirstChild("HumanoidRootPart") ~= nil
end

-- hits ------------------------------------------------------------------------------------------------------------
-- A thrown ability (one with Hit = { Kind, Release, Speed }) isn't resolved on the thrower's client: at the release
-- moment the server picks the target the same way the effects aim (closest rider or dummy in front, within
-- Config.AbilityVFX.TargetRange / AimCone), flies the throw towards it at the same speed, and when it gets there tells
-- every client "this model got hit by this" (Config.Hits). The player who got hit slows down / is stunned on their own
-- client; everyone plays the stun animation on them. The thrower can't pick who gets hit, or claim a hit.
local V = Config.AbilityVFX or {}
local HITS = Config.Hits or {}
local stunnedUntil = {} -- player -> os.clock() when their stun wears off (no abilities until then)
local dodgeUntil = {} -- player -> os.clock() when their Sharingan dodge runs out
local noCooldownUntil = {} -- player -> os.clock(): 500 IQ, no cooldowns on their skills until then
local lastSlot = {} -- player -> their last used basic move (Skill1 / Skill2), for Sharingan Copy
local frozenUntil = {} -- player -> os.clock() when time moves again for them (someone's Za Warudo)
local heldDummies = {} -- frozen dummy's root -> os.clock() when it's let go

local function isFrozen(player)
	return frozenUntil[player] ~= nil and os.clock() < frozenUntil[player]
end

-- ultimate charge (Config.Abilities.UltCharge) ----------------------------------------------------------------------
-- Kept here, never trusted from the client: it fills every quarter second while you ride (PerSecond), jumps a little
-- when a skill use is accepted (SkillBonus x that skill's cooldown), and empties when your ultimate is accepted. It's
-- copied onto the player as the "UltCharge" attribute (0-100) for their ability bar to show.
local UC = A and A.UltCharge
local ultCharge = {} -- player -> 0-100
local ultPausedUntil = {} -- player -> os.clock(): no charging until then (their own ultimate is still going)

local function setCharge(player, value)
	value = math.clamp(value, 0, 100)
	ultCharge[player] = value
	player:SetAttribute("UltCharge", math.floor(value * 10 + 0.5) / 10)
end

-- wait `seconds` of this player's own time: while they're frozen (Za Warudo) their moves wait too
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
local function watchTargets()
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

-- same rules as AbilityVFX:FindTarget
local function findTarget(character, range, ahead)
	local myRoot = character:FindFirstChild("HumanoidRootPart")
	if not myRoot then
		return nil
	end
	local v = myRoot.AssemblyLinearVelocity
	local forward = v.Magnitude > 5 and v.Unit or myRoot.CFrame.LookVector
	local cone = math.cos(math.rad(V.AimCone or 70))
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
	local hit = HITS[kind]
	if not hit then
		return
	end
	local victim = Players:GetPlayerFromCharacter(model)
	local dodge = victim and dodgeUntil[victim] -- Sharingan: basic moves (or everything) miss
	if dodge and os.clock() < dodge.Until and not (dodge.BaseOnly and fromSlot == "Ultimate") then
		log(model.Name, "dodged", kind, "from", attacker.Name)
		remote:FireAllClients("Dodged", model, attacker)
		return
	end
	if victim then
		local from = math.max(os.clock(), frozenUntil[victim] or 0) -- hit while frozen: the stun starts when time moves again
		stunnedUntil[victim] = math.max(stunnedUntil[victim] or 0, from + (hit.StunTime or 0))
	end
	log(attacker.Name, "hit", model.Name, "with", kind)
	remote:FireAllClients("Hit", model, kind, attacker)
end

-- one throw: wait for the release, pick the target, fly to it (homing, like the effect)
local function throw(player, ability, fromSlot)
	local spec = ability.Hit
	waitOwnTime(player, (V.Timings and V.Timings[spec.Release]) or 0)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and alive(player)) then
		return
	end
	if stunnedUntil[player] and os.clock() < stunnedUntil[player] then
		return -- stunned mid-throw: it doesn't come out
	end
	local target = findTarget(character, V.TargetRange or 160, spec.Ahead ~= false)
	if not target then
		return log(player.Name, "threw", spec.Kind, "at nobody")
	end
	local speed = (V[spec.Speed] or 150) + root.AssemblyLinearVelocity.Magnitude
	local pos = root.Position + Vector3.new(0, spec.Height or 1.5, 0)
	local maxFlight = (V.ThrowRange or 140) * 1.6
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

-- Chidori: for its Duration, anyone (rider or dummy) within Touch.Radius of you gets hit, once each
local function touchAttack(player, ability, characterId, slot)
	local spec = ability.Touch
	local done = {}
	local endsAt = os.clock() + (ability.Duration or 2)
	local function ended(hit) -- tell everyone it's over (hit = the strike; otherwise it fizzled)
		remote:FireAllClients("Ended", player, characterId, slot, hit)
	end
	while os.clock() < endsAt do
		local dt = task.wait(0.05)
		if isFrozen(player) then
			endsAt += dt -- frozen mid-Chidori: it waits with you
			continue
		end
		if not alive(player) or (stunnedUntil[player] and os.clock() < stunnedUntil[player]) then
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
						busyUntil[player] = os.clock() + 0.2 -- the move is over: the other slots free up again
						ended(true)
						return
					end
				end
			end
		end
	end
end

-- Boogie Woogie: at the clap, swap places with the closest rider or dummy within Swap.Range (team-mate or not). Riders
-- move themselves (their own client runs their board: "Teleport"), the server moves dummies
local function swapPlaces(player, ability)
	local spec = ability.Swap
	waitOwnTime(player, (V.Timings and V.Timings[spec.Release or "Clap"]) or 0.28)
	if not alive(player) or (stunnedUntil[player] and os.clock() < stunnedUntil[player]) then
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
		return log(player.Name, "Boogie Woogie: nobody in range")
	end
	local mine, theirs = root.CFrame, bestRoot.CFrame
	local myNew = CFrame.new(theirs.Position) * mine.Rotation -- each keeps facing their own way: only the places swap
	local theirNew = CFrame.new(mine.Position) * theirs.Rotation
	local other = Players:GetPlayerFromCharacter(best)
	remote:FireClient(player, "Teleport", myNew)
	if other then
		remote:FireClient(other, "Teleport", theirNew)
	else
		local offset = theirs:ToObjectSpace(best:GetPivot())
		best:PivotTo(theirNew * offset)
	end
	log(player.Name, "swapped places with", best.Name, string.format("(%.0f studs)", bestDistance))
	remote:FireAllClients("Swapped", player, best)
end

-- Za Warudo: when the dome bursts (Freeze.Release timing), every other rider and dummy (within Freeze.Range; 0 = everyone)
-- freezes for the ability's Duration. Frozen riders hold still on their own client ("Frozen"), and here their abilities are
-- ignored and their thrown moves hang in the air until it's over; frozen dummies are held in place here. Every client
-- freezes their poses and effects.
local function timeStop(player, ability)
	local spec = ability.Freeze
	waitOwnTime(player, (V.Timings and V.Timings[spec.Release or "ZaWarudo"]) or 0.55)
	if not alive(player) or (stunnedUntil[player] and os.clock() < stunnedUntil[player]) then
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
					frozenUntil[victim] = math.max(frozenUntil[victim] or 0, untilTime)
				elseif not r.Anchored or heldDummies[r] then
					-- a dummy / NPC: held in place here until it's over
					heldDummies[r] = math.max(heldDummies[r] or 0, untilTime)
					r.Anchored = true
					task.delay(duration + 0.05, function()
						if heldDummies[r] and os.clock() >= heldDummies[r] then
							heldDummies[r] = nil
							if r.Parent then
								r.Anchored = false
							end
						end
					end)
				end
			end
		end
	end
	log(player.Name, "Za Warudo froze", #frozen, "for", duration, "s")
	remote:FireAllClients("Frozen", player, frozen, duration)
end

local serverEffects -- (defined below: Copy uses it for the copied move)

-- Sharingan Copy: a random rider within Range (team-mate or not) and a random one of their basic moves (not the same as
-- last time, when there's a choice). It goes in the copier's slot for Window seconds: they use it with "UseCopy".
local pendingCopy = {} -- player -> { Id, Slot, Ability, Expires, FromSlot }
local lastCopy = {} -- player -> "Character/Slot" they copied last
local function copyMove(player, ability, fromSlot)
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
		log(player.Name, "Sharingan Copy: nobody close enough to copy")
		lastUsed[player] = lastUsed[player] or {}
		lastUsed[player][fromSlot] = os.clock() -- straight onto cooldown
		if UC and fromSlot == "Ultimate" then -- (a charged ultimate: given back, Config.Abilities.UltCharge.CopyFailRefund)
			ultPausedUntil[player] = nil
			setCharge(player, (ultCharge[player] or 0) + (UC.CopyFailRefund or 0))
		end
		remote:FireClient(player, "CopyFailed")
		return
	end
	local person, slot
	for _ = 1, 6 do
		person = people[math.random(#people)]
		slot = person.Slots[math.random(#person.Slots)]
		if person.Id .. "/" .. slot ~= lastCopy[player] then
			break
		end
	end
	lastCopy[player] = person.Id .. "/" .. slot
	local copied = findCharacter(person.Id)[slot]
	local window = spec.Window or 20
	pendingCopy[player] = { Id = person.Id, Slot = slot, Ability = copied, Expires = os.clock() + window, FromSlot = fromSlot }
	log(player.Name, "copied", person.Id, slot, "(" .. copied.Name .. ") from", person.Model.Name)
	remote:FireClient(player, "Copy", person.Id, slot, window)
end

-- the copier uses the copied move (within its Window)
local function useCopy(player)
	local copy = pendingCopy[player]
	if not copy then
		return log(player.Name, "ignored: no copied move")
	end
	local now = os.clock()
	if now > copy.Expires + (N.CooldownLeeway or 0.3) then
		pendingCopy[player] = nil
		return log(player.Name, "ignored: the copied move ran out")
	end
	if not alive(player) then
		return
	end
	if stunnedUntil[player] and now < stunnedUntil[player] - (N.BusyLeeway or 0.15) then
		return log(player.Name, "ignored: stunned")
	end
	if frozenUntil[player] and now < frozenUntil[player] - (N.BusyLeeway or 0.15) then
		return log(player.Name, "ignored: frozen (Za Warudo)")
	end
	if busyUntil[player] and now < busyUntil[player] then
		return log(player.Name, "ignored: still using another ability")
	end
	pendingCopy[player] = nil
	lastUsed[player] = lastUsed[player] or {}
	lastUsed[player][copy.FromSlot] = now -- the Sharingan Copy cooldown starts now
	busyUntil[player] = now + math.max(Abilities.BusyTime(copy.Id, copy.Slot) - (N.BusyLeeway or 0.15), 0)
	log(player.Name, "used the copied", copy.Id, copy.Slot)
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			remote:FireClient(other, "Used", player, copy.Id, copy.Slot)
		end
	end
	serverEffects(player, copy.Ability, copy.Slot, copy.Id)
end

-- the parts of an ability the server runs itself
function serverEffects(player, ability, fromSlot, characterId)
	if type(ability.Hit) == "table" and HITS[ability.Hit.Kind] then
		task.spawn(throw, player, ability, fromSlot)
	end
	if type(ability.Touch) == "table" and HITS[ability.Touch.Kind] then
		task.spawn(touchAttack, player, ability, characterId, fromSlot)
	end
	if type(ability.Swap) == "table" then
		task.spawn(swapPlaces, player, ability)
	end
	if ability.NoCooldowns then
		noCooldownUntil[player] = os.clock() + Abilities.BusyTime(characterId or "", fromSlot or "") + ability.NoCooldowns
	end
	if ability.Dodge then
		dodgeUntil[player] = { Until = os.clock() + (ability.Duration or 6), BaseOnly = ability.Dodge == "Base" }
	end
	if type(ability.Copy) == "table" and fromSlot then
		task.spawn(copyMove, player, ability, fromSlot)
	end
	if type(ability.Freeze) == "table" then
		task.spawn(timeStop, player, ability)
	end
end

local function useAbility(player, slot, characterId)
	if type(slot) ~= "string" or not SLOTS[slot] then
		return log(player.Name, "ignored: not a slot")
	end
	local current = player:GetAttribute("AbilityCharacter")
	if characterId ~= current then
		return log(player.Name, "ignored:", tostring(characterId), "isn't their character (", tostring(current), ")")
	end
	local character = findCharacter(current)
	local ability = character and character[slot]
	if not ability then
		return log(player.Name, "ignored: no", slot, "for", tostring(current))
	end
	if not alive(player) then
		return log(player.Name, "ignored: not alive")
	end
	local now = os.clock()
	if stunnedUntil[player] and now < stunnedUntil[player] - (N.BusyLeeway or 0.15) then
		return log(player.Name, "ignored: stunned")
	end
	if frozenUntil[player] and now < frozenUntil[player] - (N.BusyLeeway or 0.15) then
		return log(player.Name, "ignored: frozen (Za Warudo)")
	end
	-- holding a copied move (Sharingan Copy): that slot is taken until it's used or runs out
	local copy = pendingCopy[player]
	if copy and now > copy.Expires then
		pendingCopy[player] = nil
		lastUsed[player] = lastUsed[player] or {}
		lastUsed[player][copy.FromSlot] = copy.Expires -- ran out: the cooldown started then
		copy = nil
	end
	if copy and copy.FromSlot == slot then
		return log(player.Name, "ignored: holding a copied move in", slot)
	end
	local used = lastUsed[player]
	if not used then
		used = {}
		lastUsed[player] = used
	end
	local cooldown = ability.Cooldown or (A.Cooldowns and A.Cooldowns[slot]) or 5
	local noCooldowns = slot ~= "Ultimate" and noCooldownUntil[player] and now < noCooldownUntil[player] + (N.CooldownLeeway or 0.3)
	local charged = slot == "Ultimate" and UC ~= nil -- the ultimate charges up instead of a cooldown
	if charged then
		if (ultCharge[player] or 0) < 100 - (UC.Leeway or 0.5) then
			return log(player.Name, "ignored: ultimate only", string.format("%.0f%%", ultCharge[player] or 0), "charged")
		end
	elseif used[slot] and not noCooldowns and now - used[slot] < cooldown - (N.CooldownLeeway or 0.3) then
		return log(player.Name, "ignored:", slot, "still cooling down")
	end
	if busyUntil[player] and now < busyUntil[player] then
		return log(player.Name, "ignored: still using another ability")
	end
	used[slot] = now
	busyUntil[player] = now + math.max(Abilities.BusyTime(current, slot) - (N.BusyLeeway or 0.15), 0)
	if charged then
		setCharge(player, 0) -- spent
		if UC.PauseWhileActive ~= false then -- no charging while it's still going
			ultPausedUntil[player] = now + math.max(Abilities.BusyTime(current, slot), ability.Duration or 0)
		end
	elseif UC and (slot == "Skill1" or slot == "Skill2") and not noCooldowns then
		setCharge(player, (ultCharge[player] or 0) + cooldown * (UC.SkillBonus or 0)) -- a few % for using a skill
	end
	log(player.Name, "used", current, slot, UC and string.format("(ult %.0f%%)", ultCharge[player] or 0) or "")
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			remote:FireClient(other, "Used", player, current, slot)
		end
	end
	if slot == "Skill1" or slot == "Skill2" then
		lastSlot[player] = slot
	end
	serverEffects(player, ability, slot, current)
end

-- who can use the test switcher: anyone in a Studio playtest; in Team Test (a real server, not "Studio") only the
-- game's developers: group members of Config.Abilities.TesterRank or above, or listed in Config.Abilities.Testers
local function canSwitch(player)
	if not A.TestSwitcher then
		return false
	end
	if RunService:IsStudio() then
		return true
	end
	if table.find(A.Testers or {}, player.UserId) then
		return true
	end
	if game.CreatorType == Enum.CreatorType.Group then
		local ok, rank = pcall(function()
			return player:GetRankInGroup(game.CreatorId)
		end)
		return ok and rank >= (A.TesterRank or 254)
	end
	return player.UserId == game.CreatorId
end

-- the test switcher: in the real game the server decides who you play
local function selectCharacter(player, characterId)
	if not canSwitch(player) then
		if characterId ~= player:GetAttribute("AbilityCharacter") then
			remote:FireClient(player, "SelectRefused", player:GetAttribute("AbilityCharacter")) -- the bar goes back to who you are
		end
		return log(player.Name, "ignored: not allowed to switch characters here (Config.Abilities.TesterRank / Testers)")
	end
	if type(characterId) ~= "string" or not findCharacter(characterId) then
		return log(player.Name, "ignored: unknown character")
	end
	if player:GetAttribute("AbilityCharacter") ~= characterId then
		player:SetAttribute("AbilityCharacter", characterId)
		lastUsed[player] = {} -- a new character starts with everything ready (same as the ability bar)
		pendingCopy[player] = nil
		noCooldownUntil[player] = nil
		if UC then -- a new character starts at StartAt (Studio's test arrows: full, to try ultimates straight away)
			ultPausedUntil[player] = nil
			setCharge(player, (UC.StudioFillOnSwitch and RunService:IsStudio()) and 100 or (UC.StartAt or 0))
		end
		log(player.Name, "now plays", characterId)
	end
end

if A and A.Enabled then
	watchTargets()
	remote.OnServerEvent:Connect(function(player, action, a, b)
		if not allow(player) then
			return log(player.Name, "ignored: too many messages")
		end
		if action == "Use" then
			useAbility(player, a, b)
		elseif action == "UseCopy" then
			useCopy(player)
		elseif action == "Select" then
			selectCharacter(player, a)
		end
	end)

	local function onPlayer(player)
		if player:GetAttribute("AbilityCharacter") == nil then
			player:SetAttribute("AbilityCharacter", A.DefaultCharacter)
		end
		if UC and ultCharge[player] == nil then
			setCharge(player, UC.StartAt or 0)
		end
	end

	-- the ultimate charges up while you ride (every quarter second). Not while you're dead, frozen (Za Warudo), or
	-- while your own ultimate is still going / you hold a copied move (UltCharge.PauseWhileActive)
	if UC then
		local STEP = 0.25
		local waited = 0
		RunService.Heartbeat:Connect(function(dt)
			waited += dt
			if waited < STEP then
				return
			end
			local step = waited
			waited = 0
			local now = os.clock()
			for _, player in ipairs(Players:GetPlayers()) do
				local copy = pendingCopy[player]
				if copy and now > copy.Expires + (N.CooldownLeeway or 0.3) then
					pendingCopy[player] = nil -- the copied move ran out unused
					copy = nil
				end
				local charge = ultCharge[player]
				local paused = UC.PauseWhileActive ~= false and (copy ~= nil or (ultPausedUntil[player] ~= nil and now < ultPausedUntil[player]))
				if charge and charge < 100 and not paused and alive(player) and not isFrozen(player) then
					setCharge(player, charge + (UC.PerSecond or 0) * step)
				end
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastUsed[player] = nil
		budget[player] = nil
		busyUntil[player] = nil
		stunnedUntil[player] = nil
		dodgeUntil[player] = nil
		lastSlot[player] = nil
		pendingCopy[player] = nil
		lastCopy[player] = nil
		noCooldownUntil[player] = nil
		frozenUntil[player] = nil
		ultCharge[player] = nil
		ultPausedUntil[player] = nil
	end)
end
