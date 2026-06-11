namespace HelloMauiApp;

public partial class MainPage : ContentPage
{
    public MainPage()
    {
        InitializeComponent();
    }

    private async void OnNavigateClicked(object sender, EventArgs e)
    {
        string name = NameEntry.Text?.Trim() ?? "Friend";

        // Navigate to GreetingPage, passing the name as a query parameter
        await Shell.Current.GoToAsync($"{nameof(GreetingPage)}?name={Uri.EscapeDataString(name)}");
    }
}
