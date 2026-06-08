import SwiftUI

struct StatusView: View {
    @ObservedObject var viewModel: StatusViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("HA-LockBridge")
                .font(.title2.bold())

            // Inline pair-approval banner — shown above whichever main
            // screen is up, in both waiting and paired states (a second HA
            // can request pairing while the first is connected).
            if let pending = viewModel.pendingRequest {
                pairBanner(pending)
            }

            Group {
                switch viewModel.display {
                case .initializing:
                    initializingView
                case .waiting:
                    waitingView
                case .debug:
                    debugView
                case .resetConfirm:
                    resetConfirmView
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
        .animation(.easeInOut(duration: 0.2), value: viewModel.pendingRequest)
    }

    // MARK: - Pair banner (shown inline, not as a separate screen)

    private func pairBanner(_ pending: StatusViewModel.PendingPair) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(.accentColor)
                Text("Pair request from")
                    .foregroundColor(.secondary)
                Text(pending.clientName)
                    .font(.body.bold())
            }
            HStack(spacing: 12) {
                Button("Deny", role: .destructive) { viewModel.denyTapped() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .buttonStyle(.bordered)
                Button("Approve") { viewModel.approveTapped() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Screens

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

            Divider().padding(.vertical, 4)
            controlBar
        }
    }

    private var debugView: some View {
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

            // "Lock Errors/Warnings" — surfaces the rough edges the bridge
            // handles transparently (write retries, reachability gaps).
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
                    .frame(maxHeight: 240)
                }
            }

            Divider()

            HStack {
                Image(systemName: "stethoscope")
                Text("Locks tracked (\(viewModel.accessories.count))").font(.headline)
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if viewModel.accessories.isEmpty {
                        Text("(none discovered yet)")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.accessories, id: \.id) { acc in
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
            .frame(maxHeight: 280)

            // Live HA connectivity (wire-level: is a WebSocket open now).
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

            Divider()
            controlBar
        }
    }

    /// Start-at-Login / Reset Pairing / Quit — the controls that used to live
    /// in the menu-bar dropdown, now inline since there's no tray icon.
    private var controlBar: some View {
        HStack(spacing: 12) {
            Toggle("Start at Login", isOn: Binding(
                get: { viewModel.loginItemEnabled },
                set: { _ in viewModel.toggleLoginItemTapped() }
            ))
            .toggleStyle(.switch)
            .disabled(!viewModel.loginItemAvailable)
            .font(.callout)

            Spacer()

            Button("Reset Pairing…", role: .destructive) { viewModel.resetTapped() }
                .buttonStyle(.bordered)
            Button("Quit") { viewModel.quitTapped() }
                .buttonStyle(.bordered)
        }
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

    // MARK: - Rows

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

    /// Render one lock health event. Color + icon convey severity at a glance.
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

    /// Returns (icon, color, leading-summary, trailing-detail) for a lock event.
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
}
