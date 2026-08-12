// sogen — Smooooth Operator development CLI.
//
// Simulates telemetry, runs it through the production pipeline, and emits
// golden vectors that anchor both Swift regression tests and Swift↔TS
// scoring cross-validation. Subcommands arrive with the engines (L1+):
//   sogen generate --profile fast_smooth --seed 42
//   sogen score    --input run.telemetry.json --config configs/scoring/v1.json
//   sogen verify   --input run.telemetry.json
//   sogen emit-contracts

import Foundation
import SOCore

let arguments = CommandLine.arguments.dropFirst()

switch arguments.first {
case "version", "--version":
    print("sogen \(KitInfo.version)")
case nil, "help", "--help":
    print(
        """
        sogen \(KitInfo.version) — Smooooth Operator development CLI

        USAGE: sogen <subcommand>

        SUBCOMMANDS:
          version           Print the SmoooothKit version.
          help              Show this help.

        Pipeline subcommands (generate, score, verify, emit-contracts)
        land with the telemetry and scoring engines.
        """
    )
default:
    print("sogen: unknown subcommand '\(arguments.first!)' — run 'sogen help'")
    exit(64)  // EX_USAGE
}
