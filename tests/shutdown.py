"""Teardown policy; contains no OBS loading or native calls of its own."""


def shutdown(runtime):
    """Every failed prerequisite aborts; never cascade into unsafe cleanup."""
    runtime.disconnect_audio()
    runtime.await_cleanup()
    runtime.drain()
    runtime.require_no_sources()
    runtime.destroy_script()
    runtime.verify_unload()
    runtime.drain()
    runtime.require_no_sources()
    runtime.unload_scripting()
    runtime.shutdown_core()
