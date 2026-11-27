using System.Windows;

namespace UniBridge.App.Dialogs;

public partial class InputDialog : Window
{
    public string DialogTitle { get; }
    public string PromptText { get; }
    public string InputText { get; set; }

    public InputDialog(string title, string prompt, string initialValue = "")
    {
        DialogTitle = title;
        PromptText = prompt;
        InputText = initialValue;
        InitializeComponent();
        DataContext = this;
        Loaded += (_, _) =>
        {
            InputBox.Focus();
            InputBox.SelectAll();
        };
    }

    private void OkButton_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
    }
}
