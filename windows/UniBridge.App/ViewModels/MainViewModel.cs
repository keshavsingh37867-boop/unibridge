using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Input;
using UniBridge.Core.Models;
using UniBridge.Core.Services;

namespace UniBridge.App.ViewModels;

public sealed record BreadcrumbSegment(string Title, RemoteLocation Location);

public sealed record QuickFolderItem(string Title, string IconGlyph, string Path);

public sealed record ConflictPolicyOption(ConflictPolicy Policy, string DisplayName)
{
    public override string ToString() => DisplayName;
}

public sealed record SortFieldOption(SortField Field, string DisplayName)
{
    public override string ToString() => DisplayName;
}

public sealed class BrowserEntryViewModel
{
    public BrowserEntry Entry { get; }
    public string Name => Entry.Name;
    public bool IsDirectory => Entry.IsDirectory;
    public long Size => Entry.Size;
    public DateTime ModifiedDate => Entry.ModifiedDate;
    public string KindDescription => Entry.KindDescription;
    public string DisplaySize => Entry.IsDirectory ? "--" : FormattingHelpers.FormatByteCount(Entry.Size);
    public string DisplayDate => Entry.ModifiedDate == DateTime.MinValue
        ? "--"
        : Entry.ModifiedDate.ToString("yyyy-MM-dd HH:mm");

    public string IconGlyph { get; }
    public string IconColor { get; }

    public BrowserEntryViewModel(BrowserEntry entry)
    {
        Entry = entry;
        (IconGlyph, IconColor) = ResolveIcon(entry);
    }

    private static (string glyph, string color) ResolveIcon(BrowserEntry entry)
    {
        if (entry.IsDirectory) return ("\uE8B7", "#60A5FA");
        return entry.FileExtension switch
        {
            "jpg" or "jpeg" or "png" or "gif" or "webp" or "heic" or "bmp" or "svg" => ("\uEB9F", "#F472B6"),
            "mp4" or "mov" or "mkv" or "avi" or "webm" or "m4v" => ("\uE8B2", "#C084FC"),
            "mp3" or "wav" or "flac" or "aac" or "m4a" or "ogg" => ("\uE8D6", "#34D399"),
            "zip" or "rar" or "7z" or "tar" or "gz" or "iso" => ("\uE7B8", "#FBBF24"),
            "pdf" or "doc" or "docx" or "txt" or "md" or "csv" or "xlsx" or "pptx" => ("\uE8A5", "#93C5FD"),
            "apk" or "exe" or "msi" or "ps1" or "bat" or "sh" => ("\uE756", "#FB923C"),
            _ => ("\uE7C3", "#9CA3AF")
        };
    }
}

public sealed class TransferJobViewModel : ObservableObject
{
    public Guid Id { get; } = Guid.NewGuid();
    public TransferControl Control { get; } = new();

    private string _title;
    public string Title
    {
        get => _title;
        set => SetProperty(ref _title, value);
    }

    private string _subtitle;
    public string Subtitle
    {
        get => _subtitle;
        set => SetProperty(ref _subtitle, value);
    }

    private TransferState _state = TransferState.Preparing;
    public TransferState State
    {
        get => _state;
        set
        {
            if (SetProperty(ref _state, value))
            {
                OnPropertyChanged(nameof(IsActive));
                OnPropertyChanged(nameof(IsPaused));
                OnPropertyChanged(nameof(CanPause));
                OnPropertyChanged(nameof(CanResume));
                OnPropertyChanged(nameof(CanCancel));
                OnPropertyChanged(nameof(StateLabel));
                OnPropertyChanged(nameof(StateColor));
            }
        }
    }

    private double _progressPercent;
    public double ProgressPercent
    {
        get => _progressPercent;
        set => SetProperty(ref _progressPercent, value);
    }

    private string _currentFileName = "Preparing...";
    public string CurrentFileName
    {
        get => _currentFileName;
        set => SetProperty(ref _currentFileName, value);
    }

    private string _statsLine = "";
    public string StatsLine
    {
        get => _statsLine;
        set => SetProperty(ref _statsLine, value);
    }

    private string? _errorMessage;
    public string? ErrorMessage
    {
        get => _errorMessage;
        set
        {
            if (SetProperty(ref _errorMessage, value))
            {
                OnPropertyChanged(nameof(HasError));
            }
        }
    }

    public bool HasError => !string.IsNullOrEmpty(ErrorMessage);
    public bool IsActive => State is TransferState.Queued or TransferState.Preparing or TransferState.Transferring or TransferState.Paused;
    public bool IsPaused => State == TransferState.Paused;
    public bool CanPause => State == TransferState.Transferring || State == TransferState.Preparing;
    public bool CanResume => State == TransferState.Paused;
    public bool CanCancel => IsActive;

    public string StateLabel => State switch
    {
        TransferState.Queued => "Queued",
        TransferState.Preparing => "Preparing",
        TransferState.Transferring => "Transferring",
        TransferState.Paused => "Paused",
        TransferState.Completed => "Completed",
        TransferState.CompletedWithSkips => "Done (with skips)",
        TransferState.Cancelled => "Cancelled",
        TransferState.Failed => "Failed",
        _ => State.ToString()
    };

    public string StateColor => State switch
    {
        TransferState.Completed => "#10B981",
        TransferState.CompletedWithSkips => "#F59E0B",
        TransferState.Paused => "#F59E0B",
        TransferState.Failed or TransferState.Cancelled => "#EF4444",
        _ => "#3B82F6"
    };

    public ICommand PauseCommand { get; }
    public ICommand ResumeCommand { get; }
    public ICommand CancelCommand { get; }

    public TransferJobViewModel(string title, string subtitle)
    {
        _title = title;
        _subtitle = subtitle;
        PauseCommand = new RelayCommand(() =>
        {
            Control.Pause();
            State = TransferState.Paused;
        }, () => CanPause);
        ResumeCommand = new RelayCommand(() =>
        {
            Control.Resume();
            State = TransferState.Transferring;
        }, () => CanResume);
        CancelCommand = new RelayCommand(() =>
        {
            Control.Cancel();
            State = TransferState.Cancelled;
        }, () => CanCancel);
    }

    public void UpdateProgress(TransferProgressSnapshot snap)
    {
        if (State == TransferState.Preparing)
        {
            State = TransferState.Transferring;
        }
        ProgressPercent = snap.TotalBytes > 0
            ? Math.Clamp(100.0 * snap.BytesTransferred / snap.TotalBytes, 0.0, 100.0)
            : (snap.TotalFiles > 0 ? 100.0 * snap.FilesCompleted / snap.TotalFiles : 0.0);

        CurrentFileName = string.IsNullOrEmpty(snap.CurrentFileName) ? "Working..." : snap.CurrentFileName;
        var bytesPart = $"{FormattingHelpers.FormatByteCount(snap.BytesTransferred)} / {FormattingHelpers.FormatByteCount(snap.TotalBytes)}";
        var filesPart = $"{snap.FilesCompleted}/{snap.TotalFiles} files";
        var speedPart = FormattingHelpers.FormatSpeed(snap.SpeedBytesPerSecond);
        var etaPart = FormattingHelpers.FormatDuration(snap.EstimatedSecondsRemaining);
        StatsLine = $"{bytesPart}  •  {filesPart}  •  {speedPart}  •  ETA {etaPart}";
    }
}

public sealed class PaneViewModel : ObservableObject
{
    private readonly UnifiedTransferService _transferService;
    private readonly List<RemoteLocation> _backStack = [];
    private readonly List<RemoteLocation> _forwardStack = [];
    private List<BrowserEntry> _rawEntries = [];
    private CancellationTokenSource? _loadCts;
    private bool _suppressEndpointSelection;

    public string PaneTitle { get; }
    public ObservableCollection<StorageEndpoint> Endpoints { get; } = [];
    public ObservableCollection<BrowserEntryViewModel> VisibleEntries { get; } = [];
    public ObservableCollection<BreadcrumbSegment> Breadcrumbs { get; } = [];
    public ObservableCollection<QuickFolderItem> QuickFolders { get; } = [];
    public List<BrowserEntry> SelectedEntries { get; private set; } = [];

    public static IReadOnlyList<SortFieldOption> SortOptions { get; } =
    [
        new(SortField.Name, "Name"),
        new(SortField.Size, "Size"),
        new(SortField.DateModified, "Modified"),
        new(SortField.Kind, "Kind")
    ];

    private StorageEndpoint? _selectedEndpoint;
    public StorageEndpoint? SelectedEndpoint
    {
        get => _selectedEndpoint;
        set
        {
            if (SetProperty(ref _selectedEndpoint, value))
            {
                OnPropertyChanged(nameof(ShowQuickFolders));
                OnPropertyChanged(nameof(CanEject));
                OnPropertyChanged(nameof(ShowAttentionOverlay));
                OnPropertyChanged(nameof(CanModifyFilesystem));
                OnPropertyChanged(nameof(EndpointSubtitle));
                OnPropertyChanged(nameof(FreeSpaceSummary));

                if (!_suppressEndpointSelection && value is not null)
                {
                    _backStack.Clear();
                    _forwardStack.Clear();
                    _ = NavigateToAsync(value.RootLocation, recordHistory: false);
                }
            }
        }
    }

    private RemoteLocation? _currentLocation;
    public RemoteLocation? CurrentLocation
    {
        get => _currentLocation;
        private set
        {
            if (SetProperty(ref _currentLocation, value))
            {
                RebuildBreadcrumbs();
                OnPropertyChanged(nameof(CanNavigateUp));
            }
        }
    }

    private string _searchQuery = string.Empty;
    public string SearchQuery
    {
        get => _searchQuery;
        set
        {
            if (SetProperty(ref _searchQuery, value))
            {
                ApplyFilter();
            }
        }
    }

    private bool _showHidden;
    public bool ShowHidden
    {
        get => _showHidden;
        set
        {
            if (SetProperty(ref _showHidden, value))
            {
                _ = RefreshAsync();
            }
        }
    }

    private SortField _sortField = SortField.Name;
    public SortField SortField
    {
        get => _sortField;
        set
        {
            if (SetProperty(ref _sortField, value))
            {
                _ = RefreshAsync();
            }
        }
    }

    private bool _sortAscending = true;
    public bool SortAscending
    {
        get => _sortAscending;
        set
        {
            if (SetProperty(ref _sortAscending, value))
            {
                OnPropertyChanged(nameof(SortDirectionGlyph));
                _ = RefreshAsync();
            }
        }
    }

    private bool _isLoading;
    public bool IsLoading
    {
        get => _isLoading;
        set
        {
            if (SetProperty(ref _isLoading, value))
            {
                OnPropertyChanged(nameof(IsEmpty));
            }
        }
    }

    private string? _errorMessage;
    public string? ErrorMessage
    {
        get => _errorMessage;
        set
        {
            if (SetProperty(ref _errorMessage, value))
            {
                OnPropertyChanged(nameof(HasError));
            }
        }
    }

    public bool HasError => !string.IsNullOrEmpty(ErrorMessage);
    public bool IsEmpty => !IsLoading && !ShowAttentionOverlay && !HasError && VisibleEntries.Count == 0;
    public bool ShowQuickFolders => SelectedEndpoint?.Platform == EndpointPlatform.WindowsPC;
    public bool CanEject => SelectedEndpoint?.Platform == EndpointPlatform.Pendrive && SelectedEndpoint.Drive is not null;
    public bool ShowAttentionOverlay => SelectedEndpoint?.RequiresAttention == true;
    public bool CanModifyFilesystem => SelectedEndpoint is { IsReadOnly: false, RequiresAttention: false };
    public bool CanNavigateBack => _backStack.Count > 0;
    public bool CanNavigateForward => _forwardStack.Count > 0;
    public bool CanNavigateUp => CurrentLocation is not null && SelectedEndpoint is not null && !IsAtRoot(CurrentLocation, SelectedEndpoint.RootLocation);
    public string SortDirectionGlyph => SortAscending ? "▲" : "▼";
    public string EndpointSubtitle => SelectedEndpoint?.Subtitle ?? "No device selected";

    public string FreeSpaceSummary => SelectedEndpoint switch
    {
        null => "",
        { TotalBytes: > 0 } ep => $"{FormattingHelpers.FormatByteCount(ep.AvailableBytes)} free of {FormattingHelpers.FormatByteCount(ep.TotalBytes)}",
        { StatusMessage: { Length: > 0 } msg } => msg,
        _ => ""
    };

    public string SelectionSummary
    {
        get
        {
            var total = VisibleEntries.Count;
            if (SelectedEntries.Count == 0)
            {
                return $"{total} item{(total == 1 ? "" : "s")}";
            }
            var selectedBytes = SelectedEntries.Where(e => !e.IsDirectory).Sum(e => e.Size);
            return selectedBytes > 0
                ? $"{SelectedEntries.Count} of {total} selected ({FormattingHelpers.FormatByteCount(selectedBytes)})"
                : $"{SelectedEntries.Count} of {total} selected";
        }
    }

    public string EmptyStateText => ShowAttentionOverlay
        ? SelectedEndpoint?.StatusMessage ?? "Device needs attention"
        : string.IsNullOrWhiteSpace(SearchQuery)
            ? "Folder is empty"
            : "No matching files or folders";

    public ICommand BackCommand { get; }
    public ICommand ForwardCommand { get; }
    public ICommand UpCommand { get; }
    public ICommand RefreshCommand { get; }
    public ICommand ToggleSortDirectionCommand { get; }

    public PaneViewModel(string paneTitle, UnifiedTransferService transferService)
    {
        PaneTitle = paneTitle;
        _transferService = transferService;

        BackCommand = new AsyncRelayCommand(GoBackAsync, () => CanNavigateBack);
        ForwardCommand = new AsyncRelayCommand(GoForwardAsync, () => CanNavigateForward);
        UpCommand = new AsyncRelayCommand(GoUpAsync, () => CanNavigateUp);
        RefreshCommand = new AsyncRelayCommand(RefreshAsync);
        ToggleSortDirectionCommand = new RelayCommand(() => SortAscending = !SortAscending);

        PopulateQuickFolders();
    }

    private void PopulateQuickFolders()
    {
        var candidates = new (string title, string icon, Environment.SpecialFolder folder)[]
        {
            ("Home", "\uE80F", Environment.SpecialFolder.UserProfile),
            ("Desktop", "\uE7F4", Environment.SpecialFolder.DesktopDirectory),
            ("Downloads", "\uE896", Environment.SpecialFolder.UserProfile),
            ("Documents", "\uE8A5", Environment.SpecialFolder.MyDocuments),
            ("Pictures", "\uEB9F", Environment.SpecialFolder.MyPictures),
            ("Videos", "\uE8B2", Environment.SpecialFolder.MyVideos)
        };

        foreach (var (title, icon, folder) in candidates)
        {
            var path = title == "Downloads"
                ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads")
                : Environment.GetFolderPath(folder);

            if (!string.IsNullOrEmpty(path) && Directory.Exists(path))
            {
                QuickFolders.Add(new QuickFolderItem(title, icon, path));
            }
        }
    }

    public void UpdateSelection(IReadOnlyList<BrowserEntryViewModel> selected)
    {
        SelectedEntries = selected.Select(x => x.Entry).ToList();
        OnPropertyChanged(nameof(SelectionSummary));
        RelayCommand.RaiseCanExecuteChanged();
    }

    public async Task SetAvailableEndpointsAsync(IReadOnlyList<StorageEndpoint> endpoints, string? preferredEndpointId)
    {
        var currentId = preferredEndpointId ?? SelectedEndpoint?.Id;
        var previousLocation = CurrentLocation;

        _suppressEndpointSelection = true;
        try
        {
            Endpoints.Clear();
            foreach (var ep in endpoints)
            {
                Endpoints.Add(ep);
            }

            var target = Endpoints.FirstOrDefault(e => e.Id == currentId) ?? Endpoints.FirstOrDefault();
            SelectedEndpoint = target;
        }
        finally
        {
            _suppressEndpointSelection = false;
        }

        if (SelectedEndpoint is null)
        {
            CurrentLocation = null;
            VisibleEntries.Clear();
            return;
        }

        if (previousLocation is not null
            && previousLocation.Platform == SelectedEndpoint.Platform
            && previousLocation.DeviceId == SelectedEndpoint.RootLocation.DeviceId
            && previousLocation.AppBundleId == SelectedEndpoint.RootLocation.AppBundleId)
        {
            await NavigateToAsync(previousLocation, recordHistory: false);
        }
        else
        {
            _backStack.Clear();
            _forwardStack.Clear();
            await NavigateToAsync(SelectedEndpoint.RootLocation, recordHistory: false);
        }
    }

    public async Task NavigateToAsync(RemoteLocation location, bool recordHistory = true)
    {
        _loadCts?.Cancel();
        _loadCts = new CancellationTokenSource();
        var ct = _loadCts.Token;

        if (recordHistory && CurrentLocation is not null && CurrentLocation != location)
        {
            _backStack.Add(CurrentLocation);
            _forwardStack.Clear();
        }

        CurrentLocation = location;
        OnPropertyChanged(nameof(CanNavigateBack));
        OnPropertyChanged(nameof(CanNavigateForward));
        OnPropertyChanged(nameof(EmptyStateText));

        if (SelectedEndpoint?.RequiresAttention == true)
        {
            _rawEntries = [];
            VisibleEntries.Clear();
            ErrorMessage = SelectedEndpoint.StatusMessage;
            OnPropertyChanged(nameof(SelectionSummary));
            return;
        }

        IsLoading = true;
        ErrorMessage = null;
        try
        {
            var entries = await _transferService.ListEntriesAsync(location, ShowHidden, SortField, SortAscending, ct);
            if (ct.IsCancellationRequested) return;

            _rawEntries = entries;
            ApplyFilter();
        }
        catch (OperationCanceledException)
        {
            // Superseded by newer navigation
        }
        catch (Exception ex)
        {
            _rawEntries = [];
            VisibleEntries.Clear();
            ErrorMessage = ex.Message;
            OnPropertyChanged(nameof(SelectionSummary));
        }
        finally
        {
            IsLoading = false;
            RelayCommand.RaiseCanExecuteChanged();
        }
    }

    public async Task RefreshAsync()
    {
        if (CurrentLocation is not null)
        {
            await NavigateToAsync(CurrentLocation, recordHistory: false);
        }
    }

    public async Task GoBackAsync()
    {
        if (_backStack.Count == 0 || CurrentLocation is null) return;
        var prev = _backStack[^1];
        _backStack.RemoveAt(_backStack.Count - 1);
        _forwardStack.Add(CurrentLocation);
        await NavigateToAsync(prev, recordHistory: false);
    }

    public async Task GoForwardAsync()
    {
        if (_forwardStack.Count == 0 || CurrentLocation is null) return;
        var next = _forwardStack[^1];
        _forwardStack.RemoveAt(_forwardStack.Count - 1);
        _backStack.Add(CurrentLocation);
        await NavigateToAsync(next, recordHistory: false);
    }

    public async Task GoUpAsync()
    {
        if (Breadcrumbs.Count >= 2)
        {
            await NavigateToAsync(Breadcrumbs[^2].Location);
        }
    }

    public Task OpenQuickFolderAsync(QuickFolderItem item) =>
        NavigateToAsync(RemoteLocation.Local(EndpointPlatform.WindowsPC, item.Path));

    private void ApplyFilter()
    {
        VisibleEntries.Clear();
        IEnumerable<BrowserEntry> filtered = _rawEntries;
        if (!string.IsNullOrWhiteSpace(SearchQuery))
        {
            var q = SearchQuery.Trim();
            filtered = filtered.Where(e => e.Name.Contains(q, StringComparison.OrdinalIgnoreCase));
        }
        foreach (var entry in filtered)
        {
            VisibleEntries.Add(new BrowserEntryViewModel(entry));
        }
        SelectedEntries = [];
        OnPropertyChanged(nameof(SelectionSummary));
        OnPropertyChanged(nameof(EmptyStateText));
        OnPropertyChanged(nameof(IsEmpty));
    }

    private void RebuildBreadcrumbs()
    {
        Breadcrumbs.Clear();
        if (CurrentLocation is null || SelectedEndpoint is null) return;

        var loc = CurrentLocation;
        var root = SelectedEndpoint.RootLocation;

        if (loc.IsLocal)
        {
            var full = Path.GetFullPath(loc.Path);
            var rootFull = Path.GetFullPath(root.Path);
            var rootClean = rootFull.TrimEnd('\\');
            var driveRoot = Path.GetPathRoot(full) ?? rootFull;

            if (full.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase))
            {
                Breadcrumbs.Add(new BreadcrumbSegment(SelectedEndpoint.Name, root));
                var rel = full[rootClean.Length..].TrimStart('\\');
                var running = rootFull;
                foreach (var seg in rel.Split('\\', StringSplitOptions.RemoveEmptyEntries))
                {
                    running = Path.Combine(running, seg);
                    Breadcrumbs.Add(new BreadcrumbSegment(seg, RemoteLocation.Local(loc.Platform, running)));
                }
            }
            else
            {
                Breadcrumbs.Add(new BreadcrumbSegment(driveRoot.TrimEnd('\\'), RemoteLocation.Local(loc.Platform, driveRoot)));
                var rel = full[driveRoot.Length..].TrimStart('\\');
                var running = driveRoot;
                foreach (var seg in rel.Split('\\', StringSplitOptions.RemoveEmptyEntries))
                {
                    running = Path.Combine(running, seg);
                    Breadcrumbs.Add(new BreadcrumbSegment(seg, RemoteLocation.Local(loc.Platform, running)));
                }
            }
        }
        else if (loc.Path.StartsWith('\\'))
        {
            Breadcrumbs.Add(new BreadcrumbSegment(SelectedEndpoint.Name, root));
            var rootSegs = root.Path.Trim('\\').Split('\\', StringSplitOptions.RemoveEmptyEntries);
            var segs = loc.Path.Trim('\\').Split('\\', StringSplitOptions.RemoveEmptyEntries);
            var running = @"\";
            for (int i = 0; i < segs.Length; i++)
            {
                running = running == @"\" ? $@"\{segs[i]}" : $@"{running}\{segs[i]}";
                if (i >= rootSegs.Length)
                {
                    Breadcrumbs.Add(new BreadcrumbSegment(segs[i], loc with { Path = running }));
                }
            }
        }
        else
        {
            Breadcrumbs.Add(new BreadcrumbSegment(SelectedEndpoint.Name, root));
            var rootNorm = root.Path.TrimEnd('/');
            var norm = loc.Path.TrimEnd('/');
            if (norm.Length > rootNorm.Length && norm.StartsWith(rootNorm, StringComparison.Ordinal))
            {
                var rel = norm[rootNorm.Length..].TrimStart('/');
                var running = rootNorm == "" ? "/" : rootNorm;
                foreach (var seg in rel.Split('/', StringSplitOptions.RemoveEmptyEntries))
                {
                    running = running == "/" ? $"/{seg}" : $"{running}/{seg}";
                    Breadcrumbs.Add(new BreadcrumbSegment(seg, loc with { Path = running }));
                }
            }
        }
    }

    private static bool IsAtRoot(RemoteLocation current, RemoteLocation root) =>
        string.Equals(current.Path.TrimEnd('\\', '/'), root.Path.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase);
}

public sealed class MainViewModel : ObservableObject
{
    private readonly DeviceManager _deviceManager = new();
    private readonly UnifiedTransferService _transferService;

    public PaneViewModel LeftPane { get; }
    public PaneViewModel RightPane { get; }
    public ObservableCollection<TransferJobViewModel> Jobs { get; } = [];

    public static IReadOnlyList<ConflictPolicyOption> ConflictPolicies { get; } =
    [
        new(ConflictPolicy.AskEachTime, "Conflicts: Ask Each Time"),
        new(ConflictPolicy.KeepBoth, "Conflicts: Keep Both"),
        new(ConflictPolicy.ReplaceExisting, "Conflicts: Replace"),
        new(ConflictPolicy.SkipExisting, "Conflicts: Skip Existing")
    ];

    private ConflictPolicyOption _selectedConflictPolicy = ConflictPolicies[0];
    public ConflictPolicyOption SelectedConflictPolicy
    {
        get => _selectedConflictPolicy;
        set => SetProperty(ref _selectedConflictPolicy, value);
    }

    private bool _showHiddenFiles;
    public bool ShowHiddenFiles
    {
        get => _showHiddenFiles;
        set
        {
            if (SetProperty(ref _showHiddenFiles, value))
            {
                LeftPane.ShowHidden = value;
                RightPane.ShowHidden = value;
            }
        }
    }

    private bool _isScanning;
    public bool IsScanning
    {
        get => _isScanning;
        set => SetProperty(ref _isScanning, value);
    }

    private int _connectedDeviceCount;
    public int ConnectedDeviceCount
    {
        get => _connectedDeviceCount;
        set
        {
            if (SetProperty(ref _connectedDeviceCount, value))
            {
                OnPropertyChanged(nameof(ConnectedSummary));
            }
        }
    }

    private bool _isTransfersExpanded = true;
    public bool IsTransfersExpanded
    {
        get => _isTransfersExpanded;
        set => SetProperty(ref _isTransfersExpanded, value);
    }

    public string ConnectedSummary => ConnectedDeviceCount switch
    {
        0 => "No external devices connected",
        1 => "1 connected endpoint",
        _ => $"{ConnectedDeviceCount} connected endpoints"
    };

    public Func<ConflictPrompt, Task<ConflictDecision>>? ConflictPromptHandler { get; set; }
    public Func<string, string, string, string?>? InputPromptHandler { get; set; }
    public Func<string, string, bool>? ConfirmPromptHandler { get; set; }
    public Func<string?>? FolderPickerHandler { get; set; }
    public Action<string, string>? AlertHandler { get; set; }

    public ICommand RescanCommand { get; }
    public ICommand SwapPanesCommand { get; }
    public ICommand CopyLeftToRightCommand { get; }
    public ICommand MoveLeftToRightCommand { get; }
    public ICommand CopyRightToLeftCommand { get; }
    public ICommand MoveRightToLeftCommand { get; }
    public ICommand ClearFinishedJobsCommand { get; }

    public MainViewModel()
    {
        _transferService = new UnifiedTransferService(_deviceManager.MTPService, _deviceManager.ADBService, _deviceManager.IOSService);
        LeftPane = new PaneViewModel("Left Pane", _transferService);
        RightPane = new PaneViewModel("Right Pane", _transferService);

        RescanCommand = new AsyncRelayCommand(RescanAsync);
        SwapPanesCommand = new AsyncRelayCommand(SwapPanesAsync);
        CopyLeftToRightCommand = new AsyncRelayCommand(() => StartPaneTransferAsync(LeftPane, RightPane, TransferMode.Copy), () => CanTransfer(LeftPane, RightPane));
        MoveLeftToRightCommand = new AsyncRelayCommand(() => StartPaneTransferAsync(LeftPane, RightPane, TransferMode.Move), () => CanTransfer(LeftPane, RightPane, move: true));
        CopyRightToLeftCommand = new AsyncRelayCommand(() => StartPaneTransferAsync(RightPane, LeftPane, TransferMode.Copy), () => CanTransfer(RightPane, LeftPane));
        MoveRightToLeftCommand = new AsyncRelayCommand(() => StartPaneTransferAsync(RightPane, LeftPane, TransferMode.Move), () => CanTransfer(RightPane, LeftPane, move: true));
        ClearFinishedJobsCommand = new RelayCommand(ClearFinishedJobs, () => Jobs.Any(j => !j.IsActive));
    }

    public async Task InitializeAsync()
    {
        await RescanAsync();
    }

    public async Task RescanAsync()
    {
        if (IsScanning) return;
        IsScanning = true;
        try
        {
            var endpoints = await _deviceManager.DiscoverAllEndpointsAsync();
            ConnectedDeviceCount = endpoints.Count(e => e.Platform != EndpointPlatform.WindowsPC);

            var nonPc = endpoints.FirstOrDefault(e => e.Platform != EndpointPlatform.WindowsPC);
            await LeftPane.SetAvailableEndpointsAsync(endpoints, LeftPane.SelectedEndpoint?.Id ?? "win::local");
            await RightPane.SetAvailableEndpointsAsync(endpoints, RightPane.SelectedEndpoint?.Id ?? nonPc?.Id ?? "win::local");
        }
        finally
        {
            IsScanning = false;
            RelayCommand.RaiseCanExecuteChanged();
        }
    }

    public async Task SwapPanesAsync()
    {
        var leftId = LeftPane.SelectedEndpoint?.Id;
        var rightId = RightPane.SelectedEndpoint?.Id;
        var endpoints = LeftPane.Endpoints.ToList();
        await LeftPane.SetAvailableEndpointsAsync(endpoints, rightId);
        await RightPane.SetAvailableEndpointsAsync(endpoints, leftId);
    }

    public async Task AddCustomFolderAsync(PaneViewModel pane)
    {
        var folder = FolderPickerHandler?.Invoke();
        if (string.IsNullOrWhiteSpace(folder)) return;

        _deviceManager.DriveMonitor.AddCustomFolderTarget(folder);
        var endpoints = await _deviceManager.DiscoverAllEndpointsAsync();
        ConnectedDeviceCount = endpoints.Count(e => e.Platform != EndpointPlatform.WindowsPC);

        var addedId = $"drive::custom::{folder}";
        var otherPane = ReferenceEquals(pane, LeftPane) ? RightPane : LeftPane;
        await pane.SetAvailableEndpointsAsync(endpoints, addedId);
        await otherPane.SetAvailableEndpointsAsync(endpoints, otherPane.SelectedEndpoint?.Id);
    }

    public async Task EjectDriveAsync(PaneViewModel pane)
    {
        if (pane.SelectedEndpoint?.Drive is not { } drive) return;
        try
        {
            await _deviceManager.DriveMonitor.EjectDriveAsync(drive);
            await RescanAsync();
        }
        catch (Exception ex)
        {
            AlertHandler?.Invoke("Eject Failed", ex.Message);
        }
    }

    public async Task CreateFolderAsync(PaneViewModel pane)
    {
        if (pane.CurrentLocation is not { } loc || !pane.CanModifyFilesystem) return;
        var name = InputPromptHandler?.Invoke("New Folder", "Enter folder name:", "New Folder");
        if (string.IsNullOrWhiteSpace(name)) return;

        try
        {
            await _transferService.CreateFolderAsync(loc, name);
            await pane.RefreshAsync();
        }
        catch (Exception ex)
        {
            AlertHandler?.Invoke("Create Folder Failed", ex.Message);
        }
    }

    public async Task RenameSelectedAsync(PaneViewModel pane)
    {
        if (pane.CurrentLocation is not { } parent || pane.SelectedEntries.Count != 1 || !pane.CanModifyFilesystem) return;
        var target = pane.SelectedEntries[0];
        var newName = InputPromptHandler?.Invoke("Rename", $"Rename '{target.Name}' to:", target.Name);
        if (string.IsNullOrWhiteSpace(newName) || newName == target.Name) return;

        try
        {
            await _transferService.RenameAsync(target, parent, newName);
            await pane.RefreshAsync();
        }
        catch (Exception ex)
        {
            AlertHandler?.Invoke("Rename Failed", ex.Message);
        }
    }

    public async Task DeleteSelectedAsync(PaneViewModel pane)
    {
        if (pane.CurrentLocation is not { } parent || pane.SelectedEntries.Count == 0 || !pane.CanModifyFilesystem) return;
        var count = pane.SelectedEntries.Count;
        var label = count == 1 ? $"'{pane.SelectedEntries[0].Name}'" : $"{count} selected items";
        var msg = parent.IsLocal
            ? $"Move {label} to the Recycle Bin (or delete permanently on removable drives)?"
            : $"Permanently delete {label} from {pane.SelectedEndpoint?.Name ?? "device"}?";

        if (ConfirmPromptHandler?.Invoke("Confirm Delete", msg) != true) return;

        try
        {
            await _transferService.DeleteAsync(pane.SelectedEntries, parent, permanentIfNeeded: true);
            await pane.RefreshAsync();
        }
        catch (Exception ex)
        {
            AlertHandler?.Invoke("Delete Failed", ex.Message);
        }
    }

    public void OpenEntry(PaneViewModel pane, BrowserEntryViewModel entryVm)
    {
        if (entryVm.IsDirectory)
        {
            _ = pane.NavigateToAsync(entryVm.Entry.Location);
            return;
        }

        if (entryVm.Entry.Location.IsLocal)
        {
            try
            {
                Process.Start(new ProcessStartInfo(entryVm.Entry.Location.Path) { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                AlertHandler?.Invoke("Open Failed", ex.Message);
            }
        }
    }

    public Task TransferBetweenPanesAsync(PaneViewModel source, PaneViewModel dest, IReadOnlyList<BrowserEntry> entries, TransferMode mode)
    {
        return ExecuteTransferAsync(entries, source, dest, mode);
    }

    public async Task DropExternalFilesAsync(PaneViewModel targetPane, string[] localPaths, TransferMode mode)
    {
        if (targetPane.SelectedEndpoint is not { } destEp
            || targetPane.CurrentLocation is not { } destLoc
            || destEp.IsReadOnly
            || destEp.RequiresAttention)
        {
            return;
        }

        var syntheticEntries = new List<BrowserEntry>();
        foreach (var p in localPaths)
        {
            if (Directory.Exists(p))
            {
                var di = new DirectoryInfo(p);
                syntheticEntries.Add(new BrowserEntry
                {
                    Id = p,
                    Name = di.Name,
                    IsDirectory = true,
                    Size = 0,
                    ModifiedDate = di.LastWriteTime,
                    Location = RemoteLocation.Local(EndpointPlatform.WindowsPC, p)
                });
            }
            else if (File.Exists(p))
            {
                var fi = new FileInfo(p);
                syntheticEntries.Add(new BrowserEntry
                {
                    Id = p,
                    Name = fi.Name,
                    IsDirectory = false,
                    Size = fi.Length,
                    ModifiedDate = fi.LastWriteTime,
                    Location = RemoteLocation.Local(EndpointPlatform.WindowsPC, p)
                });
            }
        }

        if (syntheticEntries.Count == 0) return;

        var fakePc = StorageEndpoint.WindowsHome();
        await ExecuteTransferAsync(syntheticEntries, fakePc, fakePc.RootLocation, targetPane, destEp, destLoc, mode);
    }

    private Task StartPaneTransferAsync(PaneViewModel source, PaneViewModel dest, TransferMode mode)
    {
        return ExecuteTransferAsync(source.SelectedEntries.ToList(), source, dest, mode);
    }

    private Task ExecuteTransferAsync(IReadOnlyList<BrowserEntry> entries, PaneViewModel source, PaneViewModel dest, TransferMode mode)
    {
        if (source.SelectedEndpoint is not { } srcEp
            || source.CurrentLocation is not { } srcParent
            || dest.SelectedEndpoint is not { } dstEp
            || dest.CurrentLocation is not { } dstDir)
        {
            return Task.CompletedTask;
        }
        return ExecuteTransferAsync(entries, srcEp, srcParent, dest, dstEp, dstDir, mode);
    }

    private async Task ExecuteTransferAsync(
        IReadOnlyList<BrowserEntry> entries,
        StorageEndpoint sourceEndpoint,
        RemoteLocation sourceParent,
        PaneViewModel? destinationPaneToRefresh,
        StorageEndpoint destinationEndpoint,
        RemoteLocation destinationDirectory,
        TransferMode mode)
    {
        if (entries.Count == 0) return;

        var verb = mode == TransferMode.Copy ? "Copy" : "Move";
        var summaryName = entries.Count == 1 ? entries[0].Name : $"{entries.Count} items";
        var job = new TransferJobViewModel(
            $"{verb}: {summaryName}",
            $"{sourceEndpoint.Name}  ->  {destinationEndpoint.Name}");

        Jobs.Insert(0, job);
        IsTransfersExpanded = true;
        RelayCommand.RaiseCanExecuteChanged();

        var uiDispatcher = Application.Current?.Dispatcher;

        try
        {
            var (completed, skipped) = await _transferService.ExecuteAsync(
                entries,
                sourceEndpoint,
                sourceParent,
                destinationEndpoint,
                destinationDirectory,
                mode,
                SelectedConflictPolicy.Policy,
                job.Control,
                async snapshot =>
                {
                    if (uiDispatcher is not null)
                    {
                        await uiDispatcher.InvokeAsync(() => job.UpdateProgress(snapshot));
                    }
                    else
                    {
                        job.UpdateProgress(snapshot);
                    }
                },
                async prompt =>
                {
                    if (ConflictPromptHandler is null)
                    {
                        return new ConflictDecision(ConflictResolution.Skip, false);
                    }
                    if (uiDispatcher is not null)
                    {
                        var tcs = new TaskCompletionSource<ConflictDecision>();
                        _ = uiDispatcher.BeginInvoke(async () =>
                        {
                            try
                            {
                                var decision = await ConflictPromptHandler(prompt);
                                tcs.TrySetResult(decision);
                            }
                            catch (Exception ex)
                            {
                                tcs.TrySetException(ex);
                            }
                        });
                        return await tcs.Task.ConfigureAwait(false);
                    }
                    return await ConflictPromptHandler(prompt).ConfigureAwait(false);
                });

            job.ProgressPercent = 100;
            job.State = skipped > 0 ? TransferState.CompletedWithSkips : TransferState.Completed;
            job.CurrentFileName = skipped > 0
                ? $"Completed {completed}, skipped {skipped}"
                : $"Transferred {completed} file{(completed == 1 ? "" : "s")}";
        }
        catch (OperationCanceledException)
        {
            job.State = TransferState.Cancelled;
            job.CurrentFileName = "Transfer cancelled";
        }
        catch (Exception ex)
        {
            job.State = TransferState.Failed;
            job.ErrorMessage = ex.Message;
            job.CurrentFileName = "Transfer failed";
        }
        finally
        {
            RelayCommand.RaiseCanExecuteChanged();
            await LeftPane.RefreshAsync();
            if (!ReferenceEquals(destinationPaneToRefresh, LeftPane))
            {
                await RightPane.RefreshAsync();
            }
        }
    }

    private void ClearFinishedJobs()
    {
        for (int i = Jobs.Count - 1; i >= 0; i--)
        {
            if (!Jobs[i].IsActive)
            {
                Jobs.RemoveAt(i);
            }
        }
        RelayCommand.RaiseCanExecuteChanged();
    }

    private static bool CanTransfer(PaneViewModel source, PaneViewModel dest, bool move = false)
    {
        if (source.SelectedEntries.Count == 0) return false;
        if (source.SelectedEndpoint is null || dest.SelectedEndpoint is null) return false;
        if (source.SelectedEndpoint.RequiresAttention || dest.SelectedEndpoint.RequiresAttention) return false;
        if (dest.SelectedEndpoint.IsReadOnly) return false;
        if (move && source.SelectedEndpoint.IsReadOnly) return false;
        return dest.CurrentLocation is not null;
    }
}
