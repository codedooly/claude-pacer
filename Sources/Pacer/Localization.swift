import Foundation

/// 앱 내 언어 토글 — 기본 영어, 한국어 전환.
/// 기술 용어·식별자(launchd · Routine · /schedule · Pacer · Claude)는 원문 유지.
/// @param lang "en" | "ko" (@AppStorage("pacerLang"))
/// @returns lang 에 맞는 문자열
func tr(_ lang: String, _ en: String, _ ko: String) -> String {
    lang == "ko" ? ko : en
}
