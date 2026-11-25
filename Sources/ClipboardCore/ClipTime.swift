import Foundation

/// When an item was copied, as the list shows it: "14:05", with the seconds ("14:05:32") when
/// another item was copied in the same minute, and the day in front before today ("Nov 18 14:05",
/// with the year before this year).
public enum ClipTime {
    public static func label(for date: Date, withSeconds: Bool, now: Date = Date(),
                             calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = format(date, withSeconds ? "HHmmss" : "HHmm", calendar: calendar, locale: locale)
        guard !calendar.isDate(date, inSameDayAs: now) else { return time }
        let thisYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        return format(date, thisYear ? "dMMM" : "dMMMy", calendar: calendar, locale: locale) + " " + time
    }

    private static func format(_ date: Date, _ template: String, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// The minutes in which more than one of these items was copied: theirs show the seconds.
    public static func crowdedMinutes(_ dates: [Date], calendar: Calendar = .current) -> Set<Date> {
        var counts: [Date: Int] = [:]
        for date in dates { counts[minute(of: date, calendar: calendar), default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    public static func minute(of date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .minute, for: date)?.start ?? date
    }

    /// Everything about the date, for the tooltip.
    public static func fullLabel(for date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
