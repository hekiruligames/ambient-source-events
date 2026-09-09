"""Host teardown regression tests using only Python's standard library.

Does not import ctypes, run_obs, or any OBS library.
"""
import unittest

from shutdown import shutdown


class Runtime:
    def __init__(self, fail_at=None):
        self.calls = []
        self.fail_at = fail_at

    def __getattr__(self, name):
        def operation():
            self.calls.append(name)
            if name == self.fail_at or (name, self.calls.count(name)) == self.fail_at:
                raise RuntimeError(name)
        return operation


class TeardownTests(unittest.TestCase):
    def test_sources_destroyed_before_script_and_subsystem(self):
        runtime = Runtime()
        shutdown(runtime)
        self.assertLess(runtime.calls.index('require_no_sources'), runtime.calls.index('destroy_script'))
        self.assertLess(runtime.calls.index('verify_unload'), runtime.calls.index('unload_scripting'))
        self.assertEqual(runtime.calls[-1], 'shutdown_core')
        self.assertEqual(runtime.calls.count('require_no_sources'), 2)
        self.assertEqual(runtime.calls.count('drain'), 2)

    def test_any_failed_prerequisite_stops_teardown(self):
        # In particular, leaked sources or an unreported Lua unload error must
        # never be followed by freeing callback storage or obs_shutdown.
        for point in ('disconnect_audio', 'await_cleanup', 'drain', 'require_no_sources',
                      'destroy_script', 'verify_unload', 'unload_scripting'):
            with self.subTest(point=point):
                runtime = Runtime(point)
                with self.assertRaisesRegex(RuntimeError, point):
                    shutdown(runtime)
                self.assertEqual(runtime.calls[-1], point)
                self.assertNotIn('shutdown_core', runtime.calls)

    def test_failure_after_script_destroy_keeps_callback_storage_alive(self):
        for point in ('drain', 'require_no_sources'):
            with self.subTest(point=point):
                runtime = Runtime((point, 2))
                with self.assertRaisesRegex(RuntimeError, point):
                    shutdown(runtime)
                self.assertIn('destroy_script', runtime.calls)
                self.assertNotIn('unload_scripting', runtime.calls)
                self.assertNotIn('shutdown_core', runtime.calls)


if __name__ == '__main__':
    unittest.main()
