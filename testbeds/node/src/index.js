const { greet, totalLength } = require("./greet");

function main() {
  const names = ["ann", "bob", "cy"];
  const greetings = [];
  for (const name of names) {
    const greeting = greet(name);
    greetings.push(greeting);
  }
  const total = totalLength(names);
  console.log(`${greetings.length} greetings, ${total} characters of names`);
}

main();
