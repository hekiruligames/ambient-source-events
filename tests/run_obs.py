"""Run Lua tests in the installed OBS 32.0.4, without opening user settings.

DYLD_LIBRARY_PATH=/Applications/OBS.app/Contents/Frameworks \
  /opt/homebrew/bin/python3.11 tests/run_obs.py tests/unit.lua
Use --graphics to create an isolated 1080p60 OpenGL video context.
"""
import argparse
import ctypes as C
import bisect
import json
import os
import sys
from pathlib import Path
import time
from shutdown import shutdown

ROOT = Path(__file__).resolve().parents[1]
FRAMEWORKS = Path('/Applications/OBS.app/Contents/Frameworks')
OUT = ROOT / 'verification'


def require_native_guard():
    library = os.environ.get('OBS_NATIVE_GUARD_LIB')
    marker = os.environ.get('OBS_NATIVE_GUARD_MARKER')
    if not library or not marker or not Path(library).is_file():
        raise RuntimeError('Native guard environment is required')
    guard = C.CDLL(library)
    guard.native_guard_install.argtypes = [C.c_char_p]
    guard.native_guard_install.restype = C.c_int
    if not guard.native_guard_install(marker.encode()):
        raise RuntimeError('Native guard installation failed')
    return guard


def bind(lib, name, result, *arguments):
    fn = getattr(lib, name)
    fn.restype = result
    fn.argtypes = list(arguments)
    return fn


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('script')
    parser.add_argument('--graphics', action='store_true')
    parser.add_argument('--seconds', type=float, default=0)
    parser.add_argument('--modules', action='store_true')
    parser.add_argument('--audio', action='store_true')
    parser.add_argument('--reloads', type=int, default=0)
    args = parser.parse_args()
    native_guard = require_native_guard()
    OUT.mkdir(exist_ok=True)
    os.chdir(ROOT)
    os.environ['LUA_CPATH'] = '/Applications/OBS.app/Contents/PlugIns/?.so;;'
    core = C.CDLL(str(FRAMEWORKS / 'libobs.framework/libobs'), mode=C.RTLD_GLOBAL)
    scripting = C.CDLL(str(FRAMEWORKS / 'obs-scripting.dylib'), mode=C.RTLD_GLOBAL)
    startup = bind(core, 'obs_startup', C.c_bool, C.c_char_p, C.c_char_p, C.c_void_p)
    assert startup(b'ja-JP', str(OUT / 'runtime-config').encode(), None)
    version = bind(core, 'obs_get_version_string', C.c_char_p)().decode()
    assert version == '32.0.4', version
    print('OBS runtime:', version, flush=True)
    bind(core, 'obs_add_data_path', None, C.c_char_p)(
        str(FRAMEWORKS / 'libobs.framework/Resources').encode())
    class VideoInfo(C.Structure):
        _fields_ = [('graphics_module', C.c_char_p), ('fps_num', C.c_uint32),
                    ('fps_den', C.c_uint32), ('base_width', C.c_uint32),
                    ('base_height', C.c_uint32), ('output_width', C.c_uint32),
                    ('output_height', C.c_uint32), ('output_format', C.c_int),
                    ('adapter', C.c_uint32), ('gpu_conversion', C.c_bool),
                    ('colorspace', C.c_int), ('range', C.c_int), ('scale_type', C.c_int)]
    class AudioInfo(C.Structure):
        _fields_ = [('samples_per_sec', C.c_uint32), ('speakers', C.c_int)]
    script = None
    loaded = False
    graphics_ready = False
    managed_cleanup = Path(args.script).name in ('integration.lua', 'lifecycle.lua')
    result_path = OUT / 'test-result.txt'
    result_path.unlink(missing_ok=True)
    for filename in ('cleanup-request.txt', 'cleanup-ready.txt', 'unload-result.txt',
                     'process-result.txt', 'reload-request.txt', 'reload-unload.txt',
                     'lifecycle-stage.txt'):
        (OUT / filename).unlink(missing_ok=True)
    audio_callback = None
    audio_output = None
    audio_samples = []
    reload_count = 0
    try:
        if args.graphics:
            vi = VideoInfo(str(FRAMEWORKS / 'libobs-opengl.dylib').encode(),
                           60, 1, 1920, 1080, 1920, 1080, 6, 0, False, 2, 2, 2)
            result = bind(core, 'obs_reset_video', C.c_int, C.POINTER(VideoInfo))(C.byref(vi))
            assert result == 0, f'Graphics initialization failed: {result}'
            ai = AudioInfo(48000, 2)
            assert bind(core, 'obs_reset_audio', C.c_bool, C.POINTER(AudioInfo))(C.byref(ai))
            graphics_ready = True
        if args.modules:
            load_module = bind(core, 'obs_open_module', C.c_int,
                               C.POINTER(C.c_void_p), C.c_char_p, C.c_char_p)
            init_module = bind(core, 'obs_init_module', C.c_bool, C.c_void_p)
            for name in ('image-source', 'obs-filters', 'obs-ffmpeg', 'text-freetype2'):
                plugin = Path('/Applications/OBS.app/Contents/PlugIns') / (name + '.plugin')
                module = C.c_void_p()
                rc = load_module(C.byref(module), str(plugin / 'Contents/MacOS' / name).encode(),
                                 str(plugin / 'Contents/Resources').encode())
                assert rc == 0 and init_module(module), (name, rc)
        if args.audio:
            class AudioData(C.Structure):
                _fields_ = [('data', C.POINTER(C.c_uint8) * 8), ('frames', C.c_uint32), ('timestamp', C.c_uint64)]
            callback_type = C.CFUNCTYPE(None, C.c_void_p, C.c_size_t, C.POINTER(AudioData))

            @callback_type
            def audio_callback(_, mix, data):
                block = data.contents
                if not block.data[0]:
                    return
                samples = C.cast(block.data[0], C.POINTER(C.c_float))
                peak = max((abs(samples[i]) for i in range(block.frames)), default=0)
                audio_samples.append((block.timestamp, peak))

            audio_output = bind(core, 'obs_get_audio', C.c_void_p)()
            assert bind(core, 'audio_output_connect', C.c_bool, C.c_void_p, C.c_size_t,
                        C.c_void_p, callback_type, C.c_void_p)(audio_output, 0, None, audio_callback, None)
        assert bind(scripting, 'obs_scripting_load', C.c_bool)()
        loaded = True
        create = bind(scripting, 'obs_script_create', C.c_void_p, C.c_char_p, C.c_void_p)
        script = create(str(Path(args.script).resolve()).encode(), None)
        assert script and bind(scripting, 'obs_script_loaded', C.c_bool, C.c_void_p)(script)
        reload_script = bind(scripting, 'obs_script_reload', C.c_bool, C.c_void_p)
        deadline = time.monotonic() + args.seconds
        while time.monotonic() < deadline and not result_path.exists():
            request = OUT / 'reload-request.txt'
            if request.exists():
                assert reload_count < args.reloads, 'Unexpected reload request'
                request.unlink()
                (OUT / 'reload-unload.txt').unlink(missing_ok=True)
                assert reload_script(script), 'OBS script reload failed'
                assert bind(scripting, 'obs_script_loaded', C.c_bool, C.c_void_p)(script)
                unload = OUT / 'reload-unload.txt'
                reload_deadline = time.monotonic() + 5
                while not unload.exists() and time.monotonic() < reload_deadline:
                    time.sleep(0.02)
                assert unload.exists() and unload.read_text().strip() == 'PASS', \
                    'Reload unload result missing or failed'
                reload_count += 1
            time.sleep(0.05)
        assert result_path.exists(), 'No test result was produced (inspect the OBS log).'
        result = result_path.read_text()
        print(result, flush=True)
        assert result.startswith('PASS'), result
        assert reload_count == args.reloads, \
            f'Reload count mismatch: {reload_count} != {args.reloads}'
        if args.audio:
            trace = [json.loads(line) for line in (OUT / 'integration-trace.json').read_text().splitlines()]
            timestamps = [r['timestamp'] for r in trace]
            silent, audible = [], []
            for timestamp, peak in audio_samples:
                lo = bisect.bisect_left(timestamps, timestamp - 200_000_000)
                hi = bisect.bisect_right(timestamps, timestamp + 200_000_000)
                if lo == 0 or hi >= len(trace) or hi - lo < 10:
                    continue
                window = trace[lo:hi]
                if all(r['muted'] for r in window):
                    silent.append(peak)
                elif all(not r['muted'] and r['alpha'] > 0.1 for r in window):
                    audible.append(peak)
            report = {'silent_blocks': len(silent), 'max_muted_peak': max(silent, default=-1),
                      'audible_blocks': len(audible), 'max_audible_peak': max(audible, default=0),
                      'samples': audio_samples}
            (OUT / 'audio.json').write_text(json.dumps(report))
            assert len(silent) >= 10 and max(silent) <= 1e-6, report | {'samples': 'omitted'}
            assert len(audible) >= 10 and max(audible) > 0.01, report | {'samples': 'omitted'}
            print('PASS: actual mixed audio silence/restoration:', report | {'samples': 'omitted'}, flush=True)
    finally:
        class Runtime:
            def disconnect_audio(self):
                if audio_callback and audio_output:
                    bind(core, 'audio_output_disconnect', None, C.c_void_p, C.c_size_t,
                         callback_type, C.c_void_p)(audio_output, 0, audio_callback, None)

            def await_cleanup(self):
                if not managed_cleanup or not script:
                    return
                (OUT / 'cleanup-request.txt').write_text('STOP\n')
                deadline = time.monotonic() + 5
                ready = OUT / 'cleanup-ready.txt'
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                if not ready.exists():
                    raise RuntimeError('Lua cleanup did not acknowledge completion')
                if ready.read_text().strip() != 'READY':
                    raise RuntimeError(ready.read_text())

            def drain(self):
                if graphics_ready:
                    # A real video/audio/destruction queue fence, on the host
                    # thread, outside Lua callbacks. A second fence lets the
                    # product's following tick release deferred references.
                    wait = bind(core, 'obs_wait_for_destroy_queue', C.c_bool)
                    wait()
                    wait()

            def require_no_sources(self):
                names = []
                callback_type = C.CFUNCTYPE(C.c_bool, C.c_void_p, C.c_void_p)
                name_of = bind(core, 'obs_source_get_name', C.c_char_p, C.c_void_p)

                @callback_type
                def collect(_, source):
                    names.append((name_of(source) or b'<unnamed>').decode(errors='replace'))
                    return True

                # Includes private filters/scenes omitted by obs_enum_sources.
                bind(core, 'obs_enum_all_sources', None, callback_type, C.c_void_p)(collect, None)
                if names:
                    raise RuntimeError('Sources remain before teardown: ' + ', '.join(names))

            def destroy_script(self):
                if script:
                    bind(scripting, 'obs_script_destroy', None, C.c_void_p)(script)

            def verify_unload(self):
                if managed_cleanup and script:
                    result = OUT / 'unload-result.txt'
                    if not result.exists():
                        raise RuntimeError('Lua unload result missing')
                    if result.read_text().strip() != 'PASS':
                        raise RuntimeError(result.read_text())

            def unload_scripting(self):
                if loaded:
                    bind(scripting, 'obs_scripting_unload', None)()

            def shutdown_core(self):
                bind(core, 'obs_shutdown', None)()

        try:
            shutdown(Runtime())
        except BaseException as error:
            message = 'FAIL: teardown stopped before unsafe continuation: ' + repr(error)
            (OUT / 'process-result.txt').write_text(message + '\n')
            print(message, file=sys.stderr, flush=True)
            # Failure only: OS reclaims this isolated process. Do not run the
            # unsafe native destructors after a failed lifecycle prerequisite.
            # This is explicitly a failed test, never a successful leak bypass.
            sys.stdout.flush()
            os._exit(2)
    (OUT / 'process-result.txt').write_text('PASS: checks and native teardown completed\n')
    print('PASS: checks and native teardown completed', flush=True)


if __name__ == '__main__':
    main()
