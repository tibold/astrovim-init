# Treesitter: known issues

Workarounds live in `treesitter.lua`. Found with Neovim 0.12.5; still present
in 0.12.6 and on master (2026-10-16). Not reported upstream yet.

## An injection outside its parent's ranges is parsed over the whole buffer

- **Symptom:** in a Razor file, tags, attributes and closing tags take CSS
  colours (`tag@css`, `string@css`), across the whole file, and the colouring
  flips as nearby markup is edited.
- **Cause:** `add_injection` in `vim/treesitter/languagetree.lua` skips an
  empty range list ("interpreted to mean the whole buffer"), but checks before
  narrowing the ranges to the parent tree's with `clip_regions`. Razor hands
  the HTML parser only the elements tree-sitter-razor recognised; a `style`
  attribute on a tag it did not recognise still reaches the HTML tree, its CSS
  injection narrows to nothing, and the empty list goes in: the CSS parser
  reads all 160 lines.
- **Workaround:** `_get_injections` gets a wrapped `add_injection` (swapped in
  with `debug.setupvalue`) that drops an injection which narrows to nothing.
  Drop it once Neovim checks after narrowing.

## Related, not worked around: tree-sitter-razor

The stray `style` comes from markup tree-sitter-razor cannot parse, which then
takes C# colours itself:

- `<div @ref=_root …>`: a directive attribute with an unquoted value; the tag
  never becomes an element.
- `class="@cssBlock["row"].Add("add")"`: quotes inside an expression inside a
  quoted attribute; the parser drops into C# until the end of the block, or of
  the file.
