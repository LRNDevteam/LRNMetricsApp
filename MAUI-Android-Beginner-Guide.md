# Build Your First Android App with .NET MAUI — Step by Step

A beginner-friendly guide to creating a two-page Android app with navigation using .NET MAUI and C#.

---

## What is .NET MAUI?

.NET MAUI (Multi-platform App UI) is Microsoft's framework for building native mobile and desktop apps with C# and XAML. One codebase runs on Android, iOS, Windows, and macOS.

---

## Step 1: Install the Tools

### 1a. Install Visual Studio 2022 (v17.8+)

Download from [visualstudio.microsoft.com](https://visualstudio.microsoft.com/).

During installation, check the workload:

> **.NET Multi-platform App UI development**

This automatically installs:
- .NET 8/9/10 SDK
- Microsoft OpenJDK
- Android SDK
- Android Emulator

### 1b. Enable Developer Mode (Windows)

1. Open **Settings → Privacy & Security → For developers**
2. Toggle **Developer Mode** ON

### 1c. Set Up an Android Emulator

1. Open Visual Studio → **Tools → Android → Android Device Manager**
2. Click **+ New** → choose a device (e.g. Pixel 5, API 34)
3. Click **Create** — it downloads the system image and creates the emulator

> **Tip:** If you have a physical Android phone, enable **USB Debugging** in Developer Options and connect via USB instead.

---

## Step 2: Create a New .NET MAUI Project

1. Open Visual Studio
2. Click **Create a new project**
3. Search for **".NET MAUI App"** and select it
4. Click **Next**
5. Set the project name: `HelloMauiApp`
6. Choose a location and click **Next**
7. Select **.NET 9** (or latest) as the framework
8. Click **Create**

Visual Studio generates a project with this structure:

```
HelloMauiApp/
├── App.xaml              ← App-level resources & styles
├── App.xaml.cs           ← App startup (sets MainPage)
├── AppShell.xaml         ← Shell navigation structure
├── AppShell.xaml.cs      ← Shell code-behind
├── MainPage.xaml         ← First page (UI)
├── MainPage.xaml.cs      ← First page (logic)
├── MauiProgram.cs        ← App builder & dependency injection
├── Platforms/
│   └── Android/          ← Android-specific files
│       ├── AndroidManifest.xml
│       └── MainActivity.cs
└── Resources/            ← Images, fonts, styles
```

---

## Step 3: Understand the Default App

### MauiProgram.cs — The entry point

```csharp
using Microsoft.Extensions.Logging;

namespace HelloMauiApp;

public static class MauiProgram
{
    public static MauiApp CreateMauiApp()
    {
        var builder = MauiApp.CreateBuilder();
        builder
            .UseMauiApp<App>()
            .ConfigureFonts(fonts =>
            {
                fonts.AddFont("OpenSans-Regular.ttf", "OpenSansRegular");
                fonts.AddFont("OpenSans-Semibold.ttf", "OpenSansSemibold");
            });

        return builder.Build();
    }
}
```

This is like `Program.cs` in ASP.NET — it configures the app.

### App.xaml.cs — Sets the root page

```csharp
namespace HelloMauiApp;

public partial class App : Application
{
    public App()
    {
        InitializeComponent();
    }

    protected override Window CreateWindow(IActivationState? activationState)
    {
        return new Window(new AppShell());
    }
}
```

`AppShell` is the navigation container — similar to a layout in web apps.

### AppShell.xaml — Defines navigation structure

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<Shell
    x:Class="HelloMauiApp.AppShell"
    xmlns="http://schemas.microsoft.com/dotnet/2021/maui"
    xmlns:x="http://schemas.microsoft.com/winfx/2009/xaml"
    xmlns:local="clr-namespace:HelloMauiApp">

    <ShellContent
        Title="Home"
        ContentTemplate="{DataTemplate local:MainPage}" />

</Shell>
```

`ShellContent` registers `MainPage` as the default page.

---

## Step 4: Edit MainPage (Your Home Screen)

Replace the contents of **MainPage.xaml** with:

```xml
<?xml version="1.0" encoding="utf-8" ?>
<ContentPage xmlns="http://schemas.microsoft.com/dotnet/2021/maui"
             xmlns:x="http://schemas.microsoft.com/winfx/2009/xaml"
             x:Class="HelloMauiApp.MainPage"
             Title="Home">

    <VerticalStackLayout Spacing="20" Padding="30"
                         VerticalOptions="Center">

        <Label Text="Welcome to .NET MAUI!"
               FontSize="28"
               FontAttributes="Bold"
               HorizontalOptions="Center" />

        <Label Text="This is your first Android app."
               FontSize="16"
               HorizontalOptions="Center"
               TextColor="Gray" />

        <Entry x:Name="NameEntry"
               Placeholder="Enter your name"
               MaxLength="50" />

        <Button Text="Go to Greeting Page"
                Clicked="OnNavigateClicked"
                BackgroundColor="#512BD4"
                TextColor="White"
                CornerRadius="8" />

    </VerticalStackLayout>

</ContentPage>
```

Replace **MainPage.xaml.cs** with:

```csharp
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
```

**Key concepts:**
- `Entry` = text input field
- `Button Clicked` = event handler (like onclick)
- `Shell.Current.GoToAsync(...)` = navigate to another page
- Query parameters (`?name=value`) pass data between pages

---

## Step 5: Create a Second Page (GreetingPage)

### 5a. Add the XAML file

Right-click the project → **Add → New Item → .NET MAUI ContentPage (XAML)** → name it `GreetingPage.xaml`.

Replace its contents with:

```xml
<?xml version="1.0" encoding="utf-8" ?>
<ContentPage xmlns="http://schemas.microsoft.com/dotnet/2021/maui"
             xmlns:x="http://schemas.microsoft.com/winfx/2009/xaml"
             x:Class="HelloMauiApp.GreetingPage"
             Title="Greeting">

    <VerticalStackLayout Spacing="20" Padding="30"
                         VerticalOptions="Center">

        <Label x:Name="GreetingLabel"
               Text="Hello!"
               FontSize="32"
               FontAttributes="Bold"
               HorizontalOptions="Center" />

        <Label Text="You navigated to a second page."
               FontSize="16"
               HorizontalOptions="Center"
               TextColor="Gray" />

        <Button Text="Go Back"
                Clicked="OnGoBackClicked"
                BackgroundColor="#512BD4"
                TextColor="White"
                CornerRadius="8" />

    </VerticalStackLayout>

</ContentPage>
```

### 5b. Add the code-behind

Replace **GreetingPage.xaml.cs** with:

```csharp
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
```

**Key concepts:**
- `[QueryProperty]` automatically receives the `name` parameter from navigation
- `GoToAsync("..")` navigates back (like browser back button)

---

## Step 6: Register the Route

Open **AppShell.xaml.cs** and register the new page route:

```csharp
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
```

Without this line, `GoToAsync("GreetingPage")` would throw an exception.

---

## Step 7: Run on Android

### Option A — Android Emulator

1. In the toolbar, set the debug target to your emulator (e.g. **Pixel 5 - API 34**)
2. Press **F5** or click the green ▶ button
3. Wait for the emulator to boot and the app to deploy (first time takes 1–2 minutes)

### Option B — Physical Android Device

1. Connect your phone via USB
2. Enable **USB Debugging** (Settings → Developer Options)
3. Select your device in the debug target dropdown
4. Press **F5**

### What you should see:

1. **Home page** — a text input and a "Go to Greeting Page" button
2. Type your name and tap the button
3. **Greeting page** — shows "Hello, [your name]!" with a "Go Back" button
4. Tap "Go Back" to return to the home page

---

## Step 8: How It All Connects (Summary)

```
MauiProgram.cs          → Builds the app
    ↓
App.xaml.cs             → Creates a Window with AppShell
    ↓
AppShell.xaml           → Defines MainPage as the default page
AppShell.xaml.cs        → Registers GreetingPage route
    ↓
MainPage                → User enters name, taps button
    ↓  GoToAsync("GreetingPage?name=...")
GreetingPage            → Receives name via [QueryProperty], displays greeting
    ↓  GoToAsync("..")
MainPage                → Back to home
```

---

## Common Beginner Mistakes

| Mistake | Fix |
|---|---|
| Forgot to register route | Add `Routing.RegisterRoute(...)` in AppShell.xaml.cs |
| App crashes on navigation | Check the page has a parameterless constructor |
| Emulator won't start | Enable Hyper-V in Windows Features, or use a physical device |
| Build errors after adding a page | Make sure namespace matches in XAML (`x:Class`) and C# |
| UI doesn't update | Ensure you're setting properties AFTER `InitializeComponent()` |

---

## Next Steps

Once you're comfortable with this, try:

- **Add a third page** with a ListView or CollectionView
- **Use MVVM pattern** with data binding and ViewModels
- **Call a REST API** using `HttpClient` (e.g. fetch weather data)
- **Add local storage** with SQLite or Preferences
- **Style your app** using Resources/Styles.xaml

---

## Useful Links

- [Official .NET MAUI Tutorial](https://dotnet.microsoft.com/en-us/learn/maui/first-app-tutorial/intro)
- [Build your first .NET MAUI app (Microsoft Learn)](https://learn.microsoft.com/en-us/dotnet/maui/get-started/first-app)
- [Shell Navigation docs](https://learn.microsoft.com/en-us/dotnet/maui/fundamentals/shell/navigation)
- [.NET MAUI home page](https://dotnet.microsoft.com/en-us/apps/maui)
