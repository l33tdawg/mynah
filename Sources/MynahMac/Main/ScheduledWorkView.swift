import Observation
import SageVoiceCore
import SwiftUI

// MARK: - What runs on a clock

/// The list, and the two ways out of it.
///
/// **The owner, 22 September 2026: "it needs to be set up in the app itself then
/// its just available to the user in conversation bro"** — and, a sentence
/// later, *"so that way user can go in and turn off tasks or kill those poll
/// jobs."* Both halves live here rather than in a thread he has to scroll back
/// through: the conversation is how work gets onto the clock, and this is where
/// it is read, switched off, or killed.
///
/// **Two controls, because they are two intentions.** The switch is *hold* —
/// stop for now, keep the wording, and the clock restarts from the moment it is
/// switched back on. The cross is *kill* — the request is gone and so is what it
/// said. Collapsing them into one control, which the first draft of this screen
/// did, would make the only way to hold a standing request for a fortnight be to
/// delete it and remember what it said.
@MainActor
@Observable
final class ScheduledWorkModel {

    private(set) var work: ScheduledWork

    /// The last write that failed, in words, or `nil`.
    ///
    /// Kept rather than logged: a switch that did not take has to say so, or the
    /// owner watches a poll they think they stopped keep running.
    private(set) var trouble: String?

    private let fileURL: URL

    /// Four seconds.
    ///
    /// The list can be changed from the phone — by asking, or with `//schedule`
    /// — and the owner walking to the Mac should not be reading yesterday's copy
    /// of it. One small file read four times a minute is nothing next to the
    /// node traffic this window already makes, and it is the difference between
    /// this screen being the truth and being a cache.
    static let refreshInterval: Duration = .seconds(4)

    init(fileURL: URL = ScheduledWork.defaultFileURL()) {
        self.fileURL = fileURL
        self.work = ScheduledWork.load(from: fileURL)
    }

    /// Reads once, then keeps reading until the caller's task is cancelled —
    /// which SwiftUI does when the pane goes away, so nothing polls while the
    /// owner is somewhere else in the app. The shape `TaskBoardModel.follow()`
    /// uses.
    func follow() async {
        while !Task.isCancelled {
            reload()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    func reload() {
        work = ScheduledWork.load(from: fileURL)
    }

    /// Holds it, or lets it run again. See `ScheduledWork.resume` for why the
    /// clock starts again at the moment it comes back on.
    func setEnabled(_ isEnabled: Bool, number: Int) {
        modify { work in
            if isEnabled {
                _ = work.resume(number: number, now: Date())
            } else {
                _ = work.pause(number: number)
            }
        }
    }

    /// Stops it and forgets the wording.
    func kill(number: Int) {
        modify { work in _ = work.remove(number: number) }
    }

    /// - Returns: whether it was kept, so the form knows to clear itself.
    @discardableResult
    func add(instruction: String, cadence: ScheduleCadence) -> Bool {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            trouble = "Say what to do, and it will be kept."
            return false
        }
        var updated = ScheduledWork.load(from: fileURL)
        guard updated.tasks.count < ScheduledWork.maximumTasks else {
            trouble = "That is as many as Mynah keeps (\(ScheduledWork.maximumTasks)). "
                + "Kill one first."
            return false
        }
        _ = updated.add(instruction: trimmed, cadence: cadence)
        return save(updated)
    }

    /// Every action goes through here, so nothing writes a list it read before
    /// somebody changed it from the phone — and every failure says the same
    /// thing in the same place.
    private func modify(_ change: (inout ScheduledWork) -> Void) {
        var updated = ScheduledWork.load(from: fileURL)
        let before = updated
        change(&updated)
        guard updated != before else { return }
        _ = save(updated)
    }

    private func save(_ updated: ScheduledWork) -> Bool {
        do {
            try updated.save(to: fileURL)
        } catch {
            trouble = "That didn't save, so nothing changed: \(error.localizedDescription)"
            return false
        }
        trouble = nil
        work = updated
        return true
    }
}

// MARK: - The screen

/// One destination: what Mynah does when nobody is talking to it.
struct ScheduledWorkView: View {

    @State private var model: ScheduledWorkModel

    /// The draft being typed. Held here rather than in the model because it is
    /// not state this appliance owns — it is a half-finished sentence.
    @State private var instruction = ""
    @State private var repeats = Repetition.daily
    @State private var time = ScheduledWorkView.defaultTime
    @State private var weekday = 2
    @State private var minutes = 30

    init() {
        _model = State(initialValue: ScheduledWorkModel())
    }

    /// For the render harness, which has a fixture rather than a file.
    init(model: ScheduledWorkModel) {
        _model = State(initialValue: model)
    }

    enum Repetition: String, CaseIterable, Identifiable {
        case daily
        case weekly
        case interval

        var id: String { rawValue }

        var title: String {
            switch self {
            case .daily: return "Every day"
            case .weekly: return "Every week"
            case .interval: return "Every few minutes"
            }
        }
    }

    /// 08:00, because a standing request is usually a morning one and the picker
    /// has to open somewhere.
    static var defaultTime: Date {
        var parts = DateComponents()
        parts.hour = 8
        parts.minute = 0
        return Calendar.current.date(from: parts) ?? Date()
    }

    var body: some View {
        ScrollView {
            pane
        }
        .scrollBounceBehavior(.basedOnSize)
        .task { await model.follow() }
    }

    /// The pane without its scroll view, which is the shape a render harness can
    /// draw: `ImageRenderer` produces an empty image for a `ScrollView`, so a
    /// screenshot of this screen has to be taken one layer in. See
    /// `ScheduledWorkRenderHarness`.
    var pane: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            list.padding(.top, s7)
            composer.padding(.top, s6)
            if let trouble = model.trouble {
                Text(trouble)
                    .mynahFont(.label)
                    .foregroundStyle(Palette.state.critical)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, s3)
                    .padding(.horizontal, s2)
            }
            footnote.padding(.top, s6)
        }
        .frame(maxWidth: MynahWidth.settings, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, s8)
        .padding(.top, s7)
        .padding(.bottom, s9)
        .background(Palette.surface.canvas)
    }

    // MARK: Heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: s4) {
            Text("What Mynah does on a clock")
                .mynahFont(.title1)
                .foregroundStyle(Palette.ink.primary)
                .accessibilityAddTraits(.isHeader)
            Text(
                "Work that runs by itself at a time you set, and messages you here — whether "
                    + "or not you are talking to it. Ask for one in the conversation "
                    + "(\u{201C}check my inbox every morning at 8\u{201D}) and it arrives in this "
                    + "list."
            )
            .mynahFont(.body)
            .foregroundStyle(Palette.ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: The list

    private var list: some View {
        SettingsGroup(
            "Scheduled",
            caption: model.work.tasks.isEmpty
                ? nil
                : "Switching one off holds it: the clock starts again when you switch it back "
                    + "on. The cross stops it for good."
        ) {
            let numbered = model.work.numbered()
            if numbered.isEmpty {
                empty
            } else {
                ForEach(Array(numbered.enumerated()), id: \.element.task.id) { index, entry in
                    if index > 0 {
                        Rectangle()
                            .fill(Palette.line.hairline)
                            .frame(height: 1)
                    }
                    row(number: entry.number, task: entry.task)
                }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: s2) {
            Text("Nothing is on a clock yet")
                .mynahFont(.bodyEmphasis)
                .foregroundStyle(Palette.ink.primary)
            Text("Set one up below, or ask for it in the conversation.")
                .mynahFont(.label)
                .foregroundStyle(Palette.ink.secondary)
        }
        .padding(.vertical, s3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(number: Int, task: ScheduledTask) -> some View {
        HStack(alignment: .top, spacing: s4) {
            Text("\(number)")
                .mynahFont(.label)
                .monospacedDigit()
                .foregroundStyle(Palette.ink.tertiary)
                .frame(minWidth: 12, alignment: .trailing)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: s1) {
                Text(task.instruction)
                    .mynahFont(.body)
                    // Held work keeps a readable ink. `tertiary` sits below the
                    // floor this palette sets for sentences — it is for marks
                    // and metadata — and the word "held" on the line under it
                    // already says which one is stopped. A request the owner is
                    // deciding whether to restart has to be legible.
                    .foregroundStyle(task.isEnabled ? Palette.ink.primary : Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail(for: task))
                    .mynahFont(.label)
                    .foregroundStyle(Palette.ink.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: Binding(
                get: { task.isEnabled },
                set: { model.setEnabled($0, number: number) }
            ))
            .labelsHidden()
            .mynahToggle()
            .help(task.isEnabled ? "Hold it — stop for now, keep the wording" : "Let it run again")
            .accessibilityLabel("Hold \(ScheduledWork.flattened(task.instruction, limit: 60))")

            Button {
                model.kill(number: number)
            } label: {
                Image(systemName: "xmark")
                    .mynahFont(.label)
                    .foregroundStyle(Palette.ink.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Kill it — it stops, and the wording is forgotten")
            .accessibilityLabel("Kill \(ScheduledWork.flattened(task.instruction, limit: 60))")
        }
        .padding(.vertical, s3)
    }

    /// "every day at 08:00 · ran 2 minutes ago", or the held state said plainly.
    private func detail(for task: ScheduledTask) -> String {
        var parts = [task.cadence.spoken]
        if !task.isEnabled {
            parts.append("held")
        } else if let last = task.lastRunAt {
            parts.append("ran \(last.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("hasn't run yet")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Setting one up

    private var composer: some View {
        SettingsGroup(
            "Set one up",
            caption: "Mynah messages you here when it runs, so this is for work whose answer "
                + "you want — not for a reminder to do something yourself."
        ) {
            VStack(alignment: .leading, spacing: s4) {
                TextField("what should I do?", text: $instruction)
                    .textFieldStyle(.plain)
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.primary)
                    .padding(.horizontal, s4)
                    .padding(.vertical, 9)
                    .background(Palette.surface.well, in: RoundedRectangle.mynah(r.control))
                    .mynahBorder(r.control)
                    .accessibilityLabel("What should Mynah do")

                HStack(spacing: s4) {
                    Picker("", selection: $repeats) {
                        ForEach(Repetition.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)

                    switch repeats {
                    case .daily:
                        DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.field)
                    case .weekly:
                        Picker("", selection: $weekday) {
                            ForEach(1...7, id: \.self) { day in
                                Text(ScheduleCadence.weekdayName(day)).tag(day)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.field)
                    case .interval:
                        Picker("", selection: $minutes) {
                            ForEach([5, 10, 15, 30, 60, 120], id: \.self) { value in
                                Text("every \(ScheduleCadence.spokenInterval(value))").tag(value)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }

                    Spacer(minLength: 0)

                    Button("Add") {
                        if model.add(instruction: instruction, cadence: draftCadence) {
                            instruction = ""
                        }
                    }
                    .buttonStyle(MynahButtonStyle(.primary))
                    .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.vertical, s3)
        }
    }

    /// What the three controls above mean, as one value the store — and the
    /// daemon, which reads the same file — already understands.
    private var draftCadence: ScheduleCadence {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let hour = parts.hour ?? 8
        let minute = parts.minute ?? 0
        switch repeats {
        case .daily: return .daily(hour: hour, minute: minute)
        case .weekly: return .weekly(weekday: weekday, hour: hour, minute: minute)
        case .interval: return .every(minutes: minutes)
        }
    }

    private var footnote: some View {
        Text(
            "The same work can be set up from your phone — ask for it, or send "
                + "\u{201C}//schedule every day at 8am: check my inbox\u{201D}. Mynah holds "
                + "\(ScheduledWork.maximumTasks) of these."
        )
        .mynahFont(.label)
        .foregroundStyle(Palette.ink.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, s2)
    }
}
