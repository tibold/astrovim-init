/** A greeting for one person. */
function greet(name) {
  return `hello ${name}`;
}

/** The combined length of every name. */
function totalLength(names) {
  return names.reduce((sum, name) => sum + name.length, 0);
}

module.exports = { greet, totalLength };
