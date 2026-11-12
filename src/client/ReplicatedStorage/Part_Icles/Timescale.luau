--[[
	Timescale Mixin  -  runtime timescale override for live particles + raw ParticleEmitters.

	Public API (after :Activate):
	  :SetTimescale(item, scale, duration, permanent)
	     scale      -  0 = time stop, <0 = reverse, >0 = speed multiplier.
	     duration   -  seconds before revert to original (ignored when permanent).
	     permanent  -  true → never expires (duration ignored); false → timed via duration;
	                 false + duration=0 collapses to :ClearTimescale so toggling off uses one method.
	  :ClearTimescale(item)
	  :AbsoluteSetTimescale / :AbsoluteClearTimescale (recursive, mirrors AbsoluteEnable).

	Dispatch:
	  - Transformed (Part-Icles) items: write `_tsOverride` + `_tsOverrideUntil` attrs;
	    SetTimescale walks `Particle.ActiveEmits` to flip existing pData; emit mixins call
	    `Particle._seedTsOverride(pData, src)` so new emits during the window inherit; Update
	    mixins gate on `currentTime < pData._tsOverrideUntil` and fall back to `Graphs.Timescale`.
	  - Raw `ParticleEmitter` instances: write `.TimeScale` directly. Original value stashed
	    in `_origTimeScale` so concurrent SetTimescale calls don't lose it. `_tsGen` invalidates
	    stale `task.delay` restore closures so newer calls win.
]]

return function(Particle)

	-- Emit-site seeder. Stale attrs on src are harmless: Update mixin gate expires them lazily.
	function Particle._seedTsOverride(pData, src)
		if not src then return end
		pData._tsOverride = src:GetAttribute("_tsOverride")
		pData._tsOverrideUntil = src:GetAttribute("_tsOverrideUntil")
	end

	-- Native ParticleEmitter path. Stash original once, write override, schedule restore.
	local function _setNativePE(pe, scale, duration, permanent)
		if pe:GetAttribute("_origTimeScale") == nil then
			pcall(function() pe:SetAttribute("_origTimeScale", pe.TimeScale) end)
		end
		pcall(function() pe.TimeScale = scale end)
		-- Generation token: bump invalidates any pending stale restore closure.
		local gen = (pe:GetAttribute("_tsGen") or 0) + 1
		pcall(function() pe:SetAttribute("_tsGen", gen) end)
		if permanent == true then return end
		task.delay(duration, function()
			if not pe.Parent then return end
			if pe:GetAttribute("_tsGen") ~= gen then return end
			local orig = pe:GetAttribute("_origTimeScale")
			if orig ~= nil then
				pcall(function() pe.TimeScale = orig end)
				pcall(function() pe:SetAttribute("_origTimeScale", nil) end)
			end
			pcall(function() pe:SetAttribute("_tsGen", nil) end)
		end)
	end

	local function _clearNativePE(pe)
		local orig = pe:GetAttribute("_origTimeScale")
		if orig ~= nil then
			pcall(function() pe.TimeScale = orig end)
			pcall(function() pe:SetAttribute("_origTimeScale", nil) end)
		end
		-- Bump + clear gen so any pending task.delay closure from a prior timed call bails.
		local gen = (pe:GetAttribute("_tsGen") or 0) + 1
		pcall(function() pe:SetAttribute("_tsGen", gen) end)
		pcall(function() pe:SetAttribute("_tsGen", nil) end)
	end

	-- Apply a timescale override to a Transformed item or raw ParticleEmitter. See file header
	-- for scale / duration / permanent semantics + dispatch table.
	function Particle:SetTimescale(item, scale, duration, permanent)
		if not item then return end
		if typeof(scale) ~= "number" then return end
		local effectiveDuration
		if permanent == true then
			effectiveDuration = nil
		elseif typeof(duration) == "number" and duration > 0 then
			effectiveDuration = duration
		else
			self:ClearTimescale(item)
			return
		end
		if item:IsA("ParticleEmitter") then
			_setNativePE(item, scale, effectiveDuration, permanent)
			return
		end
		local until_ = (permanent == true) and math.huge or (os.clock() + effectiveDuration)
		pcall(function()
			item:SetAttribute("_tsOverride", scale)
			item:SetAttribute("_tsOverrideUntil", until_)
		end)
		local active = self.ActiveEmits
		for i = 1, #active do
			local pData = active[i]
			if pData and pData._sourceItem == item then
				pData._tsOverride = scale
				pData._tsOverrideUntil = until_
			end
		end
	end

	-- Remove timescale override from a Transformed item or raw ParticleEmitter. Inverse of
	-- SetTimescale; restores `Graphs.Timescale` (Transformed) or `_origTimeScale` (native PE).
	function Particle:ClearTimescale(item)
		if not item then return end
		if item:IsA("ParticleEmitter") then
			_clearNativePE(item)
			return
		end
		pcall(function()
			item:SetAttribute("_tsOverride", nil)
			item:SetAttribute("_tsOverrideUntil", nil)
		end)
		local active = self.ActiveEmits
		for i = 1, #active do
			local pData = active[i]
			if pData and pData._sourceItem == item then
				pData._tsOverride = nil
				pData._tsOverrideUntil = nil
			end
		end
	end

	-- Recurse like AbsoluteEnable. Transformed items + raw ParticleEmitters both terminal.
	function Particle:AbsoluteSetTimescale(item, scale, duration, permanent)
		if not item then return end
		if item:GetAttribute("Transformed") then
			self:SetTimescale(item, scale, duration, permanent)
			return
		end
		if item:IsA("ParticleEmitter") then
			self:SetTimescale(item, scale, duration, permanent)
			return
		end
		for _, child in item:GetChildren() do
			if item:IsA("BasePart") and child:IsA("BasePart") and not child:GetAttribute("Transformed") then
				continue
			end
			self:AbsoluteSetTimescale(child, scale, duration, permanent)
		end
	end

	-- Recursive ClearTimescale across `item` + transformed descendants.
	function Particle:AbsoluteClearTimescale(item)
		if not item then return end
		if item:GetAttribute("Transformed") then
			self:ClearTimescale(item)
			return
		end
		if item:IsA("ParticleEmitter") then
			self:ClearTimescale(item)
			return
		end
		for _, child in item:GetChildren() do
			if item:IsA("BasePart") and child:IsA("BasePart") and not child:GetAttribute("Transformed") then
				continue
			end
			self:AbsoluteClearTimescale(child)
		end
	end

end
