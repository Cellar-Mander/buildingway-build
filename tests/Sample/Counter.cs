using System;

namespace Sample;

public class Counter
{
    private const int Start = 0;
    private static readonly object Gate = new();
    private int count = Start;

    public event EventHandler? OnChanged;

    public int Increment()
    {
        lock (Gate)
        {
            count++;
        }

        OnChanged?.Invoke(this, EventArgs.Empty);
        return count;
    }
}
