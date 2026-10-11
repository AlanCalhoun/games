-- Hide loose mined stone and rough gems. That is all.
-- Furniture and other build items are never touched.
--@enable = true
--@module = true

local repeatutil = require('repeat-util')

local GLOBAL_KEY = 'malphars_hide_rubble'
local MINED = {
    [df.item_type.BOULDER] = true,
    [df.item_type.ROUGH] = true,
}

enabled = enabled or false

function isEnabled()
    return enabled
end

local function stocked_ids()
    local stocked = {}
    local piles = df.global.world.buildings.other.STOCKPILE
    if not piles then return stocked end
    for i = 0, #piles - 1 do
        local stockpile = piles[i]
        if not stockpile then goto continue end
        local ok, contents = pcall(dfhack.buildings.getStockpileContents, stockpile)
        if ok and contents then
            for _, item in ipairs(contents) do
                stocked[item.id] = true
            end
        end
        ::continue::
    end
    return stocked
end

local function hide_one(item, stocked)
    if not item then return end
    local flags = item.flags
    if not flags then return end
    if flags.construction or flags.in_building or flags.garbage_collect
        or flags.artifact or flags.in_job or flags.in_inventory
        or flags.removed
    then
        return
    end
    if stocked and stocked[item.id] then
        flags.hidden = false
        return
    end
    if flags.on_ground then
        -- Forbid/owned rubble still clutters the view — hide it anyway.
        flags.hidden = true
    end
end

local function each(list, fn)
    if not list then return end
    local ok, len = pcall(function() return #list end)
    if not ok or type(len) ~= 'number' then return end
    for i = 0, len - 1 do
        local item_ok, item = pcall(function() return list[i] end)
        if item_ok and item then fn(item) end
    end
end

local function sweep()
    if not enabled or not dfhack.isMapLoaded() or not dfhack.world.isFortressMode() then
        return
    end
    local stocked = stocked_ids()
    local others = df.global.world.items.other
    if not others then return end
    each(others.BOULDER, function(item) hide_one(item, stocked) end)
    each(others.ROUGH, function(item) hide_one(item, stocked) end)
end

local function do_enable()
    enabled = true
    sweep()
    repeatutil.scheduleEvery(GLOBAL_KEY, 997, 'ticks', sweep)
    dfhack.printerr("Malphar's Mod: mined stone is hidden on the ground.")
end

local function do_disable()
    enabled = false
    repeatutil.cancel(GLOBAL_KEY)
    if not dfhack.isMapLoaded() then return end
    local others = df.global.world.items.other
    if others and others.IN_PLAY then
        each(others.IN_PLAY, function(item)
            if MINED[item:getType()] and item.flags.hidden then
                item.flags.hidden = false
            end
        end)
    end
    dfhack.printerr("Malphar's Mod: mined stone is visible again.")
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED or sc == SC_WORLD_UNLOADED then
        enabled = false
        repeatutil.cancel(GLOBAL_KEY)
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

if dfhack.isMapLoaded() and dfhack.world.isFortressMode() then
    do_enable()
end
