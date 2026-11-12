--[[
	Log  -  console output gate shared by the plugin and the Part runtime.

	Log.enabled (default true) gates Log.print / Log.warn; error() is never gated.
	Plugin: the Settings panel's "Console Output" toggle sets it (SettingsToggles.luau).
	Standalone module: `require(Part_Icles).Log.enabled = false` silences the runtime.
]]

local Log = {}

Log.enabled = true

function Log.print(...)
	if Log.enabled then print(...) end
end

function Log.warn(...)
	if Log.enabled then warn(...) end
end

return Log
