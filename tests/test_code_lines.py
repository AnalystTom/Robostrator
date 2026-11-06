"""Exercise the public line checker against real throwaway Git repositories."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

CHECK = pathlib.Path(__file__).resolve().parents[1] / 'bin/fm-code-lines.py'


class CodeLinesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        self.baseline({})

    def baseline(self, data):
        (self.root / '.code-lines.json').write_text(json.dumps(data))

    def source(self, name, lines, newline=True):
        path = self.root / name
        path.write_bytes(b'x\n' * (lines - 1) + (b'x\n' if newline else b'x'))

    def run_check(self, expected):
        p = subprocess.run([sys.executable, str(CHECK), '--root', str(self.root)], text=True, capture_output=True)
        self.assertEqual(p.returncode, expected, p.stdout + p.stderr)
        return p.stdout

    def test_limit_and_unterminated_last_line(self):
        self.source('file with spaces.py', 1000, newline=False)
        self.run_check(0)
        self.source('file with spaces.py', 1001, newline=False)
        self.assertIn('1001 lines exceeds 1000', self.run_check(1))

    def test_existing_ceiling_must_tighten_and_cannot_grow(self):
        self.baseline({'old.sh': 1200})
        self.source('old.sh', 1200)
        self.run_check(0)
        self.source('old.sh', 1201)
        self.run_check(1)
        self.source('old.sh', 1100)
        self.assertIn('lower its legacy ceiling to 1100', self.run_check(1))
        self.baseline({'old.sh': 1100})
        self.run_check(0)
        self.source('old.sh', 1000)
        self.assertIn('remove its legacy entry', self.run_check(1))
        self.baseline({})
        self.run_check(0)

    def test_ignored_and_noncode_files(self):
        (self.root / '.gitignore').write_text('ignored.py\n')
        self.source('ignored.py', 1001)
        self.source('manual.md', 1001)
        self.run_check(0)
        subprocess.run(['git', '-C', str(self.root), 'add', '-f', 'ignored.py'], check=True)
        self.run_check(1)

    def test_shebang_and_source_symlink(self):
        (self.root / 'tool').write_bytes(b'#!/bin/sh\n' + b'echo ok\n' * 1000)
        self.run_check(1)
        (self.root / 'tool').unlink()
        (self.root / 'outside.py').symlink_to('/does-not-exist')
        self.assertIn('source symlink', self.run_check(1))

    def test_stale_and_invalid_baseline(self):
        self.baseline({'missing.go': 1200})
        self.assertIn('stale', self.run_check(1))
        self.baseline({'file.go': True})
        self.run_check(1)
        (self.root / '.code-lines.json').write_text('{')
        self.run_check(1)


if __name__ == '__main__':
    unittest.main()
