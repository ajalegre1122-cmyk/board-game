-- GuiHost  -  resolve correct container for plugin-internal singleton ScreenGuis
-- (ScreenHost, TexturePin). Plugin = CoreGui (PluginGuiService capability).
-- Client LocalScript = LocalPlayer.PlayerGui (CoreGui write-blocked outside plugin).
-- Server = nil (no GUI rendering; caller no-ops).

local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Selection = game:GetService("Selection")

-- Same idiom Lifecycle.luau:11 uses; Selection:Get requires PluginOrOpenCloud capability.
local IS_PLUGIN = pcall(function() return Selection:Get() end)

local GuiHost = {}

function GuiHost.resolveContainer()
	if IS_PLUGIN then return CoreGui end
	if RunService:IsClient() then
		local lp = Players.LocalPlayer
		if lp then
			return lp:FindFirstChildOfClass("PlayerGui") or lp:WaitForChild("PlayerGui", 5)
		end
	end
	return nil
end

return GuiHost
