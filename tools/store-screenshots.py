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
import sys, os, hashlib
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
# ONBOARDING is addressed by POSITION IN THE SEQUENCE, not by filename.
# It is six static screens in a fixed order, so deduplicating the captures
# in filename order yields exactly those six, whatever the capture cadence
# happened to be. Frame numbers drift between runs; the order never does.
ONBOARDING_SCREENS = 6
ONBOARDING_PICKS = {          # position in the deduped sequence -> output name
    1: "08-pick-a-course",    # "Pick a course. Beat the benchmark."
    2: "04-four-disciplines", # "One score. Four disciplines."
    3: "06-every-run-verified",
    4: "10-drive-safe",       # the safety gate — App Review wants this one
    5: "09-roads-near-you",   # the location ask
}
# Position 0 is the opening title card, which says less than any of the above.

# THE TOUR cannot use the same trick: the live-run map moves continuously,
# so deduplicating yields dozens of distinct frames rather than a screen
# list. These are filename-addressed and therefore DRIFT BETWEEN RUNS —
# 2026-08-20 moved every one of them. Re-check against the contact sheet
# after any change to the tour, and read the mapping this script prints.
TOUR_PICKS = [
    ("tour-12.png", "01-live-run-ghost-delta"),
    ("tour-13.png", "02-run-complete-verified"),
    ("tour-09.png", "03-course-detail"),
    ("tour-22.png", "05-share-card"),
    ("tour-27.png", "07-flying-start-not-ranked"),
]

# Deliberately excluded: Home, Explore, Leaderboards, Profile and Garage.
# All render signed-out or empty against CI's absent backend, and Explore
# shows an outright error. Re-shoot on a signed-in device once the backend
# is deployed.


def onboarding_sequence(src):
    """The distinct onboarding screens, in the order they were shown."""
    frames = sorted(src.glob("onboard-*.png"))
    sequence, previous = [], None
    for frame in frames:
        digest = hashlib.md5(frame.read_bytes()).hexdigest()
        if digest != previous:          # collapse runs of identical captures
            sequence.append(frame)
            previous = digest
    return sequence


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

    # ── onboarding, by position ──────────────────────────────────────────
    sequence = onboarding_sequence(src)
    if len(sequence) < ONBOARDING_SCREENS:
        # Loud, because this is how the safety gate went missing: the
        # capture cadence aliased with the auto-advance and skipped screens,
        # and every file the old check looked for still existed.
        sys.exit(
            f"onboarding capture is incomplete: {len(sequence)} distinct "
            f"screens, expected {ONBOARDING_SCREENS}.\n"
            f"The capture cadence is aliasing with the 4s auto-advance — "
            f"screens are being skipped. Capture more often, not less."
        )

    selected = []
    for position, name in ONBOARDING_PICKS.items():
        selected.append((sequence[position], name))

    # ── tour, by filename ────────────────────────────────────────────────
    missing = [f for f, _ in TOUR_PICKS if not (src / f).exists()]
    if missing:
        sys.exit(f"missing tour capture(s): {', '.join(missing)}\n"
                 f"The tour's frame numbering changed — update TOUR_PICKS.")
    selected += [(src / f, name) for f, name in TOUR_PICKS]

    # Duplicate detection catches the loudest symptom of drift: two picks
    # that resolved to the same screen. It is not proof the rest are right.
    digests = {}
    for path, name in selected:
        digests.setdefault(hashlib.md5(path.read_bytes()).hexdigest(), []).append(name)
    collisions = [g for g in digests.values() if len(g) > 1]
    if collisions:
        print("WARNING: two picks resolved to the same screen:", file=sys.stderr)
        for group in collisions:
            print(f"  {', '.join(group)}", file=sys.stderr)
        print("  Check the mapping below against the raw captures.\n", file=sys.stderr)

    # Print the mapping, because the tour picks cannot be verified any other
    # way than by a person looking at them.
    print("mapping:")
    for path, name in sorted(selected, key=lambda pair: pair[1]):
        print(f"  {name:<28} <- {path.name}")
    print()

    written = 0
    for label, target in SIZES.items():
        out = dst / label
        out.mkdir(parents=True, exist_ok=True)
        for path, name in selected:
            img = Image.open(path).convert("RGB")
            fit(img, target).save(out / f"{name}.png", "PNG", optimize=True)
            written += 1
        print(f"{label}: {len(selected)} screenshots -> {out}")

    print(f"\n{written} files. Upload each folder to its matching size in "
          f"App Store Connect; the numeric prefixes are the display order.")


if __name__ == "__main__":
    main()
