#!/usr/bin/env python3
import pathlib
import subprocess
import sys
import tempfile
import unittest

from migrate_ui_callbacks import old_calls


class MigrationTests(unittest.TestCase):
    def test_strings_and_nested_comments_are_not_calls(self):
        source = '''const label = "b.onClickWith(value, callback)";
// b.onInputWith(value, callback)
/* b.onClickWith(value, /* nested */ callback) */
\\\\b.onClickWith(value, callback)
const actual = b.onClickWith(value /* , /* nested */ , */, callback);
'''
        calls = list(old_calls(source))
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][1], ".onClickWith( callback, value /* , /* nested */ , */)")

    def test_line_comment_newline_and_trailing_comma_survive(self):
        source = "b.onClickWith(value, callback // keep this newline\n)"
        replacement = list(old_calls(source))[0][1]
        self.assertIn("// keep this newline\n, value)", replacement)
        self.assertEqual(list(old_calls("b.onClickWith(value, callback,)"))[0][1], ".onClickWith( callback, value,)")

    def test_cli_migrates_code_only_and_is_idempotent(self):
        script = pathlib.Path(__file__).with_name("migrate_ui_callbacks.py").resolve()
        with tempfile.TemporaryDirectory(prefix="zircon-callback-migration-") as directory:
            root = pathlib.Path(directory)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, text=True)
            git("init", "--quiet")
            git("config", "user.name", "Migration test")
            git("config", "user.email", "migration@example.invalid")
            path = root / "example.zig"
            label = 'const label = "b.onClickWith(value, callback)";\n'
            comment = '// b.onClickWith(value, callback)\n'
            path.write_text(label + comment + "const handler = b.onClickWith(value, callback);\n")
            git("add", "example.zig")
            git("commit", "--quiet", "-m", "fixture")
            revision = git("rev-parse", "HEAD").strip()
            command = [sys.executable, str(script), "--from", revision]
            subprocess.run(command, cwd=root, check=True, capture_output=True)
            actual = path.read_text()
            self.assertEqual(actual, label + comment + "const handler = b.onClickWith( callback, value);\n")
            subprocess.run(command, cwd=root, check=True, capture_output=True)
            self.assertEqual(actual, path.read_text())
            subprocess.run(command + ["--check"], cwd=root, check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
