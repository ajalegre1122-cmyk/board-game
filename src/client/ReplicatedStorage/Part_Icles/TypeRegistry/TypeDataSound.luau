--[[
	TypeDataSound  -  Sound type definition (native Sound instance emitter; runtime in
	Modules/Part/Sound/). Merged into TypeData.Types at the bottom of TypeData.luau.

	The RenderTemplate is the user's Sound (SoundId and any authored effects stay on it); each
	emit plays a copy under a carrier at the source, a link, or Emit Into. Volume and
	PlaybackSpeed are envelopes over Lifetime; Lifetime 0 = the clip's own length.
]]

local Sound = {}

Sound.SoundProperties = {
	Volume        = { type = "NumberSequence", default = NumberSequence.new(0.5), attrName = "SndVolume" },
	PlaybackSpeed = { type = "NumberSequence", default = NumberSequence.new(1),   attrName = "SndPlaybackSpeed" },
	-- Timescale: see PartProperties.
	Timescale     = { type = "NumberSequence", default = NumberSequence.new(1),   attrName = "SndTimescale" },

	-- 0 = play the clip once and die when it ends (Looped clips need an explicit Lifetime).
	Lifetime       = { type = "NumberRange", default = NumberRange.new(0), nonNegative = true },
	Rate           = { type = "number",      default = 10 },
	TotalKeyFrames = { type = "number",      default = 100 },
	Enabled        = { type = "boolean",     default = false },
	RollOffMin     = { type = "number",      default = 10,    nonNegative = true },
	RollOffMax     = { type = "number",      default = 10000, nonNegative = true },
	Looped         = { type = "boolean",     default = false },
	-- Seconds into the clip to start from.
	StartOffset    = { type = "number",      default = 0, nonNegative = true },
	-- Play through SoundService (no position, heard everywhere on this client).
	Local2D        = { type = "boolean",     default = false },
}

Sound.Types = {
	Sound = {
		classCheck = function(item) return item:IsA("Sound") end,
		pDataType = "Sound",
		uiSection = "Sounds",
		properties = Sound.SoundProperties,

		resize = {
			scaleNumbers = { "RollOffMin", "RollOffMax" },
		},
		retime = {
			multiplyNumbers = { "Rate" },
			divideRanges = { "Lifetime" },
		},
		clipboard = {
			{name = "Emission", props = {"Rate", "Lifetime", "StartOffset", "Looped", "Local2D", "Timescale", "EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Sound", props = {"Volume", "PlaybackSpeed", "RollOffMin", "RollOffMax"}},
			{name = "Advanced", props = {"TotalKeyFrames"}},
			{name = "Events", props = {"OnEmit", "OnDeath", "OnDestruction"}},
		},
	},
}

return Sound
