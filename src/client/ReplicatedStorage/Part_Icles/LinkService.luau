--[[
	LinkService  -  standalone CFrame-tracking service.
	Users link arbitrary BaseParts / Models / Attachments to any target Instance
	(BasePart / Model / Attachment / Bone / Camera) using the same LinkMode dispatch
	as the particle runtime, without spawning particles.

	API:
	  LinkService:Activate()
	  LinkService:Deactivate()
	  LinkService:Link(part1, target, mode, duration)
	  LinkService:Clear(part1)
	  LinkService:IsLinked(part1) -> boolean

	mode: "Weld" | "Follow" | "Pivot" | "WeldWithoutRotation" (unknown -> "Weld")
	duration: optional number of seconds; nil = infinite. Entry auto-clears on expiry,
	          target destruction, or part1 destruction.

	Anchored is snapshotted at :Link time and forced true so Roblox physics does not
	fight per-frame CFrame writes; restored on :Clear / auto-expire.
]]

local RunService = game:GetService("RunService")
local Constants = require(script.Parent.PartConstants)
local Log = require(script.Parent.Log)

-- Resume in PreRender on client (after physics + attachment-transform propagation
-- complete; matches the Lifecycle.luau LOOP_YIELD_EVENT choice). Heartbeat on server
-- since PreRender is client-only.
local TICK_EVENT = RunService:IsClient() and RunService.PreRender or RunService.Heartbeat

local LinkService = {}

LinkService._active = false
LinkService._connection = nil
LinkService._links = {}
LinkService._anchorSnapshot = {}
LinkService._warnedNotActive = false

local VALID_MODES = {
	Weld = true,
	Follow = true,
	Pivot = true,
	WeldWithoutRotation = true,
}

local function _readPart1CF(part1)
	if part1:IsA("Model") then
		local ok, cf = pcall(part1.GetPivot, part1)
		if ok and cf then return cf end
		return CFrame.new()
	end
	if part1:IsA("Attachment") then return part1.WorldCFrame end
	return part1.CFrame
end

local function _classifyPart1(part1)
	if part1:IsA("Model") then return "Model" end
	if part1:IsA("Attachment") then return "Attachment" end
	return "Part"
end

-- Snapshot prior Anchored state + force true. Attachment has no Anchored  -  returns nil.
-- BasePart returns a bool. Model returns a table {[BasePart] = priorAnchored} so non-
-- PrimaryPart members do not free-fall under gravity while PivotTo drives PrimaryPart.
function LinkService:_captureAndAnchor(part1)
	if part1:IsA("BasePart") then
		local prior = part1.Anchored
		part1.Anchored = true
		return prior
	end
	if part1:IsA("Model") then
		local snapshot = {}
		for _, desc in ipairs(part1:GetDescendants()) do
			if desc:IsA("BasePart") then
				snapshot[desc] = desc.Anchored
				desc.Anchored = true
			end
		end
		return snapshot
	end
	return nil
end

function LinkService:_restoreAnchor(part1)
	local prior = self._anchorSnapshot[part1]
	self._anchorSnapshot[part1] = nil
	if prior == nil then return end
	if part1:IsA("BasePart") and part1.Parent then
		part1.Anchored = prior
		return
	end
	if part1:IsA("Model") and type(prior) == "table" then
		for desc, priorAnchored in pairs(prior) do
			if desc.Parent then desc.Anchored = priorAnchored end
		end
	end
end

-- Start the per-frame link-tracking loop. Idempotent.
function LinkService:Activate()
	if self._active then return end
	self._active = true
	self._connection = TICK_EVENT:Connect(function(dt)
		self:_tick(dt)
	end)
end

-- Stop tracking + clear every active link, restoring each part1's prior Anchored state.
function LinkService:Deactivate()
	if not self._active then return end
	self._active = false
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
	for part1 in pairs(self._links) do
		self._links[part1] = nil
		self:_restoreAnchor(part1)
	end
end

-- Pin `part1`'s CFrame to follow `target` every frame using `mode` (Weld / Follow /
-- Pivot / WeldWithoutRotation). `duration` (optional seconds) auto-clears the link
-- when elapsed; nil = persist until Clear. Anchored is snapshotted+forced true so
-- physics does not fight the per-frame CFrame writes; restored on Clear.
function LinkService:Link(part1, target, mode, duration)
	if not part1 or not target then return end
	if part1 == target then return end
	if not (part1:IsA("BasePart") or part1:IsA("Model") or part1:IsA("Attachment")) then return end
	if not part1.Parent or not target.Parent then return end
	if not VALID_MODES[mode] then mode = "Weld" end
	if not self._active and not self._warnedNotActive then
		self._warnedNotActive = true
		Log.warn("[Part-Icles LinkService] Link called before Activate(); the link won't update until you call LinkService:Activate(). This warning fires once.")
	end

	local targetCF = Constants.resolveLinkCFrame(target)
	local part1CF = _readPart1CF(part1)

	-- Snapshot Anchored on first Link only; re-Link of same part1 keeps the original
	-- prior-state so a Clear after multiple Links restores the truly-authored value.
	if self._anchorSnapshot[part1] == nil and not self._links[part1] then
		self._anchorSnapshot[part1] = self:_captureAndAnchor(part1)
	else
		-- Re-arm anchor flag in case user toggled it between Link calls.
		self:_captureAndAnchor(part1)
	end

	self._links[part1] = {
		target = target,
		mode = mode,
		offsetCF = targetCF:ToObjectSpace(part1CF),
		rotation = part1CF.Rotation,
		expiresAt = duration and (os.clock() + duration) or nil,
		partKind = _classifyPart1(part1),
	}
end

-- Stop tracking `part1`; restore its prior Anchored state. No-op if not linked.
function LinkService:Clear(part1)
	if not self._links[part1] then return end
	self._links[part1] = nil
	self:_restoreAnchor(part1)
end

-- Returns true when `part1` has an active link entry.
function LinkService:IsLinked(part1)
	return self._links[part1] ~= nil
end

function LinkService:_tick(dt)
	local now = os.clock()
	for part1, entry in pairs(self._links) do
		if not part1.Parent or not entry.target.Parent then
			self:Clear(part1)
		elseif entry.expiresAt and now >= entry.expiresAt then
			self:Clear(part1)
		else
			local targetCF = Constants.resolveLinkCFrame(entry.target)
			local newCF
			if entry.mode == "Weld" then
				newCF = targetCF * entry.offsetCF
			else
				-- Follow / Pivot / WeldWithoutRotation: position tracks the linked offset,
				-- rotation stays at the authored snapshot. WWR's mesh-frame variant from
				-- the particle pipeline doesn't apply outside emit; v1 treats it as Follow.
				newCF = CFrame.new((targetCF * entry.offsetCF).Position) * entry.rotation
			end
			if entry.partKind == "Model" then
				pcall(function() part1:PivotTo(newCF) end)
			elseif entry.partKind == "Attachment" then
				local parent = part1.Parent
				if parent and parent:IsA("BasePart") then
					part1.CFrame = parent.CFrame:ToObjectSpace(newCF)
				end
			else
				part1.CFrame = newCF
			end
		end
	end
end

return LinkService
