--[[
	Distortion/PlaneBuilder  -  constructs the shared canvas backends.

	Mesh tier: EditableMesh grid plane, unit XY extents ([-0.5..0.5]), tiny baked
	Z relief so MeshSize has a nonzero Z (a degenerate flat mesh renders nothing).
	Canvas drives screen coverage via MeshPart.Size X/Y per frame and TRUE-stud
	height via vertex Z (Size.Z = MeshSize.Z keeps Z 1:1), so the per-frame write
	is Z-only. Single-sided winding toward local +Z (the camera).

	Tile tier: RES_TW x RES_TH squashed-Ball glass lenses on a shallow sphere
	section (each facing the camera); per-tile Transparency is the strength knob.
	Verified: gaps between tiles stay (overlapping glass culls itself).

	Both tiers carry the verified render recipe: Glass + Highlight child
	(FillTransparency 1, OutlineTransparency 0.98).
]]

local AssetService = game:GetService("AssetService")

local PlaneBuilder = {}

PlaneBuilder.RES_W = 24
PlaneBuilder.RES_H = 14
PlaneBuilder.TILE_W = 8
PlaneBuilder.TILE_H = 5

local function addRecipeHighlight(part)
	local hl = Instance.new("Highlight")
	hl.FillTransparency = 1
	hl.OutlineTransparency = 0.98
	hl.Parent = part
	return hl
end

local function configurePart(part)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	-- Locked keeps the canvas from being picked by a click in the Studio viewport.
	part.Locked = true
	part.Archivable = false
	part.Material = Enum.Material.Glass
	part.Color = Color3.new(1, 1, 1)
end

-- Capability probe: EditableMesh creation can be permission-gated (published
-- games without the Mesh/Image APIs toggle) or return nil on memory budget.
function PlaneBuilder.probeMesh()
	local ok, em = pcall(function()
		return AssetService:CreateEditableMesh()
	end)
	if ok and em then
		pcall(function() em:Destroy() end)
		return true
	end
	return false
end

-- Build the mesh-tier canvas at the given grid resolution (defaults RES_W x
-- RES_H). YIELDS (CreateMeshPartAsync)  -  caller wraps in task.spawn and treats
-- the canvas as "building" until the callback fires.
-- Returns nil on failure (memory budget / permissions drift mid-session).
function PlaneBuilder.buildMesh(resW, resH)
	local ok, result = pcall(function()
		local em = AssetService:CreateEditableMesh()
		if not em then return nil end
		local W = resW or PlaneBuilder.RES_W
		local H = resH or PlaneBuilder.RES_H
		local ids = table.create(W * H)
		local baseX = table.create(W * H)
		local baseY = table.create(W * H)
		for gy = 0, H - 1 do
			for gx = 0, W - 1 do
				local x = gx / (W - 1) - 0.5
				local y = gy / (H - 1) - 0.5
				-- Baked corner relief: nonzero Z bounds without disturbing the
				-- visually flat center (amplitude far below visible refraction).
				local z = ((gx + gy) % 2 == 0) and 0.004 or -0.004
				local k = gy * W + gx + 1
				ids[k] = em:AddVertex(Vector3.new(x, y, z))
				baseX[k] = x
				baseY[k] = y
			end
		end
		-- Auto vertex normals are REQUIRED: the tilted normals of the displaced
		-- grid ARE the glass refraction. Pinning them flat kills the warp
		-- entirely (verified the hard way). The sun-smear side effect is handled
		-- by Canvas's sun-hole mask, not here.
		for gy = 0, H - 2 do
			for gx = 0, W - 2 do
				local a = ids[gy * W + gx + 1]
				local b = ids[gy * W + gx + 2]
				local c = ids[(gy + 1) * W + gx + 1]
				local d = ids[(gy + 1) * W + gx + 2]
				-- Winding faces local +Z (verified single-sided requirement).
				em:AddTriangle(a, b, d)
				em:AddTriangle(a, d, c)
			end
		end
		local mp = AssetService:CreateMeshPartAsync(Content.fromObject(em))
		mp.Name = "__PartIclesDistortion"
		configurePart(mp)
		mp.Size = mp.MeshSize
		local hl = addRecipeHighlight(mp)
		return { part = mp, em = em, ids = ids, baseX = baseX, baseY = baseY,
			meshSizeZ = mp.MeshSize.Z, highlight = hl, resW = W, resH = H }
	end)
	if ok then return result end
	return nil
end

-- Build the tile-tier canvas: model of lens parts + their view-sphere angular
-- offsets (Canvas re-aims each tile from the live camera every frame).
function PlaneBuilder.buildTiles()
	local model = Instance.new("Model")
	model.Name = "__PartIclesDistortion"
	local tiles = {}
	local highlights = {}
	local yawAng = {}
	local pitchAng = {}
	local TW, TH = PlaneBuilder.TILE_W, PlaneBuilder.TILE_H
	local spacing = math.rad(10)
	local n = 0
	for gy = 1, TH do
		for gx = 1, TW do
			local lens = Instance.new("Part")
			lens.Shape = Enum.PartType.Ball
			lens.Size = Vector3.new(0.8, 0.8, 0.26)
			configurePart(lens)
			lens.Transparency = 1
			lens.Name = "Lens" .. gx .. "_" .. gy
			lens.Parent = model
			n += 1
			tiles[n] = lens
			highlights[n] = addRecipeHighlight(lens)
			yawAng[n] = -(gx - (TW + 1) / 2) * spacing
			pitchAng[n] = (gy - (TH + 1) / 2) * spacing
		end
	end
	return { model = model, tiles = tiles, highlights = highlights, yawAng = yawAng,
		pitchAng = pitchAng, count = n, writeCFs = table.create(n) }
end

return PlaneBuilder
