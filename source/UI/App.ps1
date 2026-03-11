Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Load XAML
$xaml = Get-Content ".\source\UI\App.xaml" -Raw
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$Window = [Windows.Markup.XamlReader]::Load($reader)

# Hook controls
$UserInput = $Window.FindName("UserInput")
$SubmitBtn = $Window.FindName("SubmitBtn")
$OutputText = $Window.FindName("OutputText")

# Events
$SubmitBtn.Add_Click({
    $OutputText.Text = "Hello, $($UserInput.Text)!"
})

# Show UI
$Window.ShowDialog() | Out-Null