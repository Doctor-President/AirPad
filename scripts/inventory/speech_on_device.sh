#!/bin/bash
# live-10 (4) — static guard: every speech recognizer/request in the app targets is built by `OnDeviceSpeech`
# (which requires on-device recognition; `-OnDeviceSpeechSelfTest` checks the builders). A new path that builds its
# own request would bypass the flag, so any construction outside that enum fails here. Exit 0 = PASS.
cd "$(dirname "$0")/../.." || exit 2
pattern='SFSpeech(URL|AudioBuffer)RecognitionRequest\(|SFSpeechRecognizer\(locale|SpeechAnalyzer\(|SpeechTranscriber\(|DictationTranscriber\('
outside=$(grep -rnE "$pattern" --include='*.swift' AirPad AirPadShare AirPadWidgets \
  | grep -v '^AirPad/Services/LiveDictationService.swift:' )
inside=$(awk '/^enum OnDeviceSpeech/{f=1} f&&/^}/{f=0} f' AirPad/Services/LiveDictationService.swift | grep -cE "$pattern")
stray=$(awk '/^enum OnDeviceSpeech/{f=1} f&&/^}/{f=0;next} !f' AirPad/Services/LiveDictationService.swift | grep -cE "$pattern")
if [ -z "$outside" ] && [ "$stray" -eq 0 ] && [ "$inside" -ge 1 ]; then
  echo "[SpeechOnDeviceGuard] PASS — $inside construction site(s), all inside OnDeviceSpeech"
else
  echo "[SpeechOnDeviceGuard] FAIL — built outside OnDeviceSpeech:"
  [ -n "$outside" ] && echo "$outside" | cut -d: -f1,2
  [ "$stray" -gt 0 ] && echo "AirPad/Services/LiveDictationService.swift (outside the enum): $stray"
  exit 1
fi
