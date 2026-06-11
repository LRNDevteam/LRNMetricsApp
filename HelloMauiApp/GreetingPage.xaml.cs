namespace HelloMauiApp;

[QueryProperty(nameof(Name), "name")]
public partial class GreetingPage : ContentPage
{
    private string _name = string.Empty;

    public string Name
    {
        get => _name;
        set
        {
            _name = Uri.UnescapeDataString(value ?? "Friend");
            GreetingLabel.Text = $"Hello, {_name}!";
        }
    }

    public GreetingPage()
    {
        InitializeComponent();
    }

    private async void OnGoBackClicked(object sender, EventArgs e)
    {
        await Shell.Current.GoToAsync("..");  // go back one page
    }
}
