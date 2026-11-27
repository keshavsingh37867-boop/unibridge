using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using Microsoft.Win32;
using UniBridge.App.Dialogs;
using UniBridge.App.ViewModels;
using UniBridge.App.Views;
using UniBridge.Core.Models;

namespace UniBridge.App;

public partial class MainWindow : Window
{
    private const int WmDeviceChange = 0x0219;
    private const int DbtDeviceArrival = 0x8000;
    private const int DbtDeviceRemoveComplete = 0x8004;
    private const int DbtDevNodesChanged = 0x0007;

    private readonly MainViewModel _viewModel = new();
    private readonly DispatcherTimer _usbDebounceTimer;
    private HwndSource? _hwndSource;

    public MainWindow()
    {
        InitializeComponent();
        DataContext = _viewModel;

        _usbDebounceTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(900)
        };
        _usbDebounceTimer.Tick += async (_, _) =>
        {
            _usbDebounceTimer.Stop();
            await _viewModel.RescanAsync();
        };

        ConfigureDialogHandlers();
        WirePaneEvents(LeftPaneView);
        WirePaneEvents(RightPaneView);

        Loaded += async (_, _) => await _viewModel.InitializeAsync();
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var helper = new WindowInteropHelper(this);
        _hwndSource = HwndSource.FromHwnd(helper.Handle);
        _hwndSource?.AddHook(WndProc);
    }

    protected override void OnClosed(EventArgs e)
    {
        _hwndSource?.RemoveHook(WndProc);
        _usbDebounceTimer.Stop();
        base.OnClosed(e);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WmDeviceChange)
        {
            int code = wParam.ToInt32();
            if (code is DbtDeviceArrival or DbtDeviceRemoveComplete or DbtDevNodesChanged)
            {
                _usbDebounceTimer.Stop();
                _usbDebounceTimer.Start();
            }
        }
        return IntPtr.Zero;
    }

    private void ConfigureDialogHandlers()
    {
        _viewModel.ConflictPromptHandler = prompt =>
        {
            var dlg = new ConflictDialog(prompt) { Owner = this };
            bool? ok = dlg.ShowDialog();
            return Task.FromResult(ok == true ? dlg.Decision : new ConflictDecision(ConflictResolution.CancelAll, false));
        };

        _viewModel.InputPromptHandler = (title, prompt, initial) =>
        {
            var dlg = new InputDialog(title, prompt, initial) { Owner = this };
            return dlg.ShowDialog() == true ? dlg.InputText : null;
        };

        _viewModel.ConfirmPromptHandler = (title, message) =>
            MessageBox.Show(this, message, title, MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes;

        _viewModel.FolderPickerHandler = () =>
        {
            var dlg = new OpenFolderDialog
            {
                Title = "Select a Folder Target for UniBridge",
                Multiselect = false
            };
            return dlg.ShowDialog(this) == true ? dlg.FolderName : null;
        };

        _viewModel.AlertHandler = (title, message) =>
            MessageBox.Show(this, message, title, MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    private void WirePaneEvents(DevicePaneControl control)
    {
        control.FolderPickRequested += async (_, pane) => await _viewModel.AddCustomFolderAsync(pane);
        control.EjectRequested += async (_, pane) => await _viewModel.EjectDriveAsync(pane);
        control.NewFolderRequested += async (_, pane) => await _viewModel.CreateFolderAsync(pane);
        control.RenameRequested += async (_, pane) => await _viewModel.RenameSelectedAsync(pane);
        control.DeleteRequested += async (_, pane) => await _viewModel.DeleteSelectedAsync(pane);
        control.RescanRequested += async (_, _) => await _viewModel.RescanAsync();
        control.OpenEntryRequested += (_, args) => _viewModel.OpenEntry(args.pane, args.entry);

        control.TransferToOtherRequested += async (_, args) =>
        {
            var other = ReferenceEquals(args.pane, _viewModel.LeftPane) ? _viewModel.RightPane : _viewModel.LeftPane;
            await _viewModel.TransferBetweenPanesAsync(args.pane, other, args.pane.SelectedEntries.ToList(), args.mode);
        };

        control.PaneEntriesDropped += async (_, args) =>
        {
            await _viewModel.TransferBetweenPanesAsync(args.Payload.SourcePane, args.TargetPane, args.Payload.Entries, args.Mode);
        };

        control.ExternalFilesDropped += async (_, args) =>
        {
            await _viewModel.DropExternalFilesAsync(args.TargetPane, args.Paths, args.Mode);
        };
    }
}
