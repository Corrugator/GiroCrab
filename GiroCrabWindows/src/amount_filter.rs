//! Amount filter of the booking list (#357): "Betrag von … bis …" plus income / expenses only.
//! Pure logic without Slint; the values go into the core `BookingFilter`, which does the
//! filtering (by absolute amount, like the Mac app's `AmountFilter`).

use crate::planning::{format_plain, parse_cents};
use girocrab_core::{BookingDirection, BookingFilter};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct AmountFilter {
    pub min_cents: Option<i64>,
    pub max_cents: Option<i64>,
    pub direction: BookingDirection,
}

/// Index of the "Alle / Nur Einnahmen / Nur Ausgaben" selector.
pub fn direction_from_index(i: i32) -> BookingDirection {
    match i {
        1 => BookingDirection::Income,
        2 => BookingDirection::Expense,
        _ => BookingDirection::All,
    }
}

impl AmountFilter {
    /// Reads the two fields (German decimal comma, empty = open bound). The sign is ignored
    /// like in the core; swapped bounds are swapped instead of rejected.
    pub fn parse(from: &str, to: &str, direction_index: i32) -> Result<Self, String> {
        let bound = |label: &str, text: &str| -> Result<Option<i64>, String> {
            if text.trim().is_empty() {
                return Ok(None);
            }
            parse_cents(text)
                .map(|c| Some(c.abs()))
                .ok_or_else(|| format!("„{label}“ ist kein gültiger Betrag (z. B. 1.234,50)."))
        };
        let (mut min_cents, mut max_cents) = (bound("von", from)?, bound("bis", to)?);
        if let (Some(a), Some(b)) = (min_cents, max_cents)
            && a > b
        {
            (min_cents, max_cents) = (Some(b), Some(a));
        }
        Ok(Self {
            min_cents,
            max_cents,
            direction: direction_from_index(direction_index),
        })
    }

    pub fn is_active(&self) -> bool {
        self.min_cents.is_some()
            || self.max_cents.is_some()
            || self.direction != BookingDirection::All
    }

    /// Writes the amount range and direction into a core filter; other fields stay untouched.
    pub fn apply(&self, f: &mut BookingFilter) {
        f.amount_min_cents = self.min_cents;
        f.amount_max_cents = self.max_cents;
        f.direction = self.direction;
    }

    /// Label of the filter button; amounts are masked in privacy mode.
    pub fn title(&self, privacy: bool) -> String {
        let eur = |c: i64| format!("{} €", format_plain(c));
        let range = match (self.min_cents, self.max_cents) {
            (Some(a), Some(b)) => Some(format!("{} – {}", format_plain(a), eur(b))),
            (Some(a), None) => Some(format!("≥ {}", eur(a))),
            (None, Some(b)) => Some(format!("≤ {}", eur(b))),
            (None, None) => None,
        };
        let dir = match self.direction {
            BookingDirection::All => None,
            BookingDirection::Income => Some("Nur Einnahmen"),
            BookingDirection::Expense => Some("Nur Ausgaben"),
        };
        match (range, dir) {
            (None, None) => "Betrag".into(),
            (None, Some(d)) => d.into(),
            (Some(r), d) => {
                let r = crate::daily::mask(&r, privacy);
                match d {
                    Some(d) => format!("Betrag: {r} · {d}"),
                    None => format!("Betrag: {r}"),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nav::{Target, booking_filter};

    #[test]
    fn parses_german_thousands_and_decimal_comma() {
        let a = AmountFilter::parse("1.234,50", "", 0).unwrap();
        assert_eq!(a.min_cents, Some(123_450));
        assert_eq!(a.max_cents, None);
        assert_eq!(a.direction, BookingDirection::All);
        assert!(a.is_active());
        assert_eq!(a.title(false), "Betrag: ≥ 1234,50 €");
    }

    #[test]
    fn empty_fields_are_inactive() {
        let a = AmountFilter::parse("", "   ", 0).unwrap();
        assert_eq!(a, AmountFilter::default());
        assert!(!a.is_active());
        assert_eq!(a.title(true), "Betrag");
    }

    #[test]
    fn swapped_bounds_are_swapped_and_sign_ignored() {
        let a = AmountFilter::parse("100", "-20,5", 2).unwrap();
        assert_eq!((a.min_cents, a.max_cents), (Some(2_050), Some(10_000)));
        assert_eq!(a.direction, BookingDirection::Expense);
        assert!(AmountFilter::parse("abc", "", 0).is_err());
    }

    #[test]
    fn builds_core_filter_and_keeps_target() {
        let a = AmountFilter::parse("50", "200", 1).unwrap();
        let mut f = booking_filter(Target::Account(7));
        a.apply(&mut f);
        assert_eq!(f.account_ids, vec![7]);
        assert_eq!(f.amount_min_cents, Some(5_000));
        assert_eq!(f.amount_max_cents, Some(20_000));
        assert_eq!(f.direction, BookingDirection::Income);
    }

    #[test]
    fn title_masks_amounts_in_privacy_mode() {
        let a = AmountFilter::parse("10", "20", 2).unwrap();
        assert_eq!(a.title(true), "Betrag: •••••• · Nur Ausgaben");
        assert_eq!(a.title(false), "Betrag: 10,00 – 20,00 € · Nur Ausgaben");
    }
}
