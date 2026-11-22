# Sharinbox browser connector (Société Générale employee shares)

<!-- sync:connector-note:start -->
> **Hinweis / Note:** Dieser Connector ist ein unabhängiges Community-Projekt und steht in keiner Verbindung zur Société Générale. Schnittstelle: inoffiziell. Bei inoffiziellen Schnittstellen kann die Nutzung gegen die Nutzungsbedingungen der Bank verstoßen.
> This connector is an independent community project and is not affiliated with Société Générale. Interface: unofficial. Using unofficial interfaces may violate the bank's terms of service.
<!-- sync:connector-note:end -->

Employee share plans administered by Société Générale Securities Services are shown on
the **Sharinbox** portal. Sign in through **Add bank → Sharinbox (Société Générale)**. The login
(SG Connect: e-mail, password and authenticator app) happens in the embedded browser. After
login, choose **Bestand abrufen**.

This first version reads the **number of shares and their value** from the portal's start
page. The mailbox (PDF documents) is planned as a separate step.

## What is imported

- One securities account ("Mitarbeiteraktien") with one position per security the start page
  lists: ISIN, name, quantity, price with its date, and value.
- Quantity and value are the available and the blocked balance added up.
- Share rights (Aktienrechte) are not imported.
- The portal shows no purchase price, so no profit or loss is derived.
- Only EUR is accepted; anything else is rejected rather than guessed.

## Browser flow and technical validation

The portal signs in through SG Connect (OAuth 2.0) and then serves the start page
(`/SharinBox/connexion.do`) as HTML in the signed-in session. The page script reads that page
with a same-origin request and extracts the selected fields. No token or cookie reaches
Swift, logs or the vault; Swift receives only ISIN, name, quantity, price, price date,
currency and value. Names, e-mail addresses, account and holder numbers are not exported.
The generic portal traffic recorder is disabled for this connector.

Consistency checks before anything is stored: ISINs must be well formed and unique, the
price date a valid date, and each value must match quantity × price (the page shows the price
with three decimals). A failed check imports nothing.

## Limits

- The page is parsed from its HTML. A change of the portal's page layout stops the fetch with a
  message; nothing is imported then.
- The embedded browser is needed on every fetch (authenticator app); there is no background
  sync.
- The portal is not documented and can change without notice.
