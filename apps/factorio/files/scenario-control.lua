local handler = require("event_handler")
local pvp = require("__base__/script/pvp/pvp")

local scenario = {}
local force_for_player = {
  neBM = "neBM Factory",
  jeepersjayne = "jeepersjayne Factory"
}

local function find_team(force_name)
  for _, team in pairs(storage.pvp.config.teams) do
    if team.name == force_name then return team end
  end
end

local function remove_scenario_admin(player)
  local button = storage.pvp.elements.admin_button[player.index]
  if button and button.valid then button.destroy() end
  storage.pvp.elements.admin_button[player.index] = nil

  local frame = storage.pvp.elements.admin[player.index]
  if frame and frame.valid then frame.destroy() end
  storage.pvp.elements.admin[player.index] = nil
end

local function assign_player(player)
  if not player then return end
  local force_name = force_for_player[player.name]
  if not force_name or not storage.pvp.setup_finished then return end

  if player.force.name ~= force_name then
    set_player(player, assert(find_team(force_name)))
  end
  remove_scenario_admin(player)
end

local function enforce_independent_charting()
  game.forces["neBM Factory"].share_chart = false
  game.forces["jeepersjayne Factory"].share_chart = false
end

local function validate_ready()
  local first = assert(game.forces["neBM Factory"])
  local second = assert(game.forces["jeepersjayne Factory"])
  first.share_chart = false
  second.share_chart = false

  assert(first ~= second)
  assert(#storage.pvp.config.teams == 2)
  assert(first.get_friend(second) and second.get_friend(first))
  assert(first.get_cease_fire(second) and second.get_cease_fire(first))
  assert(not first.get_friend(game.forces.enemy))
  assert(not second.get_friend(game.forces.enemy))
  assert(not first.get_cease_fire(game.forces.enemy))
  assert(not second.get_cease_fire(game.forces.enemy))

  local surface = game.surfaces.nauvis
  local first_spawn = first.get_spawn_position(surface)
  local second_spawn = second.get_spawn_position(surface)
  local dx = first_spawn.x - second_spawn.x
  local dy = first_spawn.y - second_spawn.y
  local distance = math.sqrt(dx * dx + dy * dy)
  assert(distance >= 512 and distance <= 768)

  log(string.format(
    "Friendly factories ready: forces=2 allies=true independent-chart=true spawn-distance=%.1f",
    distance
  ))
end

scenario.on_init = function()
  assert(storage.pvp, "built-in PvP did not initialize first")
  local config = remote.call("pvp", "get_config")

  config.game_config.time_limit = 0
  config.game_config.allow_spectators = false
  config.game_config.no_rush_time = 0
  config.game_config.base_exclusion_time = 0
  config.game_config.reveal_team_positions = true
  config.game_config.reveal_map_center = true
  config.game_config.team_walls = false
  config.game_config.team_moat = false
  config.game_config.team_turrets = false
  config.game_config.team_artillery = false
  config.game_config.auto_new_round_time = 0
  config.game_config.protect_empty_teams = false
  config.game_config.enemy_building_restriction = false
  config.game_config.neutral_chests = false

  config.team_config.friendly_fire = false
  config.team_config.unlock_combat_research = false
  config.team_config.defcon_mode = false
  config.team_config.max_players = 1
  config.team_config.research_level.selected = "none"
  config.team_config.average_team_displacement = 640
  config.team_config.duplicate_starting_area_entities = true
  config.team_config.technology_price_multiplier = 1

  config.teams = {
    {name = "neBM Factory", color = "orange", team = 1, members = {}},
    {name = "jeepersjayne Factory", color = "purple", team = 1, members = {}}
  }
  config.disabled_items = {}
  config.starting_equipment.selected = "none"
  config.starting_chest.selected = "none"
  for _, condition in pairs(config.victory) do condition.active = false end

  remote.call("pvp", "set_config", config)
  storage.friendly_factories = {ready_validated = false}

  local lobby = game.create_surface("Lobby", {width = 1, height = 1})
  lobby.set_tiles({{name = "out-of-map", position = {1, 1}}})
  game.forces.player.set_surface_hidden(lobby, true)
  game.forces.neutral.set_surface_hidden(lobby, true)

  start_round()
  log("Friendly factories configured from built-in PvP; automatic round setup started")
end

scenario.events = {
  [defines.events.on_player_joined_game] = function(event)
    assign_player(game.get_player(event.player_index))
  end,
  [defines.events.on_player_promoted] = function(event)
    assign_player(game.get_player(event.player_index))
  end,
  [defines.events.on_tick] = function()
    if not storage.pvp.setup_finished then return end
    if storage.friendly_factories.ready_validated then return end

    validate_ready()
    storage.friendly_factories.ready_validated = true
    for _, player in pairs(game.connected_players) do assign_player(player) end
  end
}

scenario.on_nth_tick = {
  [60] = function()
    if not storage.pvp.setup_finished then return end
    enforce_independent_charting()
    for _, player in pairs(game.connected_players) do assign_player(player) end
  end
}

handler.add_lib(pvp)
handler.add_lib(scenario)
