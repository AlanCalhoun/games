-- Expand Malphar Cheat Workshop reactions: all plant seeds, and one of every
-- item definition. Static reaction products cannot list the whole raws set.
--@enable = true
--@module = true

local eventful = require('plugins.eventful')

local GLOBAL_KEY = 'malphars_workshop'
local SEED_STACK = 10
local RESOURCE_STACK = 100
local AMMO_STACK = 1000
local SPEAR_STACK = 1000
local SPAWN_BUDGET = 3000

enabled = enabled or false

function isEnabled()
    return enabled
end

local function first_created(created)
    if not created then return nil end
    if type(created) == 'number' then return df.item.find(created) end
    if type(created) == 'table' then
        local from_table = created[1] or created[0]
        if type(from_table) == 'number' then return df.item.find(from_table) end
        if from_table then return from_table end
    end
    local type_name = created._type and tostring(created._type) or ''
    if type_name:find('item') and not type_name:find('vector') then return created end
    return nil
end

local function creator_unit(fallback)
    if fallback then return fallback end
    for _, unit in pairs(dfhack.units.getCitizens()) do
        if unit then return unit end
    end
end

local function ground_pos(unit)
    local pos = unit and unit.pos
    if pos and pos.x and pos.x >= 0 then
        return {x = pos.x, y = pos.y, z = pos.z}
    end
end

local function put_on_ground(item, pos)
    if not item or not pos then return false end
    pcall(function() dfhack.items.moveToGround(item, pos) end)
    if item.flags then
        item.flags.on_ground = true
        item.flags.in_inventory = false
        item.flags.forbid = false
        item.flags.hidden = false
    end
    pcall(function()
        if item.quality and item.quality < 5 and not item.flags.artifact then
            item.quality = 5
        end
    end)
    return true
end

local function adamantine()
    return dfhack.matinfo.find('INORGANIC:ADAMANTINE')
        or dfhack.matinfo.find('INORGANIC:IRON')
end

local function spawn_one(unit, pos, item_type, subtype, mat_type, mat_index, stack, dimension)
    local created
    local ok = pcall(function()
        created = dfhack.items.createItem(
            unit, item_type, subtype or -1, mat_type, mat_index, false)
    end)
    if not ok or not created then return nil end
    local item = first_created(created)
    if not item or not put_on_ground(item, pos) then
        if item then pcall(dfhack.items.remove, item) end
        return nil
    end
    if stack and item.stack_size ~= nil then item.stack_size = stack end
    if dimension then
        pcall(function()
            if item.dimension ~= nil then item.dimension = dimension end
        end)
    end
    return item
end

local function spawn_all_seeds(unit)
    local pos = ground_pos(unit)
    local mat_fallback = adamantine()
    if not unit or not pos or not mat_fallback then return 0 end
    local made = 0
    for _, plant in ipairs(df.global.world.raws.plants.all) do
        if plant and plant.id then
            local mi = dfhack.matinfo.find('PLANT_MAT:' .. plant.id .. ':SEED')
            if not (mi and mi.material and mi.material.flags.SEED_MAT) then
                mi = nil
                if plant.material then
                    for _, mat in ipairs(plant.material) do
                        if mat and mat.flags and mat.flags.SEED_MAT and mat.id then
                            mi = dfhack.matinfo.find('PLANT_MAT:' .. plant.id .. ':' .. mat.id)
                            if mi then break end
                        end
                    end
                end
            end
            if mi and mi.material and mi.material.flags.SEED_MAT then
                if spawn_one(unit, pos, df.item_type.SEEDS, -1, mi.type, mi.index, SEED_STACK) then
                    made = made + 1
                end
            end
        end
    end
    return made
end

local HARD_TYPES = {
    'DOOR', 'BED', 'CHAIR', 'TABLE', 'CAGE', 'COFFIN', 'STATUE', 'SLAB',
    'CABINET', 'BOX', 'BAG', 'WEAPONRACK', 'ARMORSTAND', 'HATCH_COVER',
    'FLOODGATE', 'GRATE', 'BARS_VERTICAL', 'BARS_FLOOR', 'WINDOW',
    'CHAIN', 'BUCKET', 'ANVIL', 'QUERN', 'MILLSTONE', 'TRACTION_BENCH',
    'TRAPPARTS', 'PIPE_SECTION', 'BLOCKS', 'BOULDER', 'WOOD', 'BAR',
    'BIN', 'BARREL', 'COFFIN', 'SPLINT', 'CRUTCH', 'BACKPACK', 'QUIVER',
    'FLASK', 'GOBLET', 'TOY', 'INSTRUMENT', 'AMULET', 'RING', 'EARRING',
    'BRACELET', 'CROWN', 'SCEPTER', 'FIGURINE',
}

local DEF_VECTORS = {
    {df.item_type.WEAPON, 'weapons'},
    {df.item_type.ARMOR, 'armor'},
    {df.item_type.HELM, 'helms'},
    {df.item_type.GLOVES, 'gloves'},
    {df.item_type.SHOES, 'shoes'},
    {df.item_type.PANTS, 'pants'},
    {df.item_type.SHIELD, 'shields'},
    {df.item_type.AMMO, 'ammo'},
    {df.item_type.TRAPCOMP, 'trapcomps'},
    {df.item_type.TOOL, 'tools'},
    {df.item_type.TOY, 'toys'},
    {df.item_type.INSTRUMENT, 'instruments'},
    {df.item_type.SIEGEAMMO, 'siege_ammo'},
}

local function each_metal(fn)
    local raws = df.global.world.raws.inorganics
    if not raws then return 0 end
    local n = #raws
    local made = 0
    for i = 0, n - 1 do
        local raw = raws[i]
        if raw and raw.id and raw.material and raw.material.flags
            and raw.material.flags.IS_METAL
        then
            local mi = dfhack.matinfo.find('INORGANIC:' .. raw.id)
            if mi and fn(mi, raw.id) then
                made = made + 1
            end
        end
    end
    return made
end

local function spawn_metal_bars(unit, stack)
    stack = stack or RESOURCE_STACK
    local pos = ground_pos(unit)
    if not unit or not pos then return 0 end
    return each_metal(function(mi)
        return spawn_one(
            unit, pos, df.item_type.BAR, -1, mi.type, mi.index, stack, 150)
            ~= nil
    end)
end

local function spawn_metal_blocks(unit, stack)
    stack = stack or RESOURCE_STACK
    local pos = ground_pos(unit)
    if not unit or not pos then return 0 end
    return each_metal(function(mi)
        return spawn_one(
            unit, pos, df.item_type.BLOCKS, -1, mi.type, mi.index, stack)
            ~= nil
    end)
end

local function spawn_named_bars(unit, token, stack)
    stack = stack or RESOURCE_STACK
    local pos = ground_pos(unit)
    local mi = dfhack.matinfo.find(token)
    if not unit or not pos or not mi then return 0 end
    if spawn_one(unit, pos, df.item_type.BAR, -1, mi.type, mi.index, stack, 150) then
        return 1
    end
    return 0
end

local function spawn_named_blocks(unit, token, stack)
    stack = stack or RESOURCE_STACK
    local pos = ground_pos(unit)
    local mi = dfhack.matinfo.find(token)
    if not unit or not pos or not mi then return 0 end
    if spawn_one(unit, pos, df.item_type.BLOCKS, -1, mi.type, mi.index, stack) then
        return 1
    end
    return 0
end

local function find_itemdef_subtype(field, token)
    local defs = df.global.world.raws.itemdefs
    local vec = defs and defs[field]
    if not vec then return nil end
    for i = 0, #vec - 1 do
        local def = vec[i]
        if def and def.id == token then
            return i
        end
    end
end

local function spawn_adamantine_stack(unit, item_type, subtype_token, def_field, stack)
    stack = stack or AMMO_STACK
    local pos = ground_pos(unit)
    local mat = adamantine()
    if not unit or not pos or not mat then return 0 end
    local subtype = -1
    if subtype_token then
        subtype = find_itemdef_subtype(def_field, subtype_token)
        if subtype == nil then return 0 end
    end
    if spawn_one(unit, pos, item_type, subtype, mat.type, mat.index, stack) then
        return 1
    end
    return 0
end

local function spawn_every_item(unit)
    local pos = ground_pos(unit)
    local mat = adamantine()
    if not unit or not pos or not mat then return 0 end
    local made = 0
    local function budget_ok()
        return made < SPAWN_BUDGET
    end

    for _, name in ipairs(HARD_TYPES) do
        if not budget_ok() then break end
        local item_type = df.item_type[name]
        if item_type then
            local dimension = nil
            if name == 'BAR' or name == 'CLOTH' or name == 'THREAD' then
                dimension = 150
            end
            if spawn_one(unit, pos, item_type, -1, mat.type, mat.index, 1, dimension) then
                made = made + 1
            end
        end
    end

    local defs = df.global.world.raws.itemdefs
    for _, spec in ipairs(DEF_VECTORS) do
        if not budget_ok() then break end
        local item_type, field = spec[1], spec[2]
        local vec = defs and defs[field]
        if vec then
            for i = 0, #vec - 1 do
                if not budget_ok() then break end
                if vec[i] then
                    local stack = (item_type == df.item_type.AMMO) and 100 or 1
                    if spawn_one(unit, pos, item_type, i, mat.type, mat.index, stack) then
                        made = made + 1
                    end
                end
            end
        end
    end

    -- Cloth / thread / leather samples
    local extras = {
        {'CLOTH', 'CREATURE_MAT:SPIDER_CAVE_GIANT:SILK', 10000},
        {'THREAD', 'CREATURE_MAT:SPIDER_CAVE_GIANT:SILK', 15000},
        {'SKIN_TANNED', 'CREATURE_MAT:BIRD_ROC:LEATHER', nil},
        {'ROUGH', 'INORGANIC:DIAMOND_CLEAR', nil},
        {'SMALLGEM', 'INORGANIC:DIAMOND_CLEAR', nil},
    }
    for _, spec in ipairs(extras) do
        if not budget_ok() then break end
        local type_name, token, dim = spec[1], spec[2], spec[3]
        local item_type = df.item_type[type_name]
        local mi = dfhack.matinfo.find(token)
        if item_type and mi then
            if spawn_one(unit, pos, item_type, -1, mi.type, mi.index, 1, dim) then
                made = made + 1
            end
        end
    end
    return made
end

local function reaction_code(reaction)
    if not reaction then return nil end
    local code = reaction.code
    if type(code) == 'string' then return code end
    local ok, name = pcall(function() return reaction.getName and reaction:getName() end)
    if ok then return name end
end

local function on_reaction_complete(reaction, reaction_product, unit)
    if not enabled or not dfhack.isMapLoaded() then return end
    local code = reaction_code(reaction)
    if not code then return end
    unit = creator_unit(unit)
    if code == 'MALPHAR_FOOD_CROPS' or code == 'MALPHAR_FOOD_SEEDS' then
        local n = spawn_all_seeds(unit)
        dfhack.print(string.format("Malphar's Mod: spawned %d plant seed types.\n", n))
    elseif code == 'MALPHAR_SPAWN_ALL' then
        local n = spawn_every_item(unit)
        dfhack.print(string.format("Malphar's Mod: spawned %d item kinds (cap %d).\n", n, SPAWN_BUDGET))
    elseif code == 'MALPHAR_MAT_BUILD' then
        -- Existing materials job also dumps every metal bar + adamantine blocks.
        local bars = spawn_metal_bars(unit, RESOURCE_STACK)
        local blocks = spawn_named_blocks(unit, 'INORGANIC:ADAMANTINE', RESOURCE_STACK)
        dfhack.print(string.format(
            "Malphar's Mod: spawned %d metal bar stacks and %d adamantine block stacks (x%d).\n",
            bars, blocks, RESOURCE_STACK))
    elseif code == 'MALPHAR_MAT_METALS' then
        local n = spawn_metal_bars(unit, RESOURCE_STACK)
        dfhack.print(string.format(
            "Malphar's Mod: spawned %d metal bar stacks (x%d each).\n", n, RESOURCE_STACK))
    elseif code == 'MALPHAR_MAT_BLOCKS' then
        local n = spawn_metal_blocks(unit, RESOURCE_STACK)
        local adam = spawn_named_blocks(unit, 'INORGANIC:ADAMANTINE', RESOURCE_STACK)
        dfhack.print(string.format(
            "Malphar's Mod: spawned %d metal block stacks + %d adamantine (x%d).\n",
            n, adam, RESOURCE_STACK))
    elseif code == 'MALPHAR_MAT_ELECTRUM' then
        local n = spawn_named_bars(unit, 'INORGANIC:ELECTRUM', RESOURCE_STACK)
        dfhack.print(string.format("Malphar's Mod: spawned electrum bars x%d (%d).\n", RESOURCE_STACK, n))
    elseif code == 'MALPHAR_MAT_ADAM_BLOCKS' then
        local n = spawn_named_blocks(unit, 'INORGANIC:ADAMANTINE', RESOURCE_STACK)
        dfhack.print(string.format(
            "Malphar's Mod: spawned adamantine blocks x%d (%d).\n", RESOURCE_STACK, n))
    elseif code == 'MALPHAR_WEAP_ARROWS' then
        local n = spawn_adamantine_stack(
            unit, df.item_type.AMMO, 'ITEM_AMMO_ARROWS', 'ammo', AMMO_STACK)
        dfhack.print(string.format("Malphar's Mod: spawned arrows x%d (%d).\n", AMMO_STACK, n))
    elseif code == 'MALPHAR_WEAP_BOLTS' then
        local n = spawn_adamantine_stack(
            unit, df.item_type.AMMO, 'ITEM_AMMO_BOLTS', 'ammo', AMMO_STACK)
        dfhack.print(string.format("Malphar's Mod: spawned bolts x%d (%d).\n", AMMO_STACK, n))
    elseif code == 'MALPHAR_WEAP_BALLISTA' then
        local n = spawn_adamantine_stack(
            unit, df.item_type.SIEGEAMMO, 'ITEM_SIEGEAMMO_BALLISTA', 'siege_ammo', AMMO_STACK)
        dfhack.print(string.format(
            "Malphar's Mod: spawned ballista bolts x%d (%d).\n", AMMO_STACK, n))
    elseif code == 'MALPHAR_WEAP_SPEARS' then
        local n = spawn_adamantine_stack(
            unit, df.item_type.WEAPON, 'ITEM_WEAPON_SPEAR', 'weapons', SPEAR_STACK)
        dfhack.print(string.format("Malphar's Mod: spawned spears x%d (%d).\n", SPEAR_STACK, n))
    end
end

-- Old forts only keep reactions that existed at worldgen. Clone missing jobs
-- into the live raws and permit them so the cheat shop menu shows them.
local RUNTIME_REACTIONS = {
    {'MALPHAR_MAT_METALS', 'conjure 100 bars of every metal', 'MALPHAR_MAT_BUILD'},
    {'MALPHAR_MAT_BLOCKS', 'conjure 100 blocks of every metal', 'MALPHAR_MAT_BUILD'},
    {'MALPHAR_MAT_ELECTRUM', 'conjure 100 electrum bars', 'MALPHAR_MAT_BUILD'},
    {'MALPHAR_MAT_ADAM_BLOCKS', 'conjure 100 adamantine blocks', 'MALPHAR_MAT_BUILD'},
    {'MALPHAR_FOOD_SEEDS', 'conjure all plant seeds', 'MALPHAR_FOOD_CROPS'},
    {'MALPHAR_SPAWN_ALL', 'conjure one of every item', 'MALPHAR_FOOD_CROPS'},
    {'MALPHAR_WEAP_ARROWS', 'conjure 1000 arrows', 'MALPHAR_WEAP_RANGED'},
    {'MALPHAR_WEAP_BOLTS', 'conjure 1000 bolts', 'MALPHAR_WEAP_RANGED'},
    {'MALPHAR_WEAP_BALLISTA', 'conjure 1000 ballista bolts', 'MALPHAR_WEAP_RANGED'},
    {'MALPHAR_WEAP_SPEARS', 'conjure 1000 spears', 'MALPHAR_WEAP_MELEE'},
}

local function find_reaction(code)
    local rvec = df.global.world.raws.reactions.reactions
    if not rvec then return nil, nil end
    for i = 0, #rvec - 1 do
        local r = rvec[i]
        if r and r.code == code then
            return i, r
        end
    end
end

local function permit_reaction(idx)
    local entity = df.historical_entity.find(df.global.plotinfo.civ_id)
    if not entity or not entity.entity_raw or not entity.entity_raw.workshops then
        return
    end
    local pr = entity.entity_raw.workshops.permitted_reaction_id
    if not pr then return end
    for i = 0, #pr - 1 do
        if pr[i] == idx then return end
    end
    pcall(function() pr:insert('#', idx) end)
end

local function ensure_runtime_reactions()
    if not dfhack.isMapLoaded() then return 0 end
    local rvec = df.global.world.raws.reactions.reactions
    if not rvec then return 0 end
    local added = 0
    for _, spec in ipairs(RUNTIME_REACTIONS) do
        local code, name, base_code = spec[1], spec[2], spec[3]
        local idx, reaction = find_reaction(code)
        if not reaction then
            local _, base = find_reaction(base_code)
            if base then
                local nr = df.reaction:new()
                nr:assign(base)
                nr.code = code
                nr.name = name
                local ok = pcall(function() rvec:insert('#', nr) end)
                if ok then
                    idx = #rvec - 1
                    reaction = rvec[idx]
                    added = added + 1
                end
            end
        elseif reaction and name and reaction.name ~= name then
            reaction.name = name
        end
        if idx then
            permit_reaction(idx)
            pcall(function()
                eventful.addReactionToShop(code, 'MALPHAR_CHEAT_SHOP')
            end)
        end
    end
    return added
end

local function do_enable()
    enabled = true
    local added = ensure_runtime_reactions()
    eventful.onReactionComplete[GLOBAL_KEY] = on_reaction_complete
    if added > 0 then
        print(string.format(
            "Malphar's Mod: workshop resource conjuring is on (%d jobs added for this fort).",
            added))
    else
        print("Malphar's Mod: workshop resource conjuring is on (metals, blocks, seeds, all-items).")
    end
end

local function do_disable()
    enabled = false
    eventful.onReactionComplete[GLOBAL_KEY] = nil
    print("Malphar's Mod: workshop resource conjuring is off.")
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        enabled = false
        eventful.onReactionComplete[GLOBAL_KEY] = nil
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
