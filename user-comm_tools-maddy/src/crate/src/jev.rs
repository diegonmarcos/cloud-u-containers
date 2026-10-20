//! Jev advice for the sender axis' FALLBACK rows (#882 S1), in the live sorter.
//!
//! Jev (TypeSafe's decision model, reached through the fleet's jev-sidecar on the WireGuard mesh) may pick a
//! sender folder for a message the rules left in the routing default. It only SUGGESTS: every doubt (sidecar
//! down, no OPENROUTER_API_KEY, the use's evidence gate still closed, not confident, a folder the rules do
//! not declare) returns no pick, and [`refine`] then hands back exactly the folder [`crate::axes::folder_for`]
//! chose, so the plan is identical to a build without this module. Messages the rules DID match are never
//! sent anywhere. Copy-only like every sorter write; the INBOX original is untouched.
//!
//! OUTCOMES: each asked message is remembered ([`Pending`]); a few days later the folder the user actually
//! left it in (the one declared sender folder that holds a copy of its body) is posted to the sidecar's
//! /outcome, so the use's precision, and the gates that wait on it, are measured with no manual labelling.

use crate::email::Email;
use crate::rules::{Rules, AXIS_SENDER};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

/// What the sidecar said. `pick` only when it was confident and the folder is one we offered; `call` is the
/// sidecar's decision id even when it held its opinion back (observe-only), for the outcome.
#[derive(Debug, Default, PartialEq, Clone)]
pub struct Advice {
    pub pick: Option<String>,
    pub call: Option<String>,
    /// The sidecar could not be reached at all: stop asking for the rest of this run.
    pub unreachable: bool,
}

pub trait Advisor {
    fn advise(&self, email: &Email, candidates: &[String]) -> Advice;
}

/// The declared sender folders other than the fallback, in rule order, unique.
pub fn candidates(rules: &Rules) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for r in rules.rules.iter().filter(|r| r.axis_name() == AXIS_SENDER) {
        if r.folder != rules.routing_default && !out.contains(&r.folder) {
            out.push(r.folder.clone());
        }
    }
    out
}

/// The folder a message is copied to on the sender axis: `folder` (the rules' answer) unless the rules left it
/// in the fallback AND the advisor confidently picks a declared folder. Returns the folder and the call id of
/// the decision, when one was asked. `asked` counts calls this run against `cap`.
pub fn refine(
    rules: &Rules,
    email: &Email,
    folder: &str,
    advisor: Option<&dyn Advisor>,
    cands: &[String],
    asked: &mut usize,
    cap: usize,
) -> (String, Option<String>) {
    let Some(adv) = advisor else { return (folder.to_string(), None) };
    if folder != rules.routing_default || cands.len() < 2 || *asked >= cap {
        return (folder.to_string(), None);
    }
    *asked += 1;
    let a = adv.advise(email, cands);
    if a.unreachable {
        *asked = cap;
    }
    match a.pick {
        Some(p) if cands.contains(&p) => (p, a.call),
        _ => (folder.to_string(), a.call),
    }
}

/// Parse the sidecar's answer to the `folder` question. Never panics; anything unexpected is no opinion.
pub fn parse_advice(body: &str, cands: &[String]) -> Advice {
    let Ok(v) = serde_json::from_str::<Value>(body) else { return Advice::default() };
    let call = v.get("call").and_then(Value::as_str).map(str::to_string);
    let q = v.get("results").and_then(|r| r.get("folder"));
    let pick = (v.get("ok").and_then(Value::as_bool) == Some(true))
        .then_some(q)
        .flatten()
        .filter(|q| q.get("confident").and_then(Value::as_bool) == Some(true))
        .and_then(|q| q.get("pick").and_then(Value::as_str))
        .filter(|p| cands.iter().any(|c| c == p))
        .map(str::to_string);
    Advice { pick, call, unreachable: false }
}

/// The request for the `mail_fallback_folder` use: headers only (From, Subject, List-Id), never a body.
pub fn request_body(email: &Email, cands: &[String]) -> String {
    let headers: Vec<String> = ["From", "Subject", "List-Id"]
        .iter()
        .map(|h| (h, email.header(h)))
        .filter(|(_, v)| !v.trim().is_empty())
        .map(|(h, v)| format!("{h}: {}", v.chars().take(300).collect::<String>()))
        .collect();
    let criteria: serde_json::Map<String, Value> = cands
        .iter()
        .map(|c| (c.clone(), Value::String(format!("Mail that belongs in the folder {c}"))))
        .collect();
    json!({
        "state": {"headers": headers},
        "questions": {"folder": {
            "type": "choice",
            "instructions": "Which category folder should this message from `headers` be filed in? Pick the closest fit by sender and subject.",
            "criteria": criteria
        }}
    })
    .to_string()
}

/// Minimal HTTP/1.1 POST to the sidecar (plain http on the mesh; no new dependency). None on any failure.
pub fn post(base: &str, path: &str, body: &str, timeout: Duration) -> Option<String> {
    let host = base.strip_prefix("http://")?.trim_end_matches('/');
    let addr = host.to_socket_addrs().ok()?.next()?;
    let mut s = TcpStream::connect_timeout(&addr, timeout).ok()?;
    s.set_read_timeout(Some(timeout)).ok()?;
    s.set_write_timeout(Some(timeout)).ok()?;
    let req = format!(
        "POST {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    s.write_all(req.as_bytes()).ok()?;
    let mut raw = String::new();
    s.read_to_string(&mut raw).ok()?;
    let (head, rest) = raw.split_once("\r\n\r\n")?;
    head.starts_with("HTTP/1.1 200").then(|| rest.to_string())
}

pub struct Sidecar {
    pub base: String,
    pub timeout: Duration,
}

impl Sidecar {
    pub fn from_env() -> Option<Sidecar> {
        if std::env::var("JEV_SORTER").map(|v| v == "0").unwrap_or(false) {
            return None;
        }
        Some(Sidecar {
            base: std::env::var("JEV_SIDECAR_URL").unwrap_or_else(|_| "http://10.0.0.6:3110".into()),
            timeout: Duration::from_secs(std::env::var("JEV_TIMEOUT_S").ok().and_then(|v| v.parse().ok()).unwrap_or(4)),
        })
    }
}

impl Advisor for Sidecar {
    fn advise(&self, email: &Email, cands: &[String]) -> Advice {
        match post(&self.base, "/decide/mail_fallback_folder", &request_body(email, cands), self.timeout) {
            Some(body) => parse_advice(&body, cands),
            None => Advice { unreachable: true, ..Advice::default() },
        }
    }
}

/// An asked message awaiting its outcome.
#[derive(Debug, Serialize, Deserialize, PartialEq, Clone)]
pub struct Pending {
    pub call: String,
    pub src_msg_id: i64,
    pub at: u64,
}

/// The pending list lives next to the database, like the sorter's other state files.
pub fn pending_path(db_path: &str) -> String {
    format!("{db_path}.jev-pending.json")
}

pub fn load_pending(path: &str) -> Vec<Pending> {
    std::fs::read_to_string(path).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
}

pub fn save_pending(path: &str, list: &[Pending]) {
    if let Ok(s) = serde_json::to_string(list) {
        let _ = std::fs::write(path, s);
    }
}

/// Outcome of a pending entry that is old enough: `Some(label)` when exactly one declared sender folder holds
/// a copy of the message (where the user left it), None when there is nothing to learn (it never left the
/// fallback, was deleted, or sits in several folders). Pure, so it can be tested.
pub fn observed_label(holding: &[String], cands: &[String]) -> Option<String> {
    let mut mine = holding.iter().filter(|h| cands.contains(h));
    let first = mine.next()?;
    mine.next().is_none().then(|| first.clone())
}

/// POST the outcome. Best effort.
pub fn send_outcome(base: &str, call: &str, label: &str, timeout: Duration) {
    let body = json!({"call": call, "label": {"folder": label}}).to_string();
    let _ = post(base, "/outcome/mail_fallback_folder", &body, timeout);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rules() -> Rules {
        serde_json::from_value(json!({
            "account": "a@b",
            "routing_default": "Fz",
            "rules": [
                {"id": "Fa", "folder": "Fa", "when": {"type": "from_domain", "values": ["github.com"]}},
                {"id": "Fb", "folder": "Fb", "when": {"type": "from_domain", "values": ["shop.example"]}},
                {"id": "Ga", "folder": "Ga", "axis": "auth", "when": {"type": "header_contains", "header": "Subject", "values": ["code"]}}
            ]
        }))
        .unwrap()
    }

    fn email(from: &str, subject: &str) -> Email {
        Email::from_cached_header_json(json!({"From": [from], "Subject": [subject]}).to_string().as_bytes()).unwrap()
    }

    struct Fixed(Advice, std::cell::Cell<usize>);
    impl Advisor for Fixed {
        fn advise(&self, _: &Email, _: &[String]) -> Advice {
            self.1.set(self.1.get() + 1);
            self.0.clone()
        }
    }
    fn fixed(pick: Option<&str>, call: Option<&str>, unreachable: bool) -> Fixed {
        Fixed(Advice { pick: pick.map(Into::into), call: call.map(Into::into), unreachable }, Default::default())
    }

    #[test]
    fn candidates_are_the_declared_sender_folders_without_the_fallback_or_auth() {
        assert_eq!(candidates(&rules()), vec!["Fa".to_string(), "Fb".to_string()]);
    }

    #[test]
    fn no_opinion_is_the_rules_answer_for_every_kind_of_silence() {
        let r = rules();
        let c = candidates(&r);
        let e = email("x@unlisted.org", "hello");
        let rules_answer = crate::axes::folder_for(&r, &e, AXIS_SENDER).unwrap();
        assert_eq!(rules_answer, "Fz");
        let cases: Vec<Option<Fixed>> = vec![
            None, // no advisor at all (JEV_SORTER=0)
            Some(fixed(None, None, false)),                  // gate closed / no_key / garbage
            Some(fixed(None, Some("c1"), false)),            // held by the gate: a call id but no pick
            Some(fixed(None, None, true)),                   // sidecar unreachable
            Some(fixed(Some("Elsewhere"), Some("c2"), false)), // a folder the rules do not declare
        ];
        for adv in &cases {
            let mut asked = 0;
            let (f, _) = refine(&r, &e, rules_answer, adv.as_ref().map(|a| a as &dyn Advisor), &c, &mut asked, 20);
            assert_eq!(f, rules_answer, "no opinion must keep the rules' folder");
        }
    }

    #[test]
    fn a_matched_message_is_never_sent_anywhere() {
        let r = rules();
        let c = candidates(&r);
        let e = email("a@github.com", "PR");
        let adv = fixed(Some("Fb"), Some("c"), false);
        let mut asked = 0;
        let (f, call) = refine(&r, &e, "Fa", Some(&adv), &c, &mut asked, 20);
        assert_eq!((f.as_str(), call, adv.1.get(), asked), ("Fa", None, 0, 0));
    }

    #[test]
    fn a_confident_declared_pick_refiles_a_fallback_row_and_reports_its_call() {
        let r = rules();
        let c = candidates(&r);
        let e = email("x@unlisted.org", "your order");
        let adv = fixed(Some("Fb"), Some("c3"), false);
        let mut asked = 0;
        assert_eq!(refine(&r, &e, "Fz", Some(&adv), &c, &mut asked, 20), ("Fb".to_string(), Some("c3".to_string())));
        assert_eq!(asked, 1);
    }

    #[test]
    fn the_per_run_cap_and_an_unreachable_sidecar_stop_the_asking() {
        let r = rules();
        let c = candidates(&r);
        let e = email("x@unlisted.org", "s");
        let adv = fixed(None, None, false);
        let mut asked = 0;
        for _ in 0..5 {
            refine(&r, &e, "Fz", Some(&adv), &c, &mut asked, 2);
        }
        assert_eq!(adv.1.get(), 2, "cap");
        let down = fixed(None, None, true);
        let mut asked = 0;
        for _ in 0..5 {
            refine(&r, &e, "Fz", Some(&down), &c, &mut asked, 20);
        }
        assert_eq!(down.1.get(), 1, "one failed call ends the asking for the run");
    }

    #[test]
    fn parse_advice_only_trusts_a_confident_offered_pick() {
        let c = vec!["Fa".to_string(), "Fb".to_string()];
        let ok = |pick: &str, conf: bool| {
            json!({"ok": true, "call": "k", "results": {"folder": {"type": "choice", "pick": pick, "p": 0.9, "confident": conf}}}).to_string()
        };
        assert_eq!(parse_advice(&ok("Fa", true), &c).pick.as_deref(), Some("Fa"));
        assert_eq!(parse_advice(&ok("Fa", false), &c).pick, None);
        assert_eq!(parse_advice(&ok("Fz", true), &c).pick, None);
        let held = json!({"ok": false, "reason": "gate_closed", "call": "k"}).to_string();
        assert_eq!(parse_advice(&held, &c), Advice { pick: None, call: Some("k".into()), unreachable: false });
        assert_eq!(parse_advice("<html>502</html>", &c), Advice::default());
        assert_eq!(parse_advice(&json!({"ok": false, "reason": "no_key"}).to_string(), &c), Advice::default());
    }

    #[test]
    fn the_request_carries_headers_only() {
        let c = vec!["Fa".to_string(), "Fb".to_string()];
        let body = request_body(&email("Shop <n@shop.example>", "Your order"), &c);
        let v: Value = serde_json::from_str(&body).unwrap();
        assert_eq!(v["state"]["headers"][0], "From: Shop <n@shop.example>");
        assert_eq!(v["questions"]["folder"]["criteria"].as_object().unwrap().len(), 2);
        assert!(!body.contains("body"));
    }

    #[test]
    fn the_observed_label_is_where_the_user_left_the_message() {
        let c = vec!["Fa".to_string(), "Fb".to_string()];
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        assert_eq!(observed_label(&s(&["Fb", "Trash"]), &c), Some("Fb".into()));
        assert_eq!(observed_label(&s(&["Fz"]), &c), None, "still only in the fallback: nothing learned");
        assert_eq!(observed_label(&s(&[]), &c), None);
        assert_eq!(observed_label(&s(&["Fa", "Fb"]), &c), None, "ambiguous");
    }

    #[test]
    fn post_reaches_a_sidecar_and_fails_quietly_without_one() {
        use std::net::TcpListener;
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let h = std::thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            let mut buf = [0u8; 4096];
            let n = s.read(&mut buf).unwrap();
            let req = String::from_utf8_lossy(&buf[..n]).to_string();
            let body = r#"{"ok":false,"reason":"gate_closed","call":"zz"}"#;
            write!(s, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body).unwrap();
            req
        });
        let got = post(&format!("http://127.0.0.1:{port}"), "/decide/x", "{}", Duration::from_secs(2));
        assert_eq!(got.as_deref(), Some(r#"{"ok":false,"reason":"gate_closed","call":"zz"}"#));
        assert!(h.join().unwrap().starts_with("POST /decide/x HTTP/1.1"));
        assert_eq!(post("http://127.0.0.1:9", "/x", "{}", Duration::from_millis(300)), None);
    }
}
