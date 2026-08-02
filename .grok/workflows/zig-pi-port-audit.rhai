// Read-only honesty audit for Zig Pi port ledgers.
// Args: domain optional "auto"|"ai"|"agent"|"coding-agent"|"tui"

let meta = #{
    name: "zig-pi-port-audit",
    description: "Audit Zig/TS parity ledgers for inflated implemented rows and inventory gaps",
    when_to_use: "Before or between zig-pi-port-slice runs when ledger honesty is in doubt, or after large upstream merges",
    phases: [
        #{ title: "Audit", detail: "scan ledgers vs packages/ inventory" },
        #{ title: "Report", detail: "demote candidates and missing inventory" },
    ],
};

let audit_schema = #{
    "type": "object",
    "required": ["demote_candidates", "missing_inventory", "notes"],
    "properties": #{
        "demote_candidates": #{
            "type": "array",
            "maxItems": 30,
            "items": #{
                "type": "object",
                "required": ["ledger", "ts_source", "reason"],
                "properties": #{
                    "ledger": #{ "type": "string" },
                    "ts_source": #{ "type": "string" },
                    "reason": #{ "type": "string" },
                },
            },
        },
        "missing_inventory": #{
            "type": "array",
            "maxItems": 30,
            "items": #{ "type": "string" },
        },
        "priority_next": #{
            "type": "array",
            "maxItems": 10,
            "items": #{ "type": "string" },
        },
        "notes": #{ "type": "string" },
        "package_counts": #{ "type": "string" },
    },
};

let domain_arg = "auto";
if args != () && args.domain != () { domain_arg = args.domain; }

phase("Audit");
let prompt = "";
prompt += "You audit Zig Pi port parity ledgers for honesty (read-only).\n";
prompt += "Domain filter: " + domain_arg + " (auto = ai, agent, coding-agent, tui).\n\n";
prompt += "MUST use tools. Read docs/PORT_STATUS.md and docs/*_PARITY.md.\n";
prompt += "Spot-check rows marked implemented: open Zig module + tests for shipped-API tests.\n";
prompt += "If a row claims implemented but lacks tests calling shipped APIs, add demote_candidates (demote to partial).\n";
prompt += "Compare inventory: list packages/<pkg>/src/** vs zig/src/** and ledger rows for gaps (missing_inventory).\n";
prompt += "priority_next: 3-8 concrete next slice titles ordered by goal priority (agent session storage before polish).\n";
prompt += "Do NOT edit files. package_counts: short text counts per domain if computed.\n";
prompt += "Empty demote_candidates is valid only after tool-based spot checks of several implemented rows.\n";

let r = agent(prompt, #{
    label: "ledger-audit",
    capability_mode: "read-only",
    output_schema: audit_schema,
});

phase("Report");
if r == () || !r.success || r.output == () {
    complete(#{ summary: "audit agent failed", success: false });
}

let body = "";
body += "# zig-pi-port-audit\n\n";
body += json_encode(r.output);
body += "\n";
let path = write_scratch_file("zig-port-ledger-audit.md", body);
log("wrote " + path);
complete(#{ path: path, report: body, result: r.output, success: true });
