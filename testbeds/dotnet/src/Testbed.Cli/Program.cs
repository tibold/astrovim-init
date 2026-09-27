using Testbed.Core;

var names = new[] { "ann", "bob", "cy" };
var greetings = new List<string>();
foreach (var name in names)
{
    var greeting = Greeter.Greet(name);
    greetings.Add(greeting);
}
var total = Greeter.TotalLength(names);
Console.WriteLine($"{greetings.Count} greetings, {total} characters of names");
