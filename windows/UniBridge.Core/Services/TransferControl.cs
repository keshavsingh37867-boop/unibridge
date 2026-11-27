namespace UniBridge.Core.Services;

public sealed class TransferControl
{
    private readonly CancellationTokenSource _cts = new();
    private readonly ManualResetEventSlim _pauseGate = new(initialState: true);
    private volatile bool _isPaused;

    public bool IsPaused => _isPaused;
    public bool IsCancelled => _cts.IsCancellationRequested;
    public CancellationToken Token => _cts.Token;

    public void Pause()
    {
        if (IsCancelled) return;
        _isPaused = true;
        _pauseGate.Reset();
    }

    public void Resume()
    {
        _isPaused = false;
        _pauseGate.Set();
    }

    public void Cancel()
    {
        _isPaused = false;
        _cts.Cancel();
        _pauseGate.Set();
    }

    public async Task WaitIfPausedAsync()
    {
        _cts.Token.ThrowIfCancellationRequested();
        if (_isPaused)
        {
            await Task.Run(() => _pauseGate.Wait(_cts.Token), _cts.Token).ConfigureAwait(false);
        }
        _cts.Token.ThrowIfCancellationRequested();
    }
}
