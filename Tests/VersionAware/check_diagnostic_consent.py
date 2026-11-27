from pathlib import Path

base = Path(__file__).resolve().parents[2]
client = (base / "Sources/TinplateClient.swift").read_text()
composer = client.split("struct TinplateTicketComposer: View {", 1)[1]

# Consent must be local to the composer and default to false.
assert "@State private var authorizeDiagnostics = false" in composer
assert 'Toggle("授权提交诊断信息", isOn: $authorizeDiagnostics)' in composer
assert "if authorizeDiagnostics" in composer
assert "diagnosticSummary: nil" in composer

# A checked box must produce a preview and require a second explicit action.
assert "model.makeDiagnosticPreview()" in composer
assert "showingDiagnosticPreview = true" in composer
assert "诊断内容预览" in composer
assert "确认并提交" in composer
assert "approvedSummary = diagnosticPreview" in composer

# Cancel must revoke this ticket's consent and discard the preview.
assert "onDismiss: {" in composer
assert "authorizeDiagnostics = false" in composer
assert "diagnosticPreview = \"\"" in composer

# The model must only append diagnostics when an approved summary is passed.
assert "diagnosticSummary: String? = nil" in client
assert "—— 用户已授权提交的诊断摘要 ——" in client
assert "if diagnostic.isEmpty" in client
assert "finalDescription.count <= 5000" in client

# The preview generator must redact credentials, bearer values, account name and paths.
assert "private func redactDiagnosticText" in client
for marker in ("password", "authorization", "Bearer", "recovery", "应用沙盒路径", "本地路径", "查询参数已脱敏"):
    assert marker in client
assert "UIDevice.current.systemVersion" in client
assert "selectedGame?.name" in client
assert "LaunchDiagnostics.logURL" in client

print("PASS: B153 ticket diagnostics are opt-in, previewed, separately confirmed, cancellable, and redacted")
