//! A small crate for checking debugging and tests in Neovim.

/// A greeting for one person.
pub fn greet(name: &str) -> String {
    format!("hello {name}")
}

/// The combined length of every name, in bytes.
pub fn total_length(names: &[&str]) -> usize {
    names.iter().map(|name| name.len()).sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn greets_by_name() {
        assert_eq!(greet("ann"), "hello ann");
    }

    #[test]
    fn totals_the_lengths() {
        assert_eq!(total_length(&["ann", "bob"]), 6);
    }

    /// Fails on purpose, so failure reporting can be checked as well.
    #[test]
    fn deliberately_fails() {
        assert_eq!(greet("bob"), "good day bob");
    }
}
