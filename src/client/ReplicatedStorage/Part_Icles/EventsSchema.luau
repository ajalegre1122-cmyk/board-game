--[[
	EventsSchema  -  read/write/sanitize for the per-item Events tree.
	Tree: PartIcleProperties/Events/<EventName Configuration>/{Enabled, EmitMode, ScriptEnabled,
	ChainDepthLimit, EmitTarget (ObjectValue), Module (ModuleScript)}.
	Trail excluded (directAccess + continuous). OnHit only on Part/Attachment/Model/Lightning/Rocks.
]]

local TypeRegistry = require(script.Parent.TypeRegistry)
local HitFilter = require(script.Parent.HitFilter)

local EventsSchema = {}

local EVENTS_FOLDER_NAME = "Events"
local EVENT_NAMES = { "OnEmit", "OnDeath", "OnDestruction", "OnHit" }
EventsSchema.EVENT_NAMES = EVENT_NAMES
EventsSchema.EVENTS_FOLDER_NAME = EVENTS_FOLDER_NAME

local EMIT_MODES = { AtPosition = true, AtSource = true, AtTarget = true, AtCFrame = true }
EventsSchema.EMIT_MODES = EMIT_MODES

-- One line per mode for the Events UI hint under the Mode dropdown.
EventsSchema.EMIT_MODE_HINTS = {
	AtPosition = "Spawns where the event happened (emit, death or hit point).",
	AtSource = "Spawns at the source emitter's current position.",
	AtTarget = "Spawns at the target's own authored placement.",
	AtCFrame = "Spawns at the event position and rotation.",
}

-- OnHit Collision: Off (pass-through) / Kill (snap+destroy) / Stop (freeze) / Bounce (reflect).
local COLLISION_MODES = { Off = true, Kill = true, Stop = true, Bounce = true }
EventsSchema.COLLISION_MODES = COLLISION_MODES

local function clampDepthValue(v)
	local n = tonumber(v)
	if not n then return 4 end
	return math.clamp(math.floor(n), 1, 32)
end

local function safeEmitMode(v)
	if type(v) == "string" and EMIT_MODES[v] then return v end
	return "AtPosition"
end

local function safeCollisionMode(v)
	if type(v) == "string" and COLLISION_MODES[v] then return v end
	return "Off"
end

local function clampUnit(v, lo, hi, default)
	local n = tonumber(v)
	if not n then return default end
	if n < lo then return lo end
	if n > hi then return hi end
	return n
end

EventsSchema.clampChainDepth = clampDepthValue
EventsSchema.safeEmitMode = safeEmitMode
EventsSchema.safeCollisionMode = safeCollisionMode
EventsSchema.clampUnit = clampUnit

-- Per-type event validity (OnHit only on collision-bearing types).
-- OnDestruction may only be offered where Events.getWorldCF resolves an origin for the type;
-- VisualPart-less types (CameraShake, Distortion) have explicit branches there.
local VALID_PER_TYPE = {
	Part        = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = true  },
	Beam        = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	Attachment  = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = true  },
	Model       = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = true  },
	PointLight  = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	Sound       = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	Highlight   = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	TrailEmitter = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	Atmosphere  = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	Blur        = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	Bloom       = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	ColorCorrection = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	ImageLabel  = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	-- Lightning OnHit: Seek mode only — fires per strike-point acquisition
	-- (emit + each retarget) with the seek raycast's payload (Lightning/init.luau).
	Lightning   = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = true },
	CameraShake = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	-- Rocks OnHit fires ONCE per burst on first chunk contact (from the sim's own
	-- raycast, Rocks/init.luau); CollisionAction modes don't apply (physics owns bounce).
	Rocks       = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = true },
	Rope        = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	Distortion  = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
}

-- Per-event defaults. Enabled=false so ensureEvent paths don't implicitly arm the runtime.
local DEFAULT_ATTRS = {
	Enabled         = false,
	EmitMode        = "AtPosition",
	ScriptEnabled   = false,
	ChainDepthLimit = 4,
	Collision       = "Off",
	-- Collision physics: 0..1 each. Bounciness = normal restitution; Friction = tangential
	-- damping; Spin = nrm×v_t coefficient.
	Bounciness      = 0.7,
	Friction        = 0.2,
	Spin            = 0.5,
	-- 0 = check every Heartbeat. Clamp 0..0.5.
	HitCheckInterval = 0,
}

-- Default Module source  -  commented payload reference for the Edit Script panel.
-- Outer literal uses [==[ ... ]==] so the inner --[[ ... ]] block comment's `]]`
-- doesn't terminate the long-string early.
local DEFAULT_MODULE_SOURCE = [==[--[[
	Part-Icles event script.

	This function runs once every time this event happens to ONE particle.
	`payload` describes that particle and gives you functions to change it.
	The script only runs while the event's "Script" toggle is on. Errors show in
	the Output window and never stop the effect.
	Keep the last three lines: the file must return a function that takes `payload`.
]]

-- WHEN DOES THIS RUN?
--   OnEmit         the particle was just created
--   OnHit          the particle touched something (Part / Attachment / Model / Lightning / Rocks emitters only)
--   OnDeath        the particle's lifetime ran out, or something killed it
--   OnDestruction  the particle is removed for good (after its Linger time, if it has one)

-- QUICK EXAMPLE  (OnDeath: spawn a second effect only if the particle lived longer than a second)
--   return function(payload)
--       if payload.Age > 1 then
--           payload.Emit(workspace.Sparks, "AtPosition")
--       end
--   end

-- ============================================================================
--  THINGS YOU CAN READ  (plain values; changing them does nothing)
-- ============================================================================
--   In every event
--     payload.Source            the emitter you set up in the plugin (the original)
--     payload.Particle          the copy flying around right now (nil for Camera Shake / Distortion)
--     payload.WorldPosition     where the particle is, as a Vector3 (nil for screen effects)
--     payload.WorldCFrame       the same with rotation, as a CFrame (nil for screen effects)
--     payload.LifeTime          how many seconds the particle is set to live
--     payload.LifeProgress      0 = just born, 1 = about to die
--     payload.TimeRemaining     seconds left before it dies on its own
--     payload.StartTime         os.clock() at the moment it was created
--     payload.SpeedMultiplier   current speed scale (1 = normal; bounces lower it)
--     payload.ChainDepth        0 normally; 1, 2, ... when this particle was itself spawned by an event
--     payload.RenderTemplate    old name for payload.Particle
--
--   OnEmit only
--     payload.EmitPosition      same as WorldPosition
--     payload.EmitIndex         which particle of the burst this is (1 = first)
--     payload.EmitCount         how many particles the burst made (nil for a single emit)
--
--   OnHit only
--     payload.HitInstance       the part it touched (payload.Other is the same thing)
--     payload.HitPosition       the exact contact point (Vector3)
--     payload.HitNormal         the direction the surface faces at that point (Vector3, length 1)
--
--   OnDeath only
--     payload.DeathPosition     same as WorldPosition
--     payload.Age               how many seconds it really lived (less than LifeTime when killed early)
--
--   OnDestruction only
--     payload.DeathPosition     same as WorldPosition
--     payload.LingerElapsed     seconds spent in Linger before removal (0 without Linger)

-- ============================================================================
--  THINGS YOU CAN DO  (functions; they change this one particle only)
-- ============================================================================
--   Spawn and end
--     payload.Emit(target, mode)      fire another emitter from here. target = an emitter, a Folder or a
--                                     Model of emitters. mode = "AtPosition" | "AtSource" | "AtTarget" |
--                                     "AtCFrame"; leave it out to use this event's Mode dropdown
--     payload.Kill()                  remove the particle now (OnDeath does not fire for it)
--     payload.Resurrect()             cancel a Kill made earlier in this same script
--
--   Look
--     payload.SetColor(color3)        set the colour and stop the Color graph from changing it
--     payload.SetTransparency(0..1)   set the transparency and stop the Transparency graph
--     payload.SetSize(size)           set the size and stop the Size graph (Vector3; UDim2 for ImageLabel)
--     payload.SetSkipColor(true)      stop only the graph, keep the current value (false resumes it)
--     payload.SetSkipTransparency(true)
--     payload.SetSkipSize(true)       Parts only
--
--   Time
--     payload.SetLifetime(seconds)    new total lifetime, counted from birth (a tiny value = dies next frame)
--     payload.Pause(seconds)          freeze the particle for that long, then continue
--     payload.FreezeTime(true)        freeze until you call FreezeTime(false)
--
--   Motion
--     payload.Teleport(cframe)        move the particle there (Part / Attachment / Model only)
--     payload.SetVelocity(vector3)    fly in that direction at that speed; SetVelocity(nil) restores the authored speed
--     payload.SetSpeedMultiplier(n)   scale the speed (2 = twice as fast, 0.5 = half)
--     payload.AddImpulse(vector3)     give it a push (added to its velocity)
--     payload.AddSpin(vector3)        make it tumble (spin speed per axis)

-- GOOD TO KNOW
--   * The script has its own thread: task.wait() and loops are fine, but after a wait the
--     particle may already be gone.
--   * payload.Source.Parent is nil when the emitter was deleted mid-flight; check it first.
--   * In Animate mode, payload.Particle IS the original RenderTemplate: what you change stays changed.

return function(payload)
	-- your code here
end
]==]

-- Internal: walk an item to its Events folder. Returns nil for non-config-mode types
-- (Trail) or items without the folder created yet. Doesn't create the folder.
local function getConfig(item)
	if not item then return nil end
	local typeDef = TypeRegistry.getTypeFor(item)
	if not typeDef or typeDef.directAccess then return nil end
	return TypeRegistry.getConfig(item)
end

local function getTypeName(item)
	local _, typeName = TypeRegistry.getTypeFor(item)
	return typeName
end

--- Lookup the Events folder under this item's PartIcleProperties. Returns nil if the
--- folder hasn't been created yet (lazy creation). Trail / unknown types return nil.
function EventsSchema.read(item)
	local config = getConfig(item)
	if not config then return nil end
	local folder = config:FindFirstChild(EVENTS_FOLDER_NAME)
	if folder and folder:IsA("Folder") then return folder end
	return nil
end

--- Returns true if `eventName` is valid for this item's type. Used by UI to hide
--- inapplicable rows (e.g. OnHit on a Beam) and by setEnabled/ensureEvent to refuse
--- creation of disallowed events.
function EventsSchema.isValidForItem(item, eventName)
	local typeName = getTypeName(item)
	if not typeName then return false end
	return EventsSchema.isValidForTypeName(typeName, eventName)
end

--- Type-name variant. UIBuilder/WidgetEvents calls this at section-build time when no
--- live item is available (the section is constructed once per type, not per selection).
--- Mirrors isValidForItem so the UI can never render rows the schema would refuse to
--- create  -  keeping a parallel local table in WidgetEvents would silently drift.
function EventsSchema.isValidForTypeName(typeName, eventName)
	local valid = VALID_PER_TYPE[typeName]
	return valid and valid[eventName] == true or false
end

--- Why `target` cannot spawn at an event origin (AtPosition / AtSource / AtCFrame), or nil when
--- it can. Single source for the runtime dispatcher (Events/EmitTarget.luau) and the Events UI
--- badge. Containers qualify when any child does.
function EventsSchema.emitCapabilityReason(target)
	if not target then return "no target" end
	if target:IsA("Folder") then
		for _, child in ipairs(target:GetChildren()) do
			if EventsSchema.emitCapabilityReason(child) == nil then return nil end
		end
		return "the folder holds nothing with a position"
	end
	if target:GetAttribute("Transformed") and (target:GetAttribute("EmissionMode") or "Emit") == "Animate" then
		return "Animate-mode targets animate their own instance"
	end
	if target:IsA("BasePart") or target:IsA("Attachment") or target:IsA("Model") or target:IsA("ParticleEmitter") then
		return nil
	end
	return target.ClassName .. " has no position to move"
end

function EventsSchema.emitCapability(target)
	return EventsSchema.emitCapabilityReason(target) == nil
end

--- Returns the per-event Configuration child if present. Doesn't create.
function EventsSchema.readEvent(item, eventName)
	local folder = EventsSchema.read(item)
	if not folder then return nil end
	local cfg = folder:FindFirstChild(eventName)
	if cfg and cfg:IsA("Configuration") then return cfg end
	return nil
end

--- Snapshot of currently-enabled events for runtime consumption. Returns nil when no
--- event is enabled (or folder missing). Each entry is a PLAIN TABLE of captured
--- attribute values + the Module reference (only when ScriptEnabled=true)  -  NOT a live
--- Configuration ref. Snapshot semantics matter at emit time: cfg can mutate mid-flight
--- under user authoring, and a live ref would let the runtime see half-applied state.
---
--- Fail-closed on `ImportedUntrusted`: if a per-event Configuration has the attribute
--- set, runtime SKIPS it regardless of its Enabled value. Inventory / cloud import
--- pipeline stamps this attribute on imported events; the user must explicitly clear
--- it via the UI's "Trust this asset" button after reviewing the Module source.
---
--- Snapshot shape per event:
---   {
---       Enabled         = true,            -- always true (gate is at the readEnabled level)
---       EmitMode        = "AtPosition",
---       ScriptEnabled   = false,
---       ChainDepthLimit = 4,
---       EmitTarget      = <Instance|nil>,  -- ObjectValue.Value snapshot
---       Module          = <ModuleScript|nil>,  -- only when ScriptEnabled
---   }
function EventsSchema.readEnabled(item)
	local folder = EventsSchema.read(item)
	if not folder then return nil end
	local out
	for _, name in ipairs(EVENT_NAMES) do
		-- Per-type validity gate: VALID_PER_TYPE forbids OnHit on Beam / PointLight /
		-- screens / ImageLabel because they have no discrete-particle collision concept.
		-- Sanitize removes invalid configs on save / import, but a hand-edited cfg between
		-- write and the next sanitize would otherwise reach the runtime path and crash
		-- (e.g. Beam has no .CFrame, so EventsCollision.readWorldCF errors). Filter here
		-- so readEnabled and the schema agree on what's runtime-eligible.
		if not EventsSchema.isValidForItem(item, name) then continue end
		local cfg = folder:FindFirstChild(name)
		if cfg and cfg:IsA("Configuration") and cfg:GetAttribute("Enabled") == true
			and not cfg:GetAttribute("ImportedUntrusted")
		then
			local et = cfg:FindFirstChild("EmitTarget")
			local scriptOn = cfg:GetAttribute("ScriptEnabled") == true
			local mod = scriptOn and cfg:FindFirstChild("Module") or nil
			if mod and not mod:IsA("ModuleScript") then mod = nil end
			out = out or {}
			out[name] = {
				Enabled         = true,
				EventName       = name,
				EmitMode        = safeEmitMode(cfg:GetAttribute("EmitMode")),
				ScriptEnabled   = scriptOn,
				ChainDepthLimit = clampDepthValue(cfg:GetAttribute("ChainDepthLimit")),
				EmitTarget      = et and et:IsA("ObjectValue") and et.Value or nil,
				Module          = mod,
				-- Collision is OnHit-only at runtime; cheap to include for all events.
				Collision       = safeCollisionMode(cfg:GetAttribute("Collision")),
				Bounciness      = clampUnit(cfg:GetAttribute("Bounciness"), 0, 1, 0.7),
				Friction        = clampUnit(cfg:GetAttribute("Friction"), 0, 1, 0.2),
				Spin            = clampUnit(cfg:GetAttribute("Spin"), 0, 2, 0.5),
				HitCheckInterval = clampUnit(cfg:GetAttribute("HitCheckInterval"), 0, 0.5, 0),
			}
		end
	end
	return out
end

--- Lazily create the Events folder under PartIcleProperties. Returns the folder.
function EventsSchema.ensure(item)
	local config = getConfig(item)
	if not config then return nil end
	local folder = config:FindFirstChild(EVENTS_FOLDER_NAME)
	if folder and folder:IsA("Folder") then return folder end
	-- Replace if a non-Folder instance with the reserved name slipped in.
	if folder then folder:Destroy() end
	folder = Instance.new("Folder")
	folder.Name = EVENTS_FOLDER_NAME
	folder.Parent = config
	return folder
end

--- Lazily create the per-event Configuration. Stamps default attributes and the Module
--- ModuleScript with the stub source. Refuses creation when the event isn't valid for
--- the item's type. Idempotent: returns existing cfg unchanged when already created.
function EventsSchema.ensureEvent(item, eventName)
	if not EventsSchema.isValidForItem(item, eventName) then return nil end
	local folder = EventsSchema.ensure(item)
	if not folder then return nil end
	local cfg = folder:FindFirstChild(eventName)
	if cfg and cfg:IsA("Configuration") then return cfg end
	if cfg then cfg:Destroy() end
	cfg = Instance.new("Configuration")
	cfg.Name = eventName
	for attrName, attrVal in pairs(DEFAULT_ATTRS) do
		cfg:SetAttribute(attrName, attrVal)
	end
	local emitTarget = Instance.new("ObjectValue")
	emitTarget.Name = "EmitTarget"
	emitTarget.Value = nil
	emitTarget.Parent = cfg
	local moduleScript = Instance.new("ModuleScript")
	moduleScript.Name = "Module"
	moduleScript.Source = DEFAULT_MODULE_SOURCE
	moduleScript.Parent = cfg
	cfg.Parent = folder
	return cfg
end

--- Toggle an event's Enabled attribute. Creates the per-event Configuration on first
--- enable; toggle-off keeps the cfg + Module on disk (user code is work, don't lose it
--- because they untoggled). Returns the cfg or nil if the event isn't valid here.
function EventsSchema.setEnabled(item, eventName, enabled)
	if enabled then
		local cfg = EventsSchema.ensureEvent(item, eventName)
		if not cfg then return nil end
		cfg:SetAttribute("Enabled", true)
		-- setEnabled MUST NOT clear ImportedUntrusted. Otherwise the ordinary event toggle
		-- becomes an implicit trust action. Trust requires the dedicated trustEvent /
		-- trustAllEvents methods, wired from a visible "Trust Script" UI action.
		--
		-- If the user toggles an untrusted event on without trusting first, readEnabled
		-- still gates on `not ImportedUntrusted` so the runtime stays safe.
		return cfg
	end
	local cfg = EventsSchema.readEvent(item, eventName)
	if not cfg then return nil end
	cfg:SetAttribute("Enabled", false)
	return cfg
end

--- Explicit user-driven trust action. Clears ImportedUntrusted on a single event.
--- UI ("Trust Script" button on the per-event row) calls this AFTER the user has
--- reviewed the Module source in Studio's Script Editor. Doesn't touch Enabled  - 
--- enabling is a separate user action via setEnabled.
function EventsSchema.trustEvent(item, eventName)
	local cfg = EventsSchema.readEvent(item, eventName)
	if not cfg then return false end
	if cfg:GetAttribute("ImportedUntrusted") then
		cfg:SetAttribute("ImportedUntrusted", nil)
		return true
	end
	return false
end

--- Bulk trust action. Clears ImportedUntrusted on every event under this item.
--- UI ("Trust Asset" button on the Inventory detail panel) calls this. Caller is
--- expected to confirm with the user (modal or inline confirm) before invoking;
--- this method is the schema-side write only.
function EventsSchema.trustAllEvents(item)
	local folder = EventsSchema.read(item)
	if not folder then return false end
	local cleared = false
	for _, cfg in ipairs(folder:GetChildren()) do
		if cfg:IsA("Configuration") and cfg:GetAttribute("ImportedUntrusted") then
			cfg:SetAttribute("ImportedUntrusted", nil)
			cleared = true
		end
	end
	return cleared
end

--- Stamp every event Configuration on this item with ImportedUntrusted=true and
--- Enabled=false. Called by the Inventory / cloud import pipeline after a fresh
--- DeserializeInstancesAsync call. Imported events can carry arbitrary Luau in the
--- Module ModuleScript that would execute on first event fire  -  fail-closed by
--- default so the user has to explicitly trust the asset before scripts run.
---
--- Clearing ImportedUntrusted requires the explicit trustEvent / trustAllEvents
--- methods (wired from a visible Trust Script / Trust Asset UI action). setEnabled
--- never clears the flag.
function EventsSchema.stampImportedUntrusted(item)
	local folder = EventsSchema.read(item)
	if not folder then return false end
	local stamped = false
	for _, cfg in ipairs(folder:GetChildren()) do
		if cfg:IsA("Configuration") then
			cfg:SetAttribute("ImportedUntrusted", true)
			cfg:SetAttribute("Enabled", false)
			stamped = true
		end
	end
	return stamped
end

--- Reset Event button: blow away the per-event Configuration (loses authored Module
--- source). Caller is expected to confirm with the user before invoking. Returns true
--- when something was deleted.
function EventsSchema.deleteEvent(item, eventName)
	local cfg = EventsSchema.readEvent(item, eventName)
	if not cfg then return false end
	cfg:Destroy()
	-- If the Events folder is now empty, delete it too. Keeps "no events configured"
	-- distinguishable from "events configured but all disabled".
	local folder = EventsSchema.read(item)
	if folder and #folder:GetChildren() == 0 then folder:Destroy() end
	return true
end

--- Sanity-repair the Events tree on this item. Called by Migrate.fix.
---  - Drops Folder/Configuration children whose names aren't in EVENT_NAMES.
---  - Drops events that aren't valid for this item's type (e.g. OnHit on a Beam).
---  - Backfills missing default attributes on existing event Configurations.
---  - Ensures every cfg has an EmitTarget ObjectValue + Module ModuleScript child.
---  - Moves a legacy per-event CollisionGroup / ExcludeList to the type-level HitFilter.
---  - Drops any `_CompiledEventModule` clones the runtime parented for caching.
--- Returns true if any change was made.
function EventsSchema.sanitize(item)
	local folder = EventsSchema.read(item)
	if not folder then return false end
	local changed = false
	local validSet = {}
	for _, n in ipairs(EVENT_NAMES) do validSet[n] = true end
	for _, child in ipairs(folder:GetChildren()) do
		-- Drop unrecognized siblings  -  anything not a per-event Configuration with a
		-- known event name. The compile-cache clones (named "_CompiledEventModule")
		-- live elsewhere, but if a clone leaked into the Events folder we kill it here.
		if not (child:IsA("Configuration") and validSet[child.Name]) then
			child:Destroy()
			changed = true
		elseif not EventsSchema.isValidForItem(item, child.Name) then
			-- Event name is known but doesn't apply to this type (OnHit on a Beam, etc.).
			child:Destroy()
			changed = true
		else
			-- Backfill missing default attributes.
			for attrName, defaultVal in pairs(DEFAULT_ATTRS) do
				if child:GetAttribute(attrName) == nil then
					child:SetAttribute(attrName, defaultVal)
					changed = true
				end
			end
			-- Clamp ChainDepthLimit to the documented 1..32 range. Drops any non-numeric
			-- value back to the default 4  -  protects runtime apply() / readEnabled from
			-- stringly-typed garbage data on disk-imported assets.
			local depth = child:GetAttribute("ChainDepthLimit")
			local clamped = clampDepthValue(depth)
			if depth ~= clamped then
				child:SetAttribute("ChainDepthLimit", clamped)
				changed = true
			end
			-- Snap EmitMode back to AtPosition when imported assets carry an unrecognized
			-- string. Mirrors safeEmitMode in readEnabled but at sanitize time so disk
			-- state matches runtime expectations.
			local mode = child:GetAttribute("EmitMode")
			local safe = safeEmitMode(mode)
			if mode ~= safe then
				child:SetAttribute("EmitMode", safe)
				changed = true
			end
			-- Same coercion for Collision. OnHit-only at runtime; non-OnHit events keep
			-- the attribute but it's inert. Imported assets with bogus values snap to "Off".
			local cmode = child:GetAttribute("Collision")
			local csafe = safeCollisionMode(cmode)
			if cmode ~= csafe then
				child:SetAttribute("Collision", csafe)
				changed = true
			end
			-- Clamp Bounciness / Friction / Spin to safe ranges. Backfill defaults if missing.
			local physicsRows = {
				{ name = "Bounciness",       lo = 0, hi = 1,   default = 0.7 },
				{ name = "Friction",         lo = 0, hi = 1,   default = 0.2 },
				{ name = "Spin",             lo = 0, hi = 2,   default = 0.5 },
				{ name = "HitCheckInterval", lo = 0, hi = 0.5, default = 0 },
			}
			for _, row in ipairs(physicsRows) do
				local raw = child:GetAttribute(row.name)
				local clamped = clampUnit(raw, row.lo, row.hi, row.default)
				if raw ~= clamped then
					child:SetAttribute(row.name, clamped)
					changed = true
				end
			end
			if HitFilter.migrateFromEvent(item, child) then changed = true end
			-- EmitTarget ObjectValue child.
			local et = child:FindFirstChild("EmitTarget")
			if not et or not et:IsA("ObjectValue") then
				if et then et:Destroy() end
				et = Instance.new("ObjectValue")
				et.Name = "EmitTarget"
				et.Parent = child
				changed = true
			end
			-- Module ModuleScript child.
			local mod = child:FindFirstChild("Module")
			if not mod or not mod:IsA("ModuleScript") then
				if mod then mod:Destroy() end
				mod = Instance.new("ModuleScript")
				mod.Name = "Module"
				mod.Source = DEFAULT_MODULE_SOURCE
				mod.Parent = child
				changed = true
			end
			-- Drop any stray cache clones siblings of Module.
			for _, sub in ipairs(child:GetChildren()) do
				if sub.Name == "_CompiledEventModule" then
					sub:Destroy()
					changed = true
				end
			end
		end
	end
	-- Empty-folder cleanup.
	if #folder:GetChildren() == 0 then
		folder:Destroy()
		changed = true
	end
	return changed
end

--- Capture the current Events tree as a plain Lua table for clipboard / migration use.
--- Returns nil when no events folder exists. Snapshot omits the cache clone since it's
--- runtime-only state.
---
--- Wired by `ClipShiftFix.luau` per-event clipboard copy/paste. ImportedUntrusted is
--- preserved through the snapshot/apply round-trip: a trusted event copied from one
--- item does NOT become trusted on the paste target if the source was untrusted, and
--- an untrusted event won't silently re-trust just by skipping the flag.
---
--- EmitTargetPresent flags ObjectValue presence on the source so apply() can
--- distinguish "source had no target, clear destination" from "source field
--- absent entirely, leave destination alone".
function EventsSchema.snapshot(item)
	local folder = EventsSchema.read(item)
	if not folder then return nil end
	local snap
	for _, name in ipairs(EVENT_NAMES) do
		local cfg = folder:FindFirstChild(name)
		if cfg and cfg:IsA("Configuration") then
			snap = snap or {}
			local entry = {
				Enabled           = cfg:GetAttribute("Enabled"),
				EmitMode          = cfg:GetAttribute("EmitMode"),
				ScriptEnabled     = cfg:GetAttribute("ScriptEnabled"),
				ChainDepthLimit   = cfg:GetAttribute("ChainDepthLimit"),
				Collision         = cfg:GetAttribute("Collision"),
				Bounciness        = cfg:GetAttribute("Bounciness"),
				Friction          = cfg:GetAttribute("Friction"),
				Spin              = cfg:GetAttribute("Spin"),
				HitCheckInterval  = cfg:GetAttribute("HitCheckInterval"),
				ImportedUntrusted = cfg:GetAttribute("ImportedUntrusted") == true,
			}
			local et = cfg:FindFirstChild("EmitTarget")
			-- EmitTarget.Value is an Instance ref. Resolution at apply time can't restore
			-- across game-tree boundaries (clipboard between places, asset-import) so the
			-- snapshot stores the FullName for diagnostic display + the live ref for same-
			-- session paste. Apply uses the live ref when valid; FullName is fallback log.
			if et and et:IsA("ObjectValue") then
				entry.EmitTargetPresent = true
				entry.EmitTargetValue = et.Value
				entry.EmitTargetPath = et.Value and et.Value:GetFullName() or nil
			end
			local mod = cfg:FindFirstChild("Module")
			if mod and mod:IsA("ModuleScript") then
				entry.ModuleSource = mod.Source
			end
			snap[name] = entry
		end
	end
	return snap
end

--- Apply a snapshot back onto an item. Skips events that aren't valid for this item's
--- type (snapshotting an OnHit from a Part and pasting onto a Beam silently drops the
--- OnHit entry). Existing events on the target are NOT pre-cleared  -  existing cfgs are
--- updated in-place; missing ones are created.
function EventsSchema.apply(item, snap)
	if not snap then return false end
	local applied = false
	for name, entry in pairs(snap) do
		if EventsSchema.isValidForItem(item, name) then
			local cfg = EventsSchema.ensureEvent(item, name)
			if cfg then
				if entry.Enabled ~= nil then cfg:SetAttribute("Enabled", entry.Enabled == true) end
				if entry.EmitMode ~= nil then cfg:SetAttribute("EmitMode", safeEmitMode(entry.EmitMode)) end
				if entry.ScriptEnabled ~= nil then cfg:SetAttribute("ScriptEnabled", entry.ScriptEnabled == true) end
				if entry.ChainDepthLimit ~= nil then
					cfg:SetAttribute("ChainDepthLimit", clampDepthValue(entry.ChainDepthLimit))
				end
				if entry.Collision ~= nil then
					cfg:SetAttribute("Collision", safeCollisionMode(entry.Collision))
				end
				if entry.Bounciness ~= nil then cfg:SetAttribute("Bounciness", clampUnit(entry.Bounciness, 0, 1, 0.7)) end
				if entry.Friction ~= nil then cfg:SetAttribute("Friction", clampUnit(entry.Friction, 0, 1, 0.2)) end
				if entry.Spin ~= nil then cfg:SetAttribute("Spin", clampUnit(entry.Spin, 0, 2, 0.5)) end
				if entry.HitCheckInterval ~= nil then cfg:SetAttribute("HitCheckInterval", clampUnit(entry.HitCheckInterval, 0, 0.5, 0)) end
				-- ImportedUntrusted round-trip: untrusted source stays untrusted, trusted
				-- source clears destination's untrusted flag. Paste of a trusted event
				-- onto a previously-imported untrusted destination unblocks the paste,
				-- because the user has now provided trusted source code by an explicit
				-- copy/paste action (clipboard is user-driven, unlike asset import).
				if entry.ImportedUntrusted == true then
					cfg:SetAttribute("ImportedUntrusted", true)
				else
					cfg:SetAttribute("ImportedUntrusted", nil)
				end
				local et = cfg:FindFirstChild("EmitTarget")
				if et and et:IsA("ObjectValue") and entry.EmitTargetPresent then
					-- Write even when EmitTargetValue is nil so paste can clear a
					-- stale destination target. Snapshot sets EmitTargetPresent
					-- whenever the source had an ObjectValue field.
					et.Value = entry.EmitTargetValue
				end
				local mod = cfg:FindFirstChild("Module")
				if mod and mod:IsA("ModuleScript") and entry.ModuleSource ~= nil then
					mod.Source = entry.ModuleSource
				end
				applied = true
			end
		end
	end
	return applied
end

return EventsSchema
