--[[
	Distortion/Field  -  pure height-field math for the screen-distortion canvas.
	NO Roblox APIs (fengari-testable): plain arrays + numbers in, numbers out.

	Contract: every add* function ACCUMULATES amp-scaled height into `height[]`
	(linearity is the Canvas compositor contract  -  concurrent effects sum).
	Coordinates: baseU/baseV are normalized [0,1] across the plane; `aspect`
	corrects U distances so rings stay round on screen.

	Phase is the caller's effective-time integral (dtTs x Speed), so Timescale
	graphs  -  including negative segments  -  warp and reverse the animation.
]]

local Field = {}

-- Deterministic hash-based value noise (seedable, replay-stable; math.noise is
-- Roblox-only and lattice-zeroed at integers, so it is deliberately not used).
local function hash2(ix, iy, seed)
	local h = ix * 374761393 + iy * 668265263 + seed * 1442695040888963
	h = h % 2147483647
	h = (h * 1103515245 + 12345) % 2147483647
	return (h % 10000) / 10000
end

local function smooth(t)
	return t * t * (3 - 2 * t)
end

-- Single-octave value noise at (x, y).
local function valueNoise(x, y, seed)
	local ix = math.floor(x)
	local iy = math.floor(y)
	local fx = smooth(x - ix)
	local fy = smooth(y - iy)
	local a = hash2(ix, iy, seed)
	local b = hash2(ix + 1, iy, seed)
	local c = hash2(ix, iy + 1, seed)
	local d = hash2(ix + 1, iy + 1, seed)
	local ab = a + (b - a) * fx
	local cd = c + (d - c) * fx
	return (ab + (cd - ab) * fy) * 2 - 1
end

Field.valueNoise = valueNoise

-- Expanding ring from the epicenter. Wavefront sits at d == phase; a gaussian
-- window of width ~wavelength keeps a tight visible band around the front.
function Field.addRipple(height, baseU, baseV, count, aspect, amp, wavelength, phase, epicU, epicV)
	if amp == 0 then return end
	local wl = math.max(wavelength, 0.02)
	local invW = 1 / wl
	local twoPi = 2 * math.pi
	for i = 1, count do
		local dx = (baseU[i] - epicU) * aspect
		local dy = baseV[i] - epicV
		local d = math.sqrt(dx * dx + dy * dy)
		local front = (d - phase) * invW
		height[i] += amp * math.cos(twoPi * front) * math.exp(-front * front * 4)
	end
end

-- Directional traveling sine wave. dirRad = travel direction in plane space.
function Field.addWave(height, baseU, baseV, count, aspect, amp, wavelength, phase, dirRad)
	if amp == 0 then return end
	local wl = math.max(wavelength, 0.02)
	local kx = math.cos(dirRad) / wl
	local ky = math.sin(dirRad) / wl
	local twoPi = 2 * math.pi
	for i = 1, count do
		local s = baseU[i] * aspect * kx + baseV[i] * ky
		height[i] += amp * math.sin(twoPi * (s - phase / wl))
	end
end

-- 2-octave scrolling value noise; scroll direction dirRad, seed decorrelates
-- concurrent effects.
function Field.addNoise(height, baseU, baseV, count, aspect, amp, scale, phase, dirRad, seed)
	if amp == 0 then return end
	local sx = math.cos(dirRad) * phase
	local sy = math.sin(dirRad) * phase
	for i = 1, count do
		local u = (baseU[i] * aspect - sx) * scale
		local v = (baseV[i] - sy) * scale
		height[i] += amp * (valueNoise(u, v, seed) + 0.5 * valueNoise(u * 2.13, v * 2.13, seed + 71))
	end
end

-- Static lens dome: sign of amp picks bulge (+) or pinch (-). Phase-independent.
function Field.addLens(height, baseU, baseV, count, aspect, amp, radius, epicU, epicV)
	if amp == 0 then return end
	local r = math.max(radius, 0.02)
	local invR2 = 1 / (r * r)
	for i = 1, count do
		local dx = (baseU[i] - epicU) * aspect
		local dy = baseV[i] - epicV
		local q = 1 - (dx * dx + dy * dy) * invR2
		if q > 0 then
			height[i] += amp * q * q
		end
	end
end

-- Zero the height buffer (table.clear nils entries; the hot loop needs 0s).
function Field.zero(height, count)
	for i = 1, count do
		height[i] = 0
	end
end

-- Dispatch one contribution by kind id (1 Ripple, 2 Wave, 3 Noise, 4 Bulge,
-- 5 Pinch). Bulge/Pinch share addLens with signed amp.
function Field.accumulate(kindId, height, baseU, baseV, count, aspect, amp, wavelength, phase, dirRad, noiseScale, lensRadius, epicU, epicV, seed)
	if kindId == 1 then
		Field.addRipple(height, baseU, baseV, count, aspect, amp, wavelength, phase, epicU, epicV)
	elseif kindId == 2 then
		Field.addWave(height, baseU, baseV, count, aspect, amp, wavelength, phase, dirRad)
	elseif kindId == 3 then
		Field.addNoise(height, baseU, baseV, count, aspect, amp, noiseScale, phase, dirRad, seed)
	elseif kindId == 4 then
		Field.addLens(height, baseU, baseV, count, aspect, amp, lensRadius, epicU, epicV)
	elseif kindId == 5 then
		Field.addLens(height, baseU, baseV, count, aspect, -amp, lensRadius, epicU, epicV)
	end
end

return Field
