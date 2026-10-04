//! Parses `msgs.cachedHeader` (a JSON blob go-imap-sql caches at delivery
//! time — `{"From": ["..."], "Subject": ["..."], ...}`, Go's canonical
//! MIME header casing, one entry per occurrence) and matches it against a
//! [`crate::rules::PredicateNode`] tree.
//!
//! The bash version this replaces round-tripped cachedHeader through a
//! fake RFC822 text blob just so a jq/awk header parser could read it back
//! out. Unnecessary here — cachedHeader already IS a header multimap, so
//! this parses it directly.

use crate::rules::{Predicate, PredicateNode};
use std::collections::HashMap;

pub struct Email {
    headers: HashMap<String, Vec<String>>,
}

impl Email {
    pub fn from_cached_header_json(bytes: &[u8]) -> anyhow::Result<Self> {
        let headers: HashMap<String, Vec<String>> = serde_json::from_slice(bytes)
            .map_err(|e| anyhow::anyhow!("cachedHeader is not the expected JSON header map: {e}"))?;
        Ok(Email { headers })
    }

    /// Case-insensitive header lookup (cachedHeader keys are Go's
    /// canonical MIME casing, e.g. "X-Spam-Status", but match defensively).
    fn header_joined(&self, name: &str) -> String {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.join(", "))
            .unwrap_or_default()
    }

    fn header_exists(&self, name: &str) -> bool {
        !self.header_joined(name).trim().is_empty()
    }

    /// Domain of the first address in the From header. Handles both
    /// `Name <addr@domain>` and a bare `addr@domain`.
    pub fn from_domain(&self) -> String {
        let from = self.header_joined("From");
        let addr = if let (Some(l), Some(r)) = (from.find('<'), from.find('>')) {
            &from[l + 1..r]
        } else {
            from.trim()
        };
        addr.rsplit('@').next().unwrap_or("").trim().to_ascii_lowercase()
    }
}

pub fn matches(email: &Email, node: &PredicateNode) -> bool {
    match node {
        PredicateNode::AnyOf(children) => children.iter().any(|c| matches(email, c)),
        PredicateNode::AllOf(children) => children.iter().all(|c| matches(email, c)),
        PredicateNode::Not(child) => !matches(email, child),
        PredicateNode::Atom(atom) => atom_matches(email, atom),
    }
}

fn atom_matches(email: &Email, predicate: &Predicate) -> bool {
    match predicate {
        Predicate::FromDomain { values } => {
            let d = email.from_domain();
            values.iter().any(|v| d == v.to_ascii_lowercase())
        }
        Predicate::FromDomainSuffix { values } => {
            let d = email.from_domain();
            values.iter().any(|v| d.ends_with(v.to_ascii_lowercase().as_str()))
        }
        Predicate::HeaderContains { header, values } => {
            if !email.header_exists(header) {
                return false;
            }
            let hl = email.header_joined(header).to_ascii_lowercase();
            values.iter().any(|v| hl.contains(&v.to_ascii_lowercase()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rules::PredicateNode;
    use serde_json::json;

    fn email(headers: serde_json::Value) -> Email {
        Email::from_cached_header_json(headers.to_string().as_bytes()).unwrap()
    }

    fn pred(v: serde_json::Value) -> PredicateNode {
        serde_json::from_value(v).unwrap()
    }

    #[test]
    fn from_domain_handles_display_name_and_bare_address() {
        let with_name = email(json!({"From": ["GitHub <notifications@github.com>"]}));
        let bare = email(json!({"From": ["notifications@github.com"]}));
        assert_eq!(with_name.from_domain(), "github.com");
        assert_eq!(bare.from_domain(), "github.com");
    }

    #[test]
    fn from_domain_atom() {
        let em = email(json!({"From": ["a@GitHub.com"]}));
        let p = pred(json!({"type": "from_domain", "values": ["github.com"]}));
        assert!(matches(&em, &p));
    }

    #[test]
    fn from_domain_suffix_atom() {
        let em = email(json!({"From": ["a@notify.github.com"]}));
        let p = pred(json!({"type": "from_domain_suffix", "values": [".github.com"]}));
        assert!(matches(&em, &p));
        let root = email(json!({"From": ["a@github.com"]}));
        assert!(!matches(&root, &p), "root domain must not match a subdomain-only suffix");
    }

    #[test]
    fn header_contains_atom_case_insensitive_header_name() {
        let em = email(json!({"x-spam-status": ["Yes, score=9.1"]}));
        let p = pred(json!({"type": "header_contains", "header": "X-Spam-Status", "values": ["Yes"]}));
        assert!(matches(&em, &p));
    }

    #[test]
    fn combinators() {
        let em = email(json!({"From": ["a@b.com"]}));
        let any = pred(json!({"any_of": [
            {"type": "from_domain", "values": ["x.com"]},
            {"type": "from_domain", "values": ["b.com"]}
        ]}));
        let not_b = pred(json!({"not": {"type": "from_domain", "values": ["b.com"]}}));
        assert!(matches(&em, &any));
        assert!(!matches(&em, &not_b));
    }
}
