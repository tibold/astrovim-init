namespace Testbed.Core;

/// <summary>A small type for checking debugging and tests in Neovim.</summary>
public static class Greeter
{
    /// <summary>A greeting for one person.</summary>
    public static string Greet(string name) => $"hello {name}";

    /// <summary>The combined length of every name.</summary>
    public static int TotalLength(IEnumerable<string> names) => names.Sum(name => name.Length);
}
