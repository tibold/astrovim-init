const { greet, totalLength } = require("./greet");

test("greets by name", () => {
  expect(greet("ann")).toBe("hello ann");
});

test("totals the lengths", () => {
  expect(totalLength(["ann", "bob"])).toBe(6);
});

// Fails on purpose, so failure reporting can be checked as well.
test("deliberately fails", () => {
  expect(greet("bob")).toBe("good day bob");
});
