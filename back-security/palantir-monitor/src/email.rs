use crate::config::CloudConfig;
use crate::report::Report;
use anyhow::{Context, Result};
use lettre::message::{header, Attachment, MultiPart, SinglePart};
use lettre::transport::smtp::authentication::Credentials;
use lettre::{Message, SmtpTransport, Transport};
use std::fs;

pub async fn send_report(report: &Report, config: &CloudConfig) -> Result<()> {
    tracing::info!("Attempting to send email report...");

    // Try SMTPS first if password is configured
    if let Some(password) = &config.smtp_pass {
        match send_via_smtps(report, config, password).await {
            Ok(_) => {
                tracing::info!("✅ Email sent successfully via SMTPS");
                return Ok(());
            }
            Err(e) => {
                tracing::warn!("SMTPS delivery failed: {}", e);
            }
        }
    }

    // Fallback to HTTP proxy
    match send_via_http_proxy(report, config).await {
        Ok(_) => {
            tracing::info!("✅ Email sent successfully via HTTP proxy");
            return Ok(());
        }
        Err(e) => {
            tracing::warn!("HTTP proxy delivery failed: {}", e);
        }
    }

    // Final fallback to ntfy
    send_via_ntfy(report).await?;
    tracing::info!("✅ Notification sent via ntfy");

    Ok(())
}

async fn send_via_smtps(
    report: &Report,
    config: &CloudConfig,
    password: &str,
) -> Result<()> {
    // Read report files
    let md_content = report.generate_markdown();
    let json_content = report.generate_json()?;
    let html_content = report.generate_html();

    // Build email with attachments
    let email = Message::builder()
        .from(config.from_email.parse()?)
        .to(config.to_email.parse()?)
        .subject(&report.subject_line()) // NO EMOJI
        .multipart(
            MultiPart::mixed()
                .singlepart(SinglePart::html(html_content))
                .singlepart(
                    Attachment::new("health-report.md".to_string())
                        .body(md_content, "text/markdown".parse()?),
                )
                .singlepart(
                    Attachment::new("health-report.json".to_string())
                        .body(json_content, "application/json".parse()?),
                ),
        )?;

    // Connect to SMTP server
    let creds = Credentials::new(config.smtp_user.clone(), password.to_string());

    let mailer = SmtpTransport::relay("130.110.251.193")?
        .port(465) // SMTPS
        .credentials(creds)
        .build();

    mailer.send(&email)?;

    Ok(())
}

async fn send_via_http_proxy(report: &Report, config: &CloudConfig) -> Result<()> {
    use base64::{engine::general_purpose, Engine as _};

    let md_content = report.generate_markdown();
    let json_content = report.generate_json()?;
    let html_content = report.generate_html();

    // Build multipart MIME email
    let boundary = format!("----=_NextPart_{}", chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0));

    let mut email_body = String::new();

    // Headers
    email_body.push_str(&format!("From: {}\r\n", config.from_email));
    email_body.push_str(&format!("To: {}\r\n", config.to_email));
    email_body.push_str(&format!("Subject: {}\r\n", report.subject_line())); // NO EMOJI
    email_body.push_str(&format!("Date: {}\r\n", chrono::Utc::now().to_rfc2822()));
    email_body.push_str("MIME-Version: 1.0\r\n");
    email_body.push_str(&format!("Content-Type: multipart/mixed; boundary=\"{}\"\r\n", boundary));
    email_body.push_str(&format!("X-Report-ID: {}\r\n", report.metadata.report_id));
    email_body.push_str("X-Palantir-Monitor: true\r\n");
    email_body.push_str("\r\n");

    // HTML body part
    email_body.push_str(&format!("--{}\r\n", boundary));
    email_body.push_str("Content-Type: text/html; charset=utf-8\r\n");
    email_body.push_str("Content-Transfer-Encoding: 7bit\r\n");
    email_body.push_str("\r\n");
    email_body.push_str(&html_content);
    email_body.push_str("\r\n");

    // Markdown attachment
    email_body.push_str(&format!("--{}\r\n", boundary));
    email_body.push_str("Content-Type: text/markdown; name=\"health-report.md\"\r\n");
    email_body.push_str("Content-Transfer-Encoding: base64\r\n");
    email_body.push_str("Content-Disposition: attachment; filename=\"health-report.md\"\r\n");
    email_body.push_str("\r\n");
    email_body.push_str(&general_purpose::STANDARD.encode(md_content.as_bytes()));
    email_body.push_str("\r\n");

    // JSON attachment
    email_body.push_str(&format!("--{}\r\n", boundary));
    email_body.push_str("Content-Type: application/json; name=\"health-report.json\"\r\n");
    email_body.push_str("Content-Transfer-Encoding: base64\r\n");
    email_body.push_str("Content-Disposition: attachment; filename=\"health-report.json\"\r\n");
    email_body.push_str("\r\n");
    email_body.push_str(&general_purpose::STANDARD.encode(json_content.as_bytes()));
    email_body.push_str("\r\n");

    // Close multipart
    email_body.push_str(&format!("--{}--\r\n", boundary));

    // Send via HTTP POST
    let client = reqwest::Client::new();
    let response = client
        .post(&config.smtp_proxy_url)
        .header("Content-Type", "text/plain")
        .header("X-API-Key", &config.smtp_proxy_key)
        .body(email_body)
        .timeout(std::time::Duration::from_secs(30))
        .send()
        .await?;

    if response.status().is_success() {
        Ok(())
    } else {
        anyhow::bail!("HTTP proxy returned status: {}", response.status())
    }
}

async fn send_via_ntfy(report: &Report) -> Result<()> {
    let md_preview = report
        .generate_markdown()
        .lines()
        .take(50)
        .collect::<Vec<_>>()
        .join("\n");

    let client = reqwest::Client::new();
    client
        .post("https://rss.diegonmarcos.com/palantir")
        .header("Title", &report.subject_line())
        .header("Priority", "high")
        .header("Tags", "cloud,monitor")
        .body(md_preview)
        .timeout(std::time::Duration::from_secs(10))
        .send()
        .await?;

    Ok(())
}
