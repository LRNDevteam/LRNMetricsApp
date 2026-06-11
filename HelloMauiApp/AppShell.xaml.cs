namespace HelloMauiApp;

public partial class AppShell : Shell
{
    public AppShell()
    {
        InitializeComponent();

        // Register GreetingPage so Shell.Current.GoToAsync can find it
        Routing.RegisterRoute(nameof(GreetingPage), typeof(GreetingPage));
    }
}
