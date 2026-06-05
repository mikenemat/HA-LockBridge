import SwiftUI

struct StatusView: View {
    @ObservedObject var viewModel: StatusViewModel

    var body: some View {
        VStack(spacing: 18) {
            Text("HA-LockBridge")
                .font(.title2.bold())

            Group {
                switch viewModel.display {
                case .initializing:
                    initializingView
                case .waitingForFirstPair:
                    waitingView
                case .pendingRequest(_, let clientName):
                    pendingView(clientName: clientName)
                case .approved(let n):
                    resultView(systemImage: "checkmark.circle.fill", color: .green,
                               title: "Paired!", countdown: n)
                case .denied(let n):
                    resultView(systemImage: "xmark.circle.fill", color: .red,
                               title: "Pairing denied", countdown: n)
                case .expired(let n):
                    resultView(systemImage: "clock.badge.exclamationmark.fill", color: .orange,
                               title: "Pairing request expired", countdown: n)
                case .briefStatus(let n):
                    briefStatusView(countdown: n)
                case .debug(let accessories, let pairedCount):
                    debugView(accessories: accessories, pairedCount: pairedCount)
                case .resetConfirm:
                    resetConfirmView
                case .hidden:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity)

            Spacer(minLength: 0)

            Divider()
            HStack(spacing: 6) {
                Image(systemName: viewModel.pairedCount > 0 ? "person.fill.checkmark" : "person.fill.xmark")
                    .imageScale(.small)
                Text(viewModel.pairedCount > 0 ? "paired" : "not paired")
                Text("·").foregroundColor(.secondary)
                Image(systemName: "lock.fill").imageScale(.small)
                Text("\(viewModel.accessoryCount) locks tracked")
            }
            .font(.caption.monospaced())
            .foregroundColor(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: viewModel.display)
    }

    // MARK: - Sub-views

    private var initializingView: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.5).padding(8)
            Text("Starting up…").font(.body)
        }
    }

    private var waitingView: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text("Waiting for Home Assistant to pair")
                .font(.headline)
            Text("This bridge is advertising itself on your network. In Home Assistant, open **Settings → Devices & Services** — it should appear as a discovered integration.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    private func pendingView(clientName: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)
            Text("Pair request")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text(clientName)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Deny", role: .destructive) {
                    viewModel.denyTapped()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.bordered)

                Button("Approve") {
                    viewModel.approveTapped()
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
    }

    private func resultView(systemImage: String, color: Color, title: String, countdown: Int) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundColor(color)
            Text(title)
                .font(.headline)
            Text("Window will hide in \(countdown)…")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func briefStatusView(countdown: Int) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 44))
                .foregroundColor(.green)
            Text("Bridge is running")
                .font(.headline)
            Text("Window will hide in \(countdown)…")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func debugView(accessories: [AccessoryState], pairedCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Live activity header — most-recent-first, updates as events
            // arrive via @Published recentInteractions on the view model.
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "arrow.left.arrow.right")
                    Text("Recent activity").font(.headline)
                    Spacer()
                }
                if viewModel.recentInteractions.isEmpty {
                    Text("(no activity yet)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 22)
                } else {
                    ForEach(viewModel.recentInteractions) { event in
                        interactionRow(event)
                    }
                }
            }

            Divider()

            // "Lock Errors/Warnings" — surfaces the rough edges that the
            // bridge handles transparently (background-write retries,
            // reachability gaps) so the user can see when the system
            // is healing things on their behalf. Empty state shows
            // "(no warnings)" so users know it's working as intended,
            // not a missing feature.
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Lock Errors/Warnings").font(.headline)
                    Spacer()
                }
                if viewModel.recentLockEvents.isEmpty {
                    Text("(no warnings)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 22)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(viewModel.recentLockEvents) { event in
                                lockEventRow(event)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Cap at 240pt (was 140 in 0.5.3) — paired with the
                    // window-height bump in 0.5.5, this lets ~10+ event
                    // rows show at once when populated. The empty state
                    // takes the if-branch above and skips the ScrollView
                    // entirely, so this cap is "free" when there are no
                    // warnings to show.
                    .frame(maxHeight: 240)
                }
            }

            Divider()

            HStack {
                Image(systemName: "stethoscope")
                Text("Locks tracked (\(accessories.count))").font(.headline)
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if accessories.isEmpty {
                        Text("(none discovered yet)")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(accessories, id: \.id) { acc in
                            DisclosureGroup {
                                Text(Self.jsonString(for: acc))
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 22)
                                    .padding(.vertical, 4)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "lock.fill").imageScale(.small)
                                    Text(acc.name).font(.callout)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            // Live HA connectivity. `pairedCount` below is config-level
            // (does HA have a token at all); this line is wire-level (is HA
            // currently holding a WebSocket open). Reads viewModel directly
            // so it updates in real time as HA connects/disconnects while
            // this page is open.
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .imageScale(.small)
                    .foregroundColor(viewModel.connectedClients.isEmpty ? .red : .green)
                if viewModel.connectedClients.isEmpty {
                    Text("HA not connected")
                } else if viewModel.connectedClients.count == 1 {
                    Text("HA connected — \(viewModel.connectedClients[0])")
                } else {
                    Text("HA connected (\(viewModel.connectedClients.count)) — \(viewModel.connectedClients.joined(separator: ", "))")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
            Text(pairedCount > 0 ? "Bridge is paired with Home Assistant." : "No Home Assistant paired.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Close") { viewModel.dismissOverlay() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func interactionRow(_ event: InteractionLog.Event) -> some View {
        HStack(spacing: 6) {
            // .command arrives at the bridge from HA; .stateUpdate leaves
            // the bridge for HA. The arrow direction echoes that flow.
            Image(systemName: event.direction == .command ? "arrow.down.left" : "arrow.up.right")
                .imageScale(.small)
                .foregroundColor(event.direction == .command ? .blue : .green)
                .frame(width: 16)
            Text(event.accessoryName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(event.detail)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(Self.interactionTimeFormatter.string(from: event.timestamp))
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
            Text(event.clientAddress)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    /// Render one lock health event. Color + icon convey severity at a
    /// glance: orange triangle for in-progress / resolved-successfully,
    /// red for revert (the only "user actually lost the operation"
    /// outcome). Reachability gaps follow the same color scheme — open
    /// gaps are orange (system is currently degraded but healing-eligible),
    /// closed gaps render in neutral text since they're historical.
    private func lockEventRow(_ event: LockEventLog.Event) -> some View {
        let (icon, color, summary, detail) = Self.formatLockEvent(event)
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundColor(color)
                .frame(width: 16)
            Text(event.accessoryName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(summary)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(detail)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
            Text(Self.interactionTimeFormatter.string(from: event.timestamp))
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
        }
    }

    /// Returns (icon, color, leading-summary, trailing-detail) for a
    /// lock event. Split out so the row body stays declarative.
    private static func formatLockEvent(_ event: LockEventLog.Event) -> (String, Color, String, String) {
        switch event.kind {
        case .writeRetry(let action, let attempts, let durationMs, let outcome):
            let durStr = formatDurationMs(durationMs)
            switch outcome {
            case .ongoing:
                return ("hourglass",
                        .orange,
                        "retrying \(action) — attempt \(attempts)",
                        durStr)
            case .succeeded:
                return ("checkmark.circle",
                        .orange,
                        "delayed \(action) — succeeded (\(attempts) attempt\(attempts == 1 ? "" : "s"))",
                        durStr)
            case .reverted:
                return ("xmark.octagon",
                        .red,
                        "failed \(action) — reverted (\(attempts) attempt\(attempts == 1 ? "" : "s"))",
                        durStr)
            case .satisfiedExternally:
                return ("arrow.triangle.branch",
                        .secondary,
                        "delayed \(action) — satisfied externally",
                        durStr)
            }
        case .unreachableGap(let durationSec):
            if let d = durationSec {
                return ("antenna.radiowaves.left.and.right",
                        .secondary,
                        "unreachable — recovered",
                        formatDurationSec(d))
            } else {
                let elapsed = Date().timeIntervalSince(event.timestamp)
                return ("antenna.radiowaves.left.and.right.slash",
                        .orange,
                        "currently unreachable",
                        formatDurationSec(elapsed))
            }
        }
    }

    private static func formatDurationMs(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let secs = Double(ms) / 1000.0
        return String(format: "%.1fs", secs)
    }

    private static func formatDurationSec(_ s: Double) -> String {
        if s < 60 { return String(format: "%.1fs", s) }
        let mins = Int(s / 60)
        let rem = Int(s.truncatingRemainder(dividingBy: 60))
        return "\(mins)m\(rem)s"
    }

    private static let interactionTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static func jsonString(for accessory: AccessoryState) -> String {
        guard let data = try? jsonEncoder.encode(accessory),
              let string = String(data: data, encoding: .utf8) else {
            return "(encode failed)"
        }
        return string
    }

    private var resetConfirmView: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundColor(.orange)
            Text("Reset pairing?").font(.headline)
            Text("This wipes all paired Home Assistant clients on the bridge. Connected HAs will lose access immediately and need to re-pair.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            HStack(spacing: 12) {
                Button("Cancel") { viewModel.cancelResetTapped() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .buttonStyle(.bordered)
                Button("Reset", role: .destructive) { viewModel.confirmResetTapped() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
