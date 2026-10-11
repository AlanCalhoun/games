-- Remove dead creatures and body pieces on the ground and in workshops.
-- Only fortress-citizen corpses are left for burial.
-- Also: at most one ghost, and only for a short time.
--@enable = true
--@module = true

local repeatutil = require('repeat-util')

local GLOBAL_KEY = 'malphars_cleanup'
local REMOVE_CAP = 500
-- One haunting at a time, then put to rest (7 in-game days).
local MAX_GHOSTS = 1
local GHOST_LIFETIME_TICKS = 8400
local TICKS_PER_YEAR = 403200

enabled = enabled or false
-- unit.id -> absolute tick when first seen as a ghost this session/fort load
ghost_seen_at = ghost_seen_at or {}

function isEnabled()
    return enabled
end

local function can_remove(item)
    return item
        and item.flags
        and not item.flags.garbage_collect
        and not item.flags.in_job
        and not item.flags.construction
        and not item.flags.artifact
end

-- Keep only corpses of living fort citizens (your dwarves) for burial.
local function is_fort_citizen_corpse(item)
    local uid = -1
    pcall(function() uid = item.unit_id or -1 end)
    if not uid or uid < 0 then
        return false
    end
    local unit = df.unit.find(uid)
    if not unit then
        return false
    end
    local ok, citizen = pcall(dfhack.units.isCitizen, unit)
    return ok and citizen == true
end

local function remove_item(item)
    local ok, res = pcall(dfhack.items.remove, item)
    return ok and res ~= false
end

local function held_by_workshop(item)
    local ok, bld = pcall(function()
        if dfhack.items.getHolderBuilding then
            return dfhack.items.getHolderBuilding(item)
        end
    end)
    if not ok or not bld then
        return false
    end
    return df.building_workshopst:is_instance(bld)
        or df.building_furnacest:is_instance(bld)
end

local function collect_targets()
    local targets = {}
    local seen = {}
    local function consider(item, protect_citizens)
        if not item or seen[item.id] then
            return
        end
        if not can_remove(item) then
            return
        end
        if protect_citizens and is_fort_citizen_corpse(item) then
            return
        end
        -- Ground clutter, flagged building items, or unflagged workshop leftovers
        -- (butcher shops often leave pieces with neither on_ground nor in_building).
        if item.flags.on_ground or item.flags.in_building or held_by_workshop(item) then
            seen[item.id] = true
            targets[#targets + 1] = item
        end
    end
    local others = df.global.world.items.other
    local function add_list(name, protect_citizens)
        local list = others[name]
        if not list then
            return
        end
        for i = 0, #list - 1 do
            consider(list[i], protect_citizens)
        end
    end
    add_list('REMAINS', false)
    add_list('CORPSE', true)
    add_list('CORPSEPIECE', true)
    return targets
end

local function now_abs()
    return (df.global.cur_year or 0) * TICKS_PER_YEAR + (df.global.cur_year_tick or 0)
end

local function list_ghosts()
    local ghosts = {}
    local active = df.global.world.units.active
    if not active then
        return ghosts
    end
    for _, unit in ipairs(active) do
        local ok, is_ghost = pcall(dfhack.units.isGhost, unit)
        if ok and is_ghost and unit and unit.id then
            ghosts[#ghosts + 1] = unit
        end
    end
    return ghosts
end

local function death_abs(unit)
    if not unit or not unit.hist_figure_id or unit.hist_figure_id < 0 then
        return nil
    end
    local hf = df.historical_figure.find(unit.hist_figure_id)
    if not hf or not hf.died_year or hf.died_year < 0 then
        return nil
    end
    return hf.died_year * TICKS_PER_YEAR + (hf.died_seconds or 0)
end

local function put_ghost_to_rest(unit)
    if not unit then
        return false
    end
    pcall(function()
        if unit.flags3 then
            unit.flags3.ghostly = false
        end
    end)
    pcall(function()
        unit.ghost_info = nil
    end)
    pcall(function()
        if unit.hist_figure_id and unit.hist_figure_id >= 0 then
            local hf = df.historical_figure.find(unit.hist_figure_id)
            if hf and hf.flags then
                hf.flags.ghost = false
            end
        end
    end)
    pcall(function()
        if unit.animal then
            unit.animal.vanish_countdown = 2
        end
    end)
    if unit.id then
        ghost_seen_at[unit.id] = nil
    end
    return true
end

-- Keep the newest ghost only; put it to rest after GHOST_LIFETIME_TICKS
-- (from death time when known, else from first seen this load).
local function police_ghosts()
    local ghosts = list_ghosts()
    local now = now_abs()
    local alive = {}
    for _, unit in ipairs(ghosts) do
        local id = unit.id
        if not ghost_seen_at[id] then
            ghost_seen_at[id] = now
        end
        alive[id] = true
    end
    for id in pairs(ghost_seen_at) do
        if not alive[id] then
            ghost_seen_at[id] = nil
        end
    end

    table.sort(ghosts, function(a, b)
        local da = death_abs(a) or ghost_seen_at[a.id] or 0
        local db = death_abs(b) or ghost_seen_at[b.id] or 0
        if da ~= db then
            return da > db
        end
        return (a.id or 0) > (b.id or 0)
    end)

    for i = 1, #ghosts do
        local unit = ghosts[i]
        local born = death_abs(unit) or ghost_seen_at[unit.id] or now
        local too_old = (now - born) >= GHOST_LIFETIME_TICKS
        local over_cap = i > MAX_GHOSTS
        if too_old or over_cap then
            put_ghost_to_rest(unit)
        end
    end
end

local function sweep()
    if not enabled or not dfhack.isMapLoaded() or not dfhack.world.isFortressMode() then
        return
    end
    pcall(police_ghosts)
    local targets = collect_targets()
    local removed = 0
    for i = 1, #targets do
        if removed >= REMOVE_CAP then
            break
        end
        if remove_item(targets[i]) then
            removed = removed + 1
        end
    end
end

local function do_enable()
    enabled = true
    ghost_seen_at = {}
    sweep()
    repeatutil.scheduleEvery(GLOBAL_KEY, 307, 'ticks', sweep)
    print("Malphar's Mod: dead creatures dumped; at most one ghost (7 days). Fort-citizen corpses stay for burial.")
end

local function do_disable()
    enabled = false
    repeatutil.cancel(GLOBAL_KEY)
    print("Malphar's Mod: corpse cleanup is off.")
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        enabled = false
        ghost_seen_at = {}
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
