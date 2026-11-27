using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using UniBridge.App.ViewModels;
using UniBridge.Core.Models;

namespace UniBridge.App.Views;

public sealed record PaneDragPayload(PaneViewModel SourcePane, IReadOnlyList<BrowserEntry> Entries);

public sealed record PaneDropEventArgs(PaneViewModel TargetPane, PaneDragPayload Payload, TransferMode Mode);

public sealed record ExternalDropEventArgs(PaneViewModel TargetPane, string[] Paths, TransferMode Mode);

public partial class DevicePaneControl : UserControl
{
    private Point _dragStartPoint;
    private bool _potentialDrag;

    public PaneViewModel? ViewModel => DataContext as PaneViewModel;

    public event EventHandler<PaneViewModel>? FolderPickRequested;
    public event EventHandler<PaneViewModel>? EjectRequested;
    public event EventHandler<PaneViewModel>? NewFolderRequested;
    public event EventHandler<PaneViewModel>? RenameRequested;
    public event EventHandler<PaneViewModel>? DeleteRequested;
    public event EventHandler<(PaneViewModel pane, TransferMode mode)>? TransferToOtherRequested;
    public event EventHandler<(PaneViewModel pane, BrowserEntryViewModel entry)>? OpenEntryRequested;
    public event EventHandler? RescanRequested;
    public event EventHandler<PaneDropEventArgs>? PaneEntriesDropped;
    public event EventHandler<ExternalDropEventArgs>? ExternalFilesDropped;

    public DevicePaneControl()
    {
        InitializeComponent();
    }

    private void FileListView_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ViewModel is null) return;
        var selected = FileListView.SelectedItems.OfType<BrowserEntryViewModel>().ToList();
        ViewModel.UpdateSelection(selected);
    }

    private void FileListView_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (ViewModel is null) return;
        if (FileListView.SelectedItem is BrowserEntryViewModel item)
        {
            OpenEntryRequested?.Invoke(this, (ViewModel, item));
        }
    }

    private void FileListView_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        _dragStartPoint = e.GetPosition(null);
        _potentialDrag = e.OriginalSource is DependencyObject d
                         && ItemsControl.ContainerFromElement(FileListView, d) is ListViewItem;
    }

    private void FileListView_MouseMove(object sender, MouseEventArgs e)
    {
        if (!_potentialDrag || e.LeftButton != MouseButtonState.Pressed || ViewModel is null)
        {
            return;
        }

        var current = e.GetPosition(null);
        if (Math.Abs(current.X - _dragStartPoint.X) < SystemParameters.MinimumHorizontalDragDistance
            && Math.Abs(current.Y - _dragStartPoint.Y) < SystemParameters.MinimumVerticalDragDistance)
        {
            return;
        }

        _potentialDrag = false;
        var entries = FileListView.SelectedItems.OfType<BrowserEntryViewModel>().Select(x => x.Entry).ToList();
        if (entries.Count == 0) return;

        var data = new DataObject();
        data.SetData(typeof(PaneDragPayload), new PaneDragPayload(ViewModel, entries));
        if (entries.All(item => item.Location.IsLocal))
        {
            data.SetFileDropList([.. entries.Select(item => item.Location.Path)]);
        }

        DragDrop.DoDragDrop(FileListView, data, DragDropEffects.Copy | DragDropEffects.Move);
    }

    private void Root_DragOver(object sender, DragEventArgs e)
    {
        bool canAccept = CanAcceptDrop(e.Data);
        if (canAccept)
        {
            bool shiftHeld = (e.KeyStates & DragDropKeyStates.ShiftKey) != 0;
            e.Effects = shiftHeld ? DragDropEffects.Move : DragDropEffects.Copy;
            DropHighlightBorder.Visibility = Visibility.Visible;
        }
        else
        {
            e.Effects = DragDropEffects.None;
            DropHighlightBorder.Visibility = Visibility.Collapsed;
        }
        e.Handled = true;
    }

    private void Root_DragLeave(object sender, DragEventArgs e)
    {
        DropHighlightBorder.Visibility = Visibility.Collapsed;
    }

    private void Root_Drop(object sender, DragEventArgs e)
    {
        DropHighlightBorder.Visibility = Visibility.Collapsed;
        if (ViewModel is null || !CanAcceptDrop(e.Data)) return;

        bool shiftHeld = (e.KeyStates & DragDropKeyStates.ShiftKey) != 0;
        var mode = shiftHeld ? TransferMode.Move : TransferMode.Copy;

        if (e.Data.GetDataPresent(typeof(PaneDragPayload))
            && e.Data.GetData(typeof(PaneDragPayload)) is PaneDragPayload payload
            && !ReferenceEquals(payload.SourcePane, ViewModel))
        {
            PaneEntriesDropped?.Invoke(this, new PaneDropEventArgs(ViewModel, payload, mode));
            e.Handled = true;
            return;
        }

        if (e.Data.GetDataPresent(DataFormats.FileDrop)
            && e.Data.GetData(DataFormats.FileDrop) is string[] paths
            && paths.Length > 0)
        {
            ExternalFilesDropped?.Invoke(this, new ExternalDropEventArgs(ViewModel, paths, mode));
            e.Handled = true;
        }
    }

    private bool CanAcceptDrop(IDataObject data)
    {
        if (ViewModel is null || !ViewModel.CanModifyFilesystem || ViewModel.CurrentLocation is null)
        {
            return false;
        }
        if (data.GetDataPresent(typeof(PaneDragPayload))
            && data.GetData(typeof(PaneDragPayload)) is PaneDragPayload payload)
        {
            return !ReferenceEquals(payload.SourcePane, ViewModel);
        }
        return data.GetDataPresent(DataFormats.FileDrop);
    }

    private void PickFolder_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not null) FolderPickRequested?.Invoke(this, ViewModel);
    }

    private void EjectDrive_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not null) EjectRequested?.Invoke(this, ViewModel);
    }

    private void QuickFolder_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not null && sender is FrameworkElement { Tag: QuickFolderItem item })
        {
            _ = ViewModel.OpenQuickFolderAsync(item);
        }
    }

    private void Breadcrumb_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not null && sender is FrameworkElement { Tag: BreadcrumbSegment seg })
        {
            _ = ViewModel.NavigateToAsync(seg.Location);
        }
    }

    private void NewFolder_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not null) NewFolderRequested?.Invoke(this, ViewModel);
    }

    private void Rename_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not null) RenameRequested?.Invoke(this, ViewModel);
    }

    private void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not null) DeleteRequested?.Invoke(this, ViewModel);
    }

    private void CopyToOther_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not null) TransferToOtherRequested?.Invoke(this, (ViewModel, TransferMode.Copy));
    }

    private void MoveToOther_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not null) TransferToOtherRequested?.Invoke(this, (ViewModel, TransferMode.Move));
    }

    private void OpenSelected_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not null && FileListView.SelectedItem is BrowserEntryViewModel item)
        {
            OpenEntryRequested?.Invoke(this, (ViewModel, item));
        }
    }

    private void Rescan_Click(object sender, RoutedEventArgs e)
    {
        RescanRequested?.Invoke(this, EventArgs.Empty);
    }
}
