-- Real obs_script_reload with live parent sources and attached filters.
-- The host performs reloads outside Lua callbacks; main Canvas owns the scene.
local obs = obslua
obs.obs_frontend_add_event_callback = function() end
obs.obs_frontend_remove_event_callback = function() end
local live, phase, elapsed, assertions = {}, 0, 0, 0
local awaiting_reload, initialized, finished, cleanup_frames = false, false, false, nil
local outcome, original_tick, original_unload
local names = {'ASE reload image', 'ASE reload video'}
local function publish(name, value)
    local path = 'verification/' .. name
    local f = assert(io.open(path .. '.tmp', 'w'))
    assert(f:write(value)); assert(f:close()); assert(os.rename(path .. '.tmp', path))
end
local function check(value, reason)
    assert(value, reason); assertions = assertions + 1
end
local function source(name, fn)
    local p = assert(obs.obs_get_source_by_name(name), name)
    local ok, reason = xpcall(function() fn(p) end, debug.traceback)
    obs.obs_source_release(p)
    assert(ok, reason)
end
local function data(p)
    local f = assert(obs.obs_source_get_filter_by_name(p, 'ASE reload filter'))
    local d = live[obs.obs_source_get_uuid(f)]
    obs.obs_source_release(f)
    return assert(d, 'Live filter instance was not recreated')
end
local function setup()
    local scene = assert(obs.obs_scene_create('ASE reload scene'))
    for i, name in ipairs(names) do
        local settings = obs.obs_data_create()
        if i == 1 then
            obs.obs_data_set_string(settings, 'file', script_path() .. '../verification/fixtures/alpha.png')
        else
            obs.obs_data_set_bool(settings, 'is_local_file', true)
            obs.obs_data_set_string(settings, 'local_file', script_path() .. '../verification/fixtures/video.mp4')
            for _, key in ipairs({'looping', 'restart_on_activate', 'close_when_inactive'}) do
                obs.obs_data_set_bool(settings, key, false)
            end
        end
        local p = assert(obs.obs_source_create(i == 1 and 'image_source' or 'ffmpeg_source', name, settings, nil))
        obs.obs_data_release(settings)
        obs.obs_scene_add(scene, p)
        local s = obs.obs_data_create()
        obs.obs_data_set_int(s, 'first_display', 1)
        obs.obs_data_set_double(s, 'interval', 1)
        local f = assert(obs.obs_source_create_private('lua_ambient_source_events_v1', 'ASE reload filter', s))
        obs.obs_data_release(s)
        obs.obs_source_filter_add(p, f)
        obs.obs_source_release(f); obs.obs_source_release(p)
    end
    obs.obs_set_output_source(0, obs.obs_scene_get_source(scene))
    obs.obs_scene_release(scene)
end
local function finish(ok, reason)
    if finished then return end
    finished = true
    outcome = ok and ('PASS: live reload phase ' .. phase .. ', ' .. assertions .. ' checks\n')
        or ('FAIL: ' .. tostring(reason) .. '\n')
    obs.obs_set_output_source(0, nil)
    local scene = obs.obs_get_source_by_name('ASE reload scene')
    if scene then obs.obs_source_remove(scene); obs.obs_source_release(scene) end
    cleanup_frames = 0
end
local function request_reload()
    awaiting_reload = true
    publish('lifecycle-stage.txt', tostring(phase + 1))
    publish('reload-request.txt', 'RELOAD\n')
end
local function step(dt)
    if finished then
        cleanup_frames = cleanup_frames + 1
        if cleanup_frames == 5 then
            publish('cleanup-ready.txt', 'READY\n')
            publish('test-result.txt', outcome)
        end
        return
    end
    local stop = io.open('verification/cleanup-request.txt', 'r')
    if stop then stop:close(); finish(false, 'Host interrupted test'); return end
    if awaiting_reload then return end
    elapsed = elapsed + dt
    if not initialized then
        initialized = true
        if phase == 0 then setup() end
    end
    if phase > 0 and not live.checked_initial and elapsed > 0.12 then
        for _, name in ipairs(names) do source(name, function(p)
            local d = data(p)
            check(d.state == 'WAITING' and d.alpha == 0 and d.generation == 0,
                'Reload must reset to initial waiting policy: ' .. name)
            check(d.wait_left > 0.65, 'Reload must start a fresh wait: ' .. name)
            check(d.effect ~= nil, 'Reload recreated shader: ' .. name)
            check(d.original_muted == false, 'Transient mute must not become original mute')
        end) end
        live.checked_initial = true
        if phase == 2 then request_reload = nil end
    end
    if phase == 1 and live.checked_initial then
        source(names[2], function(p)
            check(obs.obs_source_muted(p), 'Second reload starts while media is hidden and muted')
        end)
        request_reload()
    elseif phase == 0 or phase == 2 then
        source(names[2], function(p)
            local d = data(p)
            if d.ready and d.elapsed > 0.8 then
                check(d.generation == 1, 'First event after load/reload')
                check(not obs.obs_source_muted(p), 'Original audible state restored during playback')
                check(obs.obs_source_media_get_state(p) == obs.OBS_MEDIA_STATE_PLAYING, 'Actual decoder playing')
                if phase == 0 then request_reload() else finish(true) end
            end
        end)
    end
end
function script_load()
    local stage = io.open('verification/lifecycle-stage.txt', 'r')
    if stage then phase = tonumber(stage:read('*a')) or 0; stage:close() end
    local register = obs.obs_register_source
    obs.obs_register_source = function(info)
        local create = info.create
        info.create = function(settings, p)
            local d = create(settings, p)
            live[obs.obs_source_get_uuid(p)] = d
            return d
        end
        register(info)
    end
    dofile('ambient-source-events.lua')
    original_tick, original_unload = script_tick, script_unload
    local product_load = script_load
    product_load()
    obs.obs_register_source = register
    script_tick = function(dt)
        local ok, reason = xpcall(function() original_tick(); step(dt) end, debug.traceback)
        if not ok then finish(false, reason) end
    end
    script_unload = function()
        local ok, reason = xpcall(function()
            assert(awaiting_reload or (cleanup_frames and cleanup_frames >= 5), 'Unexpected unload')
            original_unload()
            if awaiting_reload then
                source(names[2], function(p)
                    check(not obs.obs_source_muted(p), 'Unload restores original mute before reload')
                end)
            end
        end, debug.traceback)
        publish(awaiting_reload and 'reload-unload.txt' or 'unload-result.txt',
            ok and 'PASS\n' or ('FAIL: ' .. tostring(reason) .. '\n'))
    end
end
