-- Stop miasma. Rottable goods are kept frozen so they never rot, and any
-- miasma already in the fort is removed.
--@enable = true
--@module = true

local repeatutil = require('repeat-util')

local GLOBAL_KEY = 'malphars_no_miasma'
local CLEAR_KEY = GLOBAL_KEY .. '.clear'
local FROZEN = 10000
local ROTTING = {
    'PLANT', 'FOOD', 'MEAT', 'FISH', 'FISH_RAW', 'CHEESE', 'EGG',
    'GLOB', 'CORPSE', 'CORPSEPIECE', 'REMAINS', 'SEEDS', 'LIQUID_MISC',
}

enabled = enabled or false
local rots_stripped = false

function isEnabled()
    return enabled
end

local function strip_one(mat)
    if not mat or not mat.flags then return end
    pcall(function()
        if mat.flags.ROTS then mat.flags.ROTS = false end
    end)
end

local function strip_rots()
    if rots_stripped then return end
    local raws = df.global.world.raws
    pcall(function()
        for _, raw in ipairs(raws.inorganics.all) do
            strip_one(raw.material)
        end
    end)
    pcall(function()
        for _, plant in ipairs(raws.plants.all) do
            if plant.material then
                for _, mat in ipairs(plant.material) do strip_one(mat) end
            end
        end
    end)
    pcall(function()
        for _, cre in ipairs(raws.creatures.all) do
            if cre.material then
                for _, mat in ipairs(cre.material) do strip_one(mat) end
            end
        end
    end)
    rots_stripped = true
end

local function clear_miasma()
    local miasma = df.flow_type.Miasma
    if not miasma or not df.global.flows then return end
    for _, flow in ipairs(df.global.flows) do
        if flow and not flow.flags.DEAD and flow.type == miasma then
            flow.flags.DEAD = true
            local block = dfhack.maps.getTileBlock(flow.pos)
            if block and block.flow_pool then
                block.flow_pool.flags.active = true
            elseif df.global.world.orphaned_flow_pool then
                df.global.world.orphaned_flow_pool.flags.active = true
            end
        end
    end
end

local function freeze(item)
    if not item or item.flags.garbage_collect or item.flags.construction then return end
    pcall(function()
        local temp = item.temperature
        if not temp then return end
        -- Drinks at freezing point turn solid. Hold them just above that.
        local limit = FROZEN
        if item.getType and item:getType() == df.item_type.DRINK then
            limit = 10015
        end
        if temp.whole ~= limit and (item:getType() == df.item_type.DRINK or temp.whole > limit) then
            temp.whole = limit
            temp.fraction = 0
        end
    end)
    pcall(function()
        if item.flags.rotten then item.flags.rotten = false end
    end)
end

local function sweep()
    if not enabled or not dfhack.isMapLoaded() or not dfhack.world.isFortressMode() then
        return
    end
    pcall(strip_rots)
    pcall(clear_miasma)
    local others = df.global.world.items.other
    for _, name in ipairs(ROTTING) do
        local list = others[name]
        if list then
            for _, item in ipairs(list) do
                freeze(item)
            end
        end
    end
end

local function clear_only()
    if not enabled or not dfhack.isMapLoaded() or not dfhack.world.isFortressMode() then
        return
    end
    pcall(clear_miasma)
end

local function do_enable()
    enabled = true
    rots_stripped = false
    sweep()
    repeatutil.scheduleEvery(GLOBAL_KEY, 100, 'ticks', sweep)
    repeatutil.scheduleEvery(CLEAR_KEY, 1, 'ticks', clear_only)
    print("Malphar's Mod: miasma is off.")
end

local function do_disable()
    enabled = false
    repeatutil.cancel(GLOBAL_KEY)
    repeatutil.cancel(CLEAR_KEY)
    print("Malphar's Mod: miasma prevention is off.")
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        enabled = false
        rots_stripped = false
        repeatutil.cancel(GLOBAL_KEY)
        repeatutil.cancel(CLEAR_KEY)
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
