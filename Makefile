# Smooooth Operator — developer entrypoints.
# All targets must stay green on Linux; see docs/TESTING.md.

SWIFT ?= swift
DENO ?= deno
SUPABASE ?= supabase

.PHONY: test kit-test db-test edge-test xval regen-goldens syntax-check lint

## Run every Linux-verifiable test suite (the definition of "green").
test: kit-test db-test edge-test syntax-check

## SwiftPM package: build + unit/property/golden tests.
kit-test:
	cd SmoooothKit && $(SWIFT) build && $(SWIFT) test

## pgTAP schema + RLS tests against the local Supabase stack.
db-test:
	$(SUPABASE) test db

## Edge function unit tests (scoring/integrity TS ports, contracts).
edge-test:
	cd supabase/functions && $(DENO) test --allow-read=../../fixtures,../../configs

## End-to-end: golden run through storage + score-run against the LOCAL stack
## (requires `supabase start`; skips itself when the stack is down).
e2e-test:
	cd supabase/functions && $(DENO) test --allow-read=../../fixtures,../../configs --allow-net tests/score_run_integration_test.ts

## Cross-validate Swift reference scorer against the TS port on all golden vectors.
xval:
	tools/xval.sh

## Regenerate golden fixtures via sogen. Deliberate act — review the diff.
regen-goldens:
	tools/regen-goldens.sh

## Parse-check the iOS layer on Linux (no type resolution — see docs/TESTING.md).
syntax-check:
	tools/ios-syntax-check.sh

## Enforce Kit purity: no Apple-only framework imports in SmoooothKit.
lint:
	tools/kit-purity-check.sh
