"""Read OPL results and render six-string text tablature."""

import math
import re
from dataclasses import dataclass
from pathlib import Path

HEADER = re.compile(r"Note\s+String\s+Fret\s+Handposition\s+Finger(?:\s|$)")
ROW = re.compile(r"(\S+)\s+(\d+)\s+(\d+)\s+\d+\s+([0-4xX])(?:\s+\S+)?")
LABELS = ("Rhythm: ", "e|", "B|", "G|", "D|", "A|", "E|", "Finger: ")
RHYTHMS = (
    ("w", 4), ("h.", 3), ("h", 2), ("q.", 1.5), ("q", 1), ("e.", 0.75),
    ("et", 2 / 3), ("e", 0.5), ("s.", 0.375), ("st", 1 / 3), ("s", 0.25),
    ("sst", 1 / 6), ("t", 0.125),
)


@dataclass(frozen=True)
class Fingering:
    note: str
    string: int
    fret: int
    finger: str


def parse_times(match, field):
    values = [float(value) for value in match[1].split(",") if value.strip()]
    if not values or any(not math.isfinite(value) or value < 0 for value in values):
        raise ValueError(f"{field} must contain non-negative times in milliseconds.")
    return values


def read_timing(data_path: Path):
    content = data_path.read_text(encoding="utf-8-sig")
    bpm_match = re.search(r"(?m)^\s*//\s*BPM(?: of the MIDI file)?\s*:\s*([^\s]+)", content)
    bpm = float(bpm_match[1]) if bpm_match else 120.0
    if not math.isfinite(bpm) or bpm <= 0:
        raise ValueError(f"Invalid BPM in {data_path}.")

    transitions = re.search(r"(?m)^[ \t]*availableTime\s*=\s*\[([^]]*)\]\s*;", content)
    if transitions is None:
        raise ValueError(f"availableTime was not found in {data_path}.")
    transition_times = parse_times(transitions, "availableTime")
    durations = re.search(r"(?m)^[ \t]*//\s*Duration ms:\s*\[([^]]*)\]", content)
    if durations is None:
        return bpm, transition_times, True
    duration_times = parse_times(durations, "Duration ms")
    if len(duration_times) != len(transition_times):
        raise ValueError(f"Duration ms and availableTime have different lengths in {data_path}.")
    return bpm, duration_times, False


def read_fingerings(solution_path: Path):
    fingerings = []
    with solution_path.open(encoding="utf-8-sig", errors="replace") as log:
        for line in log:
            if HEADER.match(line.strip()):
                break
        else:
            raise ValueError(f"No fingering table was found in {solution_path}.")

        for line in log:
            line = line.strip()
            if line.startswith(("---", "Objective:", "Cost Breakdown", "Total Cost", "main returns")):
                break
            if not line:
                if fingerings:
                    break
                continue
            row = ROW.fullmatch(line)
            if row is None:
                raise ValueError(f"Invalid fingering row in {solution_path}: {line}")
            note, string_text, fret_text, finger = row.groups()
            string, fret = int(string_text), int(fret_text)
            if note != "R" and not 1 <= string <= 6:
                raise ValueError(f"Invalid string number in {solution_path}: {string}")
            fingerings.append(Fingering(note, string, fret, finger.lower()))

    if not fingerings:
        raise ValueError(f"The fingering table in {solution_path} is empty.")
    return fingerings


def rhythm_label(milliseconds, quarter_note_ms):
    beats = milliseconds / quarter_note_ms
    symbol, ideal_beats = min(RHYTHMS, key=lambda rhythm: abs(rhythm[1] - beats))
    return symbol if abs(ideal_beats - beats) <= 0.30 * ideal_beats else "?"


def render_tab(data_path: Path, solution_path: Path):
    bpm, times, uses_transition_times = read_timing(data_path)
    fingerings = read_fingerings(solution_path)
    if len(times) != len(fingerings):
        raise ValueError(f"Data has {len(times)} events but the solution has {len(fingerings)} fingerings.")

    rest_count = sum(fingering.note == "R" for fingering in fingerings)
    sections = [
        f"Guitar tablature ({bpm:g} BPM)",
        f"Notes: {len(fingerings) - rest_count} | Rests: {rest_count}",
        "sN = slide to fret N; R = rest; ? = unclassified duration",
    ]
    if uses_transition_times:
        sections.append("Rhythm is estimated from availableTime in this legacy data file.")

    label_width = max(map(len, LABELS))
    labels = [label.rjust(label_width) for label in LABELS]
    lines = labels.copy()
    previous = None
    for index, (milliseconds, fingering) in enumerate(zip(times, fingerings)):
        rhythm = rhythm_label(milliseconds, 60_000 / bpm)
        if uses_transition_times and index == 0 and milliseconds == 1000:
            rhythm = "START"

        cells = [rhythm, "", "", "", "", "", "", fingering.finger]
        if fingering.note == "R":
            cells[0] += "(R)"
            cells[-1] = ""
        else:
            slide = (
                previous is not None and previous.note != "R"
                and previous.string == fingering.string and previous.fret != fingering.fret
                and previous.finger == fingering.finger and fingering.finger in "1234"
            )
            cells[fingering.string] = f"s{fingering.fret}" if slide else str(fingering.fret)

        width = max(4, max(map(len, cells)) + 1)
        if len(lines[0]) + width > 78:
            sections.append("\n" + "\n".join(lines))
            lines = labels.copy()
        lines = [line + cell.ljust(width, "-") for line, cell in zip(lines, cells)]
        previous = fingering

    sections.append("\n" + "\n".join(lines))
    return "\n".join(sections)
