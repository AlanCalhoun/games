-- Place buildings without stocked materials. Use adamantine, or the
-- highest-value material the item is allowed to be.
--@enable = true
--@module = true

local repeatutil = require('repeat-util')
local utils = require('utils')

local GLOBAL_KEY = 'malphars_adamantine'
local MAX_PER_SWEEP = 80
-- Soft caps: materials stay small; food/drink/clothes track population.
local MATERIAL_CAP = 100
local AMMO_CAP = 1000
local CULL_PER_SWEEP = 1200
-- Empty bins/barrels only; filled ones are bottomless storage.
local CONTAINER_CAP = 16

enabled = enabled or false
materials = materials or nil

function isEnabled()
    return enabled
end

local function citizen_count()
    local n = 0
    local ok, citizens = pcall(dfhack.units.getCitizens)
    if not ok or not citizens then return 1 end
    for _, unit in pairs(citizens) do
        if unit then n = n + 1 end
    end
    return math.max(n, 1)
end

-- Twice what the fort needs for the current population.
local function pop_need(mult)
    return math.max(20, citizen_count() * (mult or 2))
end

local SKIP_JOB = {
    StoreItemInStockpile = true,
    StoreItemInBag = true,
    StoreItemInLocation = true,
    StoreItemInBarrel = true,
    StoreItemInBin = true,
    StoreItemInVehicle = true,
    StoreOwnedItem = true,
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
    SIEGEAMMO = function(mat) return mat.flags.ITEMS_AMMO or mat.flags.ITEMS_WEAPON end,
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
FILTERS.TRAPCOMP = hard_ok
FILTERS.PIPE_SECTION = hard_ok
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

local function claim_for_job(job, item, idx)
    if not job or not item then return false end
    local before = attached(job, idx or 0)
    local ok = pcall(function()
        return dfhack.job.attachJobItem(job, item, df.job_role_type.Hauled, idx or 0, -1)
    end)
    return ok and attached(job, idx or 0) > before
end

local function free_match_on_tile(job, spawn_type, spawn_sub)
    local pos = job and job.pos
    if not pos or not spawn_type then return nil end
    -- Typed vector only. Walking IN_PLAY (~60k items) was a major lag hitch.
    local type_name = df.item_type[spawn_type]
    local list = type_name and df.global.world.items.other[type_name]
    if not list then return nil end
    for _, item in ipairs(list) do
        if item and item.flags and item.flags.on_ground
            and not item.flags.in_job and not item.flags.in_building
            and not item.flags.in_inventory and not item.flags.garbage_collect
        then
            local sub_ok = true
            if spawn_sub and spawn_sub >= 0 then
                local ok, sub = pcall(function() return item:getSubtype() end)
                sub_ok = ok and sub == spawn_sub
            end
            if sub_ok then
                local ok, x, y, z = pcall(dfhack.items.getPosition, item)
                if ok and x == pos.x and y == pos.y and z == pos.z then
                    return item
                end
            end
        end
    end
end

local function first_created(created)
    if not created then return nil end
    if type(created) == 'number' then return df.item.find(created) end
    -- DFHack createItem returns a 1-based Lua table of item pointers.
    if type(created) == 'table' then
        local from_table = created[1] or created[0]
        if type(from_table) == 'number' then return df.item.find(from_table) end
        if from_table then return from_table end
    end
    local type_name = created._type and tostring(created._type) or ''
    if type_name:find('item') and not type_name:find('vector') then return created end
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

local put_on_ground

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
                    if placing and spawn_type == df.item_type.TRAPCOMP
                        and (not spawn_sub or spawn_sub < 0) and job.pos then
                        local okb, bld = pcall(dfhack.buildings.findAtTile,
                            job.pos.x, job.pos.y, job.pos.z)
                        if okb and bld and bld:getType() == df.building_type.ScrewPump then
                            local cork = dfhack.items.findSubtype(
                                'TRAPCOMP:ITEM_TRAPCOMP_ENORMOUSCORKSCREW')
                            if cork and cork >= 0 then spawn_sub = cork end
                        end
                    end
                    relax_filter(filter, spawn_type, spawn_sub, chosen)
                    job.mat_type = chosen.type
                    job.mat_index = chosen.index
                    local filled = false
                    while missing > 0 and budget > 0 do
                        local item = free_match_on_tile(job, spawn_type, spawn_sub)
                        if not item then
                            local created = dfhack.items.createItem(
                                unit, spawn_type, spawn_sub, chosen.type, chosen.index, false)
                            item = first_created(created)
                            if item and job.pos then
                                put_on_ground(item, {
                                    x = job.pos.x, y = job.pos.y, z = job.pos.z,
                                })
                            end
                        end
                        if not item then break end
                        set_dimension(item, 150)
                        if not claim_for_job(job, item, i) then
                            if not item.flags.in_job then
                                pcall(dfhack.items.remove, item)
                            end
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

local STOCK_BUDGET = 40

-- type, subtype token or nil, count, material picker, stack size, dimension
-- Counts are defaults; stock_want() scales beds/tables and caps materials at 100.
local STOCK = {
    {'DOOR', nil, 30, 'best'},
    {'BED', nil, 20, 'best'},
    {'CHAIR', nil, 30, 'best'},
    {'TABLE', nil, 30, 'best'},
    -- Keep a full stack of adamantine blocks on hand for building.
    {'BLOCKS', nil, 100, 'adamantine', 100},
    {'TRAPPARTS', nil, 30, 'best'},
    -- Screw pumps need corkscrews + pipe sections (not mechanisms).
    {'TRAPCOMP', 'ITEM_TRAPCOMP_ENORMOUSCORKSCREW', 30, 'best'},
    {'TRAPCOMP', 'ITEM_TRAPCOMP_GIANTAXEBLADE', 10, 'best'},
    {'TRAPCOMP', 'ITEM_TRAPCOMP_SPIKEDBALL', 10, 'best'},
    {'TRAPCOMP', 'ITEM_TRAPCOMP_LARGESERRATEDDISC', 10, 'best'},
    {'TRAPCOMP', 'ITEM_TRAPCOMP_MENACINGSPIKE', 10, 'best'},
    {'PIPE_SECTION', nil, 30, 'best'},
    {'PLANT', nil, 100, 'plant', 100},
    {'BAR', nil, 100, 'soap', nil, 150},
    {'CLOTH', nil, 100, 'thread', nil, 10000},
    {'THREAD', nil, 100, 'thread', nil, 15000},
    {'SPLINT', nil, 10, 'best'},
    {'CRUTCH', nil, 10, 'best'},
    {'CHAIN', nil, 30, 'best'},
    {'ANVIL', nil, 2, 'best'},
    {'CABINET', nil, 20, 'best'},
    {'BOX', nil, 20, 'best'},
    {'HATCH_COVER', nil, 20, 'best'},
    {'FLOODGATE', nil, 20, 'best'},
    {'GRATE', nil, 10, 'best'},
    {'CAGE', nil, 20, 'best'},
    {'COFFIN', nil, 10, 'best'},
    {'STATUE', nil, 10, 'best'},
    {'WEAPONRACK', nil, 10, 'best'},
    {'ARMORSTAND', nil, 10, 'best'},
    -- BIN/BARREL stay on stockpiles only (malphar-stockpile). Do not spawn
    -- free ones at citizens — that drops bins in hallways and the inn.
    {'BUCKET', nil, 10, 'best'},
    {'WINDOW', nil, 10, 'best'},
    {'TOOL', 'ITEM_TOOL_BOOKCASE', 20, 'best'},
    {'TOOL', 'ITEM_TOOL_NEST_BOX', 10, 'best'},
    {'TOOL', 'ITEM_TOOL_HIVE', 10, 'best'},
    {'TOOL', 'ITEM_TOOL_DISPLAY_CASE', 10, 'best'},
    {'TOOL', 'ITEM_TOOL_ALTAR', 5, 'best'},
    {'AMMO', 'ITEM_AMMO_BOLTS', 1000, 'best', 100},
    {'AMMO', 'ITEM_AMMO_ARROWS', 1000, 'best', 100},
    {'AMMO', 'ITEM_AMMO_BLOWDARTS', 1000, 'best', 100},
    {'SIEGEAMMO', 'ITEM_SIEGEAMMO_BALLISTA', 1000, 'best', 100},
    {'SHIELD', 'ITEM_SHIELD_SHIELD', 20, 'best'},
    {'SHIELD', 'ITEM_SHIELD_BUCKLER', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_PICK', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_AXE_BATTLE', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_HAMMER_WAR', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_SWORD_SHORT', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_SWORD_LONG', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_SWORD_2H', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_SPEAR', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_MACE', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_CROSSBOW', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_BOW', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_PIKE', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_HALBERD', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_MAUL', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_AXE_GREAT', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_DAGGER_LARGE', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_SCIMITAR', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_FLAIL', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_MORNINGSTAR', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_WHIP', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_SCOURGE', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_BLOWGUN', 20, 'best'},
    {'WEAPON', 'ITEM_WEAPON_PICK_GREAT', 20, 'best'},
}

local function stock_want(spec)
    local type_name, want = spec[1], spec[3]
    local n = citizen_count()
    if type_name == 'BED' then return n + 10 end
    if type_name == 'CHAIR' or type_name == 'TABLE' then return n end
    if type_name == 'CABINET' or type_name == 'BOX' or type_name == 'WEAPONRACK'
        or type_name == 'ARMORSTAND' then
        return math.min(MATERIAL_CAP, n)
    end
    if type_name == 'COFFIN' then return math.min(MATERIAL_CAP, math.ceil(n / 2)) end
    if type_name == 'AMMO' or type_name == 'SIEGEAMMO' then return AMMO_CAP end
    if type_name == 'WEAPON' and spec[2] == 'ITEM_WEAPON_PICK' then
        return math.min(MATERIAL_CAP, math.max(20, math.ceil(n / 4)))
    end
    return math.min(want or MATERIAL_CAP, MATERIAL_CAP)
end

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
    elseif kind == 'adamantine' then
        return dfhack.matinfo.find('INORGANIC:ADAMANTINE')
            or best_material(item_type)
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

local function count_free_mat(type_name, want_type, want_index)
    local have = 0
    local list = df.global.world.items.other[type_name]
    if not list then return 0 end
    for i = 0, #list - 1 do
        local item = list[i]
        if item_is_free(item) then
            local mt, mi
            pcall(function()
                mt = item.getMaterial and item:getMaterial() or item.mat_type
                mi = item.getMaterialIndex and item:getMaterialIndex() or item.mat_index
            end)
            if mt == want_type and mi == want_index then
                have = have + (item.stack_size or 1)
            end
        end
    end
    return have
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
    -- Never use the mouse here. That was dumping stock items under the cursor.
end

put_on_ground = function(item, pos)
    if not item or not pos then return false end
    pcall(function() dfhack.items.moveToGround(item, pos) end)
    item.flags.on_ground = true
    item.flags.in_inventory = false
    item.flags.forbid = false
    item.flags.hidden = false
    pcall(function()
        if item.pos then
            item.pos.x = pos.x
            item.pos.y = pos.y
            item.pos.z = pos.z
        end
    end)
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
    -- Only the STOCK item types. Full IN_PLAY scans were ~180ms on this fort.
    local seen_type = {}
    local others = df.global.world.items.other
    for _, spec in ipairs(STOCK) do
        local type_name = spec[1]
        if type_name and not seen_type[type_name] then
            seen_type[type_name] = true
            local list = others[type_name]
            if list then
                for _, item in ipairs(list) do
                    if item_is_free(item) then
                        local item_type = item:getType()
                        local subtype = item:getSubtype()
                        local n = item.stack_size or 1
                        by_type[item_type] = (by_type[item_type] or 0) + n
                        if subtype and subtype >= 0 then
                            by_sub[item_type .. ':' .. subtype] =
                                (by_sub[item_type .. ':' .. subtype] or 0) + n
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
            end
        end
    end
    return by_type, by_sub, soap, piles
end

-- Keep every ammo consumer loaded: siege engines, bolt throwers, catapults,
-- and anyone carrying a bow / crossbow / blowgun.
local AMMO_LOAD_BUDGET = 40
local BOLT_THROWER_LOAD = 25
local BOLT_THROWER_MIN = 10
local UNIT_AMMO_WANT = 50
local RANGED_AMMO_TOKEN = {
    BOLT = 'ITEM_AMMO_BOLTS',
    ARROW = 'ITEM_AMMO_ARROWS',
    BLOWDART = 'ITEM_AMMO_BLOWDARTS',
}

local function siege_ammo_units(bld, item_type)
    local n = 0
    for _, ci in ipairs(bld.contained_items) do
        if ci.item and ci.item:getType() == item_type then
            n = n + (ci.item.stack_size or 1)
        end
    end
    return n
end

local function siege_kind(bld)
    for _, ci in ipairs(bld.contained_items) do
        local item = ci.item
        if item then
            local t = item:getType()
            if t == df.item_type.BALLISTAPARTS then return 'ballista' end
            if t == df.item_type.BOLT_THROWER_PARTS then return 'bolt_thrower' end
            if t == df.item_type.CATAPULTPARTS then return 'catapult' end
        end
    end
end

local function move_ammo_into_engine(item, bld)
    if not item or not bld then return false end
    local pos = xyz2pos(bld.centerx, bld.centery, bld.z)
    pcall(function()
        local container = dfhack.items.getContainer(item)
        if container then
            dfhack.items.moveToGround(item, pos)
        end
    end)
    pcall(dfhack.items.moveToGround, item, pos)
    local ok, res = pcall(dfhack.items.moveToBuilding, item, bld,
        df.building_item_role_type.GENERAL, false)
    return ok and res
end

local function spawn_ammo_item(unit, item_type, subtype, mat, stack)
    local created = dfhack.items.createItem(
        unit, item_type, subtype, mat.type, mat.index, false)
    local item = first_created(created)
    if not item then return nil end
    if stack and item.stack_size ~= nil then
        item.stack_size = stack
    end
    return item
end

local function unit_find_quiver(unit)
    if not unit or not unit.inventory then return nil end
    for _, inv in ipairs(unit.inventory) do
        if inv.item and inv.item:getType() == df.item_type.QUIVER then
            return inv.item
        end
    end
end

local function unit_carried_ammo(unit, subtype)
    local n = 0
    if not unit or not unit.inventory then return 0 end
    for _, inv in ipairs(unit.inventory) do
        local item = inv.item
        if item and item:getType() == df.item_type.AMMO and item:getSubtype() == subtype then
            n = n + (item.stack_size or 1)
        elseif item and item:getType() == df.item_type.QUIVER then
            for _, child in ipairs(dfhack.items.getContainedItems(item) or {}) do
                if child:getType() == df.item_type.AMMO and child:getSubtype() == subtype then
                    n = n + (child.stack_size or 1)
                end
            end
        end
    end
    return n
end

local function unit_ranged_ammo_token(unit)
    if not unit or not unit.inventory then return nil end
    for _, inv in ipairs(unit.inventory) do
        local item = inv.item
        if item and item:getType() == df.item_type.WEAPON and item.subtype then
            local class = item.subtype.ranged_ammo
            if type(class) == 'string' and class ~= '' then
                local token = RANGED_AMMO_TOKEN[class]
                if token then return token end
            end
        end
    end
end

local function give_unit_ammo(unit, subtype, mat, want)
    local have = unit_carried_ammo(unit, subtype)
    if have >= want then return false end
    local item = spawn_ammo_item(unit, df.item_type.AMMO, subtype, mat, want - have)
    if not item then return false end
    local quiver = unit_find_quiver(unit)
    if quiver then
        local ok, res = pcall(dfhack.items.moveToContainer, item, quiver)
        if ok and res ~= false then return true end
    end
    local ok, res = pcall(dfhack.items.moveToInventory, item, unit,
        df.inv_item_role_type.Hauled, -1)
    if ok and res then return true end
    pcall(dfhack.items.remove, item)
    return false
end

local function ensure_ammo_loaded()
    local unit = creator_unit()
    if not unit or not materials then return end
    local ammo_mat = pick_mat('best', df.item_type.AMMO)
    local siege_mat = pick_mat('best', df.item_type.SIEGEAMMO) or ammo_mat
    if not ammo_mat then return end
    local bolt_sub = cached_subtype('AMMO', 'ITEM_AMMO_BOLTS')
    local arrow_sub = cached_subtype('AMMO', 'ITEM_AMMO_ARROWS')
    local dart_sub = cached_subtype('AMMO', 'ITEM_AMMO_BLOWDARTS')
    local siege_sub = cached_subtype('SIEGEAMMO', 'ITEM_SIEGEAMMO_BALLISTA')
    local subtype_for = {
        ITEM_AMMO_BOLTS = bolt_sub,
        ITEM_AMMO_ARROWS = arrow_sub,
        ITEM_AMMO_BLOWDARTS = dart_sub,
    }
    local loaded = 0

    for _, bld in ipairs(df.global.world.buildings.all) do
        if loaded >= AMMO_LOAD_BUDGET then break end
        if df.building_type[bld:getType()] == 'SiegeEngine' then
            local kind = siege_kind(bld)
            if kind == 'bolt_thrower' and bolt_sub and bolt_sub >= 0
                and siege_ammo_units(bld, df.item_type.AMMO) < BOLT_THROWER_MIN then
                local item = spawn_ammo_item(
                    unit, df.item_type.AMMO, bolt_sub, ammo_mat, BOLT_THROWER_LOAD)
                if item and move_ammo_into_engine(item, bld) then
                    loaded = loaded + 1
                elseif item then
                    pcall(dfhack.items.remove, item)
                end
            elseif kind == 'ballista' and siege_sub and siege_sub >= 0 and siege_mat
                and siege_ammo_units(bld, df.item_type.SIEGEAMMO) < 1 then
                local item = spawn_ammo_item(
                    unit, df.item_type.SIEGEAMMO, siege_sub, siege_mat, 1)
                if item and move_ammo_into_engine(item, bld) then
                    loaded = loaded + 1
                elseif item then
                    pcall(dfhack.items.remove, item)
                end
            elseif kind == 'catapult' and siege_ammo_units(bld, df.item_type.BOULDER) < 1 then
                local rock
                for _, it in ipairs(df.global.world.items.other.BOULDER or {}) do
                    if it and not it.flags.garbage_collect and not it.flags.in_building
                        and not it.flags.in_job and not it.flags.construction
                        and item_is_free(it) then
                        rock = it
                        break
                    end
                end
                if rock and move_ammo_into_engine(rock, bld) then
                    loaded = loaded + 1
                end
            end
        end
    end

    local ok_citizens, citizens = pcall(dfhack.units.getCitizens, true)
    if ok_citizens and citizens then
        for _, citizen in pairs(citizens) do
            if loaded >= AMMO_LOAD_BUDGET then break end
            if citizen and dfhack.units.isActive(citizen) and not dfhack.units.isDead(citizen) then
                local token = unit_ranged_ammo_token(citizen)
                local subtype = token and subtype_for[token]
                if subtype and subtype >= 0 then
                    if give_unit_ammo(citizen, subtype, ammo_mat, UNIT_AMMO_WANT) then
                        loaded = loaded + 1
                    end
                end
            end
        end
    end
end

local function ensure_stock()
    local unit = creator_unit()
    if not unit or not materials then return end
    local pos = ground_pos(unit)
    if not pos then return end
    local by_type, by_sub, soap, piles = tally_free(pos)
    local removed = 0
    for _, spec in ipairs(STOCK) do
        if removed >= 80 then break end
        local type_name, token = spec[1], spec[2]
        local want = stock_want(spec)
        local item_type = df.item_type[type_name]
        local subtype = item_type and cached_subtype(type_name, token)
        if item_type and subtype then
            local key = item_type .. ':' .. subtype
            local pile = piles[key]
            if pile and #pile > want then
                for i = want + 1, #pile do
                    if removed >= 80 then break end
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
        local type_name, token, _, kind, stack, dimension = spec[1], spec[2], spec[3], spec[4], spec[5], spec[6]
        local want = stock_want(spec)
        local item_type = df.item_type[type_name]
        local subtype = item_type and cached_subtype(type_name, token)
        if item_type and subtype then
            local have
            local chosen = pick_mat(kind, item_type)
            if kind == 'soap' then
                have = soap
            elseif kind == 'adamantine' and chosen then
                have = count_free_mat(type_name, chosen.type, chosen.index)
            elseif subtype >= 0 then
                have = by_sub[item_type .. ':' .. subtype] or 0
            else
                have = by_type[item_type] or 0
            end
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

-- Cursor-follow preview stays off (it dumped free items under the mouse).
-- While the build menu is open, keep free matching furniture in stock so
-- "Closest item" never runs out. Spawn at a citizen, never at the cursor.
local function placing_now()
    local ok, mode = pcall(function()
        return df.global.game.main_interface.bottom_mode_selected
    end)
    return ok and mode == df.main_bottom_mode_type.BUILDING_PLACEMENT
end

local function clear_place_previews()
    for _, pool in pairs(place_pools) do
        for _, item in ipairs(pool) do
            if item and item.flags and item.flags.on_ground
                and not item.flags.in_job and not item.flags.in_building
            then
                pcall(dfhack.items.remove, item)
            end
        end
    end
    place_pools = {}
end

local function filter_item_type(filter)
    local item_type = filter.item_type
    if item_type and item_type >= 0 then return item_type end
    local vector_name = filter.vector_id and df.job_item_vector_id[filter.vector_id]
    if vector_name and df.item_type[vector_name] then
        return df.item_type[vector_name]
    end
end

local function count_free(item_type, subtype)
    local name = df.item_type[item_type]
    local list = name and df.global.world.items.other[name]
    if not list then return 0 end
    local n = 0
    for _, item in ipairs(list) do
        if item_is_free(item) then
            if not subtype or subtype < 0 or item:getSubtype() == subtype then
                n = n + 1
            end
        end
    end
    return n
end

local function ensure_build_menu_stock()
    if not enabled or not dfhack.isMapLoaded() or not placing_now() then
        return
    end
    if not materials then return end
    local ui = df.global.buildreq
    local unit = creator_unit()
    local pos = ground_pos(unit)
    if not ui or not unit or not pos then return end
    local ok, filters = pcall(dfhack.buildings.getFiltersByType, {},
        ui.building_type, ui.building_subtype, ui.custom_type)
    if not ok or not filters then return end
    local made = 0
    for _, filter in ipairs(filters) do
        if made >= 15 then break end
        local item_type = filter_item_type(filter)
        if item_type then
            local subtype = filter.item_subtype
            if not subtype or subtype < 0 then subtype = -1 end
            if filter.has_tool_use and filter.has_tool_use >= 0 then
                local sub = tool_subtype(filter.has_tool_use)
                if sub >= 0 then
                    item_type = df.item_type.TOOL
                    subtype = sub
                end
            end
            -- Screw pumps need enormous corkscrews, not a random trap component.
            if item_type == df.item_type.TRAPCOMP and subtype < 0
                and ui.building_type == df.building_type.ScrewPump then
                local cork = cached_subtype('TRAPCOMP', 'ITEM_TRAPCOMP_ENORMOUSCORKSCREW')
                if cork then subtype = cork end
            end
            local chosen = best_material(item_type)
            if chosen then
                local have = count_free(item_type, subtype)
                while have < 15 and made < 15 do
                    local created = dfhack.items.createItem(
                        unit, item_type, subtype, chosen.type, chosen.index, false)
                    local item = first_created(created)
                    if not item or not put_on_ground(item, pos) then break end
                    set_masterwork(item)
                    have = have + 1
                    made = made + 1
                end
            end
        end
    end
end

local function place_at_cursor()
    -- Keep free stock for the open build menu; do not spawn under the cursor.
    ensure_build_menu_stock()
end

local function construct_job_at(x, y, z)
    local ok, bld = pcall(dfhack.buildings.findAtTile, x, y, z)
    if not ok or not bld or not bld.jobs then return nil end
    for _, job in ipairs(bld.jobs) do
        if job and job.job_type == df.job_type.ConstructBuilding then
            return job
        end
    end
end

local function building_at(x, y, z)
    local ok, bld = pcall(dfhack.buildings.findAtTile, x, y, z)
    if ok then return bld end
end

local function scrub_placement_orphans()
    local list = df.global.world.items.other.IN_PLAY
    if not list then return end
    local removed = 0
    for _, item in ipairs(list) do
        if removed >= 40 then break end
        if item and item.flags and item.flags.on_ground
            and not item.flags.in_job and not item.flags.in_building
            and not item.flags.in_inventory and not item.flags.garbage_collect
        then
            local ok, x, y, z = pcall(dfhack.items.getPosition, item)
            if ok and x and x >= 0 then
                local bld = building_at(x, y, z)
                if bld and bld:getType() ~= df.building_type.Stockpile
                    and not construct_job_at(x, y, z)
                then
                    local bname = df.building_type[bld:getType()]
                    local iname = df.item_type[item:getType()]
                    local match = bname and iname and bname:upper() == iname:upper()
                    if not match and iname == 'TOOL' then
                        match = bname == 'Bookcase' or bname == 'DisplayFurniture'
                            or bname == 'NestBox' or bname == 'Hive'
                    end
                    if match then
                        pcall(dfhack.items.remove, item)
                        removed = removed + 1
                    end
                end
            end
        end
    end
end

local larder
local meal_mode
local meal_warned = false
local supply_ids = {fish = {}, drink = {}}

local function counts_for_supply(item)
    if not item or not item.flags then return false end
    local f = item.flags
    if f.garbage_collect or f.rotten or f.forbid or f.hidden
        or f.owned or f.dump or f.in_job or f.in_building
    then
        return false
    end
    -- Bin/barrel contents count; worn gear on a unit does not.
    local ok, unit = pcall(dfhack.items.getHolderUnit, item)
    if ok and unit then return false end
    return true
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

local function can_cull_item(item)
    if not item or not item.flags then return false end
    local f = item.flags
    if f.garbage_collect or f.in_building or f.construction or f.in_job
        or f.artifact or f.owned or f.forbid
    then
        return false
    end
    local ok, unit = pcall(dfhack.items.getHolderUnit, item)
    if ok and unit then return false end
    return true
end

local function cull_remove(item)
    if not can_cull_item(item) then return false end
    local ok, res = pcall(dfhack.items.remove, item)
    return ok and res ~= false
end

local function fill_one_stack(list, match, want, spawn)
    local have = 0
    local target
    local extras = {}
    if list then
        for _, item in ipairs(list) do
            if match(item) then
                have = have + (item.stack_size or 1)
                if item.stack_size ~= nil then
                    if not target then
                        target = item
                    else
                        extras[#extras + 1] = item
                    end
                elseif can_cull_item(item) then
                    extras[#extras + 1] = item
                end
            end
        end
    end
    if have > want then
        local excess = have - want
        if target and target.stack_size and target.stack_size > 1 then
            local cut = math.min(excess, target.stack_size - 1)
            target.stack_size = target.stack_size - cut
            excess = excess - cut
            have = have - cut
        end
        for i = #extras, 1, -1 do
            if excess <= 0 then break end
            local item = extras[i]
            local size = item.stack_size or 1
            if size > excess and item.stack_size then
                item.stack_size = size - excess
                excess = 0
            elseif cull_remove(item) then
                excess = excess - size
            end
        end
        if target then set_masterwork(target) end
        return
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
    if not ing or not ing.insert then return false end
    -- Modern DF: vector<food_ingredientst*>. Older builds used parallel arrays.
    if df.food_ingredientst and df.food_ingredientst.new then
        for _ = 1, 4 do
            local fi = df.food_ingredientst:new()
            if not fi then return false end
            fi.item_type = df.item_type.MEAT
            fi.item_subtype = -1
            fi.mat_type = mat.type
            fi.mat_index = mat.index
            fi.maker = unit and unit.id or -1
            fi.quality = 5
            ing:insert('#', fi)
        end
        pcall(function() item.quality = 5 end)
        pcall(function() item:setQuality(5) end)
        return #ing >= 4
    end
    if not ing.item_type or not ing.item_type.insert then return false end
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
    pcall(function() item.quality = 5 end)
    return #ing.item_type >= 4
end

local function meal_ingredient_count(item)
    local ok, n = pcall(function()
        local ing = item.ingredients
        if not ing then return 0 end
        if ing.item_type then return #ing.item_type end
        return #ing
    end)
    return ok and n or 0
end

local function is_lavish_meal(item)
    local ok, yes = pcall(function()
        return meal_ingredient_count(item) >= 4 and (item.quality or 0) >= 5
    end)
    return ok and yes
end

local function stockpile_drop_pos(fallback)
    local piles = df.global.world.buildings.other.STOCKPILE
    if piles then
        for _, pile in ipairs(piles) do
            if pile then
                local x = pile.centerx or pile.x1
                local y = pile.centery or pile.y1
                local z = pile.z
                if tile_ok(x, y, z) then
                    return {x = x, y = y, z = z}
                end
            end
        end
    end
    return fallback
end

-- Top inventory bar counts drinks inside barrels/containers.
local function count_barrelled_drinks()
    local list = df.global.world.items.other.DRINK
    if not list then return 0 end
    local n = 0
    for i = 0, #list - 1 do
        local item = list[i]
        if item and item.flags and not item.flags.garbage_collect
            and not item.flags.rotten and not item.flags.artifact
            and dfhack.items.getContainer(item)
        then
            local ok, unit = pcall(dfhack.items.getHolderUnit, item)
            if not (ok and unit) then
                n = n + (item.stack_size or 1)
            end
        end
    end
    return n
end

local function spawn_drink_barrel(unit, pos, mat, amount)
    local metal = dfhack.matinfo.find('INORGANIC:ADAMANTINE')
    if not metal or not mat then return false end
    pos = stockpile_drop_pos(pos)
    if not pos then return false end
    local barrel_ok, barrel = pcall(function()
        local created = dfhack.items.createItem(
            unit, df.item_type.BARREL, -1, metal.type, metal.index, false)
        return first_created(created)
    end)
    if not barrel_ok or not barrel then return false end
    pcall(function() dfhack.items.moveToGround(barrel, pos) end)
    barrel.flags.on_ground = true
    barrel.flags.in_inventory = false
    barrel.flags.forbid = false
    local drink_ok, drink = pcall(function()
        local created = dfhack.items.createItem(
            unit, df.item_type.DRINK, -1, mat.type, mat.index, false)
        return first_created(created)
    end)
    if not drink_ok or not drink then
        pcall(dfhack.items.remove, barrel)
        return false
    end
    if drink.stack_size ~= nil then drink.stack_size = amount end
    set_dimension(drink, 150)
    if drink.id then supply_ids.drink[drink.id] = true end
    local moved = false
    pcall(function()
        moved = dfhack.items.moveToContainer(drink, barrel) ~= false
    end)
    if not moved then
        pcall(function() dfhack.items.moveToGround(drink, pos) end)
        drink.flags.on_ground = true
    end
    return true
end

-- Top bar counts barrelled drinks; grow those stacks first, then add barrels.
local function ensure_drinks(unit, pos, mat)
    if not unit or not mat then return end
    local want = pop_need(2)
    local have = count_barrelled_drinks()
    if have >= want then return end
    local list = df.global.world.items.other.DRINK
    if list then
        for i = 0, #list - 1 do
            if have >= want then break end
            local item = list[i]
            if item and item.flags and not item.flags.garbage_collect
                and item.stack_size and dfhack.items.getContainer(item)
            then
                local ok, holder = pcall(dfhack.items.getHolderUnit, item)
                if not (ok and holder) then
                    local add = want - have
                    item.stack_size = (item.stack_size or 1) + add
                    have = want
                end
            end
        end
    end
    local made = 0
    while have < want and made < 12 do
        local amount = math.min(50, want - have)
        if not spawn_drink_barrel(unit, pos, mat, amount) then break end
        have = count_barrelled_drinks()
        made = made + 1
    end
end

local FODDER = {
    {'PLANT', 'PLANT_MAT:MUSHROOM_HELMET_PLUMP:STRUCTURAL'},
    {'PLANT', 'PLANT_MAT:GRASS_WHEAT_CAVE:STRUCTURAL'},
    {'PLANT', 'PLANT_MAT:GRASS_TAIL_PIG:STRUCTURAL'},
    {'PLANT', 'PLANT_MAT:POD_SWEET:STRUCTURAL'},
    {'SEEDS', 'PLANT_MAT:MUSHROOM_HELMET_PLUMP:SEED'},
    {'SEEDS', 'PLANT_MAT:GRASS_WHEAT_CAVE:SEED'},
    {'SEEDS', 'PLANT_MAT:GRASS_TAIL_PIG:SEED'},
    {'SEEDS', 'PLANT_MAT:POD_SWEET:SEED'},
}

local function ensure_fodder(unit, pos, others)
    local want = math.min(MATERIAL_CAP, pop_need(2))
    for _, spec in ipairs(FODDER) do
        local type_name, token = spec[1], spec[2]
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
-- Only maintain the useful set at 2x population; cull trims every other subtype.
local WARDROBE = {
    {'ARMOR', 'ITEM_ARMOR_SHIRT'},
    {'ARMOR', 'ITEM_ARMOR_CLOAK'},
    {'ARMOR', 'ITEM_ARMOR_BREASTPLATE'},
    {'ARMOR', 'ITEM_ARMOR_MAIL_SHIRT'},
    {'PANTS', 'ITEM_PANTS_PANTS'},
    {'PANTS', 'ITEM_PANTS_GREAVES'},
    {'HELM', 'ITEM_HELM_CAP'},
    {'HELM', 'ITEM_HELM_HELM'},
    {'GLOVES', 'ITEM_GLOVES_GLOVES'},
    {'GLOVES', 'ITEM_GLOVES_GAUNTLETS'},
    {'SHOES', 'ITEM_SHOES_SHOES'},
    {'SHOES', 'ITEM_SHOES_SOCKS'},
    {'SHOES', 'ITEM_SHOES_BOOTS'},
    {'BACKPACK', nil},
    {'QUIVER', nil},
    {'FLASK', nil},
}

local function ensure_wardrobe()
    local unit = creator_unit()
    if not unit or not materials then return end
    local pos = ground_pos(unit)
    if not pos then return end
    local want = pop_need(2)
    local made = 0
    local others = df.global.world.items.other
    for _, spec in ipairs(WARDROBE) do
        if made >= WARDROBE_BUDGET then break end
        local type_name, token = spec[1], spec[2]
        local item_type = df.item_type[type_name]
        local subtype = item_type and cached_subtype(type_name, token)
        local mat = item_type and best_material(item_type)
        local list = item_type and others[type_name]
        if item_type and subtype and mat and list then
            local have = 0
            for _, item in ipairs(list) do
                local sub_ok = subtype < 0 or item:getSubtype() == subtype
                if counts_for_supply(item) and sub_ok then
                    have = have + 1
                    if same_mat(item, mat) then set_masterwork(item) end
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

local function quality_of(item)
    local q = 0
    pcall(function() q = item.quality or 0 end)
    return q
end

local function cull_ids(ids, keep, budget)
    if budget <= 0 or #ids <= keep then return budget end
    local items = {}
    for _, id in ipairs(ids) do
        local item = df.item.find(id)
        if item and can_cull_item(item) then
            items[#items + 1] = item
        end
    end
    table.sort(items, function(a, b)
        local qa, qb = quality_of(a), quality_of(b)
        if qa ~= qb then return qa > qb end
        return (a.id or 0) < (b.id or 0)
    end)
    for i = keep + 1, #items do
        if budget <= 0 then break end
        local item = items[i]
        local size = item.stack_size or 1
        if keep >= 0 and i == keep + 1 and item.stack_size and size > 1 then
            -- handled below for unit caps; item removals for count caps
        end
        if cull_remove(item) then
            budget = budget - 1
        end
    end
    return budget
end

local function trim_unit_group(ids, units, cap, budget)
    if budget <= 0 or units <= cap then return budget end
    local excess = units - cap
    for i = #ids, 1, -1 do
        if budget <= 0 or excess <= 0 then break end
        local item = df.item.find(ids[i])
        if item and can_cull_item(item) then
            local size = item.stack_size or 1
            if size > excess and item.stack_size then
                item.stack_size = size - excess
                budget = budget - 1
                excess = 0
            elseif cull_remove(item) then
                excess = excess - size
                budget = budget - 1
            end
        end
    end
    return budget
end

-- Cap each material separately (bars, cloth, thread, seeds).
local function cull_units_by_mat(type_name, cap, budget)
    local list = df.global.world.items.other[type_name]
    if not list or budget <= 0 then return budget end
    local groups = {}
    local n = #list
    for i = 0, n - 1 do
        local item = list[i]
        if item and can_cull_item(item) then
            local mt, mi = -1, -1
            pcall(function()
                mt = item.getMaterial and item:getMaterial() or item.mat_type
                mi = item.getMaterialIndex and item:getMaterialIndex() or item.mat_index
            end)
            local key = tostring(mt) .. ':' .. tostring(mi)
            local g = groups[key]
            if not g then
                g = {units = 0, ids = {}}
                groups[key] = g
            end
            g.units = g.units + (item.stack_size or 1)
            g.ids[#g.ids + 1] = item.id
        end
    end
    for _, g in pairs(groups) do
        if budget <= 0 then break end
        budget = trim_unit_group(g.ids, g.units, cap, budget)
    end
    return budget
end

-- Cap the whole type (food, wood, boulders) regardless of material.
local function cull_units_total(type_name, cap, budget)
    local list = df.global.world.items.other[type_name]
    if not list or budget <= 0 then return budget end
    local ids = {}
    local units = 0
    local n = #list
    for i = 0, n - 1 do
        local item = list[i]
        if item and can_cull_item(item) then
            units = units + (item.stack_size or 1)
            ids[#ids + 1] = item.id
        end
    end
    return trim_unit_group(ids, units, cap, budget)
end

local function cull_count_by_subtype(type_name, keep_for_sub, budget)
    local list = df.global.world.items.other[type_name]
    if not list or budget <= 0 then return budget end
    local groups = {}
    local n = #list
    for i = 0, n - 1 do
        local item = list[i]
        if item and can_cull_item(item) then
            local sub = -1
            pcall(function() sub = item:getSubtype() end)
            local key = tostring(sub)
            local g = groups[key]
            if not g then
                g = {}
                groups[key] = g
            end
            g[#g + 1] = item.id
        end
    end
    for sub_key, ids in pairs(groups) do
        if budget <= 0 then break end
        local keep = keep_for_sub
        if type(keep_for_sub) == 'function' then
            keep = keep_for_sub(tonumber(sub_key) or -1)
        end
        budget = cull_ids(ids, keep, budget)
    end
    return budget
end

local function cull_ammo_list(list, budget)
    if not list or budget <= 0 then return budget end
    local groups = {}
    local n = #list
    for i = 0, n - 1 do
        local item = list[i]
        if item and can_cull_item(item) then
            local sub = -1
            pcall(function() sub = item:getSubtype() end)
            local key = tostring(sub)
            local g = groups[key]
            if not g then
                g = {units = 0, ids = {}}
                groups[key] = g
            end
            g.units = g.units + (item.stack_size or 1)
            g.ids[#g.ids + 1] = item.id
        end
    end
    for _, g in pairs(groups) do
        if budget <= 0 then break end
        if g.units > AMMO_CAP then
            local excess = g.units - AMMO_CAP
            for i = #g.ids, 1, -1 do
                if budget <= 0 or excess <= 0 then break end
                local item = df.item.find(g.ids[i])
                if item and can_cull_item(item) then
                    local size = item.stack_size or 1
                    if size > excess and item.stack_size then
                        item.stack_size = size - excess
                        budget = budget - 1
                        excess = 0
                    elseif cull_remove(item) then
                        excess = excess - size
                        budget = budget - 1
                    end
                end
            end
        end
    end
    return budget
end

local function cull_ammo(budget)
    local others = df.global.world.items.other
    budget = cull_ammo_list(others.AMMO, budget)
    budget = cull_ammo_list(others.SIEGEAMMO, budget)
    return budget
end

local function cull_empty_containers(budget)
    for _, name in ipairs({'BIN', 'BARREL'}) do
        if budget <= 0 then break end
        local list = df.global.world.items.other[name]
        if list then
            local empty = {}
            local n = #list
            for i = 0, n - 1 do
                local item = list[i]
                if item and can_cull_item(item) then
                    local held = 0
                    pcall(function()
                        local contents = dfhack.items.getContainedItems(item)
                        if contents then held = #contents end
                    end)
                    if held == 0 then
                        empty[#empty + 1] = item.id
                    end
                end
            end
            budget = cull_ids(empty, CONTAINER_CAP, budget)
        end
    end
    return budget
end

local WARDROBE_SUBTYPES = nil
local function wardrobe_subtype_set()
    if WARDROBE_SUBTYPES then return WARDROBE_SUBTYPES end
    local set = {}
    for _, spec in ipairs(WARDROBE) do
        local type_name, token = spec[1], spec[2]
        local subtype = cached_subtype(type_name, token)
        if subtype then
            set[type_name] = set[type_name] or {}
            set[type_name][subtype] = true
        end
    end
    WARDROBE_SUBTYPES = set
    return set
end

-- Trim the fort toward ~100 of each material and 2x-pop clothes/food.
local function cull_surplus()
    local budget = CULL_PER_SWEEP
    local clothes = pop_need(2)
    local food = pop_need(2)
    -- Per-material caps (100 each).
    for _, name in ipairs({
        'BAR', 'BLOCKS', 'CLOTH', 'THREAD', 'SKIN_TANNED', 'SEEDS', 'PLANT',
    }) do
        if budget <= 0 then break end
        budget = cull_units_by_mat(name, MATERIAL_CAP, budget)
    end
    -- Fort-wide caps (do not keep 100 of every rock/wood type).
    for _, name in ipairs({'WOOD', 'BOULDER'}) do
        if budget <= 0 then break end
        budget = cull_units_total(name, MATERIAL_CAP, budget)
    end
    for _, name in ipairs({'MEAT', 'FISH', 'CHEESE', 'FOOD'}) do
        if budget <= 0 then break end
        budget = cull_units_total(name, food, budget)
    end
    budget = cull_ammo(budget)
    local allowed = wardrobe_subtype_set()
    for _, name in ipairs({
        'ARMOR', 'PANTS', 'SHOES', 'HELM', 'GLOVES',
        'BACKPACK', 'QUIVER', 'FLASK',
    }) do
        if budget <= 0 then break end
        local allow = allowed[name]
        budget = cull_count_by_subtype(name, function(sub)
            if allow and allow[sub] then return clothes end
            return 0
        end, budget)
    end
    for _, name in ipairs({
        'SHIELD', 'WEAPON', 'AMULET', 'RING', 'EARRING', 'BRACELET', 'CROWN',
    }) do
        if budget <= 0 then break end
        local keep = math.min(MATERIAL_CAP, math.max(20, math.ceil(citizen_count() / 4)))
        if name ~= 'WEAPON' and name ~= 'SHIELD' then
            keep = 0
        end
        budget = cull_count_by_subtype(name, keep, budget)
    end
    budget = cull_empty_containers(budget)
    return CULL_PER_SWEEP - budget
end

local function ensure_larder()
    local unit = creator_unit()
    if not unit then return end
    local pos = ground_pos(unit)
    if not pos then return end
    local stock = resolve_larder()
    local others = df.global.world.items.other
    local want = pop_need(2)
    ensure_fodder(unit, pos, others)
    if stock.meat then
        fill_one_stack(others.MEAT, function(item)
            return counts_for_supply(item) and same_mat(item, stock.meat)
        end, want, function(amount)
            spawn_stack(unit, pos, df.item_type.MEAT, -1, stock.meat, amount, 150)
        end)
    end
    if stock.cheese then
        fill_one_stack(others.CHEESE, function(item)
            return counts_for_supply(item) and same_mat(item, stock.cheese)
        end, want, function(amount)
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
                mat_ok = item.mat_type == stock.fish_race
                    and item.mat_index == stock.fish_caste
            end)
            return mat_ok
        end, want, function(amount)
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
        end, want, function(amount)
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
        ensure_drinks(unit, pos, stock.drink)
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
    local cull_ok, cull_err = pcall(cull_surplus)
    if not cull_ok and not sweep_warned then
        sweep_warned = true
        dfhack.printerr("Malphar's Mod: " .. tostring(cull_err))
    end
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
    -- Drinks again on their own so a earlier larder failure can't skip booze.
    pcall(function()
        local unit = creator_unit()
        local pos = ground_pos(unit)
        local stock = resolve_larder()
        if unit and pos and stock and stock.drink then
            ensure_drinks(unit, pos, stock.drink)
        end
    end)
    local ok, err = pcall(ensure_stock)
    if not ok and not sweep_warned then
        sweep_warned = true
        dfhack.printerr("Malphar's Mod: " .. tostring(err))
    end
    pcall(ensure_ammo_loaded)
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
    -- Furniture stock is topped up in sweep() / the build menu, not every frame.
    local budget = MAX_PER_SWEEP
    for _, job in utils.listpairs(df.global.world.jobs.list) do
        if job and job.job_type == df.job_type.ConstructBuilding then
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
    clear_place_previews()
    sweep()
    repeatutil.scheduleEvery(GLOBAL_KEY, 2203, 'ticks', sweep)
    -- While placing, top up free matching furniture (not under the cursor).
    repeatutil.scheduleEvery(PLACE_KEY, 5, 'frames', place_at_cursor)
    repeatutil.scheduleEvery(RELEASE_KEY, 45, 'frames', release_suspended)
    print("Malphar's Mod: buildings get materials when designated (stock tops up in the build menu).")
end

local function do_disable()
    enabled = false
    clear_place_previews()
    repeatutil.cancel(GLOBAL_KEY)
    repeatutil.cancel(PLACE_KEY)
    repeatutil.cancel(RELEASE_KEY)
    print("Malphar's Mod: adamantine placement is off.")
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        enabled = false
        materials = nil
        clear_place_previews()
        repeatutil.cancel(GLOBAL_KEY)
        repeatutil.cancel(PLACE_KEY)
        repeatutil.cancel(RELEASE_KEY)
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
