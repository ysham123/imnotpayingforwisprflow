#!/usr/bin/env python3
"""Generate public synthetic WAV fixtures. Never reads microphone/user recordings.

The same generated files are passed unchanged to baseline and candidate. Speech
rate is adjusted, never cropped, to fit each duration; explicit pauses and
distributed silence fill the remaining frames. Speech reaches the end of long
fixtures instead of finishing early with a long silent tail.
"""
import argparse
import collections
import hashlib
import json
import pathlib
import subprocess
import tempfile
import wave

SAMPLE_RATE = 16_000


def load_definition(path):
    definition = json.loads(path.read_text())
    assert definition["schema"] == 1
    assert len({case["id"] for case in definition["cases"]}) == len(definition["cases"])
    for case in definition["cases"]:
        assert case["parts"]
        assert case["targetSeconds"] is None or 0 < case["targetSeconds"] <= 300
        for part in case["parts"]:
            assert part["passage"] in definition["passages"] and part["pauseAfter"] >= 0
    return definition


def read_pcm(path):
    with wave.open(str(path), "rb") as audio:
        assert audio.getframerate() == SAMPLE_RATE and audio.getnchannels() == 1
        assert audio.getsampwidth() == 2 and audio.getcomptype() == "NONE"
        if audio.getnframes() == 0:
            raise RuntimeError("macOS speech synthesis returned empty audio. Check the installed voice and access to the local speech service.")
        return audio.readframes(audio.getnframes())


def generate(definition_path, output):
    definition = load_definition(definition_path)
    output.mkdir(parents=True, exist_ok=True)
    fingerprint = hashlib.sha256(definition_path.read_bytes()).hexdigest()
    generator_hash = hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()
    manifest_path = output / "manifest.json"
    if manifest_path.exists():
        previous = json.loads(manifest_path.read_text())
        if previous.get("definitionSHA256") == fingerprint and previous.get("generatorSHA256") == generator_hash and all(
            (output / case["file"]).is_file()
            and hashlib.sha256((output / case["file"]).read_bytes()).hexdigest() == case["audioSHA256"]
            for case in previous.get("cases", [])
        ) and len(previous.get("cases", [])) == len(definition["cases"]):
            print(f"Reused {len(previous['cases'])} verified synthetic fixtures")
            return

    cache = {}
    with tempfile.TemporaryDirectory(prefix="localdictation-upgrade-speech-") as temporary:
        temporary = pathlib.Path(temporary)

        def speech(passage, rate):
            key = (passage, rate)
            if key not in cache:
                source = temporary / "speech.txt"
                source.write_text(definition["passages"][passage]["text"])
                aiff, wav = temporary / "speech.aiff", temporary / "speech.wav"
                aiff.unlink(missing_ok=True); wav.unlink(missing_ok=True)
                subprocess.run(["/usr/bin/say", "-v", definition["voice"], "-r", str(rate), "-f", str(source), "-o", str(aiff)], check=True)
                subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)], check=True)
                cache[key] = read_pcm(wav)
            return cache[key]

        cases = []
        for case in definition["cases"]:
            target = case["targetSeconds"]
            pauses = sum(part["pauseAfter"] for part in case["parts"])
            rate = definition["rate"]
            attempts = []
            for attempt in range(8):
                chunks = [speech(part["passage"], rate) for part in case["parts"]]
                spoken = sum(len(chunk) / 2 / SAMPLE_RATE for chunk in chunks)
                attempts.append((rate, round(spoken + pauses, 3)))
                if target is None or (spoken + pauses <= target and spoken >= (target - pauses) * 0.88):
                    break
                if attempt == 7:
                    raise RuntimeError(f"Case {case['id']} cannot fit its duration without cropping; rate/duration attempts: {attempts}")
                wanted = target - pauses - 0.35
                candidate = round(rate * spoken / wanted * (1.015 if spoken + pauses > target else 1))
                candidate = min(290, max(90, candidate))
                if candidate == rate:
                    candidate += 1 if spoken + pauses > target else -1
                rate = candidate
            used_frames = sum(len(chunk) // 2 for chunk in chunks) + round(pauses * SAMPLE_RATE)
            padding_frames = 0 if target is None else round(target * SAMPLE_RATE) - used_frames
            # Voice rates are quantized on some macOS versions. Spread the small
            # remainder across phrase boundaries instead of cropping speech or
            # leaving the last half minute of a five-minute fixture silent.
            boundaries = max(1, len(chunks) - 1)
            extra, remainder = divmod(padding_frames, boundaries)
            pcm = bytearray(bytes(padding_frames * 2) if len(chunks) == 1 else b"")
            for index, (part, chunk) in enumerate(zip(case["parts"], chunks)):
                pcm.extend(chunk)
                pcm.extend(bytes(round(part["pauseAfter"] * SAMPLE_RATE) * 2))
                if len(chunks) > 1 and index < boundaries:
                    pcm.extend(bytes((extra + (index < remainder)) * 2))
            if target is not None: assert len(pcm) == round(target * SAMPLE_RATE) * 2
            filename = f"{case['id']}.wav"
            with wave.open(str(output / filename), "wb") as audio:
                audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(SAMPLE_RATE)
                audio.writeframes(pcm)
            markers = collections.OrderedDict()
            for part in case["parts"]:
                for marker in definition["passages"][part["passage"]]["markers"]:
                    key = (marker["group"], marker["pattern"], marker.get("caseSensitive", False))
                    if key not in markers:
                        markers[key] = dict(marker, caseSensitive=key[2], raw=0, clean=0)
                    markers[key]["raw"] += marker["raw"]
                    markers[key]["clean"] += marker["clean"]
            cases.append(dict(id=case["id"], name=case["name"], file=filename,
                audioSHA256=hashlib.sha256((output / filename).read_bytes()).hexdigest(),
                audioSeconds=len(pcm) / 2 / SAMPLE_RATE, speechSeconds=spoken,
                explicitPauseSeconds=pauses, paddingSeconds=padding_frames / SAMPLE_RATE,
                quietPause=case["quietPause"], rate=rate,
                markers=list(markers.values())))
            print(f"Generated synthetic case {case['id']}: {len(pcm) / 2 / SAMPLE_RATE:.2f}s, {spoken:.2f}s speech")
    manifest_path.write_text(json.dumps(dict(schema=1, definitionSHA256=fingerprint, generatorSHA256=generator_hash,
        voice=definition["voice"], vocabulary=definition["vocabulary"], cases=cases), indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--definition", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent / "Tests/UpgradeFixtures.json")
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args()
    if args.validate_only:
        definition = load_definition(args.definition)
        print(f"Validated {len(definition['cases'])} public synthetic fixture recipes; no speech generated")
    else:
        if args.output is None:
            parser.error("output directory is required unless --validate-only is supplied")
        generate(args.definition, args.output)


if __name__ == "__main__":
    main()
