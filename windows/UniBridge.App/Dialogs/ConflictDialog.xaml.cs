using System.Windows;
using UniBridge.Core.Models;

namespace UniBridge.App.Dialogs;

public partial class ConflictDialog : Window
{
    public ConflictPrompt Prompt { get; }
    public string SourceSizeText => FormattingHelpers.FormatByteCount(Prompt.SourceSize);
    public string DestSizeText => FormattingHelpers.FormatByteCount(Prompt.DestinationSize);
    public string SourceDateText => Prompt.SourceDate?.ToLocalTime().ToString("yyyy-MM-dd HH:mm") ?? "Unknown date";
    public string DestDateText => Prompt.DestinationDate?.ToLocalTime().ToString("yyyy-MM-dd HH:mm") ?? "Unknown date";
    public bool ApplyToAll { get; set; }
    public ConflictDecision Decision { get; private set; } = new(ConflictResolution.CancelAll, false);

    public ConflictDialog(ConflictPrompt prompt)
    {
        Prompt = prompt;
        InitializeComponent();
        DataContext = this;
    }

    private void Replace_Click(object sender, RoutedEventArgs e)
    {
        Decision = new ConflictDecision(ConflictResolution.Replace, ApplyToAll);
        DialogResult = true;
    }

    private void KeepBoth_Click(object sender, RoutedEventArgs e)
    {
        Decision = new ConflictDecision(ConflictResolution.KeepBoth, ApplyToAll);
        DialogResult = true;
    }

    private void Skip_Click(object sender, RoutedEventArgs e)
    {
        Decision = new ConflictDecision(ConflictResolution.Skip, ApplyToAll);
        DialogResult = true;
    }

    private void CancelAll_Click(object sender, RoutedEventArgs e)
    {
        Decision = new ConflictDecision(ConflictResolution.CancelAll, false);
        DialogResult = true;
    }
}
