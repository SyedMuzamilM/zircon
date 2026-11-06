use anyhow::{bail, Context, Result};
use regex::RegexBuilder;
use serde_json::{json, Value};
pub fn run(v: &Value) -> Result<Value> {
    let source = v["source"].as_str().context("missing source")?;
    let query = v["query"].as_str().context("missing query")?;
    if source.len() > 8 * 1024 * 1024 || query.len() > 64 * 1024 {
        bail!("search input too large");
    }
    if query.is_empty() {
        return Ok(json!({"matches":[],"truncated":false}));
    }
    let pattern = if v["regex"].as_bool().unwrap_or(false) {
        query.to_owned()
    } else {
        regex::escape(query)
    };
    let regex = RegexBuilder::new(&pattern)
        .case_insensitive(!v["case_sensitive"].as_bool().unwrap_or(false))
        .multi_line(true)
        .size_limit(1024 * 1024)
        .build()?;
    let whole = v["whole_word"].as_bool().unwrap_or(false);
    let word = |c: char| c.is_alphanumeric() || c == '_';
    let replacement = v["replacement"].as_str().unwrap_or("");
    let mut matches = Vec::new();
    let mut truncated = false;
    let mut output_bytes = 0usize;
    for cap in regex.captures_iter(source) {
        let m = cap.get(0).context("missing match")?;
        if whole
            && (source[..m.start()].chars().next_back().is_some_and(word)
                || source[m.end()..].chars().next().is_some_and(word))
        {
            continue;
        }
        if matches.len() >= 20000 {
            truncated = true;
            break;
        }
        if replacement.len().saturating_add(
            replacement
                .bytes()
                .filter(|b| *b == b'$')
                .count()
                .saturating_mul(m.len()),
        ) > 8 * 1024 * 1024
        {
            bail!("replacement expansion too large");
        }
        let mut expanded = String::new();
        if v["regex"].as_bool().unwrap_or(false) {
            cap.expand(replacement, &mut expanded);
        } else {
            expanded.push_str(replacement);
        }
        output_bytes += expanded.len();
        if output_bytes > 8 * 1024 * 1024 {
            bail!("replacement output too large");
        }
        matches.push(json!({"start":m.start(),"end":m.end(),"replacement":expanded}));
    }
    Ok(json!({"matches":matches,"truncated":truncated}))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unicode_whole_words_and_captures() {
        let v = run(&json!({"source":"日 foo FOO food foo_bar","query":"foo","whole_word":true}))
            .unwrap();
        assert_eq!(v["matches"].as_array().unwrap().len(), 2);
        let v = run(
            &json!({"source":"id=42","query":"id=(\\d+)","regex":true,"replacement":"value:${1}"}),
        )
        .unwrap();
        assert_eq!(v["matches"][0]["replacement"], "value:42");
        assert!(run(&json!({"source":"x","query":"[","regex":true})).is_err());
    }
}
