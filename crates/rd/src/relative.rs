//! Relative timestamps for `rd list -t`, standing in for Foundation's
//! `RelativeDateTimeFormatter` with `.full` units.

use std::time::SystemTime;

/// "3 days ago", "in 2 hours", "now".
pub fn describe(date: SystemTime) -> String {
    describe_since(date, SystemTime::now())
}

/// The clock is a parameter so tests can pin it. Reading `now` inside would
/// make every boundary case ("exactly one hour ago") flaky by the microseconds
/// between the caller's timestamp and ours.
fn describe_since(date: SystemTime, now: SystemTime) -> String {
    let (seconds, future) = match now.duration_since(date) {
        Ok(elapsed) => (elapsed.as_secs(), false),
        // A clock skew or a commit dated ahead of us.
        Err(error) => (error.duration().as_secs(), true),
    };

    const MINUTE: u64 = 60;
    const HOUR: u64 = 60 * MINUTE;
    const DAY: u64 = 24 * HOUR;
    const WEEK: u64 = 7 * DAY;
    const MONTH: u64 = 30 * DAY;
    const YEAR: u64 = 365 * DAY;

    // Explicit half-open ranges rather than a fall-through ladder of `..X`,
    // which all start at zero and so overlap each other.
    let (count, unit) = match seconds {
        0..MINUTE => return "now".to_string(),
        MINUTE..HOUR => (seconds / MINUTE, "minute"),
        HOUR..DAY => (seconds / HOUR, "hour"),
        DAY..WEEK => (seconds / DAY, "day"),
        WEEK..MONTH => (seconds / WEEK, "week"),
        MONTH..YEAR => (seconds / MONTH, "month"),
        _ => (seconds / YEAR, "year"),
    };

    let plural = if count == 1 { "" } else { "s" };
    if future {
        format!("in {count} {unit}{plural}")
    } else {
        format!("{count} {unit}{plural} ago")
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    /// A fixed instant well clear of the epoch, so subtracting can't underflow.
    fn now() -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(1_800_000_000)
    }

    fn ago(seconds: u64) -> String {
        describe_since(now() - Duration::from_secs(seconds), now())
    }

    #[test]
    fn describes_each_unit() {
        assert_eq!(ago(5), "now");
        assert_eq!(ago(60), "1 minute ago");
        assert_eq!(ago(3 * 60), "3 minutes ago");
        assert_eq!(ago(2 * 3600), "2 hours ago");
        assert_eq!(ago(3 * 86400), "3 days ago");
        assert_eq!(ago(14 * 86400), "2 weeks ago");
        assert_eq!(ago(60 * 86400), "2 months ago");
        assert_eq!(ago(400 * 86400), "1 year ago");
    }

    #[test]
    fn describes_a_future_date() {
        let later = now() + Duration::from_secs(2 * 3600);
        assert_eq!(describe_since(later, now()), "in 2 hours");
    }
}
