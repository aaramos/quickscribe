import EvalSupport
import Foundation
import QuickScribeCore

// The before/after experiment for the invented time of day, on its own two
// sentences and with its own runner name, because the question is different:
// does the prompt line keep a.m./p.m. the speaker never said out of the
// text? Every answer is judged twice: did the model try to invent one, and
// did one reach the inserted text anyway.
//
//   time-eval [corpus.json] [runs-per-mode]     default eval/time-corpus.json, 5
//
// Apple's route always runs. The service route runs when QSE_BASE, QSE_MODEL
// and QSE_KEY or QSE_KEYFILE name a server, exactly as cleanup-eval asks.

let argv = CommandLine.arguments
let corpusPath = argv.count > 1 ? argv[1] : "eval/time-corpus.json"
let runs = argv.count > 2 ? (Int(argv[2]) ?? 5) : 5
let items = try! evalCorpus(corpusPath)

func prompt(for variant: String) -> String {
    let mode = evalGuardMode(variant)
    if variant.hasPrefix("service_") { return ServicePrompts.all[mode] ?? "" }
    if mode == FactoryPrompts.rewriteID { return FactoryPrompts.rewrite }
    return FactoryPrompts.all[mode] ?? ""
}

let variants = ["polish", "concise", "active_voice", "rewrite"]
    + (evalServiceNamed() ? ["service_polish", "service_concise", "service_active_voice", "service_rewrite"] : [])

var tried = 0, reached = 0, total = 0
for variant in variants {
    let cleaner: any Cleaning = variant.hasPrefix("service_") ? evalServiceCleaner() : AppleCleaner(filter: .permissive)
    for run in 1...runs {
        for item in items {
            let tidied = TextCleanup.tidy(item.raw)
            total += 1
            do {
                let answer = try await cleaner.clean(tidied, instructions: prompt(for: variant))
                let inventedAnswer = CleanupGuard.inventsTimeOfDay(output: answer, input: tidied)
                let inserted = CleanupGuard.refusal(output: answer, input: tidied,
                                                    mode: evalGuardMode(variant)) == nil ? answer : tidied
                let reachedText = CleanupGuard.inventsTimeOfDay(output: inserted, input: tidied)
                tried += inventedAnswer ? 1 : 0
                reached += reachedText ? 1 : 0
                evalEmit(["id": item.id, "variant": variant, "run": run,
                          "invented_answer": inventedAnswer, "reached_text": reachedText,
                          "guarded": !inventedAnswer && inserted != answer])
            } catch {
                evalEmit(["id": item.id, "variant": variant, "run": run, "error": "\(error)"])
            }
        }
    }
}
print("SUMMARY runs=\(total) invented_by_model=\(tried) reached_text=\(reached)")
