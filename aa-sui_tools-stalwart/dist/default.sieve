require ["fileinto", "imap4flags", "mailbox", "envelope", "mime", "copy"];

# ══════════════════════════════════════════════════════════════════
# TAGS — all matching rules fire (additive IMAP keywords)
# Generated from mail-rules.json — DO NOT EDIT
# ══════════════════════════════════════════════════════════════════

# -- B1: 1- Development, Education & Tools --
if address :domain "From" ["42berlin.de"] { addflag "Dev_context:42Berlin"; fileinto :copy :create "1- Development, Education & Tools/1-0 Dev_context:42Berlin"; }
if header :contains "Subject" ["evaluation", "evaluaci", "peer review", "correction"] { addflag "Dev_context:42Evaluations"; fileinto :copy :create "1- Development, Education & Tools/1-1 Dev_context:42Evaluations"; }
if address :domain "From" ["github.com"] { addflag "Dev_platform:GitHub"; fileinto :copy :create "1- Development, Education & Tools/1-2 Dev_platform:GitHub"; }
if address :domain "From" ["gitlab.com"] { addflag "Dev_platform:GitLab"; fileinto :copy :create "1- Development, Education & Tools/1-3 Dev_platform:GitLab"; }
if header :contains "Subject" ["pull request", "merge request", "[PR]", "Review requested"] { addflag "Dev_type:PullRequest"; fileinto :copy :create "1- Development, Education & Tools/1-4 Dev_type:PullRequest"; }
if address :domain "From" ["vercel.com", "netlify.com", "railway.app", "heroku.com", "notion.so", "figma.com", "miro.com"] { addflag "SaaS_Productivity"; fileinto :copy :create "1- Development, Education & Tools/1-5 SaaS_Productivity"; }
if address :domain "From" ["jetbrains.com", "adobe.com", "canva.com"] { addflag "SaaS_Creative"; fileinto :copy :create "1- Development, Education & Tools/1-6 SaaS_Creative"; }
if address :domain "From" ["duolingo.com", "babbel.com", "busuu.com"] { addflag "Edu_Languages"; fileinto :copy :create "1- Development, Education & Tools/1-7 Edu_Languages"; }
if address :domain "From" ["udemy.com", "coursera.org", "edx.org", "skillshare.com", "pluralsight.com"] { addflag "Edu_General"; fileinto :copy :create "1- Development, Education & Tools/1-8 Edu_General"; }

# -- B2: 2- Career & Networking --
if address :domain "From" ["glassdoor.com", "xing.com", "stepstone.de", "hired.com", "wellfound.com"] { addflag "Career_JobAlerts"; fileinto :copy :create "2- Career & Networking/2-0 Career_JobAlerts"; }
if address :domain "From" ["linkedin.com"] { addflag "Career_source:LinkedIn"; fileinto :copy :create "2- Career & Networking/2-1 Career_source:LinkedIn"; }
if address :domain "From" ["indeed.com", "indeed.de"] { addflag "Career_source:Indeed"; fileinto :copy :create "2- Career & Networking/2-2 Career_source:Indeed"; }
if header :contains "Subject" ["application", "candidatura", "Bewerbung", "your application", "application status"] { addflag "Career_type:Application_Update"; fileinto :copy :create "2- Career & Networking/2-3 Career_type:Application_Update"; }
if header :contains "Subject" ["interview", "entrevista", "Vorstellungsgespr", "schedule a call", "phone screen"] { addflag "Career_type:Interview_Invite"; fileinto :copy :create "2- Career & Networking/2-4 Career_type:Interview_Invite"; }
if header :contains "Subject" ["recruiter", "headhunt", "opportunity", "we found your profile", "job match", "talent"] { addflag "Career_type:Recruiter_Message"; fileinto :copy :create "2- Career & Networking/2-5 Career_type:Recruiter_Message"; }

# -- B3: 3- Lifestyle, Travel & Logistics --
if address :domain "From" ["ryanair.com", "easyjet.com", "vueling.com", "flixbus.com", "renfe.com", "iberia.com", "lufthansa.com", "klm.com"] { addflag "Travel_type:Flight"; fileinto :copy :create "3- Lifestyle, Travel & Logistics/3-0 Travel_type:Flight"; }
if address :domain "From" ["uber.com", "bolt.eu", "freenow.com", "blablacar.com", "lyft.com"] { addflag "Travel_type:Rideshare"; fileinto :copy :create "3- Lifestyle, Travel & Logistics/3-1 Travel_type:Rideshare"; }
if address :domain "From" ["airbnb.com"] { addflag "Lodging_from:Airbnb"; fileinto :copy :create "3- Lifestyle, Travel & Logistics/3-2 Lodging_from:Airbnb"; }
if address :domain "From" ["hostelworld.com"] { addflag "Lodging_from:Hostelworld"; fileinto :copy :create "3- Lifestyle, Travel & Logistics/3-3 Lodging_from:Hostelworld"; }
if address :domain "From" ["idealista.com", "immobilienscout24.de", "immowelt.de", "fotocasa.es", "pisos.com"] { addflag "Housing_RealEstate"; fileinto :copy :create "3- Lifestyle, Travel & Logistics/3-4 Housing_RealEstate"; }
if address :domain "From" ["dhl.com", "dhl.de", "ups.com", "fedex.com", "correos.es", "dpd.com", "gls-group.com", "seur.com", "mrw.es"] { addflag "Logistics_Postal_Courier"; fileinto :copy :create "3- Lifestyle, Travel & Logistics/3-5 Logistics_Postal_Courier"; }
if address :domain "From" ["deliveroo.com", "ubereats.com", "glovo.com", "justeat.com", "lieferando.de", "doordash.com"] { addflag "Lifestyle_FoodDelivery"; fileinto :copy :create "3- Lifestyle, Travel & Logistics/3-6 Lifestyle_FoodDelivery"; }
if address :domain "From" ["doctolib.de", "doctolib.com", "gympass.com", "freeletics.com", "strava.com"] { addflag "Lifestyle_Wellness_Sports"; fileinto :copy :create "3- Lifestyle, Travel & Logistics/3-7 Lifestyle_Wellness_Sports"; }
if address :domain "From" ["eventbrite.com", "meetup.com", "ticketmaster.com", "dice.fm", "stubhub.com"] { addflag "Lifestyle_Leisure"; fileinto :copy :create "3- Lifestyle, Travel & Logistics/3-8 Lifestyle_Leisure"; }
if address :domain "From" ["tinder.com", "bumble.com", "hinge.co", "okcupid.com"] { addflag "Social_Dating"; fileinto :copy :create "3- Lifestyle, Travel & Logistics/3-9 Social_Dating"; }

# -- B4: 4- Admin, Finance & E-commerce --
if address :domain "From" ["paypal.com", "stripe.com"] { addflag "Fin_type:Receipt"; fileinto :copy :create "4- Admin, Finance & E-commerce/4-0 Fin_type:Receipt"; }
if header :contains "Subject" ["invoice", "factura", "Rechnung", "billing statement"] { addflag "Fin_type:Invoice"; fileinto :copy :create "4- Admin, Finance & E-commerce/4-1 Fin_type:Invoice"; }
if address :domain "From" ["apple.com", "spotify.com", "netflix.com", "adobe.com"] { addflag "Fin_type:Subscription"; fileinto :copy :create "4- Admin, Finance & E-commerce/4-2 Fin_type:Subscription"; }
if address :domain "From" ["allianz.com", "axa.com", "mapfre.com", "huk.de"] { addflag "Fin_type:Insurance"; fileinto :copy :create "4- Admin, Finance & E-commerce/4-3 Fin_type:Insurance"; }
if address :domain "From" ["n26.com", "revolut.com", "wise.com", "ing.es", "ing.de", "commerzbank.de", "deutschebank.de"] { addflag "Fin_entity:Bank"; fileinto :copy :create "4- Admin, Finance & E-commerce/4-4 Fin_entity:Bank"; }
if address :domain "From" ["elster.de", "agenciatributaria.es", "tax.service.gov.uk"] { addflag "Fin_entity:Tax"; fileinto :copy :create "4- Admin, Finance & E-commerce/4-5 Fin_entity:Tax"; }
if address :domain "From" ["amazon.com", "amazon.de", "amazon.es", "ebay.com", "ebay.de", "aliexpress.com", "zalando.de"] { addflag "Shopping_Online"; fileinto :copy :create "4- Admin, Finance & E-commerce/4-6 Shopping_Online"; }
if address :domain "From" ["bitwarden.com", "1password.com", "accounts.google.com", "noreply.github.com"] { addflag "Sec_type:Login_Alert"; fileinto :copy :create "4- Admin, Finance & E-commerce/4-7 Sec_type:Login_Alert"; }
if header :contains "Subject" ["GDPR", "Datenschutz", "privacy policy", "data protection", "data subject"] { addflag "Admin_Compliance:GDPR"; fileinto :copy :create "4- Admin, Finance & E-commerce/4-8 Admin_Compliance:GDPR"; }
if header :contains "Subject" ["review requested", "action required", "requires your attention", "please review"] { addflag "Action_ReviewRequested"; fileinto :copy :create "4- Admin, Finance & E-commerce/4-9 Action_ReviewRequested"; }

# -- B5: 5- Information, Media & Feeds --
if address :domain "From" ["dev.to", "hashnode.com", "hackernews.com", "theregister.com", "arstechnica.com"] { addflag "Read_topic:Tech"; fileinto :copy :create "5- Information, Media & Feeds/5-0 Read_topic:Tech"; }
if address :domain "From" ["bbc.com", "reuters.com", "elpais.com", "spiegel.de", "theguardian.com", "nytimes.com"] { addflag "Read_type:News"; fileinto :copy :create "5- Information, Media & Feeds/5-1 Read_type:News"; }
if address :domain "From" ["substack.com", "medium.com", "beehiiv.com", "revue.email"] { addflag "Read_type:Magazine"; fileinto :copy :create "5- Information, Media & Feeds/5-2 Read_type:Magazine"; }
if address :domain "From" ["spotify.com", "soundcloud.com", "bandcamp.com"] { addflag "Media_Music"; fileinto :copy :create "5- Information, Media & Feeds/5-3 Media_Music"; }
if address :domain "From" ["netflix.com", "youtube.com", "twitch.tv", "hbomax.com", "disneyplus.com", "primevideo.com"] { addflag "Media_TV"; fileinto :copy :create "5- Information, Media & Feeds/5-4 Media_TV"; }
if address :domain "From" ["goodreads.com", "kindle.amazon.com", "audible.com"] { addflag "Media_Books"; fileinto :copy :create "5- Information, Media & Feeds/5-5 Media_Books"; }
if address :domain "From" ["steampowered.com", "epicgames.com", "gog.com", "playstation.com", "xbox.com", "nintendo.com"] { addflag "Media_Games"; fileinto :copy :create "5- Information, Media & Feeds/5-6 Media_Games"; }
if address :domain "From" ["twitter.com", "x.com", "mastodon.social", "facebook.com", "instagram.com", "whatsapp.com", "reddit.com"] { addflag "Social_Notification"; fileinto :copy :create "5- Information, Media & Feeds/5-7 Social_Notification"; }
if header :contains "Subject" ["% off", "sale", "discount", "promo", "deal", "oferta", "descuento", "Rabatt"] { addflag "Promo_Occasional"; fileinto :copy :create "5- Information, Media & Feeds/5-8 Promo_Occasional"; }

# -- B6: 6- Cloud (Homelab) Management --
if header :contains "Subject" ["[alert]", "[warning]", "is down", "unreachable", "uptime"] { addflag "Cloud_Ops:Uptime_Alert"; fileinto :copy :create "6- Cloud (Homelab) Management/6-0 Cloud_Ops:Uptime_Alert"; }
if header :contains "Subject" ["backup", "restic", "snapshot", "restore"] { addflag "Cloud_Ops:Backup_Status"; fileinto :copy :create "6- Cloud (Homelab) Management/6-1 Cloud_Ops:Backup_Status"; }
if header :contains "Subject" ["disk full", "storage", "quota", "low space", "inode"] { addflag "Cloud_Ops:Storage_Warning"; fileinto :copy :create "6- Cloud (Homelab) Management/6-2 Cloud_Ops:Storage_Warning"; }
if header :contains "Subject" ["login attempt", "auth", "unauthorized", "suspicious sign"] { addflag "Cloud_Sec:Auth_Alert"; fileinto :copy :create "6- Cloud (Homelab) Management/6-3 Cloud_Sec:Auth_Alert"; }
if header :contains "Subject" ["blocked", "threat", "intrusion", "fail2ban", "banned"] { addflag "Cloud_Sec:Threat_Blocked"; fileinto :copy :create "6- Cloud (Homelab) Management/6-4 Cloud_Sec:Threat_Blocked"; }
if address :domain "From" ["letsencrypt.org"] { addflag "Cloud_Sec:Cert_Renewal"; fileinto :copy :create "6- Cloud (Homelab) Management/6-5 Cloud_Sec:Cert_Renewal"; }
if address :domain "From" ["namecheap.com", "gandi.net", "name.com", "godaddy.com"] { addflag "Cloud_Cost:Domain_Renewal"; fileinto :copy :create "6- Cloud (Homelab) Management/6-6 Cloud_Cost:Domain_Renewal"; }
if address :domain "From" ["hetzner.com", "hetzner.de", "dell.com", "lenovo.com"] { addflag "Cloud_Cost:Hardware_Asset"; fileinto :copy :create "6- Cloud (Homelab) Management/6-7 Cloud_Cost:Hardware_Asset"; }
if address :domain "From" ["oraclecloud.com", "oracle.com", "cloud.google.com", "google.cloud", "cloudflare.com", "digitalocean.com"] { addflag "Cloud_Cost:External_SaaS"; fileinto :copy :create "6- Cloud (Homelab) Management/6-8 Cloud_Cost:External_SaaS"; }

# -- B7: 7- Meta Size & Attachment Types --
if size :over 10485760 { addflag "Meta_Size:Large_10MB+"; fileinto :copy :create "7- Meta Size & Attachment Types/7-0 Meta_Size:Large_10MB+"; }
if header :mime :anychild :contenttype "Content-Type" "application/pdf" { addflag "Meta_Attach:PDF"; fileinto :copy :create "7- Meta Size & Attachment Types/7-1 Meta_Attach:PDF"; }
if header :mime :anychild :contenttype "Content-Type" "image/jpeg" { addflag "Meta_Attach:Image"; fileinto :copy :create "7- Meta Size & Attachment Types/7-2 Meta_Attach:Image"; }
if header :mime :anychild :contenttype "Content-Type" "image/png" { addflag "Meta_Attach:Image"; fileinto :copy :create "7- Meta Size & Attachment Types/7-3 Meta_Attach:Image"; }
if header :mime :anychild :contenttype "Content-Type" "image/heic" { addflag "Meta_Attach:Image"; fileinto :copy :create "7- Meta Size & Attachment Types/7-4 Meta_Attach:Image"; }
if header :mime :anychild :contenttype "Content-Type" "application/msword" { addflag "Meta_Attach:Document"; fileinto :copy :create "7- Meta Size & Attachment Types/7-5 Meta_Attach:Document"; }
if header :mime :anychild :contenttype "Content-Type" "application/vnd.openxmlformats-officedocument.wordprocessingml.document" { addflag "Meta_Attach:Document"; fileinto :copy :create "7- Meta Size & Attachment Types/7-6 Meta_Attach:Document"; }
if header :mime :anychild :contenttype "Content-Type" "text/plain" { addflag "Meta_Attach:Document"; fileinto :copy :create "7- Meta Size & Attachment Types/7-7 Meta_Attach:Document"; }
if header :mime :anychild :contenttype "Content-Type" "application/vnd.ms-excel" { addflag "Meta_Attach:Spreadsheet"; fileinto :copy :create "7- Meta Size & Attachment Types/7-8 Meta_Attach:Spreadsheet"; }
if header :mime :anychild :contenttype "Content-Type" "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" { addflag "Meta_Attach:Spreadsheet"; fileinto :copy :create "7- Meta Size & Attachment Types/7-9 Meta_Attach:Spreadsheet"; }
if header :mime :anychild :contenttype "Content-Type" "text/csv" { addflag "Meta_Attach:Spreadsheet"; fileinto :copy :create "7- Meta Size & Attachment Types/7-10 Meta_Attach:Spreadsheet"; }
if header :mime :anychild :contenttype "Content-Type" "application/zip" { addflag "Meta_Attach:Archive"; fileinto :copy :create "7- Meta Size & Attachment Types/7-11 Meta_Attach:Archive"; }
if header :mime :anychild :contenttype "Content-Type" "application/x-rar-compressed" { addflag "Meta_Attach:Archive"; fileinto :copy :create "7- Meta Size & Attachment Types/7-12 Meta_Attach:Archive"; }
if header :mime :anychild :contenttype "Content-Type" "application/gzip" { addflag "Meta_Attach:Archive"; fileinto :copy :create "7- Meta Size & Attachment Types/7-13 Meta_Attach:Archive"; }
if header :mime :anychild :contenttype "Content-Type" "application/x-tar" { addflag "Meta_Attach:Archive"; fileinto :copy :create "7- Meta Size & Attachment Types/7-14 Meta_Attach:Archive"; }
if header :mime :anychild :contenttype "Content-Type" "audio/mpeg" { addflag "Meta_Attach:Media"; fileinto :copy :create "7- Meta Size & Attachment Types/7-15 Meta_Attach:Media"; }
if header :mime :anychild :contenttype "Content-Type" "audio/wav" { addflag "Meta_Attach:Media"; fileinto :copy :create "7- Meta Size & Attachment Types/7-16 Meta_Attach:Media"; }
if header :mime :anychild :contenttype "Content-Type" "video/mp4" { addflag "Meta_Attach:Media"; fileinto :copy :create "7- Meta Size & Attachment Types/7-17 Meta_Attach:Media"; }
if header :mime :anychild :contenttype "Content-Type" "video/quicktime" { addflag "Meta_Attach:Media"; fileinto :copy :create "7- Meta Size & Attachment Types/7-18 Meta_Attach:Media"; }

# -- B8: 8- Meta Routing & Sender Properties --
if exists "CC" { addflag "Meta_Route:CC"; fileinto :copy :create "8- Meta Routing & Sender Properties/8-0 Meta_Route:CC"; }
if address :is "From" "me@diegonmarcos.com" { addflag "Meta_Route:SelfSent"; fileinto :copy :create "8- Meta Routing & Sender Properties/8-1 Meta_Route:SelfSent"; }
if exists "List-Unsubscribe" { addflag "Meta_Route:BCC_MailingList"; fileinto :copy :create "8- Meta Routing & Sender Properties/8-2 Meta_Route:BCC_MailingList"; }
if exists "X-Auto-Response-Suppress" { addflag "Meta_Sender:Automated"; fileinto :copy :create "8- Meta Routing & Sender Properties/8-3 Meta_Sender:Automated"; }
if exists "Auto-Submitted" { addflag "Meta_Sender:Automated"; fileinto :copy :create "8- Meta Routing & Sender Properties/8-4 Meta_Sender:Automated"; }
if header :contains "Precedence" ["bulk", "list", "junk"] { addflag "Meta_Sender:Automated"; fileinto :copy :create "8- Meta Routing & Sender Properties/8-5 Meta_Sender:Automated"; }
if header :contains "From" ["noreply", "no-reply", "donotreply", "mailer-daemon", "postmaster"] { addflag "Meta_Sender:Unusual"; fileinto :copy :create "8- Meta Routing & Sender Properties/8-6 Meta_Sender:Unusual"; }

# ══════════════════════════════════════════════════════════════════
# ROUTING — first match wins (fileinto + stop)
# ══════════════════════════════════════════════════════════════════

if address :domain "From" ["github.com", "gitlab.com", "bitbucket.org", "42.fr", "intra.42.fr", "42berlin.de", "42heilbronn.de", "stackoverflow.com", "stackexchange.com", "npmjs.com", "crates.io", "pypi.org", "docker.com", "hub.docker.com", "nixos.org", "discourse.nixos.org", "dev.to", "hashnode.com", "codeberg.org", "vercel.com", "netlify.com", "railway.app", "jetbrains.com", "heroku.com"] {
  fileinto :create "🎓 Development & Tech";
  stop;
}
if address :domain "From" ["linkedin.com", "indeed.com", "indeed.de", "glassdoor.com", "xing.com", "stepstone.de", "hired.com", "wellfound.com"] {
  fileinto :create "💼 Career & Network";
  stop;
}
if address :domain "From" ["airbnb.com", "booking.com", "hostelworld.com", "uber.com", "bolt.eu", "freenow.com", "blablacar.com", "lyft.com", "flixbus.com", "ryanair.com", "easyjet.com", "vueling.com", "renfe.com", "iberia.com", "dhl.com", "dhl.de", "ups.com", "fedex.com", "correos.es", "dpd.com", "gls-group.com", "seur.com", "deliveroo.com", "ubereats.com", "glovo.com", "justeat.com", "lieferando.de", "doctolib.de", "doctolib.com", "idealista.com", "immobilienscout24.de", "immowelt.de", "eventbrite.com", "meetup.com", "ticketmaster.com", "tinder.com", "bumble.com"] {
  fileinto :create "✈️ Lifestyle & Logistics";
  stop;
}
if address :domain "From" ["paypal.com", "stripe.com", "n26.com", "revolut.com", "wise.com", "ing.es", "ing.de", "amazon.com", "amazon.de", "amazon.es", "ebay.com", "ebay.de", "apple.com", "bitwarden.com", "accounts.google.com", "allianz.com", "axa.com", "elster.de", "agenciatributaria.es", "aliexpress.com", "zalando.de"] {
  fileinto :create "🛡️ Admin & Finance";
  stop;
}
if address :domain "From" ["substack.com", "medium.com", "beehiiv.com", "spotify.com", "netflix.com", "youtube.com", "twitch.tv", "twitter.com", "x.com", "reddit.com", "facebook.com", "instagram.com", "whatsapp.com", "mastodon.social", "udemy.com", "coursera.org", "edx.org", "duolingo.com", "babbel.com", "bbc.com", "reuters.com", "elpais.com", "spiegel.de", "steampowered.com", "epicgames.com", "goodreads.com"] {
  fileinto :create "📰 Information & Feeds";
  stop;
}
if address :domain "From" ["diegonmarcos.com", "oraclecloud.com", "oracle.com", "cloud.google.com", "google.cloud", "cloudflare.com", "hetzner.com", "hetzner.de", "letsencrypt.org", "resend.com", "ntfy.sh", "digitalocean.com", "namecheap.com", "gandi.net"] {
  fileinto :create "☁️ Cloud (Homelab)";
  stop;
}
# Default: unmatched emails go to Others
fileinto :create "📦 Others";
