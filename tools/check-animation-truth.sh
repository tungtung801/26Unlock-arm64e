#!/usr/bin/env bash
# Self-check: verifies that the animation source still matches the ORIGINAL
# tweak binary (original.deb) on every value that was reverse-engineered.
# Usage: bash tools/check-animation-truth.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
E="$ROOT/26Unlock/WaveEngine.m"; T="$ROOT/26Unlock/WaveTable.m"; X="$ROOT/26Unlock/Tweak.xm"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s   <-- %s\n' "$1" "$2"; fail=$((fail+1)); }
chk(){ grep -qF -- "$2" "$3" && ok "$1" || no "$1" "missing: $2"; }
chkabs(){ grep -qF -- "$2" "$3" && no "$1" "still present: $2" || ok "$1"; }

echo "== WaveTable =="
chk  "kWaveMap row0 {8,7,7,8}"        "{ 8, 7, 7, 8 }"   "$T"
chk  "kWaveMap row1 {6,4,4,6}"        "{ 6, 4, 4, 6 }"   "$T"
chk  "kWaveMap row2 {3,1,1,3}"        "{ 3, 1, 1, 3 }"   "$T"
chk  "kWaveMap row4 {3,1,1,3}"        "{ 3, 1, 1, 3 }"   "$T"
chk  "kWaveMap row5 {5,4,4,5}"        "{ 5, 4, 4, 5 }"   "$T"
chk  "center=(1.5,2.5)"               "CGPointMake(1.5, 2.5)" "$T"
chkabs "center is not the wrong 2.0"  "CGPointMake(1.5, 2.0)" "$T"
chk  "microOffset 0.015"              "0.015"            "$T"
chk  "delay wave>=4 subtract 0.055"   "-= 0.055"         "$T"

echo "== WaveEngine =="
chk  "stiffness wave1..3 = 300.0"     "return 300.0;"    "$E"
chkabs "stiffness is not 150.0"       "return 150.0;"    "$E"
chk  "damping 42 - 8n"                "42.0 - 8.0 * n"   "$E"
chk  "damping 26 - 2.1n"              "26.0 - 2.1 * n"   "$E"
chk  "damping ramp |v|/2500"          "2500.0"           "$E"
chk  "initialVelocity 12.0"           "12.0"             "$E"
chk  "mass 1.5"                       "1.5"              "$E"
chk  "halfDelta positive (col2-col1)" "(rightLayer.position.x - leftLayer.position.x) * 0.5" "$E"
chk  "horizontalFly +-0.8"            "0.8"              "$E"
chk  "dy divisor 150.0"               "150.0"            "$E"
chk  "outward push 800.0"             "800.0"            "$E"
chk  "stretch 4.5 + 2.1(1-f)"         "4.5"              "$E"
chk  "grid distance /3.0"             "3.0"              "$E"
chk  "dock +380.0"                    "380.0"            "$E"
chk  "dock damping 22.0"              "22.0"             "$E"
chk  "row==5 zPosition -1"            "-1.0"             "$E"
chk  "position FROM target"           "position.fromValue = [NSValue valueWithCGPoint:target];"   "$E"
chk  "position TO original"           "position.toValue = [NSValue valueWithCGPoint:original];"   "$E"

echo "== Tweak.xm =="
chk  "velocity fallback -1250.0"      "-1250.0"          "$X"
chk  "waveInterval 0.055"             "0.055"            "$E"
chk  "geometric registerHome"         "convertRect:view.bounds toView:nil" "$X"
chk  "col clamp 0..3"                 "> 3) col = 3"     "$X"
chk  "row clamp 0..5"                 "> 5) row = 5"     "$X"

echo
printf 'RESULT: %d PASS / %d FAIL\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
