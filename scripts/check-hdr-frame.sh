#!/bin/bash
# Small synthetic decoder fixture, not a mastering/color-fidelity reference.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/checks/hdr-input
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=128x72:rate=24' -frames:v 96 \
  -vf format=yuv420p10le -c:v libx265 -preset ultrafast \
  -x265-params 'log-level=error:pools=1:frame-threads=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:chromaloc=0:range=limited' \
  -tag:v hvc1 -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  -color_range tv -chroma_sample_location left -y build/checks/hdr-input/pq.mp4
ffmpeg -hide_banner -loglevel error -f lavfi -i 'color=gray:size=128x72:rate=24' -frames:v 1 \
  -c:v libx264 -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -y build/checks/hdr-input/sdr.mp4
binary='build/Luma HDR Prototype.app/Contents/MacOS/LumaHDRPrototype'
"$binary" --check-shader
"$binary" --check-frame build/checks/hdr-input/pq.mp4
"$binary" --check-stream build/checks/hdr-input/pq.mp4
set +e
"$binary" --check-frame build/checks/hdr-input/sdr.mp4 > build/checks/hdr-input/sdr-result.txt 2>&1
status=$?
set -e
cat build/checks/hdr-input/sdr-result.txt
[[ $status == 1 ]]
rg -Fq 'REJECTED: Requires BT.2020/(PQ or HLG)/BT.2020' build/checks/hdr-input/sdr-result.txt

ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=128x72:rate=24' -frames:v 48 \
  -vf format=yuv420p10le -c:v libx265 -preset ultrafast \
  -x265-params 'log-level=error:pools=1:frame-threads=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:chromaloc=0:range=limited' \
  -tag:v hvc1 -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc \
  -color_range tv -chroma_sample_location left -y build/checks/hdr-input/hlg.mp4
"$binary" --check-frame build/checks/hdr-input/hlg.mp4
"$binary" --check-stream build/checks/hdr-input/hlg.mp4
