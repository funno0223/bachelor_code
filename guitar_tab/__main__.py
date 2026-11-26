"""Run with python -m guitar_tab."""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

from .tablature import read_fingerings, render_tab

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODEL = ROOT / "models" / "modified_model.mod"
DEFAULT_CONFIG = ROOT / "config" / "optimization.dat"


def write_output(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8", newline="\n") as output:
        output.write(content)


def solve(data_path, model_path, output_path, oplrun):
    executable = shutil.which(oplrun or os.environ.get("OPLRUN") or "oplrun")
    if executable is None:
        raise ValueError("oplrun was not found. Add it to PATH or pass --oplrun with its full path.")
    for path in (model_path, data_path):
        if not path.is_file():
            raise FileNotFoundError(f"Input file was not found: {path}")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("xb") as log:
        print(f"Running OPL. Log: {output_path}", file=sys.stderr, flush=True)
        result = subprocess.run(
            [str(Path(executable).resolve()), str(model_path.resolve()), str(data_path.resolve())],
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        )
    if result.returncode:
        raise ValueError(f"oplrun exited with code {result.returncode}. See {output_path}.")
    read_fingerings(output_path)


def main():
    parser = argparse.ArgumentParser(description="Generate guitar tablature from MIDI using CPLEX/OPL.")
    commands = parser.add_subparsers(dest="command", required=True)

    prepare = commands.add_parser("prepare", help="convert MIDI to OPL data")
    prepare.add_argument("midi", type=Path, help="input MIDI file")
    prepare.add_argument("-o", "--output", required=True, type=Path, help="new .dat file")
    prepare.add_argument("--track", type=int, help="1-based melody track number")
    prepare.add_argument("--bpm", type=int, help="override the detected tempo (positive integer)")
    prepare.add_argument("--config", type=Path, default=DEFAULT_CONFIG, help="OPL parameter file")

    optimize = commands.add_parser("solve", help="run oplrun and save its log")
    optimize.add_argument("data", type=Path, help="input .dat file")
    optimize.add_argument("-o", "--output", required=True, type=Path, help="new solver log file")
    optimize.add_argument("--model", type=Path, default=DEFAULT_MODEL, help="OPL model file")
    optimize.add_argument("--oplrun", help="path to the oplrun executable")

    tab = commands.add_parser("tab", help="render an existing solution as text tablature")
    tab.add_argument("data", type=Path, help="the .dat file used for the solve")
    tab.add_argument("solution", type=Path, help="solver log containing a fingering table")
    tab.add_argument("-o", "--output", type=Path, help="new tab file (default: print to stdout)")

    args = parser.parse_args()
    try:
        if args.command == "prepare":
            if args.bpm is not None and args.bpm <= 0:
                raise ValueError("BPM must be greater than zero.")
            from .midi import prepare_data

            content = prepare_data(args.midi, args.config, track_number=args.track, bpm=args.bpm)
            write_output(args.output, content)
        elif args.command == "solve":
            solve(args.data, args.model, args.output, args.oplrun)
        else:
            content = render_tab(args.data, args.solution)
            if args.output is None:
                print(content)
                return 0
            write_output(args.output, content + "\n")
    except (OSError, EOFError, ValueError) as error:
        parser.exit(1, f"error: {error}\n")
    except ModuleNotFoundError as error:
        if error.name != "mido":
            raise
        parser.exit(1, "error: Install MIDI support with python -m pip install -r requirements.txt.\n")

    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
