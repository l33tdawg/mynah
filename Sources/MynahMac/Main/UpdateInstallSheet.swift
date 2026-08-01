import SageVoiceCore
import SwiftUI

/// A new Mynah arriving, while it arrives.
///
/// The four steps are listed the whole time rather than replaced one at a time,
/// and that is the point of the card. What an owner wants to know while half a
/// gigabyte comes down a domestic line is not only how far it has got but what
/// is going to happen to their Mac afterwards — and the answer, visible before
/// the download finishes, is that the signature is checked before anything is
/// put in place.
///
/// Modelled on QuietType's update card, which solved the same problem for the
/// same owner: a step list, a bar with real byte counts under it, and one
/// button at the end.
struct UpdateInstallSheet: View {

    /// The version being fetched, for the title. Known before the download
    /// starts because the row that opened this already asked.
    let version: String
    let state: SettingsModel.InstallState

    var onStop: () -> Void
    var onClose: () -> Void
    var onRestart: () -> Void
    var onOpenReleases: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: s5) {
            header
            steps
            if case .working(let progress) = state {
                bar(progress)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(s8)
        .frame(width: 480)
        .frame(minHeight: 360)
        .background(Palette.surface.overlay)
        .mynahAnimation(Motion.snap, value: state)
        // Escape closes it only when nothing is being changed. A stray keypress
        // must not look like it stopped an install that is still running.
        .onExitCommand { if !state.isWorking { onClose() } }
    }

    // MARK: The top

    private var header: some View {
        VStack(alignment: .leading, spacing: s3) {
            Text(title)
                .mynahFont(.title2)
                .foregroundStyle(Palette.ink.primary)
            Text(explanation)
                .mynahFont(.callout)
                .foregroundStyle(explanationTone)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Mynah 1.2.5", or just "Mynah" on the one path that can reach this card
    /// without a version — somebody pressing Update in the same instant the
    /// check's answer is being replaced.
    private var subject: String {
        version.isEmpty ? "Mynah" : "Mynah \(version)"
    }

    private var title: String {
        switch state {
        case .working(let progress):
            switch progress.stage {
            case .finding: return "Looking for \(subject)"
            case .downloading: return "Downloading \(subject)"
            case .checking: return "Checking \(subject)"
            case .installing: return "Installing \(subject)"
            case .installed: return "\(subject) is installed"
            }
        case .installed(let installed):
            return "Mynah \(installed) is installed"
        case .failed(let problem):
            if case .alreadyCurrent = problem { return "You are up to date" }
            if case .cancelled = problem { return "Stopped" }
            return "Mynah didn't replace itself"
        }
    }

    private var explanation: String {
        switch state {
        case .working(let progress):
            switch progress.stage {
            case .installing:
                return "Nothing you are doing is interrupted. The copy you were running is kept, "
                    + "in case the new one turns out not to work."
            default:
                return "Leave Mynah open. It keeps answering your phone while this happens, and "
                    + "nothing is replaced until the download has been checked."
            }
        case .installed:
            return "It is on this Mac and it is not running yet. Restart when it suits you — "
                + "Mynah keeps answering your phone on the version you have until you do."
        case .failed(let problem):
            return problem.spokenDescription
        }
    }

    private var explanationTone: Color {
        if case .failed(let problem) = state, !isBenign(problem) { return Palette.state.critical }
        return Palette.ink.secondary
    }

    /// "Up to date" and "you stopped it" arrive through the failure path
    /// because nothing was installed, but neither is anything going wrong.
    private func isBenign(_ problem: UpdateInstallProblem) -> Bool {
        switch problem {
        case .alreadyCurrent, .cancelled, .couldNotRestart: return true
        default: return false
        }
    }

    // MARK: The four steps

    private var steps: some View {
        VStack(alignment: .leading, spacing: s4) {
            ForEach(UpdateInstallStage.steps, id: \.rawValue) { stage in
                HStack(alignment: .firstTextBaseline, spacing: s4) {
                    mark(for: stage)
                        .frame(width: 16)
                    Text(stage.title)
                        .mynahFont(reached(stage) ? .bodyEmphasis : .body)
                        .foregroundStyle(colour(for: stage))
                    Spacer(minLength: s4)
                    if stage == .downloading, let transfer = transfer {
                        Text(transfer.spokenDescription)
                            .mynahFont(.label)
                            .monospacedDigit()
                            .foregroundStyle(Palette.ink.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface.sunken, in: RoundedRectangle.mynah(r.card))
        .mynahBorder(r.card)
    }

    @ViewBuilder
    private func mark(for stage: UpdateInstallStage) -> some View {
        if stopped(before: stage) {
            // Never started, and now never will. A dash rather than an empty
            // circle, which reads as "still to come".
            Image(systemName: "minus")
                .mynahIcon(.inline)
                .foregroundStyle(Palette.ink.quaternary)
        } else if done(stage) {
            Image(systemName: "checkmark")
                .mynahIcon(.inline)
                .foregroundStyle(Palette.state.good)
        } else if current(stage) {
            ProgressView().controlSize(.small).tint(Palette.accent.fill)
        } else {
            Circle()
                .strokeBorder(Palette.line.strong, lineWidth: 1)
                .frame(width: 8, height: 8)
        }
    }

    private var stage: UpdateInstallStage? {
        if case .working(let progress) = state { return progress.stage }
        if case .installed = state { return .installed }
        return nil
    }

    private var transfer: UpdateTransfer? {
        if case .working(let progress) = state { return progress.transfer }
        return nil
    }

    private func current(_ step: UpdateInstallStage) -> Bool { stage == step }

    private func done(_ step: UpdateInstallStage) -> Bool {
        guard let stage else { return false }
        return step < stage
    }

    private func reached(_ step: UpdateInstallStage) -> Bool {
        guard let stage else { return false }
        return step <= stage
    }

    /// A step the run never got to, because it stopped first.
    private func stopped(before step: UpdateInstallStage) -> Bool {
        if case .failed = state { return !done(step) }
        return false
    }

    private func colour(for step: UpdateInstallStage) -> Color {
        if current(step) { return Palette.ink.primary }
        return done(step) ? Palette.ink.secondary : Palette.ink.tertiary
    }

    // MARK: The bar

    @ViewBuilder
    private func bar(_ progress: UpdateInstallProgress) -> some View {
        // A determinate bar only while there is a real number behind it.
        // Everything either side of the download is a few seconds of work with
        // no measurable middle, and a bar that jumps to an invented 80% is a
        // lie about how much is left.
        if let fraction = progress.transfer?.fraction, progress.stage == .downloading {
            ProgressView(value: fraction).progressViewStyle(.linear)
        } else {
            ProgressView().progressViewStyle(.linear)
        }
    }

    // MARK: The bottom

    @ViewBuilder
    private var footer: some View {
        switch state {
        case .working(let progress):
            // Stop is offered only while nothing on disk has been touched. Once
            // the swap starts there is no safe moment to interrupt it, so the
            // button goes rather than becoming one that lies.
            ActionRow(
                quietTitle: progress.stage < .installing ? "Stop" : nil,
                quietAction: progress.stage < .installing ? onStop : nil,
                helper: progress.stage < .installing
                    ? nil : "Nearly done — this part is quick."
            ) { EmptyView() }

        case .installed:
            ActionRow(quietTitle: "Later", quietAction: onClose) {
                MynahButton("Restart Mynah", isDefault: true, action: onRestart)
            }

        case .failed(let problem):
            ActionRow(quietTitle: "Close", quietAction: onClose) {
                if problem.offersThePage {
                    MynahButton("Open the releases page", kind: .secondary, action: onOpenReleases)
                } else {
                    EmptyView()
                }
            }
        }
    }
}

#Preview("Downloading") {
    UpdateInstallSheet(
        version: "1.2.5",
        state: .working(UpdateInstallProgress(
            stage: .downloading,
            transfer: UpdateTransfer(received: 241_000_000, expected: 582_000_000)
        )),
        onStop: {}, onClose: {}, onRestart: {}, onOpenReleases: {}
    )
}

#Preview("Installed") {
    UpdateInstallSheet(
        version: "1.2.5",
        state: .installed("1.2.5"),
        onStop: {}, onClose: {}, onRestart: {}, onOpenReleases: {}
    )
}

#Preview("Refused") {
    UpdateInstallSheet(
        version: "1.2.5",
        state: .failed(.differentSigner(found: "ABCDE12345")),
        onStop: {}, onClose: {}, onRestart: {}, onOpenReleases: {}
    )
}
