--[[
	Snowboard Config: every number for the snowboard movement, camera and effects.
	Tune freely while playtesting; nothing else needs to change.

	Speeds are in studs per second (1 stud/s = 0.626 mph on the HUD). Pace is tuned like Mario & Sonic snowboard cross:
	a steady cruise you can read, crouching (W) for extra speed, and boosts as short bursts on top.
	  terminal speed on a slope  ~ sqrt(Gravity * sin(slope angle) / Drag)
	  with the values below: ~50 on a 10 deg slope, ~70 on 20 deg, ~85 on 30 deg, ~95 on 40 deg (crouching adds ~20%)
	  capped at MaxSpeed (100 = 63 mph). Cruise.BaseSpeed keeps you at 44 mph (70 studs/s) or more once rolling
	  (50 mph crouched), so a clean run averages ~85 studs/s and 2-3 minutes needs roughly 10,000 - 15,000 studs of track.
]]

local Config = {}

--// Physics //--
Config.Gravity = 75 -- pulls you down the slope while on the snow: how quickly slopes speed you up (was 140: a rocket to top
	-- speed in ~2 seconds). Lower = speed builds up more gradually. Jumps use AirGravity, so they don't change
Config.AirGravity = 150 -- pulls you down while in the air
-- a little glide in the air (like Mario & Sonic): a short hang at the top of a jump and a slightly slower fall.
-- Bumps and tiny hops aren't affected (only after AfterAirTime in the air), and a Jump Boost dive (W) ignores it
Config.Glide = {
	Enabled = true,
	AfterAirTime = 0.25, -- seconds in the air before the glide kicks in
	ApexSpeed = 10, -- near the top of the jump (moving up or down slower than this, studs/s)...
	ApexGravityScale = 0.5, -- ...gravity is this share of AirGravity: a little hang at the top
	FallGravityScale = 0.75, -- coming down: this share of AirGravity (1 = no glide, lower = floatier)
}
Config.HoverHeight = 3.25 -- root part height above the snow (the board sits 3.11 below the root)
Config.SnapDistance = 2.2 -- how far the snow can drop away and still count as "on the ground"
Config.MaxGroundAngle = 72 -- normal riding limit (degrees). Steeper SNOW is a sidewall you can ride if you're fast enough (Config.WallRide)
Config.StickForce = 40 -- extra pull into the snow so you hold banked walls
Config.MaxDropSpeed = 28 -- the fastest the board is pulled down onto the snow over crests

--// Speed //--
Config.Drag = 0.0052 -- air resistance (bigger = lower top speed on each slope)
Config.SnowFriction = 0.025 -- rolling friction on the snow
Config.MaxSpeed = 100 -- slopes can't push you past this (boosts can, briefly). 100 = 63 mph (was 125 = 78 mph)
Config.OverSpeedDecel = 20 -- how fast boosted speed above MaxSpeed bleeds back down (studs/s per second): a boost lasts ~1 second

--// Base speed (cruise) //--
-- Once you're rolling, the board holds at least BaseSpeed on flat ground and gentle slopes (arcade style):
-- below it, air drag and snow friction don't slow you down and the board speeds back up. Steeper slopes still
-- take you faster. Braking (S) or turning sideways switches it off, so you can still slow down, crawl or stop.
Config.Cruise = {
	BaseSpeed = 70, -- studs/s the board settles at on flats and gentle slopes (70 = 44 mph on the HUD; was 96 = 60 mph)
	TuckSpeed = 80, -- ...and while crouching (holding W): crouch for speed, like Mario & Sonic (80 = 50 mph)
	Accel = 20, -- how quickly it gets back up to BaseSpeed (studs/s per second)
	StartSpeed = 20, -- only kicks in once you're moving at least this fast (push off with W at the start)
}

--// Boosts //--
-- Boost pads: any part tagged "BoostPad" (the chevron Ramp pads). Rings: parts tagged "BoostRing".
Config.Boost = {
	PadAdd = 25, -- a pad adds this much speed...
	PadMinSpeed = 112, -- ...and leaves you at least this fast (112 = 70 mph; was 160 = 100 mph)
	RingAdd = 28,
	RingMinSpeed = 115,
	RingLift = 0.12, -- rings aim you slightly upward
	RingDepth = 5, -- how close to the ring's plane counts as passing through (studs)
	RingHoleShare = 0.85, -- share of the ring's radius that counts as the hole
	Cooldown = 0.6, -- seconds before another boost can trigger
	AirDragFreeTime = 1.2, -- after a boost, no air drag for this long
	FovKick = 10, -- extra camera FOV for a moment when a boost hits (on top of the speed FOV)
}

-- Speed Boost ability (Deku's ultimate): you ride SpeedMultiplier x as fast as you normally would for Duration seconds
-- (both set on the ability in Config.Abilities). Everything rides the same, just faster: jumps go further, not higher.
Config.SpeedBoost = {
	RampIn = 0.25, -- seconds to get up to full speed when it starts
	FadeOut = 0.8, -- seconds to ease back to normal speed when it ends
	NoStacking = true, -- speed from abilities never stacks. A speed boost tops out at its own multiplier x your normal
		-- top speed (Config.MaxSpeed = 100): Deku's 2x Speed Boost can reach 200 and never more, however you got there (boost
		-- pads, slopes, One For All Dash on top: none of it adds past that). A dash on its own tops out at normal top speed +
		-- the dash (One For All Dash: 170). Slopes and pads on their own work as before. Dio's Time Skip (a blink) is exempt.
		-- false = no limit (2x Speed Boost + pads + dash used to reach 250+)
}

-- One For All Dash (Deku's Skill2): a quick burst of DashSpeed extra speed for DashTime seconds (both set on the ability
-- in Config.Abilities), in the way you're going. Then it fades back to your normal speed: the burst doesn't linger.
Config.Dash = {
	RampIn = 0.06, -- seconds to reach the full burst (quick = snappy)
	FadeOut = 0.4, -- seconds to fade back to your normal speed after DashTime
}

-- what getting hit by a thrown ability does (an ability's Hit.Kind). The server decides who got hit (AbilityServer); the
-- player who got hit slows down / is stunned on their own screen, and everyone sees the stun animation on them.
Config.Hits = {
	Kunai = { -- slowed down while the stun animation plays
		SlowMultiplier = 0.5, -- ride at this share of your speed...
		SlowTime = 0.5, -- ...for this long (StunAnim is 0.5 s)
		RecoverTime = 0.3, -- then back up to full speed over this long
		Animation = "StunAnim",
		Shake = 0.35, -- camera jolt for whoever got hit
	},
	RasenShuriken = { -- fully stunned (stun + dazed animation), then slowed while you recover
		StunTime = 1.4, -- seconds stunned: nearly stopped, can't steer, jump or use abilities
		StunMultiplier = 0.08, -- share of your speed while stunned
		RecoverFrom = 0.45, -- after the stun you're back at this share of your speed...
		RecoverTime = 1.6, -- ...and up to full speed over this long
		Screen = true, -- a quick flash + blur on the stunned player's screen
		Shake = 1, -- camera jolt for whoever got hit
	},
	Chidori = { -- touched by Sasuke's Chidori: a weaker Rasen Shuriken stun (shorter, not as slow), soft screen effect
		StunTime = 0.7,
		StunMultiplier = 0.15,
		RecoverFrom = 0.55,
		RecoverTime = 0.9,
		Screen = "Soft", -- a softer flash + blur than the Rasen Shuriken's
		Shake = 0.5,
	},
	Knives = { -- hit by Dio's 3 knives: stunned (stun + dazed animation), then slowed while you recover
		StunTime = 1, -- between the Chidori (0.7) and the Rasen Shuriken (1.4)
		StunMultiplier = 0.1,
		RecoverFrom = 0.5,
		RecoverTime = 1.1,
		Screen = "Soft",
		Shake = 0.6,
	},
}

-- Jump Boost ability (Deku's Skill1): how high is JumpHeight on the ability in Config.Abilities. While you're up there:
Config.SuperJump = {
	DiveGravity = 180, -- hold W: extra pull down so you dive back to the snow (normal air gravity is AirGravity = 150; was 350)
	DivePitchMin = 45, -- hold W: the board tips nose-down this far (degrees) as the dive starts...
	DivePitchMax = 60, -- ...and up to this far as you fall steeper (it follows how steeply you're actually falling; was 70)
	DiveRampIn = 5, -- hold W: how quickly the dive builds up (pull + tilt ease in instead of snapping)
	DiveRampOut = 6, -- let go of W: how quickly it eases back off
	FlareTime = 0.45, -- seconds before you'd hit the snow that the dive starts easing off and the board levels out
	PitchResponse = 5, -- how quickly the board's tilt follows the dive (the dive itself already eases in)
	PitchReturn = 12, -- how quickly it levels out once you land
	LandingShake = 0.5, -- landing from a Jump Boost shakes the camera at most this much (0-1; 1 = a full hard-landing shake)
}
Config.Tuck = { -- hold W (crouch)
	DragMultiplier = 0.7, -- less air resistance = higher top speed
	Accel = 8, -- small extra push while tucked
	TurnMultiplier = 0.8, -- crouching turns a bit wider (like Mario & Sonic: crouch = faster but harder to turn)
}
Config.Push = { -- hold W when slow (skating off the start / across flats)
	Accel = 32,
	MaxSpeed = 30,
}
Config.Brake = { -- hold S
	Decel = 70,
	TurnMultiplier = 1.4, -- braking = tighter turns
	DownhillMinSpeed = 4.8, -- on a downhill you can't slow below this (studs/s). 4.8 = 3 mph on the HUD
	DownhillAngle = 3, -- slopes gentler than this (degrees) count as flat: you can fully stop there
	DownhillBrakeFade = 6, -- on a downhill, braking eases off over the last this-many studs/s above the minimum,
		-- so you settle into a crawl (a bit faster on steeper snow, like SKI) instead of snapping to one number. 0 = snap
	CreepDownhillShare = 0.3, -- while crawling across the hill you also drift this much straight down it, so you never stall sideways
}

--// Carving //--
Config.TurnRateSlow = 0.6 -- radians/second the board turns when slow: like SKI, steering is stiff at a crawl
Config.TurnRateFast = 2.2 -- radians/second at TurnSpeedRef and above: the faster you go, the quicker it turns (lower = softer steering)
Config.TurnSpeedRef = 70 -- speed (studs/s) where turning reaches TurnRateFast; it builds up evenly below this
Config.SteerSmoothing = 20 -- how fast your steering input ramps in/out (higher = snappier edge-to-edge, lower = smoother)
Config.TurnResponse = 18 -- how fast the board's turn builds up (higher = snappier, lower = heavier)
Config.Grip = 6.5 -- how fast your travel direction follows where the board points (radians/second)
Config.LowSpeedGrip = 11 -- grip when slow, so you can line up easily
-- Speed retention: normal turns keep their speed. Only a sharp hard cut (turning hard with the board swung
-- far from straight downhill) bleeds a tiny bit, and only a real skid (board sliding sideways) scrubs speed.
Config.HardCut = {
	Bleed = 0.05, -- share of speed lost per second at the sharpest cut (0.05 = 5% per second, only while cutting)
	StartAngle = 40, -- a turn counts as a hard cut once the board swings past this angle from straight downhill...
	FullAngle = 60, -- ...with full bleed by this angle (and only while you're actually turning, not just riding across)
}
Config.SkidAngle = 8 -- board within this many degrees of where you're going = a clean carve, no speed lost
Config.SkidScrub = 0.6 -- how much a real skid (sliding sideways, e.g. a crooked landing) scrubs off
Config.EdgeHold = 0.92 -- how much of the sideways slope pull the board edge holds (1 = never slips)

--// Going uphill //--
-- Riding UP a slope (side banks, curve walls, hills) is pure momentum: no air drag, snow friction, sideways brake,
-- cruise or skating push while you're pointing up it. Only gravity slows you (and S if you brake), so the faster
-- you come in, the further up you go, and then you slide back down.
Config.Uphill = {
	GravityScale = 1, -- how hard gravity slows you going up (1 = natural; lower = you carry further up)
}

--// Sidewall boost //--
-- Riding up onto a side wall in a curve gives you a little boost instead of slowing you down: a small kick of speed
-- as you reach the wall, then the board keeps gently speeding up while you ride up / along it (gravity doesn't slow you
-- on the way up). Only side walls count (not a hill straight ahead). Coming back down the wall, gravity speeds you up as normal.
Config.WallBoost = {
	Enabled = true,
	StartAngle = 30, -- side slopes steeper than this (degrees) start to count as a side wall...
	FullAngle = 55, -- ...fully by this angle
	Kick = 8, -- instant speed added when you reach a side wall (studs/s, 8 = 5 mph)
	Accel = 18, -- extra speed per second while riding up / along the wall (studs/s per second)
	MaxSpeed = 108, -- the wall boost won't take you past this (studs/s, 108 = 68 mph). Raise it with MaxSpeed
	Cooldown = 1.5, -- seconds before reaching a wall can kick again (you also have to leave the wall first)
	FxShare = 0.4, -- screen effects for the kick (FOV kick, speed lines) compared to a boost pad (0 = none, 1 = same)
}

--// Slow climb (crawl) - OFF //--
-- Old option: pointing up a slope and holding W, you creep up it even with no speed left.
-- Turned off so uphill is pure momentum. Set Enabled = true to bring the crawl back.
Config.Climb = {
	Enabled = false,
	Speed = 11, -- studs/s you creep up a gentle slope while holding W (11 = 7 mph)
	SteepSpeed = 5, -- studs/s on the steepest climbable slope (5 = 3 mph): the steeper, the slower
	MaxAngle = 85, -- steepest snow you can creep up (degrees). While climbing, the board also holds onto snow this steep,
		-- so short near-vertical lips (like folds in the snow mesh) can be crawled over. Normal riding still treats
		-- anything steeper than MaxGroundAngle (72) as a wall
	Facing = 0.5, -- how straight up the slope the board must point (0.5 = within 60 degrees of straight up)
}

--// Turn limit (like SKI) //--
-- Holding A / D turns you at most MaxAngle away from straight downhill, so you stop sideways across the hill
-- instead of spinning round onto your back. Turning sideways also brakes you (down to the crawl on a downhill).
Config.TurnLimit = {
	MaxAngle = 90, -- degrees from straight downhill. 90 = fully sideways. 180 = no limit
	EaseZone = 20, -- the turn eases off over the last this-many degrees, so it settles instead of snapping
	FollowRate = 3, -- how fast the remembered "downhill" direction follows the snow under you (smooths out bumps)
	FollowMinSpeed = 20, -- "downhill" is only updated while riding down at least this fast (studs/s), so riding up a hill
		-- or crawling at the foot of one doesn't flip it, and you can still turn to face the hill and climb it
	FollowMaxAngle = 50, -- "downhill" only follows the slope under you when that slope points within this many degrees of the
		-- old downhill or of the way you're riding. A side bank points across the course, so riding along it
		-- doesn't make the board count as sideways (no sideways brake on banks and curve walls)
	ReturnRate = 180, -- degrees/second the board is eased back if it ends up past the limit (e.g. after a landing)
	SideBrake = 45, -- extra slowdown (studs/s per second) with the board held fully sideways. It only kicks in once the board
		-- settles there (holding the turn), so a quick hard cut swinging through sideways just bleeds a tiny bit. 0 = no sideways brake
	SideBrakeStart = 55, -- sideways braking starts past this angle from downhill, so normal carving isn't slowed
}

--// Snow, sidewall riding and track borders //--
-- Only white snow can be ridden up steep walls: Terrain snow (the white Sand / Snow / Glacier terrain) and parts made of
-- Sand or Snow material (or tagged "Snow"). On snow you can carve right up the sidewalls in curves, all the way to
-- vertical, as long as you're going fast. Anything that ISN'T snow (rock walls, green ground, stone curbs) becomes a
-- border once it gets steeper than Border.Angle: the board won't ride up it, you slide along it instead.
-- Boost ramps (tagged "BoostPad") and parts tagged "Rideable" are never borders.
Config.Snow = {
	TerrainMaterials = { Sand = true, Snow = true, Glacier = true }, -- terrain materials that count as snow
	PartMaterials = { Sand = true, Snow = true }, -- part / mesh materials that count as snow
	Tag = "Snow", -- tag any other part with this (Tag Editor) to make it count as snow
}
Config.WallRide = {
	MaxAngle = 100, -- steepest snow you can ride (degrees from flat). 90 = vertical, a bit more = slight overhangs
	MinSpeed = 45, -- on snow steeper than MaxGroundAngle (72) you need at least this speed (studs/s, 45 = 28 mph) or you peel off
	PeelPush = 10, -- how hard you're pushed off the wall when you peel off (studs/s)
	PeelTime = 0.4, -- after peeling off, seconds before you can stick to a steep wall again
	StickForce = 70, -- pull into the snow on vertical walls (blends up from the normal StickForce on gentle slopes)
	Arc = 0.9, -- radians/second gravity swings the board back down a steep wall, so wall rides arc up and come back down
		-- (0 = keeps going the way you entered; you can always steer against it)
}
Config.Border = {
	Enabled = true, -- false = no borders: non-snow surfaces are rideable up to MaxGroundAngle like before
	Angle = 40, -- non-snow surfaces steeper than this (degrees) are borders (rock walls are 50+, gentle green ground stays rideable)
	Reach = 3, -- how far ahead / to the sides the board looks for a border (studs, plus a little more at speed)
	RayHeight = 1.5, -- how high above the snow it looks (studs): low enough to catch the foot of a wall
	Gap = 2, -- closest the board gets to a border (studs); closer gets pushed back out
	Push = 8, -- how firmly it's pushed back out (studs/s per stud too close)
	SpeedLoss = 0.35, -- share of speed lost running straight into a border; you then slide along it. A glancing hit loses
		-- much less, and scraping along it afterwards costs nothing
	TurnAway = 10, -- how fast the board turns to run along the border instead of into it
	RideableTag = "Rideable", -- tag a part with this to make it never a border
}

--// Lean / banking //--
-- Like Mario & Sonic: the rider leans by how hard the board is actually carving (speed x turn rate),
-- so quick swerves at speed tip you right over and gentle turns barely lean. The board stays on the snow.
Config.MaxLean = 42 -- degrees the rider leans into the hardest carve
Config.LeanCarveRef = 160 -- carve strength (speed x turn rate) that gives full lean. Lower = leans over sooner
Config.LeanSmoothing = 14 -- how fast the lean follows the carve (higher = snappier edge changes)
Config.BoardBelowRoot = 3.11 -- how far the board sits below the root part; keeps the board on the snow while leaning
Config.NormalSmoothing = 11 -- how fast the board tilts to match the snow under it
Config.Responsiveness = 30 -- how quickly the body follows the board's target rotation

--// Air //--
Config.JumpSpeed = 46
Config.JumpCooldown = 2 -- seconds after a jump before you can jump again (ramps and drops don't count, only Space)
Config.JumpBuffer = 0.15 -- press jump this long before landing and it still counts
Config.CoyoteTime = 0.12 -- jump this long after leaving the snow and it still counts
-- Air control: A / D gently bend your flight path while airborne, and the board turns with it so you land
-- lined up. Speed and forward momentum are kept; the path only bends a little.
Config.AirTurnRate = 1.0 -- radians/second your flight path bends in the air (1.0 = about 40 degrees over a 1 second jump)
Config.AirTurnResponse = 6 -- how quickly air steering builds up (lower = gentler)
Config.AirForwardDrag = 0.1 -- share of normal air drag on your forward motion in the air (1 = full), so momentum carries through jumps
Config.BadLandingAngle = 55 -- land more than this many degrees off your travel direction...
Config.BadLandingSpeedKeep = 0.65 -- ...and keep only this share of your speed
-- Clean landings keep your speed: the drop down from a jump doesn't eat your momentum.
Config.Landing = {
	KeepTakeoffSpeed = 0.95, -- land at least this share of the speed you took off with (1 = no loss at all, 0 = off).
		-- Only as much as you still had in the air (falling counts), so you never land faster than you were flying
}

--// Sounds //--
-- Roblox's built-in character sounds keep playing footsteps as the body moves; these are muted while on the board
Config.MutedCharacterSounds = { Running = true, Climbing = true }

--// Respawn //--
Config.KillY = -1600 -- fall below this height and you're put back on the track
Config.MaxAirTime = 3.5 -- in the air longer than this (flew off the track) = put back on the track
Config.RecoverStepsBack = 4 -- put back where you were ~2 seconds earlier (safe spots are saved every 0.5s)
Config.RecoverSpeed = 40 -- speed you keep after being put back
Config.ResetKey = Enum.KeyCode.R

--// Camera //--
Config.Camera = {
	DistanceSlow = 11, DistanceFast = 19, -- studs behind the rider
	HeightSlow = 4.5, HeightFast = 4.2, -- studs above the rider (low at speed: the snow rushes past closer to the lens)
	-- FOV (how wide the view is) grows steadily with speed, so speeding up, crouching and boosts each feel different:
	-- about 70 standing still, 87 at the 44 mph cruise, 94 at top speed (63 mph) and 97+ on a boost,
	-- plus Boost.FovKick for a moment when a boost hits. (It used to sit at 104-119 the whole run.)
	FovSlow = 70, -- FOV when slow / standing still
	FovFast = 100, -- FOV at FovSpeedRef and above (Roblox allows up to 120). Raise for a wilder, more stretched look
	FovSpeedRef = 125, -- speed (studs/s) where the FOV reaches FovFast (125 = 78 mph: only big boosts get there)
	FovSharpness = 6, -- how quickly the FOV follows your speed (higher = snappier, lower = smoother)
	FovAccelKick = 8, -- extra FOV while you're gaining speed (pumps wider as you accelerate, settles when you hold speed)
	FovAccelRef = 50, -- gaining this many studs/s per second gives the full FovAccelKick
	DollyZoom = 0.75, -- as the FOV widens the camera moves in, so the world stretches past while the rider stays big
		-- (0 = off, 1 = rider stays exactly the same size)
	SpeedRef = 100, -- full camera zoom-out (distance + height) at this speed (top speed)
	LookAhead = 10, -- the camera aims this far ahead of the rider
	FollowSharpness = 7, -- how tightly the camera follows (higher = stiffer)
	TurnSharpness = 2.5, -- how quickly the camera swings round in turns. Low = it keeps looking down the course
		-- while you swerve, so you see the rider carve left and right (like Mario & Sonic). Higher = follows every turn
	HeadingShare = 0.1, -- how much the camera follows where the board points vs where you're going (0 = only travel)
	RollFactor = 0.45, -- share of the rider's lean the camera tilts with (banks into carves)
	MaxRoll = 12, -- degrees
	LandingShake = 0.7, -- shake on hard landings (first version: 0.9)
	BoostShake = 0.2, -- shake when a boost hits (first version: 0.25)
	-- the camera gets left behind for a moment, then catches up (whoosh)
	AccelPullBack = 2.5, -- extra studs behind while you're speeding up hard
	BoostPullBack = 4, -- extra studs behind when a boost hits (eases back in)
	-- high-speed rumble: a smooth camera shudder that builds as you go faster (like the first version, a bit softer)
	RumbleStart = 88, -- studs/s where it starts (88 = 55 mph: fast crouched runs and boosts, not the cruise)
	RumbleFull = 125, -- studs/s for the full rumble (boosts)
	RumbleAmount = 0.38, -- how far the camera shudders (studs; first version: 0.5)
	RumbleRoll = 0.9, -- how much it rocks side to side (degrees; first version: 1.2)
	RumbleSpeed = 16, -- how fast it shudders (higher = buzzier; first version: 18)
	AccelSmoothing = 2.5, -- how smoothly the camera reacts to speeding up (FOV punch, pull-back, shake). Lower = calmer
	DiveFollow = 0.6, -- Jump Boost dive (hold W): how much of the board's nose-down tilt the camera follows (1 = all of it, 0 = off; was 0.85)
	DivePullBack = 4, -- ...and how much further back it sits while diving (studs), so you see the snow coming
}

--// Speed / wind screen effect (SpeedFX) //--
-- Fullscreen wind streaks, stronger the faster you go. The middle of the screen always stays clear so you can see the track.
Config.SpeedFX = {
	Style = "Noise", -- "Noise" = soft cloudy streaks bursting out from the middle (like the After Effects reference video)
		-- "Lines" = the older sharp speed lines + wind wisps from the screen edges (the Line / Wisp numbers below)
	StartSpeed = 60, -- studs/s where it starts to show (60 = 38 mph: light at the 44 mph cruise, stronger as you speed up)
	FullSpeed = 110, -- studs/s for the full effect (110 = 69 mph: boosts and big drops)
	AccelBoost = 0.5, -- extra strength while you're gaining speed (0 = off)
	AccelRef = 60, -- gaining this many studs/s per second counts as fully "speeding up"
	BoostBurst = 1, -- extra strength for a moment when a boost hits
	BurstFade = 2.5, -- how quickly that burst fades (higher = shorter)
	Smoothing = 6, -- how quickly the effect fades in and out
	ClearCenter = 0.17, -- at full strength, streaks stop this far from the middle (0 = centre, 1 = screen corner)
	ClearCenterLow = 0.32, -- at low strength they stay further out (above ~0.5 only the corners would show)
	Vignette = 0.6, -- dark edge glow at full strength, so the white streaks pop on bright snow (0 = off, 1 = black edges)
	VignetteColor = Color3.fromRGB(10, 14, 24),
	-- sharp anime speed lines
	Lines = 90, -- how many at full strength
	LineOpacity = 0.9, -- how solid the brightest lines are (0-1)
	LineColor = Color3.fromRGB(255, 255, 255),
	LineWidthMin = 2, LineWidthMax = 6, -- thickness in pixels (on a 1000 px tall screen)
	LineLifeMin = 0.08, LineLifeMax = 0.22, -- how long each line flickers on screen (seconds)
	-- soft wind wisps
	Wisps = 20, -- how many at full strength
	WispOpacity = 0.45, -- how visible they are (0-1, keep fairly low: they're meant to be soft)
	WispColor = Color3.fromRGB(225, 238, 255),
	WispWidthMin = 16, WispWidthMax = 55, -- thickness in pixels (on a 1000 px tall screen)
	WispLifeMin = 0.3, WispLifeMax = 0.6, -- seconds each wisp takes to rush past
	WispDrift = 0.35, -- how far outward a wisp travels during its life
	-- soft noise streaks (Style = "Noise"): painted once when the game starts, with the same recipe as the
	-- After Effects reference (Fractal Noise -> Polar Coordinates -> Unmult). Changes here need a new playtest.
	NoiseOpacity = 1, -- how solid the brightest streaks are at full strength (0-1)
	NoiseColor = Color3.fromRGB(255, 255, 255),
	NoiseStreaks = 3.8, -- how many big streaks around the circle (about 6x this: 3.8 = ~24)
	NoiseLength = 1.4, -- how often a streak breaks up along its length (lower = longer, smoother streaks)
	NoiseDetail = 5, -- layers of finer, cloudier detail (After Effects "Complexity")
	NoiseBrightness = 0.36, -- overall level (After Effects "Brightness"): lower = bigger gaps between streaks
	NoiseContrast = 0.36, -- (After Effects "Contrast"): higher = harder, brighter streaks with darker gaps
	NoiseHoleSoftness = 0.2, -- how soft the edge of the clear middle is
	NoiseFrames = 6, -- different streak pictures it cycles through (more = less repetitive, takes longer to paint)
	NoiseResolution = 512, -- picture size in pixels (256 = softer and quicker to paint, 1024 = max)
	NoiseLayers = 4, -- streak pictures flowing outward at once, evenly staggered (more = smoother flow, 2-6)
	NoiseLifeSlow = 0.7, NoiseLifeFast = 0.3, -- seconds each one takes to flow out (fade in, grow, fade out) when slow / at full strength
	NoiseZoomFrom = 0.8, NoiseZoomTo = 1.9, -- how big each picture starts and ends, so the streaks rush outward past you
	NoiseZoomEase = 2, -- 1 = steady growth; higher = starts slow near the middle and speeds up toward the edges
	NoiseSpin = 12, -- degrees each picture can twist over its life (a gentle swirl)
	NoiseSway = 0.05, -- how far the whole wind tunnel leans against your carving (share of the screen width)
	NoiseExtraLines = 45, -- sharp anime speed lines flickering in from the edges on top of the soft streaks (0 = none)
}

--// Animations //--
-- For the live game, publish each animation (Animation Editor > Publish) and paste its id here,
-- e.g. Idle = "rbxassetid://1234567890". Empty = use the saved KeyframeSequence (works in Studio only).
Config.AnimationIds = {
	Idle = "", Forward = "", Left = "", Right = "",
	Jump = "", Float = "", Land = "",
}
-- where the saved animations live (rig name in ReplicatedStorage.BoardAssets.Rigs, then the animation name)
-- All from the Luffy board rig (Board2), which matches the LuffyBoard on StarterCharacter.
Config.AnimationSources = {
	Idle = { "Board2", "Idle" }, Forward = { "Board2", "Forward" },
	Left = { "Board2", "Left" }, Right = { "Board2", "Right" },
	Jump = { "Board2", "Jump" }, Float = { "Board2", "Float" }, Land = { "Board2", "Land" },
}
Config.Animation = {
	SteerThreshold = 0.3, -- steering past this plays Left / Right
	RideSpeed = 18, -- faster than this (going straight) plays Forward, slower plays Idle
	Fade = 0.15, -- crossfade time between poses (short = snappy edge-to-edge)
}

--// Board tester (testing only) //--
-- Small collapsible panel at the bottom-left, above the controls line. Click its header (or press ToggleKey)
-- to open it, then click a board (or press 1-5 while it's open): the board model and its animation set swap
-- on your character, so you can compare the animations. Only you see the swap (it's done on your screen only).
Config.BoardTester = {
	Enabled = true, -- false = no panel, always the normal Luffy board
	StudioOnly = true, -- only show it in Studio playtests (the saved test animations only play in Studio anyway)
	StartOpen = false, -- start collapsed so it takes little space
	ToggleKey = Enum.KeyCode.B, -- opens / closes the panel
}
-- The boards in the panel, top to bottom. Rig = model in ReplicatedStorage.BoardAssets.Rigs, Part = its board part,
-- FxPart = part the snow spray sits on (if not Part), AnimNames = slot -> animation name when the rig saved it
-- under a different name, or { "OtherRig", "Name" } to borrow one from another rig.
-- Vfx = the board's effects model in ReplicatedStorage.BoardAssets.VFXBoards, VfxDeck = the board mesh inside that model
-- (the effects are lined up around it). Luffy's effects are already built into StarterCharacter.
-- Default = the board already on StarterCharacter (uses AnimationIds / AnimationSources above).
Config.TestBoards = {
	{ Name = "Luffy", Rig = "Board2", Part = "LuffyBoard", Default = true },
	{ Name = "Goku (Nimbus)", Rig = "Nimbus", Part = "Nimbus", AnimNames = { Float = "Floating" },
		Vfx = "NimbusBoard", VfxDeck = "Nimbus" },
	{ Name = "Kurapika", Rig = "Board5", Part = "Handle", FxPart = "Plane.001",
		Vfx = "KurapikaBoard", VfxDeck = "Plane.001" },
	-- these two have no air animations of their own: they borrow Kurapika's (Board5) Jump / Float / Land
	{ Name = "Goku (board)", Rig = "Board4", Part = "Board",
		AnimNames = { Jump = { "Board5", "Jump" }, Float = { "Board5", "Float" }, Land = { "Board5", "Land" } },
		Vfx = "GokuBoard", VfxDeck = "Plane.005" },
	{ Name = "Itachi", Rig = "Board3", Part = "Board",
		AnimNames = { Jump = { "Board5", "Jump" }, Float = { "Board5", "Float" }, Land = { "Board5", "Land" } },
		Vfx = "ItachiBoard", VfxDeck = "Plane.008" },
}

--// Abilities //--
-- Each character has 2 skills and an ultimate. The ability bar (bottom-middle, under the timer) shows your character's 3 slots:
-- Skill1 on the left, the Ultimate in the middle (bigger), Skill2 on the right. Pressing a key or tapping a slot plays the
-- button press, starts its cooldown and plays its effects (Config.AbilityVFX below). What an ability actually DOES to your
-- ride lives in Snowboard.Abilities: so far Deku's 3 and Naruto's 3 (Kunai Throw / Rasen Shuriken hits: Config.Hits); the rest are effects only for now.
--   Cooldown = seconds for this ability (optional; otherwise Cooldowns below)
--   Duration = seconds a lasting effect stays on (auras, Sharingan eyes, Chidori arm, 500 IQ glow, Za Warudo grey world)
--   Icon  = image for the slot ("rbxassetid://..."); empty = shows the ability's initials (or Short)
--   Anim  = saved animation in BoardAssets.Rigs.AbilitiesBoard.AnimSaves to use later
--   Vfx   = effect in BoardAssets.SkillVFX to use later
--   Rarity = Rare / Epic / Legendary / Mythic (nil = no badge)
--   JumpHeight = Jump Boost: how many times higher than a normal jump
--   SpeedMultiplier = Speed Boost: how many times faster you ride (for Duration seconds)
--   DashSpeed / DashTime = One For All Dash: extra speed (studs/s) and how long it's held (seconds)
--   BusyTime = (optional) seconds using it locks the other slots, instead of its animation's length (Busy above)
--   Hit = thrown at the closest rider / dummy in front: { Kind = a Config.Hits entry, Release = the Config.AbilityVFX.Timings
--         moment it leaves the hand, Speed = the Config.AbilityVFX speed it flies at }. The server works out the hit.
--   Touch = { Kind = a Config.Hits entry, Radius = studs, EndOnHit }: for Duration, anyone that close gets hit (server checks);
--         EndOnHit = it ends on the first hit (the speed boost too)
--   Dodge = "Base": other riders' basic moves (Skill1 / Skill2) that would hit you are dodged for Duration; true = everything
--         (server checks)
--   Swap = { Range = studs }: at the clap you swap places with the closest rider / dummy that close (server moves you)
--   NoCooldowns = seconds: after its animation, your skills have no cooldowns for this long (server checks too)
--   Copy = { Range = studs, Window = seconds }: copies a random nearby rider's random basic move into this slot; use it
--         within Window seconds. This slot's cooldown starts once it's used (or runs out). The server picks it.
Config.Abilities = {
	Enabled = true,
	DefaultCharacter = "Naruto",
	Keys = { Skill1 = Enum.KeyCode.Q, Ultimate = Enum.KeyCode.F, Skill2 = Enum.KeyCode.E },
	Cooldowns = { Skill1 = 5, Skill2 = 5, Ultimate = 10 }, -- default cooldowns in seconds (test values for now). The
		-- ultimate uses UltCharge below instead (Ultimate here only counts if UltCharge is set to nil)
	-- the ultimate CHARGES UP instead of having a cooldown (like Overwatch): it fills while you ride, plus a few % each
	-- time you use a skill. 100% = ready (it glows); using it empties it. The server keeps everyone's charge (nobody can
	-- fake it) and puts it on the player as the "UltCharge" attribute (0-100), which the ability bar shows.
	-- Aim: 1-2 ultimates a race. Riding alone fills it in 100 / PerSecond = 80 s. Using your skills whenever they're
	-- ready adds about 2 x SkillBonus % a second on top, whatever the character: full in about 57 s.
	-- Set UltCharge = nil to go back to a plain cooldown (Cooldowns.Ultimate).
	UltCharge = {
		PerSecond = 1.25, -- % a second, just from riding
		SkillBonus = 0.25, -- using a skill gives this many % per second of that skill's cooldown: a 20 s skill = +5%,
			-- a 5 s one (Todo's) = +1.25%. So short-cooldown skills can't be spammed for charge. None during 500 IQ
		StartAt = 0, -- % you start with when you join, or switch character
		PauseWhileActive = true, -- no charging while your own ultimate is still going (its Duration), or while you hold a
			-- move copied with Sharingan Copy
		CopyFailRefund = 100, -- Sharingan Copy with nobody near to copy: % given back (100 = it cost nothing)
		StudioFillOnSwitch = true, -- Studio playtests only: picking a character with the test arrows fills it, so you
			-- can try ultimates without waiting (the live game and Team Test always start at StartAt)
		Leeway = 0.5, -- % of lag allowed when the server checks it's full
	},
	-- other players see your abilities: your client tells the server, which checks each use before passing it on
	-- (ServerScriptService.Snowboard.AbilityServer)
	Network = {
		PerSecond = 3, -- ability messages a player can send per second (any more are ignored)...
		Burst = 6, -- ...with up to this many in a quick burst
		CooldownLeeway = 0.3, -- seconds of lag allowed when the server checks a cooldown
		BusyLeeway = 0.15, -- seconds of lag allowed when the server checks the busy lock (Busy below)
	},
	-- while you're using an ability (its animation is playing) the other slots are locked, so skills can't be spammed
	-- back to back. Only the move itself counts, not lasting effects (Speed Boost's 7 seconds, auras...)
	Busy = {
		NoAnimation = 0.3, -- abilities with no animation (Speed Boost, Chakra Mode, Sharingan...) lock the others this long
		Extra = 0.05, -- added on after an ability's animation ends
	},
	SlotSize = 64, -- skill slot size (pixels)
	UltSize = 86, -- ultimate slot size (pixels): a bit bigger
	Position = UDim2.new(0.5, 0, 1, -50), -- where the bar sits: bottom-middle of the screen, just clear of the controls line
		-- (the run timer moves up to sit just above it)
	AnchorPoint = Vector2.new(0.5, 1), -- which point of the bar Position refers to (0.5, 1 = its bottom-middle)
	UiScale = { RefHeight = 900, Min = 0.7, Max = 1.25 }, -- the bar grows / shrinks with the screen height (900 px = normal size)
	TestSwitcher = true, -- Studio only: arrows above the bar to flip through the characters while testing
	-- Team Test runs on a real Roblox server, not Studio, so there the server only lets these players switch characters:
	-- members of the game's group of at least TesterRank (4 = Lead Developer, 5 = co owner, 255 = Owner), plus anyone
	-- listed in Testers by user id (e.g. a friend helping test). Everyone else plays DefaultCharacter.
	TesterRank = 4,
	Testers = {},
	Rarities = {
		Rare = Color3.fromRGB(80, 170, 255),
		Epic = Color3.fromRGB(176, 108, 255),
		Legendary = Color3.fromRGB(255, 194, 51),
		Mythic = Color3.fromRGB(255, 61, 110),
	},
	Characters = {
		{
			Id = "Naruto", Name = "Naruto", Rarity = nil, Color = Color3.fromRGB(255, 138, 43),
			Skill1 = { Name = "Chakra Mode", Description = "1.5x speed boost that lasts 3 seconds.", Icon = "", Vfx = "Naruto/NarutoAuraz", Duration = 3,
				Cooldown = 25, SpeedMultiplier = 1.5 },
			Skill2 = { Name = "Kunai Throw", Description = "Throws a kunai: whoever it hits slows down for a moment.", Icon = "", Anim = "KunaiThrow", Vfx = "Naruto/KunaiThrowVFX",
				Cooldown = 30, Hit = { Kind = "Kunai", Release = "KunaiRelease", Speed = "KunaiSpeed" } },
			Ultimate = { Name = "Rasen Shuriken", Description = "Stuns the enemy and slows them down for a bit.", Icon = "", Anim = "RasenShuriken", Vfx = "Naruto/RasenShurikenVFX",
				Hit = { Kind = "RasenShuriken", Release = "RasenThrow", Speed = "ShurikenSpeed", Radius = 3, Height = 4 } },
		},
		{
			Id = "Deku", Name = "Deku", Rarity = nil, Color = Color3.fromRGB(61, 220, 132),
			Skill1 = { Name = "Jump Boost", Description = "Jumps really high into the air. Hold W to dive down.", Icon = "", Anim = "Jump", Vfx = "Deku/DekuJump",
				Cooldown = 30, JumpHeight = 10 }, -- x as high as a normal jump. Launches at the push-off in the Jump animation (AbilityVFX.Timings.JumpPushOff)
			Skill2 = { Name = "One For All Dash", Description = "A quick dash forward.", Icon = "", Short = "OFA", Anim = "DekuBoost", Vfx = "Deku/DekuDashVFX",
				Cooldown = 35, DashSpeed = 70, DashTime = 0.3 }, -- a burst of DashSpeed extra speed (studs/s) for DashTime seconds, at the push in the animation (AbilityVFX.Timings.DashPush)
			Ultimate = { Name = "Speed Boost", Description = "Doubles your speed for 5 seconds.", Icon = "", Duration = 5,
				SpeedMultiplier = 2 }, -- you ride SpeedMultiplier x as fast for Duration seconds (the green aura lasts as long).
				-- Never more than 2x your normal top speed (200): nothing stacks on top (Config.SpeedBoost.NoStacking)
		},
		{
			Id = "Sasuke", Name = "Sasuke", Rarity = "Epic", Color = Color3.fromRGB(110, 120, 255),
			Skill1 = { Name = "Chidori", Description = "1.2x speed for up to 5 seconds to reach someone: touch them to stun them.", Icon = "", Anim = "ChidoriCharge", Vfx = "Sasuke", Duration = 5,
				Cooldown = 30, SpeedMultiplier = 1.2, Touch = { Kind = "Chidori", Radius = 15, EndOnHit = true } }, -- live for up to Duration s at 1.2x speed: the first rider within Radius studs gets hit automatically (no need to touch exactly) and it ends (else it fizzles out)
			Skill2 = { Name = "Sharingan", Description = "Auto-dodges other riders' basic moves (not ultimates) for up to 6 seconds.", Icon = "", Duration = 6,
				Cooldown = 45, Dodge = "Base" }, -- "Base" = dodges basic moves (Skill1 / Skill2) only; true = dodges everything
			Ultimate = { Name = "Sharingan Copy", Description = "Copies a random basic move from a random rider nearby: use it within 20 seconds. Also 1.2x speed for 5 seconds.", Icon = "", Duration = 2.5,
				SpeedMultiplier = 1.2, SpeedTime = 5, -- the little speed boost when you use it
				Copy = { Range = 160, Window = 20 } }, -- a random rider within Range (team-mate or not), a random basic move of theirs; Window = seconds to use it
		},
		{
			Id = "Todo", Name = "Todo", Rarity = "Legendary", Color = Color3.fromRGB(232, 164, 74),
			Skill1 = { Name = "Boogie Woogie", Description = "Swap places with the closest surfer within 60 studs.", Icon = "", Anim = "Clap", Vfx = "Todo/TodoClap",
				Swap = { Range = 60 } }, -- at the clap you swap places with the closest rider / dummy within Range studs (team-mate or not)
			Skill2 = { Name = "Fake Clap", Description = "A fake clap to trick your enemies: the clap, but nothing happens.", Icon = "", Anim = "Clap" },
			Ultimate = { Name = "500 IQ", Description = "No cooldowns for 8 seconds.", Icon = "", Short = "IQ", Anim = "TodoUlts", Vfx = "Todo/TodoCutscene", Duration = 8,
				NoCooldowns = 8 }, -- after the cutscene, your skills have no cooldowns for this many seconds (gold glow while it lasts)
		},
		{
			Id = "Dio", Name = "Dio", Rarity = "Mythic", Color = Color3.fromRGB(255, 210, 63),
			Skill1 = { Name = "Time Skip", Description = "A dash so quick it looks like you teleported.", Icon = "", Anim = "TimeSkip", Vfx = "Dio/TimeSkip",
				Cooldown = 15, DashSpeed = 250, DashTime = 0.14, DashRampIn = 0.02, DashFadeOut = 0.12 }, -- (a blink: exempt from SpeedBoost.NoStacking)
				-- a burst of DashSpeed extra speed (studs/s) for DashTime seconds, snapping in over DashRampIn and out over
				-- DashFadeOut: about 45 studs further in a blink. You vanish while it happens (everyone sees it) and reappear
				-- with the burst (AbilityVFX.Timings.TimeSkipReappear)
			Skill2 = { Name = "Knives", Description = "Throw 3 knives at an enemy to stun them.", Icon = "", Anim = "KnifeThrow", Vfx = "Dio/KnifeThrow",
				Cooldown = 30, Hit = { Kind = "Knives", Release = "KnifeRelease", Speed = "KnifeSpeed" } }, -- what the stun does: Config.Hits.Knives
			Ultimate = { Name = "Za Warudo", Description = "Freeze everyone and everything except yourself.", Icon = "", Anim = "TimeStopUlt", Vfx = "Dio/TimeStop", Duration = 5,
				Freeze = { Range = 0, Release = "ZaWarudo" } },
				-- when the dome bursts (AbilityVFX.Timings.ZaWarudo) every other rider and dummy freezes for Duration seconds: no
				-- moving, steering, jumping or abilities, animations and thrown moves stop mid-air, then everything carries on
				-- exactly as it was. Range = 0: everyone in the server; or a number = only riders / dummies within that many studs
		},
	},
}

--// Ability effects (VFX only for now) //--
-- AbilityVFX plays each ability's effects on your rider when you use it: the ready-made ones from
-- ReplicatedStorage.BoardAssets.SkillVFX (played with ReplicatedStorage.Part_Icles), plus a few made in code
-- (Sharingan eyes, Deku's green aura, kunai / knives, Za Warudo's grey screen, 500 IQ's gold glow).
-- Nothing here changes gameplay yet. Only you see them for now (other players will once the ability system is in).
Config.AbilityVFX = {
	Enabled = true,
	ThrowRange = 140, -- how far thrown things fly (studs) before they vanish / the Rasen Shuriken explodes
	KunaiSpeed = 180, -- studs/s faster than you're riding
	KnifeSpeed = 170,
	ShurikenSpeed = 130,
	ShurikenHoldHeight = 6, -- studs above you while it's held
	TargetRange = 160, -- throws and Boogie Woogie auto-aim at the closest dummy / NPC / other rider within this range (studs).
		-- Anything with a Humanoid counts; tag a model "IgnoreAbilities" to leave it out, or "AbilityTarget" to add one
	AimCone = 70, -- throws only lock on to targets within this many degrees of straight ahead (Boogie Woogie works any direction)
	AuraTrail = false, -- true = aura particles stream out behind you at speed; false = they stay on your body
	Cutscenes = true, -- false = 500 IQ and Za Warudo skip their camera cutscene
	CutsceneFov = 70,
	-- the cutscenes play the camera rigs' saved animations, which only works in Studio. For the live game publish them
	-- (Animation Editor > Publish) and paste the ids here, e.g. TimeStopCam = "rbxassetid://1234567890"
	CutsceneAnimationIds = { TodoUltCam = "", TimeStopCam = "" },
	ScreenEffects = true, -- Za Warudo's negative flash + grey world (on your camera only; Lighting isn't touched)
	RemoteScreenEffects = false, -- also grey your screen when SOMEONE ELSE uses Za Warudo (their cutscene never takes your camera)
	-- ability animations: each ability's "Anim" (Config.Abilities) from BoardAssets.Rigs.AbilitiesBoard.AnimSaves plays
	-- on your rider with its effects. The board in the animation follows whichever board you ride.
	Animations = true, -- false = effects only, no ability animations
	AnimationRig = "AbilitiesBoard", -- rig in BoardAssets.Rigs whose AnimSaves hold the ability animations
	-- saved animations only play in Studio. For the live game publish them and paste the ids here,
	-- e.g. KunaiThrow = "rbxassetid://1234567890" (the board part in a published animation has to be called "Board")
	AnimationIds = {
		KunaiThrow = "", RasenShuriken = "", Jump = "", DekuBoost = "", ChidoriCharge = "", ChidoriFinish = "",
		Clap = "", TodoUlts = "", TimeSkip = "", KnifeThrow = "", TimeStopUlt = "", StunAnim = "", DazedAnim = "",
	},
	StunTime = 2, -- seconds someone who gets hit (Rasen Shuriken, kunai, knives) plays the stunned + dazed animations
	-- seconds into each ability's animation when its effects fire (matched to the animations; nudge if they look early / late)
	Timings = {
		KunaiRelease = 0.38, -- the kunai leaves the hand
		RasenFormed = 0.45, -- the Rasen Shuriken forms in the hands (it then spins overhead)...
		RasenThrow = 1.38, -- ...and is thrown
		JumpPushOff = 0.4, -- Deku pushes off (the leap burst)
		DashPush = 0.1, -- One For All Dash burst
		ChidoriArm = 0.25, -- lightning starts on the arm (the finishing thrust plays at the end of the Chidori's Duration)
		Clap = 0.28, -- Todo's hands meet (Boogie Woogie / Fake Clap)
		IQClap = 0.95, -- the 500 IQ clap
		TimeSkipReappear = 0.2, -- Dio reappears (he's invisible from the start of Time Skip until then)
		KnifeRelease = 0.3, -- the knives leave the hand
		ZaWarudo = 0.55, -- Dio's arms fling up: the dome + grey world
	},
}

return Config
