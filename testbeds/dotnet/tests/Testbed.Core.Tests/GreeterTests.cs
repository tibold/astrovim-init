using Testbed.Core;

namespace Testbed.Core.Tests;

public class GreeterTests
{
    [Fact]
    public void GreetsByName()
    {
        Assert.Equal("hello ann", Greeter.Greet("ann"));
    }

    [Fact]
    public void TotalsTheLengths()
    {
        Assert.Equal(6, Greeter.TotalLength(["ann", "bob"]));
    }

    /// <summary>Fails on purpose, so failure reporting can be checked as well.</summary>
    [Fact]
    public void DeliberatelyFails()
    {
        Assert.Equal("good day bob", Greeter.Greet("bob"));
    }
}
