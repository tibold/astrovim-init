use testbed::{greet, total_length};

fn main() {
    let names = vec!["ann", "bob", "cy"];
    let mut greetings = Vec::new();
    for name in &names {
        let greeting = greet(name);
        greetings.push(greeting);
    }
    let total = total_length(&names);
    println!("{} greetings, {total} bytes of names", greetings.len());
}
