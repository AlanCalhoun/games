-- One shared stockpile inventory, with bins and barrels.
-- Drops and new ground items go straight to the nearest pile.
--@enable = true
--@module = true

local eventful = require('plugins.eventful')
local repeatutil = require('repeat-util')
local utils = require('utils')

local GLOBAL_KEY = 'malphars_stockpile'
local HAUL_KEY = 'malphars_stockpile.no_haul'
local PILE_NAME = 'Malphar'
local MOVE_CAP = 120
local SCAN_CAP = 2000
-- Vanilla piles are not infinite; bins/barrels are. Treat each as bottomless
-- so a handful of containers hold the whole fort without dwarf hauling.
local PER_CONTAINER = 100000
local CULL_CAP = 80
local HAUL_CANCEL_CAP = 80
-- Superdwarf tree-felling floods the map (tower-caps, surface trees). Keep a
-- small wood stock and cancel further FellTree jobs once full.
local WOOD_CAP = 100
local WOOD_TRIM_CAP = 400
local scan_cursor = 0

-- Dwarves should not haul stockpile goods; Malphar teleports instead.
local NO_HAUL_JOBS = {
    StoreItemInStockpile = true,
    StoreItemInBag = true,
    StoreItemInLocation = true,
    StoreItemInBarrel = true,
    StoreItemInBin = true,
    StoreItemInVehicle = true,
    StoreOwnedItem = true,
    DumpItem = true,
}

enabled = enabled or false
local configured_ids = {}
local announced = false
local failed_ids = {}

function isEnabled()
    return enabled
end

local BIN_NAMES = {
    'WEAPON', 'TRAPCOMP', 'ARMOR', 'SHOES', 'SHIELD', 'HELM', 'GLOVES', 'PANTS',
    'AMMO', 'SIEGEAMMO', 'GOBLET', 'FLASK', 'INSTRUMENT', 'TOY', 'TOOL', 'CHAIN', 'BAR',
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

-- Furniture / build materials must stay on the tile for ConstructBuilding.
local BUILD_KEEP = type_set({
    'DOOR', 'BED', 'CHAIR', 'TABLE', 'CAGE', 'COFFIN', 'STATUE',
    'SLAB', 'CABINET', 'BOX', 'BAG', 'WEAPONRACK', 'ARMORSTAND',
    'HATCH_COVER', 'FLOODGATE', 'GRATE', 'BARS_VERTICAL', 'BARS_FLOOR',
    'WINDOW', 'WINDOW_GLASS', 'WINDOW_GEM', 'TOOL', 'BLOCKS',
    'TRAPPARTS', 'TRAPCOMP', 'PIPE_SECTION', 'CHAIN', 'BUCKET', 'ANVIL',
    'QUERN', 'MILLSTONE', 'TRACTION_BENCH', 'INSTRUMENT', 'TOY',
})

local function placing_now()
    local ok, mode = pcall(function()
        return df.global.game.main_interface.bottom_mode_selected
    end)
    return ok and mode == df.main_bottom_mode_type.BUILDING_PLACEMENT
end

local function any_construct_jobs()
    local ok, list = pcall(function() return df.global.world.jobs.list end)
    if not ok or not list then return false end
    for _, job in utils.listpairs(list) do
        if job and job.job_type == df.job_type.ConstructBuilding then
            return true
        end
    end
    return false
end

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
    if not pile then return tiles end
    local room = pile.room
    if room and room.width and room.height and room.x and room.y then
        local w = room.width
        local h = room.height
        local extents = room.extents
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local idx = y * w + x
                if not extents or extents[idx] ~= 0 then
                    tiles[#tiles + 1] = {x = room.x + x, y = room.y + y, z = pile.z}
                end
            end
        end
    end
    if #tiles == 0 and pile.x1 then
        for y = pile.y1, pile.y2 do
            for x = pile.x1, pile.x2 do
                tiles[#tiles + 1] = {x = x, y = y, z = pile.z}
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
    -- Few containers; each holds effectively unlimited goods.
    local want_barrels = math.min(2, math.max(1, #tiles > 0 and 1 or 0))
    local want_bins = math.min(2, math.max(1, #tiles > 0 and 1 or 0))
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
    -- Cull empty surplus left from older one-bin-per-tile behavior.
    local keep_bins = math.max(want_bins, 2)
    local keep_barrels = math.max(want_barrels, 2)
    local function empty(item)
        return contained_count(item) == 0
    end
    local function safe_remove(item)
        if not item or not item.flags then return false end
        if item.flags.in_job or item.flags.garbage_collect or item.flags.artifact
            or item.flags.construction
        then
            return false
        end
        local ok, res = pcall(dfhack.items.remove, item)
        return ok and res ~= false
    end
    for i = #bins, 1, -1 do
        if #bins <= keep_bins then break end
        local item = bins[i]
        if item and empty(item) and safe_remove(item) then
            table.remove(bins, i)
        end
    end
    for i = #barrels, 1, -1 do
        if #barrels <= keep_barrels then break end
        local item = barrels[i]
        if item and empty(item) and safe_remove(item) then
            table.remove(barrels, i)
        end
    end
    for i = #barrows, 1, -1 do
        if #barrows <= want_barrows then break end
        local item = barrows[i]
        if item and empty(item) and safe_remove(item) then
            table.remove(barrows, i)
        end
    end
    return bins, barrels
end

local function item_pos(item)
    local ok, x, y, z = pcall(dfhack.items.getPosition, item)
    if ok and x then return x, y, z end
end

local function on_any_pile(item, piles)
    local x, y, z = item_pos(item)
    if not x then return false end
    for _, pile in ipairs(piles) do
        if z == pile.z and x >= pile.x1 and x <= pile.x2
            and y >= pile.y1 and y <= pile.y2
        then
            return true
        end
    end
    return false
end

local function dist2(x, y, z, x2, y2, z2)
    local dx, dy = x - x2, y - y2
    local dz = (z - z2) * 8
    return dx * dx + dy * dy + dz * dz
end

local function nearest_roomy(item, containers, limit, counts)
    local x, y, z = item_pos(item)
    local best, best_d
    local checked = 0
    -- Cap the search so large forts stay responsive.
    for _, container in ipairs(containers) do
        checked = checked + 1
        if checked > 96 then break end
        local n = counts[container.id]
        if n == nil then
            n = contained_count(container)
            counts[container.id] = n
        end
        if n < limit then
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

local function clear_haul_blocks(item)
    if not item or not item.flags then return end
    pcall(function()
        item.flags.forbid = false
        item.flags.dump = false
        item.flags.in_job = false
    end)
end

local function loose_enough(item)
    if not item or failed_ids[item.id] then return false end
    local flags = item.flags
    if not flags or not flags.on_ground then return false end
    -- Owned/forbid/dump clutter still counts as mess — clear and park it.
    if flags.in_inventory or flags.in_building or flags.in_job
        or flags.construction or flags.garbage_collect
        or flags.removed or flags.artifact
    then
        return false
    end
    -- Only pause furniture vacuum while the player is placing a building.
    -- A blanket "any ConstructBuilding job" check left hallways full of clutter.
    if placing_now() then return false end
    clear_haul_blocks(item)
    return true
end

local function store_on_pile(item, pile)
    clear_haul_blocks(item)
    local tiles = pile_tiles(pile)
    local tile = tiles[1]
    if tile then
        local pos = xyz2pos(tile.x, tile.y, tile.z)
        pcall(function() dfhack.items.moveToGround(item, pos) end)
    end
    local ok = pcall(function() dfhack.items.moveToBuilding(item, pile, 0) end)
    return ok
end

-- Build once per sweep: bins/barrels already on a pile must not be re-parked
-- every tick (that was causing lag with thousands of containers).
local function pile_tile_set(piles)
    local set = {}
    for _, pile in ipairs(piles) do
        for _, tile in ipairs(pile_tiles(pile)) do
            set[tile.x .. ',' .. tile.y .. ',' .. tile.z] = true
        end
    end
    return set
end

local function on_pile_tile(item, tileset)
    if not item or not tileset then return false end
    local ok, x, y, z = pcall(dfhack.items.getPosition, item)
    if not ok or not x then return false end
    return tileset[x .. ',' .. y .. ',' .. z] == true
end

-- Hallway leftovers from older overspawn: empty barrels/bins/wheelbarrows
-- off stockpile tiles get removed. Keep one wheelbarrow per pile.
-- Collect ids first — never remove while walking DF item vectors.
local function cull_stray_containers(piles)
    if placing_now() or any_construct_jobs() then
        return
    end
    local tileset = pile_tile_set(piles)
    local doomed = {}
    local function mark(item)
        if not item or not item.flags or #doomed >= CULL_CAP then
            return
        end
        if item.flags.in_job or item.flags.garbage_collect or item.flags.artifact
            or item.flags.construction or item.flags.in_building
        then
            return
        end
        doomed[#doomed + 1] = item.id
    end
    for _, name in ipairs({'BARREL', 'BIN'}) do
        local list = df.global.world.items.other[name]
        if list then
            local n = #list
            for i = 0, n - 1 do
                if #doomed >= CULL_CAP then
                    break
                end
                local item = list[i]
                if item and item.flags and item.flags.on_ground
                    and contained_count(item) == 0
                    and not on_pile_tile(item, tileset)
                then
                    mark(item)
                end
            end
        end
    end
    local tools = df.global.world.items.other.TOOL
    if tools then
        local on_pile_ids, off_pile_ids = {}, {}
        local n = #tools
        for i = 0, n - 1 do
            local item = tools[i]
            if item and is_wheelbarrow(item) and item.flags and item.flags.on_ground
                and not item.flags.garbage_collect
            then
                if on_pile_tile(item, tileset) then
                    on_pile_ids[#on_pile_ids + 1] = item.id
                else
                    off_pile_ids[#off_pile_ids + 1] = item.id
                end
            end
        end
        for _, id in ipairs(off_pile_ids) do
            if #doomed >= CULL_CAP then
                break
            end
            local item = df.item.find(id)
            mark(item)
        end
        local keep_wb = math.max(1, #piles)
        for i = keep_wb + 1, #on_pile_ids do
            if #doomed >= CULL_CAP then
                break
            end
            local item = df.item.find(on_pile_ids[i])
            mark(item)
        end
    end
    for _, id in ipairs(doomed) do
        local item = df.item.find(id)
        if item and item.flags and not item.flags.garbage_collect
            and not item.flags.in_job
        then
            local ok, res = pcall(dfhack.items.remove, item)
            if not (ok and res ~= false) then
                -- ignore failed removes; next sweep retries
            end
        end
    end
end

local function move_into(item, container)
    clear_haul_blocks(item)
    local ok, res = pcall(function()
        return dfhack.items.moveToContainer(item, container)
    end)
    if not ok or res == false then
        return false
    end
    return item.flags and not item.flags.on_ground
end

local function parked_ok(item, piles, on_pile)
    if not item or not item.flags then return false end
    if not item.flags.on_ground then return true end
    if on_any_pile(item, piles) then return true end
    if on_pile_tile(item, on_pile) then return true end
    return false
end

local function stash_item(item, piles, bins, barrels, counts, on_pile)
    local kind = item:getType()
    local container
    if kind == df.item_type.BIN or kind == df.item_type.BARREL
        or is_wheelbarrow(item)
    then
        if on_any_pile(item, piles) or on_pile_tile(item, on_pile) then
            return true, nil
        end
        local pile = nearest_pile(item, piles)
        if not pile then return false, nil end
        store_on_pile(item, pile)
        return parked_ok(item, piles, on_pile), nil
    end
    if BIN_TYPES[kind] then
        container = nearest_roomy(item, bins, PER_CONTAINER, counts)
        if container and move_into(item, container) then
            return true, container
        end
        local pile = nearest_pile(item, piles)
        if not pile then return false, nil end
        store_on_pile(item, pile)
        return parked_ok(item, piles, on_pile), nil
    end
    if BARREL_TYPES[kind] then
        container = nearest_roomy(item, barrels, PER_CONTAINER, counts)
        if container and move_into(item, container) then
            return true, container
        end
        local pile = nearest_pile(item, piles)
        if not pile then return false, nil end
        store_on_pile(item, pile)
        return parked_ok(item, piles, on_pile), nil
    end
    if kind == df.item_type.BOULDER or kind == df.item_type.ROUGH then
        return false, nil
    end
    local pile = nearest_pile(item, piles)
    if not pile then return false, nil end
    store_on_pile(item, pile)
    return parked_ok(item, piles, on_pile), nil
end

local function load_goods(piles, bins, barrels)
    local list = df.global.world.items.other.IN_PLAY
    if not list then return end
    local counts = {}
    local moved = 0
    local on_pile = pile_tile_set(piles)
    local n = #list
    if n < 1 then return end
    if scan_cursor < 0 or scan_cursor >= n then scan_cursor = 0 end
    local scanned = 0
    local i = scan_cursor
    while scanned < SCAN_CAP and moved < MOVE_CAP do
        local item = list[i]
        scanned = scanned + 1
        i = i + 1
        if i >= n then i = 0 end
        if scanned > 0 and i == scan_cursor and scanned > 1 then break end
        if loose_enough(item) and not on_any_pile(item, piles) then
            local ok, container = stash_item(item, piles, bins, barrels, counts, on_pile)
            if ok then
                moved = moved + 1
                if container then
                    counts[container.id] = (counts[container.id] or 0) + 1
                end
            else
                failed_ids[item.id] = true
            end
        end
    end
    scan_cursor = i
end

-- Direct typed pass so seeds/plants/clothes are not starved by IN_PLAY scan order.
local TYPED_VACUUM = {
    'SEEDS', 'PLANT', 'PLANT_GROWTH', 'THREAD', 'CLOTH', 'ARMOR', 'SHOES',
    'HELM', 'GLOVES', 'PANTS', 'WEAPON', 'AMMO', 'SIEGEAMMO', 'SHIELD', 'FLASK', 'GOBLET',
    'BACKPACK', 'QUIVER', 'BOX', 'BAG', 'TOOL', 'BLOCKS', 'PIPE_SECTION',
    'TRAPPARTS', 'TRAPCOMP', 'CHAIR', 'TABLE', 'DOOR', 'BED', 'CABINET',
    'WEAPONRACK', 'ARMORSTAND', 'STATUE', 'WINDOW',
}

local function vacuum_typed(piles, bins, barrels)
    local counts = {}
    local on_pile = pile_tile_set(piles)
    local moved = 0
    local others = df.global.world.items.other
    for _, name in ipairs(TYPED_VACUUM) do
        if moved >= MOVE_CAP then break end
        local list = others[name]
        if list then
            local ids = {}
            local n = #list
            for i = 0, n - 1 do
                local item = list[i]
                if item and loose_enough(item) and not on_any_pile(item, piles) then
                    ids[#ids + 1] = item.id
                    if #ids >= MOVE_CAP then break end
                end
            end
            for _, id in ipairs(ids) do
                if moved >= MOVE_CAP then break end
                local item = df.item.find(id)
                if item and loose_enough(item) and not on_any_pile(item, piles) then
                    local ok, container = stash_item(item, piles, bins, barrels, counts, on_pile)
                    if ok then
                        moved = moved + 1
                        if container then
                            counts[container.id] = (counts[container.id] or 0) + 1
                        end
                    end
                end
            end
        end
    end
end

-- Pull leftover goods out of workshops/furnaces into bins/barrels (no dwarf haul).
local function vacuum_workshops(piles, bins, barrels)
    if placing_now() or any_construct_jobs() then
        return
    end
    local counts = {}
    local on_pile = pile_tile_set(piles)
    local moved = 0
    for _, bld in ipairs(df.global.world.buildings.all) do
        if moved >= MOVE_CAP then break end
        if bld and (df.building_workshopst:is_instance(bld)
            or df.building_furnacest:is_instance(bld)) then
            local ok_ci, ci = pcall(function() return bld.contained_items end)
            if ok_ci and ci then
                local ids = {}
                for _, contained in ipairs(ci) do
                    local item = contained.item
                    if item and item.flags and not item.flags.garbage_collect
                        and not item.flags.in_job and not item.flags.artifact
                        and not item.flags.construction
                        and contained.use_mode ~= 2
                    then
                        local kind = item:getType()
                        if kind ~= df.item_type.CORPSE
                            and kind ~= df.item_type.CORPSEPIECE
                            and kind ~= df.item_type.REMAINS
                            and (BIN_TYPES[kind] or BARREL_TYPES[kind])
                        then
                            ids[#ids + 1] = item.id
                            if #ids >= MOVE_CAP then break end
                        end
                    end
                end
                for _, id in ipairs(ids) do
                    if moved >= MOVE_CAP then break end
                    local item = df.item.find(id)
                    if item and item.flags and not item.flags.in_job then
                        -- Detach from workshop so stash can park it in a pile/bin.
                        item.flags.in_building = false
                        item.flags.on_ground = true
                        item.flags.in_inventory = false
                        local ok, container = stash_item(
                            item, piles, bins, barrels, counts, on_pile)
                        if ok then
                            moved = moved + 1
                            if container then
                                counts[container.id] = (counts[container.id] or 0) + 1
                            end
                        elseif BARREL_TYPES[item:getType()] then
                            -- Still pull drinks/food out even if binning fails.
                            local pile = nearest_pile(item, piles)
                            if pile then
                                store_on_pile(item, pile)
                                moved = moved + 1
                            end
                        end
                    end
                end
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

local function resolve_item(item_or_id)
    if not item_or_id then return nil end
    if type(item_or_id) == 'number' then
        return df.item.find(item_or_id)
    end
    return item_or_id
end

local function quick_containers(piles)
    local bins, barrels = {}, {}
    for _, pile in ipairs(piles) do
        local pile_bins, pile_barrels = contents_of(pile)
        if pile_bins then
            for i = 1, math.min(12, #pile_bins) do
                bins[#bins + 1] = pile_bins[i]
            end
        end
        if pile_barrels then
            for i = 1, math.min(8, #pile_barrels) do
                barrels[#barrels + 1] = pile_barrels[i]
            end
        end
    end
    return bins, barrels
end

local function wood_units()
    local list = df.global.world.items.other.WOOD
    if not list then return 0 end
    local n = 0
    for i = 0, #list - 1 do
        local item = list[i]
        if item and item.flags and not item.flags.garbage_collect
            and not item.flags.artifact
        then
            n = n + (item.stack_size or 1)
        end
    end
    return n
end

local function cancel_fell_trees()
    local list = df.global.world.jobs.list
    if not list then return end
    for _, job in utils.listpairs(list) do
        if job and job.job_type == df.job_type.FellTree then
            pcall(function() dfhack.job.removeJob(job) end)
        end
    end
end

local function discard_wood(item)
    if not item or not item.flags or item.flags.garbage_collect then
        return false
    end
    if item.flags.artifact or item.flags.construction then
        return false
    end
    local ok_unit, unit = pcall(dfhack.items.getHolderUnit, item)
    if ok_unit and unit then
        return false
    end
    if item.flags.owned then
        return false
    end
    if item.flags.in_job then
        pcall(clear_haul_blocks, item)
    end
    -- FellTree often leaves "ghost" logs with no flags; remove() fails until grounded.
    if not item.flags.on_ground and not item.flags.in_inventory then
        local citizen = creator_unit()
        local pos = citizen and citizen.pos
        if pos then
            pcall(function() dfhack.items.moveToGround(item, pos) end)
            item.flags.on_ground = true
        end
    end
    item.flags.in_building = false
    local ok, res = pcall(dfhack.items.remove, item)
    if not (ok and res ~= false) then
        item.flags.garbage_collect = true
    end
    return item.flags.garbage_collect == true or (ok and res ~= false)
end

-- Keep ~100 logs total; tower-cap / surface felling otherwise never stops.
local function trim_wood_excess()
    local have = wood_units()
    if have <= WOOD_CAP then
        return
    end
    cancel_fell_trees()
    local list = df.global.world.items.other.WOOD
    if not list then return end
    local ids = {}
    for i = 0, #list - 1 do
        local item = list[i]
        if item and item.flags and not item.flags.garbage_collect
            and not item.flags.artifact and not item.flags.construction
        then
            local unit = dfhack.items.getHolderUnit(item)
            if not unit and not item.flags.owned then
                ids[#ids + 1] = item.id
            end
        end
    end
    local excess = have - WOOD_CAP
    local removed = 0
    for i = #ids, 1, -1 do
        if excess <= 0 or removed >= WOOD_TRIM_CAP then break end
        local item = df.item.find(ids[i])
        if item and item.flags and not item.flags.garbage_collect then
            local size = item.stack_size or 1
            if discard_wood(item) then
                excess = excess - size
                removed = removed + 1
            end
        end
    end
end

-- Instant catch: dwarf drops and freshly created ground items never linger.
local function catch_loose_item(item_or_id)
    if not enabled or not dfhack.isMapLoaded() or not dfhack.world.isFortressMode() then
        return
    end
    if placing_now() then return end
    local item = resolve_item(item_or_id)
    if not item or not item.flags then return end
    if item.flags.garbage_collect or item.flags.removed or item.flags.artifact then
        return
    end
    if item.flags.in_job or item.flags.construction or item.flags.in_building
        or item.flags.in_inventory
    then
        return
    end
    if not item.flags.on_ground then return end
    local kind = item:getType()
    if kind == df.item_type.BOULDER or kind == df.item_type.ROUGH then
        return
    end
    -- New logs from tree cutting: keep a small stock, delete the rest.
    if kind == df.item_type.WOOD then
        if wood_units() > WOOD_CAP then
            cancel_fell_trees()
            discard_wood(item)
            return
        end
    end
    if placing_now() and BUILD_KEEP[kind] and not is_wheelbarrow(item) then
        return
    end
    local piles = all_piles()
    if #piles == 0 then return end
    if on_any_pile(item, piles) then return end
    failed_ids[item.id] = nil
    local bins, barrels = quick_containers(piles)
    local on_pile = pile_tile_set(piles)
    clear_haul_blocks(item)
    stash_item(item, piles, bins, barrels, {}, on_pile)
end

local function defer_catch(item_id)
    if not item_id then return end
    pcall(function()
        dfhack.timeout(1, 'ticks', function()
            catch_loose_item(item_id)
        end)
    end)
end

local function on_inventory_change(unit_id, item_id, old_equip, new_equip)
    if not enabled then return end
    -- Dropped: had equipment record, now none.
    if new_equip ~= nil then return end
    if old_equip == nil then return end
    local item = resolve_item(item_id)
    if not item then return end
    catch_loose_item(item)
    if item.flags and item.flags.on_ground then
        defer_catch(item.id)
    end
end

local function on_item_created(item_id)
    if not enabled then return end
    local item = resolve_item(item_id)
    if item and item:getType() == df.item_type.WOOD then
        -- Logs often spawn in_job from FellTree; trim after the job releases them.
        defer_catch(item.id)
        if wood_units() > WOOD_CAP then
            cancel_fell_trees()
            pcall(function()
                dfhack.timeout(2, 'ticks', trim_wood_excess)
            end)
        end
    end
    catch_loose_item(item_id)
    local id = type(item_id) == 'number' and item_id or (item_id and item_id.id)
    defer_catch(id)
end

local function bind_drop_events()
    -- Frequency 1 was a major hitch with ~80k items. Check every 10 ticks.
    eventful.enableEvent(eventful.eventType.INVENTORY_CHANGE, 10)
    eventful.enableEvent(eventful.eventType.ITEM_CREATED, 10)
    eventful.onInventoryChange[GLOBAL_KEY] = on_inventory_change
    eventful.onItemCreated[GLOBAL_KEY] = on_item_created
end

local function unbind_drop_events()
    eventful.onInventoryChange[GLOBAL_KEY] = nil
    eventful.onItemCreated[GLOBAL_KEY] = nil
end

local function release_carried(item)
    if not item or not item.flags then return end
    local ok, unit = pcall(dfhack.items.getHolderUnit, item)
    if ok and unit and unit.pos then
        pcall(function() dfhack.items.moveToGround(item, unit.pos) end)
        item.flags.in_inventory = false
        item.flags.on_ground = true
    end
    clear_haul_blocks(item)
end

-- Cancel stockpile/dump hauling; Malphar teleports the goods instead.
local function cancel_dwarf_hauling()
    if not enabled or not dfhack.isMapLoaded() or not dfhack.world.isFortressMode() then
        return
    end
    local list = df.global.world.jobs.list
    if not list then return end
    local cancelled = 0
    local item_ids = {}
    for _, job in utils.listpairs(list) do
        if cancelled >= HAUL_CANCEL_CAP then break end
        if job then
            local jname = df.job_type[job.job_type]
            if jname and NO_HAUL_JOBS[jname] then
                if job.items then
                    for _, ji in ipairs(job.items) do
                        if ji and ji.item and ji.item.id then
                            item_ids[#item_ids + 1] = ji.item.id
                        end
                    end
                end
                pcall(function() dfhack.job.removeJob(job) end)
                cancelled = cancelled + 1
            end
        end
    end
    if #item_ids == 0 then return end
    local piles = all_piles()
    if #piles == 0 then return end
    local bins, barrels = quick_containers(piles)
    local on_pile = pile_tile_set(piles)
    local counts = {}
    for _, id in ipairs(item_ids) do
        local item = df.item.find(id)
        if item and item.flags and not item.flags.garbage_collect
            and not item.flags.artifact and not item.flags.construction
        then
            release_carried(item)
            local kind = item:getType()
            if kind ~= df.item_type.BOULDER and kind ~= df.item_type.ROUGH then
                if not (placing_now() and BUILD_KEEP[kind]) then
                    stash_item(item, piles, bins, barrels, counts, on_pile)
                end
            end
        end
    end
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
    failed_ids = {}
    local bins, barrels = {}, {}
    for _, pile in ipairs(piles) do
        if not configured_ids[pile.id] then configure(pile, pile.name == PILE_NAME) end
        local pile_bins, pile_barrels = ensure_containers(pile)
        if pile_bins then
            for i = 1, math.min(48, #pile_bins) do
                bins[#bins + 1] = pile_bins[i]
            end
        end
        if pile_barrels then
            for i = 1, math.min(24, #pile_barrels) do
                barrels[#barrels + 1] = pile_barrels[i]
            end
        end
    end
    link_network(piles)
    cancel_dwarf_hauling()
    -- Unforbid hallway drops so vacuum can take them.
    do
        local list = df.global.world.items.other.IN_PLAY
        if list then
            local n = 0
            for i = 0, #list - 1 do
                if n >= 200 then break end
                local item = list[i]
                if item and item.flags and item.flags.on_ground
                    and (item.flags.forbid or item.flags.dump)
                    and not item.flags.garbage_collect and not item.flags.in_job
                then
                    clear_haul_blocks(item)
                    n = n + 1
                end
            end
        end
    end
    cull_stray_containers(piles)
    trim_wood_excess()
    vacuum_workshops(piles, bins, barrels)
    vacuum_typed(piles, bins, barrels)
    load_goods(piles, bins, barrels)
    if not announced then
        announced = true
        print('Malphar\'s Mod: no dwarf hauling — goods teleport into infinite bins/barrels.')
    end
end

local function do_enable()
    enabled = true
    configured_ids = {}
    announced = false
    failed_ids = {}
    bind_drop_events()
    sweep()
    -- Less frequent full sweeps; drop events handle most clutter.
    repeatutil.scheduleEvery(GLOBAL_KEY, 503, 'ticks', sweep)
    -- Kill store/dump jobs often so dwarves never settle into hauling.
    repeatutil.scheduleEvery(HAUL_KEY, 37, 'ticks', cancel_dwarf_hauling)
end

local function do_disable()
    enabled = false
    unbind_drop_events()
    repeatutil.cancel(GLOBAL_KEY)
    repeatutil.cancel(HAUL_KEY)
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        enabled = false
        configured_ids = {}
        announced = false
        failed_ids = {}
        unbind_drop_events()
        repeatutil.cancel(GLOBAL_KEY)
        repeatutil.cancel(HAUL_KEY)
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
