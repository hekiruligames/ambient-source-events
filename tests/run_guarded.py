"""Build and run one isolated OBS test behind the native crash guard."""
import argparse
import ctypes
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'verification'


def build_guard(path):
    subprocess.run(['clang', '-dynamiclib', '-O2', '-o', str(path),
                    str(ROOT / 'tests/native_guard.c')], check=True)


def run_child(argv, env, log_path, timeout):
    with log_path.open('w') as log:
        child = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=log,
                                 stderr=subprocess.STDOUT, text=True)
        try:
            return child.wait(timeout=timeout), False
        except subprocess.TimeoutExpired:
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()
            return child.returncode, True


def log_has_lua_error(log_path):
    needles = ('Failed to call', 'Error calling', 'Error running file', 'Error loading')
    prefixes = ('[Lua:', '[obs-scripting]')
    for line in log_path.read_text(errors='replace').splitlines():
        if any(prefix in line for prefix in prefixes) and any(needle in line for needle in needles):
            return True
    return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--signal', choices=('SIGSEGV', 'SIGBUS', 'SIGABRT'))
    parser.add_argument('--timeout', type=float, default=120)
    parser.add_argument('script', nargs='?')
    parser.add_argument('script_args', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.self_test and not args.script:
        parser.error('script is required unless --self-test is used')
    stamp = time.strftime('%Y%m%d-%H%M%S') + '-' + str(time.time_ns())
    run_dir = OUT / 'guarded-runs' / stamp
    run_dir.mkdir(parents=True, exist_ok=False)
    guard = run_dir / 'native_guard.dylib'
    marker = run_dir / 'crash-marker.txt'
    build_guard(guard)
    env = os.environ.copy()
    env['OBS_NATIVE_GUARD_LIB'] = str(guard)
    env['OBS_NATIVE_GUARD_MARKER'] = str(marker)
    env['DYLD_LIBRARY_PATH'] = '/Applications/OBS.app/Contents/Frameworks'
    if args.self_test:
        guard_setup = (
            'import ctypes, os\n'
            'g=ctypes.CDLL(os.environ["OBS_NATIVE_GUARD_LIB"])\n'
            'g.native_guard_install.argtypes=[ctypes.c_char_p]\n'
            'g.native_guard_install.restype=ctypes.c_int\n'
            'ok=g.native_guard_install(os.environ["OBS_NATIVE_GUARD_MARKER"].encode())\n'
            'if not ok: raise RuntimeError("native guard installation failed")\n'
        )
        if args.signal:
            code = (guard_setup + 'import os, signal\n'
                    f'os.kill(os.getpid(), signal.{args.signal})')
        else:
            code = guard_setup + 'import time\ntime.sleep(3600)'
        command = [sys.executable, '-c', code]
    else:
        command = [sys.executable, str(ROOT / 'tests/run_obs.py'), args.script] + args.script_args
    process_result = OUT / 'process-result.txt'
    if not args.self_test and process_result.exists():
        (run_dir / 'previous-process-result.txt').write_text(process_result.read_text())
        process_result.unlink()
    return_code, timed_out = run_child(command, env, run_dir / 'child.log', args.timeout)
    child_log = run_dir / 'child.log'
    result = process_result.read_text().strip() if process_result.exists() else ''
    marker_text = marker.read_text().strip() if marker.exists() else ''
    if args.self_test and args.signal:
        expected = 128 + getattr(signal, args.signal)
        if timed_out or return_code != expected or not marker_text.startswith('FAIL:'):
            message = f'FAIL: guard self-test {args.signal} (not OBS acceptance)'
        else:
            message = f'PASS: guard self-test {args.signal} (not OBS acceptance)'
    elif args.self_test:
        if timed_out and return_code != 0 and marker.exists() and not marker_text:
            message = 'PASS: guard self-test timeout (not OBS acceptance)'
        else:
            message = 'FAIL: guard self-test timeout (not OBS acceptance)'
    elif timed_out:
        message = 'FAIL: guarded child timed out'
    elif marker_text:
        message = f'FAIL: native crash marker (exit {return_code}): {marker_text}'
    elif return_code != 0:
        message = f'FAIL: guarded child exited {return_code}'
    elif not args.self_test and log_has_lua_error(child_log):
        message = 'FAIL: child log contains Lua/OBS scripting error'
    elif not result.startswith('PASS:') or not marker.exists() or marker_text:
        message = 'FAIL: process-result.txt is missing or not PASS'
    else:
        message = f'PASS: guarded child completed ({run_dir})'
    message = f'{message} [run_dir={run_dir}]'
    (run_dir / 'wrapper-result.txt').write_text(message + '\n')
    print(message)
    raise SystemExit(0 if message.startswith('PASS:') else 2)


if __name__ == '__main__':
    main()
