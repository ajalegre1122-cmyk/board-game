--[[
	PoolHide  -  type-dispatched hide/show for pooled visuals.

	hide:  Part/Model  → CFrame teleport to far-away (Trails disabled first to avoid streak)
	       Beam/PointLight → Enabled=false
	       Attachment → no-op
	show:  no-op (Trails restored separately via PoolHide.restoreTrails after the
	       caller writes the new spawn CFrame).

	Caller's emit-setup re-writes Size / CFrame / Color / Transparency on acquire;
	PoolHide does not restore any rendering properties.
]]

local FAR_AWAY = Vector3.new(1e9, 1e9, 1e9)
local FAR_CFRAME = CFrame.new(FAR_AWAY)

local PoolHide = {}

-- Snapshot + disable every Trail descendant; runs BEFORE teleport to avoid a streak.
-- Also snapshot + zero Lifetime so existing segments expire instantly instead of persisting
-- across the teleport (Enabled=false only stops NEW segments; old ones live for Lifetime
-- seconds and render between the pre/post-teleport attachment positions = visible streak).
-- Skip snapshot when one already pending so a same-frame acquire→release race
-- can't overwrite the authored value with a transient false.
local function disableTrails(root)
	if root:IsA("Trail") then
		pcall(function()
			if root:GetAttribute("_pooledTrailEnabled") == nil then
				root:SetAttribute("_pooledTrailEnabled", root.Enabled)
			end
			if root:GetAttribute("_pooledTrailLifetime") == nil then
				root:SetAttribute("_pooledTrailLifetime", root.Lifetime)
			end
			root.Lifetime = 0
			root.Enabled = false
		end)
		return
	end
	for _, desc in ipairs(root:GetDescendants()) do
		if desc:IsA("Trail") then
			pcall(function()
				if desc:GetAttribute("_pooledTrailEnabled") == nil then
					desc:SetAttribute("_pooledTrailEnabled", desc.Enabled)
				end
				if desc:GetAttribute("_pooledTrailLifetime") == nil then
					desc:SetAttribute("_pooledTrailLifetime", desc.Lifetime)
				end
				desc.Lifetime = 0
				desc.Enabled = false
			end)
		end
	end
end

-- Restore each Trail's Lifetime + Enabled from snapshot, clear the attributes for next cycle.
local function restoreTrails(root)
	if root:IsA("Trail") then
		pcall(function()
			local priorLife = root:GetAttribute("_pooledTrailLifetime")
			if priorLife ~= nil then root.Lifetime = priorLife end
			root:SetAttribute("_pooledTrailLifetime", nil)
			local prior = root:GetAttribute("_pooledTrailEnabled")
			if prior ~= nil then root.Enabled = prior == true end
			root:SetAttribute("_pooledTrailEnabled", nil)
		end)
		return
	end
	for _, desc in ipairs(root:GetDescendants()) do
		if desc:IsA("Trail") then
			pcall(function()
				local priorLife = desc:GetAttribute("_pooledTrailLifetime")
				if priorLife ~= nil then desc.Lifetime = priorLife end
				desc:SetAttribute("_pooledTrailLifetime", nil)
				local prior = desc:GetAttribute("_pooledTrailEnabled")
				if prior ~= nil then desc.Enabled = prior == true end
				desc:SetAttribute("_pooledTrailEnabled", nil)
			end)
		end
	end
end

-- Bump cancel + duration gens + disable nested ParticleEmitter / Trail descendants.
-- Invalidates pending delayed starts + delayed-off closures from Particles.EnableEmit
-- so stale fires can't land on a reused pooled visual.
local CANCEL_GEN_ATTR = "_PartIcleNativeEmitGen"
local DURATION_GEN_ATTR = "_PartIcleNativeDurationGen"
local function cancelNativeDescendants(root)
	for _, desc in ipairs(root:GetDescendants()) do
		if desc:IsA("ParticleEmitter") or desc:IsA("Trail") then
			pcall(function()
				local cancelCur = desc:GetAttribute(CANCEL_GEN_ATTR) or 0
				desc:SetAttribute(CANCEL_GEN_ATTR, cancelCur + 1)
				local durCur = desc:GetAttribute(DURATION_GEN_ATTR) or 0
				desc:SetAttribute(DURATION_GEN_ATTR, durCur + 1)
				desc.Enabled = false
			end)
		end
	end
end

function PoolHide.hide(instance, kind)
	if not instance or not instance.Parent then return end

	if kind == "Part" then
		-- disableTrails must run BEFORE cancelNativeDescendants so the snapshot reads
		-- the authored Trail.Enabled instead of the about-to-be-disabled value.
		disableTrails(instance)
		cancelNativeDescendants(instance)
		if instance:IsA("BasePart") then
			pcall(function() instance.CFrame = FAR_CFRAME end)
		end

	-- Model keeps PivotTo: EmitModel moves clones through the pivot every frame,
	-- so the stored pivot tracks the parts. Lightning maintains WorldPivot per
	-- roll (applyRoll), so PivotTo stays correct there too.
	elseif kind == "Model" or kind == "Lightning" then
		disableTrails(instance)
		cancelNativeDescendants(instance)
		pcall(function() instance:PivotTo(FAR_CFRAME) end)

	elseif kind == "Rocks" or kind == "Rope" then
		-- Rig kinds move parts with BulkMoveTo, which never updates a
		-- PrimaryPart-less Model's STORED pivot. The first PivotTo(FAR) froze the
		-- pivot at FAR, so later releases computed a zero delta and left chunks
		-- visible on the ground inside the pool folder until the next acquire
		-- snapped them away. Park every part directly; never trust the pivot.
		disableTrails(instance)
		cancelNativeDescendants(instance)
		for _, chunk in ipairs(instance:GetChildren()) do
			if chunk:IsA("BasePart") then
				pcall(function()
					chunk.Anchored = true
					chunk.CanCollide = false
					chunk.CanTouch = false
					chunk.CFrame = FAR_CFRAME
				end)
			end
		end

	elseif kind == "Beam" then
		-- Snapshot Color + Transparency before disable so reacquire with an empty colorStates
		-- graph restores authored values instead of inheriting the prior cycle's last frame.
		pcall(function()
			if instance:GetAttribute("_pooledBeamColor") == nil then
				instance:SetAttribute("_pooledBeamColor", instance.Color)
			end
			if instance:GetAttribute("_pooledBeamTransparency") == nil then
				instance:SetAttribute("_pooledBeamTransparency", instance.Transparency)
			end
			instance.Enabled = false
		end)

	elseif kind == "PointLight" then
		pcall(function() instance.Enabled = false end)

	elseif kind == "Highlight" then
		pcall(function() instance.Enabled = false end)

	elseif kind == "TrailEmitter" then
		pcall(function() instance.Enabled = false end)

	elseif kind == "ImageLabel" then
		-- ImageLabel has no .Enabled; .Visible=false is the equivalent hide. Pool.release
		-- re-parents to the pool folder  -  Roblox tolerates GUI under
		-- non-ScreenGui ancestors (just doesn't render until reparented back).
		pcall(function() instance.Visible = false end)

	elseif kind == "Attachment" then
		-- Attachment stays at its real-world pose; cancel native PE/Trail
		-- descendants so stale delayed starts can't re-emit on the pooled
		-- attachment after the custom visual died. disableTrails runs first
		-- so its snapshot reads the authored Trail.Enabled instead of the
		-- about-to-be-disabled value (mirrors Part / Model branches).
		disableTrails(instance)
		cancelNativeDescendants(instance)
	-- Visible is intentionally untouched: toggling diverges pooled vs fresh
	-- (Visible defaults false on authored Attachments, exposing a 3D cross gizmo).
	end
end

function PoolHide.show(instance, kind)
	if not instance or not instance.Parent then return end
	-- Symmetric with hide: Beam/PointLight/Highlight/TrailEmitter Enabled flip kept self-contained in the pool contract.
	if kind == "Beam" then
		-- Restore authored Color + Transparency from snapshot before re-enable. Emit setup only
		-- writes Color/Transparency when a graph is non-empty (Emit.luau:582-583); without this
		-- restore, pooled Beams reused with no graph keep prior-cycle final-frame values.
		pcall(function()
			local priorColor = instance:GetAttribute("_pooledBeamColor")
			if priorColor ~= nil then instance.Color = priorColor end
			instance:SetAttribute("_pooledBeamColor", nil)
			local priorTrans = instance:GetAttribute("_pooledBeamTransparency")
			if priorTrans ~= nil then instance.Transparency = priorTrans end
			instance:SetAttribute("_pooledBeamTransparency", nil)
			instance.Enabled = true
		end)
	elseif kind == "PointLight" or kind == "Highlight" or kind == "TrailEmitter" then
		pcall(function() instance.Enabled = true end)
	elseif kind == "ImageLabel" then
		pcall(function() instance.Visible = true end)
	end
	-- Trail restore deferred to PoolHide.restoreTrails (caller sets new CFrame first).
end

-- Call AFTER setting the new spawn CFrame. Restores Trail.Enabled from snapshot. Safe on
-- fresh clones (no `_pooledTrailEnabled` attribute means no-op).
function PoolHide.restoreTrails(instance, kind)
	if not instance or not instance.Parent then return end
	if kind == "Part" or kind == "Model" or kind == "Attachment" or kind == "Lightning" or kind == "Rocks" or kind == "Rope" then
		restoreTrails(instance)
	end
end

return PoolHide
