//! Sharinbox (Société Générale Securities Services): employee share plans. The pages are
//! read inside the embedded browser; only the selected share data crosses the bridge.
//! The portal is the only interface (no FinTS/PSD2), see `docs/sharinbox-connector.md`.
use std::{collections::HashSet, sync::Arc};

use serde_json::Value;

use super::{FetchResult, RemoteAccount, RemoteHolding, SyncSummary};
use crate::{
    error::{CoreError, CoreResult},
    i18n::tr,
    models::{AccountKind, ConnectorKind, Holding},
    vault::Vault,
};

/// Stable reference of the single securities account; it carries no personal number.
const ACCOUNT_REF: &str = "depot:sharinbox";

fn invalid() -> CoreError {
    CoreError::InvalidInput {
        message: tr("Sharinbox: Unvollständige oder ungültige Portalantwort. Es wurden keine Daten übernommen.").into(),
    }
}

fn text<'a>(v: &'a Value, key: &str) -> CoreResult<&'a str> {
    v[key]
        .as_str()
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(invalid)
}

fn date(v: &Value, key: &str) -> CoreResult<String> {
    let s = text(v, key)?.get(..10).ok_or_else(invalid)?;
    jiff::civil::Date::strptime("%Y-%m-%d", s).map_err(|_| invalid())?;
    Ok(s.into())
}

fn number(v: &Value, key: &str) -> CoreResult<f64> {
    v[key]
        .as_f64()
        .filter(|n| n.is_finite() && n.abs() < 1e12)
        .ok_or_else(invalid)
}

/// Monetary values are rounded once at the boundary, never quantities.
fn cents_of(n: f64) -> i64 {
    (n * 100.0).round() as i64
}

/// One security as the portal shows it: the available and the blocked balance are added up
/// by the page script, so quantity and value are totals.
struct Position {
    isin: String,
    name: String,
    quantity: f64,
    price: f64,
    value: i64,
}

fn positions(depot: &Value) -> CoreResult<Vec<Position>> {
    let items = depot["items"].as_array().ok_or_else(invalid)?;
    let mut seen = HashSet::new();
    let mut out = Vec::with_capacity(items.len());
    for item in items {
        let isin = text(item, "isin")?;
        if isin.len() != 12
            || !isin.bytes().all(|b| b.is_ascii_alphanumeric())
            || !seen.insert(isin.to_string())
        {
            return Err(invalid());
        }
        if text(item, "currency")? != "EUR" {
            return Err(invalid());
        }
        date(item, "priceDate")?;
        let quantity = number(item, "quantity")?;
        let price = number(item, "price")?;
        let value = cents_of(number(item, "value")?);
        if quantity < 0.0 || price < 0.0 || value < 0 {
            return Err(invalid());
        }
        // value = shares x price. The price is shown with three decimals, so allow 1 ct plus
        // 0.05 ct per share for that rounding.
        let expected = (quantity * price * 100.0).round() as i64;
        if (value - expected).abs() > 1 + (quantity * 0.05).ceil() as i64 {
            return Err(invalid());
        }
        out.push(Position {
            isin: isin.into(),
            name: item["name"]
                .as_str()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .unwrap_or(isin)
                .into(),
            quantity,
            price,
            value,
        });
    }
    Ok(out)
}

fn holding(p: &Position) -> Holding {
    // the portal shows no purchase price, so there is no profit or loss either
    Holding {
        isin: p.isin.clone(),
        name: p.name.clone(),
        quantity: p.quantity,
        current_price_cents: cents_of(p.price),
        value_cents: p.value,
        ..Default::default()
    }
}

fn snapshot(json: &str) -> CoreResult<FetchResult> {
    let root: Value = serde_json::from_str(json).map_err(|_| invalid())?;
    if root["version"].as_u64() != Some(1) {
        return Err(invalid());
    }
    let as_of = date(&root, "asOf")?;
    let depot = &root["depot"];
    let positions = positions(depot)?;
    let total: i64 = positions.iter().map(|p| p.value).sum();
    let mut result = FetchResult {
        bank_name: Some("Sharinbox".into()),
        ..Default::default()
    };
    result.accounts.push(RemoteAccount {
        external_ref: ACCOUNT_REF.into(),
        name: tr("Mitarbeiteraktien").into(),
        owner: String::new(),
        iban: String::new(),
        account_number: String::new(),
        currency: "EUR".into(),
        kind: AccountKind::Brokerage,
        balance_cents: total,
        balance_date: as_of,
    });
    for p in &positions {
        result.holdings.push(RemoteHolding {
            classification: Default::default(),
            direct_crypto: false,
            account_ref: ACCOUNT_REF.into(),
            holding: holding(p),
        });
    }
    // an empty list clears positions that were sold since the last fetch
    result.holdings_fetched.push(ACCOUNT_REF.into());
    Ok(result)
}

#[uniffi::export]
impl Vault {
    pub fn import_sharinbox_snapshot(
        self: Arc<Self>,
        connection_id: i64,
        snapshot_json: String,
    ) -> CoreResult<SyncSummary> {
        if self.portal_connection(connection_id)?.0 != ConnectorKind::Sharinbox {
            return Err(invalid());
        }
        crate::banking_gate::check_connector("sharinbox")?;
        let summary = super::store_fetch(
            &self,
            ConnectorKind::Sharinbox,
            connection_id,
            snapshot(&snapshot_json)?,
        )?;
        let _ = self.checkpoint();
        Ok(summary)
    }
}

/// Placeholder connector: the login and the page reads run in the embedded browser.
pub struct WebOnlyConnector;

#[async_trait::async_trait]
impl super::BankConnector for WebOnlyConnector {
    async fn begin(&mut self, _ctx: &super::ConnectContext) -> CoreResult<super::Phase> {
        Err(CoreError::BrowserLoginRequired {
            message: tr("Bitte bei Sharinbox im Browserfenster anmelden und die Daten abrufen.")
                .into(),
        })
    }
    async fn respond(
        &mut self,
        ctx: &super::ConnectContext,
        _response: super::ChallengeResponse,
    ) -> CoreResult<super::Phase> {
        self.begin(ctx).await
    }
    async fn fetch(&mut self, _ctx: &super::ConnectContext) -> CoreResult<FetchResult> {
        Err(CoreError::BrowserLoginRequired {
            message: tr("Bitte bei Sharinbox im Browserfenster abrufen.").into(),
        })
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn item(isin: &str, quantity: f64, price: f64, value: f64) -> Value {
        json!({"isin":isin,"name":"Test Aktie","quantity":quantity,"price":price,
            "priceDate":"2026-11-20","currency":"EUR","value":value})
    }

    fn fixture() -> Value {
        json!({"version":1,"asOf":"2026-11-21","depot":{
            "items":[item("FR0000000001", 100.0, 45.14, 4514.0)]}})
    }

    #[test]
    fn maps_the_share_and_the_total() {
        let r = snapshot(&fixture().to_string()).unwrap();
        assert_eq!(r.accounts.len(), 1);
        assert_eq!(r.accounts[0].kind, AccountKind::Brokerage);
        assert_eq!(r.accounts[0].balance_cents, 451_400);
        assert_eq!(r.accounts[0].external_ref, ACCOUNT_REF);
        assert_eq!(r.holdings.len(), 1);
        let h = &r.holdings[0].holding;
        assert_eq!((h.isin.as_str(), h.quantity), ("FR0000000001", 100.0));
        assert_eq!((h.current_price_cents, h.value_cents), (4514, 451_400));
        assert_eq!(h.purchase_price_cents, 0);
        assert_eq!(r.holdings_fetched, vec![ACCOUNT_REF.to_string()]);
    }

    #[test]
    fn the_price_with_three_decimals_is_tolerated() {
        // 16 290 shares at a price shown as 45.140: no cent difference
        let mut f = fixture();
        f["depot"]["items"] = json!([item("FR0000000001", 16290.0, 45.14, 735330.6)]);
        assert!(snapshot(&f.to_string()).is_ok());
        // rounded price, value from the unrounded one: stays within 0.05 ct per share
        f["depot"]["items"] = json!([item("FR0000000001", 16290.0, 45.14, 735335.0)]);
        assert!(snapshot(&f.to_string()).is_ok());
    }

    #[test]
    fn an_empty_list_is_valid_and_clears_positions() {
        let mut f = fixture();
        f["depot"]["items"] = json!([]);
        let r = snapshot(&f.to_string()).unwrap();
        assert!(r.holdings.is_empty());
        assert_eq!(r.accounts[0].balance_cents, 0);
        assert_eq!(r.holdings_fetched.len(), 1);
    }

    #[test]
    fn rejects_incomplete_or_inconsistent_snapshots() {
        let bad = |f: Value| assert!(snapshot(&f.to_string()).is_err(), "{f}");
        let mut f = fixture();
        f["version"] = json!(2);
        bad(f);
        let mut f = fixture();
        f["asOf"] = json!("gestern");
        bad(f);
        let mut f = fixture();
        f["depot"] = json!({});
        bad(f);
        // value does not match shares x price
        let mut f = fixture();
        f["depot"]["items"] = json!([item("FR0000000001", 1.0, 10.0, 100.0)]);
        bad(f);
        // malformed ISIN, other currency, negative quantity, duplicate ISIN
        for broken in [
            item("FR00", 1.0, 1.0, 1.0),
            json!({"isin":"FR0000000001","name":"x","quantity":1.0,"price":1.0,
                "priceDate":"2026-11-20","currency":"USD","value":1.0}),
            item("FR0000000001", -1.0, 1.0, -1.0),
        ] {
            let mut f = fixture();
            f["depot"]["items"] = json!([broken]);
            bad(f);
        }
        let mut f = fixture();
        f["depot"]["items"] = json!([
            item("FR0000000001", 1.0, 1.0, 1.0),
            item("FR0000000001", 1.0, 1.0, 1.0)
        ]);
        bad(f);
        assert!(snapshot("not json").is_err());
    }

    #[test]
    fn a_missing_name_falls_back_to_the_isin() {
        let mut f = fixture();
        f["depot"]["items"][0]["name"] = json!("  ");
        let r = snapshot(&f.to_string()).unwrap();
        assert_eq!(r.holdings[0].holding.name, "FR0000000001");
    }

    #[test]
    fn import_stores_the_depot_and_is_idempotent() {
        let dir = crate::test_support::TempDir::new("sharinbox-import");
        let vault =
            Vault::open(dir.join("vault.db").to_string_lossy().into(), vec![7; 32]).unwrap();
        let id = vault
            .add_bank_connection(
                ConnectorKind::Sharinbox,
                "Mitarbeiteraktien".into(),
                "x".into(),
            )
            .unwrap();
        for _ in 0..2 {
            let s = vault
                .clone()
                .import_sharinbox_snapshot(id, fixture().to_string())
                .unwrap();
            assert_eq!(s.accounts_updated, 1);
        }
    }

    #[test]
    fn rejects_other_connector_kinds() {
        let dir = crate::test_support::TempDir::new("sharinbox-other");
        let vault =
            Vault::open(dir.join("vault.db").to_string_lossy().into(), vec![7; 32]).unwrap();
        let id = vault
            .add_bank_connection(ConnectorKind::Quirion, "Andere".into(), "x".into())
            .unwrap();
        assert!(
            vault
                .clone()
                .import_sharinbox_snapshot(id, fixture().to_string())
                .is_err()
        );
    }
}
