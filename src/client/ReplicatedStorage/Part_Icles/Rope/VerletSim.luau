--[[
	Rope/VerletSim  -  position-verlet chain over the rope rig point buffers.
	Pure math, no Roblox services  -  the Node harness runs this file headless.

	step() integrates every FREE point (pos += (pos - prev)·(1 - damping) +
	(gravity + wind)·h²) then runs K Jakobsen relaxation iterations over the
	adjacent-point distance constraints. Pinned points (start always; end when
	pinEnd) have weight 0  -  their correction goes fully to the free neighbor.
	Projection cannot add energy, so a hanging rope settles dead still.

	Caller contract (Rope/init.luau UpdateRope): fixed-substep accumulator at
	SUBSTEP, at most MAX_SUBSTEPS per frame, input dt clamped, EXCESS ACCUM
	DROPPED at the cap  -  a hitch slows the rope, it never explodes. Anchors
	re-pin before every substep (Rope/Anchors.luau).
]]

local VerletSim = {}

VerletSim.SUBSTEP = 1 / 60
VerletSim.MAX_SUBSTEPS = 3

-- Wind sample for normalized arc position s: 2-octave noise on world X/Z.
local function windAccel(s, amp, phase, seedA, seedB)
	local x1 = s * 3 - phase
	local x2 = s * 8.1 - phase * 1.6
	return Vector3.new(
		(math.noise(x1, seedA) + 0.5 * math.noise(x2, seedA + 37.1)) * amp,
		0,
		(math.noise(x1, seedB) + 0.5 * math.noise(x2, seedB + 37.1)) * amp)
end

-- One fixed substep h. pos/prev hold n+1 points; params reads pData fields:
-- _damping, _gravity (Vector3), _restLen (or animated _restLenEff), _stiffness,
-- _pinStart (nil/true = pinned; false = free, Release death), _pinEnd,
-- _bendStiffness (0..1 second-neighbor constraints — cable/tentacle rigidity),
-- _windAmp + _windFreq seeds. windPhase advanced by the caller in effective time.
function VerletSim.step(pos, prev, n, params, h, windPhase)
	-- Time-corrected Verlet: the implicit velocity (pos - prev) is in units of
	-- the PREVIOUS step, so a changing h (Timescale slow-mo shrinks the step)
	-- must rescale it by h/hPrev or momentum jumps at every speed change.
	local hPrev = params._lastH or h
	params._lastH = h
	-- Damping normalized per SUBSTEP of simulated time: slow-mo (smaller h,
	-- more steps per sim-second) must not over-damp the rope.
	local damp = 1 - (params._damping or 0)
	if h ~= VerletSim.SUBSTEP and damp < 1 and damp > 0 then
		damp = damp ^ (h / VerletSim.SUBSTEP)
	end
	local keep = damp * (h / hPrev)
	local g = params._gravity
	local windAmp = params._windAmp or 0
	local pinStart = params._pinStart ~= false
	local pinEnd = params._pinEnd
	local firstFree = pinStart and 2 or 1
	local lastFree = pinEnd and n or (n + 1)

	for i = firstFree, lastFree do
		local p = pos[i]
		local acc = g
		if windAmp ~= 0 then
			acc = acc + windAccel((i - 1) / n, windAmp, windPhase, params._windSeedA, params._windSeedB)
		end
		pos[i] = p + (p - prev[i]) * keep + acc * (h * h)
		prev[i] = p
	end

	local restLen = params._restLenEff or params._restLen
	local bend = params._bendStiffness or 0
	local iterations = params._stiffness or 4
	for _ = 1, iterations do
		for i = 1, n do
			local a = pos[i]
			local b = pos[i + 1]
			local d = b - a
			local len = d.Magnitude
			if len > 1e-6 then
				local off = d * ((len - restLen) / len)
				local aPinned = pinStart and i == 1
				local bPinned = pinEnd and (i + 1 == n + 1)
				if aPinned then
					if not bPinned then
						pos[i + 1] = b - off
					end
				elseif bPinned then
					pos[i] = a + off
				else
					local half = off * 0.5
					pos[i] = a + half
					pos[i + 1] = b - half
				end
			end
		end
		if bend > 0 then
			-- Neighbor-midpoint straightening (cloth/hair-sim bend): pull each
			-- INTERIOR point toward its neighbors' midpoint — directly fights
			-- curvature, far stronger than second-neighbor distance constraints
			-- for gentle curves. Endpoints never move, so pins stay exact; the
			-- distance pass restores segment lengths each iteration.
			local k = bend * 0.5
			for i = 2, n do
				local mid = (pos[i - 1] + pos[i + 1]) * 0.5
				pos[i] = pos[i] + (mid - pos[i]) * k
			end
		end
	end
end

-- Rigid-translate the whole chain (teleport guard) without adding velocity.
function VerletSim.translate(pos, prev, n, offset)
	for i = 1, n + 1 do
		pos[i] = pos[i] + offset
		prev[i] = prev[i] + offset
	end
end

-- Kill all velocities in place (prev := pos)  -  spawn calm / degrade calm.
function VerletSim.calm(pos, prev, n)
	for i = 1, n + 1 do
		prev[i] = pos[i]
	end
end

return VerletSim
