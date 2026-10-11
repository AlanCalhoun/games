-- Teleport path-stuck citizens to the embark wagon, or the trade depot if
-- the wagon is gone.
--@enable = true
--@module = true

local repeatutil = require('repeat-util')

local GLOBAL_KEY = 'malphars_unstuck'

enabled = enabled or false
local stuck_streak = stuck_streak or {}

function isEnabled()
    return enabled
end

local SKIP_JOB = {
    [df.job_type.Sleep] = true,
    [df.job_type.Rest] = true,
    [df.job_type.Eat] = true,
    [df.job_type.Drink] = true,
    [df.job_type.CleanSelf] = true,
}

local function wagon_pos()
    local depot, wagon
    for _, bld in ipairs(df.global.world.buildings.all) do
        local t = df.building_type[bld:getType()]
        if t == 'TradeDepot' and not depot then
            depot = bld
        elseif t == 'Wagon' and not wagon then
            wagon = bld
        end
    end
    local bld = wagon or depot
    if bld then
        return xyz2pos(bld.centerx, bld.centery, bld.z)
    end
    for _, bld in ipairs(df.global.world.buildings.all) do
        if df.building_civzonest:is_instance(bld) then
            return xyz2pos(bld.centerx, bld.centery, bld.z)
        end
    end
    return nil
end

local function unit_path_len(unit)
    local plen = 0
    pcall(function()
        plen = #unit.path.path.x
    end)
    return plen
end

local function is_path_stuck(unit)
    if not unit or not dfhack.units.isActive(unit) then return false end
    if not dfhack.units.isDwarf(unit) then return false end
    if dfhack.units.isGhost(unit) then return false end
    if dfhack.units.isDead(unit) then return false end
    if unit.flags1.caged or unit.flags1.chained then return false end
    local job = unit.job and unit.job.current_job
    if job and SKIP_JOB[job.job_type] then return false end
    local goal = unit.path and unit.path.goal or -1
    if not goal or goal < 0 then return false end
    return unit_path_len(unit) == 0
end

local function rescue_stuck()
    if not enabled or not dfhack.isMapLoaded() or not dfhack.world.isFortressMode() then
        return
    end
    local dest = wagon_pos()
    if not dest then return end
    local seen = {}
    local moved = 0
    for _, unit in pairs(dfhack.units.getCitizens(true)) do
        if unit and dfhack.units.isCitizen(unit, true) then
            seen[unit.id] = true
            if is_path_stuck(unit) then
                stuck_streak[unit.id] = (stuck_streak[unit.id] or 0) + 1
                -- two polls (~200 ticks) before yanking
                if stuck_streak[unit.id] >= 2 then
                    local ok, res = pcall(dfhack.units.teleport, unit, dest)
                    if ok and res then
                        stuck_streak[unit.id] = 0
                        moved = moved + 1
                        pcall(function()
                            unit.path.goal = -1
                            unit.path.path.x:resize(0)
                            unit.path.path.y:resize(0)
                            unit.path.path.z:resize(0)
                        end)
                    end
                end
            else
                stuck_streak[unit.id] = 0
            end
        end
    end
    for id in pairs(stuck_streak) do
        if not seen[id] then stuck_streak[id] = nil end
    end
    if moved > 0 then
        print(("Malphar's Mod: moved %d stuck dwarf(s) to wagon/depot @ %d,%d,%d"):format(
            moved, dest.x, dest.y, dest.z))
    end
end

local function do_enable()
    enabled = true
    stuck_streak = {}
    repeatutil.scheduleEvery(GLOBAL_KEY, 100, 'ticks', rescue_stuck)
    rescue_stuck()
    print("Malphar's Mod: stuck dwarves teleport to the wagon / trade depot.")
end

local function do_disable()
    enabled = false
    stuck_streak = {}
    repeatutil.cancel(GLOBAL_KEY)
    print("Malphar's Mod: stuck-dwarf rescue is off.")
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        enabled = false
        stuck_streak = {}
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
