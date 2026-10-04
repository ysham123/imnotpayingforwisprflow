import json
import struct
import subprocess
import sys
import uuid

worker = sys.argv[1]
ids = [str(uuid.uuid4()) for _ in range(3)]
terms = ['x' * 180, 'y' * 20, 'José']

def frame(entries, samples=None):
    samples = [0.1] * 4000 if samples is None else samples
    value = struct.pack('<II', len(samples), len(entries))
    for identity, term in entries:
        encoded = term.encode()
        value += identity.encode() + struct.pack('<I', len(encoded)) + encoded
    return value + struct.pack('<' + 'f' * len(samples), *samples)

def run(data):
    p = subprocess.run([worker, 'fixture-model'], input=data, capture_output=True, timeout=5, check=True)
    return [json.loads(line) for line in p.stdout.decode().splitlines()]

result = run(frame(list(zip(ids, terms))) + frame([]))
assert result[0]['protocol'] == 2 and result[0]['vocabulary_token_budget'] == 200
assert result[1]['text'] == ' ' + terms[0] + ', ' + terms[2]
assert result[1]['vocabulary_overflow'] == [ids[1]]
assert result[2]['text'] == 'no hints' and not result[2]['vocabulary_overflow']
assert run(frame(list(zip(ids, terms)), [0.0] * 4000))[1]['text'] == ''
assert len(run(struct.pack('<II', 4000, 101))) == 1
assert len(run(struct.pack('<II', 4000, 1) + ids[0].encode() + struct.pack('<I', 257))) == 1
assert len(run(frame([(ids[0], 'bad\x00word')]))) == 1
assert len(run(frame([(ids[0], 'José')])[:-4])) == 1
assert len(run(struct.pack('<II', 1_920_001, 0))) == 1
print('Passed 10 native worker framing, complete-term budget, UTF8, silence, and state-reset checks (stub decoder)')
