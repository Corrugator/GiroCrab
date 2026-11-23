//! `SyncSession` with a connector that asks during `fetch` (#1730, ADR 0002):
//! the question reaches the front end as a normal challenge step, the answer
//! goes back into the running fetch.

use std::sync::{Arc, Mutex};

use async_trait::async_trait;

use super::*;
use crate::vault::Vault;

/// What the scripted connector saw.
#[derive(Default)]
struct Seen {
    answers: Vec<String>,
    had_prompt: Option<bool>,
    finished: bool,
}

/// Logs in without a challenge, then asks `questions` times during the fetch
/// and delivers one account.
struct Asking {
    questions: usize,
    seen: Arc<Mutex<Seen>>,
}

fn code_challenge() -> Challenge {
    Challenge {
        kind: ChallengeKind::Code,
        title: "TAN".into(),
        message: "Bitte TAN eingeben".into(),
        method_name: String::new(),
        redirect_url: None,
        image: None,
        expires_in_seconds: None,
        poll_interval_seconds: 0,
    }
}

#[async_trait]
impl BankConnector for Asking {
    async fn begin(&mut self, _ctx: &ConnectContext) -> CoreResult<Phase> {
        Ok(Phase::Ready)
    }
    async fn respond(&mut self, _: &ConnectContext, _: ChallengeResponse) -> CoreResult<Phase> {
        Err(CoreError::protocol("no login challenge"))
    }
    async fn fetch(&mut self, ctx: &ConnectContext) -> CoreResult<FetchResult> {
        self.seen.lock().unwrap().had_prompt = Some(ctx.prompt.is_some());
        if let Some(prompt) = &ctx.prompt {
            for _ in 0..self.questions {
                let answer = match prompt.ask(Phase::Challenge(code_challenge())).await? {
                    PromptAnswer::Code(c) => format!("code {}", c.expose()),
                    PromptAnswer::Poll => "poll".into(),
                    PromptAnswer::Skip => "skip".into(),
                };
                self.seen.lock().unwrap().answers.push(answer);
            }
        }
        Ok(FetchResult {
            accounts: vec![RemoteAccount {
                external_ref: "DE89370400440532013000".into(),
                name: "Tagesgeld".into(),
                owner: String::new(),
                iban: "DE89370400440532013000".into(),
                account_number: String::new(),
                currency: "EUR".into(),
                kind: AccountKind::Savings,
                balance_cents: 100,
                balance_date: "2026-11-23".into(),
            }],
            ..Default::default()
        })
    }
    async fn finish(&mut self, _ctx: &ConnectContext) {
        self.seen.lock().unwrap().finished = true;
    }
}

fn session(questions: usize) -> (SyncSession, Arc<Vault>, Arc<Mutex<Seen>>) {
    let dir = crate::test_support::thread_temp_path("gc-fetch-prompt");
    std::fs::create_dir_all(&dir).unwrap();
    let vault = Vault::open(dir.join("v.db").to_string_lossy().into(), vec![7u8; 32]).unwrap();
    let connection_id = vault
        .add_bank_connection(ConnectorKind::FinTsGeneric, String::new(), "login".into())
        .unwrap();
    let seen = Arc::new(Mutex::new(Seen::default()));
    let ctx = ConnectContext {
        connection_id,
        since: "2026-01-01".into(),
        ..Default::default()
    };
    let connector = Asking {
        questions,
        seen: seen.clone(),
    };
    let s = SyncSession::new(
        vault.clone(),
        ConnectorKind::FinTsGeneric,
        Box::new(connector),
        ctx,
    );
    (s, vault, seen)
}

fn stored_accounts(vault: &Vault) -> usize {
    vault.list_accounts().unwrap().len()
}

#[tokio::test]
async fn questions_during_the_fetch_come_as_challenges_and_the_answers_go_back() {
    let (s, vault, seen) = session(2);
    let step = s.start().await.unwrap();
    assert!(matches!(step, SyncStep::NeedsChallenge { .. }));
    // nothing is stored while the fetch waits
    assert_eq!(stored_accounts(&vault), 0);
    let step = s.submit_code("123456".into()).await.unwrap();
    assert!(matches!(step, SyncStep::NeedsChallenge { .. }));
    let step = s.skip().await.unwrap();
    assert!(matches!(step, SyncStep::Finished { .. }), "{step:?}");
    {
        let seen = seen.lock().unwrap();
        assert_eq!(seen.answers, ["code 123456", "skip"]);
        assert!(seen.finished);
    }
    assert_eq!(stored_accounts(&vault), 1);
    assert!(matches!(s.poll().await, Err(CoreError::SessionClosed)));
}

#[tokio::test]
async fn cancelling_during_the_fetch_stores_nothing_and_closes_the_dialog() {
    let (s, vault, seen) = session(1);
    assert!(matches!(
        s.start().await.unwrap(),
        SyncStep::NeedsChallenge { .. }
    ));
    s.cancel().await;
    {
        let seen = seen.lock().unwrap();
        assert!(seen.answers.is_empty());
        assert!(seen.finished);
    }
    assert_eq!(stored_accounts(&vault), 0);
    assert!(matches!(
        s.submit_code("1".into()).await,
        Err(CoreError::SessionClosed)
    ));
}

#[tokio::test]
async fn an_automatic_sync_gets_no_prompt() {
    let (s, vault, seen) = session(1);
    s.set_quiet();
    assert!(matches!(
        s.start().await.unwrap(),
        SyncStep::Finished { .. }
    ));
    assert_eq!(seen.lock().unwrap().had_prompt, Some(false));
    assert_eq!(stored_accounts(&vault), 1);
}

#[tokio::test]
async fn a_login_challenge_cannot_be_skipped() {
    let (s, _vault, seen) = session(0);
    assert!(matches!(
        s.skip().await,
        Err(CoreError::InvalidInput { .. })
    ));
    // the session is still there for the login
    assert!(matches!(
        s.start().await.unwrap(),
        SyncStep::Finished { .. }
    ));
    assert_eq!(seen.lock().unwrap().had_prompt, Some(true));
}
