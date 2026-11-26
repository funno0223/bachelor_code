import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.data = self.directory / "demo.dat"

    def cli(self, *args):
        return subprocess.run(
            [sys.executable, "-m", "guitar_tab", *map(str, args)],
            cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace",
        )

    def prepare(self):
        result = self.cli("prepare", ROOT / "examples/demo.mid", "-o", self.data)
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.data.read_text(encoding="utf-8")

    def test_prepare_and_tab_keep_transition_times_and_durations_aligned(self):
        data = self.prepare()
        self.assertIn("note = [40,41,0,43,45];", data)
        self.assertIn("availableTime = [300,30,250,150,300];", data)
        self.assertIn("// Duration ms: [500,250,250,250,500]", data)
        for parameter in ("stringAction12thMm", "d_AT", "alpha_AT", "d_SC", "alpha_SC"):
            self.assertIn(f"{parameter} =", data)

        tab = self.cli("tab", self.data, ROOT / "examples/demo-fingerings.txt")
        self.assertEqual(tab.returncode, 0, tab.stderr)
        self.assertIn("Notes: 4 | Rests: 1", tab.stdout)
        self.assertIn("Rhythm: q---e---e(R)-e---q---", tab.stdout)

        duplicate = self.cli("prepare", ROOT / "examples/demo.mid", "-o", self.data)
        self.assertNotEqual(duplicate.returncode, 0)
        self.assertEqual(self.data.read_text(encoding="utf-8"), data)

    def test_legacy_table_with_angle_and_open_string_marker(self):
        self.data.write_text("// BPM of the MIDI file: 90\navailableTime = [1000, 300.5];\n")
        log = self.directory / "legacy.log"
        log.write_text(
            "Note String Fret Handposition Finger EffAngle\n"
            "E2 6 0 1 x 0\nF2 6 1 1 1 -5\n\n--- Cost Breakdown ---\n"
        )
        result = self.cli("tab", self.data, log)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("90 BPM", result.stdout)
        self.assertIn("START", result.stdout)

        self.data.write_text("availableTime = [1000];\n")
        mismatch = self.cli("tab", self.data, log)
        self.assertNotEqual(mismatch.returncode, 0)
        self.assertIn("the solution has 2 fingerings", mismatch.stderr)

    def test_solver_requires_a_fingering_table_even_on_zero_exit(self):
        self.prepare()
        program = self.directory / "fake solver.mod"
        program.write_text("print('No solution')\n")
        log = self.directory / "solver log.txt"
        result = self.cli("solve", self.data, "--model", program, "--oplrun", sys.executable, "-o", log)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No fingering table", result.stderr)
        self.assertEqual(log.read_text().strip(), "No solution")
