#!/usr/bin/env python3
"""Turn the CI demo-tour captures into App Store Connect screenshot sets.

App Store Connect accepts a fixed list of pixel sizes and rejects anything
else, with a message that names the size it wanted and not the one you sent.
The nightly tour captures on whatever iPhone simulator the runner happened
to list first — an iPhone 16 Pro gives 1206x2622, which is not on Apple's
list at any size.

So this does two things the raw artifact cannot:

  1. Emits EXACT store dimensions (1242x2688 for 6.5", 1284x2778 for 6.7").
  2. Picks and ORDERS the ten frames worth uploading. The tour photographs
     every screen, including five that render signed-out or error-state
     because CI has no backend — "Couldn't load courses" is not a
     screenshot anyone should ship.

Geometry: scale to cover the target width, then centre-crop the ~0.5%
height overshoot. Source and target aspect ratios differ by under half a
percent, so nothing meaningful leaves the frame. Where the source is
smaller than the target this upscales — 6.5% for the 6.7" set — which
softens text slightly. Capturing on a natively-sized simulator avoids that
entirely, which is why the workflow now prefers one; this is the safety net
for when it cannot.

  python3 tools/store-screenshots.py <input-dir> <output-dir>
"""
import sys, re, hashlib
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("needs Pillow:  pip install Pillow")

# Apple's slots. Portrait only — this app is portrait-locked.
SIZES = {
    "6.5-inch_1242x2688": (1242, 2688),
    "6.7-inch_1284x2778": (1284, 2778),
}

# ── Which frames, and how they are found ──────────────────────────────────
#
# BY NAME. Nothing here is inferred, deduplicated, counted or positioned.
# Every screen is photographed from its own app launch, so the file either
# holds that screen or does not exist.
#
# Three inference schemes preceded this — filename indexing, position among
# distinct frames, position among stable frames — and each failed in its own
# way as the tour's timing shifted underneath it. The last failed SILENTLY:
# one extra stable segment shifted every tour pick by one, and the set that
# came out was ordered, self-consistent, and had the course detail screen in
# the slot labelled "run complete". Only opening the image revealed it.
#
# The lesson is not that the heuristics were bad. It is that a capture whose
# timing cannot be relied upon cannot be made reliable downstream.

ONBOARDING_PICKS = {          # onboarding page -> output name
    1: "08-pick-a-course",
    2: "04-four-disciplines",
    3: "06-every-run-verified",
    4: "10-drive-safe",       # the safety gate — App Review wants this one
    5: "09-roads-near-you",
}
# Page 0 is the opening title card, which says less than any of the above.

TOUR_PICKS = {                # tour stage -> output name
    "driving":     "01-live-run-ghost-delta",
    "driveResult": "02-run-complete-verified",
    "course":      "03-course-detail",
    "shareCard":   "05-share-card",
    "flyingStart": "07-flying-start-not-ranked",
}
# Captured but deliberately unused: home, explore, leaderboards, profile and
# garage all render signed-out or empty against CI's absent backend. They
# stay in the raw artifact as a contact sheet.
#
# `driveResult` renders the finished-run screen from a fixture rather than
# waiting for the live drive to reach it, because that moment arrives
# partway through `driving` and the app's clock cannot be predicted under
# capture load. Its numbers match the share card so the two agree.


def fit(img, target):
    tw, th = target
    scale = tw / img.width
    resized = img.resize((tw, max(th, round(img.height * scale))), Image.LANCZOS)
    if resized.height == th:
        return resized
    top = (resized.height - th) // 2          # split the overshoot evenly
    return resized.crop((0, top, tw, top + th))


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: python3 tools/store-screenshots.py <input-dir> <output-dir>")
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    if not src.is_dir():
        sys.exit(f"no such directory: {src}")

    wanted = ([(src / f"onboard-page-{n}.png", name)
               for n, name in ONBOARDING_PICKS.items()]
              + [(src / f"tour-{stage}.png", name)
                 for stage, name in TOUR_PICKS.items()])

    missing = [path.name for path, _ in wanted if not path.exists()]
    if missing:
        # Each file is one app launch, so a missing file is a launch that
        # failed — not a timing question any more.
        sys.exit("cannot build a complete set; missing capture(s):\n  "
                 + "\n  ".join(missing)
                 + "\nEach is captured from its own app launch — check the "
                   "capture step's log for that stage.")

    # Distinctness still matters: two stages that rendered identically means
    # a launch opened the wrong screen, which naming cannot rule out.
    digests = {}
    for path, name in wanted:
        digests.setdefault(hashlib.md5(path.read_bytes()).hexdigest(), []).append(name)
    collisions = [g for g in digests.values() if len(g) > 1]
    if collisions:
        sys.exit("two captures are identical, so a launch opened the wrong "
                 "screen:\n  " + "\n  ".join(", ".join(g) for g in collisions))

    print("mapping:")
    for path, name in sorted(wanted, key=lambda pair: pair[1]):
        print(f"  {name:<28} <- {path.name}")
    print()

    written = 0
    for label, target in SIZES.items():
        out = dst / label
        out.mkdir(parents=True, exist_ok=True)
        for path, name in wanted:
            fit(Image.open(path).convert("RGB"), target).save(
                out / f"{name}.png", "PNG", optimize=True)
            written += 1
        print(f"{label}: {len(wanted)} screenshots -> {out}")

    print(f"\n{written} files. Upload each folder to its matching size in "
          f"App Store Connect; the numeric prefixes are the display order.")


if __name__ == "__main__":
    main()
