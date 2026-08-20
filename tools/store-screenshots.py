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

# The ten worth uploading, in the order they should appear on the listing.
# Screenshot 1 is what most people see, so it leads with the product in
# motion rather than with an onboarding slide.
CURATED = [
    ("tour-11.png",    "01-live-run-ghost-delta"),
    ("tour-12.png",    "02-run-complete-verified"),
    ("tour-09.png",    "03-course-detail"),
    ("onboard-02.png", "04-four-disciplines"),
    ("tour-23.png",    "05-share-card"),
    ("onboard-03.png", "06-every-run-verified"),
    ("tour-27.png",    "07-flying-start-not-ranked"),
    ("onboard-01.png", "08-pick-a-course"),
    ("onboard-06.png", "09-roads-near-you"),
    ("onboard-04.png", "10-drive-safe"),
]

# Deliberately excluded: tour-01/03/05/07/24 (Home, Explore, Leaderboards,
# Profile, Garage). All five render signed-out or empty against CI's absent
# backend; Explore shows an outright error. Re-shoot them on a signed-in
# device once the backend is deployed.


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
        sys.exit(__doc__.strip().splitlines()[-1].strip())
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    if not src.is_dir():
        sys.exit(f"no such directory: {src}")

    missing = [f for f, _ in CURATED if not (src / f).exists()]
    if missing:
        # Loud, because a renamed capture silently shrinking the set from
        # ten to eight is exactly the kind of thing nobody notices.
        sys.exit(f"missing {len(missing)} expected capture(s): {', '.join(missing)}\n"
                 f"The tour's frame numbering changed — update CURATED.")

    # CURATED indexes frames by POSITION IN TIME, and the tour captures on a
    # fixed 2s timer. Run it on a slower simulator and every screen slides to
    # a different number — the files all still exist, so the check above
    # passes, and you get ten valid screenshots of the wrong screens.
    #
    # There is no cheap way to confirm a frame shows what it should. What
    # duplicate detection CAN catch is the loudest symptom: if two picks are
    # byte-identical, the tour has drifted far enough that distinct moments
    # collapsed onto one screen. Treat a warning here as "re-check the
    # numbering by eye", not as the only thing that can go wrong.
    digests = {}
    for filename, name in CURATED:
        digest = hashlib.md5((src / filename).read_bytes()).hexdigest()
        digests.setdefault(digest, []).append(f"{filename} ({name})")
    collisions = [group for group in digests.values() if len(group) > 1]
    if collisions:
        print("WARNING: curated frames are not all distinct — the tour's "
              "timing has probably shifted.", file=sys.stderr)
        for group in collisions:
            print(f"  identical: {', '.join(group)}", file=sys.stderr)
        print("  Open the raw captures and re-map CURATED before uploading.\n",
              file=sys.stderr)

    written = 0
    for label, target in SIZES.items():
        out = dst / label
        out.mkdir(parents=True, exist_ok=True)
        for filename, name in CURATED:
            img = Image.open(src / filename).convert("RGB")
            fit(img, target).save(out / f"{name}.png", "PNG", optimize=True)
            written += 1
        print(f"{label}: {len(CURATED)} screenshots -> {out}")

    print(f"\n{written} files. Upload each folder to its matching size in "
          f"App Store Connect; the numeric prefixes are the display order.")


if __name__ == "__main__":
    main()
