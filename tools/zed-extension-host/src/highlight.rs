use anyhow::{Context, Result};
use serde_json::{json, Value};
use std::{
    fs,
    io::{self, Read, Write},
    path::Path,
};
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
pub const SOURCE_LIMIT: usize = 8 * 1024 * 1024;
const METADATA_LIMIT: usize = 64 * 1024;
const RESPONSE_LIMIT: usize = 64 * 1024 * 1024;

pub fn run(grammar: &Path, name: &str, query: &Path, source: &str) -> Result<Value> {
    Session::default().highlight(grammar, name, query, source)
}

#[derive(Default)]
struct Session {
    // Consuming the highlight iterator returns its query cursor to this pool.
    highlighter: Highlighter,
    engine: Option<wasmtime::Engine>,
}

impl Session {
    fn highlight(
        &mut self,
        grammar: &Path,
        name: &str,
        query: &Path,
        source: &str,
    ) -> Result<Value> {
        let (language, query, store) = if grammar == Path::new("@builtin") {
            let (language, query) = crate::languages::grammar(name)?;
            (language, query, None)
        } else {
            let engine = self.engine.get_or_insert_with(wasmtime::Engine::default);
            let mut store = tree_sitter::WasmStore::new(engine)?;
            let language = store.load_language(name, &fs::read(grammar)?)?;
            (language, fs::read_to_string(query)?, Some(store))
        };
        let mut config = HighlightConfiguration::new(language, name, &query, "", "")?;
        config.configure(NAMES);
        if let Some(store) = store {
            self.highlighter.parser().set_wasm_store(store)?;
        }
        let result = spans(&mut self.highlighter, &config, source);
        // Drop per-request WASM instances while keeping the parser and cursor pool.
        self.highlighter.parser().take_wasm_store();
        result
    }
}

fn spans(
    highlighter: &mut Highlighter,
    config: &HighlightConfiguration,
    source: &str,
) -> Result<Value> {
    let events = highlighter.highlight(config, source.as_bytes(), None, |_| None)?;
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

pub fn serve() -> Result<()> {
    serve_stream(io::stdin().lock(), io::stdout().lock())
}

fn serve_stream(mut input: impl Read, mut output: impl Write) -> Result<()> {
    let mut session = Session::default();
    let mut header = [0; 8];
    let mut metadata = Vec::new();
    let mut source = Vec::new();
    // Lengths are little-endian u32. Read one byte separately so a clean EOF
    // (window closed) is distinguishable from a truncated request.
    while input.read(&mut header[..1])? != 0 {
        input.read_exact(&mut header[1..])?;
        let metadata_len = u32::from_le_bytes(header[..4].try_into()?) as usize;
        let source_len = u32::from_le_bytes(header[4..].try_into()?) as usize;
        anyhow::ensure!(
            metadata_len <= METADATA_LIMIT,
            "highlight metadata exceeds 64 KiB"
        );
        anyhow::ensure!(source_len <= SOURCE_LIMIT, "source exceeds 8 MiB");
        metadata.resize(metadata_len, 0);
        source.resize(source_len, 0);
        input.read_exact(&mut metadata)?;
        input.read_exact(&mut source)?;
        let result = (|| {
            let [grammar, name, query]: [String; 3] =
                serde_json::from_slice(&metadata).context("invalid highlight metadata")?;
            let text = std::str::from_utf8(&source).context("invalid UTF-8 source")?;
            let result = session.highlight(Path::new(&grammar), &name, Path::new(&query), text)?;
            let response = serde_json::to_vec(&result)?;
            anyhow::ensure!(response.len() <= RESPONSE_LIMIT, "highlights exceed 64 MiB");
            Ok(response)
        })();
        let (status, mut body) = match result {
            Ok(body) => (1, body),
            Err(error) => (0, format!("{error:#}").into_bytes()),
        };
        if status == 0 {
            let mut end = body.len().min(METADATA_LIMIT);
            while end < body.len() && body[end] & 0xc0 == 0x80 {
                end -= 1;
            }
            body.truncate(end);
        }
        output.write_all(&[status])?;
        output.write_all(&(body.len() as u32).to_le_bytes())?;
        output.write_all(&body)?;
        output.flush()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_matches_one_shot_across_an_error_and_grammar_switch() -> Result<()> {
        let requests = [
            ("rust", "fn main() { let name = \"🙂\"; }"),
            ("missing-grammar", "ignore"),
            ("json", "{\"name\": \"日本語\", \"ready\": true}"),
            ("rust", "// different source\nfn foo() {}"),
        ];
        let mut input = Vec::new();
        for (name, source) in requests {
            let metadata = serde_json::to_vec(&["@builtin", name, ""])?;
            input.extend_from_slice(&(metadata.len() as u32).to_le_bytes());
            input.extend_from_slice(&(source.len() as u32).to_le_bytes());
            input.extend_from_slice(&metadata);
            input.extend_from_slice(source.as_bytes());
        }
        let mut output = Vec::new();
        serve_stream(input.as_slice(), &mut output)?;
        let mut output = output.as_slice();
        for (name, source) in requests {
            let size = u32::from_le_bytes(output[1..5].try_into()?) as usize;
            let body = &output[5..5 + size];
            if name == "missing-grammar" {
                assert_eq!(output[0], 0);
                assert!(std::str::from_utf8(body)?.contains(name));
            } else {
                assert_eq!(output[0], 1);
                let expected = run(Path::new("@builtin"), name, Path::new(""), source)?;
                assert_eq!(serde_json::from_slice::<Value>(body)?, expected);
            }
            output = &output[5 + size..];
        }
        assert!(output.is_empty());
        Ok(())
    }
}
