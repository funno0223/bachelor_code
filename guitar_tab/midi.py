"""Convert a MIDI melody to the integer-note OPL data format."""

from dataclasses import dataclass
from pathlib import Path

from mido import MidiFile, bpm2tempo, tempo2bpm

OPEN_STRING_PITCHES = (64, 59, 55, 50, 45, 40)
PITCH_CLASSES = ("C", "Cs", "D", "Ds", "E", "F", "Fs", "G", "Gs", "A", "As", "B")
REST = 0
REST_THRESHOLD_MS = 50
MIN_TRANSITION_MS = 30
TRANSITION_RATIO = 0.6


@dataclass(frozen=True)
class TimedNote:
    pitch: int
    start_ms: int
    end_ms: int


def read_notes(track, milliseconds_per_tick):
    tick = 0
    active = {}
    notes = []
    for message in track:
        tick += message.time
        if message.type not in {"note_on", "note_off"}:
            continue
        key = message.channel, message.note
        if message.type == "note_on" and message.velocity > 0:
            active[key] = tick
        elif key in active:
            notes.append((active.pop(key), tick, message.note))

    notes.sort(key=lambda note: note[0])
    return [
        TimedNote(pitch, int(start * milliseconds_per_tick), int(end * milliseconds_per_tick))
        for start, end, pitch in notes
    ]


def melody_events(notes):
    pitches = []
    transition_times = []
    durations = []
    for index, note in enumerate(notes):
        duration = note.end_ms - note.start_ms
        movement_time = max(int(duration * TRANSITION_RATIO), MIN_TRANSITION_MS)
        gap = notes[index + 1].start_ms - note.end_ms if index + 1 < len(notes) else 0

        pitches.append(note.pitch)
        durations.append(duration)
        if gap > REST_THRESHOLD_MS:
            transition_times.append(MIN_TRANSITION_MS)
            pitches.append(REST)
            durations.append(gap)
            transition_times.append(gap)
        else:
            transition_times.append(movement_time + max(0, gap))

    return pitches, transition_times, durations


def opl_instrument():
    fret_count = 22
    pitches = [REST, *range(min(OPEN_STRING_PITCHES), max(OPEN_STRING_PITCHES) + fret_count + 1)]
    open_strings = []
    combinations = []
    for pitch in pitches:
        positions = [
            (string, pitch - base)
            for string, base in enumerate(OPEN_STRING_PITCHES, start=1)
            if 0 <= pitch - base <= fret_count
        ]
        open_strings.append("{" + ",".join(str(string) for string, fret in positions if fret == 0) + "}")
        combinations.append("{" + ",".join(f"<{string},{fret}>" for string, fret in positions) + "}")

    names = [f'"{PITCH_CLASSES[pitch % 12]}{pitch // 12 - 1}"' for pitch in range(128)]
    lines = [
        f"f_max = {fret_count};",
        f"s_max = {len(OPEN_STRING_PITCHES)};",
        "p_max = 17;",
        "PlayableSounds = {" + ",".join(map(str, pitches)) + "};",
        "OpenStrings = [" + ",".join(open_strings) + "];",
        "Combinations = [" + ",".join(combinations) + "];",
        "MidiNames = [" + ",".join(names) + "];",
    ]
    return pitches, lines


def prepare_data(midi_path: Path, config: Path, *, track_number=None, bpm=None):
    midi = MidiFile(midi_path)
    if midi.ticks_per_beat <= 0:
        raise ValueError("The MIDI file must use ticks per quarter note (PPQN).")

    tempo = 500_000
    signature = "4/4"
    for track in midi.tracks:
        for message in track:
            if message.type == "set_tempo":
                tempo = message.tempo
            elif message.type == "time_signature":
                signature = f"{message.numerator}/{message.denominator}"
    if bpm is not None:
        tempo = bpm2tempo(bpm)
    if tempo <= 0:
        raise ValueError("The MIDI tempo must be greater than zero.")

    if track_number is None:
        track_number = next(
            (number for number, track in enumerate(midi.tracks, start=1)
             if any(message.type == "note_on" and message.velocity > 0 for message in track)),
            0,
        )
        if track_number == 0:
            raise ValueError("No note-on events were found in the MIDI file.")
    elif not 1 <= track_number <= len(midi.tracks):
        raise ValueError(f"Track number must be between 1 and {len(midi.tracks)}.")

    notes = read_notes(midi.tracks[track_number - 1], tempo / midi.ticks_per_beat / 1000)
    if not notes:
        raise ValueError(f"No complete notes were found in MIDI track {track_number}.")

    playable, instrument = opl_instrument()
    invalid = sorted({note.pitch for note in notes if note.pitch == REST or note.pitch not in playable})
    if invalid:
        raise ValueError(f"MIDI pitches outside the guitar range ({playable[1]}–{playable[-1]}): {invalid}")

    pitches, transition_times, durations = melody_events(notes)
    return "\n".join([
        f"// MIDI tracks: {len(midi.tracks)}; selected track: {track_number}",
        f"// Ticks per beat: {midi.ticks_per_beat}",
        f"// Tempo: {tempo}",
        f"// BPM: {tempo2bpm(tempo):.6g}",
        f"// Time signature: {signature}",
        "",
        *instrument,
        "",
        f"m = {len(pitches)};",
        "note = [" + ",".join(map(str, pitches)) + "]; // 0 = rest",
        "availableTime = [" + ",".join(map(str, transition_times)) + "];",
        "// Duration ms: [" + ",".join(map(str, durations)) + "]",
        "",
        config.read_text(encoding="utf-8-sig").strip(),
        "",
    ])
