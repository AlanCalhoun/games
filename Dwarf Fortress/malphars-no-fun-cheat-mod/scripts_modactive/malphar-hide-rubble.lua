-- Hide loose mined stone and rough gems. Show them again once they are in a stockpile.
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
    for _, stockpile in ipairs(piles) do
        for _, item in ipairs(dfhack.buildings.getStockpileContents(stockpile)) do
            stocked[item.id] = true
            for _, inner in ipairs(dfhack.items.getContainedItems(item)) do
                stocked[inner.id] = true
                for _, inner2 in ipairs(dfhack.items.getContainedItems(inner)) do
                    stocked[inner2.id] = true
                end
            end
        end
    end
    return stocked
end

local function sweep()
    if not enabled or not dfhack.isMapLoaded() or not dfhack.world.isFortressMode() then
        return
    end
    local stocked = stocked_ids()
    local function hide_one(item)
        if not item
            or item.flags.construction
            or item.flags.in_building
            or item.flags.garbage_collect
            or item.flags.artifact
            or item.flags.owned
        then
            return
        end
        if stocked[item.id] then
            item.flags.hidden = false
        elseif item.flags.on_ground and not item.flags.in_job then
            local x, y, z = dfhack.items.getPosition(item)
            if x and dfhack.maps.isTileVisible(x, y, z) then
                item.flags.hidden = true
            end
        end
    end
    local boulders = df.global.world.items.other.BOULDER
    local rough = df.global.world.items.other.ROUGH
    if boulders then
        for _, item in ipairs(boulders) do hide_one(item) end
    end
    if rough then
        for _, item in ipairs(rough) do hide_one(item) end
    end
end

local function do_enable()
    enabled = true
    sweep()
    repeatutil.scheduleEvery(GLOBAL_KEY, 1000, 'ticks', sweep)
end

local function do_disable()
    enabled = false
    repeatutil.cancel(GLOBAL_KEY)
    if not dfhack.isMapLoaded() then return end
    for _, item in pairs(df.global.world.items.other.IN_PLAY) do
        if MINED[item:getType()] and item.flags.hidden then
            item.flags.hidden = false
        end
    end
    print("Malphar's Mod: mined stone is visible again.")
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        enabled = false
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
