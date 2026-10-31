#!/bin/bash
# On-device audio test for the alioth WCD938x mic + CS35L41 speaker work.
# Run as root on the phone.  It talks to the card directly, so stop the user
# audio stack first (the script does that) and restart it at the end.
#
# Usage:
#   test-audio.sh info          # card PCMs, key mixer controls, dmesg audio errors
#   test-audio.sh play          # apply speaker route, play 2 s 440 Hz, show dmesg
#   test-audio.sh mic main      # record 3 s from main mic (speak/clap when asked)
#   test-audio.sh mic top|back|front
#   test-audio.sh mics          # record all four in sequence
#   test-audio.sh loopback      # play 440 Hz while recording main mic, measure 440 Hz
#
# Recording goes to /tmp/mic-<name>.wav; loopback to /tmp/loopback.wav.
set -u
CARD=0
PPCM="hw:${CARD},0"
CPCM="hw:${CARD},1"
U="sudo -u user XDG_RUNTIME_DIR=/run/user/1000"

say() { echo; echo "== $*"; }

stop_pw() {
  $U systemctl --user stop pipewire.socket pipewire wireplumber \
    pipewire-pulse.socket pipewire-pulse >/dev/null 2>&1 || true
  sleep 1
}
start_pw() {
  $U systemctl --user start pipewire.socket pipewire wireplumber \
    pipewire-pulse.socket pipewire-pulse >/dev/null 2>&1 || true
}

cset() { amixer -c "$CARD" cset name="$1" "$2" >/dev/null 2>&1; }

# TX-macro + codec sequence for one of the four WCD938x mics.
# Args: profile smic adc_mixer_ctl adc_mux_ctl adc_mux_val adc_switch_ctl tx_mode_ctl
mic_on() {
  cset "TX DEC0 MUX" SWR_MIC
  cset "TX SMIC MUX0" "$1"
  cset "TX_AIF1_CAP Mixer DEC0" 1
  cset "TX_DEC0 Volume" 100
  cset "$2" 1
  [ -n "${3:-}" ] && cset "$3" "$4"
  cset "$5" 1
  cset "$6" ADC_NORMAL
}
mic_off() {
  cset "$1" 0
  cset "$2" 0
  cset "$3" ADC_INVALID
  cset "TX_AIF1_CAP Mixer DEC0" 0
  cset "TX SMIC MUX0" ZERO
  cset "TX DEC0 MUX" ZERO
}
mic_main_on()  { mic_on ADC0 "ADC1_MIXER Switch" "" "" "ADC1 Switch" "TX0 MODE"; }
mic_top_on()   { mic_on ADC3 "ADC4_MIXER Switch" "ADC4 MUX" INP5 "ADC4 Switch" "TX3 MODE"; }
mic_back_on()  { mic_on ADC2 "ADC3_MIXER Switch" "ADC3 MUX" INP4 "ADC3 Switch" "TX2 MODE"; }
mic_front_on() { mic_on ADC1 "ADC2_MIXER Switch" "ADC2 MUX" INP3 "ADC2 Switch" "TX1 MODE"; }
mic_main_off()  { mic_off "ADC1_MIXER Switch" "ADC1 Switch" "TX0 MODE"; }
mic_top_off()   { mic_off "ADC4_MIXER Switch" "ADC4 Switch" "TX3 MODE"; }
mic_back_off()  { mic_off "ADC3_MIXER Switch" "ADC3 Switch" "TX2 MODE"; }
mic_front_off() { mic_off "ADC2_MIXER Switch" "ADC2 Switch" "TX1 MODE"; }

speaker_on() {
  cset "RCV DSP1 Preload Switch" 1
  cset "RCV DRE Switch" 1
  cset "RCV PCM Soft Ramp" 4ms
  cset "RCV Analog PCM Volume" 18
  cset "RCV ASP TX1 Source" DSPTX1
  cset "RCV DSP RX1 Source" ASPRX1
  cset "RCV DSP RX2 Source" ASPTX2
  cset "LCV DSP1 Preload Switch" 1
  cset "LCV DRE Switch" 1
  cset "LCV PCM Soft Ramp" 4ms
  cset "LCV Analog PCM Volume" 18
  cset "LCV ASP TX1 Source" DSPTX1
  cset "LCV DSP RX1 Source" ASPRX1
  cset "LCV DSP RX2 Source" ASPTX2
  cset "TERT_TDM_RX_0 Audio Mixer MultiMedia1" 1
  cset "RCV PCM Source" DSP
  cset "LCV PCM Source" DSP
}

tone_wav() {  # <file> <seconds>
  python3 - "$1" "$2" <<'PY'
import math, struct, sys, wave
path, secs = sys.argv[1], float(sys.argv[2])
w = wave.open(path, "w"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
fr = b"".join(struct.pack("<hh",
        int(8000 * math.sin(2 * math.pi * 440 * i / 48000)),
        int(8000 * math.sin(2 * math.pi * 440 * i / 48000)))
    for i in range(int(48000 * secs)))
w.writeframes(fr); w.close()
PY
}

rms() {  # <wav> -> "rms=<x> peak=<y>"
  python3 - "$1" <<'PY'
import struct, sys, wave
w = wave.open(sys.argv[1], "rb")
n, ch = w.getnframes(), w.getnchannels()
raw = w.readframes(n)
s = struct.unpack("<%dh" % (n * ch), raw) if n else ()
peak = max((abs(v) for v in s), default=0)
rms = int((sum(v * v for v in s) / len(s)) ** 0.5) if s else 0
print("rms=%d peak=%d frames=%d" % (rms, peak, n))
PY
}

# Energy at 440 Hz relative to the whole band (loopback proof).
tone_ratio() {  # <wav>
  python3 - "$1" <<'PY'
import cmath, math, struct, sys, wave
w = wave.open(sys.argv[1], "rb")
n = w.getnframes(); rate = w.getframerate(); ch = w.getnchannels()
raw = w.readframes(n)
s = struct.unpack("<%dh" % (n * ch), raw)
# left channel only, mono mix is fine for a ratio
x = [s[i * ch] for i in range(n)]
N = min(48000, n)
if N < 1024: print("too short"); raise SystemExit
x = x[:N]
# Goertzel at 440 Hz
k = int(0.5 + N * 440.0 / rate)
w0 = 2 * math.pi * k / N
re = sum(v * math.cos(w0 * i) for i, v in enumerate(x))
im = sum(v * math.sin(w0 * i) for i, v in enumerate(x))
tone = (re * re + im * im) / N
tot = sum(v * v for v in x) / N
print("tone=%.3e total=%.3e ratio=%.1f dB" % (tone, tot, 10 * math.log10(tone / tot) if tot else -999))
PY
}

dmesg_audio() {
  dmesg | tail -n 300 | grep -iE "cs35|PRE_PMU|Enable\(1\)|CSPL|MBOX|TX_CODEC|WCD|soundwire|sdw|no backend" | tail -25
}

case "${1:-info}" in
info)
  say "card"; cat /proc/asound/cards; cat /proc/asound/pcm
  say "key controls"
  amixer -c "$CARD" controls 2>/dev/null | grep -iE "TX SMIC|TX DEC0|AIF1_CAP Mixer DEC0|ADC[1-4]_MIXER|ADC[1-4] Switch|TX[0-3] MODE|MultiMedia1 Mixer|WCD" | head -40
  say "dmesg"; dmesg_audio
  ;;
play)
  stop_pw
  say "speaker route"; speaker_on
  tone_wav /tmp/tone.wav 2
  say "play"; aplay -D "$PPCM" /tmp/tone.wav 2>&1 | tail -3
  sleep 1
  say "dmesg after play"; dmesg_audio
  start_pw
  ;;
mic)
  name="${2:-main}"
  case "$name" in
    main) on=mic_main_on; off=mic_main_off ;;
    top) on=mic_top_on; off=mic_top_off ;;
    back) on=mic_back_on; off=mic_back_off ;;
    front) on=mic_front_on; off=mic_front_off ;;
    *) echo "unknown mic: $name (main|top|back|front)"; exit 1 ;;
  esac
  stop_pw
  say "mic $name: keep quiet 1 s, then talk/clap for 3 s"
  $on; sleep 1
  arecord -D "$CPCM" -f S16_LE -r 48000 -c 2 -d 3 "/tmp/mic-$name.wav" 2>&1 | tail -2
  $off
  say "result"; rms "/tmp/mic-$name.wav"
  say "dmesg"; dmesg_audio
  start_pw
  ;;
mics)
  for m in main top back front; do "$0" mic "$m"; done
  ;;
loopback)
  name="${2:-main}"
  case "$name" in
    main) on=mic_main_on; off=mic_main_off ;;
    top) on=mic_top_on; off=mic_top_off ;;
    back) on=mic_back_on; off=mic_back_off ;;
    front) on=mic_front_on; off=mic_front_off ;;
    *) echo "unknown mic: $name (main|top|back|front)"; exit 1 ;;
  esac
  stop_pw
  say "speaker on"; speaker_on
  say "$name mic on"; $on
  tone_wav /tmp/tone.wav 3
  ( aplay -D "$PPCM" /tmp/tone.wav >/dev/null 2>&1 ) &
  sleep 0.3
  arecord -D "$CPCM" -f S16_LE -r 48000 -c 2 -d 3 "/tmp/loopback-$name.wav" 2>&1 | tail -2
  wait
  $off
  say "loopback $name result"; rms "/tmp/loopback-$name.wav"; tone_ratio "/tmp/loopback-$name.wav"
  say "dmesg"; dmesg_audio
  start_pw
  ;;
*)
  echo "usage: $0 {info|play|mic <main|top|back|front>|mics|loopback}"; exit 1
  ;;
esac
