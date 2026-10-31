-- Hard Braking: tyre screech and skid marks on asphalt and concrete when you brake hard.
-- Author: FS Modding
HardBraking = {}

local modDirectory = g_currentModDirectory

-- ---------------------------------------------------------------- settings
HardBraking.MIN_SPEED = 20            -- km/h, below this no hard braking starts
HardBraking.STOP_SPEED = 3            -- km/h, skidding ends below this
HardBraking.PEDAL = 0.7               -- brake pedal pressed at least this much
HardBraking.DECEL_PEDAL = 2.5         -- m/s2 slowing down with the brake pedal pressed
HardBraking.DECEL_ANY = 6.0           -- m/s2 slowing down without pedal (helpers, other players, crashes)
HardBraking.SEG_LEN = 0.3             -- m, length of one skid mark piece
HardBraking.MARK_HEIGHT = 0.012       -- m above the road
HardBraking.MAX_MARKS = 4000          -- pieces on the map, the oldest go first
HardBraking.MARK_LIFE = 30            -- real minutes a skid mark stays
HardBraking.VOLUME = 1.0
HardBraking.SOUND_RANGE = 120         -- m the screech is heard
HardBraking.HARD_WORDS = { "asphalt", "concrete", "tarmac", "road", "cobble", "pavement", "paving", "street", "beton", "stone", "tile" }

-- ---------------------------------------------------------------- state
HardBraking.states = {}               -- [vehicle] = { lastSpeed, decel, skidding, sound, ... }
HardBraking.marks = {}                -- { node, time }
HardBraking.logged = {}
HardBraking.time = 0

local function logOnce(key, text, ...)
    if HardBraking.logged[key] then return end
    HardBraking.logged[key] = true
    Logging.info("[HardBraking] " .. text, ...)
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function getControlledVehicle()
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        local v = g_localPlayer:getCurrentVehicle()
        if v ~= nil then return v end
    end
    local m = g_currentMission
    if m ~= nil and m.controlledVehicle ~= nil then return m.controlledVehicle end
    return nil
end

local function isHardName(name)
    if name == nil then return false end
    name = string.lower(tostring(name))
    for _, w in ipairs(HardBraking.HARD_WORDS) do
        if string.find(name, w, 1, true) then return true end
    end
    return false
end

-- ---------------------------------------------------------------- skid mark model

function HardBraking:loadTemplate()
    local path = modDirectory .. "i3d/hardBraking.i3d"
    local root = nil
    if g_i3DManager ~= nil and g_i3DManager.loadI3DFile ~= nil then
        root = g_i3DManager:loadI3DFile(path, false, false)
    elseif loadI3DFile ~= nil then
        root = loadI3DFile(path, false, false, false)
    end
    if root == nil or root == 0 then
        Logging.warning("[HardBraking] could not load %s", path)
        return
    end
    link(getRootNode(), root)
    setVisibility(root, false)
    self.templateRoot = root
    local group = getChildAt(root, 0)
    self.template = getChildAt(group, 0)
    Logging.info("[HardBraking] skid mark model loaded")
end

function HardBraking:addMark(x1, y1, z1, x2, y2, z2, width)
    if self.template == nil then return end
    local dx, dy, dz = x2 - x1, y2 - y1, z2 - z1
    local flat = math.sqrt(dx * dx + dz * dz)
    if flat < 0.01 then return end
    local node = clone(self.template, false, false, false)
    if node == nil or node == 0 then return end
    link(getRootNode(), node)
    setVisibility(node, true)
    setTranslation(node, (x1 + x2) * 0.5, (y1 + y2) * 0.5 + self.MARK_HEIGHT, (z1 + z2) * 0.5)
    setRotation(node, -math.atan(dy / flat), math.atan2(dx, dz), 0)
    setScale(node, width, 1, flat + 0.03)
    table.insert(self.marks, { node = node, time = self.time })
    while #self.marks > self.MAX_MARKS do
        local old = table.remove(self.marks, 1)
        if entityExists(old.node) then delete(old.node) end
    end
end

function HardBraking:updateMarks()
    local life = self.MARK_LIFE * 60000
    while #self.marks > 0 and self.time - self.marks[1].time > life do
        local old = table.remove(self.marks, 1)
        if entityExists(old.node) then delete(old.node) end
    end
end

function HardBraking:clearMarks()
    for _, m in ipairs(self.marks) do
        if entityExists(m.node) then delete(m.node) end
    end
    self.marks = {}
end

-- ---------------------------------------------------------------- wheels and surface

local function wheelParts(wheel)
    local ph = type(wheel.physics) == "table" and wheel.physics or wheel
    local node = wheel.node or ph.node
    local shape = ph.wheelShape or wheel.wheelShape
    local center = wheel.driveNode or ph.driveNode or wheel.repr or ph.repr or wheel.linkNode
    local radius = ph.radius or wheel.radius or 0.5
    local width = ph.width or wheel.width or 0.4
    return node, shape, center, radius, width
end

-- the surface name the game uses for tyre sounds on this vehicle
local function surfaceName(vehicle)
    if vehicle.getCurrentSurfaceSound ~= nil then
        local s = vehicle:getCurrentSurfaceSound()
        if type(s) == "table" then
            return s.name or s.sampleName or s.type
        end
    end
    return nil
end

local function isOnField(x, z)
    local m = g_currentMission
    if m == nil or m.fieldGroundSystem == nil or FieldDensityMap == nil then return false end
    local v = m.fieldGroundSystem:getValueAtWorldPos(FieldDensityMap.GROUND_TYPE, x, 0, z)
    return v ~= nil and v ~= 0
end


-- contact point of a wheel and whether it is on asphalt / concrete
local function keysOf(t)
    local keys = {}
    for k, v in pairs(t) do table.insert(keys, tostring(k) .. "=" .. type(v)) end
    table.sort(keys)
    return table.concat(keys, ", ")
end

function HardBraking:wheelContact(vehicle, wheel, surface)
    local node, shape, center, radius, width = wheelParts(wheel)
    if not self.logged.wheel then
        logOnce("wheel", "wheel values: %s", keysOf(wheel))
        if type(wheel.physics) == "table" then logOnce("wheelPhysics", "wheel physics values: %s", keysOf(wheel.physics)) end
        logOnce("wheelParts", "wheel node %s, shape %s, center %s, radius %.2f, width %.2f, contact functions %s, surface sound %s",
            tostring(node), tostring(shape), tostring(center), radius, width,
            tostring(getWheelShapeContactObject ~= nil), tostring(vehicle.getCurrentSurfaceSound ~= nil))
    end
    local x, y, z
    local onObject = nil
    if node ~= nil and shape ~= nil and shape ~= 0 and getWheelShapeContactObject ~= nil then
        local obj = getWheelShapeContactObject(node, shape)
        if obj == nil or obj == 0 then return nil end          -- in the air
        local terrain = g_currentMission.terrainRootNode
        onObject = obj ~= terrain
        if getWheelShapeContactPoint ~= nil then
            x, y, z = getWheelShapeContactPoint(node, shape)
        end
    end
    if x == nil or (x == 0 and y == 0 and z == 0) then
        if center == nil or not entityExists(center) then return nil end
        x, y, z = getWorldTranslation(center)
        y = y - radius
    end
    if isOnField(x, z) then return nil end

    local hard
    if surface ~= nil then
        hard = isHardName(surface)
    else
        -- no surface from the game (some trailers): on a road object = asphalt
        hard = onObject == true
    end
    if not hard then return nil end
    return x, y, z, width
end

local function vehicleChain(vehicle)
    local list, seen = { vehicle }, { [vehicle] = true }
    if vehicle.getChildVehicles ~= nil then
        for _, v in pairs(vehicle:getChildVehicles()) do
            if not seen[v] then
                seen[v] = true
                table.insert(list, v)
            end
        end
    end
    return list
end

-- ---------------------------------------------------------------- sound

function HardBraking:getSound(vehicle, state)
    if state.sound ~= nil then return state.sound end
    state.sound = false
    if createAudioSource == nil or getAudioSourceSample == nil then
        logOnce("nosound", "no audio functions, no screech sound")
        return false
    end
    local node = createAudioSource("hardBrakingScreech", modDirectory .. "sounds/tireScreech.ogg", self.SOUND_RANGE, 8, 1, 0)
    if node == nil or node == 0 then return false end
    if setAudioSourceAutoPlay ~= nil then setAudioSourceAutoPlay(node, false) end
    link(vehicle.rootNode, node)
    setTranslation(node, 0, 0.5, 0)
    local sample = getAudioSourceSample(node)
    if setSampleGroup ~= nil and AudioGroup ~= nil and AudioGroup.VEHICLE ~= nil then
        setSampleGroup(sample, AudioGroup.VEHICLE)
    end
    state.sound = { node = node, sample = sample, playing = false, volume = 0 }
    logOnce("sound", "screech sound loaded")
    return state.sound
end

function HardBraking:updateSound(vehicle, state, target, speed, dt)
    if target <= 0 and (state.sound == nil or not state.sound or not state.sound.playing) then return end
    local snd = self:getSound(vehicle, state)
    if not snd or not entityExists(snd.node) then return end
    -- quick fade in, a bit slower fade out
    local rate = target > snd.volume and dt / 80 or dt / 250
    if target > snd.volume then
        snd.volume = math.min(target, snd.volume + rate)
    else
        snd.volume = math.max(target, snd.volume - rate)
    end
    if snd.volume > 0.01 then
        if not snd.playing then
            playSample(snd.sample, 0, snd.volume, 0, 0, 0)
            snd.playing = true
        end
        setSampleVolume(snd.sample, snd.volume)
        if setSamplePitch ~= nil then setSamplePitch(snd.sample, 0.85 + 0.25 * clamp(speed / 60, 0, 1)) end
    elseif snd.playing then
        stopSample(snd.sample, 0, 0)
        snd.playing = false
    end
end

-- ---------------------------------------------------------------- braking

-- how much the brake pedal is pressed (0..1), nil when unknown
local function brakePedal(vehicle)
    local spec = vehicle.spec_drivable
    if spec == nil or type(spec.axisForward) ~= "number" then return nil end
    local dir = vehicle.movingDirection or 1
    if dir == 0 then dir = 1 end
    local b = -spec.axisForward * dir
    return b > 0 and b or 0
end

function HardBraking:updateVehicle(vehicle, dt, isPlayer)
    local state = self.states[vehicle]
    if state == nil then
        state = { lastSpeed = 0, decel = 0, skidding = false, test = 0, points = {}, lock = {} }
        self.states[vehicle] = state
    end
    local speed = vehicle.getLastSpeed ~= nil and vehicle:getLastSpeed() or 0
    local s = math.max(dt, 1) / 1000
    local decel = math.max(0, -((speed - state.lastSpeed) / 3.6) / s)
    state.lastSpeed = speed
    state.decel = state.decel + (decel - state.decel) * math.min(1, s * 8)

    local pedal = isPlayer and brakePedal(vehicle) or nil
    state.pedal = pedal
    local hardPedal = pedal ~= nil and pedal >= self.PEDAL
    if state.test > 0 then state.test = state.test - dt end

    if not state.skidding then
        if state.test > 0 and speed > self.STOP_SPEED then
            state.skidding = true
        elseif speed > self.MIN_SPEED and ((hardPedal and state.decel > self.DECEL_PEDAL) or state.decel > self.DECEL_ANY) then
            state.skidding = true
        end
    elseif speed < self.STOP_SPEED or (state.test <= 0 and not hardPedal and state.decel < self.DECEL_PEDAL * 0.6) then
        state.skidding = false
    end

    local onHard = 0
    if state.skidding then
        for _, v in ipairs(vehicleChain(vehicle)) do
            local spec = v.spec_wheels
            if spec ~= nil and spec.wheels ~= nil then
                local surface = surfaceName(v)
                if surface ~= nil and surface ~= state.lastSurface then
                    state.lastSurface = surface
                    Logging.info("[HardBraking] %s surface: %s", v:getName(), tostring(surface))
                end
                for _, wheel in ipairs(spec.wheels) do
                    local x, y, z, width = self:wheelContact(v, wheel, surface)
                    local last = state.points[wheel]
                    if x ~= nil then
                        onHard = onHard + 1
                        if last == nil then
                            state.points[wheel] = { x, y, z }
                        else
                            local dx, dz = x - last[1], z - last[3]
                            local d = math.sqrt(dx * dx + dz * dz)
                            if d > 3 then
                                state.points[wheel] = { x, y, z }
                            elseif d >= self.SEG_LEN then
                                self:addMark(last[1], last[2], last[3], x, y, z, width)
                                state.points[wheel] = { x, y, z }
                            end
                        end
                    else
                        state.points[wheel] = nil
                    end
                end
            end
        end
    else
        state.points = {}
        state.lock = {}
    end
    state.onHard = onHard

    local target = 0
    if state.skidding and onHard > 0 then
        target = self.VOLUME * clamp(0.55 + 0.45 * clamp(speed / 50, 0, 1), 0, 1)
    end
    self:updateSound(vehicle, state, target, speed, dt)
end

function HardBraking:update(dt)
    if g_currentMission == nil or g_currentMission.vehicleSystem == nil then return end
    if g_currentMission.getIsClient ~= nil and not g_currentMission:getIsClient() then return end
    self.time = self.time + dt
    if not self.loaded then
        self.loaded = true
        self:loadTemplate()
    end
    local player = getControlledVehicle()
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle.spec_drivable ~= nil and vehicle.rootNode ~= nil and entityExists(vehicle.rootNode)
            and (vehicle.rootVehicle == nil or vehicle.rootVehicle == vehicle) then
            self:updateVehicle(vehicle, dt, vehicle == player)
        end
    end
    for vehicle, state in pairs(self.states) do
        if vehicle.rootNode == nil or not entityExists(vehicle.rootNode) then
            self.states[vehicle] = nil
        end
    end
    self:updateMarks()
end

function HardBraking:deleteMap()
    self:clearMarks()
    if self.templateRoot ~= nil and entityExists(self.templateRoot) then delete(self.templateRoot) end
    self.templateRoot, self.template = nil, nil
    self.states = {}
end

-- ---------------------------------------------------------------- console

function HardBraking:consoleInfo()
    local v = getControlledVehicle()
    local s = v ~= nil and HardBraking.states[v] or nil
    if s == nil then return "get in a vehicle" end
    local wheels = v.spec_wheels ~= nil and v.spec_wheels.wheels or {}
    return string.format("speed %.0f km/h, slowing %.1f m/s2, brake pedal %s, skidding %s, wheels on asphalt/concrete %d of %d, surface %s, skid marks %d",
        s.lastSpeed, s.decel, s.pedal ~= nil and string.format("%.2f", s.pedal) or "unknown", tostring(s.skidding),
        s.onHard or 0, #wheels, tostring(surfaceName(v)), #HardBraking.marks)
end
addConsoleCommand("hbInfo", "Hard braking status", "consoleInfo", HardBraking)

function HardBraking:consoleTest()
    local v = getControlledVehicle()
    local s = v ~= nil and HardBraking.states[v] or nil
    if s == nil then return "get in a vehicle" end
    s.test = 3000
    return "skid for 3 seconds (drive on asphalt or concrete)"
end
addConsoleCommand("hbTest", "Skid for 3 seconds", "consoleTest", HardBraking)

function HardBraking:consoleClear()
    local n = #HardBraking.marks
    HardBraking:clearMarks()
    return string.format("%d skid marks removed", n)
end
addConsoleCommand("hbClear", "Remove all skid marks", "consoleClear", HardBraking)

function HardBraking:consoleVolume(v)
    v = tonumber(v)
    if v ~= nil then HardBraking.VOLUME = clamp(v, 0, 2) end
    return string.format("screech volume %.2f (hbVolume 0..2)", HardBraking.VOLUME)
end
addConsoleCommand("hbVolume", "Screech volume: hbVolume 0..2", "consoleVolume", HardBraking)

function HardBraking:consoleSensitivity(v)
    v = tonumber(v)
    if v ~= nil then HardBraking.DECEL_PEDAL = clamp(v, 0.5, 10) end
    return string.format("hard braking from %.1f m/s2 slowing down (lower = easier)", HardBraking.DECEL_PEDAL)
end
addConsoleCommand("hbSensitivity", "Slowing down needed for hard braking in m/s2 (default 2.5)", "consoleSensitivity", HardBraking)

-- ---------------------------------------------------------------- locked wheels while skidding

-- the node the game turns when the wheel rolls
local function driveNodeOf(wheel)
    local ph = type(wheel.physics) == "table" and wheel.physics or nil
    local node = wheel.driveNode or (ph ~= nil and ph.driveNode) or nil
    if node == nil and type(wheel.visualWheels) == "table" and wheel.visualWheels[1] ~= nil then
        local vw = wheel.visualWheels[1]
        node = vw.driveNode or vw.node
    end
    if node ~= nil and node ~= 0 and entityExists(node) then return node end
    return nil
end

-- after the game turned the wheels: hold them where they were when the skid started
function HardBraking:applyLocks(vehicle)
    local root = vehicle.rootVehicle or vehicle
    local state = self.states[root]
    if state == nil or not state.skidding then return end
    local spec = vehicle.spec_wheels
    if spec == nil or spec.wheels == nil then return end
    for _, wheel in ipairs(spec.wheels) do
        local node = driveNodeOf(wheel)
        if node ~= nil then
            local rx, ry, rz = getRotation(node)
            local lx = state.lock[node]
            if lx == nil then
                state.lock[node] = rx
                logOnce("lock", "wheels lock while skidding")
            else
                setRotation(node, lx, ry, rz)
            end
        else
            logOnce("nolock", "no drive node on the wheels of %s, wheels can not lock", vehicle:getName())
        end
    end
end

if Wheels ~= nil then
    for _, name in ipairs({ "onUpdate", "onUpdateTick", "onPostUpdate" }) do
        if Wheels[name] ~= nil then
            Wheels[name] = Utils.appendedFunction(Wheels[name], function(vehicle, ...)
                HardBraking:applyLocks(vehicle)
            end)
        end
    end
end

addModEventListener(HardBraking)
