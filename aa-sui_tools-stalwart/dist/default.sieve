require ["fileinto", "imap4flags", "mailbox", "envelope", "mime"];

# ══════════════════════════════════════════════════════════════════
# TAGS — all matching rules fire (additive IMAP keywords)
# Generated from mail-rules.json — DO NOT EDIT
# ══════════════════════════════════════════════════════════════════

# -- B1: Development & Tools --
if address :domain "From" ["github.com"] { addflag "Dev_platform:GitHub"; }
if address :domain "From" ["gitlab.com"] { addflag "Dev_platform:GitLab"; }
if address :domain "From" ["bitbucket.org"] { addflag "Dev_platform:Bitbucket"; }
if address :domain "From" ["42.fr", "intra.42.fr", "42berlin.de", "42heilbronn.de"] { addflag "Dev_context:42"; }
if address :domain "From" ["stackoverflow.com", "stackexchange.com"] { addflag "Dev_platform:StackOverflow"; }
if address :domain "From" ["npmjs.com", "crates.io", "pypi.org"] { addflag "Dev_type:PackageRegistry"; }
if address :domain "From" ["docker.com", "hub.docker.com"] { addflag "Dev_platform:Docker"; }
if address :domain "From" ["vercel.com", "netlify.com", "railway.app"] { addflag "SaaS_Productivity"; }
if address :domain "From" ["jetbrains.com"] { addflag "SaaS_Creative"; }
if address :domain "From" ["udemy.com", "coursera.org", "edx.org"] { addflag "Edu_General"; }
if address :domain "From" ["duolingo.com", "babbel.com"] { addflag "Edu_Languages"; }

# -- B2: Career & Networking --
if address :domain "From" ["linkedin.com"] { addflag "Career_source:LinkedIn"; }
if address :domain "From" ["indeed.com", "indeed.de"] { addflag "Career_source:Indeed"; }
if address :domain "From" ["glassdoor.com", "xing.com", "stepstone.de", "hired.com"] { addflag "Career_JobAlerts"; }
if header :contains "Subject" ["interview", "entrevista", "Vorstellungsgespr"] { addflag "Career_type:Interview_Invite"; }
if header :contains "Subject" ["application", "candidatura", "Bewerbung"] { addflag "Career_type:Application_Update"; }

# -- B3: Lifestyle, Travel & Logistics --
if address :domain "From" ["ryanair.com", "easyjet.com", "vueling.com", "flixbus.com", "renfe.com"] { addflag "Travel_type:Flight"; }
if address :domain "From" ["uber.com", "bolt.eu", "freenow.com", "blablacar.com"] { addflag "Travel_type:Rideshare"; }
if address :domain "From" ["airbnb.com", "booking.com", "hostelworld.com"] { addflag "Lodging_from:Accommodation"; }
if address :domain "From" ["dhl.com", "dhl.de", "ups.com", "fedex.com", "correos.es", "dpd.com", "gls-group.com"] { addflag "Logistics_Postal_Courier"; }
if address :domain "From" ["deliveroo.com", "ubereats.com", "glovo.com", "justeat.com", "lieferando.de"] { addflag "Lifestyle_FoodDelivery"; }
if address :domain "From" ["doctolib.de", "doctolib.com"] { addflag "Lifestyle_Wellness_Sports"; }
if address :domain "From" ["idealista.com", "immobilienscout24.de", "immowelt.de"] { addflag "Housing_RealEstate"; }

# -- B4: Admin, Finance & E-commerce --
if address :domain "From" ["paypal.com", "stripe.com"] { addflag "Fin_type:Receipt"; }
if address :domain "From" ["n26.com", "revolut.com", "wise.com", "ing.es"] { addflag "Fin_entity:Bank"; }
if address :domain "From" ["amazon.com", "amazon.de", "amazon.es", "ebay.com", "ebay.de"] { addflag "Shopping_Online"; }
if address :domain "From" ["apple.com"] { addflag "Fin_type:Subscription"; }
if address :domain "From" ["bitwarden.com"] { addflag "Sec_type:Login_Alert"; }
if header :contains "Subject" ["invoice", "factura", "Rechnung"] { addflag "Fin_type:Invoice"; }
if header :contains "Subject" ["GDPR", "Datenschutz", "privacy policy", "data protection"] { addflag "Admin_Compliance:GDPR"; }

# -- B5: Information, Media & Feeds --
if address :domain "From" ["substack.com", "medium.com", "beehiiv.com"] { addflag "Read_type:Newsletter"; }
if address :domain "From" ["dev.to", "hashnode.com", "hackernews.com"] { addflag "Read_topic:Tech"; }
if address :domain "From" ["spotify.com"] { addflag "Media_Music"; }
if address :domain "From" ["netflix.com", "youtube.com", "twitch.tv"] { addflag "Media_TV"; }
if address :domain "From" ["twitter.com", "x.com", "mastodon.social"] { addflag "Social_Notification"; }
if address :domain "From" ["facebook.com", "instagram.com", "whatsapp.com"] { addflag "Social_Notification"; }
if address :domain "From" ["reddit.com"] { addflag "Social_Notification"; }

# -- B6: Cloud (Homelab) --
if address :domain "From" ["diegonmarcos.com"] { addflag "Cloud_Ops:Self"; }
if address :domain "From" ["oraclecloud.com", "oracle.com"] { addflag "Cloud_Cost:Oracle"; }
if address :domain "From" ["cloud.google.com", "google.cloud"] { addflag "Cloud_Cost:GCP"; }
if address :domain "From" ["cloudflare.com"] { addflag "Cloud_Sec:Cloudflare"; }
if address :domain "From" ["hetzner.com", "hetzner.de"] { addflag "Cloud_Cost:Hetzner"; }
if address :domain "From" ["letsencrypt.org"] { addflag "Cloud_Sec:Cert_Renewal"; }
if address :domain "From" ["resend.com"] { addflag "Cloud_Ops:Resend"; }
if header :contains "Subject" ["[alert]", "[warning]", "disk full", "certificate expir"] { addflag "Cloud_Ops:Uptime_Alert"; }

# -- B7: Meta Size & Attachments --
if size :over 10485760 { addflag "Meta_Size:Large_10MB+"; }
if header :mime :anychild :contenttype "Content-Type" "application/pdf" { addflag "Meta_Attach:PDF"; }
if header :mime :anychild :contenttype "Content-Type" "image/jpeg" { addflag "Meta_Attach:Image"; }
if header :mime :anychild :contenttype "Content-Type" "image/png" { addflag "Meta_Attach:Image"; }
if header :mime :anychild :contenttype "Content-Type" "image/heic" { addflag "Meta_Attach:Image"; }
if header :mime :anychild :contenttype "Content-Type" "application/msword" { addflag "Meta_Attach:Document"; }
if header :mime :anychild :contenttype "Content-Type" "application/vnd.openxmlformats-officedocument.wordprocessingml.document" { addflag "Meta_Attach:Document"; }
if header :mime :anychild :contenttype "Content-Type" "text/plain" { addflag "Meta_Attach:Document"; }
if header :mime :anychild :contenttype "Content-Type" "application/vnd.ms-excel" { addflag "Meta_Attach:Spreadsheet"; }
if header :mime :anychild :contenttype "Content-Type" "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" { addflag "Meta_Attach:Spreadsheet"; }
if header :mime :anychild :contenttype "Content-Type" "text/csv" { addflag "Meta_Attach:Spreadsheet"; }
if header :mime :anychild :contenttype "Content-Type" "application/zip" { addflag "Meta_Attach:Archive"; }
if header :mime :anychild :contenttype "Content-Type" "application/x-rar-compressed" { addflag "Meta_Attach:Archive"; }
if header :mime :anychild :contenttype "Content-Type" "application/gzip" { addflag "Meta_Attach:Archive"; }

# -- B8: Meta Routing & Sender --
if address :is "From" "me@diegonmarcos.com" { addflag "Meta_Route:SelfSent"; }
if exists "CC" { addflag "Meta_Route:CC"; }
if exists "List-Unsubscribe" { addflag "Meta_Route:BCC_MailingList"; }
if exists "X-Auto-Response-Suppress" { addflag "Meta_Sender:Automated"; }
if exists "Auto-Submitted" { addflag "Meta_Sender:Automated"; }
if header :contains "Precedence" ["bulk", "list", "junk"] { addflag "Meta_Sender:Automated"; }

# ══════════════════════════════════════════════════════════════════
# ROUTING — first match wins (fileinto + stop)
# ══════════════════════════════════════════════════════════════════

if address :domain "From" ["github.com", "gitlab.com", "bitbucket.org", "42.fr", "intra.42.fr", "42berlin.de", "42heilbronn.de", "stackoverflow.com", "stackexchange.com", "npmjs.com", "crates.io", "pypi.org", "docker.com", "hub.docker.com", "nixos.org", "discourse.nixos.org", "dev.to", "hashnode.com", "codeberg.org", "vercel.com", "netlify.com", "railway.app", "jetbrains.com"] {
  fileinto :create "Development";
  stop;
}
if address :domain "From" ["linkedin.com", "indeed.com", "indeed.de", "glassdoor.com", "xing.com", "stepstone.de", "hired.com"] {
  fileinto :create "Career";
  stop;
}
if address :domain "From" ["airbnb.com", "booking.com", "hostelworld.com", "uber.com", "bolt.eu", "freenow.com", "blablacar.com", "flixbus.com", "ryanair.com", "easyjet.com", "vueling.com", "renfe.com", "dhl.com", "dhl.de", "ups.com", "fedex.com", "correos.es", "dpd.com", "gls-group.com", "deliveroo.com", "ubereats.com", "glovo.com", "justeat.com", "lieferando.de", "doctolib.de", "doctolib.com", "idealista.com", "immobilienscout24.de", "immowelt.de"] {
  fileinto :create "Lifestyle";
  stop;
}
if address :domain "From" ["paypal.com", "stripe.com", "n26.com", "revolut.com", "wise.com", "ing.es", "amazon.com", "amazon.de", "amazon.es", "ebay.com", "ebay.de", "apple.com", "bitwarden.com", "google.com"] {
  fileinto :create "Admin";
  stop;
}
if address :domain "From" ["substack.com", "medium.com", "beehiiv.com", "spotify.com", "netflix.com", "youtube.com", "twitch.tv", "twitter.com", "x.com", "reddit.com", "facebook.com", "instagram.com", "whatsapp.com", "mastodon.social", "udemy.com", "coursera.org", "edx.org", "duolingo.com", "babbel.com"] {
  fileinto :create "Information";
  stop;
}
if address :domain "From" ["diegonmarcos.com", "oraclecloud.com", "oracle.com", "cloud.google.com", "google.cloud", "cloudflare.com", "hetzner.com", "hetzner.de", "letsencrypt.org", "resend.com", "ntfy.sh"] {
  fileinto :create "Cloud";
  stop;
}
# Default: implicit keep -> INBOX
