//! Axis planning: which folder of EACH classification axis a message is copied into.
//!
//! The F0 sender axis is first-match-wins with the routing default as its fallback (unchanged). The G0 _ AUTH
//! axis is independent: first match among the `auth` rules, whose last rule (Gc No Auth) is the complement
//! of the other two, so it always lands somewhere. Pure functions, so they are testable without a database.

use crate::email::{matches, Email};
use crate::rules::{Rules, AXIS_AUTH, AXIS_SENDER};

/// The folder a message goes to on [`axis`]: the first rule of that axis that matches, or the sender
/// axis's routing default, or nothing (an axis with no fallback and no match files nowhere).
pub fn folder_for<'a>(rules: &'a Rules, email: &Email, axis: &str) -> Option<&'a str> {
    rules
        .rules
        .iter()
        .filter(|r| r.axis_name() == axis)
        .find(|r| matches(email, &r.when))
        .map(|r| r.folder.as_str())
        .or_else(|| (axis == AXIS_SENDER).then_some(rules.routing_default.as_str()))
}

/// The axes the rules declare, sender first.
pub fn declared_axes(rules: &Rules) -> Vec<&'static str> {
    let mut axes = vec![AXIS_SENDER];
    if rules.rules.iter().any(|r| r.axis_name() == AXIS_AUTH) {
        axes.push(AXIS_AUTH);
    }
    axes
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn rules() -> Rules {
        serde_json::from_value(json!({
            "account": "a@b",
            "routing_default": "Fz",
            "rules": [
                {"id": "Fa", "folder": "Fa", "when": {"type": "from_domain", "values": ["github.com"]}},
                {"id": "Ga", "folder": "Ga", "axis": "auth",
                 "when": {"type": "header_contains", "header": "Subject", "values": ["verification code"]}},
                {"id": "Gb", "folder": "Gb", "axis": "auth", "when": {"all_of": [
                    {"type": "header_contains", "header": "Subject", "values": ["reset your password"]},
                    {"not": {"type": "header_contains", "header": "Subject", "values": ["verification code"]}}]}},
                {"id": "Gc", "folder": "Gc", "axis": "auth", "when": {"not": {"any_of": [
                    {"type": "header_contains", "header": "Subject", "values": ["verification code"]},
                    {"type": "header_contains", "header": "Subject", "values": ["reset your password"]}]}}}
            ]
        }))
        .unwrap()
    }

    fn email(from: &str, subject: &str) -> Email {
        Email::from_cached_header_json(json!({"From": [from], "Subject": [subject]}).to_string().as_bytes()).unwrap()
    }

    #[test]
    fn a_message_gets_one_folder_per_axis() {
        let r = rules();
        let e = email("a@github.com", "Your verification code is 123456");
        assert_eq!(folder_for(&r, &e, AXIS_SENDER), Some("Fa"));
        assert_eq!(folder_for(&r, &e, AXIS_AUTH), Some("Ga"));
    }

    #[test]
    fn the_sender_axis_falls_back_to_the_routing_default_and_auth_to_gc() {
        let r = rules();
        let e = email("x@news.example", "Ten gardening tips");
        assert_eq!(folder_for(&r, &e, AXIS_SENDER), Some("Fz"));
        assert_eq!(folder_for(&r, &e, AXIS_AUTH), Some("Gc"));
    }

    #[test]
    fn a_link_phrase_without_a_code_is_gb_and_with_a_code_is_ga() {
        let r = rules();
        assert_eq!(folder_for(&r, &email("a@b.c", "Reset your password"), AXIS_AUTH), Some("Gb"));
        assert_eq!(
            folder_for(&r, &email("a@b.c", "Verification code - reset your password"), AXIS_AUTH),
            Some("Ga")
        );
    }

    #[test]
    fn rules_without_an_axis_are_sender_rules_and_auth_rules_never_claim_the_sender_axis() {
        let r = rules();
        assert_eq!(declared_axes(&r), vec![AXIS_SENDER, AXIS_AUTH]);
        // a verification-code subject from an unknown sender is still routed by SENDER rules only
        let e = email("x@news.example", "Your verification code");
        assert_eq!(folder_for(&r, &e, AXIS_SENDER), Some("Fz"));
    }

    #[test]
    fn a_ruleset_without_the_auth_axis_declares_only_sender() {
        let r: Rules = serde_json::from_value(json!({
            "account": "a@b", "routing_default": "Fz",
            "rules": [{"id": "Fa", "folder": "Fa", "when": {"type": "from_domain", "values": ["github.com"]}}]
        }))
        .unwrap();
        assert_eq!(declared_axes(&r), vec![AXIS_SENDER]);
    }
}
