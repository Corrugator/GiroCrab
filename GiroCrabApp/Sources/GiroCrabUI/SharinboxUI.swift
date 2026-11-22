import SwiftUI
import WebKit
import GiroCrabCore

/// Sharinbox (Société Générale employee share plans). Design page: `docs/sharinbox-connector.md`.
///
/// The user signs in through SG Connect (e-mail, password and authenticator app) in the visible
/// web view. The start page is server-rendered HTML in the signed-in session, so the page script
/// reads it with a same-origin request; no token or cookie ever reaches Swift, logs or the vault.
/// Only the selected share data (ISIN, name, quantity, price, value) crosses the bridge.
enum SharinboxScripts {
    static let hook = #"""
    (() => {
      const pageOrigin = 'https://sharinbox.sgmarkets.com';
      if (location.origin !== pageOrigin || window.__gcSharinbox) return;
      const HOME = '/SharinBox/connexion.do';
      const fail = message => { throw new Error('Sharinbox: ' + message); };
      // "735.330,60" -> 735330.6; "16.290" -> 16290; "-" (nothing held) -> 0
      const amount = raw => {
        const s = String(raw || '').replace(/[\s ]/g, '');
        if (s === '' || s === '-') return 0;
        if (!/^\d{1,3}(\.\d{3})*(,\d+)?$|^\d+(,\d+)?$/.test(s)) fail('Unbekanntes Zahlenformat.');
        return Number(s.replace(/\./g, '').replace(',', '.'));
      };
      const strip = html => String(html || '').replace(/<[^>]*>/g, ' ').replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim();
      // the available and the blocked balance each show "Menge" and "Importe"/"Bewertung"
      const panel = (block, cls) => {
        const m = new RegExp(cls + '[\\s\\S]*?<span class="text-muted">[^<]*</span>\\s*(?:<br\\s*/?>)?\\s*([^<]*?)\\s*</div>\\s*<div class="col-6">\\s*<span class="text-muted">[^<]*</span>\\s*(?:<br\\s*/?>)?\\s*([^<]*?)\\s*</div>').exec(block);
        if (!m) fail('Unbekanntes Seitenformat.');
        const value = /^([\d.,\s-]*?)\s*([A-Z]{3})?$/.exec(m[2].trim());
        if (!value) fail('Unbekanntes Seitenformat.');
        return {quantity: amount(m[1]), value: amount(value[1]), currency: value[2] || ''};
      };
      const parse = html => {
        const items = [];
        const marker = /id="myChart-assets-([A-Z]{2}[A-Z0-9]{9}\d)"/g;
        let m;
        while ((m = marker.exec(html))) {
          const isin = m[1];
          const head = html.lastIndexOf('<h5', m.index);
          const end = html.indexOf('id="myChart-detail-' + isin + '"', m.index);
          if (head < 0 || end < 0) fail('Unbekanntes Seitenformat.');
          const block = html.slice(head, end);
          const name = strip((/<h5[^>]*>([\s\S]*?)<\/h5>/.exec(block) || [])[1]).replace(/^ACTION\s+/i, '');
          const price = /class="stockprice"[\s\S]*?<em>\s*([\d.,]+)\s*\(([A-Z]{3})\)\s*<\/em>/.exec(block);
          const when = /class="stockprice"[\s\S]*?(\d{2})\.(\d{2})\.(\d{2,4})/.exec(block);
          if (!price || !when) fail('Kurs nicht gefunden.');
          const year = when[3].length === 2 ? '20' + when[3] : when[3];
          const free = panel(block, 'panelChartBorderBlue');
          const blocked = panel(block, 'panelChartBorderLightBlue');
          const currency = free.currency || blocked.currency || price[2];
          if ((free.currency && blocked.currency && free.currency !== blocked.currency) || currency !== price[2])
            fail('Uneinheitliche Währung.');
          items.push({isin, name: name || isin, quantity: free.quantity + blocked.quantity, price: amount(price[1]),
            priceDate: year + '-' + when[2] + '-' + when[1], currency, value: free.value + blocked.value});
        }
        return items;
      };
      window.__gcSharinbox = {
        // signed in: the page is inside the portal area after the login
        ready: () => location.origin === pageOrigin && location.pathname.startsWith('/SharinBox/'),
        collect: async () => {
          if (location.origin !== pageOrigin) fail('Bitte erneut anmelden.');
          const controller = new AbortController();
          const timeout = setTimeout(() => controller.abort(), 30000);
          let html;
          try {
            const r = await fetch(HOME, {method: 'GET', credentials: 'same-origin', redirect: 'error',
              headers: {'Accept': 'text/html'}, signal: controller.signal});
            if (!r.ok) fail('Abruf fehlgeschlagen (HTTP ' + r.status + '). Bitte erneut anmelden.');
            html = await r.text();
          } finally { clearTimeout(timeout); }
          const items = parse(html);
          if (items.length === 0 && !html.includes('myChart-droitsActions')) fail('Keine Bestandsübersicht erkannt. Bitte erneut anmelden.');
          return JSON.stringify({version: 1, asOf: new Date().toISOString().slice(0, 10), depot: {items}});
        }
      };
    })();
    """#

    static let probe = #"""
    location.origin === 'https://sharinbox.sgmarkets.com' && !!window.__gcSharinbox?.ready()
    """#
}

struct SharinboxWebSheet: View {
    @Environment(\.reportRedaction) private var redaction
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let connection: BankConnection
    @State private var browser = PortalBrowser(url: URL(string: "https://sharinbox.sgmarkets.com/home")!,
        domains: PortalDomains(kind: .sharinbox), captureTraffic: false, userScript: SharinboxScripts.hook)
    @State private var uiDelegate = AmazonUIDelegate()
    @State private var ready = false
    @State private var running = false
    @State private var notice: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(redaction.masking(connection.displayName)) – Sharinbox").appFont(.headline)
                    if running { Text("Bestand abrufen …").appFont(.caption) }
                    else if let notice { Text(notice).appFont(.caption).foregroundStyle(Theme.warning) }
                    else { Text(ready ? String(localized: "Angemeldet – der Bestand kann abgerufen werden.") : String(localized: "Melden Sie sich bei Sharinbox an (E-Mail, Passwort und Authenticator-App).")).appFont(.caption) }
                }
                Spacer()
                if running || browser.loading { ProgressView().controlSize(.small) }
            }.padding(14)
            Divider()
            PortalWebView(browser: browser).macFrame(minWidth: 760, minHeight: 620)
            Divider()
            HStack {
                Button("Schließen", role: .cancel) { task?.cancel(); close() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Bestand abrufen") { start() }.buttonStyle(.borderedProminent).disabled(!ready || running)
            }.padding(12)
        }
        .webPageDialogs(uiDelegate)
        .task {
            browser.webView.uiDelegate = uiDelegate
            while !Task.isCancelled {
                let authenticated = (try? await browser.webView.evaluateJavaScript(SharinboxScripts.probe)) as? Bool ?? false
                let ok = browser.onPortal && authenticated
                if ready != ok { ready = ok }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .onDisappear { task?.cancel(); browser.teardown() }
        .interactiveDismissDisabled(running)
    }

    private func run(_ script: String) async throws -> String {
        try Task.checkCancellation()
        let guardScript = "if (location.origin !== 'https://sharinbox.sgmarkets.com' || !window.__gcSharinbox) throw new Error('Sharinbox: Bitte erneut anmelden.');\n"
        let result: Any?
        do {
            result = try await browser.webView.callAsyncJavaScript(guardScript + script, arguments: [:], in: nil, contentWorld: .page)
        } catch {
            try Task.checkCancellation()
            // The page script's own message; WebKit's generic text says nothing. Text that
            // carries a URL is never shown (it can hold tokens).
            let message = ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String) ?? ""
            if !message.isEmpty, message.count <= 160, !message.contains("://") {
                throw SharinboxError.portal(message)
            }
            throw SharinboxError.unreadable
        }
        try Task.checkCancellation()
        guard let string = result as? String else { throw SharinboxError.unreadable }
        return string
    }

    private func start() {
        running = true
        notice = nil
        task = Task {
            guard let pin = model.pinVault() else { running = false; return }
            let connectionId = connection.id
            do {
                let snapshot = try await run("return await window.__gcSharinbox.collect();")
                let summary = try await pin.run { try $0.importSharinboxSnapshot(connectionId: connectionId, snapshotJson: snapshot) }
                model.toast = String(localized: "Sharinbox: \(summary.accountsUpdated) Depot aktualisiert.")
                close()
            } catch is CancellationError {
            } catch { notice = describe(error) }
            await pin.checkpoint()
            running = false
            model.reloadAll()
            // accounts another login already delivers wait for a choice (#346)
            model.checkPendingAccountSelection()
        }
    }

    private func close() { model.webLoginConnection = nil; dismiss() }
}

private enum SharinboxError: LocalizedError {
    case unreadable
    case portal(String)
    var errorDescription: String? {
        switch self {
        case .unreadable: return String(localized: "Sharinbox: Die Portalantwort konnte nicht gelesen werden.")
        case .portal(let message): return message
        }
    }
}
