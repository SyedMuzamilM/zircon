use anyhow::Result;
use serde_json::{json, Value};
use std::{fs, path::Path};
use tree_sitter_highlight::{HighlightConfiguration, HighlightEvent, Highlighter};
const NAMES: &[&str] = &[
    "variable",
    "keyword",
    "string",
    "number",
    "comment",
    "punctuation",
    "function",
    "type",
    "property",
    "constant",
    "operator",
    "boolean",
    "constructor",
    "tag",
    "attribute",
];
pub fn run(grammar: &Path, name: &str, query: &Path, source: &str) -> Result<Value> {
    let engine = wasmtime::Engine::default();
    let (language, query, store) = if grammar == Path::new("@builtin") {
        let (language, query) = crate::languages::grammar(name)?;
        (language, query, None)
    } else {
        let mut store = tree_sitter::WasmStore::new(&engine)?;
        let language = store.load_language(name, &fs::read(grammar)?)?;
        (language, fs::read_to_string(query)?, Some(store))
    };
    let mut config = HighlightConfiguration::new(language, name, &query, "", "")?;
    config.configure(NAMES);
    let mut highlighter = Highlighter::new();
    if let Some(store) = store {
        highlighter.parser().set_wasm_store(store)?;
    }
    let events = highlighter.highlight(&config, source.as_bytes(), None, |_| None)?;
    let mut stack = Vec::new();
    let mut spans = Vec::new();
    for event in events {
        match event? {
            HighlightEvent::HighlightStart(highlight) => stack.push(highlight.0),
            HighlightEvent::HighlightEnd => {
                stack.pop();
            }
            HighlightEvent::Source { start, end } => {
                if let Some(kind) = stack.last() {
                    let kind = match *kind {
                        1 | 10 | 11 => "keyword",
                        2 => "string",
                        3 => "number",
                        4 => "comment",
                        5 => "punctuation",
                        0 | 8 => "plain",
                        _ => "builtin",
                    };
                    if spans.len() > 1_000_000 {
                        anyhow::bail!("too many highlights");
                    }
                    spans.push(json!({"start":start,"end":end,"kind":kind}));
                }
            }
        }
    }
    Ok(json!({"spans":spans,"bytes":source.len()}))
}
