-- Power every pump, millstone, and roller by itself. No axles, windmills, or
-- water wheels required. Machine power need is forced to zero.
--
-- On/off: build a gear assembly next to the machines (no axle link), link a
-- lever to that gear. Engaged = on, disengaged = off for consumers near that
-- gear only. Vanilla cannot link levers to pumps — use a gear as the switch.
--@enable = true
--@module = true

local repeatutil = require('repeat-util')

local GLOBAL_KEY = 'malphars_power'
local POWER_SURPLUS = 100000
-- Only nearby standalone switch gears toggle machines (not old power-train gears).
local SWITCH_RADIUS = 8
local SWITCH_Z = 10
local PUMP_ENERGY = 50

enabled = enabled or false

function isEnabled()
    return enabled
end

local function is_millstone(bld)
    return bld and df.building_type[bld:getType()] == 'Workshop'
        and bld.type == df.workshop_type.Millstone
end

local function needs_own_power(bld)
    if not bld then return false end
    local t = bld:getType()
    return t == df.building_type.ScrewPump
        or t == df.building_type.Rollers
        or is_millstone(bld)
end

local function next_machine_id()
    local max_id = 0
    local machines = df.global.world.machines.all
    if machines then
        for _, machine in ipairs(machines) do
            if machine and machine.id and machine.id > max_id then
                max_id = machine.id
            end
        end
    end
    return max_id + 1
end

local function machine_for_building(bld)
    if not bld then return nil end
    local mid = -1
    pcall(function()
        mid = bld.machine.machine_id
    end)
    if mid and mid >= 0 then
        local by_id = df.machine.find(mid)
        if by_id then return by_id end
    end
    local machines = df.global.world.machines.all
    if not machines then return nil end
    for _, machine in ipairs(machines) do
        if machine and machine.components then
            for _, node in ipairs(machine.components) do
                if node.building_id == bld.id then
                    return machine
                end
            end
        end
    end
end

-- Standalone gear (not wired into axles/wheels/pumps) used as a lever switch.
local function is_switch_gear(gear)
    if not gear or gear:getType() ~= df.building_type.GearAssembly then
        return false
    end
    local mid = -1
    pcall(function() mid = gear.machine.machine_id end)
    if not mid or mid < 0 then return true end
    local machine = df.machine.find(mid)
    if not machine or not machine.components then return true end
    for _, node in ipairs(machine.components) do
        if node.building_id ~= gear.id then
            local other = df.building.find(node.building_id)
            if other then
                local t = other:getType()
                if t == df.building_type.AxleHorizontal
                    or t == df.building_type.AxleVertical
                    or t == df.building_type.WaterWheel
                    or t == df.building_type.Windmill
                    or t == df.building_type.ScrewPump
                    or t == df.building_type.Rollers
                    or t == df.building_type.GearAssembly then
                    return false
                end
            end
        end
    end
    return true
end

local function juice_machine(machine)
    if not machine then return end
    pcall(function()
        if machine.flags then
            machine.flags.frozen = false
            machine.flags.active = true
        end
    end)
    machine.min_power = 0
    machine.cur_power = POWER_SURPLUS
end

local function kill_machine(machine)
    if not machine then return end
    pcall(function()
        if machine.flags then
            machine.flags.active = false
            machine.flags.frozen = true
        end
    end)
    machine.cur_power = 0
end

local function ensure_machine(bld)
    local machine = machine_for_building(bld)
    if machine then return machine end
    local ok, created = pcall(function()
        local mach = df.machine_standardst:new()
        mach.x = bld.centerx
        mach.y = bld.centery
        mach.z = bld.z
        mach.id = next_machine_id()
        mach.min_power = 0
        mach.cur_power = POWER_SURPLUS
        mach.flags.active = true
        mach.flags.frozen = false
        local node = df.machine_nodest:new()
        node.building_id = bld.id
        mach.components:insert('#', node)
        df.global.world.machines.all:insert('#', mach)
        bld.machine.machine_id = mach.id
        if bld.machine.flags then
            bld.machine.flags.frozen = false
        end
        return mach
    end)
    if ok then return created end
end

local function within_switch_range(switch_bld, bld)
    local dx = switch_bld.centerx - bld.centerx
    local dy = switch_bld.centery - bld.centery
    local dz = switch_bld.z - bld.z
    return (dx * dx + dy * dy) <= (SWITCH_RADIUS * SWITCH_RADIUS)
        and math.abs(dz) <= SWITCH_Z
end

local function switched_off_ids()
    local off = {}
    for _, bld in ipairs(df.global.world.buildings.all) do
        if df.building_type[bld:getType()] == 'Trap'
            and bld.trap_type == df.trap_type.Lever
            and bld.linked_mechanisms then
            for _, mech in ipairs(bld.linked_mechanisms) do
                local target
                pcall(function()
                    local tref = dfhack.items.getGeneralRef(
                        mech, df.general_ref_type.BUILDING_HOLDER)
                    if tref then target = tref:getBuilding() end
                end)
                if target and is_switch_gear(target) then
                    local disengaged = false
                    pcall(function()
                        disengaged = target.gear_flags.disengaged
                    end)
                    if disengaged then
                        for _, other in ipairs(df.global.world.buildings.all) do
                            if needs_own_power(other)
                                and within_switch_range(target, other) then
                                off[other.id] = true
                            end
                        end
                    end
                end
            end
        end
    end
    return off
end

local function power_building(bld)
    pcall(function()
        if bld.machine and bld.machine.flags then
            bld.machine.flags.frozen = false
        end
    end)
    juice_machine(ensure_machine(bld))
    -- Screw pumps need energy ticks to actually move fluid.
    pcall(function()
        if bld.pump_energy ~= nil and bld.pump_energy < PUMP_ENERGY then
            bld.pump_energy = PUMP_ENERGY
        end
    end)
end

local function depower_building(bld)
    pcall(function()
        if bld.machine and bld.machine.flags then
            bld.machine.flags.frozen = true
        end
    end)
    local machine = machine_for_building(bld) or ensure_machine(bld)
    kill_machine(machine)
    pcall(function()
        if bld.pump_energy ~= nil then bld.pump_energy = 0 end
    end)
end

local function ensure_power()
    if not enabled or not dfhack.isMapLoaded() or not dfhack.world.isFortressMode() then
        return
    end
    local off = switched_off_ids()

    local machines = df.global.world.machines.all
    if machines then
        for _, machine in ipairs(machines) do
            local blocked = false
            if machine.components then
                for _, node in ipairs(machine.components) do
                    if off[node.building_id] then
                        blocked = true
                        break
                    end
                end
            end
            if blocked then
                kill_machine(machine)
            else
                juice_machine(machine)
            end
        end
    end

    for _, bld in ipairs(df.global.world.buildings.all) do
        if needs_own_power(bld) then
            if off[bld.id] then
                depower_building(bld)
            else
                power_building(bld)
            end
        end
    end
end

local function do_enable()
    enabled = true
    repeatutil.scheduleEvery(GLOBAL_KEY, 5, 'ticks', ensure_power)
    ensure_power()
    print("Malphar's Mod: pumps/mills/rollers self-powered. Lever+nearby gear = on/off.")
end

local function do_disable()
    enabled = false
    repeatutil.cancel(GLOBAL_KEY)
    print("Malphar's Mod: auto-power is off.")
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        enabled = false
        repeatutil.cancel(GLOBAL_KEY)
        return
    end
    if sc ~= SC_MAP_LOADED or not dfhack.world.isFortressMode() then
        return
    end
    do_enable()
end

if dfhack_flags.enable then
    if dfhack_flags.enable_state then
        if dfhack.isMapLoaded() and dfhack.world.isFortressMode() then
            do_enable()
        else
            enabled = true
        end
    else
        do_disable()
    end
    return
end

if dfhack_flags.module then
    return
end

if dfhack.isMapLoaded() and dfhack.world.isFortressMode() then
    do_enable()
end
