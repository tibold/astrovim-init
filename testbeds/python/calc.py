"""A small module for checking debugging and tests in Neovim."""


def greet(name: str) -> str:
    """A greeting for one person."""
    return f"hello {name}"


def total_length(names: list[str]) -> int:
    """The combined length of every name."""
    return sum(len(name) for name in names)
