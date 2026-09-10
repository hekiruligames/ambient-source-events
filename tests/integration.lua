-- Isolated real libobs: decoded media, scene activity, GPU pixels and lifecycle.
local obs, ffi = obslua, require('ffi')
obs.obs_frontend_add_event_callback = function() end
obs.obs_frontend_remove_event_callback = function() end
ffi.cdef[[
typedef struct obs_source obs_source_t;
typedef struct gs_texture_render gs_texrender_t;
typedef struct gs_texture gs_texture_t;
typedef struct gs_stage_surface gs_stagesurf_t;
struct vec4 { float x,y,z,w; };
obs_source_t *obs_get_source_by_name(const char *name);
void obs_source_release(obs_source_t *source);
void obs_source_video_render(obs_source_t *source);
void obs_enter_graphics(void); void obs_leave_graphics(void);
gs_texrender_t *gs_texrender_create(int format, int zsformat);
void gs_texrender_destroy(gs_texrender_t *);
bool gs_texrender_begin(gs_texrender_t *, unsigned int, unsigned int);
void gs_texrender_end(gs_texrender_t *);
gs_texture_t *gs_texrender_get_texture(const gs_texrender_t *);
gs_stagesurf_t *gs_stagesurface_create(unsigned int, unsigned int, int);
void gs_stagesurface_destroy(gs_stagesurf_t *);
void gs_stage_texture(gs_stagesurf_t *, gs_texture_t *);
bool gs_stagesurface_map(gs_stagesurf_t *, unsigned char **, unsigned int *);
void gs_stagesurface_unmap(gs_stagesurf_t *);
void gs_clear(unsigned int, const struct vec4 *, float, unsigned char);
void gs_ortho(float,float,float,float,float,float);
void gs_blend_state_push(void); void gs_blend_state_pop(void);
void gs_blend_function(int,int);
void gs_matrix_push(void); void gs_matrix_pop(void);
void gs_matrix_translate3f(float,float,float);
]]
local C = ffi.load('/Applications/OBS.app/Contents/Frameworks/libobs.framework/libobs')
local live, resources, count = {}, {}, 0
local done, time, switches, pause_started, pause_position, pause_alpha = false, 0, 0
local outcome, cleanup_frame, render_registered, cleanup_failed = nil, nil, false, false
local snapshots, history = {}, {}
local scene_a, scene_b, image, peek, peek_angle, wipe_horizontal, wipe_vertical
local wipe_diagonal, wipe_angle, soft_wipe, soft_reference
local zoom_reference, zoom_shrink, zoom_grow, zoom_zero, zoom_start_only, zoom_end_only
local easing_fade
local white, media, gif_image, gif_media, text_source
local original_load, original_unload, original_tick
local integration_seconds = tonumber(os.getenv('ASE_INTEGRATION_SECONDS') or '14')
assert(integration_seconds and integration_seconds >= 14, 'ASE_INTEGRATION_SECONDS must be at least 14')
local trace = assert(io.open('verification/integration-trace.json', 'w'))
local function check(ok, msg) assert(ok, msg); count = count + 1 end
local function near(a,b,e) return math.abs(a-b) < (e or 0.03) end
local function publish(path, contents)
    -- The host must never observe a half-written result or acknowledgement.
    local temporary=path..'.tmp'
    local f=assert(io.open(temporary,'w'))
    assert(f:write(contents)); assert(f:close())
    assert(os.rename(temporary,path))
end
local function write_result(ok, reason)
    if done then
        -- A later cleanup error invalidates an earlier successful check set.
        if not ok then outcome='FAIL: '..tostring(reason)..'\n' end
        return
    end
    done = true; trace:close()
    outcome = ok and ('PASS: '..count..' real OBS integration checks (native teardown pending)\n')
        or ('FAIL: '..tostring(reason)..'\n')
end
local function fail_cleanup(reason)
    cleanup_failed = true
    write_result(false,reason)
    publish('verification/cleanup-ready.txt',outcome)
    publish('verification/test-result.txt',outcome)
end
local function capture(name, label, background, options)
    options = options or {}
    local width, height = options.width or 320, options.height or 180
    local graphics_entered, render_begun, blend_pushed, matrix_pushed, mapped = false, false, false, false, false
    local target, stage, source
    local rows, result
    local ok, reason = xpcall(function()
        C.obs_enter_graphics(); graphics_entered = true
        target = C.gs_texrender_create(obs.GS_RGBA, obs.GS_ZS_NONE)
        stage = C.gs_stagesurface_create(width,height,obs.GS_RGBA)
        source = C.obs_get_source_by_name(name)
        assert(source ~= nil, 'Capture source unavailable')
        assert(target ~= nil, 'Capture texrender unavailable')
        assert(stage ~= nil, 'Capture stagesurface unavailable')
        assert(C.gs_texrender_begin(target,width,height)); render_begun = true
        C.gs_blend_state_push(); blend_pushed = true
        C.gs_blend_function(obs.GS_BLEND_SRCALPHA,obs.GS_BLEND_INVSRCALPHA)
        C.gs_clear(obs.GS_CLEAR_COLOR,background or ffi.new('struct vec4'),0,0)
        C.gs_ortho(0,width,0,height,-100,100)
        if options.translate_x or options.translate_y then
            C.gs_matrix_push(); matrix_pushed = true
            C.gs_matrix_translate3f(options.translate_x or 0,options.translate_y or 0,0)
        end
        C.obs_source_video_render(source)
        if matrix_pushed then C.gs_matrix_pop(); matrix_pushed = false end
        C.gs_blend_state_pop(); blend_pushed = false
        C.gs_texrender_end(target); render_begun = false
        C.gs_stage_texture(stage,C.gs_texrender_get_texture(target))
        local bytes, stride = ffi.new('unsigned char *[1]'), ffi.new('unsigned int[1]')
        assert(C.gs_stagesurface_map(stage,bytes,stride), 'GPU readback failed'); mapped = true
        rows = {}
        for y=0,height-1 do rows[#rows+1] = ffi.string(bytes[0]+y*stride[0],width*4) end
        local function pixel(x,y)
            local off = y*stride[0]+x*4
            return {tonumber(bytes[0][off]),tonumber(bytes[0][off+1]),tonumber(bytes[0][off+2]),tonumber(bytes[0][off+3])}
        end
        local samples = options.samples or {
            {80,45},{240,45},{80,135},{240,135},
            {120,30},{200,150},{40,110},{280,70},
        }
        result = {}
        for _,sample in ipairs(samples) do result[#result+1]=pixel(sample[1],sample[2]) end
    end, debug.traceback)
    -- Always unwind resources acquired above, including when an assert fails.
    local cleanup_errors = {}
    local function cleanup_call(label, fn, arg)
        local cleanup_ok, cleanup_reason
        if arg == nil then cleanup_ok, cleanup_reason = pcall(fn)
        else cleanup_ok, cleanup_reason = pcall(fn,arg) end
        if not cleanup_ok then cleanup_errors[#cleanup_errors+1] = label..': '..tostring(cleanup_reason) end
    end
    if mapped then cleanup_call('stagesurface_unmap',C.gs_stagesurface_unmap,stage) end
    if matrix_pushed then cleanup_call('matrix_pop',C.gs_matrix_pop) end
    if blend_pushed then cleanup_call('blend_state_pop',C.gs_blend_state_pop) end
    if render_begun then cleanup_call('texrender_end',C.gs_texrender_end,target) end
    if stage ~= nil then cleanup_call('stagesurface_destroy',C.gs_stagesurface_destroy,stage) end
    if target ~= nil then cleanup_call('texrender_destroy',C.gs_texrender_destroy,target) end
    if source ~= nil then cleanup_call('source_release',C.obs_source_release,source) end
    if graphics_entered then cleanup_call('leave_graphics',C.obs_leave_graphics) end
    if #cleanup_errors > 0 then
        local cleanup_reason = table.concat(cleanup_errors, '\n')
        reason = ok and cleanup_reason or (tostring(reason)..'\n'..cleanup_reason)
        ok = false
    end
    assert(ok, reason)
    local f=assert(io.open('verification/'..label..'.rgba','wb')); f:write(table.concat(rows)); f:close()
    return result
end
local function make_source(kind, name, values, options)
    local s=obs.obs_data_create()
    for k,v in pairs(values) do
        if type(v)=='boolean' then obs.obs_data_set_bool(s,k,v)
        elseif type(v)=='number' then obs.obs_data_set_int(s,k,v)
        else obs.obs_data_set_string(s,k,v) end
    end
    local p=assert(obs.obs_source_create(kind,name,s,nil),name)
    obs.obs_data_release(s)
    resources[#resources+1]=p
    obs.obs_scene_add(scene_a,p)
    local settings=obs.obs_data_create()
    for k,v in pairs(options or {}) do
        if k:find('effect') or k:find('mode') or k:find('direction') or k:find('angle')
                or k:find('anchor') or k:find('easing')
                or k=='first_display' then obs.obs_data_set_int(settings,k,v)
        else obs.obs_data_set_double(settings,k,v) end
    end
    local f=assert(obs.obs_source_create_private('lua_ambient_source_events_v1',name..' filter',settings))
    obs.obs_data_release(settings)
    obs.obs_source_filter_add(p,f)
    -- Keep one test reference so the test can disable/remove in a controlled order.
    resources[#resources+1]=f
    local d=assert(live[obs.obs_source_get_uuid(f)])
    check(d.effect~=nil,'Actual shader compiled: '..name)
    return {parent=p,filter=f,data=d,name=name}
end
local function load_product()
    local register=obs.obs_register_source
    obs.obs_register_source=function(info)
        local create=info.create
        info.create=function(s,p)
            local d=create(s,p); live[obs.obs_source_get_uuid(p)]=d; return d
        end
        register(info)
    end
    dofile('ambient-source-events.lua')
    original_load,original_unload,original_tick=script_load,script_unload,script_tick
    original_load()
    obs.obs_register_source=register
end
local function setup()
    scene_a=obs.obs_scene_create('ASE isolated A'); scene_b=obs.obs_scene_create('ASE isolated B')
    local root=script_path()..'../verification/fixtures/'
    image=make_source('image_source','ASE PNG',{file=root..'alpha.png'},
        {first_display=1,interval=1,display_duration=2,start_duration=0.5,end_duration=0.5})
    peek=make_source('image_source','ASE Peek PNG',{file=root..'alpha.png'},
        {first_display=1,interval=1,display_duration=2,start_effect=2,end_effect=2,
            start_duration=0.5,end_duration=0.5,start_direction=2,end_direction=6})
    peek_angle=make_source('image_source','ASE Peek angle PNG',{file=root..'alpha.png'},
        {first_display=1,interval=1,display_duration=2,start_effect=2,end_effect=2,
            start_duration=0.5,end_duration=0.5,start_direction=8,start_angle=0,
            end_direction=8,end_angle=180})
    wipe_horizontal=make_source('image_source','ASE Wipe horizontal PNG',{file=root..'alpha.png'},
        {first_display=1,interval=1,display_duration=2,start_effect=3,end_effect=3,
            start_duration=0.5,end_duration=0.5,start_direction=2,end_direction=6})
    wipe_vertical=make_source('image_source','ASE Wipe vertical PNG',{file=root..'alpha.png'},
        {first_display=1,interval=1,display_duration=2,start_effect=3,end_effect=3,
            start_duration=0.5,end_duration=0.5,start_direction=0,end_direction=4})
    wipe_diagonal=make_source('image_source','ASE Wipe diagonal PNG',{file=root..'alpha.png'},
        {first_display=1,interval=1,display_duration=2,start_effect=3,end_effect=3,
            start_duration=0.5,end_duration=0.5,start_direction=3,end_direction=7})
    wipe_angle=make_source('image_source','ASE Wipe angle PNG',{file=root..'alpha.png'},
        {first_display=1,interval=1,display_duration=2,start_effect=3,end_effect=3,
            start_duration=0.5,end_duration=0.5,start_direction=8,start_angle=30,
            end_direction=8,end_angle=210})
    soft_wipe=make_source('image_source','ASE Soft Wipe PNG',{file=root..'softness.png'},
        {first_display=1,interval=1,display_duration=2,start_effect=3,end_effect=3,
            start_duration=0.5,end_duration=0.5,start_direction=2,end_direction=2,
            start_softness=100,end_softness=100})
    soft_reference=make_source('image_source','ASE Soft Wipe reference PNG',{file=root..'softness.png'},
        {first_display=1,interval=1,display_duration=2,start_effect=0,end_effect=0})
    zoom_reference=make_source('image_source','ASE Zoom reference PNG',{file=root..'alpha.png'},
        {first_display=1,interval=1,display_duration=2,start_effect=0,end_effect=0})
    zoom_shrink=make_source('image_source','ASE Zoom shrink PNG',{file=root..'alpha.png'},
        {first_display=1,interval=1,display_duration=2,start_effect=4,end_effect=4,
            start_duration=0.5,end_duration=0.5,start_zoom_percent=50,end_zoom_percent=50,
            start_zoom_anchor=4,end_zoom_anchor=8})
    zoom_grow=make_source('image_source','ASE Zoom grow PNG',{file=root..'alpha.png'},
        {first_display=1,interval=1,display_duration=2,start_effect=4,end_effect=4,
            start_duration=0.5,end_duration=0.5,start_zoom_percent=200,end_zoom_percent=200,
            start_zoom_anchor=2,end_zoom_anchor=7})
    zoom_zero=make_source('image_source','ASE Zoom zero PNG',{file=root..'alpha.png'},
        {first_display=1,interval=1,display_duration=2,start_effect=4,end_effect=0,
            start_duration=0.5,start_zoom_percent=0,start_zoom_anchor=4})
    zoom_start_only=make_source('image_source','ASE Zoom start-only PNG',{file=root..'alpha.png'},
        {first_display=1,interval=1,display_duration=2,start_effect=4,end_effect=0,
            start_duration=0.5,start_zoom_percent=50,start_zoom_anchor=4,start_easing=0})
    zoom_end_only=make_source('image_source','ASE Zoom end-only PNG',{file=root..'alpha.png'},
        {first_display=1,interval=1,display_duration=2,start_effect=0,end_effect=4,
            end_duration=0.5,end_zoom_percent=50,end_zoom_anchor=4,end_easing=3})
    easing_fade=make_source('image_source','ASE Easing Fade',{file=root..'alpha.png'},
        {first_display=1,interval=1,display_duration=2,start_effect=1,end_effect=1,
            start_duration=1,end_duration=1,start_easing=0,end_easing=3})
    white=make_source('color_source','ASE white',{color=0xffffffff,width=320,height=180},
        {first_display=1,interval=1,display_duration=2,start_duration=0.5,end_duration=0.5})
    media=make_source('ffmpeg_source','ASE video',{is_local_file=true,local_file=root..'video.mp4',
        looping=false,restart_on_activate=false,close_when_inactive=false,clear_on_media_end=true},
        {first_display=1,interval=1,start_duration=0.5,end_duration=0.5})
    gif_image=make_source('image_source','ASE image GIF',{file=root..'animation.gif'},
        {display_duration=2,interval=1})
    gif_media=make_source('ffmpeg_source','ASE media GIF',{is_local_file=true,local_file=root..'animation.gif',
        looping=false,restart_on_activate=false,close_when_inactive=false,clear_on_media_end=true},
        {interval=1})
    local font=obs.obs_data_create(); obs.obs_data_set_string(font,'face','Hiragino Sans'); obs.obs_data_set_int(font,'size',32)
    text_source=make_source('text_ft2_source_v2','ASE text',{text='ASE 文字の試験'}, {interval=1,display_duration=2})
    local ts=obs.obs_source_get_settings(text_source.parent); obs.obs_data_set_obj(ts,'font',font)
    obs.obs_source_update(text_source.parent,ts); obs.obs_data_release(ts); obs.obs_data_release(font)
    obs.obs_set_output_source(0,obs.obs_scene_get_source(scene_a))
end
local function step(dt)
    if done then return end
    time=time+dt
    local d=media.data
    local state=obs.obs_source_media_get_state(media.parent)
    local position=obs.obs_source_media_get_time(media.parent)
    local row=obs.obs_data_create()
    obs.obs_data_set_double(row,'wall',time); obs.obs_data_set_int(row,'timestamp',obs.os_gettime_ns())
    obs.obs_data_set_string(row,'phase',d.state); obs.obs_data_set_double(row,'alpha',d.alpha)
    obs.obs_data_set_int(row,'media_state',state); obs.obs_data_set_int(row,'position',position)
    obs.obs_data_set_bool(row,'muted',obs.obs_source_muted(media.parent))
    trace:write(obs.obs_data_get_json(row):gsub('\n',''),'\n'); obs.obs_data_release(row)
    if not history[d.generation] then history[d.generation]={start=time,minimum=position} end
    history[d.generation].minimum=math.min(history[d.generation].minimum,position)
    if switches==0 and d.ready and d.elapsed>1 and d.elapsed<1.5 then
        switches=1; pause_started=time
        obs.obs_set_output_source(0,obs.obs_scene_get_source(scene_b))
    elseif switches==1 and time-pause_started>0.15 then
        pause_position=position; pause_alpha=d.alpha
        check(state==obs.OBS_MEDIA_STATE_PAUSED,'Real media paused while inactive')
        switches=2
    elseif switches==2 and time-pause_started>1 then
        check(math.abs(position-pause_position)<=34,'Real media position remains paused')
        check(d.alpha==pause_alpha,'Fade progress remains frozen')
        check(obs.obs_source_muted(media.parent),'Inactive source muted')
        obs.obs_set_output_source(0,obs.obs_scene_get_source(scene_a)); switches=3
    end
    if easing_fade then
        local ed=easing_fade.data
        local start_mode=ed.cfg.start_easing
        local end_mode=ed.cfg.end_easing
        if ed.state=='ENDING' and start_mode<3
                and snapshots['easing-start-'..start_mode]
                and snapshots['easing-end-'..end_mode]
                and not snapshots['easing-advanced-'..start_mode] then
            local settings=obs.obs_source_get_settings(easing_fade.filter)
            obs.obs_data_set_int(settings,'start_easing',start_mode+1)
            obs.obs_data_set_int(settings,'end_easing',2-start_mode)
            obs.obs_source_update(easing_fade.filter,settings)
            obs.obs_data_release(settings)
            snapshots['easing-advanced-'..start_mode]=true
        end
    end
    if time>integration_seconds and not snapshots.disabled then
        check(switches==3,'Scene pause/resume completed')
        check(d.generation>=3,'Real Media Source restarts across multiple ended cycles')
        for gen,h in pairs(history) do if gen>0 then check(h.minimum<350,'Restart begins near start '..gen) end end
        check(not gif_image.data.media and gif_media.data.media,'GIF classified by source type')
        check(gif_media.data.generation>=3,'Media GIF repeats through actual restart')
        check(text_source.data.generation>=3,'Text source events progress')
        check(obs.obs_source_get_width(peek.filter)==320 and obs.obs_source_get_height(peek.filter)==180,
            'Peek keeps the source output size')
        check(obs.obs_source_get_width(peek_angle.filter)==320 and obs.obs_source_get_height(peek_angle.filter)==180,
            'Custom-angle Peek keeps the source output size')
        for _,wipe in ipairs({wipe_horizontal,wipe_vertical,wipe_diagonal,wipe_angle}) do
            check(obs.obs_source_get_width(wipe.filter)==320 and obs.obs_source_get_height(wipe.filter)==180,
                'Wipe keeps the source output size: '..wipe.name)
        end
        check(obs.obs_source_get_width(soft_wipe.filter)==320
                and obs.obs_source_get_height(soft_wipe.filter)==180,
            'Soft Wipe keeps the source output size')
        for _,zoom in ipairs({zoom_shrink,zoom_grow,zoom_zero,zoom_start_only,zoom_end_only}) do
            check(obs.obs_source_get_width(zoom.filter)==320 and obs.obs_source_get_height(zoom.filter)==180,
                'Zoom keeps Scene Item source dimensions: '..zoom.name)
        end
        for easing_mode=0,3 do
            check(snapshots['easing-start-'..easing_mode]
                    and snapshots['easing-end-'..easing_mode],
                'Captured easing mode '..easing_mode..' through real OBS settings and GPU rendering')
        end
        obs.obs_source_set_enabled(image.filter,false)
        snapshots.disabled='pending'
    elseif snapshots.disabled=='pending' and time>integration_seconds+0.2 then
        local pixels=capture(image.name,'disabled')
        check(pixels[1][4]==255 and math.abs(pixels[2][4]-128)<=1,'Disable restores original alpha')
        snapshots.disabled=true
        obs.obs_source_filter_remove(media.parent,media.filter)
        snapshots.removed=time
    elseif snapshots.removed and time-snapshots.removed>0.5 then
        check(not obs.obs_source_muted(media.parent),'Removal restores original unmuted state')
        check(obs.obs_source_media_get_state(media.parent)==obs.OBS_MEDIA_STATE_PLAYING,'Removal restores playback')
        for _,key in ipairs({'waiting','half','visible','ending','peek-start-outside','peek-end-outside',
                'wipe-start-hidden','wipe-end-hidden','zoom-zero','zoom-shrink-in-half',
                'zoom-shrink-out-half','zoom-grow-in','zoom-grow-out',
                'zoom-start-only-near-end','zoom-start-only-visible','zoom-start-only-hidden',
                'zoom-end-only-near-start','zoom-end-only-near-end','zoom-end-only-hidden',
                'soft-wipe-in','soft-wipe-out','soft-wipe-in-near-end',
                'soft-wipe-in-end','soft-wipe-out-near-end','soft-wipe-out-end'}) do
            check(snapshots[key]~=nil,'Captured GPU '..key)
        end
        write_result(true)
    end
end
local function same_pixel(a,b)
    for channel=1,4 do if math.abs(a[channel]-b[channel])>2 then return false end end
    return true
end
local function check_wipe_mask(pixels, visible, hidden, reference, label)
    for _,index in ipairs(visible) do
        check(pixels[index][4]>0, label..' visible sample '..index)
        if reference then check(same_pixel(pixels[index],reference[index]),
            label..' preserves color, brightness, alpha, and pixel position '..index) end
    end
    for _,index in ipairs(hidden) do
        check(pixels[index][1]==0 and pixels[index][2]==0 and pixels[index][3]==0
                and pixels[index][4]==0, label..' hidden sample '..index)
    end
end
local function smoothstep(a,b,x)
    local t=math.max(0,math.min(1,(x-a)/(b-a)))
    return t*t*(3-2*t)
end
local function check_soft_wipe(phase,label,percent)
    local d=soft_wipe.data
    local progress=phase=='STARTING' and d.start_progress or d.end_progress
    local softness=percent/100*180/320
    local center_position=progress*(1+softness)-softness*0.5
    local center=center_position*320
    local full_x=math.max(0,math.floor(center-softness*160-12))
    local hidden_x=math.min(319,math.ceil(center+softness*160+12))
    if phase=='ENDING' then full_x,hidden_x=hidden_x,full_x end
    local center_x=math.max(0,math.min(319,math.floor(center)))
    local samples={{full_x,30},{center_x,30},{hidden_x,30},
        {center_x,90},{center_x,150}}
    local pixels=capture(soft_wipe.name,label,nil,{samples=samples})
    local reference=capture(soft_reference.name,label..'-reference',nil,{samples=samples})
    check(same_pixel(pixels[1],reference[1]),label..' fully visible side preserves source RGBA')
    check(pixels[3][1]==0 and pixels[3][2]==0 and pixels[3][3]==0 and pixels[3][4]==0,
        label..' fully hidden side is transparent')
    local position=(center_x+0.5)/320
    local edge0=center_position-softness*0.5
    local edge1=center_position+softness*0.5
    local mask=smoothstep(edge0,edge1,position)
    if phase=='STARTING' then mask=1-mask end
    check(mask>0.05 and mask<0.95,label..' samples a genuine gradient pixel')
    for index=1,4 do
        check(math.abs(pixels[2][index]-reference[2][index]*mask)<=7,
            label..' premultiplied opaque channel '..index)
        check(math.abs(pixels[4][index]-reference[4][index]*mask)<=7,
            label..' premultiplied half-alpha channel '..index)
    end
    check(pixels[5][1]==0 and pixels[5][2]==0 and pixels[5][3]==0 and pixels[5][4]==0,
        label..' original transparent pixel stays transparent in gradient')
    local yellow=ffi.new('struct vec4',1,1,0,1)
    local composite=capture(soft_wipe.name,label..'-yellow',yellow,
        {samples={{center_x,30},{center_x,90}}})
    for index,source_index in ipairs({2,4}) do
        local source=reference[source_index]
        local expected_alpha=source[4]/255*mask
        local expected={source[1]*mask+255*(1-expected_alpha),
            source[2]*mask+255*(1-expected_alpha),source[3]*mask,255}
        for channel=1,4 do check(math.abs(composite[index][channel]-expected[channel])<=8,
            label..' composites without darkening or color shift '..index..'/'..channel) end
    end
    check(d.alpha==1,label..' does not change global opacity')
    snapshots[label]=pixels
end
local function zoom_samples(scale, anchor_x, anchor_y, offset_x, offset_y)
    local result = {}
    for _,point in ipairs({{80,45},{240,45},{80,135},{240,135}}) do
        result[#result+1] = {
            math.floor(offset_x + 320*anchor_x + (point[1]-320*anchor_x)*scale + 0.5),
            math.floor(offset_y + 180*anchor_y + (point[2]-180*anchor_y)*scale + 0.5),
        }
    end
    return result
end
local function check_zoom_pixels(zoom, label, scale, anchor_x, anchor_y, options)
    options.samples = zoom_samples(scale,anchor_x,anchor_y,options.translate_x or 0,options.translate_y or 0)
    local pixels=capture(zoom.name,label,nil,options)
    local reference=capture(zoom_reference.name,label..'-reference',nil,
        {samples={{80,45},{240,45},{80,135},{240,135}}})
    for index=1,4 do
        check(same_pixel(pixels[index],reference[index]),
            label..' preserves source color, brightness, and alpha sample '..index)
    end
    check(zoom.data.alpha==1,label..' does not change opacity')
    snapshots[label]=pixels
end
local function easing_value(t, mode)
    t=math.max(0,math.min(1,t))
    if t==0 or t==1 or mode==0 then return t end
    if mode==1 then return t*t*t end
    if mode==2 then return 1-(1-t)*(1-t)*(1-t) end
    return t<0.5 and 4*t*t*t or 1-((-2*t+2)^3)/2
end
local function check_easing_fades()
    if not easing_fade then return end
    for _,phase in ipairs({'STARTING','ENDING'}) do
        local d=easing_fade.data
        local mode=phase=='STARTING' and d.cfg.start_easing or d.cfg.end_easing
        local snapshot_key=(phase=='STARTING' and 'easing-start-' or 'easing-end-')..mode
        if not snapshots[snapshot_key] then
            if d.owns and d.active and d.state==phase and d.total then
                local raw=phase=='STARTING' and d.elapsed/d.cfg.start_duration
                    or (d.elapsed-(d.total-d.cfg.end_duration))/d.cfg.end_duration
                if raw>0.2 and raw<0.3 then
                    local expected=easing_value(raw,mode)
                    local progress=phase=='STARTING' and d.start_progress or d.end_progress
                    local alpha=phase=='STARTING' and expected or 1-expected
                    check(near(progress,expected,1e-6),
                        phase..' applies easing mode '..mode..' to progress')
                    check(near(d.alpha,alpha,1e-6),
                        phase..' easing mode '..mode..' drives Fade opacity only')
                    check(d.cfg.end_easing==3-d.cfg.start_easing,
                        'Real OBS keeps independent start and end easing settings')
                    local pixels=capture(easing_fade.name,snapshot_key)
                    check(math.abs(pixels[1][4]-math.floor(alpha*255+0.5))<=2,
                        phase..' easing mode '..mode..' reaches GPU opacity')
                    snapshots[snapshot_key]=true
                end
            end
        end
    end
end
local function render()
    if done or not image then return end
    check_easing_fades()
    local d=image.data
    local pd=peek.data
    if pd.owns and pd.active and pd.state=='STARTING' and pd.start_progress<0.05
            and not snapshots['peek-start-outside'] then
        local pixels=capture(peek.name,'peek-start-outside')
        for i,pixel in ipairs(pixels) do
            check(pixel[1]==0 and pixel[2]==0 and pixel[3]==0 and pixel[4]==0,
                'Peek In begins fully outside sample '..i)
        end
        check(pd.alpha==1,'Peek In does not change opacity')
        snapshots['peek-start-outside']=pixels
    elseif pd.owns and pd.active and pd.state=='ENDING' and pd.end_progress>0.95
            and not snapshots['peek-end-outside'] then
        local pixels=capture(peek.name,'peek-end-outside')
        for i,pixel in ipairs(pixels) do
            check(pixel[1]==0 and pixel[2]==0 and pixel[3]==0 and pixel[4]==0,
                'Peek Out finishes fully outside sample '..i)
        end
        check(pd.alpha==1,'Peek Out does not change opacity')
        snapshots['peek-end-outside']=pixels
    end
    local wd=wipe_horizontal.data
    if wd.owns and wd.active and wd.state=='STARTING' and wd.start_progress<0.05
            and not snapshots['wipe-start-hidden'] then
        local pixels=capture(wipe_horizontal.name,'wipe-start-hidden')
        for i,pixel in ipairs(pixels) do
            check(pixel[1]==0 and pixel[2]==0 and pixel[3]==0 and pixel[4]==0,
                'Wipe In begins fully hidden sample '..i)
        end
        check(wd.alpha==1,'Wipe In hidden endpoint does not use opacity')
        snapshots['wipe-start-hidden']=pixels
    elseif wd.owns and wd.active and wd.state=='ENDING' and wd.end_progress>0.95
            and not snapshots['wipe-end-hidden'] then
        local pixels=capture(wipe_horizontal.name,'wipe-end-hidden')
        for i,pixel in ipairs(pixels) do
            check(pixel[1]==0 and pixel[2]==0 and pixel[3]==0 and pixel[4]==0,
                'Wipe Out finishes fully hidden sample '..i)
        end
        check(wd.alpha==1,'Wipe Out hidden endpoint does not use opacity')
        snapshots['wipe-end-hidden']=pixels
    end
    local sd=soft_wipe.data
    if sd.owns and sd.active and sd.state=='STARTING'
            and sd.start_progress>0.35 and sd.start_progress<0.65
            and not snapshots['soft-wipe-in'] then
        check_soft_wipe('STARTING','soft-wipe-in',sd.cfg.start_softness)
    elseif sd.owns and sd.active and sd.state=='STARTING' and sd.start_progress>0.94
            and not snapshots['soft-wipe-in-near-end'] then
        snapshots['soft-wipe-in-near-end']=capture(soft_wipe.name,'soft-wipe-in-near-end',nil,
            {samples={{319,30},{319,90},{319,150}}})
    elseif sd.owns and sd.active and sd.state=='VISIBLE'
            and snapshots['soft-wipe-in-near-end'] and not snapshots['soft-wipe-in-end'] then
        local pixels=capture(soft_wipe.name,'soft-wipe-in-end',nil,
            {samples={{319,30},{319,90},{319,150}}})
        for index,pixel in ipairs(pixels) do
            for channel=1,4 do check(math.abs(pixel[channel]
                        - snapshots['soft-wipe-in-near-end'][index][channel])<=10,
                    'Soft Wipe In approaches its endpoint without a final jump '..index..'/'..channel) end
        end
        snapshots['soft-wipe-in-end']=pixels
    elseif sd.owns and sd.active and sd.state=='ENDING'
            and sd.end_progress>0.35 and sd.end_progress<0.65
            and not snapshots['soft-wipe-out'] then
        check_soft_wipe('ENDING','soft-wipe-out',sd.cfg.end_softness)
    elseif sd.owns and sd.active and sd.state=='ENDING' and sd.end_progress>0.94
            and not snapshots['soft-wipe-out-near-end'] then
        snapshots['soft-wipe-out-near-end']=capture(soft_wipe.name,'soft-wipe-out-near-end',nil,
            {samples={{319,30},{319,90},{319,150}}})
    elseif sd.owns and sd.active and sd.state=='WAITING'
            and snapshots['soft-wipe-out-near-end'] and not snapshots['soft-wipe-out-end'] then
        local pixels=capture(soft_wipe.name,'soft-wipe-out-end',nil,
            {samples={{319,30},{319,90},{319,150}}})
        for index,pixel in ipairs(pixels) do
            for channel=1,4 do check(math.abs(pixel[channel]
                        - snapshots['soft-wipe-out-near-end'][index][channel])<=10,
                    'Soft Wipe Out approaches its endpoint without a final jump '..index..'/'..channel) end
        end
        snapshots['soft-wipe-out-end']=pixels
    end
    local zd=zoom_zero.data
    if zd.owns and zd.active and zd.state=='STARTING' and zd.start_progress<0.05
            and not snapshots['zoom-zero'] then
        local pixels=capture(zoom_zero.name,'zoom-zero')
        for index,pixel in ipairs(pixels) do
            check(pixel[1]==0 and pixel[2]==0 and pixel[3]==0 and pixel[4]==0,
                'Zero percent Zoom is transparent sample '..index)
        end
        check(zd.alpha==1,'Zero percent Zoom does not use opacity')
        snapshots['zoom-zero']=pixels
    end
    local zsi=zoom_start_only.data
    if zsi.owns and zsi.active and zsi.state=='STARTING' and zsi.start_progress>0.94
            and not snapshots['zoom-start-only-near-end'] then
        local scale=0.5+0.5*zsi.start_progress
        check_zoom_pixels(zoom_start_only,'zoom-start-only-near-end',scale,0.5,0.5,
            {width=320,height=180})
        check(zsi.end_progress==0,'Start-only Zoom does not borrow end progress near completion')
    elseif zsi.owns and zsi.active and zsi.state=='VISIBLE'
            and snapshots['zoom-start-only-near-end']
            and not snapshots['zoom-start-only-visible'] then
        check_zoom_pixels(zoom_start_only,'zoom-start-only-visible',1,0.5,0.5,
            {width=320,height=180})
        check(zsi.start_progress==1 and zsi.end_progress==0,
            'Start-only Zoom holds its completed endpoint during normal display')
    elseif zsi.owns and zsi.active and zsi.state=='WAITING'
            and snapshots['zoom-start-only-visible']
            and not snapshots['zoom-start-only-hidden'] then
        local pixels=capture(zoom_start_only.name,'zoom-start-only-hidden')
        for index,pixel in ipairs(pixels) do
            check(pixel[1]==0 and pixel[2]==0 and pixel[3]==0 and pixel[4]==0,
                'Start-only Zoom is fully hidden without a reset frame '..index)
        end
        check(zsi.start_progress==0 and zsi.end_progress==0,
            'Start-only Zoom resets inactive progress while hidden')
        snapshots['zoom-start-only-hidden']=pixels
    end
    local zei=zoom_end_only.data
    if zei.owns and zei.active and zei.state=='ENDING' and zei.end_progress<0.06
            and not snapshots['zoom-end-only-near-start'] then
        local scale=1-0.5*zei.end_progress
        check_zoom_pixels(zoom_end_only,'zoom-end-only-near-start',scale,0.5,0.5,
            {width=320,height=180})
        check(zei.start_progress==1,'End-only Zoom starts after the normal visible state')
    elseif zei.owns and zei.active and zei.state=='ENDING' and zei.end_progress>0.94
            and not snapshots['zoom-end-only-near-end'] then
        local scale=1-0.5*zei.end_progress
        check_zoom_pixels(zoom_end_only,'zoom-end-only-near-end',scale,0.5,0.5,
            {width=320,height=180})
        check(zei.start_progress==1,'End-only Zoom keeps start completion near its endpoint')
    elseif zei.owns and zei.active and zei.state=='WAITING'
            and snapshots['zoom-end-only-near-end']
            and not snapshots['zoom-end-only-hidden'] then
        local pixels=capture(zoom_end_only.name,'zoom-end-only-hidden')
        for index,pixel in ipairs(pixels) do
            check(pixel[1]==0 and pixel[2]==0 and pixel[3]==0 and pixel[4]==0,
                'End-only Zoom is fully hidden without a 100 percent reset frame '..index)
        end
        check(zei.start_progress==0 and zei.end_progress==0,
            'End-only Zoom resets inactive progress while hidden')
        snapshots['zoom-end-only-hidden']=pixels
    end
    local zs=zoom_shrink.data
    if zs.owns and zs.active and zs.state=='STARTING' and near(zs.start_progress,0.5,0.05)
            and not snapshots['zoom-shrink-in-half'] then
        local scale=0.5+0.5*zs.start_progress
        check_zoom_pixels(zoom_shrink,'zoom-shrink-in-half',scale,0.5,0.5,
            {width=320,height=180})
        local empty=capture(zoom_shrink.name,'zoom-shrink-in-empty',nil,
            {samples={{5,5},{315,175}}})
        for index,pixel in ipairs(empty) do
            check(pixel[1]==0 and pixel[2]==0 and pixel[3]==0 and pixel[4]==0,
                'Zoom In shrink leaves transparent space '..index)
        end
    elseif zs.owns and zs.active and zs.state=='ENDING' and near(zs.end_progress,0.5,0.05)
            and not snapshots['zoom-shrink-out-half'] then
        local scale=1-0.5*zs.end_progress
        check_zoom_pixels(zoom_shrink,'zoom-shrink-out-half',scale,1,1,
            {width=320,height=180})
    end
    local zg=zoom_grow.data
    if zg.owns and zg.active and zg.state=='STARTING' and zg.start_progress<0.05
            and not snapshots['zoom-grow-in'] then
        local scale=2-zg.start_progress
        check_zoom_pixels(zoom_grow,'zoom-grow-in',scale,1,0,
            {width=700,height=400,translate_x=340,translate_y=20})
        local expanded=zoom_samples(scale,1,0,340,20)
        check(expanded[1][1]<340,'Above-100 Zoom In allocates visible pixels left of the original source area')
    elseif zg.owns and zg.active and zg.state=='ENDING' and near(zg.end_progress,0.5,0.05)
            and not snapshots['zoom-grow-out'] then
        local scale=1+zg.end_progress
        check_zoom_pixels(zoom_grow,'zoom-grow-out',scale,0.5,1,
            {width=640,height=480,translate_x=200,translate_y=150})
        local expanded=zoom_samples(scale,0.5,1,200,150)
        check(expanded[1][2]<150,'Above-100 Zoom Out allocates visible pixels above the original source area')
    end
    local label
    if d.owns and d.active then
        if d.state=='WAITING' and not snapshots.waiting then label='waiting'
        elseif d.state=='STARTING' and near(d.alpha,0.5,0.04) and not snapshots.half then label='half'
        elseif d.state=='VISIBLE' and d.alpha==1 and not snapshots.visible then label='visible'
        elseif d.state=='ENDING' and near(d.alpha,0.5,0.04) and not snapshots.ending then label='ending' end
    end
    if label then
        local pixels=capture(image.name,label)
        local expected=math.floor(d.alpha*255+0.5)
        local yellow=ffi.new('struct vec4',1,1,0,1)
        local white_pixels=capture(white.name,label..'-white',yellow)
        local white_alpha=white.data.alpha
        local white_expected=math.floor(white_alpha*255+0.5)
        check(math.abs(white_pixels[1][1]-255)<=2 and math.abs(white_pixels[1][2]-255)<=2,
            'GPU white over yellow RG '..label)
        check(math.abs(white_pixels[1][3]-white_expected)<=2 and math.abs(white_pixels[1][4]-255)<=2,
            'GPU white over yellow B/A '..label)
        local yellow_pixels=capture(image.name,label..'-yellow',yellow)
        local green_alpha=128/255*d.alpha
        check(math.abs(yellow_pixels[4][1]-255)<=2 and math.abs(yellow_pixels[4][2]-255)<=2
            and math.abs(yellow_pixels[4][3])<=2 and math.abs(yellow_pixels[4][4]-255)<=2,
            'GPU transparent PNG over yellow '..label)
        local expected_green_r=255*(1-green_alpha)
        check(math.abs(yellow_pixels[2][1]-expected_green_r)<=2
            and math.abs(yellow_pixels[2][2]-255)<=2 and math.abs(yellow_pixels[2][3])<=2
            and math.abs(yellow_pixels[2][4]-255)<=2,
            'GPU half-alpha PNG over yellow '..label)
        check(math.abs(pixels[1][4]-expected)<=2,'GPU opaque alpha '..label..': '..pixels[1][4]..' expected '..expected)
        check(math.abs(pixels[2][4]-128*d.alpha)<=2,'GPU original half-alpha preserved '..label)
        check(pixels[4][4]==0,'GPU transparent region stays transparent '..label)
        check(math.abs(pixels[1][1]-expected)<=2,'GPU premultiplied RGB '..label)
        local peek_pixels=capture(peek.name,'peek-'..label)
        local angle_pixels=capture(peek_angle.name,'peek-angle-'..label)
        local wipe_pixels={
            horizontal=capture(wipe_horizontal.name,'wipe-horizontal-'..label),
            vertical=capture(wipe_vertical.name,'wipe-vertical-'..label),
            diagonal=capture(wipe_diagonal.name,'wipe-diagonal-'..label),
            angle=capture(wipe_angle.name,'wipe-angle-'..label),
        }
        if label=='half' or label=='ending' then
            check(peek.data.alpha==1,'Peek opacity unchanged '..label)
            check(math.abs(peek_pixels[1][4]-128)<=2 and peek_pixels[2][4]==0
                    and peek_pixels[3][4]==0 and peek_pixels[4][4]==0,
                'Peek clips translated pixels inside original bounds '..label)
            check(peek_angle.data.alpha==1,'Custom-angle Peek opacity unchanged '..label)
            check(angle_pixels[1][4]==0 and angle_pixels[2][4]==0
                    and angle_pixels[3][4]==255 and math.abs(angle_pixels[4][4]-128)<=2,
                'Custom 0/180 degree Peek moves vertically and clips '..label)
            local reference=snapshots.visible
            check(wipe_horizontal.data.alpha==1 and wipe_vertical.data.alpha==1
                    and wipe_diagonal.data.alpha==1 and wipe_angle.data.alpha==1,
                'Wipe changes only its boundary, not opacity '..label)
            check_wipe_mask(wipe_pixels.horizontal,{1,3},{2},reference,
                'Horizontal Wipe '..label)
            check_wipe_mask(wipe_pixels.vertical,{3},{1,2},reference,
                'Vertical Wipe '..label)
            check_wipe_mask(wipe_pixels.diagonal,{1,5,7},{8},reference,
                'Diagonal Wipe '..label)
            check_wipe_mask(wipe_pixels.angle,{3,7},{1,2,5,8},reference,
                'Custom-angle Wipe '..label)
            if not reference then snapshots['wipe-half']=wipe_pixels end
        elseif label=='visible' then
            check(peek.data.alpha==1,'Peek opacity unchanged '..label)
            check(peek_pixels[1][4]==255 and math.abs(peek_pixels[2][4]-128)<=1
                    and peek_pixels[3][4]==255 and peek_pixels[4][4]==0,
                'Peek normal position preserves original alpha')
            check(angle_pixels[1][4]==255 and math.abs(angle_pixels[2][4]-128)<=1
                    and angle_pixels[3][4]==255 and angle_pixels[4][4]==0,
                'Custom-angle Peek normal position preserves original alpha')
            for name,wipe_capture in pairs(wipe_pixels) do
                for index=1,#pixels do check(same_pixel(wipe_capture[index],pixels[index]),
                    'Fully visible '..name..' Wipe preserves source pixel '..index) end
            end
            local half=snapshots['wipe-half']
            check(half~=nil,'Captured Wipe In halfway pixels')
            check_wipe_mask(half.horizontal,{1,3},{2},pixels,'Horizontal Wipe half')
            check_wipe_mask(half.vertical,{3},{1,2},pixels,'Vertical Wipe half')
            check_wipe_mask(half.diagonal,{1,5,7},{8},pixels,'Diagonal Wipe half')
            check_wipe_mask(half.angle,{3,7},{1,2,5,8},pixels,'Custom-angle Wipe half')
        end
        snapshots[label]=pixels
    end
end
local function on_render()
    local ok,reason=xpcall(render,debug.traceback)
    if not ok then write_result(false,reason) end
end
local function cleanup()
    if cleanup_frame then
        cleanup_frame = cleanup_frame + 1
        if cleanup_frame == 4 then
            -- Several actual video ticks have passed since render removal.
            -- Python still fences the destroy queue and checks ALL sources.
            publish('verification/cleanup-ready.txt','READY\n')
            publish('verification/test-result.txt',outcome)
        end
        return
    end
    if render_registered then
        obs.obs_remove_main_render_callback(on_render)
        render_registered = false
    end
    obs.obs_set_output_source(0,nil)
    -- Release our references while the script and its source definitions live.
    -- Parent destruction removes attached filters via the normal OBS path.
    -- Canvas owns a scene-source reference; remove it before releasing the scene.
    if scene_a then
        obs.obs_source_remove(obs.obs_scene_get_source(scene_a))
        obs.obs_scene_release(scene_a); scene_a = nil
    end
    if scene_b then
        obs.obs_source_remove(obs.obs_scene_get_source(scene_b))
        obs.obs_scene_release(scene_b); scene_b = nil
    end
    while #resources > 0 do
        obs.obs_source_release(table.remove(resources))
    end
    cleanup_frame = 1
end
function script_load()
    local ok,reason=xpcall(load_product,debug.traceback)
    -- dofile changes exports; restore this harness's per-frame driver below.
    script_tick=function(dt)
        if cleanup_failed then return end -- never retry a partly failed release
        local request=io.open('verification/cleanup-request.txt','r')
        if request then
            request:close()
            if not done then write_result(false,'Test interrupted before completion') end
        end
        if not scene_a and not done then
            local success,why=xpcall(setup,debug.traceback)
            if not success then write_result(false,why) end
        end
        if original_tick then
            local success,why=xpcall(original_tick,debug.traceback)
            if not success then fail_cleanup(why); return end
        end
        local success,why=xpcall(function() step(dt) end,debug.traceback)
        if not success then write_result(false,why) end
        if done then
            success,why=xpcall(cleanup,debug.traceback)
            if not success then fail_cleanup(why) end
        end
    end
    script_unload=function()
        -- Do not hide errors in OBS's unchecked script_unload lua_pcall.
        local success,why=xpcall(function()
            assert(not cleanup_failed,'A cleanup error occurred after the test checks')
            assert(cleanup_frame and cleanup_frame>=4,'Host unloaded before cleanup handshake')
            if original_unload then original_unload() end
        end,debug.traceback)
        publish('verification/unload-result.txt',success and 'PASS\n' or ('FAIL: '..tostring(why)))
    end
    if not ok then write_result(false,reason)
    else obs.obs_add_main_render_callback(on_render); render_registered = true end
end
