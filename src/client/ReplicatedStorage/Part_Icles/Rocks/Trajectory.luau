--[[
	Rocks/Trajectory  -  FULLY PREDETERMINED debris paths (edit mode and running games alike;
	the physics engine never touches a chunk).

	The whole flight is computed ONCE at emit: ballistic arcs are raycast in
	slices to find each impact, bounces reflect analytically (restitution above
	BOUNCE_MIN, friction on the tangent, travel→tumble), the final roll-out is a
	closed-form deceleration, and the rest pose (nearest face flat, heading
	preserved) is exact. Playback = evaluate(traj, t)  -  a pure function of
	time, so jitter/vibration/unpredicted poses are impossible at ANY phase,
	reverse or scaled Timescale replays exactly, and the per-frame cost is a
	handful of vector ops per chunk. All raycast cost happens at emit
	(≤ ~18 rays per chunk).

	The raycast is INJECTED (raycastFn(origin, displacement) → RaycastResult-like
	or nil) so a Node harness can verify the builder + evaluator headless.
]]

-- Bounces slower than this along the normal don't rebound; the path rolls out.
local BOUNCE_MIN = 6
local MAX_BOUNCES = 3
-- Roll-out deceleration = friction · gravity · this factor (rolling resistance).
local ROLL_RESIST = 0.5
-- Arc raycast slicing.
local FIRST_ARC_SLICES = 6
local BOUNCE_ARC_SLICES = 4
local MAX_ARC_TIME = 6

local Trajectory = {}

-- OBB support distance: projection of the (scaled) half extents onto dir.
local function support(rot, halfExt, dir, scale)
	return (math.abs(rot.XVector:Dot(dir)) * halfExt.X
		+ math.abs(rot.YVector:Dot(dir)) * halfExt.Y
		+ math.abs(rot.ZVector:Dot(dir)) * halfExt.Z) * scale
end

local function spinCF(rot, w, dt)
	local mag = w.Magnitude
	if mag * dt < 1e-4 then return rot end
	return CFrame.fromAxisAngle(w * (1 / mag), mag * dt) * rot
end

-- Exact time the parabola center crosses n·center(t) = target. The swept chord
-- ray only DETECTS the surface; placing the impact on the chord would snap the
-- pose by the chord-parabola gap (grows with the arc window). Solving the
-- quadratic keeps evaluate() continuous through the impact by construction.
local function planeCrossTime(p, v, gVec, n, target, tMax)
	local a = 0.5 * gVec:Dot(n)
	local b = v:Dot(n)
	local c = p:Dot(n) - target
	if math.abs(a) < 1e-6 then
		if math.abs(b) < 1e-9 then return nil end
		local t = -c / b
		if t >= 0 and t <= tMax then return t end
		return nil
	end
	local disc = b * b - 4 * a * c
	if disc < 0 then return nil end
	local sq = math.sqrt(disc)
	local t1 = (-b - sq) / (2 * a)
	local t2 = (-b + sq) / (2 * a)
	if t1 > t2 then
		t1, t2 = t2, t1
	end
	if t1 >= 0 and t1 <= tMax then return t1 end
	if t2 >= 0 and t2 <= tMax then return t2 end
	return nil
end

-- Face-flat orientation on normal n, heading preserved. Alignment is weighted
-- by 1/halfExt so an elongated axis must be near-perfectly vertical to win:
-- debris settles onto its broad face (lowest center of mass) like real rubble
-- instead of standing on end. Returns (rotation, resting-face half extent).
local function restPose(rot, halfExt, n)
	local dx, dy, dz = rot.XVector:Dot(n), rot.YVector:Dot(n), rot.ZVector:Dot(n)
	local sx = math.abs(dx) / math.max(halfExt.X, 0.05)
	local sy = math.abs(dy) / math.max(halfExt.Y, 0.05)
	local sz = math.abs(dz) / math.max(halfExt.Z, 0.05)
	local axisVec, faceHalf
	if sx >= sy and sx >= sz then
		axisVec = rot.XVector * (dx >= 0 and 1 or -1)
		faceHalf = halfExt.X
	elseif sy >= sz then
		axisVec = rot.YVector * (dy >= 0 and 1 or -1)
		faceHalf = halfExt.Y
	else
		axisVec = rot.ZVector * (dz >= 0 and 1 or -1)
		faceHalf = halfExt.Z
	end
	local d = math.clamp(axisVec:Dot(n), -1, 1)
	local arc = axisVec:Cross(n)
	if arc.Magnitude > 1e-5 and d < 0.9999 then
		return CFrame.fromAxisAngle(arc.Unit, math.acos(d)) * rot, faceHalf
	end
	return rot, faceHalf
end

-- Spawn-state ballistic placeholder: what an unbuilt chunk flies until its full path lands
-- (Rocks/init spreads Trajectory.build over frames).
function Trajectory.ballistic(p0, v0, rot0, w0)
	return { segs = { { kind = 1, t0 = 0, p0 = p0, v0 = v0, rot0 = rot0, w = w0 } }, impactT = nil, hit = nil, restT = math.huge }
end

-- Build one chunk's complete path. Returns a trajectory table:
--   segs[]: {kind=1 ballistic|2 roll|3 rest, t0, p0, v0/dir, rot0, w/rotF, dur, ...}
--   impactT (first ground contact time or nil), hit (its RaycastResult), restT, restNormal.
function Trajectory.build(p0, v0, rot0, w0, halfExt, scale, gravity, bounciness, friction, raycastFn)
	local segs = {}
	local traj = { segs = segs, impactT = nil, hit = nil, restT = math.huge }
	local t, p, v, rot, w = 0, p0, v0, rot0, w0
	local gVec = Vector3.new(0, -gravity, 0)

	for bounce = 0, MAX_BOUNCES do
		-- Raycast the arc in slices until it hits or the window closes.
		local slices = bounce == 0 and FIRST_ARC_SLICES or BOUNCE_ARC_SLICES
		-- Arc window: generous time for the parabola to come back down.
		local upTime = math.max(v.Y, 0) / math.max(gravity, 1)
		local window = math.min(upTime * 2 + 1.5, MAX_ARC_TIME)
		local sliceDt = window / slices
		local hit, hitT = nil, nil
		local prevP = p
		for s = 1, slices do
			local st = s * sliceDt
			local sp = p + v * st + gVec * (0.5 * st * st)
			local seg = sp - prevP
			if seg.Magnitude > 1e-4 then
				local dirU = seg.Unit
				local reach = support(rot, halfExt, dirU, scale)
				local h = raycastFn(prevP, seg + dirU * reach)
				if h then
					hit = h
					-- Support extent toward the surface at the chord-estimate pose.
					local frac = math.clamp((h.Position - prevP).Magnitude / (seg.Magnitude + reach), 0, 1)
					local approxT = (s - 1) * sliceDt + sliceDt * frac
					local supEst = support(spinCF(rot, w, approxT), halfExt, h.Normal, scale)
					-- Exact crossing of the contact plane, seated at support height.
					local target = h.Position:Dot(h.Normal) + supEst
					hitT = planeCrossTime(p, v, gVec, h.Normal, target, window) or approxT
					break
				end
			end
			prevP = sp
		end

		if not hit then
			-- No ground in the window: fly ballistic until Lifetime ends.
			segs[#segs + 1] = { kind = 1, t0 = t, p0 = p, v0 = v, rot0 = rot, w = w }
			return traj
		end

		local n = hit.Normal
		local vImp = v + gVec * hitT
		local rotImp = spinCF(rot, w, hitT)
		local sup = support(rotImp, halfExt, n, scale)
		-- On-parabola impact position: matches evaluate() at t0+hitT exactly, so
		-- the ballistic→bounce/roll boundary never snaps.
		local pImp = p + v * hitT + gVec * (0.5 * hitT * hitT)

		segs[#segs + 1] = { kind = 1, t0 = t, p0 = p, v0 = v, rot0 = rot, w = w }
		t += hitT
		if not traj.impactT then
			traj.impactT = t
			traj.hit = hit
		end

		local vn = vImp:Dot(n)
		local vt = vImp - n * vn
		-- Bounce only when the REBOUND (post-restitution) speed clears the
		-- threshold  -  low Bounciness goes straight to the roll-out.
		if (-vn * bounciness) > BOUNCE_MIN and n.Y > 0.3 and bounce < MAX_BOUNCES then
			-- Rebound: restitution + impact friction + travel→tumble.
			v = vt * (1 - friction) + n * (-vn * bounciness)
			local axis = n:Cross(vt)
			if axis.Magnitude > 1e-4 and vt.Magnitude > 0.5 then
				w = axis.Unit * (vt.Magnitude / math.max(sup, 0.1))
			end
			p = pImp
			rot = rotImp
		else
			-- Roll-out: closed-form deceleration along the tangent, orientation
			-- blends to the exact rest pose, timed to finish with the slide.
			local speed = vt.Magnitude
			local decel = math.max(friction * gravity * ROLL_RESIST, 10)
			local dur = math.min(speed / decel, 2)
			local dir = speed > 1e-3 and vt.Unit or Vector3.xAxis
			local rotF, faceHalf = restPose(rotImp, halfExt, n)
			local d = hit.Position:Dot(n)
			-- Rest center sits exactly at face height on the contact plane.
			local function planeSeat(pt, height)
				return pt + n * ((d + height) - pt:Dot(n))
			end
			local rollP0 = planeSeat(pImp, sup)
			local rollP1 = planeSeat(rollP0 + dir * (speed * dur - 0.5 * decel * dur * dur), faceHalf * scale)
			segs[#segs + 1] = { kind = 2, t0 = t, dur = math.max(dur, 0.15),
				p0 = rollP0, p1 = rollP1, rot0 = rotImp, rotF = rotF }
			t += math.max(dur, 0.15)
			segs[#segs + 1] = { kind = 3, t0 = t, cf = rotF + rollP1 }
			traj.restT = t
			traj.restNormal = n
			return traj
		end
	end
	return traj
end

-- Evaluate the pose at time t (pure function; any t, any direction).
function Trajectory.evaluate(traj, t, gravity)
	local segs = traj.segs
	local seg = segs[1]
	for s = 2, #segs do
		if segs[s].t0 <= t then seg = segs[s] else break end
	end
	if seg.kind == 1 then
		local dt = math.max(t - seg.t0, 0)
		local p = seg.p0 + seg.v0 * dt + Vector3.new(0, -0.5 * gravity * dt * dt, 0)
		return spinCF(seg.rot0, seg.w, dt) + p
	elseif seg.kind == 2 then
		local s = math.clamp((t - seg.t0) / seg.dur, 0, 1)
		local e = 1 - (1 - s) * (1 - s)
		return seg.rot0:Lerp(seg.rotF, e) + seg.p0:Lerp(seg.p1, e)
	end
	return seg.cf
end

return Trajectory
