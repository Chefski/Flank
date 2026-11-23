import os

_DEFAULT_USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

# Set VLR_USER_AGENT to an identifiable value (a bot name plus a contact URL or
# email) so vlr.gg can recognise, allowlist or contact this scraper instead of
# blocking an anonymous browser string.
headers = {
    "User-Agent": os.environ.get("VLR_USER_AGENT", "").strip() or _DEFAULT_USER_AGENT,
}


region = {
    "na": "north-america",
    "eu": "europe",
    "ap": "asia-pacific",
    "la": "latin-america",
    "la-s": "la-s",
    "la-n": "la-n",
    "oce": "oceania",
    "kr": "korea",
    "mn": "mena",
    "gc": "gc",
    "br": "Brazil",
    "cn": "china",
    "jp": "japan",
    "col": "collegiate",
}
