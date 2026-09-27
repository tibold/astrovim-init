using Bunit;
using Testbed.Web.Components;

namespace Testbed.Web.Tests;

public class GreetingTests : BunitContext
{
    [Fact]
    public void ShowsTheFirstGreeting()
    {
        var greeting = Render<Greeting>();
        Assert.Equal("hello ann", greeting.Find(".greeting").TextContent);
    }

    [Fact]
    public void MovesToTheNextName()
    {
        var greeting = Render<Greeting>();
        greeting.Find(".next").Click();
        Assert.Equal("hello bob", greeting.Find(".greeting").TextContent);
    }

    /// <summary>Fails on purpose, so failure reporting can be checked as well.</summary>
    [Fact]
    public void DeliberatelyFails()
    {
        var greeting = Render<Greeting>();
        Assert.Equal("good day ann", greeting.Find(".greeting").TextContent);
    }
}
