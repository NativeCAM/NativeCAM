import Foundation

/// Run times as the app shows them.
public enum DurationFormat {
    /// "m:ss", or "h:mm:ss" from an hour, rounded to the second.
    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// A difference in run time, "+0:01" or "−1:01", rounded to the second first so the sign matches what's shown:
    /// one that rounds to nothing is "0:00", with no sign (#150).
    public static func signedDelta(_ seconds: Double) -> String {
        let s = seconds.rounded()
        if s == 0 { return "0:00" }
        return (s > 0 ? "+" : "−") + duration(abs(s))
    }
}
