#![forbid(unsafe_code)]
#![deny(unsafe_op_in_unsafe_fn)]
#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if let Ok(s) = std::str::from_utf8(data) {
        // parse_frontmatter should never panic, only return Ok or Err
        let _ = issue_tui::issue::parse_frontmatter(s);
    }
});
