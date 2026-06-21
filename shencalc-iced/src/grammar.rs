//! Port of `CASTools.swift` — the deterministic half of English mode.
//!
//! The language model never does math; it only emits ONE tool call (e.g.
//! `INTEGRATE(x^2; x)`) chosen from a fixed menu. This module owns:
//!   1. the system prompt (the tool menu + grammar + few-shot examples),
//!   2. a parser that turns the model's tool call into shen-cas bracket syntax,
//!   3. `normalize_expr`, best-effort fix-ups (sin(x) -> Sin[x], ln -> Log).
//!
//! Swift assembles the final CAS expression, so the operation can't be wrong —
//! at worst the operand expression is rejected by the CAS reader. Kept in
//! lock-step with the Swift registry so the prompt always matches the parser.

use std::sync::LazyLock;

use regex::Regex;

struct Tool {
    tag: &'static str,
    /// operand count: 2 => "expr; var", 1 => "expr".
    arity: usize,
    /// the few-shot line shown in the prompt.
    example: &'static str,
}

const TOOLS: &[Tool] = &[
    Tool { tag: "D", arity: 2, example: r#""derivative of sin x"            -> D(Sin[x]; x)"# },
    Tool { tag: "INTEGRATE", arity: 2, example: r#""integrate x squared wrt x"       -> INTEGRATE(x^2; x)"# },
    Tool { tag: "SOLVE", arity: 2, example: r#""solve x^2 = 4 for x"             -> SOLVE(x^2 - 4; x)"# },
    Tool { tag: "SIMPLIFY", arity: 1, example: r#""simplify a plus a"               -> SIMPLIFY(a + a)"# },
    Tool { tag: "EXPAND", arity: 1, example: r#""expand (x+1) squared"            -> EXPAND((x+1)^2)"# },
    Tool { tag: "FACTOR", arity: 1, example: r#""factor x squared minus one"      -> FACTOR(x^2 - 1)"# },
    Tool { tag: "EVAL", arity: 1, example: r#""what is two plus three"          -> EVAL(2 + 3)"# },
];

fn is_known(tag: &str) -> bool {
    TOOLS.iter().any(|t| t.tag == tag)
}

/// System prompt: the tool menu + grammar + few-shot examples, generated from
/// the registry so it always matches the parser.
pub fn system_prompt() -> String {
    let menu = TOOLS
        .iter()
        .map(|t| {
            let argv = if t.arity == 2 { "expr; var" } else { "expr" };
            format!("  {}({argv})", t.tag)
        })
        .collect::<Vec<_>>()
        .join("\n");
    let examples = TOOLS
        .iter()
        .map(|t| format!("  {}", t.example))
        .collect::<Vec<_>>()
        .join("\n");
    format!(
        "You translate a math question into ONE tool call for a computer-algebra\n\
         system. Output ONLY the tool call on a single line — no prose, no\n\
         explanation, no markdown, no \"=\".\n\
         \n\
         Available tools (pick exactly one):\n\
         {menu}\n\
         \n\
         Writing expressions inside a tool call:\n\
         - numbers and variables as-is: 2, 42, x, y, a, b\n\
         - arithmetic infix: a + b, a - b, a * b, a / b, a^b\n\
         - named functions ALWAYS in square brackets: Sin[x], Cos[x], Tan[x],\n\
         \x20 Exp[x], Log[x], Sqrt[x]   (Log is natural log; write e^x as Exp[x])\n\
         - for SOLVE, move everything to one side: \"x^2 = 4\" becomes x^2 - 4\n\
         - if no variable is named for D / INTEGRATE / SOLVE, use x\n\
         \n\
         Examples:\n\
         {examples}\n\
         \n\
         Now output the single tool call for the user's request."
    )
}

/// Parse a model reply into a CAS expression. Falls back to treating the whole
/// reply as a raw CAS expression if it isn't a recognised tool call.
pub fn parse(reply: &str) -> String {
    let line = first_meaningful_line(reply);
    if let Some((tag, args)) = split_call(&line) {
        let utag = tag.to_uppercase();
        if is_known(&utag) {
            let ops: Vec<String> = if args.is_empty() {
                vec![String::new()]
            } else {
                args.iter().map(|a| normalize_expr(a)).collect()
            };
            return build_cas(&utag, &ops);
        }
    }
    // Not a tool call — maybe the model emitted raw CAS syntax. Normalize and
    // pass it through so the CAS reader gets its best shot.
    normalize_expr(&line)
}

/// Assemble the final shen-cas bracket expression for a recognised tool.
fn build_cas(tag: &str, ops: &[String]) -> String {
    let a0 = ops.first().map(String::as_str).unwrap_or("");
    let var = arg(ops, 1, "x");
    match tag {
        "D" => format!("D[{a0}, {var}]"),
        "INTEGRATE" => format!("Integrate[{a0}, {var}]"),
        "SOLVE" => format!("Solve[{a0}, {var}]"),
        "SIMPLIFY" => format!("Simplify[{a0}]"),
        "EXPAND" => format!("Expand[{a0}]"),
        "FACTOR" => format!("Factor[{a0}]"),
        // EVAL (and any fallthrough): the operand is the expression itself.
        _ => a0.to_string(),
    }
}

fn arg(a: &[String], i: usize, fallback: &str) -> String {
    a.get(i)
        .filter(|s| !s.is_empty())
        .cloned()
        .unwrap_or_else(|| fallback.to_string())
}

/// Strip code fences / labels and take the first non-empty line.
fn first_meaningful_line(s: &str) -> String {
    let t = s.replace("```", "").replace("Output:", "");
    t.lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or_else(|| t.trim())
        .to_string()
}

/// Split "TAG(a; b)" into ("TAG", ["a", "b"]). Tolerates trailing junk.
fn split_call(s: &str) -> Option<(String, Vec<String>)> {
    let open = s.find('(')?;
    let close = s.rfind(')')?;
    if open >= close {
        return None;
    }
    let tag = s[..open].trim().to_string();
    if tag.is_empty() || !tag.chars().all(|c| c.is_ascii_alphabetic()) {
        return None;
    }
    let inside = &s[open + 1..close];
    let args = inside.split(';').map(|a| a.trim().to_string()).collect();
    Some((tag, args))
}

/// (?i)\bFUNC\s*[([]\s*(...)\s*[)\]] -> CANON[$1], for each loose function form.
static FUNC_RES: LazyLock<Vec<(Regex, &'static str)>> = LazyLock::new(|| {
    [
        ("sin", "Sin"),
        ("cos", "Cos"),
        ("tan", "Tan"),
        ("exp", "Exp"),
        ("sqrt", "Sqrt"),
        ("log", "Log"),
        ("ln", "Log"),
    ]
    .iter()
    .map(|(lower, canon)| {
        let pat = format!(r"(?i)\b{lower}\s*[\(\[]\s*([^\)\]]*?)\s*[\)\]]");
        (Regex::new(&pat).expect("valid func regex"), *canon)
    })
    .collect()
});

/// Best-effort fix-ups so loose model output still reads in the CAS:
/// lowercase / paren-form functions -> bracket form, `ln`/`e^` aliases.
pub fn normalize_expr(raw: &str) -> String {
    let mut s = raw.trim().to_string();
    for (re, canon) in FUNC_RES.iter() {
        s = re.replace_all(&s, format!("{canon}[${{1}}]").as_str()).into_owned();
    }
    s
}

#[cfg(test)]
mod tests {
    use super::{normalize_expr, parse, system_prompt};

    #[test]
    fn tool_calls_match_swift() {
        // Mirrors the toolChecks in the Swift self-test.
        assert_eq!(parse("INTEGRATE(x^2; x)"), "Integrate[x^2, x]");
        assert_eq!(parse("D(Sin[x]; x)"), "D[Sin[x], x]");
        assert_eq!(parse("FACTOR(x^2 - 1)"), "Factor[x^2 - 1]");
        assert_eq!(parse("SOLVE(x^2 - 4; x)"), "Solve[x^2 - 4, x]");
        assert_eq!(parse("EVAL(2 + 3)"), "2 + 3");
        assert_eq!(parse("integrate(sin(x); x)"), "Integrate[Sin[x], x]");
    }

    #[test]
    fn defaults_missing_var_to_x() {
        assert_eq!(parse("D(x^2)"), "D[x^2, x]");
        assert_eq!(parse("INTEGRATE(x^2;)"), "Integrate[x^2, x]");
    }

    #[test]
    fn strips_fences_and_labels() {
        assert_eq!(parse("```\nFACTOR(x^2 - 1)\n```"), "Factor[x^2 - 1]");
        assert_eq!(parse("Output: EVAL(2 + 3)"), "2 + 3");
    }

    #[test]
    fn normalize_functions() {
        assert_eq!(normalize_expr("sin(x)"), "Sin[x]");
        assert_eq!(normalize_expr("LN(x)"), "Log[x]");
        assert_eq!(normalize_expr("sqrt(x + 1)"), "Sqrt[x + 1]");
    }

    #[test]
    fn prompt_lists_every_tool() {
        let p = system_prompt();
        for tag in ["D(", "INTEGRATE(", "SOLVE(", "SIMPLIFY(", "EXPAND(", "FACTOR(", "EVAL("] {
            assert!(p.contains(tag), "prompt missing {tag}");
        }
    }
}
