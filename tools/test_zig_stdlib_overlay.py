"""Exercise cache publication and source integrity without changing a compiler."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("overlay", Path(__file__).with_name("zig_stdlib_overlay.py"))
OVERLAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OVERLAY)


class OverlayCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zircon-overlay-test-")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.library = root / "lib"
        (self.library / "std/Io").mkdir(parents=True)
        self.spawn = self.library / "std/Io/Threaded.zig"
        self.spawn.write_text("fn spawnDarwin() void {\n        .START_SUSPENDED = start_suspended,\n}\n")
        self.other = self.library / "std/other.zig"
        self.other.write_text("first version\n")
        self.compiler = root / "compiler"
        environment = '.{\n    .lib_dir = "' + str(self.library) + '",\n}'
        self.compiler.write_text("#!/usr/bin/env python3\nprint(" + repr(environment) + ")\n")
        self.compiler.chmod(0o755)
        original_location = OVERLAY.__file__
        OVERLAY.__file__ = str(root / "project/tools/zig_stdlib_overlay.py")
        self.addCleanup(setattr, OVERLAY, "__file__", original_location)

    def test_complete_cache_reused_and_original_library_unchanged(self):
        before = self.spawn.read_bytes()
        first = OVERLAY.prepare(self.compiler)
        self.assertEqual(first, OVERLAY.prepare(self.compiler))
        self.assertEqual(before, self.spawn.read_bytes())
        self.assertIn(b".CLOEXEC_DEFAULT = true", (first / "std/Io/Threaded.zig").read_bytes())

    def test_non_spawn_source_update_creates_a_fresh_copy(self):
        first = OVERLAY.prepare(self.compiler)
        self.other.write_text("second version\n")
        second = OVERLAY.prepare(self.compiler)
        self.assertNotEqual(first, second)
        self.assertEqual("second version\n", (second / "std/other.zig").read_text())

    def test_corrupt_cached_library_is_rejected(self):
        cached = OVERLAY.prepare(self.compiler)
        (cached / "std/other.zig").write_text("corruption\n")
        with self.assertRaisesRegex(RuntimeError, "Cached Darwin isolation overlay changed"):
            OVERLAY.prepare(self.compiler)

    def test_unknown_spawn_source_is_rejected(self):
        self.spawn.write_text("unknown implementation\n")
        with self.assertRaisesRegex(RuntimeError, "Pinned Darwin spawn implementation changed"):
            OVERLAY.prepare(self.compiler)


if __name__ == "__main__":
    unittest.main()
