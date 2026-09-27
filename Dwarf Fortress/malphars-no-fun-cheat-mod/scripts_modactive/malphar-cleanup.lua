-- Remove animal corpses and refuse. Leave people for burial.
--@enable = true
--@module = true

local repeatutil = require('repeat-util')

local GLOBAL_KEY = 'malphars_cleanup'
local REMOVE_CAP = 80

enabled = enabled or false
local person_cache = {}

function isEnabled()
    return enabled
end

local function flag_on(flags, name)
    if not flags then return false end
    local ok, yes = pcall(function() return flags[name] end)
    return ok and yes == true
end

local function is_person(race)
    if race == nil or race < 0 then return true end
    local cached = person_cache[race]
    if cached ~= nil then return cached end
    local person = false
    local cre = df.global.world.raws.creatures.all[race]
    if not cre then
        person = true
    else
        local function check(flags)
            return flag_on(flags, 'INTELLIGENT')
                or flag_on(flags, 'CAN_LEARN')
                or flag_on(flags, 'CAN_SPEAK')
        end
        if check(cre.flags) then
            person = true
        elseif cre.caste then
            for i = 0, #cre.caste - 1 do
                local caste = cre.caste[i]
                if caste and check(caste.flags) then
                    person = true
                    break
                end
            end
        end
    end
    person_cache[race] = person
    return person
end

local function corpse_race(item)
    local race = nil
    pcall(function() race = item.race end)
    return race
end

local function can_remove(item)
    return item
        and not item.flags.garbage_collect
        and not item.flags.in_job
        and not item.flags.construction
        and not item.flags.artifact
end

local function sweep()
    if not enabled or not dfhack.isMapLoaded() or not dfhack.world.isFortressMode() then
        return
    end
    local removed = 0
    local others = df.global.world.items.other
    local function take(item)
        if removed >= REMOVE_CAP or not can_remove(item) then return end
        local ok = pcall(dfhack.items.remove, item)
        if ok then removed = removed + 1 end
    end
    local remains = others.REMAINS
    if remains then
        for _, item in ipairs(remains) do
            if removed >= REMOVE_CAP then break end
            take(item)
        end
    end
    for _, name in ipairs({'CORPSE', 'CORPSEPIECE'}) do
        local list = others[name]
        if list then
            for _, item in ipairs(list) do
                if removed >= REMOVE_CAP then break end
                if can_remove(item) and not is_person(corpse_race(item)) then
                    take(item)
                end
            end
        end
    end
end

local function do_enable()
    enabled = true
    person_cache = {}
    sweep()
    repeatutil.scheduleEvery(GLOBAL_KEY, 200, 'ticks', sweep)
    print("Malphar's Mod: animal corpses and refuse are removed. People are left for burial.")
end

local function do_disable()
    enabled = false
    repeatutil.cancel(GLOBAL_KEY)
    print("Malphar's Mod: corpse cleanup is off.")
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        enabled = false
        person_cache = {}
        repeatutil.cancel(GLOBAL_KEY)
        dfhack.onStateChange[GLOBAL_KEY] = nil
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
