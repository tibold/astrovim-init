# neotest: known issues

Workarounds live in `neotest.lua`. Found on Windows; not reported upstream.

## The integrated strategy loses output under ConPTY

- **Symptom:** adapters parse an output file holding only terminal escapes; the
  Rust adapter then marks every test in the file failed.
- **Cause:** the built-in "integrated" strategy runs tests under a pty (ConPTY on
  Windows), takes the empty chunk ConPTY sends at start as end of output, and
  closes the file before ConPTY has flushed.
- **Workaround:** a pipe strategy, used as the default on Windows.

## Output must arrive in one stream

- **Symptom:** with the pipe strategy, every Rust test in a file showed failed,
  passing ones too.
- **Cause:** rustaceanvim runs `cargo test --nocapture`, so panics go to stderr
  as they happen. Read through two pipes, they arrived after the summary with no
  blank line after, and rustaceanvim's parser (which needs that blank line)
  matched no failure.
- **Workaround:** the child gets one OS pipe for both stdout and stderr, as a
  terminal gives it one stream.

## neotest-python registered twice

- **Symptom:** every Python test shows, and runs, twice.
- **Cause:** astrocommunity's python pack is reached through more than one
  import, so its neotest opts run twice.
- **Workaround:** keep the first adapter of each name.

## Projects nested in the editor's directory

Not a bug to work around, but a limit: neotest finds adapters and roots from the
working directory, and an adapter matching an open buffer is registered with the
directory being scanned as its root. Projects inside another project's
directory (the testbeds in this config repo) need their own tab with `:tcd`.
