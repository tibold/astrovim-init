from calc import greet, total_length


def test_greets_by_name():
    assert greet("ann") == "hello ann"


def test_totals_the_lengths():
    assert total_length(["ann", "bob"]) == 6


def test_deliberately_fails():
    """Fails on purpose, so failure reporting can be checked as well."""
    assert greet("bob") == "good day bob"
