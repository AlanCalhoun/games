-- One shared stockpile inventory, with bins and barrels.
-- Dropped items go to the nearest pile. Corpses and refuse stay out.
--@enable = true
--@module = true

local repeatutil = require('repeat-util')
local utils = require('utils')

local GLOBAL_KEY = 'malphars_stockpile'
local PILE_NAME = 'Malphar'
local MOVE_CAP = 40
local BOULDER_CAP = 300
local PER_CONTAINER = 100
local BOULDER_PER_BIN = 5000

enabled = enabled or false
local configured_ids = {}
local announced = false
local failed_ids = {}

function isEnabled()
    return enabled
end

local BIN_NAMES = {
    'WEAPON', 'TRAPCOMP', 'ARMOR', 'SHOES', 'SHIELD', 'HELM', 'GLOVES', 'PANTS',
    'AMMO', 'GOBLET', 'FLASK', 'INSTRUMENT', 'TOY', 'TOOL', 'CHAIN', 'BAR',
    'BLOCKS', 'SMALLGEM', 'ROUGH', 'CLOTH', 'SHEET', 'THREAD', 'SKIN_TANNED',
    'FIGURINE', 'AMULET', 'SCEPTER', 'CROWN', 'RING', 'EARRING', 'BRACELET',
    'BACKPACK', 'QUIVER', 'BOX', 'COIN', 'SPLINT', 'CRUTCH',
}
local BARREL_NAMES = {
    'MEAT', 'FISH', 'FISH_RAW', 'CHEESE', 'PLANT', 'PLANT_GROWTH', 'SEEDS',
    'FOOD', 'DRINK', 'POWDER_MISC', 'LIQUID_MISC', 'GLOB', 'EGG', 'LEAVES',
}

local function type_set(names)
    local set = {}
    for _, name in ipairs(names) do
        local id = df.item_type[name]
        if id then set[id] = true end
    end
    return set
end

local BIN_TYPES = type_set(BIN_NAMES)
local BARREL_TYPES = type_set(BARREL_NAMES)

local function first_created(created)
    if not created then return nil end
    if type(created) == 'number' then return df.item.find(created) end
    local type_name = created._type and tostring(created._type) or ''
    if type_name:find('item') and not type_name:find('vector') then return created end
    local ok, item = pcall(function() return created[0] end)
    if ok and item and type(item) ~= 'number' and item._type then return item end
    if ok and type(item) == 'number' then return df.item.find(item) end
    if type(created) == 'table' then
        local from_table = created[1] or created[0]
        if type(from_table) == 'number' then return df.item.find(from_table) end
        return from_table
    end
end

local function creator_unit()
    for _, unit in pairs(dfhack.units.getCitizens()) do
        if unit then return unit end
    end
end

local function adamantine()
    local ok, info = pcall(dfhack.matinfo.find, 'INORGANIC:ADAMANTINE')
    if ok and info then return info end
    return dfhack.matinfo.find('PLANT:PINE:WOOD')
end

local function find_pile()
    local piles = df.global.world.buildings.other.STOCKPILE
    if not piles then return nil end
    for _, pile in ipairs(piles) do
        if pile.name == PILE_NAME then return pile end
    end
end

local function tile_open(x, y, z)
    if not dfhack.maps.isValidTilePos(x, y, z) then return false end
    local tt = dfhack.maps.getTileType(x, y, z)
    if not tt or tt < 0 then return false end
    local shape = df.tiletype.attrs[tt].shape
    if shape ~= df.tiletype_shape.FLOOR then return false end
    local occupied = true
    local ok, bld = pcall(dfhack.buildings.findAtTile, x, y, z)
    if ok then occupied = bld ~= nil end
    return not occupied
end

local function find_rect(z, anchor_x, anchor_y, side)
    local maxx, maxy = dfhack.maps.getTileSize()
    for radius = side, 40 do
        local x0 = math.max(1, anchor_x - radius)
        local y0 = math.max(1, anchor_y - radius)
        local x1 = math.min(maxx - side - 1, anchor_x + radius)
        local y1 = math.min(maxy - side - 1, anchor_y + radius)
        for y = y0, y1 do
            for x = x0, x1 do
                if math.abs(x - anchor_x) + math.abs(y - anchor_y) >= side then
                    local clear = true
                    for dy = 0, side - 1 do
                        for dx = 0, side - 1 do
                            if not tile_open(x + dx, y + dy, z) then
                                clear = false
                                break
                            end
                        end
                        if not clear then break end
                    end
                    if clear then return x, y end
                end
            end
        end
    end
end

local function make_extents(w, h)
    local area = w * h
    local extents = df.reinterpret_cast(df.building_extents_type, df.new('uint8_t', area))
    for i = 0, area - 1 do
        extents[i] = 1
    end
    return extents
end

local function create_pile()
    local unit = creator_unit()
    if not unit then return nil end
    local pos = unit.pos
    local side
    local x, y
    for _, try_side in ipairs({7, 5, 3}) do
        x, y = find_rect(pos.z, pos.x, pos.y, try_side)
        if x then
            side = try_side
            break
        end
    end
    if not x then return nil end
    local extents = make_extents(side, side)
    local bld, err = dfhack.buildings.constructBuilding{
        type = df.building_type.Stockpile,
        abstract = true,
        pos = xyz2pos(x, y, pos.z),
        width = side,
        height = side,
        fields = {room = {x = x, y = y, width = side, height = side, extents = extents}},
    }
    if not bld then
        dfhack.printerr('Malphar\'s Mod: could not place the stockpile. ' .. tostring(err))
        return nil
    end
    return bld
end

local function configure(pile, rename)
    local ok, stockpiles = pcall(require, 'plugins.stockpiles')
    if not ok or not stockpiles or not stockpiles.import_settings then return end
    local opts = {id = pile.id, mode = 'set'}
    pcall(function() stockpiles.import_settings('library/all', opts) end)
    opts.mode = 'disable'
    pcall(function() stockpiles.import_settings('library/cat_stone', opts) end)
    pcall(function() stockpiles.import_settings('library/cat_corpses', opts) end)
    pcall(function() stockpiles.import_settings('library/cat_refuse', opts) end)
    local tiles = 1
    if pile.room and pile.room.width and pile.room.height then
        tiles = pile.room.width * pile.room.height
    end
    if pile.storage then
        pile.storage.max_bins = tiles
        pile.storage.max_barrels = tiles
        pile.storage.max_wheelbarrows = 1
    end
    pcall(function()
        if pile.stockpile_flag then
            pile.stockpile_flag.use_links_only = false
        end
    end)
    if rename then pile.name = PILE_NAME end
    configured_ids[pile.id] = true
end

local function pile_tiles(pile)
    local tiles = {}
    local room = pile.room
    if not room then return tiles end
    local w = room.width or 1
    local h = room.height or 1
    local extents = room.extents
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local idx = y * w + x
            if not extents or extents[idx] ~= 0 then
                tiles[#tiles + 1] = {x = room.x + x, y = room.y + y, z = pile.z}
            end
        end
    end
    return tiles
end

local function park(item, pile, tile)
    if not item or not tile then return false end
    local pos = xyz2pos(tile.x, tile.y, tile.z)
    local grounded = pcall(function() dfhack.items.moveToGround(item, pos) end)
    pcall(function() dfhack.items.moveToBuilding(item, pile, 0) end)
    pcall(function() item.quality = 5 end)
    return grounded
end

local function spawn_container(unit, item_type, mat, pile, tile, subtype)
    subtype = subtype or -1
    local created
    local ok = pcall(function()
        created = dfhack.items.createItem(unit, item_type, subtype, mat.type, mat.index, false)
    end)
    if not ok or not created then
        pcall(function()
            created = dfhack.items.createItem(item_type, subtype, mat.type, mat.index, unit)
        end)
    end
    local item = first_created(created)
    if not item then return nil end
    if not park(item, pile, tile) then return nil end
    return item
end

local function is_wheelbarrow(item)
    local ok, yes = pcall(function() return item:isWheelbarrow() end)
    return ok and yes == true
end

local function wheelbarrow_subtype()
    local ok, sub = pcall(dfhack.items.findSubtype, 'TOOL:ITEM_TOOL_WHEELBARROW')
    if ok and type(sub) == 'number' and sub >= 0 then return sub end
end

local function add_container(bins, barrels, barrows, seen, item)
    if not item or seen[item.id] then return end
    seen[item.id] = true
    local kind = item:getType()
    if kind == df.item_type.BIN then
        bins[#bins + 1] = item
    elseif kind == df.item_type.BARREL then
        barrels[#barrels + 1] = item
    elseif is_wheelbarrow(item) then
        barrows[#barrows + 1] = item
    end
end

local function on_tiles(item, tiles)
    local ok, x, y, z = pcall(dfhack.items.getPosition, item)
    if not ok or not x then return false end
    for _, tile in ipairs(tiles) do
        if tile.x == x and tile.y == y and tile.z == z then return true end
    end
    return false
end

local function contents_of(pile, tiles)
    local bins, barrels, barrows = {}, {}, {}
    local seen = {}
    local ok, stored = pcall(dfhack.buildings.getStockpileContents, pile)
    if ok and stored then
        for _, item in ipairs(stored) do
            add_container(bins, barrels, barrows, seen, item)
        end
    end
    local others = df.global.world.items.other
    local function scan(list)
        if not list then return end
        for i = 0, #list - 1 do
            local item = list[i]
            if item and on_tiles(item, tiles) then
                add_container(bins, barrels, barrows, seen, item)
            end
        end
    end
    if others then
        local function field(name)
            local found, list = pcall(function() return others[name] end)
            if found then return list end
        end
        scan(field('BIN'))
        scan(field('BARREL'))
        scan(field('TOOL'))
    end
    return bins, barrels, barrows
end

local function contained_count(container)
    local ok, inner = pcall(dfhack.items.getContainedItems, container)
    if not ok or not inner then return 0 end
    return #inner
end

local function ensure_containers(pile)
    local unit = creator_unit()
    local mat = adamantine()
    if not unit or not mat then return end
    local tiles = pile_tiles(pile)
    local bins, barrels, barrows = contents_of(pile, tiles)
    local want_barrows = 0
    if #tiles >= 4 or pile.name == PILE_NAME then
        want_barrows = math.min(1, #tiles)
    end
    local want_barrels = math.min(8, math.max(1, math.floor(#tiles / 4)))
    local want_bins = math.max(1, #tiles - want_barrels - want_barrows)
    local function next_tile(used)
        used = used + 1
        return tiles[used], used
    end
    local used = #bins + #barrels + #barrows
    while #barrows < want_barrows do
        local tile
        tile, used = next_tile(used)
        local sub = wheelbarrow_subtype()
        local item
        if sub then
            item = spawn_container(unit, df.item_type.TOOL, mat, pile, tile, sub)
        end
        if not item then break end
        barrows[#barrows + 1] = item
    end
    while #barrels < want_barrels do
        local tile
        tile, used = next_tile(used)
        local item = spawn_container(unit, df.item_type.BARREL, mat, pile, tile)
        if not item then break end
        barrels[#barrels + 1] = item
    end
    while #bins < want_bins do
        local tile
        tile, used = next_tile(used)
        local item = spawn_container(unit, df.item_type.BIN, mat, pile, tile)
        if not item then break end
        bins[#bins + 1] = item
    end
    return bins, barrels
end

local function item_pos(item)
    local ok, x, y, z = pcall(dfhack.items.getPosition, item)
    if ok and x then return x, y, z end
end

local function dist2(x, y, z, x2, y2, z2)
    local dx, dy = x - x2, y - y2
    local dz = (z - z2) * 8
    return dx * dx + dy * dy + dz * dz
end

local function nearest_roomy(item, containers, limit)
    local x, y, z = item_pos(item)
    local best, best_d
    for _, container in ipairs(containers) do
        if contained_count(container) < limit then
            local cx, cy, cz = item_pos(container)
            local d = 0
            if x and cx then d = dist2(x, y, z, cx, cy, cz) end
            if not best_d or d < best_d then
                best, best_d = container, d
            end
        end
    end
    return best
end

local function nearest_pile(item, piles)
    local x, y, z = item_pos(item)
    local best, best_d
    for _, pile in ipairs(piles) do
        local px = pile.centerx or (pile.room and pile.room.x)
        local py = pile.centery or (pile.room and pile.room.y)
        local pz = pile.z
        if px and py and pz then
            local d = 0
            if x then d = dist2(x, y, z, px, py, pz) end
            if not best_d or d < best_d then
                best, best_d = pile, d
            end
        end
    end
    return best or piles[1]
end

local function loose_enough(item)
    if not item or failed_ids[item.id] then return false end
    local flags = item.flags
    if not flags or not flags.on_ground then return false end
    if flags.in_inventory or flags.in_building or flags.in_job
        or flags.construction or flags.garbage_collect or flags.owned
        or flags.removed or flags.forbid or flags.dump
    then
        return false
    end
    local kind = item:getType()
    if kind == df.item_type.BIN or kind == df.item_type.BARREL or is_wheelbarrow(item) then
        return false
    end
    return true
end

local function store_on_pile(item, pile)
    local tiles = pile_tiles(pile)
    local tile = tiles[1]
    if tile then
        local pos = xyz2pos(tile.x, tile.y, tile.z)
        pcall(function() dfhack.items.moveToGround(item, pos) end)
    end
    local ok = pcall(function() dfhack.items.moveToBuilding(item, pile, 0) end)
    return ok
end

local function load_goods(piles, bins, barrels)
    local list = df.global.world.items.other.IN_PLAY
    if not list then return end
    local moved = 0
    for i = 0, #list - 1 do
        if moved >= MOVE_CAP then break end
        local item = list[i]
        if loose_enough(item) then
            local kind = item:getType()
            local attempted = false
            local ok = false
            if BIN_TYPES[kind] then
                local container = nearest_roomy(item, bins, PER_CONTAINER)
                if container then
                    attempted = true
                    ok = pcall(function() dfhack.items.moveToContainer(item, container) end)
                end
            elseif BARREL_TYPES[kind] then
                local container = nearest_roomy(item, barrels, PER_CONTAINER)
                if container then
                    attempted = true
                    ok = pcall(function() dfhack.items.moveToContainer(item, container) end)
                end
            elseif kind ~= df.item_type.BOULDER then
                local pile = nearest_pile(item, piles)
                if pile then
                    attempted = true
                    ok = store_on_pile(item, pile)
                end
            end
            if ok and item.flags and not item.flags.on_ground then
                moved = moved + 1
            elseif attempted then
                failed_ids[item.id] = true
            end
        end
    end
end

local function load_boulders(bins)
    local list = df.global.world.items.other.BOULDER
    if not list or #bins == 0 then return end
    local moved = 0
    for i = 0, #list - 1 do
        if moved >= BOULDER_CAP then break end
        local item = list[i]
        if loose_enough(item) then
            local container = nearest_roomy(item, bins, BOULDER_PER_BIN)
            if not container then break end
            local ok = pcall(function() dfhack.items.moveToContainer(item, container) end)
            if ok then
                moved = moved + 1
            else
                failed_ids[item.id] = true
            end
        end
    end
end

local function already_linked(vec, id)
    if not vec then return false end
    for _, bld in ipairs(vec) do
        if bld and bld.id == id then return true end
    end
    return false
end

local function link_network(piles)
    local others = df.global.world.buildings.other
    if not others then return end
    local seen = {}
    local function link_shop(shop)
        if not shop or seen[shop.id] or not shop.profile or not shop.profile.links then return end
        seen[shop.id] = true
        for _, pile in ipairs(piles) do
            if pile.links and not already_linked(shop.profile.links.take_from_pile, pile.id) then
                utils.insert_sorted(shop.profile.links.take_from_pile, pile, 'id')
            end
            if pile.links and not already_linked(pile.links.give_to_workshop, shop.id) then
                utils.insert_sorted(pile.links.give_to_workshop, shop, 'id')
            end
        end
    end
    local function walk(vec)
        if not vec then return end
        for _, shop in ipairs(vec) do link_shop(shop) end
    end
    walk(others.WORKSHOP_ANY)
    walk(others.WORKSHOP_CUSTOM)
end

local function all_piles()
    local piles = {}
    local list = df.global.world.buildings.other.STOCKPILE
    if not list then return piles end
    for _, pile in ipairs(list) do
        piles[#piles + 1] = pile
    end
    return piles
end

local function sweep()
    if not enabled or not dfhack.isMapLoaded() or not dfhack.world.isFortressMode() then
        return
    end
    local piles = all_piles()
    if #piles == 0 then
        local pile = create_pile()
        if pile then
            configure(pile, true)
            piles[1] = pile
        end
    end
    if #piles == 0 then
        if not announced then
            announced = true
            print('Malphar\'s Mod: no open floor for the stockpile yet.')
        end
        return
    end
    local bins, barrels = {}, {}
    for _, pile in ipairs(piles) do
        if not configured_ids[pile.id] then configure(pile, pile.name == PILE_NAME) end
        local pile_bins, pile_barrels = ensure_containers(pile)
        if pile_bins then
            for _, bin in ipairs(pile_bins) do bins[#bins + 1] = bin end
        end
        if pile_barrels then
            for _, barrel in ipairs(pile_barrels) do barrels[#barrels + 1] = barrel end
        end
    end
    link_network(piles)
    load_goods(piles, bins, barrels)
    load_boulders(bins)
    if not announced then
        announced = true
        print('Malphar\'s Mod: stockpiles share one inventory. Dropped items go to the nearest pile.')
    end
end

local function do_enable()
    enabled = true
    configured_ids = {}
    announced = false
    failed_ids = {}
    sweep()
    repeatutil.scheduleEvery(GLOBAL_KEY, 1000, 'ticks', sweep)
end

local function do_disable()
    enabled = false
    repeatutil.cancel(GLOBAL_KEY)
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        enabled = false
        configured_ids = {}
        announced = false
        failed_ids = {}
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
