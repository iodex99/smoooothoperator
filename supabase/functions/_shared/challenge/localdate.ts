// Local-date resolution (directive §16): Today's Challenge resets on the
// USER'S calendar day, never a global UTC moment. Preference order:
// client-declared IANA timezone (the phone always knows it) → longitude
// approximation (15°/hour) → UTC. Nothing is hard-coded to any region.

/** YYYY-MM-DD in the user's local calendar. */
export function localDate(
  timezone: string | null,
  longitude: number | null,
  now: Date = new Date(),
): string {
  if (timezone) {
    try {
      // en-CA formats as YYYY-MM-DD.
      return new Intl.DateTimeFormat("en-CA", {
        timeZone: timezone,
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
      }).format(now);
    } catch {
      // Unknown zone string — fall through to longitude.
    }
  }
  const offsetHours = longitude === null ? 0 : Math.round(longitude / 15);
  const shifted = new Date(now.getTime() + offsetHours * 3_600_000);
  return shifted.toISOString().slice(0, 10);
}

/** Start of the user's local day as a UTC instant — the window for honest
 * "participants today" counts. */
export function localDayStart(
  timezone: string | null,
  longitude: number | null,
  now: Date = new Date(),
): Date {
  const date = localDate(timezone, longitude, now);
  const offsetHours = timezone
    ? timezoneOffsetHours(timezone, now)
    : (longitude === null ? 0 : Math.round(longitude / 15));
  return new Date(Date.parse(`${date}T00:00:00Z`) - offsetHours * 3_600_000);
}

function timezoneOffsetHours(timezone: string, now: Date): number {
  try {
    const parts = new Intl.DateTimeFormat("en-US", {
      timeZone: timezone,
      timeZoneName: "shortOffset",
    }).formatToParts(now);
    const label = parts.find((p) => p.type === "timeZoneName")?.value ?? "GMT";
    const match = label.match(/GMT([+-])(\d{1,2})(?::(\d{2}))?/);
    if (!match) return 0;
    const sign = match[1] === "-" ? -1 : 1;
    return sign * (Number(match[2]) + Number(match[3] ?? 0) / 60);
  } catch {
    return 0;
  }
}
