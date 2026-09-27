-- Keep DFHack superdwarf on for fortress citizens while this mod is active.
--@enable = true
--@module = true

local eventful = require('plugins.eventful')
local repeatutil = require('repeat-util')

local GLOBAL_KEY = 'malphars_mod'

enabled = enabled or false

function isEnabled()
    return enabled
end

local function apply_citizens()
    if not enabled or not dfhack.isMapLoaded() then return end
    local superdwarf = reqscript('superdwarf')
    if not superdwarf or not superdwarf.superUnits or not superdwarf.main then return end
    for _, unit in pairs(dfhack.units.getCitizens()) do
        if unit and not superdwarf.superUnits[unit.id] then
            superdwarf.main({'add', tostring(unit.id)})
        end
    end
end

local function on_new_unit(unit_id)
    if not enabled then return end
    local unit = df.unit.find(unit_id)
    if unit and dfhack.units.isCitizen(unit, true) then
        apply_citizens()
    end
end

local function do_enable()
    enabled = true
    eventful.enableEvent(eventful.eventType.UNIT_NEW_ACTIVE, 5)
    eventful.onUnitNewActive[GLOBAL_KEY] = on_new_unit
    apply_citizens()
    repeatutil.scheduleEvery(GLOBAL_KEY, 1, 'days', apply_citizens)
    print('Malphar\'s Mod: superdwarf is on. Citizens finish jobs immediately.')
end

local function do_disable()
    enabled = false
    eventful.onUnitNewActive[GLOBAL_KEY] = nil
    repeatutil.cancel(GLOBAL_KEY)
    if dfhack.isMapLoaded() then
        local superdwarf = reqscript('superdwarf')
        if superdwarf and superdwarf.main then
            superdwarf.main({'clear'})
        end
    end
    print('Malphar\'s Mod: superdwarf is off.')
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        enabled = false
        eventful.onUnitNewActive[GLOBAL_KEY] = nil
        repeatutil.cancel(GLOBAL_KEY)
        dfhack.onStateChange[GLOBAL_KEY] = nil
        return
    end
    if sc ~= SC_MAP_LOADED or not dfhack.world.isFortressMode() then
        return
    end
    do_enable()
end

if dfhack_flags.module then
    return
end

if dfhack_flags.enable then
    if dfhack_flags.enable_state then
        enabled = true
        if dfhack.isMapLoaded() and dfhack.world.isFortressMode() then
            do_enable()
        end
    else
        do_disable()
    end
    return
end

if dfhack.isMapLoaded() and dfhack.world.isFortressMode() then
    enabled = true
    do_enable()
end
