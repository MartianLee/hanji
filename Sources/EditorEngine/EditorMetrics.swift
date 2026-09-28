/// Counters the checks read to hold the editor to its incremental design: how
/// much a keystroke restyles, how often it has to restyle everything, how many
/// refreshes and widget views it costs. Plain increments on the main thread;
/// the app never reads them.
public enum EditorMetrics {
    /// Characters handed to LivePreviewStyler (restyled scopes, summed).
    public static var restyledCharacters = 0
    /// Restyles that covered the whole note.
    public static var fullRestyles = 0
    /// `refresh()` calls that actually restyled.
    public static var refreshes = 0
    /// Widget hosting views created.
    public static var widgetViewsCreated = 0
    /// Height reservations written by `reserve` (the text storage or a restyle's copy).
    public static var reservationWrites = 0

    public static func reset() {
        restyledCharacters = 0; fullRestyles = 0; refreshes = 0
        widgetViewsCreated = 0; reservationWrites = 0
    }
}
