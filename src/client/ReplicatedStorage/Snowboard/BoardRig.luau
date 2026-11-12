--[[
	BoardRig: how the board is attached to the rider, and how the saved animations are fitted to it.

	The rider's board hangs off the HumanoidRootPart (the part the board physics moves), not the Torso. So in an
	animation the body can lean, crouch and twist while the board stays planted under it, and switching between
	animations (carving left -> right, jump, land, abilities) blends the board smoothly instead of wobbling it around
	with the torso.

	The saved animations (BoardAssets.Rigs.*.AnimSaves) were made on rigs where the board hangs off the Torso. They're
	left exactly as they are. When one is loaded, a copy is fitted to the rider's board ("retargeted"): at every
	keyframe the board's place under the body (torso pose x board pose, exactly as in the animation) is worked out and
	keyed on the rider's board joint. So the board moves just like it does in the animation editor. A board from a
	different rig (the ability animations' "Board") moves the rider's own board the same way, from where that board
	normally sits on the rider.

	API
	  BoardRig.BoardJoint(model, partName?)               the board's Motor6D (hanging off the HumanoidRootPart or the Torso)
	  BoardRig.Attach(motor, model)                       hang a board joint off the HumanoidRootPart instead of the Torso
	                                                      (same resting place)
	  BoardRig.Retarget(kfs, sourceRig, targetJoint)      a copy of a saved animation, fitted to the target board
	  BoardRig.Signature(joint)                           a key for caching fitted animations per board joint
]]

local TweenService = game:GetService("TweenService")

local FILL_STEP = 1 / 30 -- seconds: the board gets a key at least this often in a fitted animation

local BoardRig = {}

local BODY = {
	HumanoidRootPart = true, Torso = true, Head = true,
	["Left Arm"] = true, ["Right Arm"] = true, ["Left Leg"] = true, ["Right Leg"] = true,
}

-- a model's joints, without looking through its saved animations: a dummy that carries an AnimSaves has ~11,000
-- keyframes / poses in there, and searching all of that every time it got hit (or frozen) made the game hitch
local SKIP = { ObjectValue = true, KeyframeSequence = true, Keyframe = true, Pose = true }
local function jointsOf(model)
	local joints = {}
	local function walk(node)
		for _, child in ipairs(node:GetChildren()) do
			if not SKIP[child.ClassName] then
				if child:IsA("Motor6D") then
					table.insert(joints, child)
				end
				walk(child)
			end
		end
	end
	walk(model)
	return joints
end

-- the root -> torso joint, and where the torso rests relative to the root
local function rootJoint(model)
	local root = model:FindFirstChild("HumanoidRootPart")
	local torso = model:FindFirstChild("Torso")
	if root and torso then
		for _, d in ipairs(jointsOf(model)) do
			if d:IsA("Motor6D") and d.Part0 == root and d.Part1 == torso then
				return d, d.C0 * d.C1:Inverse()
			end
		end
	end
	return nil, CFrame.identity
end

function BoardRig.BoardJoint(model, partName)
	if not model then
		return nil
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	local torso = model:FindFirstChild("Torso")
	for _, d in ipairs(jointsOf(model)) do
		if d.Part0 and d.Part1 and not BODY[d.Part1.Name] and (d.Part0 == root or d.Part0 == torso) then
			if partName then
				if d.Part1.Name == partName then
					return d
				end
			elseif not d.Part1:FindFirstAncestor("TestBoard") then -- the board tester's swapped board: only when asked by name
				return d
			end
		end
	end
	return nil
end

function BoardRig.Attach(motor, model)
	local root = model:FindFirstChild("HumanoidRootPart")
	if not (motor and root and motor.Part0 and motor.Part0.Name == "Torso") then
		return motor
	end
	local _, rest = rootJoint(model)
	motor.C0 = rest * motor.C0 -- same resting place, now measured from the root
	motor.Part0 = root
	motor.Parent = root
	return motor
end

function BoardRig.Signature(joint)
	if not (joint and joint.Part0 and joint.Part1) then
		return "none"
	end
	local function key(cf)
		local c = { cf:GetComponents() }
		for i, v in ipairs(c) do
			c[i] = math.floor(v * 1000 + 0.5)
		end
		return table.concat(c, ",")
	end
	return joint.Part0.Name .. ">" .. joint.Part1.Name .. ":" .. key(joint.C0) .. ":" .. key(joint.C1)
end

-- every keyframe where a pose is actually keyed (Weight 0 poses are just placeholders holding their children)
local function keysOf(kfs, poseName, parentName)
	local keys = {}
	for _, kf in ipairs(kfs:GetChildren()) do
		if kf:IsA("Keyframe") then
			for _, p in ipairs(kf:GetDescendants()) do
				if p:IsA("Pose") and p.Name == poseName and p.Weight > 0 and p.Parent and p.Parent.Name == parentName then
					table.insert(keys, { Time = kf.Time, CFrame = p.CFrame, Style = p.EasingStyle, Direction = p.EasingDirection })
					break
				end
			end
		end
	end
	table.sort(keys, function(a, b)
		return a.Time < b.Time
	end)
	return keys
end

-- a pose's value at time t, the way the animation plays it (each joint eases from one of its keys to the next)
local function sample(keys, t)
	local n = #keys
	if n == 0 then
		return CFrame.identity
	end
	if t <= keys[1].Time then
		return keys[1].CFrame
	end
	for i = 2, n do
		local b = keys[i]
		if t <= b.Time then
			local a = keys[i - 1]
			local span = b.Time - a.Time
			if span <= 0 then
				return b.CFrame
			end
			local alpha = (t - a.Time) / span
			local style = a.Style.Name
			if style == "Constant" then
				return a.CFrame
			elseif style ~= "Linear" then
				local ok, eased = pcall(function()
					return TweenService:GetValue(alpha, Enum.EasingStyle[style == "CubicV2" and "Cubic" or style], Enum.EasingDirection[a.Direction.Name])
				end)
				alpha = ok and eased or alpha
			end
			return a.CFrame:Lerp(b.CFrame, alpha)
		end
	end
	return keys[n].CFrame
end

local function getPose(parent, name)
	local pose = parent:FindFirstChild(name)
	if not (pose and pose:IsA("Pose")) then
		pose = Instance.new("Pose")
		pose.Name = name
		pose.Weight = 0 -- placeholder: not keyed here
		pose.Parent = parent
	end
	return pose
end

function BoardRig.Retarget(kfs, sourceRig, targetJoint)
	local copy = kfs:Clone()
	local sourceJoint = BoardRig.BoardJoint(sourceRig)
	local targetModel = targetJoint and targetJoint:FindFirstAncestorOfClass("Model")
	if not (sourceJoint and targetJoint and targetModel) then
		return copy -- nothing to fit (no board on one side): as it is
	end
	local sourceName = sourceJoint.Part1.Name
	local sourceParent = sourceJoint.Part0.Name -- "Torso" on the saved rigs
	local targetName = targetJoint.Part1.Name
	local targetParent = targetJoint.Part0.Name -- "HumanoidRootPart" on the rider (or "Torso", e.g. a dummy)
	local sourceRJ, sourceRest = rootJoint(sourceRig)
	local targetRJ, targetRest = rootJoint(targetModel)
	local torsoKeys = keysOf(kfs, "Torso", "HumanoidRootPart")
	local boardKeys = keysOf(kfs, sourceName, sourceParent)

	-- torso relative to the root at time t (animated)
	local function torsoAt(rj, rest, t)
		if not rj then
			return rest
		end
		return rj.C0 * sample(torsoKeys, t) * rj.C1:Inverse()
	end
	-- where the source board is relative to the root at time t
	local function sourceBoardAt(t)
		local j = sourceJoint
		local onJoint = j.C0 * sample(boardKeys, t) * j.C1:Inverse()
		return sourceParent == "Torso" and torsoAt(sourceRJ, sourceRest, t) * onJoint or onJoint
	end
	-- resting places (relative to the root): the target board follows the source board from where it normally sits
	local sourceRestBoard = (sourceParent == "Torso" and sourceRest or CFrame.identity) * sourceJoint.C0 * sourceJoint.C1:Inverse()
	local targetRestBoard = (targetParent == "Torso" and targetRest or CFrame.identity) * targetJoint.C0 * targetJoint.C1:Inverse()
	local offset = sourceRestBoard:Inverse() * targetRestBoard

	-- the board's pose on the target joint at time t
	local function targetPoseAt(t)
		local board = sourceBoardAt(t) * offset -- target board relative to the root
		if targetParent == "Torso" then
			return targetJoint.C0:Inverse() * torsoAt(targetRJ, targetRest, t):Inverse() * board * targetJoint.C1
		end
		return targetJoint.C0:Inverse() * board * targetJoint.C1
	end
	local function addPose(kf, t)
		local rootPose = getPose(kf, "HumanoidRootPart")
		local parentPose = targetParent == "Torso" and getPose(rootPose, "Torso") or rootPose
		local pose = Instance.new("Pose")
		pose.Name = targetName
		pose.CFrame = targetPoseAt(t)
		pose.Weight = 1
		pose.EasingStyle = Enum.PoseEasingStyle.Linear
		pose.EasingDirection = Enum.PoseEasingDirection.In
		pose.Parent = parentPose
		return pose
	end

	local times = {}
	for _, kf in ipairs(copy:GetChildren()) do
		if kf:IsA("Keyframe") then
			local t = kf.Time
			table.insert(times, t)
			-- take the old board pose out (its children, e.g. Clouds or chains, move to the new one)
			local children = {}
			for _, p in ipairs(kf:GetDescendants()) do
				if p:IsA("Pose") and p.Name == sourceName and p.Parent and p.Parent.Name == sourceParent then
					for _, c in ipairs(p:GetChildren()) do
						table.insert(children, c)
					end
					for _, c in ipairs(p:GetChildren()) do
						c.Parent = nil
					end
					p:Destroy()
				end
			end
			-- key the board on the target joint, at every keyframe, so it follows the body exactly
			local pose = addPose(kf, t)
			for _, c in ipairs(children) do
				c.Parent = pose
			end
		end
	end
	-- where keyframes are far apart, add in-between board keys (FILL_STEP apart), so the board traces the same path
	-- the body makes between them instead of cutting straight across
	table.sort(times)
	for i = 2, #times do
		local a, b = times[i - 1], times[i]
		local extra = math.ceil((b - a) / FILL_STEP - 1e-6) - 1
		for k = 1, extra do
			local t = a + (b - a) * k / (extra + 1)
			local kf = Instance.new("Keyframe")
			kf.Name = "BoardFill"
			kf.Time = t
			local rootPose = Instance.new("Pose")
			rootPose.Name = "HumanoidRootPart"
			rootPose.Weight = 0
			rootPose.Parent = kf
			addPose(kf, t)
			kf.Parent = copy
		end
	end
	return copy
end

return BoardRig
