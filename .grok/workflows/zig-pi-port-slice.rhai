// Zig Pi port vertical-slice orchestrator.
// Standing charter: docs/goals/ZIG_PI_PORT_GOAL.md + ZIG_PI_PORT_PROMPT.md
// Dashboard: docs/PORT_STATUS.md
// Ledgers: docs/{AI,AGENT,CODING_AGENT,TUI}_PARITY.md
//
// Args (all optional):
//   domain     — "auto" | "ai" | "agent" | "coding-agent" | "tui"  (default auto)
//   max_slices — integer 1..5 sequential slices (default 1)
//   prefer     — optional path substring to prefer when picking
//
// Each slice: Pick (read-only) → Implement (all) → Verify (execute).
// Serial only — same zig/ and ledger tree; do not parallelize writers.

let meta = #{
    name: "zig-pi-port-slice",
    description: "One or more Zig Pi port vertical slices: pick ledger gap, implement, offline zig tests, ledger",
    when_to_use: "Continue TS→Zig port under docs/goals/ZIG_PI_PORT_* after upstream merges",
    phases: [
        #{ title: "Pick", detail: "lowest unfinished domain + one TS file/cluster" },
        #{ title: "Implement", detail: "vertical slice + offline shipped-API tests + ledger" },
        #{ title: "Verify", detail: "zig tests green + honesty checks" },
        #{ title: "Report", detail: "slice summary and next gap" },
    ],
};

let pick_schema = #{
    "type": "object",
    "required": ["domain", "ts_source", "zig_target", "status_now", "gaps", "ts_tests", "rationale"],
    "properties": #{
        "domain": #{ "type": "string" },
        "ts_source": #{ "type": "string" },
        "zig_target": #{ "type": "string" },
        "status_now": #{ "type": "string" },
        "gaps": #{
            "type": "array",
            "maxItems": 8,
            "items": #{ "type": "string" },
        },
        "ts_tests": #{ "type": "string" },
        "rationale": #{ "type": "string" },
        "done": #{ "type": "boolean" },
        "done_reason": #{ "type": "string" },
    },
};

let impl_schema = #{
    "type": "object",
    "required": ["ok", "summary", "zig_files", "tests_added", "ledger_rows", "zig_test_green"],
    "properties": #{
        "ok": #{ "type": "boolean" },
        "summary": #{ "type": "string" },
        "zig_files": #{
            "type": "array",
            "maxItems": 20,
            "items": #{ "type": "string" },
        },
        "tests_added": #{
            "type": "array",
            "maxItems": 20,
            "items": #{ "type": "string" },
        },
        "ledger_rows": #{
            "type": "array",
            "maxItems": 10,
            "items": #{ "type": "string" },
        },
        "zig_test_green": #{ "type": "boolean" },
        "test_command": #{ "type": "string" },
        "blockers": #{ "type": "string" },
    },
};

let verify_schema = #{
    "type": "object",
    "required": ["zig_test_green", "packages_untouched_or_justified", "honesty_ok", "notes"],
    "properties": #{
        "zig_test_green": #{ "type": "boolean" },
        "packages_untouched_or_justified": #{ "type": "boolean" },
        "honesty_ok": #{ "type": "boolean" },
        "notes": #{ "type": "string" },
        "fix_hint": #{ "type": "string" },
        "test_command": #{ "type": "string" },
    },
};

// --- args ---
let domain_arg = "auto";
let max_slices = 1;
let prefer = "";
if args != () {
    if args.domain != () { domain_arg = args.domain; }
    if args.max_slices != () {
        let ms = args.max_slices;
        if type_of(ms) == "i64" || type_of(ms) == "int" {
            max_slices = ms;
        } else if type_of(ms) == "string" {
            if ms == "2" { max_slices = 2; }
            else if ms == "3" { max_slices = 3; }
            else if ms == "4" { max_slices = 4; }
            else if ms == "5" { max_slices = 5; }
            else { max_slices = 1; }
        }
    }
    if args.prefer != () { prefer = args.prefer; }
}
if max_slices < 1 { max_slices = 1; }
if max_slices > 5 { max_slices = 5; }

log("zig-pi-port-slice domain=" + domain_arg + " max_slices=" + max_slices.to_string() + " prefer=" + prefer);

let slice_reports = [];
let slice_i = 0;
let stop_early = false;
let stop_reason = "";

while slice_i < max_slices && !stop_early {
    let slice_n = slice_i + 1;
    log("--- slice " + slice_n.to_string() + "/" + max_slices.to_string() + " ---");

    // ========== Pick ==========
    phase("Pick");
    let pick_prompt = "";
    pick_prompt += "You are the Zig Pi port slice picker (read-only).\n";
    pick_prompt += "Repo: pi-mono-zig monorepo. TS source of truth under packages/. Zig under zig/.\n\n";
    pick_prompt += "Charter: docs/goals/ZIG_PI_PORT_PROMPT.md + docs/goals/ZIG_PI_PORT_GOAL.md\n";
    pick_prompt += "Dashboard: docs/PORT_STATUS.md\n";
    pick_prompt += "Hard dependency order: ai → agent → coding-agent → tui.\n";
    pick_prompt += "protocol/server/evals/sqlite-node are deferred unless already in ledger as in-scope.\n\n";
    pick_prompt += "Requested domain filter: " + domain_arg + "\n";
    pick_prompt += "(If auto: pick the LOWEST unfinished domain that still has missing/partial in-scope rows.)\n";
    if prefer != "" {
        pick_prompt += "Prefer TS path containing: " + prefer + " when multiple candidates exist.\n";
    }
    pick_prompt += "\nYOU MUST use tools (read_file, grep, list_dir). Do not answer from memory.\n";
    pick_prompt += "1. Read docs/PORT_STATUS.md.\n";
    pick_prompt += "2. Open the relevant ledger: docs/AI_PARITY.md, docs/AGENT_PARITY.md, docs/CODING_AGENT_PARITY.md, or docs/TUI_PARITY.md.\n";
    pick_prompt += "3. Find the first high-value missing/partial row that unblocks dependents (agent session storage before random coding-agent utils).\n";
    pick_prompt += "4. Open matching packages/*/src file and note behavioral gaps vs Zig under zig/src/.\n";
    pick_prompt += "5. Find TS tests under packages/*/test if present.\n\n";
    pick_prompt += "CRITICAL SCOPE: pick a slice that ONE implementer can finish in ~15-25 tool turns.\n";
    pick_prompt += "Prefer a SMALL API cluster (e.g. reject unsupported session search only), not entire agent-harness.\n";
    pick_prompt += "gaps[0] MUST be the single primary deliverable; gaps[1..] are optional stretch only.\n";
    pick_prompt += "Return JSON: domain, ts_source (path under packages/), zig_target, status_now (partial|missing), gaps, ts_tests, rationale.\n";
    pick_prompt += "If the filtered domain is fully implemented/deferred-only, set done=true and done_reason; still fill other fields best-effort.\n";
    pick_prompt += "Empty gaps only after you inspected ledgers with tools.\n";

    let pick = agent(pick_prompt, #{
        label: "pick-" + slice_n.to_string(),
        capability_mode: "read-only",
        output_schema: pick_schema,
    });

    if pick == () || !pick.success || pick.output == () {
        stop_early = true;
        stop_reason = "pick agent failed on slice " + slice_n.to_string();
        log(stop_reason);
        break;
    }

    let p = pick.output;
    if p.done == true {
        stop_early = true;
        stop_reason = "picker reports domain complete: ";
        if p.done_reason != () { stop_reason += p.done_reason; } else { stop_reason += "(no reason)"; }
        log(stop_reason);
        slice_reports.push(#{
            slice: slice_n,
            phase: "pick-done",
            domain: p.domain,
            ts_source: p.ts_source,
            reason: stop_reason,
        });
        break;
    }

    let pick_json = json_encode(p);
    log("picked " + p.domain + " :: " + p.ts_source);

    // ========== Implement ==========
    phase("Implement");
    let impl_prompt = "";
    impl_prompt += "You are the Zig Pi port implementer for ONE vertical slice.\n";
    impl_prompt += "Standing rules: docs/goals/ZIG_PI_PORT_PROMPT.md — follow completely.\n";
    impl_prompt += "TS under packages/ is behavioral reference. Implement in zig/. Prefer not to edit packages/ unless a clear TS bug blocks the slice (then note it).\n";
    impl_prompt += "NEVER mark implemented without offline tests on shipped Zig APIs.\n";
    impl_prompt += "Use deferred ONLY for Exclusion List in the goal. Prefer partial over fake implemented.\n";
    impl_prompt += "If zig tests are red at start for your area, fix red first only if caused by your tree; do not expand scope.\n\n";
    impl_prompt += "THIS SLICE (from picker — do not change target file):\n";
    impl_prompt += pick_json;
    impl_prompt += "\n\nHARD SCOPE LIMIT:\n";
    impl_prompt += "- Implement ONLY gaps[0]. Ignore gaps[1..] unless free after green tests.\n";
    impl_prompt += "- Do NOT rewrite whole harness/session/model-runtime stacks in one turn.\n";
    impl_prompt += "- Stop after: code for gaps[0] + offline tests + ledger note + targeted zig test green.\n";
    impl_prompt += "- Prefer pure/IO APIs with mock streamFn. No live network.\n\n";
    impl_prompt += "Required work:\n";
    impl_prompt += "1. Read TS at ts_source and existing Zig zig_target.\n";
    impl_prompt += "2. Implement behavioral parity for gaps[0] only.\n";
    impl_prompt += "3. Port/add offline tests in Zig test blocks. Comment: // Pi: <ts path> \"case\".\n";
    impl_prompt += "4. Tests MUST call shipped public Zig APIs.\n";
    impl_prompt += "5. Update ledger row(s) honestly; update docs/PORT_STATUS.md Recent briefly.\n";
    impl_prompt += "6. Run the narrowest relevant: `cd zig && zig build test-ai|test-agent|test-coding-agent|test-tui` or full `zig build test` if cheap enough. Leave green before finishing.\n";
    impl_prompt += "7. Do not touch unrelated domains. Follow AGENTS.md Zig notes (stream contract, keybindings).\n";
    impl_prompt += "8. Do not commit unless the user asked. Stage only files you changed.\n\n";
    impl_prompt += "Return JSON: ok, summary, zig_files[], tests_added[], ledger_rows[], zig_test_green, test_command, blockers.\n";
    impl_prompt += "If you only finish gaps[0], ok=true is fine while ledger remains partial.\n";

    let impl = agent(impl_prompt, #{
        label: "impl-" + slice_n.to_string(),
        capability_mode: "all",
        output_schema: impl_schema,
    });

    if impl == () || !impl.success || impl.output == () {
        stop_early = true;
        stop_reason = "implement agent failed on slice " + slice_n.to_string();
        log(stop_reason);
        slice_reports.push(#{
            slice: slice_n,
            phase: "impl-failed",
            domain: p.domain,
            ts_source: p.ts_source,
            reason: stop_reason,
        });
        break;
    }

    let im = impl.output;
    let impl_json = json_encode(im);
    if im.ok != true || im.zig_test_green != true {
        log("implement reported incomplete ok=" + (if im.ok == true { "true" } else { "false" })
            + " zig_test_green=" + (if im.zig_test_green == true { "true" } else { "false" }));
    }

    // ========== Verify ==========
    phase("Verify");
    let ver_prompt = "";
    ver_prompt += "You are the Zig Pi port verifier for one slice. Fail closed.\n";
    ver_prompt += "Use shell/tools. Do not trust the implementer report without checking.\n\n";
    ver_prompt += "Picker target:\n";
    ver_prompt += pick_json;
    ver_prompt += "\n\nImplementer claim:\n";
    ver_prompt += impl_json;
    ver_prompt += "\n\nChecks (all required):\n";
    ver_prompt += "1. Re-run the claimed test_command (or domain default under zig/). zig_test_green = exit 0.\n";
    ver_prompt += "2. packages_untouched_or_justified=true if packages/ is unchanged OR only justified tiny TS bugfix with explanation in notes.\n";
    ver_prompt += "3. Honesty: open ledger rows claimed implemented; if tests don't call shipped APIs, honesty_ok=false and note demotion.\n";
    ver_prompt += "4. If tests red, zig_test_green=false and fix_hint (file + symptom).\n";
    ver_prompt += "5. notes: short factual summary of what you verified.\n";

    let ver = agent(ver_prompt, #{
        label: "verify-" + slice_n.to_string(),
        capability_mode: "execute",
        output_schema: verify_schema,
    });

    let ver_ok = false;
    let ver_notes = "";
    let zig_green = false;
    let pkgs_ok = false;
    let honesty = false;
    if ver != () && ver.success && ver.output != () {
        let v = ver.output;
        zig_green = v.zig_test_green == true;
        pkgs_ok = v.packages_untouched_or_justified == true;
        honesty = v.honesty_ok == true;
        ver_ok = zig_green && pkgs_ok && honesty;
        if v.notes != () { ver_notes = v.notes; }
        if !ver_ok {
            stop_early = true;
            stop_reason = "verify failed slice " + slice_n.to_string() + ": " + ver_notes;
            if v.fix_hint != () { stop_reason += " | fix: " + v.fix_hint; }
            log(stop_reason);
        }
    } else {
        stop_early = true;
        stop_reason = "verify agent failed on slice " + slice_n.to_string();
        log(stop_reason);
    }

    slice_reports.push(#{
        slice: slice_n,
        domain: p.domain,
        ts_source: p.ts_source,
        zig_target: p.zig_target,
        impl_ok: im.ok == true,
        zig_test_green: zig_green,
        packages_ok: pkgs_ok,
        honesty_ok: honesty,
        summary: im.summary,
        verify_notes: ver_notes,
    });

    if stop_early { break; }
    slice_i += 1;
}

// ========== Report ==========
phase("Report");
let report = "";
report += "# zig-pi-port-slice report\n\n";
report += "- domain_arg: " + domain_arg + "\n";
report += "- max_slices: " + max_slices.to_string() + "\n";
report += "- prefer: " + prefer + "\n";
report += "- slices_attempted: " + slice_reports.len().to_string() + "\n";
if stop_reason != "" {
    report += "- stop_reason: " + stop_reason + "\n";
}
report += "\n## Slices\n\n";
report += json_encode(slice_reports);
report += "\n\n## Next operator step\n\n";
report += "Re-run `/workflow zig-pi-port-slice` or continue `/goal` with docs/goals/ZIG_PI_PORT_GOAL.md.\n";
report += "Order: ai → agent → coding-agent → tui. One vertical slice per turn when working manually.\n";

let report_path = write_scratch_file("zig-port-slice-report.md", report);
log("wrote " + report_path);

complete(#{
    path: report_path,
    report: report,
    domain: domain_arg,
    max_slices: max_slices,
    slices: slice_reports,
    stop_reason: stop_reason,
    success: !stop_early || slice_reports.len() > 0,
});
