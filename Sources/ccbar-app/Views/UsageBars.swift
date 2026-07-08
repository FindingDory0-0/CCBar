import SwiftUI
import CCBarCore

/// The 5h / 7d / (optional) per-model utilization bars shown at the top of the popover.
///
/// Pull-to-refresh isn't a thing for popovers; instead we re-fetch every time the
/// popover opens (via PopoverView's .task) and the underlying client caches for 30s.
struct UsageBars: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let usage = appModel.usage {
                // Have at least one good snapshot — show the bars.
                bar(label: "5h",  window: usage.fiveHour)
                bar(label: "7d",  window: usage.sevenDay)
                if let opus = usage.sevenDayOpus {
                    bar(label: "Opus", window: opus, sub: true)
                }
                if let sonnet = usage.sevenDaySonnet {
                    bar(label: "Sonnet", window: sonnet, sub: true)
                }
                // Per-model weekly caps from the API's `limits` array (e.g. Fable).
                // Same full-size style as 5h/7d (not the thinner sub-bar).
                ForEach(usage.scopedModels ?? [], id: \.modelName) { m in
                    bar(label: m.modelName, window: m.window)
                }
                // If a fetch failed since the snapshot was taken, fold in a tiny notice.
                if let err = appModel.usageError {
                    inlineErrorBadge(err, fetchedAt: usage.fetchedAt)
                }
            } else if appModel.usageIsLoading {
                placeholder
            } else if let err = appModel.usageError {
                // No cached usage yet AND we hit an error → still show one row.
                errorView(err)
            } else {
                placeholder
            }
        }
    }

    private func inlineErrorBadge(_ failure: UsageApiClient.Failure, fetchedAt: Date) -> some View {
        let staleness = Date().timeIntervalSince(fetchedAt)
        let staleText: String = {
            switch staleness {
            case ..<60:    return "방금 갱신"
            case ..<3600:  return "\(Int(staleness / 60))분 전 값"
            default:       return "\(Int(staleness / 3600))시간 전 값"
            }
        }()
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text(briefMessage(for: failure))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(staleText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .help(message(for: failure))
        .padding(.top, 2)
    }

    /// One-liner suitable for the inline badge alongside the (stale) bars.
    private func briefMessage(for failure: UsageApiClient.Failure) -> String {
        switch failure {
        case .keychainUnavailable, .credentialsMalformed: "인증 정보 읽기 실패"
        case .tokenRefreshFailed:                          "토큰 갱신 실패"
        case .http(429):                                   "잠시 후 자동 재시도"
        case .http(let code):                              "API 응답 \(code)"
        case .decoding:                                    "응답 디코딩 실패"
        case .network:                                     "네트워크 오류"
        }
    }

    // MARK: - Bar

    private func bar(label: String, window: SubscriptionUsage.Window, sub: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(sub ? .caption2 : .caption.weight(.semibold))
                .foregroundStyle(sub ? .secondary : .primary)
                .frame(width: 40, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(color(for: window.utilization))
                        .frame(width: max(2, proxy.size.width * CGFloat(min(window.utilization, 100)) / 100))
                }
            }
            .frame(height: sub ? 4 : 6)
            Text(percentLabel(window.utilization))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Text(resetLabel(window.resetsAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help(absoluteReset(window.resetsAt))
                .frame(width: 100, alignment: .trailing)
        }
    }

    // MARK: - Placeholder / error

    private var placeholder: some View {
        HStack(spacing: 8) {
            Text("사용량")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ProgressView()
                .controlSize(.mini)
            Spacer()
        }
    }

    private func errorView(_ err: UsageApiClient.Failure) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(message(for: err))
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await appModel.refreshUsage(force: true) }
                } label: {
                    Label("지금 다시 시도", systemImage: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(appModel.usageIsLoading)
            }
            Spacer(minLength: 0)
            if appModel.usageIsLoading {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private func message(for failure: UsageApiClient.Failure) -> String {
        switch failure {
        case .keychainUnavailable:     "Keychain에서 Claude Code 인증 정보를 읽지 못했습니다"
        case .credentialsMalformed:    "인증 정보 형식이 예상과 다릅니다"
        case .tokenRefreshFailed:      "토큰 갱신 실패 — Claude Code 재로그인 필요"
        case .http(let code):          "사용량 API 응답 \(code)"
        case .decoding:                "사용량 응답 디코딩 실패"
        case .network(let s):          "네트워크 오류: \(s)"
        }
    }

    // MARK: - Formatting

    private func color(for utilization: Double) -> Color {
        switch utilization {
        case ..<70:  return .green
        case ..<90:  return .orange
        default:     return .red
        }
    }

    private func percentLabel(_ u: Double) -> String {
        String(format: "%.0f%%", u)
    }

    /// "1시간 38분 후" / "2일 8시간 후" / "30분 후" / "곧 리셋".
    ///
    /// `RelativeDateTimeFormatter` always rounds to a single unit ("1시간 후"
    /// even when 38 minutes are left), which made the bar look stale. We format
    /// two units manually so the user can see exactly when the window resets.
    private func resetLabel(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 0 { return "곧 리셋" }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 {
            return hours > 0 ? "\(days)일 \(hours)시간 후" : "\(days)일 후"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)시간 \(minutes)분 후" : "\(hours)시간 후"
        }
        return "\(max(minutes, 1))분 후"
    }

    private func absoluteReset(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(f.string(from: date))에 리셋"
    }
}
