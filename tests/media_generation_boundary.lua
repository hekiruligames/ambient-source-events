-- Deterministic real-GPU regressions for Media Source generation boundaries.
-- Stale startup must stay transparent through 69 -> 23 ms -> ENDED, and an
-- active generation must become transparent as soon as its playhead rewinds.
local obs = obslua
obs.obs_frontend_add_event_callback = function() end
obs.obs_frontend_remove_event_callback = function() end

local live, resources = {}, {}
local scene, parent, data, elapsed, cleanup_frame, outcome
local original_load, original_unload, original_tick
local boundary = os.getenv('ASE_MEDIA_BOUNDARY') or 'stale'
local case = os.getenv('ASE_ZOOM_CASE') or 'A'
local percent = tonumber(os.getenv('ASE_ZOOM_PERCENT') or '50')
assert(boundary == 'stale' or boundary == 'wrap', 'Invalid ASE_MEDIA_BOUNDARY')
assert(case == 'A' or case == 'B', 'Invalid ASE_ZOOM_CASE')
local simulated = boundary == 'stale'
    and {state = obs.OBS_MEDIA_STATE_PLAYING, position = 66, duration = 3000}
    or {state = obs.OBS_MEDIA_STATE_ENDED, position = 3000, duration = 3000}
local phase = 0

local real_id = obs.obs_source_get_unversioned_id
local real_state = obs.obs_source_media_get_state
local real_time = obs.obs_source_media_get_time
local real_duration = obs.obs_source_media_get_duration
local real_stop = obs.obs_source_media_stop
local real_restart = obs.obs_source_media_restart
local real_play_pause = obs.obs_source_media_play_pause
local function is_parent(source)
    return parent ~= nil and source ~= nil
        and obs.obs_source_get_uuid(source) == obs.obs_source_get_uuid(parent)
end

obs.obs_source_get_unversioned_id = function(source)
    return is_parent(source) and 'ffmpeg_source' or real_id(source)
end
obs.obs_source_media_get_state = function(source)
    return is_parent(source) and simulated.state or real_state(source)
end
obs.obs_source_media_get_time = function(source)
    return is_parent(source) and simulated.position or real_time(source)
end
obs.obs_source_media_get_duration = function(source)
    return is_parent(source) and simulated.duration or real_duration(source)
end
obs.obs_source_media_stop = function(source)
    if not is_parent(source) then real_stop(source) end
end
obs.obs_source_media_restart = function(source)
    if not is_parent(source) then real_restart(source) end
end
obs.obs_source_media_play_pause = function(source, paused)
    if not is_parent(source) then real_play_pause(source, paused) end
end

local function publish(path, contents)
    local temporary = path .. '.tmp'
    local file = assert(io.open(temporary, 'w'))
    assert(file:write(contents)); assert(file:close()); assert(os.rename(temporary, path))
end

local function load_product()
    local register = obs.obs_register_source
    obs.obs_register_source = function(info)
        local create = info.create
        info.create = function(settings, source)
            local instance = create(settings, source)
            live[obs.obs_source_get_uuid(source)] = instance
            return instance
        end
        register(info)
    end
    dofile('ambient-source-events.lua')
    original_load, original_unload, original_tick = script_load, script_unload, script_tick
    original_load()
    obs.obs_register_source = register
end

local function setup()
    scene = obs.obs_scene_create('ASE Media generation boundary')
    local root = script_path() .. '../verification/fixtures/'
    local source_settings = obs.obs_data_create()
    obs.obs_data_set_string(source_settings, 'file', root .. 'alpha.png')
    obs.obs_data_set_bool(source_settings, 'is_local_file', true)
    obs.obs_data_set_string(source_settings, 'local_file', root .. 'video.mp4')
    obs.obs_data_set_bool(source_settings, 'looping', false)
    obs.obs_data_set_bool(source_settings, 'restart_on_activate', false)
    obs.obs_data_set_bool(source_settings, 'close_when_inactive', false)
    parent = assert(obs.obs_source_create('image_source', 'ASE simulated Media target',
        source_settings, nil))
    obs.obs_data_release(source_settings)
    resources[#resources + 1] = parent
    obs.obs_scene_add(scene, parent)

    local settings = obs.obs_data_create()
    obs.obs_data_set_int(settings, 'first_display', 0)
    obs.obs_data_set_double(settings, 'interval', 30)
    obs.obs_data_set_int(settings, 'start_effect', case == 'A' and 4 or 0)
    obs.obs_data_set_int(settings, 'end_effect', case == 'B' and 4 or 0)
    obs.obs_data_set_double(settings, 'start_duration', 5)
    obs.obs_data_set_double(settings, 'end_duration', 5)
    obs.obs_data_set_double(settings, 'start_zoom_percent', percent)
    obs.obs_data_set_double(settings, 'end_zoom_percent', percent)
    local filter = assert(obs.obs_source_create_private('lua_ambient_source_events_v1',
        'ASE Media generation filter', settings))
    obs.obs_data_release(settings)
    resources[#resources + 1] = filter
    obs.obs_source_filter_add(parent, filter)
    data = assert(live[obs.obs_source_get_uuid(filter)], 'Filter data unavailable')
    obs.obs_set_output_source(0, obs.obs_scene_get_source(scene))
end

local function drive_sequence()
    if not data or data.generation ~= 1 then return end
    if boundary == 'stale' then
        if phase == 0 then
            data.restart_ack, data.started_signal = 1, 1
            simulated.state, simulated.position = obs.OBS_MEDIA_STATE_PLAYING, 69
            phase = 1
        elseif phase == 1 then
            simulated.state, simulated.position = obs.OBS_MEDIA_STATE_PLAYING, 23
            phase = 2
        elseif phase == 2 then
            simulated.state, simulated.position = obs.OBS_MEDIA_STATE_ENDED, 33
            data.ended_signal = 1
            phase = 3
        end
    elseif phase == 0 then
        data.restart_ack, data.started_signal = 1, 1
        simulated.state, simulated.position = obs.OBS_MEDIA_STATE_PLAYING, 23
        phase = 1
    elseif phase == 1 then
        simulated.position = 33
        phase = 2
    elseif phase == 2 then
        simulated.position = 500
        phase = 3
    elseif phase < 40 then
        -- OBS can rewind a non-looping source before delivering ENDED. Keep
        -- that delayed-notification window open long enough for raw pixels to
        -- distinguish product hiding from test cleanup.
        simulated.position = 23
        phase = phase + 1
    end
end

local function cleanup()
    if cleanup_frame then
        cleanup_frame = cleanup_frame + 1
        if cleanup_frame == 4 then
            publish('verification/cleanup-ready.txt', 'READY\n')
            publish('verification/test-result.txt', outcome)
        end
        return
    end
    obs.obs_set_output_source(0, nil)
    if scene then
        obs.obs_source_remove(obs.obs_scene_get_source(scene))
        obs.obs_scene_release(scene)
        scene = nil
    end
    while #resources > 0 do obs.obs_source_release(table.remove(resources)) end
    parent, data = nil, nil
    cleanup_frame = 1
end

function script_load()
    local ok, reason = xpcall(load_product, debug.traceback)
    script_tick = function(seconds)
        if original_tick then original_tick() end
        if not scene and not outcome then
            local setup_ok, setup_reason = xpcall(setup, debug.traceback)
            if not setup_ok then outcome = 'FAIL: ' .. tostring(setup_reason) .. '\n' end
        end
        drive_sequence()
        elapsed = (elapsed or 0) + seconds
        if elapsed >= 1 and not outcome then
            local complete = boundary == 'stale' and phase == 3
                or boundary == 'wrap' and phase == 40
            outcome = complete and ('PASS: Media ' .. boundary .. ' boundary completed\n')
                or ('FAIL: sequence did not complete, phase=' .. tostring(phase) .. '\n')
        end
        if outcome then cleanup() end
    end
    script_unload = function()
        local unload_ok, unload_reason = xpcall(function()
            assert(cleanup_frame and cleanup_frame >= 4, 'Host unloaded before cleanup handshake')
            if original_unload then original_unload() end
        end, debug.traceback)
        publish('verification/unload-result.txt', unload_ok and 'PASS\n'
            or ('FAIL: ' .. tostring(unload_reason) .. '\n'))
    end
    if not ok then outcome = 'FAIL: ' .. tostring(reason) .. '\n' end
end
