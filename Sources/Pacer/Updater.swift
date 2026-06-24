import AppKit

/// 인앱 업데이트 — 미서명 앱이라 자기 번들을 직접 못 덮어쓴다.
/// 헬퍼 스크립트를 detached 로 띄우고 앱이 종료되면, 스크립트가 Pacer 종료를 기다렸다가
/// 최신 dmg 를 받아 /Applications/Pacer.app 을 교체하고 재실행한다.
enum Updater {
    /// 확인창 → 헬퍼 스크립트 작성·실행 → 앱 종료. 스크립트가 교체·재실행을 마무리한다.
    @MainActor static func runUpdate() {
        let lang = UserDefaults.standard.string(forKey: "pacerLang") ?? "en"

        // 확인창 — Update 가 아니면 중단
        let alert = NSAlert()
        alert.messageText = "Pacer 업데이트"
        alert.informativeText = tr(lang,
            "Download the latest version and restart?",
            "최신 버전을 받아 재시작합니다. 계속할까요?")
        alert.addButton(withTitle: tr(lang, "Update", "업데이트"))
        alert.addButton(withTitle: tr(lang, "Cancel", "취소"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

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
