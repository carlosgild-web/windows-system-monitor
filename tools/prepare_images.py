#!/usr/bin/env python3
"""Turn the downloaded Gemini images into the files the project uses (dev-only tool, needs Pillow).

    python tools/prepare_images.py              # every image found in art/raw/
    python tools/prepare_images.py --only hero  # just some
    python tools/prepare_images.py prompts      # print the full prompt for each job

Raw downloads go in art/raw/<name>.png|jpg|jpeg|webp (git-ignored). Each image is center-cropped
to its slot's shape, resized, and saved where the app or the README loads it. Missing images
are skipped: every slot has a fallback, so the app works without them.
"""
import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "art" / "raw"
JOBS = json.loads((ROOT / "docs" / "image_prompts.json").read_text(encoding="utf-8"))

# name -> list of (output path, width, height)
OUTPUTS = {
    "app-icon": [(ROOT / "web/static/img/app-icon-512.png", 512, 512),
                 (ROOT / "web/static/img/app-icon-180.png", 180, 180)],
    "guide": [(ROOT / "web/static/img/guide.webp", 920, 400)],
    "state-nodata": [(ROOT / "web/static/img/state-nodata.webp", 160, 160)],
    "state-paused": [(ROOT / "web/static/img/state-paused.webp", 160, 160)],
    "state-error": [(ROOT / "web/static/img/state-error.webp", 160, 160)],
    "hero": [(ROOT / "docs/images/hero.webp", 1600, 560)],
    "social-preview": [(ROOT / "docs/images/social-preview.png", 1280, 640)],
}


def full_prompt(job):
    parts = [job["prompt"], JOBS["style"]]
    if job.get("spot"):
        parts.append(JOBS["spot_style"])
    return " ".join(parts)


def find_raw(name):
    for ext in (".png", ".jpg", ".jpeg", ".webp"):
        p = RAW / (name + ext)
        if p.exists():
            return p
    return None


def cover(img, w, h):
    """Center-crop to w:h, then resize to exactly w x h."""
    from PIL import Image
    src_ratio, dst_ratio = img.width / img.height, w / h
    if src_ratio > dst_ratio:                       # too wide: trim the sides
        new_w = round(img.height * dst_ratio)
        left = (img.width - new_w) // 2
        img = img.crop((left, 0, left + new_w, img.height))
    else:                                           # too tall: trim top and bottom
        new_h = round(img.width / dst_ratio)
        top = (img.height - new_h) // 2
        img = img.crop((0, top, img.width, top + new_h))
    return img.resize((w, h), Image.LANCZOS)


def prepare(only):
    from PIL import Image
    done = 0
    for job in JOBS["jobs"]:
        name = job["name"]
        if only and name not in only:
            continue
        raw = find_raw(name)
        if raw is None:
            print(f"skip  {name}: no art/raw/{name}.png|jpg|webp")
            continue
        with Image.open(raw) as img:
            img = img.convert("RGB")
            for out, w, h in OUTPUTS[name]:
                out.parent.mkdir(parents=True, exist_ok=True)
                res = cover(img, w, h)
                if out.suffix == ".webp":
                    res.save(out, "WEBP", quality=86, method=6)
                else:
                    res.save(out, "PNG", optimize=True)
                print(f"ok    {name} -> {out.relative_to(ROOT)} ({w}x{h}, {out.stat().st_size // 1024} KB)")
        done += 1
    print(f"{done} image(s) prepared")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", nargs="?", default="prepare", choices=["prepare", "prompts"])
    ap.add_argument("--only", nargs="*", default=None)
    args = ap.parse_args()
    if args.command == "prompts":
        for job in JOBS["jobs"]:
            print(f"--- {job['name']} ({job['aspect']})\n{full_prompt(job)}\n")
        return 0
    try:
        import PIL  # noqa: F401
    except ImportError:
        print("This tool needs Pillow: python -m pip install pillow", file=sys.stderr)
        return 1
    prepare(set(args.only) if args.only else None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
