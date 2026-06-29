import AppKit

/// 인앱 업데이트 — 미서명 앱이라 자기 번들을 직접 못 덮어쓴다.
/// 헬퍼 스크립트를 detached 로 띄우고 앱이 종료되면, 스크립트가 Pacer 종료를 기다렸다가
/// 최신 dmg 를 받아 /Applications/Pacer.app 을 교체하고 재실행한다.
enum Updater {
    /// GitHub 최신 릴리즈 태그(tag_name) fetch — 앞의 v 제거. 두 진입점 공용.
    /// @param completion 메인스레드에서 최신 버전(없으면 nil) 전달
    static func fetchLatest(completion: @escaping (String?) -> Void) {
        let url = URL(string: "https://api.github.com/repos/codedooly/claude-pacer/releases/latest")!
        URLSession.shared.dataTask(with: url) { data, _, _ in
            // tag_name(예 "v1.1.0") 파싱 → 앞의 v 제거
            let latest: String? = data
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["tag_name"] as? String }
                .map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
            DispatchQueue.main.async { completion(latest) }
        }.resume()
    }

    /// 현재 앱 버전 (CFBundleShortVersionString).
    static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// fetchLatest 의 async 래퍼 (주기 업데이트 체크용).
    static func latestVersion() async -> String? {
        await withCheckedContinuation { c in fetchLatest { c.resume(returning: $0) } }
    }

    /// latest 가 current 보다 새 버전인지 — 숫자 비교(1.2.0 > 1.1.11 정확히).
    static func isNewer(_ latest: String, than current: String) -> Bool {
        latest.compare(current, options: .numeric) == .orderedDescending
    }

    /// 확인창 → 헬퍼 스크립트 작성·실행 → 앱 종료. 스크립트가 교체·재실행을 마무리한다.
    /// @param latest 최신 버전 (알면 현재→최신 화살표 표시, 모르면 일반 문구)
    @MainActor static func runUpdate(latest: String? = nil) {
        let lang = UserDefaults.standard.string(forKey: "pacerLang") ?? "en"
        let current = currentVersion()

        // 확인창 — Update 가 아니면 중단
        // 최신을 알면 현재→최신 화살표, 모르면(네트워크 실패) 기존 일반 문구
        let message: String
        if let latest {
            message = tr(lang,
                "Current  \(current)  →  Latest  \(latest)\n\nDownload and restart?",
                "현재  \(current)  →  최신  \(latest)\n\n받아서 재시작합니다. 계속할까요?")
        } else {
            message = tr(lang,
                "Download the latest version and restart?",
                "최신 버전을 받아 재시작합니다. 계속할까요?")
        }
        // 확인창 — "업데이트"(인덱스 1) 일 때만 진행
        PacerDialog.show(title: tr(lang, "Update Pacer", "Pacer 업데이트"),
                         message: message,
                         buttons: [(tr(lang, "Cancel", "취소"), false),
                                   (tr(lang, "Update", "업데이트"), true)]) { idx in
            guard idx == 1 else { return }

            // 교체 스크립트 작성 — Pacer 종료 대기 후 dmg 받아 /Applications 교체·재실행
            let script = """
            #!/bin/bash
            while pgrep -x Pacer >/dev/null 2>&1; do sleep 0.4; done
            DL=$(mktemp -d); MNT=$(mktemp -d)
            curl -fsSL https://github.com/codedooly/claude-pacer/releases/latest/download/Pacer.dmg -o "$DL/Pacer.dmg" || exit 1
            hdiutil attach -nobrowse -quiet -mountpoint "$MNT" "$DL/Pacer.dmg" || exit 1
            rm -rf /Applications/Pacer.app
            cp -R "$MNT/Pacer.app" /Applications/
            hdiutil detach -quiet "$MNT"
            rm -rf "$DL" "$MNT"
            open -a Pacer
            """
            let path = NSTemporaryDirectory() + "pacer-update.sh"
            guard (try? script.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return }

            // detached 실행 — 앱이 곧 종료되므로 waitUntilExit 하지 않는다 (chmod 불필요: bash <path>)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [path]
            try? p.run()

            // 앱 종료 → 스크립트의 pgrep 대기가 풀려 교체 시작
            NSApp.terminate(nil)
        }
    }
}
