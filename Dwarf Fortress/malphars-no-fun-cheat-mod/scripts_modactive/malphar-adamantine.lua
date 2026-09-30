-- Place buildings without stocked materials. Use adamantine, or the
-- highest-value material the item is allowed to be.
--@enable = true
--@module = true

local repeatutil = require('repeat-util')
local utils = require('utils')

local GLOBAL_KEY = 'malphars_adamantine'
local MAX_PER_SWEEP = 40

enabled = enabled or false
materials = materials or nil

function isEnabled()
    return enabled
end

local SKIP_JOB = {
    StoreItemInStockpile = true,
    DumpItem = true,
    Eat = true,
    Drink = true,
    CustomReaction = true,
    MakeCharcoal = true,
    MakeAsh = true,
    CollectSand = true,
    CollectClay = true,
    MilkCreature = true,
    ShearCreature = true,
    ButcherAnimal = true,
    PrepareMeal = true,
    BrewDrink = true,
    ExtractFromPlants = true,
    MillPlants = true,
    ProcessPlants = true,
    MakeCheese = true,
    SpinThread = true,
    WeaveCloth = true,
    DyeCloth = true,
    PrepareRawFish = true,
    ExtractFromRawFish = true,
}

local RAW_ITEM = {
    WOOD = true,
    BOULDER = true,
    ROCK = true,
    BAR = true,
    BLOCKS = true,
    CLOTH = true,
    SKIN_TANNED = true,
    THREAD = true,
    ROUGH = true,
    MEAT = true,
    FISH = true,
    FISH_RAW = true,
    PLANT = true,
    SEEDS = true,
    DRINK = true,
    CHEESE = true,
    GLOB = true,
    POWDER_MISC = true,
    LIQUID_MISC = true,
}

local function push_mat(list, mi)
    if not mi or not mi.material then return end
    list[#list + 1] = {
        type = mi.type,
        index = mi.index,
        value = mi.material.material_value or 0,
        material = mi.material,
    }
end

local function collect_materials()
    local list = {}
    for _, token in ipairs({
        'INORGANIC:ADAMANTINE',
        'INORGANIC:RAW_ADAMANTINE',
        'INORGANIC:DIAMOND_CLEAR',
        'CREATURE_MAT:DRAGON:MUSCLE',
        'CREATURE_MAT:BIRD_ROC:LEATHER',
        'CREATURE_MAT:SPIDER_CAVE_GIANT:SILK',
        'CREATURE_MAT:COW:CHEESE',
        'PLANT_MAT:BUSH_QUARRY:SOAP',
        'PLANT_MAT:MUSHROOM_HELMET_PLUMP:STRUCTURAL',
        'PLANT_MAT:POD_SWEET:DRINK',
        'PLANT_MAT:OAK:WOOD',
        'COAL:COKE',
    }) do
        push_mat(list, dfhack.matinfo.find(token))
    end
    table.sort(list, function(a, b) return a.value > b.value end)
    return list
end

local function bag_ok(mat)
    local f = mat.flags
    return f.SILK or f.THREAD_PLANT or f.YARN
end

local function armor_ok(mat)
    local f = mat.flags
    return f.ITEMS_ARMOR or f.LEATHER
end

local function hard_ok(mat)
    return mat.flags.ITEMS_HARD
end

local function thread_ok(mat)
    local f = mat.flags
    return f.THREAD_PLANT or f.SILK or f.YARN or f.STOCKPILE_THREAD_METAL
end

local FILTERS = {
    WEAPON = function(mat) return mat.flags.ITEMS_WEAPON or mat.flags.ITEMS_WEAPON_RANGED end,
    AMMO = function(mat) return mat.flags.ITEMS_AMMO end,
    ARMOR = armor_ok,
    SHIELD = armor_ok,
    HELM = armor_ok,
    INSTRUMENT = hard_ok,
    AMULET = function(mat) return mat.flags.ITEMS_SOFT or mat.flags.ITEMS_HARD end,
    ROCK = function(mat) return mat.flags.IS_STONE end,
    BOULDER = function(mat) return mat.flags.IS_STONE end,
    BAR = function(mat)
        local id = mat.id
        return mat.flags.IS_METAL or mat.flags.SOAP or id == 'COAL' or id == 'POTASH'
            or id == 'ASH' or id == 'PEARLASH'
    end,
    BLOCKS = function(mat)
        local f = mat.flags
        return f.IS_STONE or f.IS_METAL or f.IS_GLASS or f.WOOD
    end,
    BAG = bag_ok,
    SEEDS = function(mat) return mat.flags.SEED_MAT end,
    PLANT = function(mat) return mat.flags.STRUCTURAL_PLANT_MAT end,
    LEAVES = function(mat) return mat.flags.STOCKPILE_PLANT_GROWTH end,
    MEAT = function(mat) return mat.flags.MEAT end,
    CHEESE = function(mat) return mat.flags.CHEESE_PLANT or mat.flags.CHEESE_CREATURE end,
    LIQUID_MISC = function(mat)
        local f = mat.flags
        return mat.id == 'WATER' or mat.id == 'LYE' or f.LIQUID_MISC_PLANT
            or f.LIQUID_MISC_CREATURE or f.LIQUID_MISC_OTHER
    end,
    POWDER_MISC = function(mat)
        return mat.flags.POWDER_MISC_PLANT or mat.flags.POWDER_MISC_CREATURE
    end,
    DRINK = function(mat) return mat.flags.ALCOHOL_PLANT or mat.flags.ALCOHOL_CREATURE end,
    GLOB = function(mat) return mat.flags.STOCKPILE_GLOB end,
    WOOD = function(mat) return mat.flags.WOOD end,
    THREAD = thread_ok,
    CLOTH = thread_ok,
    LEATHER = function(mat) return mat.flags.LEATHER end,
    SKIN_TANNED = function(mat) return mat.flags.LEATHER end,
    ROUGH = function(mat) return mat.flags.IS_GEM end,
    SMALLGEM = function(mat) return mat.flags.IS_GEM end,
}

FILTERS.GOBLET = hard_ok
FILTERS.FLASK = hard_ok
FILTERS.TOY = hard_ok
FILTERS.RING = hard_ok
FILTERS.CROWN = hard_ok
FILTERS.SCEPTER = hard_ok
FILTERS.FIGURINE = hard_ok
FILTERS.TOOL = hard_ok
FILTERS.TRAPPARTS = hard_ok
FILTERS.ANVIL = function(mat) return mat.flags.ITEMS_ANVIL or mat.flags.IS_METAL end
FILTERS.CHAIN = function(mat) return mat.flags.IS_METAL or mat.flags.ITEMS_HARD end
FILTERS.SHOES = function(mat) return armor_ok(mat) or bag_ok(mat) end
FILTERS.GLOVES = FILTERS.SHOES
FILTERS.PANTS = FILTERS.SHOES

local function furniture_ok(mat)
    local f = mat.flags
    return f.IS_METAL or f.IS_STONE or f.WOOD or f.IS_GLASS or f.ITEMS_HARD or f.BONE or f.SHELL
end

local function allows(item_type, mat)
    local name = df.item_type[item_type]
    local pred = name and FILTERS[name]
    if pred then return pred(mat) end
    return furniture_ok(mat)
end

local function best_material(item_type)
    if not materials then return nil end
    for _, cand in ipairs(materials) do
        if allows(item_type, cand.material) then
            return cand
        end
    end
end

local function reagent_type(mat)
    local f = mat.flags
    if f.IS_METAL or f.ITEMS_METAL then return df.item_type.BAR end
    if f.WOOD then return df.item_type.WOOD end
    if f.IS_STONE or f.IS_GEM then return df.item_type.BOULDER end
    if f.IS_GLASS then return df.item_type.BLOCKS end
    if f.LEATHER then return df.item_type.SKIN_TANNED end
    if f.SILK or f.THREAD_PLANT or f.YARN or f.STOCKPILE_THREAD_METAL then
        return df.item_type.CLOTH
    end
    return df.item_type.BAR
end

local function output_item_type(job)
    local name = df.job_type[job.job_type]
    if not name then return nil end
    local rest = name:gsub('^Construct', ''):gsub('^Make', '')
    if rest == name then return nil end
    if rest == 'THRONE' then rest = 'CHAIR' end
    if rest == 'BUILDING' or rest == 'CHARCOAL' or rest == 'ASH' then return nil end
    local upper = rest:upper()
    if df.item_type[upper] then return df.item_type[upper] end
    return nil
end

local function attached(job, idx)
    local n = 0
    for _, ref in ipairs(job.items) do
        if ref.job_item_idx == idx and ref.item then
            n = n + (ref.item.stack_size or 1)
        end
    end
    return n
end

local function first_created(created)
    if not created then return nil end
    if type(created) == 'number' then return df.item.find(created) end
    local type_name = created._type and tostring(created._type) or ''
    if type_name:find('item') and not type_name:find('vector') then return created end
    local ok, item = pcall(function() return created[0] end)
    if ok and item and type(item) ~= 'number' then
        if item._type then return item end
    end
    if ok and type(item) == 'number' then return df.item.find(item) end
    if type(created) == 'table' then
        local from_table = created[1] or created[0]
        if type(from_table) == 'number' then return df.item.find(from_table) end
        return from_table
    end
    return nil
end

local function creator_unit()
    for _, unit in pairs(dfhack.units.getCitizens()) do
        if unit then return unit end
    end
end

local function relax_filter(filter, item_type, item_subtype, mat)
    filter.item_type = item_type
    filter.item_subtype = item_subtype
    filter.mat_type = mat.type
    filter.mat_index = mat.index
    filter.metal_ore = -1
    filter.reaction_class = ''
    filter.has_material_reaction_product = ''
    local name = df.item_type[item_type]
    if name and df.job_item_vector_id[name] then
        filter.vector_id = df.job_item_vector_id[name]
    end
end

local function set_dimension(item, value)
    if not item or not value then return end
    local name = df.item_type[item:getType()]
    if name ~= 'BAR' and name ~= 'CLOTH' and name ~= 'THREAD'
        and name ~= 'DRINK' and name ~= 'POWDER_MISC' and name ~= 'LIQUID_MISC'
        and name ~= 'GLOB' and name ~= 'CHEESE' and name ~= 'MEAT' then
        return
    end
    pcall(function()
        if item.dimension < value then item.dimension = value end
    end)
end

local function set_masterwork(item)
    if not item or (item.flags and item.flags.artifact) then return end
    pcall(function()
        if item.quality < 5 then item.quality = 5 end
    end)
end

local TOOL_FOR_USE = {
    BOOKCASE = 'ITEM_TOOL_BOOKCASE',
    NEST_BOX = 'ITEM_TOOL_NEST_BOX',
    HIVE = 'ITEM_TOOL_HIVE',
    PLACE_OFFERING = 'ITEM_TOOL_ALTAR',
    DISPLAY_OBJECT = 'ITEM_TOOL_DISPLAY_CASE',
}

local function tool_subtype(use)
    if not use or use < 0 then return -1 end
    local name = df.tool_uses[use]
    local token = name and TOOL_FOR_USE[name]
    if not token then return -1 end
    local found = dfhack.items.findSubtype('TOOL:' .. token)
    if found and found >= 0 then return found end
    return -1
end

local function supply_job(job, budget)
    local uname = df.job_type[job.job_type]
    if not uname or SKIP_JOB[uname] then return budget end
    if not job.job_items or not job.job_items.elements then return budget end
    local elems = job.job_items.elements
    if #elems == 0 then return budget end
    local unit = creator_unit()
    if not unit then return budget end
    local produced = output_item_type(job)
    local placing = job.job_type == df.job_type.ConstructBuilding

    for i = 0, #elems - 1 do
        if budget <= 0 then break end
        local filter = elems[i]
        if filter then
            local need = filter.quantity
            if not need or need < 1 then need = 1 end
            local have = attached(job, i)
            local missing = need - have
            if missing > 0 then
                local filter_type = filter.item_type
                local filter_name = filter_type >= 0 and df.item_type[filter_type] or nil
                local finished = filter_name and not RAW_ITEM[filter_name]
                local product_type = finished and filter_type or produced
                if placing and finished then
                    product_type = filter_type
                end
                local mat_for = product_type or filter_type
                if not mat_for or mat_for < 0 then
                    mat_for = df.item_type.BLOCKS
                end
                local chosen = best_material(mat_for)
                if chosen then
                    local spawn_type, spawn_sub
                    local construction_input = (not filter_name) or filter_name == 'WOOD'
                        or filter_name == 'BLOCKS' or filter_name == 'BAR'
                    if placing and construction_input then
                        spawn_type = df.item_type.BLOCKS
                        spawn_sub = -1
                        chosen = best_material(df.item_type.BLOCKS) or chosen
                    elseif finished or (placing and filter_name and not RAW_ITEM[filter_name]) then
                        spawn_type = filter_type
                        spawn_sub = filter.item_subtype >= 0 and filter.item_subtype or -1
                    elseif produced and not RAW_ITEM[df.item_type[produced] or ''] then
                        spawn_type = reagent_type(chosen.material)
                        spawn_sub = -1
                    elseif filter_type >= 0 then
                        spawn_type = filter_type
                        spawn_sub = filter.item_subtype >= 0 and filter.item_subtype or -1
                        chosen = best_material(spawn_type) or chosen
                    else
                        spawn_type = df.item_type.BLOCKS
                        spawn_sub = -1
                        chosen = best_material(df.item_type.BLOCKS) or chosen
                    end
                    if filter.has_tool_use and filter.has_tool_use >= 0 then
                        local sub = tool_subtype(filter.has_tool_use)
                        if sub >= 0 then
                            spawn_type = df.item_type.TOOL
                            spawn_sub = sub
                            chosen = best_material(spawn_type) or chosen
                        end
                    end
                    relax_filter(filter, spawn_type, spawn_sub, chosen)
                    job.mat_type = chosen.type
                    job.mat_index = chosen.index
                    local filled = false
                    while missing > 0 and budget > 0 do
                        local created = dfhack.items.createItem(
                            unit, spawn_type, spawn_sub, chosen.type, chosen.index, false)
                        local item = first_created(created)
                        if not item then break end
                        set_dimension(item, 150)
                        local before = attached(job, i)
                        if not dfhack.job.attachJobItem(job, item, df.job_role_type.Hauled, i, -1)
                            or attached(job, i) <= before then
                            dfhack.items.remove(item)
                            break
                        end
                        missing = missing - 1
                        budget = budget - 1
                        filled = true
                    end
                    if filled then
                        job.flags.suspend = false
                    end
                end
            end
        end
    end
    return budget
end

local LEAVE_ITEM = {
    PLANT = true,
    SEEDS = true,
    MEAT = true,
    CHEESE = true,
    DRINK = true,
    FISH = true,
    FISH_RAW = true,
    GLOB = true,
    EGG = true,
    LEAVES = true,
    LIQUID_MISC = true,
    POWDER_MISC = true,
    REMAINS = true,
    CORPSE = true,
    CORPSEPIECE = true,
    VERMIN = true,
    PET = true,
    FOOD = true,
}

local function upgrade_item(item)
    if not item or not materials then return end
    if item.flags and (item.flags.garbage_collect or item.flags.artifact or item.flags.construction) then
        return
    end
    local name = df.item_type[item:getType()]
    if not name or LEAVE_ITEM[name] then return end
    local cur_ok, cur = pcall(dfhack.matinfo.decode, item.mat_type, item.mat_index)
    if cur_ok and cur and cur.material then
        local id = cur.material.id
        if id == 'COAL' or id == 'CHARCOAL' then return end
    end
    local chosen = best_material(item:getType())
    if not chosen then return end
    if cur_ok and cur and cur.material and (cur.material.material_value or 0) >= chosen.value then
        return
    end
    item.mat_type = chosen.type
    item.mat_index = chosen.index
end

local function upgrade_cheat_shops()
    for _, bld in ipairs(df.global.world.buildings.all) do
        if df.building_workshopst:is_instance(bld) and bld.custom_type >= 0 and bld.contained_items then
            local def_ok, def = pcall(df.building_def.find, bld.custom_type)
            if def_ok and def and def.code == 'MALPHAR_CHEAT_SHOP' then
                for _, contained in ipairs(bld.contained_items) do
                    if contained.item then
                        set_masterwork(contained.item)
                        pcall(upgrade_item, contained.item)
                    end
                end
            end
        end
    end
end

local STOCK_BUDGET = 8

-- type, subtype token or nil, count, material picker, stack size, dimension
local STOCK = {
    {'DOOR', nil, 8, 'best'},
    {'BED', nil, 4, 'best'},
    {'CHAIR', nil, 4, 'best'},
    {'TABLE', nil, 4, 'best'},
    {'BLOCKS', nil, 40, 'best'},
    {'TRAPPARTS', nil, 20, 'best'},
    {'PLANT', nil, 20, 'plant', 20},
    {'BAR', nil, 10, 'soap', nil, 150},
    {'CLOTH', nil, 20, 'thread', nil, 10000},
    {'THREAD', nil, 20, 'thread', nil, 15000},
    {'SPLINT', nil, 10, 'best'},
    {'CRUTCH', nil, 10, 'best'},
    {'CHAIN', nil, 10, 'best'},
    {'ANVIL', nil, 1, 'best'},
    {'CABINET', nil, 2, 'best'},
    {'BOX', nil, 2, 'best'},
    {'HATCH_COVER', nil, 2, 'best'},
    {'FLOODGATE', nil, 2, 'best'},
    {'GRATE', nil, 2, 'best'},
    {'CAGE', nil, 2, 'best'},
    {'COFFIN', nil, 2, 'best'},
    {'STATUE', nil, 2, 'best'},
    {'WEAPONRACK', nil, 2, 'best'},
    {'ARMORSTAND', nil, 2, 'best'},
    {'BIN', nil, 2, 'best'},
    {'BARREL', nil, 2, 'best'},
    {'BUCKET', nil, 2, 'best'},
    {'AMMO', 'ITEM_AMMO_BOLTS', 100, 'best', 100},
    {'AMMO', 'ITEM_AMMO_ARROWS', 100, 'best', 100},
    {'SHIELD', 'ITEM_SHIELD_SHIELD', 10, 'best'},
    {'SHIELD', 'ITEM_SHIELD_BUCKLER', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_PICK', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_AXE_BATTLE', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_HAMMER_WAR', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_SWORD_SHORT', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_SWORD_LONG', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_SWORD_2H', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_SPEAR', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_MACE', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_CROSSBOW', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_BOW', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_PIKE', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_HALBERD', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_MAUL', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_AXE_GREAT', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_DAGGER_LARGE', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_SCIMITAR', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_FLAIL', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_MORNINGSTAR', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_WHIP', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_SCOURGE', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_BLOWGUN', 10, 'best'},
    {'WEAPON', 'ITEM_WEAPON_PICK_GREAT', 10, 'best'},
}

local function best_where(pred)
    if not materials then return nil end
    for _, cand in ipairs(materials) do
        if pred(cand.material) then return cand end
    end
end

local function pick_mat(kind, item_type)
    if kind == 'thread' then
        return best_where(thread_ok)
    elseif kind == 'soap' then
        return best_where(function(mat) return mat.flags.SOAP end)
    elseif kind == 'leather' then
        return best_where(function(mat) return mat.flags.LEATHER end)
    elseif kind == 'meat' then
        return best_where(function(mat) return mat.flags.MEAT end)
    elseif kind == 'cheese' then
        return best_where(function(mat) return mat.flags.CHEESE_PLANT or mat.flags.CHEESE_CREATURE end)
    elseif kind == 'drink' then
        return best_where(function(mat) return mat.flags.ALCOHOL_PLANT or mat.flags.ALCOHOL_CREATURE end)
    elseif kind == 'plant' then
        return best_where(function(mat)
            local flags = mat.flags
            return (flags.EDIBLE_RAW or flags.EDIBLE_COOKED)
                and (flags.STRUCTURAL_PLANT_MAT or flags.STOCKPILE_PLANT_GROWTH)
        end)
    end
    return best_material(item_type)
end

local function item_is_free(item)
    return item
        and not item.flags.garbage_collect
        and not item.flags.in_building
        and not item.flags.construction
        and not item.flags.in_job
        and not item.flags.forbid
        and not item.flags.hidden
end

local function is_soap(item)
    local ok, cur = pcall(dfhack.matinfo.decode, item.mat_type, item.mat_index)
    return ok and cur and cur.material and cur.material.flags.SOAP
end

local function tile_ok(x, y, z)
    if not x or x < 0 or not y or y < 0 or not z or z < 0 then return false end
    local fn = dfhack.maps.isValidTilePos
    if not fn then return true end
    local ok, yes = pcall(fn, x, y, z)
    return ok and yes
end

local function ground_pos(unit)
    local pos = unit and unit.pos
    if pos and tile_ok(pos.x, pos.y, pos.z) then
        return {x = pos.x, y = pos.y, z = pos.z}
    end
    local ok, mouse = pcall(dfhack.gui.getMousePos)
    if ok and mouse and tile_ok(mouse.x, mouse.y, mouse.z) then
        return {x = mouse.x, y = mouse.y, z = mouse.z}
    end
end

local function put_on_ground(item, pos)
    if not item or not pos then return false end
    local ok = pcall(function() dfhack.items.moveToGround(item, pos) end)
    if not ok then return false end
    item.flags.forbid = false
    item.flags.hidden = false
    set_masterwork(item)
    return true
end

local subtype_cache = {}

local function cached_subtype(type_name, token)
    if not token then return -1 end
    local key = type_name .. ':' .. token
    local cached = subtype_cache[key]
    if cached == nil then
        local found = dfhack.items.findSubtype(key)
        cached = (found and found >= 0) and found or false
        subtype_cache[key] = cached
    end
    if cached == false then return nil end
    return cached
end

local function on_spawn_tile(item, pos)
    local ok, ipos = pcall(function() return item.pos end)
    if not ok or not ipos or not pos then return false end
    return ipos.x == pos.x and ipos.y == pos.y and ipos.z == pos.z
end

local function tally_free(pos)
    local by_type = {}
    local by_sub = {}
    local soap = 0
    local piles = {}
    local list = df.global.world.items.other.IN_PLAY
    if not list then return by_type, by_sub, soap, piles end
    for _, item in ipairs(list) do
        if item_is_free(item) then
            local item_type = item:getType()
            local subtype = item:getSubtype()
            local n = item.stack_size or 1
            by_type[item_type] = (by_type[item_type] or 0) + n
            if subtype and subtype >= 0 then
                by_sub[item_type .. ':' .. subtype] = (by_sub[item_type .. ':' .. subtype] or 0) + n
            end
            if item_type == df.item_type.BAR and is_soap(item) then
                soap = soap + n
            end
            if on_spawn_tile(item, pos) and not item.flags.owned then
                local key = item_type .. ':' .. (subtype or -1)
                local pile = piles[key]
                if not pile then
                    pile = {}
                    piles[key] = pile
                end
                pile[#pile + 1] = item
            end
        end
    end
    return by_type, by_sub, soap, piles
end

local function ensure_stock()
    local unit = creator_unit()
    if not unit or not materials then return end
    local pos = ground_pos(unit)
    if not pos then return end
    local by_type, by_sub, soap, piles = tally_free(pos)
    local removed = 0
    for _, spec in ipairs(STOCK) do
        if removed >= 20 then break end
        local type_name, token, want = spec[1], spec[2], spec[3]
        local item_type = df.item_type[type_name]
        local subtype = item_type and cached_subtype(type_name, token)
        if item_type and subtype then
            local key = item_type .. ':' .. subtype
            local pile = piles[key]
            if pile and #pile > want then
                for i = want + 1, #pile do
                    if removed >= 20 then break end
                    local item = pile[i]
                    if item and item.stack_size and item.stack_size > 1 and spec[5] then
                        item.stack_size = want
                        removed = removed + 1
                        break
                    end
                    if item then
                        pcall(dfhack.items.remove, item)
                        removed = removed + 1
                    end
                end
            end
        end
    end
    local made = 0
    for _, spec in ipairs(STOCK) do
        if made >= STOCK_BUDGET then break end
        local type_name, token, want, kind, stack, dimension = spec[1], spec[2], spec[3], spec[4], spec[5], spec[6]
        local item_type = df.item_type[type_name]
        local subtype = item_type and cached_subtype(type_name, token)
        if item_type and subtype then
            local have
            if kind == 'soap' then
                have = soap
            elseif subtype >= 0 then
                have = by_sub[item_type .. ':' .. subtype] or 0
            else
                have = by_type[item_type] or 0
            end
            local chosen = pick_mat(kind, item_type)
                if chosen and have < want then
                    local missing = want - have
                    if stack and stack > 1 then
                        local item_ok, item = pcall(function()
                        local created = dfhack.items.createItem(
                            unit, item_type, subtype, chosen.type, chosen.index, false)
                        return first_created(created)
                    end)
                    if item_ok and item and put_on_ground(item, pos) then
                            if item.stack_size ~= nil then item.stack_size = missing end
                            set_dimension(item, dimension or 150)
                            made = made + 1
                        end
                    else
                        while missing > 0 and made < STOCK_BUDGET do
                            local item_ok, item = pcall(function()
                            local created = dfhack.items.createItem(
                                unit, item_type, subtype, chosen.type, chosen.index, false)
                            return first_created(created)
                        end)
                        if not item_ok or not item or not put_on_ground(item, pos) then break end
                            set_dimension(item, dimension or 150)
                            missing = missing - 1
                            made = made + 1
                    end
                end
            end
        end
    end
end

local function spawn_doors()
    local unit = creator_unit()
    local pos = ground_pos(unit)
    local mi = dfhack.matinfo.find('INORGANIC:ADAMANTINE')
    if not unit or not pos or not mi then return 0 end
    local have = 0
    local list = df.global.world.items.other.DOOR
    if list then
        for _, item in ipairs(list) do
            if item_is_free(item) then have = have + 1 end
        end
    end
    local made = 0
    while have < 8 and made < 8 do
        local ok, item = pcall(function()
            local created = dfhack.items.createItem(
                unit, df.item_type.DOOR, -1, mi.type, mi.index, false)
            return first_created(created)
        end)
        if not ok or not item or not put_on_ground(item, pos) then break end
        have = have + 1
        made = made + 1
    end
    return made
end

local PLACE_KEY = GLOBAL_KEY .. '.place'
local RELEASE_KEY = GLOBAL_KEY .. '.release'
local place_pools = {}

local function placing_now()
    local ok, mode = pcall(function()
        return df.global.game.main_interface.bottom_mode_selected
    end)
    return ok and mode == df.main_bottom_mode_type.BUILDING_PLACEMENT
end

local function cursor_pos()
    local ui = df.global.buildreq
    local pos = ui and ui.pos
    if pos and tile_ok(pos.x, pos.y, pos.z) then
        return {x = pos.x, y = pos.y, z = pos.z}
    end
    local ok, mouse = pcall(dfhack.gui.getMousePos)
    if ok and mouse and tile_ok(mouse.x, mouse.y, mouse.z) then
        return {x = mouse.x, y = mouse.y, z = mouse.z}
    end
end

local function filter_item_type(filter)
    local item_type = filter.item_type
    if item_type and item_type >= 0 then return item_type end
    local vector_name = filter.vector_id and df.job_item_vector_id[filter.vector_id]
    if vector_name and df.item_type[vector_name] then
        return df.item_type[vector_name]
    end
end

local function wanted_on_cursor(ui, filter)
    local n = 1
    if filter.quantity and filter.quantity > 1 then n = filter.quantity end
    local sp, p = ui.selection_pos, ui.pos
    if filter.quantity and filter.quantity < 0 and sp and sp.x >= 0 and p and p.x >= 0 then
        n = (math.abs(p.x - sp.x) + 1) * (math.abs(p.y - sp.y) + 1) * (math.abs(p.z - sp.z) + 1)
    end
    if n > 20 then n = 20 end
    if n < 1 then n = 1 end
    return n
end

local function spawn_at(unit, item_type, subtype, mat, pos)
    local created
    local ok = pcall(function()
        created = dfhack.items.createItem(
            unit, item_type, subtype, mat.type, mat.index, false)
    end)
    if not ok or not created then
        pcall(function()
            created = dfhack.items.createItem(item_type, subtype, mat.type, mat.index, unit)
        end)
    end
    local item = first_created(created)
    if not item or not put_on_ground(item, pos) then return nil end
    return item
end

local function place_at_cursor()
    if not enabled or not dfhack.isMapLoaded() or not placing_now() then return end
    if not materials then return end
    local ui = df.global.buildreq
    local pos = cursor_pos()
    local unit = creator_unit()
    if not ui or not pos or not unit then return end
    local ok, filters = pcall(dfhack.buildings.getFiltersByType, {},
        ui.building_type, ui.building_subtype, ui.custom_type)
    if not ok or not filters then return end
    for _, filter in ipairs(filters) do
        local item_type = filter_item_type(filter)
        local chosen = item_type and best_material(item_type)
        if item_type and chosen then
            local subtype = filter.item_subtype
            if not subtype or subtype < 0 then subtype = -1 end
            if filter.has_tool_use and filter.has_tool_use >= 0 then
                local sub = tool_subtype(filter.has_tool_use)
                if sub >= 0 then subtype = sub end
            end
            local pool_key = item_type .. ':' .. subtype
            local pool = place_pools[pool_key] or {}
            local kept = {}
            for _, item in ipairs(pool) do
                local same = item and item_is_free(item) and item:getType() == item_type
                if same and subtype >= 0 then
                    local ok_sub, sub = pcall(function() return item:getSubtype() end)
                    same = ok_sub and sub == subtype
                end
                if same then
                    put_on_ground(item, pos)
                    kept[#kept + 1] = item
                end
            end
            local want = wanted_on_cursor(ui, filter)
            local made = 0
            while #kept < want and made < 4 do
                local item = spawn_at(unit, item_type, subtype, chosen, pos)
                if not item then break end
                kept[#kept + 1] = item
                made = made + 1
            end
            place_pools[pool_key] = kept
        end
    end
end

local larder
local meal_mode
local meal_warned = false
local supply_ids = {fish = {}, drink = {}}

local function counts_for_supply(item)
    return item
        and not item.flags.garbage_collect
        and not item.flags.rotten
        and not item.flags.forbid
        and not item.flags.hidden
        and not item.flags.owned
        and not item.flags.dump
end

local function note_best(bucket, value, token)
    if value > bucket.value then
        bucket.value = value
        bucket.token = token
    end
end

local function resolve_token(bucket, fallback)
    local mi = bucket.token and dfhack.matinfo.find(bucket.token) or nil
    if not mi then mi = dfhack.matinfo.find(fallback) end
    if not mi or not mi.material then return nil end
    return {
        type = mi.type,
        index = mi.index,
        value = mi.material.material_value or 0,
        material = mi.material,
    }
end

local function find_race(token)
    local all = df.global.world.raws.creatures.all
    for race = 0, #all - 1 do
        local cre = all[race]
        if cre and cre.creature_id == token then return race end
    end
end

local function resolve_larder()
    if larder then return larder end
    local best = {
        meat = {value = -1},
        cheese = {value = -1},
        drink = {value = -1},
    }
    local fish_race, fish_value = nil, -1
    pcall(function()
        for _, plant in ipairs(df.global.world.raws.plants.all) do
            if plant.material then
                for _, mat in ipairs(plant.material) do
                    local value = mat.material_value or 0
                    local token = 'PLANT_MAT:' .. plant.id .. ':' .. mat.id
                    local flags = mat.flags
                    if flags.ALCOHOL_PLANT or flags.ALCOHOL_CREATURE then
                        note_best(best.drink, value, token)
                    end
                    if flags.CHEESE_PLANT or flags.CHEESE_CREATURE then
                        note_best(best.cheese, value, token)
                    end
                end
            end
        end
    end)
    pcall(function()
        local all = df.global.world.raws.creatures.all
        for race = 0, #all - 1 do
            local cre = all[race]
            if cre and cre.material then
                local fish = false
                pcall(function() fish = cre.flags.FISHITEM and true or false end)
                local this_fish = -1
                for _, mat in ipairs(cre.material) do
                    local value = mat.material_value or 0
                    local token = 'CREATURE_MAT:' .. cre.creature_id .. ':' .. mat.id
                    local flags = mat.flags
                    if flags.MEAT then
                        note_best(best.meat, value, token)
                        if fish then this_fish = math.max(this_fish, value) end
                    end
                    if flags.CHEESE_CREATURE or flags.CHEESE_PLANT then
                        note_best(best.cheese, value, token)
                    end
                    if flags.ALCOHOL_CREATURE or flags.ALCOHOL_PLANT then
                        note_best(best.drink, value, token)
                    end
                    if fish and (flags.EDIBLE_RAW or flags.EDIBLE_COOKED) then
                        this_fish = math.max(this_fish, value)
                    end
                end
                if fish and this_fish > fish_value then
                    fish_value = this_fish
                    fish_race = race
                end
            end
        end
    end)
    if not fish_race then fish_race = find_race('LOBSTER_CAVE') end
    larder = {
        meat = resolve_token(best.meat, 'CREATURE_MAT:DRAGON:MUSCLE'),
        cheese = resolve_token(best.cheese, 'CREATURE_MAT:COW:CHEESE'),
        drink = resolve_token(best.drink, 'PLANT_MAT:MUSHROOM_HELMET_PLUMP:DRINK'),
        fish_race = fish_race,
        fish_caste = 0,
    }
    return larder
end

local function same_mat(item, mat)
    return item.mat_type == mat.type and item.mat_index == mat.index
end

local function fill_one_stack(list, match, want, spawn)
    local have = 0
    local target
    if list then
        for _, item in ipairs(list) do
            if match(item) then
                have = have + (item.stack_size or 1)
                if not target and item.stack_size ~= nil then target = item end
            end
        end
    end
    if have >= want then
        if target then set_masterwork(target) end
        return
    end
    if target then
        target.stack_size = (target.stack_size or 1) + (want - have)
        set_masterwork(target)
        return
    end
    spawn(want - have)
end

local function spawn_stack(unit, pos, item_type, subtype, mat, amount, dimension)
    local item_ok, item = pcall(function()
        local created = dfhack.items.createItem(
            unit, item_type, subtype, mat.type, mat.index, false)
        return first_created(created)
    end)
    if not item_ok or not item or not put_on_ground(item, pos) then return nil end
    if item.stack_size ~= nil then item.stack_size = amount end
    if dimension then set_dimension(item, dimension) end
    return item
end

local function add_meal_ingredients(item, mat, unit)
    local ing = item.ingredients
    if not ing or not ing.item_type or not ing.item_type.insert then return false end
    if not ing.mat_type or not ing.mat_index then return false end
    for _ = 1, 4 do
        ing.item_type:insert('#', df.item_type.MEAT)
        if ing.item_subtype and ing.item_subtype.insert then
            ing.item_subtype:insert('#', -1)
        end
        ing.mat_type:insert('#', mat.type)
        ing.mat_index:insert('#', mat.index)
        if ing.maker and ing.maker.insert then
            ing.maker:insert('#', unit and unit.id or -1)
        end
        if ing.quality and ing.quality.insert then
            ing.quality:insert('#', 5)
        end
    end
    return #ing.item_type >= 4
end

local function is_lavish_meal(item)
    local ok, yes = pcall(function()
        return #item.ingredients.item_type >= 4 and (item.quality or 0) >= 5
    end)
    return ok and yes
end

local function spawn_drink_barrel(unit, pos, mat, amount)
    local metal = dfhack.matinfo.find('INORGANIC:ADAMANTINE')
    if not metal then return false end
    local barrel_ok, barrel = pcall(function()
        local created = dfhack.items.createItem(
            unit, df.item_type.BARREL, -1, metal.type, metal.index, false)
        return first_created(created)
    end)
    if not barrel_ok or not barrel or not put_on_ground(barrel, pos) then return false end
    local drink = spawn_stack(unit, pos, df.item_type.DRINK, -1, mat, amount, 150)
    if not drink then return false end
    if drink.id then supply_ids.drink[drink.id] = true end
    pcall(function() dfhack.items.moveToContainer(drink, barrel) end)
    return true
end

local FODDER = {
    {'PLANT', 'PLANT_MAT:MUSHROOM_HELMET_PLUMP:STRUCTURAL', 30},
    {'PLANT', 'PLANT_MAT:GRASS_WHEAT_CAVE:STRUCTURAL', 30},
    {'PLANT', 'PLANT_MAT:GRASS_TAIL_PIG:STRUCTURAL', 30},
    {'PLANT', 'PLANT_MAT:POD_SWEET:STRUCTURAL', 30},
    {'SEEDS', 'PLANT_MAT:MUSHROOM_HELMET_PLUMP:SEED', 30},
    {'SEEDS', 'PLANT_MAT:GRASS_WHEAT_CAVE:SEED', 30},
    {'SEEDS', 'PLANT_MAT:GRASS_TAIL_PIG:SEED', 30},
    {'SEEDS', 'PLANT_MAT:POD_SWEET:SEED', 30},
}

local function ensure_fodder(unit, pos, others)
    for _, spec in ipairs(FODDER) do
        local type_name, token, want = spec[1], spec[2], spec[3]
        local item_type = df.item_type[type_name]
        local mi = dfhack.matinfo.find(token)
        local list = others[type_name]
        if item_type and mi and list then
            fill_one_stack(list, function(item)
                return counts_for_supply(item) and same_mat(item, mi)
            end, want, function(amount)
                spawn_stack(unit, pos, item_type, -1, mi, amount, nil)
            end)
        end
    end
end

local WARDROBE_BUDGET = 40
local WARDROBE = {
    {'ARMOR', 'ITEM_ARMOR_SHIRT', 10},
    {'ARMOR', 'ITEM_ARMOR_CLOAK', 10},
    {'ARMOR', 'ITEM_ARMOR_TUNIC', 10},
    {'ARMOR', 'ITEM_ARMOR_COAT', 10},
    {'ARMOR', 'ITEM_ARMOR_VEST', 10},
    {'ARMOR', 'ITEM_ARMOR_ROBE', 10},
    {'ARMOR', 'ITEM_ARMOR_DRESS', 10},
    {'ARMOR', 'ITEM_ARMOR_CAPE', 10},
    {'ARMOR', 'ITEM_ARMOR_TOGA', 10},
    {'ARMOR', 'ITEM_ARMOR_BREASTPLATE', 10},
    {'ARMOR', 'ITEM_ARMOR_MAIL_SHIRT', 10},
    {'PANTS', 'ITEM_PANTS_PANTS', 10},
    {'PANTS', 'ITEM_PANTS_LEGGINGS', 10},
    {'PANTS', 'ITEM_PANTS_SKIRT', 10},
    {'PANTS', 'ITEM_PANTS_BRAIES', 10},
    {'PANTS', 'ITEM_PANTS_GREAVES', 10},
    {'HELM', 'ITEM_HELM_CAP', 10},
    {'HELM', 'ITEM_HELM_HOOD', 10},
    {'HELM', 'ITEM_HELM_HELM', 10},
    {'GLOVES', 'ITEM_GLOVES_GLOVES', 10},
    {'GLOVES', 'ITEM_GLOVES_MITTENS', 10},
    {'GLOVES', 'ITEM_GLOVES_GAUNTLETS', 10},
    {'SHOES', 'ITEM_SHOES_SHOES', 10},
    {'SHOES', 'ITEM_SHOES_SOCKS', 10},
    {'SHOES', 'ITEM_SHOES_SANDAL', 10},
    {'SHOES', 'ITEM_SHOES_BOOTS', 10},
    {'BACKPACK', nil, 10},
    {'QUIVER', nil, 10},
    {'FLASK', nil, 10},
    {'TOOL', 'ITEM_TOOL_POUCH', 10},
    {'AMULET', nil, 10},
    {'RING', nil, 10},
    {'EARRING', nil, 10},
    {'BRACELET', nil, 10},
    {'CROWN', nil, 10},
}

local function ensure_wardrobe()
    local unit = creator_unit()
    if not unit or not materials then return end
    local pos = ground_pos(unit)
    if not pos then return end
    local made = 0
    local others = df.global.world.items.other
    for _, spec in ipairs(WARDROBE) do
        if made >= WARDROBE_BUDGET then break end
        local type_name, token, want = spec[1], spec[2], spec[3]
        local item_type = df.item_type[type_name]
        local subtype = item_type and cached_subtype(type_name, token)
        local mat = item_type and best_material(item_type)
        local list = item_type and others[type_name]
        if item_type and subtype and mat and list then
            local have = 0
            for _, item in ipairs(list) do
                local sub_ok = subtype < 0 or item:getSubtype() == subtype
                if counts_for_supply(item) and same_mat(item, mat) and sub_ok then
                    have = have + 1
                    set_masterwork(item)
                end
            end
            while have < want and made < WARDROBE_BUDGET do
                local item = spawn_stack(unit, pos, item_type, subtype, mat, 1, nil)
                if not item then break end
                have = have + 1
                made = made + 1
            end
        end
    end
end

local function ensure_larder()
    local unit = creator_unit()
    if not unit then return end
    local pos = ground_pos(unit)
    if not pos then return end
    local stock = resolve_larder()
    local others = df.global.world.items.other
    ensure_fodder(unit, pos, others)
    if stock.meat then
        fill_one_stack(others.MEAT, function(item)
            return counts_for_supply(item) and same_mat(item, stock.meat)
        end, 20, function(amount)
            spawn_stack(unit, pos, df.item_type.MEAT, -1, stock.meat, amount, 150)
        end)
    end
    if stock.cheese then
        fill_one_stack(others.CHEESE, function(item)
            return counts_for_supply(item) and same_mat(item, stock.cheese)
        end, 10, function(amount)
            spawn_stack(unit, pos, df.item_type.CHEESE, -1, stock.cheese, amount, 150)
        end)
    end
    if stock.fish_race then
        fill_one_stack(others.FISH, function(item)
            if not counts_for_supply(item) then return false end
            if supply_ids.fish[item.id] then return true end
            local race_ok = false
            pcall(function() race_ok = item.race == stock.fish_race end)
            if race_ok then return true end
            local mat_ok = false
            pcall(function()
                mat_ok = item.mat_type == stock.fish_race and item.mat_index == stock.fish_caste
            end)
            return mat_ok
        end, 20, function(amount)
            local item_ok, item = pcall(function()
                local created = dfhack.items.createItem(
                    unit, df.item_type.FISH, -1, stock.fish_race, stock.fish_caste, false)
                return first_created(created)
            end)
            if not item_ok or not item or not put_on_ground(item, pos) then return end
            pcall(function()
                item.race = stock.fish_race
                item.caste = stock.fish_caste
            end)
            if item.id then supply_ids.fish[item.id] = true end
            if item.stack_size ~= nil then item.stack_size = amount end
        end)
    end
    if stock.meat and meal_mode ~= 'failed' then
        fill_one_stack(others.FOOD, function(item)
            return counts_for_supply(item) and is_lavish_meal(item)
        end, 10, function(amount)
            local item = spawn_stack(unit, pos, df.item_type.FOOD, -1, stock.meat, amount, nil)
            if not item then return end
            local built = false
            pcall(function() built = add_meal_ingredients(item, stock.meat, unit) end)
            if not built then
                pcall(dfhack.items.remove, item)
                meal_mode = 'failed'
                if not meal_warned then
                    meal_warned = true
                    dfhack.printerr("Malphar's Mod: could not build prepared meals.")
                end
            end
        end)
    end
    if stock.drink then
        local have = 0
        local list = others.DRINK
        if list then
            for _, item in ipairs(list) do
                if counts_for_supply(item) and (same_mat(item, stock.drink) or supply_ids.drink[item.id]) then
                    have = have + (item.stack_size or 1)
                end
            end
        end
        local made = 0
        while have < 40 and made < 4 do
            local amount = math.min(10, 40 - have)
            if not spawn_drink_barrel(unit, pos, stock.drink, amount) then break end
            have = have + amount
            made = made + 1
        end
    end
end

local function sweep()
    if not enabled or not dfhack.isMapLoaded() or not dfhack.world.isFortressMode() then
        return
    end
    if not materials then
        local ok, list = pcall(collect_materials)
        if ok and list and #list > 0 then
            materials = list
        else
            materials = {}
            local mi = dfhack.matinfo.find('INORGANIC:ADAMANTINE')
            if mi and mi.material then
                materials[1] = {
                    type = mi.type,
                    index = mi.index,
                    value = mi.material.material_value or 300,
                    material = mi.material,
                }
            end
            if not sweep_warned then
                sweep_warned = true
                dfhack.printerr("Malphar's Mod: using adamantine only.")
            end
        end
    end
    pcall(spawn_doors)
    local larder_ok, larder_err = pcall(ensure_larder)
    local wear_ok, wear_err = pcall(ensure_wardrobe)
    if not wear_ok and not sweep_warned then
        sweep_warned = true
        dfhack.printerr("Malphar's Mod: " .. tostring(wear_err))
    end
    if not larder_ok and not sweep_warned then
        sweep_warned = true
        dfhack.printerr("Malphar's Mod: " .. tostring(larder_err))
    end
    local ok, err = pcall(ensure_stock)
    if not ok and not sweep_warned then
        sweep_warned = true
        dfhack.printerr("Malphar's Mod: " .. tostring(err))
    end
    pcall(upgrade_cheat_shops)
    local budget = MAX_PER_SWEEP
    for _, job in utils.listpairs(df.global.world.jobs.list) do
        if budget <= 0 then break end
        local ok, next_budget = pcall(supply_job, job, budget)
        if not ok then
            if not sweep_warned then
                sweep_warned = true
                dfhack.printerr("Malphar's Mod: " .. tostring(next_budget))
            end
            break
        end
        budget = next_budget
    end
end

local function release_suspended()
    if not enabled or not dfhack.isMapLoaded() or not dfhack.world.isFortressMode() then
        return
    end
    if not materials then return end
    local budget = MAX_PER_SWEEP
    for _, job in utils.listpairs(df.global.world.jobs.list) do
        if job and job.flags.suspend and job.job_type == df.job_type.ConstructBuilding then
            if budget > 0 then
                local ok, next_budget = pcall(supply_job, job, budget)
                if ok and type(next_budget) == 'number' then
                    budget = next_budget
                end
            end
            job.flags.suspend = false
        end
    end
end

local function do_enable()
    enabled = true
    materials = nil
    larder = nil
    meal_mode = nil
    meal_warned = false
    supply_ids = {fish = {}, drink = {}}
    sweep_warned = false
    sweep()
    repeatutil.scheduleEvery(GLOBAL_KEY, 1000, 'ticks', sweep)
    repeatutil.scheduleEvery(PLACE_KEY, 1, 'frames', place_at_cursor)
    repeatutil.scheduleEvery(RELEASE_KEY, 5, 'frames', release_suspended)
    print("Malphar's Mod: best food, clothes, and personal items are kept in supply.")
end

local function do_disable()
    enabled = false
    place_pools = {}
    repeatutil.cancel(GLOBAL_KEY)
    repeatutil.cancel(PLACE_KEY)
    repeatutil.cancel(RELEASE_KEY)
    print("Malphar's Mod: adamantine placement is off.")
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        enabled = false
        materials = nil
        place_pools = {}
        repeatutil.cancel(GLOBAL_KEY)
        repeatutil.cancel(PLACE_KEY)
        repeatutil.cancel(RELEASE_KEY)
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
