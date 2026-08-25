//! Typed schema for `/data/mail-rules.json` (the Maddy subset rendered by
//! `_shared/lib/mail-rules.nix::toMaddyJson` — same source of truth as
//! Stalwart's Sieve, filtered to `filters.views` where `axis == "sender"`).
//!
//! Only the atoms the F0 sender axis actually uses today are implemented:
//! `from_domain`, `from_domain_suffix`, `header_contains`, plus the
//! any_of/all_of/not combinators. An unrecognised `type` is a startup
//! error, not a silent no-match — same rationale as the Stalwart crate's
//! rules.rs: a typo'd predicate should crash loud, not quietly file
//! nothing into a folder forever.

use serde::Deserialize;

#[derive(Debug, Deserialize)]
pub struct Rules {
    pub account: String,
    /// Already the literal fallback mailbox NAME (e.g. "Fz    📭 Others"),
    /// not a key needing a `folders` lookup — toMaddyJson resolves that.
    pub routing_default: String,
    pub rules: Vec<Route>,
}

#[derive(Debug, Deserialize)]
pub struct Route {
    #[allow(dead_code)] // not matched on; present for log/debug output
    pub id: String,
    pub folder: String,
    pub when: PredicateNode,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Predicate {
    FromDomain {
        #[serde(default)]
        values: Vec<String>,
    },
    FromDomainSuffix {
        #[serde(default)]
        values: Vec<String>,
    },
    HeaderContains {
        header: String,
        #[serde(default)]
        values: Vec<String>,
    },
}

/// A predicate tree: `Atom` is a leaf [`Predicate`]; `AnyOf`/`AllOf`/`Not`
/// combine child trees. Mirrors user-comm_tools-stalwart/src/crate/src/
/// rules.rs's PredicateNode exactly (same JSON shape, same reason for a
/// hand-rolled Deserialize: combinators have no `type` tag in the JSON).
#[derive(Debug)]
pub enum PredicateNode {
    AnyOf(Vec<PredicateNode>),
    AllOf(Vec<PredicateNode>),
    Not(Box<PredicateNode>),
    Atom(Predicate),
}

impl<'de> Deserialize<'de> for PredicateNode {
    fn deserialize<D>(d: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = serde_json::Value::deserialize(d)?;
        Self::from_value(value).map_err(serde::de::Error::custom)
    }
}

impl PredicateNode {
    fn from_value(value: serde_json::Value) -> Result<Self, String> {
        let obj = value
            .as_object()
            .ok_or_else(|| format!("predicate must be a JSON object, got {value}"))?;
        if let Some(v) = obj.get("any_of") {
            let items = v.as_array().ok_or("any_of must be an array")?;
            return Ok(PredicateNode::AnyOf(
                items.iter().cloned().map(Self::from_value).collect::<Result<_, _>>()?,
            ));
        }
        if let Some(v) = obj.get("all_of") {
            let items = v.as_array().ok_or("all_of must be an array")?;
            return Ok(PredicateNode::AllOf(
                items.iter().cloned().map(Self::from_value).collect::<Result<_, _>>()?,
            ));
        }
        if let Some(v) = obj.get("not") {
            return Ok(PredicateNode::Not(Box::new(Self::from_value(v.clone())?)));
        }
        let atom: Predicate = serde_json::from_value(value).map_err(|e| e.to_string())?;
        Ok(PredicateNode::Atom(atom))
    }
}

impl Rules {
    pub fn load(path: &str) -> anyhow::Result<Self> {
        let raw = std::fs::read_to_string(path)
            .map_err(|e| anyhow::anyhow!("cannot read rules at {path}: {e}"))?;
        serde_json::from_str(&raw)
            .map_err(|e| anyhow::anyhow!("cannot parse rules at {path}: {e}"))
    }
}
