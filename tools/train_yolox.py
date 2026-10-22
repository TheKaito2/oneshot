"""Fine-tunes YOLOX (Megvii, Apache-2.0, third_party/YOLOX) on data/yolo for OneShot's detector.

Our own small loop around YOLOX's model, loss, optimizer, LR schedule and EMA; the data side is ours:
YOLO txt labels, letterbox to --size with grey 114 padding, BGR 0-255 as YOLOX expects.
Augmentation is geometry only: quarter turns (packs lie on the counter any way round; a mirror would reverse
their print), scale 0.5-1.5 and translate 10 %. No hue, saturation or brightness jitter: Lay's flavours differ
by colour. The last --no-aug epochs train on plain letterboxes with YOLOX's L1 box loss, as YOLOX does.

    PYTORCH_ENABLE_MPS_FALLBACK=1 third_party/.venv/bin/python tools/train_yolox.py --name tiny416
    # --exp yolox-s, --size 640, --epochs, --batch

Writes runs/yolox/<name>/: log.csv (train loss, val loss per epoch), best.pth (EMA weights, lowest val loss
without the L1 term, which only exists in the last epochs), last.pth.
"""
import argparse
import csv
import math
import random
import sys
import time
from pathlib import Path

import cv2
import numpy as np
import torch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "third_party/YOLOX"))
from yolox.exp import Exp  # noqa: E402
from yolox.models.yolo_head import YOLOXHead  # noqa: E402
from yolox.utils import ModelEMA  # noqa: E402

_losses = YOLOXHead.get_losses


def losses_on_cpu(self, *args, **kwargs):
    """YOLOX's loss (SimOTA assignment included), run on the CPU; autograd carries the gradients back to MPS.
    Its shapes change with each image's pack count and MPS builds a new graph for every new shape: measured 7 s
    a step with it on MPS against 0.65 s for a repeated batch."""
    cpu = lambda a: a.cpu() if torch.is_tensor(a) else [cpu(x) for x in a] if isinstance(a, list) else a
    return _losses(self, *map(cpu, args), **kwargs)


YOLOXHead.get_losses = losses_on_cpu

SIZES = {"yolox-tiny": (0.33, 0.375, "yolox_tiny.pth"), "yolox-s": (0.33, 0.50, "yolox_s.pth")}
PAD = 114
MAX_LABELS = 120


def make_exp(name, num_classes):
    depth, width, weights = SIZES[name]
    exp = Exp()
    exp.depth, exp.width, exp.num_classes = depth, width, num_classes
    return exp, ROOT / "third_party/weights" / weights


def read_labels(path):
    """YOLO txt rows (cls cx cy w h, normalised) as an N x 5 float array."""
    rows = [line.split() for line in path.read_text().splitlines() if line.strip()] if path.exists() else []
    return np.array(rows, dtype=np.float32).reshape(-1, 5)


def letterbox_matrix(w, h, size, scale=1.0, shift=(0.0, 0.0)):
    """2x3 affine: fit w x h into size x size, centred (like Vision's scaleFit), times scale, plus shift."""
    r = size / max(w, h) * scale
    return np.array([[r, 0, size / 2 - r * w / 2 + shift[0]], [0, r, size / 2 - r * h / 2 + shift[1]]], np.float32)


def augment(image, boxes, size, train):
    """image: BGR uint8. boxes: N x 5 (cls, cx, cy, w, h) normalised. Returns size x size image and pixel boxes."""
    h, w = image.shape[:2]
    xyxy = np.stack([boxes[:, 1] - boxes[:, 3] / 2, boxes[:, 2] - boxes[:, 4] / 2,
                     boxes[:, 1] + boxes[:, 3] / 2, boxes[:, 2] + boxes[:, 4] / 2], 1) * [w, h, w, h]
    if train:
        for _ in range(random.randrange(4)):   # quarter turn clockwise: (x, y) -> (h - y, x)
            image = cv2.rotate(image, cv2.ROTATE_90_CLOCKWISE)
            xyxy = np.stack([h - xyxy[:, 3], xyxy[:, 0], h - xyxy[:, 1], xyxy[:, 2]], 1)
            h, w = w, h
        m = letterbox_matrix(w, h, size, random.uniform(0.5, 1.5),
                             (random.uniform(-0.1, 0.1) * size, random.uniform(-0.1, 0.1) * size))
    else:
        m = letterbox_matrix(w, h, size)
    out = cv2.warpAffine(image, m, (size, size), flags=cv2.INTER_LINEAR, borderValue=(PAD, PAD, PAD))
    r = m[0, 0]
    moved = xyxy * r + [m[0, 2], m[1, 2], m[0, 2], m[1, 2]]
    clipped = moved.clip(0, size)
    area = lambda b: (b[:, 2] - b[:, 0]).clip(0) * (b[:, 3] - b[:, 1]).clip(0)
    # ponytail: a pack less than 40 % in frame is dropped, not labelled; the app drops tile-edge cuts the same way.
    keep = (area(clipped) >= 0.4 * area(moved).clip(1e-6)) & ((clipped[:, 2:] - clipped[:, :2]) >= 2).all(1)
    c = clipped[keep]
    labels = np.stack([boxes[keep, 0], (c[:, 0] + c[:, 2]) / 2, (c[:, 1] + c[:, 3]) / 2,
                       c[:, 2] - c[:, 0], c[:, 3] - c[:, 1]], 1) if keep.any() else np.zeros((0, 5), np.float32)
    return out, labels


class YoloFolder(torch.utils.data.Dataset):
    def __init__(self, split, size):
        self.images = sorted((ROOT / "data/yolo/images" / split).glob("*.jpg"))
        self.labels = [ROOT / "data/yolo/labels" / split / (p.stem + ".txt") for p in self.images]
        self.size, self.train = size, split == "train"

    def __len__(self):
        return len(self.images)

    def __getitem__(self, i):
        image = cv2.imread(str(self.images[i]))
        if image is None:
            raise IOError(f"can't read {self.images[i]}")
        out, labels = augment(image, read_labels(self.labels[i]), self.size, self.train)
        target = np.zeros((MAX_LABELS, 5), np.float32)
        target[:len(labels)] = labels[:MAX_LABELS]
        return torch.from_numpy(out.transpose(2, 0, 1).astype(np.float32)), torch.from_numpy(target)


def load_coco(model, weights):
    """COCO weights everywhere the shapes match; the class head (80 -> 12) keeps its fresh init."""
    state = torch.load(weights, map_location="cpu", weights_only=False)["model"]
    own = model.state_dict()
    kept = {k: v for k, v in state.items() if k in own and own[k].shape == v.shape}
    model.load_state_dict(kept, strict=False)
    return sorted(set(own) - set(kept))


def val_loss(model, loader, device):
    """Mean YOLOX loss on val, without the L1 term. BatchNorm stays in eval; only the head computes losses."""
    model.eval()
    model.training = model.head.training = True
    total, n = 0.0, 0
    with torch.no_grad():
        for images, targets in loader:
            out = model(images.to(device), targets.to(device))
            total += float(out["total_loss"] - out["l1_loss"]) * len(images)
            n += len(images)
    model.eval()
    return total / n


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exp", default="yolox-tiny", choices=SIZES)
    parser.add_argument("--size", type=int, default=416)
    parser.add_argument("--epochs", type=int, default=100)
    parser.add_argument("--no-aug", type=int, default=10)
    parser.add_argument("--batch", type=int, default=8)
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--name", required=True)
    args = parser.parse_args()

    names = [line.split(":", 1)[1].strip() for line in (ROOT / "data/yolo/data.yaml").read_text().splitlines()
             if line.startswith("  ") and ":" in line]
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    out_dir = ROOT / "runs/yolox" / args.name
    out_dir.mkdir(parents=True, exist_ok=True)

    exp, weights = make_exp(args.exp, len(names))
    exp.max_epoch, exp.warmup_epochs, exp.no_aug_epochs = args.epochs, 3, args.no_aug
    model = exp.get_model()
    fresh = load_coco(model, weights)
    print(f"{args.exp} {args.size}px, {len(names)} classes, fresh: {fresh}", flush=True)
    model.to(device).train()

    train = YoloFolder("train", args.size)
    val = YoloFolder("val", args.size)
    train_loader = torch.utils.data.DataLoader(train, args.batch, shuffle=True, drop_last=True,
                                               num_workers=args.workers, persistent_workers=True)
    val_loader = torch.utils.data.DataLoader(val, args.batch, num_workers=args.workers)
    optimizer = exp.get_optimizer(args.batch)
    scheduler = exp.get_lr_scheduler(exp.basic_lr_per_img * args.batch, len(train_loader))
    ema = ModelEMA(model, 0.9998)
    print(f"train {len(train)} · val {len(val)} · {len(train_loader)} steps/epoch · {device}", flush=True)

    best = math.inf
    with open(out_dir / "log.csv", "a", newline="") as log_file:
        log = csv.writer(log_file)
        log.writerow(["epoch", "lr", "train_loss", "val_loss", "seconds"])
        step = 0
        for epoch in range(args.epochs):
            if epoch == args.epochs - args.no_aug:
                train.train = False   # plain letterboxes + L1 loss for the last epochs, as YOLOX does
                model.head.use_l1 = True
                train_loader = torch.utils.data.DataLoader(train, args.batch, shuffle=True, drop_last=True,
                                                           num_workers=args.workers)
            start, running = time.time(), 0.0
            model.train()
            for images, targets in train_loader:
                step += 1
                lr = scheduler.update_lr(step)
                for group in optimizer.param_groups:
                    group["lr"] = lr
                loss = model(images.to(device), targets.to(device))["total_loss"]
                optimizer.zero_grad()
                loss.backward()
                optimizer.step()
                ema.update(model)
                running += float(loss)
            ema.ema.head.use_l1 = False
            vl = val_loss(ema.ema, val_loader, device)
            seconds = time.time() - start
            train_loss = running / len(train_loader)
            log.writerow([epoch + 1, f"{lr:.6f}", f"{train_loss:.4f}", f"{vl:.4f}", f"{seconds:.0f}"])
            log_file.flush()
            state = {"model": ema.ema.state_dict(), "exp": args.exp, "size": args.size, "names": names,
                     "epoch": epoch + 1, "val_loss": vl}
            torch.save(state, out_dir / "last.pth")
            if vl < best:
                best = vl
                torch.save(state, out_dir / "best.pth")
            print(f"epoch {epoch + 1}/{args.epochs} lr {lr:.5f} train {train_loss:.3f} val {vl:.3f}"
                  f"{' *' if vl == best else ''} {seconds:.0f}s", flush=True)


if __name__ == "__main__":
    main()
