// Harness smoke test — proves `make edge-test` / the CI edge job are wired.
// Real suites (TS scoring/integrity ports, contract tests) land in Phase L4.

Deno.test("edge test harness is wired", () => {
  const kitCanary = 2 + 2;
  if (kitCanary !== 4) {
    throw new Error("arithmetic is broken; abandon ship");
  }
});

Deno.test("shared fixtures directory is reachable", () => {
  // The xval and contract suites read golden vectors from here.
  const info = Deno.statSync(new URL("../../../fixtures", import.meta.url));
  if (!info.isDirectory) {
    throw new Error("fixtures/ missing — golden vectors have no home");
  }
});
