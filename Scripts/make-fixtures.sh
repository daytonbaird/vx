#!/usr/bin/env bash
# Regenerates the checked-in audio fixtures under fixtures/audio/ using macOS
# text-to-speech (`say`) and `afconvert`. Output is 16 kHz / 16-bit / mono WAV,
# the exact format vx-rs `file` mode requires and the app streams to the backend.
#
# Fixtures are committed; run this only to add a fixture or deliberately
# regenerate one. TTS voices differ between machines and macOS versions, so a
# regenerated clip may transcribe slightly differently — re-key
# fixtures/audio/goldens.json afterwards with VX_UPDATE_GOLDENS=1.
#
# Usage: Scripts/make-fixtures.sh [name ...]   (no args = all)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/fixtures/audio"
VOICE="${VX_FIXTURE_VOICE:-Samantha}"
RATE="${VX_FIXTURE_RATE:-175}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$OUT"

# name|text  — "[[slnc N]]" is a say(1) embedded command: N ms of silence.
FIXTURES=(
  "short-phrase|The quick brown fox jumps over the lazy dog."
  "punctuation-numbers|Meet me at four thirty on March third, and bring twelve apples."
  "rule-trigger|open brace new line close brace"
  "spoken-submit|Send the report to the team. submit"
  "two-utterances|This is the first sentence. [[slnc 1500]] This is the second sentence."
  "long-45s|The lighthouse keeper climbed the spiral stairs every evening at dusk. He carried a brass lantern, a thermos of tea, and a worn logbook. From the top he could see the fishing boats returning to the harbor, their lamps swaying on the dark water. On clear nights the stars were so bright that he rarely needed the lantern at all. He wrote the weather in the logbook, noted the ships that passed, and wound the great clockwork that turned the lens. The beam swept across the bay every twelve seconds, steady as a heartbeat. In winter the wind howled through the gallery and salt spray froze on the railing. Still he climbed, every evening, because the light had to shine. After forty years he knew every stone of the tower and every mood of the sea. When the automatic lamp finally arrived, he stayed on for one more season, just to be sure it worked."
  "long-60s|Sarah had lived in the old house on Maple Street for as long as anyone could remember. The walls were painted a pale yellow that caught the morning light, and the windows rattled whenever the wind picked up. Strange noises came from the attic at night, but she had long since stopped being afraid of them. Every morning she walked to the bakery on the corner, bought a single loaf of rye bread, and talked with the owner about the weather. In the afternoons she tended the garden, pulling weeds from between the tomato plants and watering the roses that climbed the fence. The neighbors said she was quiet, but she simply preferred listening to talking. On Sundays her nephew visited and they played chess on the porch until the sun went down. She usually won. When the town council proposed tearing down the old houses to build a shopping center, Sarah wrote a letter to the newspaper. The letter was published on the front page and the plan was quietly dropped. Fifty years later, the house still stands, and the yellow paint still catches the morning light. The earth turns, the sun rises, and somewhere in distant worlds someone is scrubbing a floor and thinking of home."
)

selected=("$@")
for entry in "${FIXTURES[@]}"; do
  name="${entry%%|*}"
  text="${entry#*|}"
  if [[ ${#selected[@]} -gt 0 ]] && [[ ! " ${selected[*]} " == *" $name "* ]]; then
    continue
  fi
  aiff="$TMP/$name.aiff"
  wav="$OUT/$name.wav"
  say -v "$VOICE" -r "$RATE" -o "$aiff" -- "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$aiff" "$wav"
  dur=$(afinfo "$wav" | awk '/estimated duration/ {print $3}')
  printf '%-22s %6.1fs  %s\n' "$name" "$dur" "$wav"
done
