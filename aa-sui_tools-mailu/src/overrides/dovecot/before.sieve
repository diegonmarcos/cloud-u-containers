require ["fileinto", "mailbox"];

# Health check emails → Health folder (skip inbox)
if header :contains "Subject" "[health-check]" {
  fileinto :create "Health";
  stop;
}
if header :contains "Subject" "[health-outbound]" {
  fileinto :create "Health";
  stop;
}

# GitHub notifications → GitHub folder (skip inbox)
if header :contains "From" "notifications@github.com" {
  fileinto :create "GitHub";
  stop;
}
if header :contains "From" "noreply@github.com" {
  fileinto :create "GitHub";
  stop;
}
