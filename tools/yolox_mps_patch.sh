#!/bin/zsh
# Makes YOLOX (third_party/YOLOX, Apache-2.0) train on Apple MPS: it moves tensors with CUDA type strings
# ('torch.cuda.FloatTensor'), which MPS rejects. Pass the reference tensor instead, so .to() matches its device.
set -euo pipefail
cd "$(dirname "$0")/../third_party/YOLOX/yolox"
sed -i '' 's/xin\[0\]\.type()/xin[0]/g; s/\.type(dtype)/.to(dtype)/g' models/yolo_head.py
sed -i '' 's/(tl < br)\.type(tl\.type())/(tl < br).to(tl)/' utils/boxes.py models/losses.py
grep -c "xin\[0\]\.type()\|\.type(dtype)" models/yolo_head.py || echo "patched"
