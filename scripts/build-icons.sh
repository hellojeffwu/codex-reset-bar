#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-icons.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/app-icon.png --out "$work_dir/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" assets/app-icon.png --out "$work_dir/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$work_dir/AppIcon.iconset" -o assets/AppIcon.icns
for size in 16 24 32 48 64 128 256; do
  sips -z "$size" "$size" assets/app-icon.png --out "$work_dir/icon-$size.png" >/dev/null
  sips -s format ico "$work_dir/icon-$size.png" --out "$work_dir/icon-$size.ico" >/dev/null
done
# Package ImageIO's encoded frames into one multi-resolution ICO; pixels are
# resized/encoded by sips, not redrawn or edited by this container-writing step.
python3 - "$work_dir" <<'PY'
from pathlib import Path
import struct,sys
frames=[]
for size in [16,24,32,48,64,128,256]:
    data=(Path(sys.argv[1])/f'icon-{size}.ico').read_bytes()
    reserved,kind,count=struct.unpack_from('<HHH',data)
    assert reserved==0 and kind==1 and count>=1
    entry=struct.unpack_from('<BBBBHHII',data,6)
    length,offset=entry[-2:]
    frames.append((entry[:6],data[offset:offset+length]))
offset=6+16*len(frames)
output=bytearray(struct.pack('<HHH',0,1,len(frames)))
for entry,frame in frames:
    output.extend(struct.pack('<BBBBHHII',*entry,len(frame),offset))
    offset+=len(frame)
for _,frame in frames: output.extend(frame)
Path('assets/app.ico').write_bytes(output)
Path('windows/CodexResetBar/app.ico').write_bytes(output)
print('Built macOS ICNS and Windows ICO (16–256 px) from the same source icon.')
PY
