# Python: known plugin issues

Workaround lives in `python.lua`. Found on Windows; not reported upstream.

## nvim-dap-python: debugpy adapter started with the wrong arguments

- **Symptom:** no Python debug session ever starts; nvim-dap's log shows
  `debugpy-adapter.CMD` exiting with code 2 (a usage error).
- **Cause:** astrocommunity's python pack passes `exepath("debugpy-adapter")` to
  `dap-python.setup()`. dap-python recognises that adapter only by a basename of
  exactly `debugpy-adapter`; on Windows it is `debugpy-adapter.CMD`, so it is
  taken for a Python interpreter and started with `-m debugpy.adapter`.
- **Workaround:** give dap-python the Python inside Mason's debugpy package
  (`packages/debugpy/venv/Scripts/python.exe`), for which `-m debugpy.adapter`
  is right.

Drop it once dap-python ignores the extension when recognising the adapter, or
the pack passes an interpreter.
