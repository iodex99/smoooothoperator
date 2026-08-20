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
# Both sequences are addressed by POSITION AMONG STABLE SCREENS, never by
# filename. Filenames moved on all three August 2026 runs; the order of the
# tour never does.
#
# "Stable" means a screen that was photographed more than once in a row.
# That filter is doing real work: a tab change or a page turn caught
# mid-animation appears as a single distinct frame, and the first version of
# this tool happily picked those transition blurs as screens — CI run
# 32341477503 mapped "Pick a course" onto a fade between two other pages.
# Every real stage now dwells long enough (DemoTour.stageDwell) to be caught
# at least three times, so anything seen once is by definition not a stage.

MIN_DWELL = 2

# ONBOARDING is addressed by PAGE NUMBER, because CI now photographs each
# page from its own app launch (SMOOOOTH_DEMO_ONBOARDING_PAGE) rather than
# letting a timer advance a walk. There is nothing left to infer: page 4 is
# in onboard-page-4.png or the file is absent.
#
# This replaced position-among-stable-screens, which replaced filename
# indexing, both of which were attempts to recover a reliable signal from a
# capture whose timing could not be relied upon. Removing the timing was the
# fix; the heuristics were treatment of a symptom.
ONBOARDING_PICKS = {          # onboarding page -> output name
    1: "08-pick-a-course",
    2: "04-four-disciplines",
    3: "06-every-run-verified",
    4: "10-drive-safe",       # the safety gate — App Review wants this one
    5: "09-roads-near-you",
}
# Page 0 is the opening title card, which says less than any of the above.

# The tour's stable stages, in the fixed order DemoTourView walks them.
# Indices 0-3 are Home / Explore / Leaderboards / Profile, all of which
# render signed-out against CI's absent backend and are deliberately unused.
TOUR_STAGES = 9
TOUR_PICKS = {
    4: "03-course-detail",
    5: "02-run-complete-verified",   # DriveView's own result, after the drive
    6: "05-share-card",
    7: None,                         # garage — signed-out, not shipped
    8: "07-flying-start-not-ranked",
}

# The live run is NOT a stable screen: the map moves, so every frame differs.
# It is found as the longest run of never-repeated frames, which is the drive
# and nothing else — a transition blur is one frame, the drive is six or
# seven. Taking the middle of that run avoids the start and finish overlays.
LIVE_RUN_OUTPUT = "01-live-run-ghost-delta"


def segments(src, pattern):
    """[(path, dwell)] — consecutive identical captures collapsed."""
    frames = sorted(src.glob(pattern),
                    key=lambda p: int(re.search(r"(\d+)", p.name).group(1)))
    out, previous = [], None
    for frame in frames:
        digest = hashlib.md5(frame.read_bytes()).hexdigest()
        if digest != previous:
            out.append([frame, 1])
            previous = digest
        else:
            out[-1][1] += 1
    return out


def longest_transient_run(segs):
    """The drive: the longest stretch of frames that never repeated."""
    best, current = [], []
    for path, dwell in segs:
        if dwell < MIN_DWELL:
            current.append(path)
            if len(current) > len(best):
                best = list(current)
        else:
            current = []
    return best


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

    problems, selected = [], []

    # ── onboarding, one file per page ────────────────────────────────────
    missing = [n for n in ONBOARDING_PICKS if not (src / f"onboard-page-{n}.png").exists()]
    if missing:
        problems.append(
            f"onboarding: missing page(s) {', '.join(map(str, missing))}. "
            f"Each page is captured from its own app launch, so a missing "
            f"file means that launch failed — check the capture step's log."
        )
    else:
        selected += [(src / f"onboard-page-{n}.png", name)
                     for n, name in ONBOARDING_PICKS.items()]

    # ── tour: stable stages ──────────────────────────────────────────────
    tour = segments(src, "tour-*.png")
    stages = [p for p, dwell in tour if dwell >= MIN_DWELL]
    if len(stages) < TOUR_STAGES:
        problems.append(
            f"tour: {len(stages)} stable stages, expected {TOUR_STAGES}. "
            f"The tour did not complete, or a stage is dwelling too briefly "
            f"to be photographed twice."
        )
    else:
        selected += [(stages[i], name)
                     for i, name in TOUR_PICKS.items() if name]

    # ── tour: the live run ───────────────────────────────────────────────
    drive = longest_transient_run(tour)
    if len(drive) < 3:
        problems.append(
            f"live run: found {len(drive)} moving frames, expected several. "
            f"The mock drive is finishing faster than the capture interval — "
            f"lower `speedup` in DemoTour.swift."
        )
    else:
        selected.append((drive[len(drive) // 2], LIVE_RUN_OUTPUT))

    if problems:
        # Refuse rather than emit a set with a hole in it. A duplicated slot
        # looks like a finished screenshot set right up until Apple sees it.
        sys.exit("cannot build a complete set:\n  " + "\n  ".join(problems))

    # Distinctness is the last backstop: if two picks resolved to the same
    # screen, the mapping is wrong however plausible the counts looked.
    digests = {}
    for path, name in selected:
        digests.setdefault(hashlib.md5(path.read_bytes()).hexdigest(), []).append(name)
    collisions = [g for g in digests.values() if len(g) > 1]
    if collisions:
        sys.exit("two picks resolved to the same screen:\n  "
                 + "\n  ".join(", ".join(g) for g in collisions))

    print("mapping:")
    for path, name in sorted(selected, key=lambda pair: pair[1]):
        print(f"  {name:<28} <- {path.name}")
    print()

    written = 0
    for label, target in SIZES.items():
        out = dst / label
        out.mkdir(parents=True, exist_ok=True)
        for path, name in selected:
            fit(Image.open(path).convert("RGB"), target).save(
                out / f"{name}.png", "PNG", optimize=True)
            written += 1
        print(f"{label}: {len(selected)} screenshots -> {out}")

    print(f"\n{written} files. Upload each folder to its matching size in "
          f"App Store Connect; the numeric prefixes are the display order.")


if __name__ == "__main__":
    main()
