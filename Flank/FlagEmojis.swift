//
//  FlagEmojis.swift
//  Flank
//
//  Created by Patryk Radziszewski on 30/07/2024.
//

import Foundation

public let flagEmojis: [String: String] = [
    "flag_br": "🇧🇷",
    "flag_us": "🇺🇸",
    "flag_pl": "🇵🇱",
    "flag_tr": "🇹🇷",
    "flag_eu": "🇪🇺",
    "flag_fr": "🇫🇷",
    "flag_de": "🇩🇪",
    "flag_cn": "🇨🇳",
    "flag_kr": "🇰🇷",
    "flag_id": "🇮🇩",
    "flag_ph": "🇵🇭",
    "flag_it": "🇮🇹",
    "flag_kw": "🇰🇼",
    "flag_sa": "🇸🇦",
    "flag_pt": "🇵🇹",
    "flag_un": "🇺🇳",
    "flag_gb": "🇬🇧",
    "flag_ca": "🇨🇦",
    "flag_au": "🇦🇺",
    "flag_jp": "🇯🇵",
    "flag_es": "🇪🇸",
    "flag_ru": "🇷🇺",
    "flag_in": "🇮🇳",
    "flag_mx": "🇲🇽",
    "flag_ar": "🇦🇷",
    "flag_se": "🇸🇪",
    "flag_no": "🇳🇴",
    "flag_dk": "🇩🇰",
    "flag_fi": "🇫🇮",
    "flag_nl": "🇳🇱",
    "flag_be": "🇧🇪",
    "flag_ch": "🇨🇭",
    "flag_at": "🇦🇹",
    "flag_gr": "🇬🇷",
    "flag_za": "🇿🇦",
    "flag_nz": "🇳🇿",
    "flag_sg": "🇸🇬",
    "flag_ua": "🇺🇦",
    "flag_vn": "🇻🇳",
    "flag_th": "🇹🇭",
    "flag_my": "🇲🇾",
]

public func emoji(for flagCode: String) -> String {
    return flagEmojis[flagCode] ?? "🏳️" // Default to white flag if not found
}