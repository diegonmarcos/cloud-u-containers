require ["fileinto", "mailbox"];

# Route health-check emails to Health folder (skip inbox)
if header :contains "Subject" "[health-check]" {
  fileinto :create "Health";
  stop;
}
if header :contains "Subject" "[health-outbound]" {
  fileinto :create "Health";
  stop;
}
