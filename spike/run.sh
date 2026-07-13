#!/usr/bin/env bash
# Phase-0 de-risk spike: prove MoltenVK runs dye.k-emitted SPIR-V at 1.3 and 1.4.
# Regenerates the two .spv from dye.k, then builds+runs the Vulkan compute program.
set -euo pipefail
cd "$(dirname "$0")/.."

MVK=/opt/homebrew/opt/molten-vk
VKH=/opt/homebrew/opt/vulkan-headers/include

# 1. emit dye.k `shader.compute[{[x] x*2}]` words
cat > /tmp/dump.k <<'EOF'
2:"lib/dye.k"
wds: shader.compute[{[x] x*2}]
`0 0: $#wds
`0 0: ,/{" ",$x}'wds
EOF
[ -x zig-out/bin/ink ] || zig build
./zig-out/bin/ink /tmp/dump.k > /tmp/words.txt

# 2. pack 1.3 (as-is) + 1.4 (version word bumped)
python3 - <<'PY'
import struct
t=open('/tmp/words.txt').read().split(); n=int(t[0]); w=[int(x) for x in t[1:1+n]]
def pack(ws,p): open(p,'wb').write(b''.join(struct.pack('<I',x&0xffffffff) for x in ws))
pack(w,'spike/k13.spv')
w2=list(w); w2[1]=0x00010400; pack(w2,'/tmp/k14raw.spv')
PY

# Phase-6 transform: expand OpEntryPoint to list ALL non-I/O globals (SPIR-V 1.4
# requires the interface to include every referenced global variable, not just
# Input/Output). Done on --raw-id disassembly so every id is numeric+stable.
spirv-dis --raw-id /tmp/k14raw.spv > /tmp/k14.dis
python3 - <<'PY'
import re
lines=open('/tmp/k14.dis').read().splitlines()
# ids of non-I/O global variables that must join the interface
extra=[m.group(1) for l in lines
       for m in [re.search(r'(%\d+)\s*=\s*OpVariable .*(StorageBuffer|Uniform|PushConstant)\b', l)] if m]
for i,l in enumerate(lines):
  if 'OpEntryPoint' in l:
    have=set(re.findall(r'%\d+', l.split('"main"')[1]))
    lines[i]=l.rstrip()+''.join(' '+e for e in extra if e not in have)
open('/tmp/k14.dis','w').write('\n'.join(lines)+'\n')
print('iface += '+' '.join(extra))
PY
spirv-as --target-env spv1.4 /tmp/k14.dis -o spike/k14.spv
spirv-val --target-env vulkan1.1 spike/k13.spv; echo "k13 valid @ vulkan1.1"
spirv-val --target-env vulkan1.2 spike/k14.spv; echo "k14 valid @ vulkan1.2"

# 3. build + run the Vulkan/MoltenVK compute spike
cd spike
zig build-exe vkspike.zig -I "$VKH" -L "$MVK/lib" -lMoltenVK \
  -framework Metal -framework Foundation -framework QuartzCore -framework IOKit \
  -framework IOSurface -framework CoreGraphics -framework AppKit -lc++ -lc \
  -femit-bin=vkspike
./vkspike
