import SwiftUI

// MARK: - Stage 1

/// The first screen anyone sees, and therefore the whole first impression.
///
/// It asks for nothing. Three cards say what the thing is, one of them names
/// Signal outright — a promise that arrives without its requirement is a promise
/// the owner discovers is false two screens later — and a closing line sets the
/// answer time *before* the owner has ever waited for one. The only commitment
/// on the screen is "Get started".
struct WelcomeStage: View {
    let titles: [String]
    let model: SetupModel

    @Environment(AppModel.self) private var app
    @State private var isExplaining = false

    var body: some View {
        StageShell(
            stageTitles: titles,
            currentIndex: SetupModel.Stage.welcome.rawValue,
            glyph: "waveform",
            title: "Talk to Mynah from your phone.",
            subtitle: "Send it a voice note and it answers out loud, using what it "
                + "remembers about you."
        ) {
            VStack(alignment: .leading, spacing: s4) {
                ForEach(WelcomePoint.all) { point in
                    MynahCard {
                        VStack(alignment: .leading, spacing: s2) {
                            Text(point.title)
                                .mynahFont(.title2)
                                .foregroundStyle(Palette.ink.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(point.body)
                                .mynahFont(.body)
                                .foregroundStyle(Palette.ink.secondary)
                                .mynahProse()
                        }
                    }
                }
            }
            .frame(maxWidth: MynahWidth.stageColumn)
        } actions: {
            // On a first run, "What is this?" is the escape hatch's slot and it
            // leads somewhere: a sheet inside the app. Sending a first-time
            // owner out to a browser is how you lose them before the second
            // screen.
            //
            // On a *restart* the slot goes to "Never mind" instead, because an
            // owner who pressed "Change" in Settings out of curiosity would
            // otherwise be forced to re-pick a brain and walk the whole flow
            // again with no way back. The explainer is still reachable from the
            // second card's copy and from Settings; being stuck is not.
            ActionRow(
                quietTitle: app.canCancelSetupRestart ? "Never mind" : "What is this?",
                quietAction: {
                    if app.canCancelSetupRestart {
                        app.cancelSetupRestart()
                    } else {
                        isExplaining = true
                    }
                }
            ) {
                MynahButton("Get started", isDefault: true) { model.advance() }
            }
        }
        .sheet(isPresented: $isExplaining) {
            WhatIsMynahSheet { isExplaining = false }
        }
    }
}

// MARK: - Copy

/// The three things worth knowing before anything is asked of the owner.
///
/// Held as data rather than three inlined cards because this screen is almost
/// entirely copy, and copy is easier to weigh when it sits together. Three is
/// the count: a fourth card would turn a welcome into a feature list.
private struct WelcomePoint: Identifiable {
    let id: String
    let title: String
    let body: String

    static let all: [WelcomePoint] = [
        WelcomePoint(
            id: "signal",
            title: "You talk to it in Signal",
            // Signal is named here, not later. It is the one thing the owner has
            // to already have — or install — for any of the rest to be true.
            body: "Signal is a free messaging app. You record a voice note, send it, "
                + "and Mynah answers out loud — the same as messaging a friend. If "
                + "Signal isn't on your phone yet, install it before you start."
        ),
        WelcomePoint(
            id: "memory",
            title: "It remembers what matters to you",
            body: "Mynah keeps what you tell it and brings it back when it's useful, so "
                + "you don't have to repeat yourself. You can read everything it "
                + "remembers, and delete any of it, whenever you like."
        ),
        WelcomePoint(
            id: "here",
            title: "It runs here, on this Mac",
            // Foreshadows stage 2 without pre-empting it. "Where it thinks is your
            // choice" is the promise the brain screen then keeps.
            body: "Mynah answers from this machine and keeps answering after you close "
                + "this window. Where it does its thinking is your choice — that's the "
                + "next screen."
        )
    ]
}

// MARK: - What is this?

/// The long answer, in the app.
///
/// Six plain sections, no product names for anything internal, no links out. An
/// owner who clicks "What is this?" is uncertain; handing them a browser tab at
/// that moment is handing them somewhere else to be.
struct WhatIsMynahSheet: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What Mynah is")
                .mynahFont(.title1)
                .foregroundStyle(Palette.ink.primary)
                .accessibilityAddTraits(.isHeader)

            ScrollView {
                VStack(alignment: .leading, spacing: s7) {
                    ForEach(ExplainerSection.all) { section in
                        VStack(alignment: .leading, spacing: s2) {
                            Text(section.title)
                                .mynahFont(.title3)
                                .foregroundStyle(Palette.ink.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                            Text(section.body)
                                .mynahFont(.body)
                                .foregroundStyle(Palette.ink.secondary)
                                .mynahProse()
                        }
                    }
                }
                .padding(.vertical, s6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)

            ActionRow {
                MynahButton("Done", action: onClose)
                    // Escape closes it. A modal explainer with no keyboard way out
                    // is a trap, and this one has nothing to confirm.
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, s5)
        }
        .padding(s8)
        .frame(width: 560, height: 560)
        .background(Palette.surface.overlay)
    }
}

private struct ExplainerSection: Identifiable {
    let id: String
    let title: String
    let body: String

    static let all: [ExplainerSection] = [
        ExplainerSection(
            id: "what",
            title: "A private assistant that lives on this Mac",
            body: "Mynah runs on this computer — the one in front of you. There's no "
                + "website, no account to create, and nobody else's machine involved "
                + "unless you choose one on the next screen."
        ),
        ExplainerSection(
            id: "signal",
            title: "You talk to it in Signal",
            body: "Signal is a free messaging app you install on your phone. Send Mynah "
                + "a voice note the way you'd send one to a friend and it answers out "
                + "loud. There's nothing else to install, and no separate Mynah app for "
                + "your phone."
        ),
        ExplainerSection(
            id: "memory",
            title: "It remembers what you tell it",
            body: "Over time Mynah builds up a picture of what matters to you — how you "
                + "like things done, who's who, what you're working on — and brings it "
                + "back when it's useful. Everything it remembers is listed in the app, "
                + "and you can delete any of it."
        ),
        ExplainerSection(
            id: "where",
            title: "You decide where its thinking happens",
            body: "On the next screen you pick what does Mynah's thinking. One choice "
                + "keeps everything you say on this Mac. The others send what you say to "
                + "a company such as Google or Anthropic, which is usually faster and "
                + "sometimes free. Whichever you pick, you can change it later."
        ),
        ExplainerSection(
            id: "time",
            title: "It thinks before it answers",
            body: "Mynah thinks before it speaks and looks through what it remembers. "
                + "Twenty seconds is normal, and a question that needs a lot of "
                + "remembering can take a minute. Nothing has gone wrong while you're "
                + "waiting."
        ),
        ExplainerSection(
            id: "web",
            title: "It can look things up",
            body: "If a question needs something Mynah doesn't already know, it can "
                + "search the web and use what it finds in its answer."
        )
    ]
}

// MARK: - Previews

#Preview("Welcome") {
    WelcomePreviewPair {
        WelcomeStage(titles: SetupModel.Stage.allCases.map(\.title), model: SetupModel())
            .environment(WelcomePreviewApp.model)
    }
    .frame(width: 1440, height: 860)
}

#Preview("Welcome — larger text") {
    WelcomePreviewPair {
        WelcomeStage(titles: SetupModel.Stage.allCases.map(\.title), model: SetupModel())
            .environment(WelcomePreviewApp.model)
            .mynahTextSize(.larger)
    }
    .frame(width: 1440, height: 940)
}

/// A throwaway `AppModel` so a preview never rewrites the real app's settings on
/// this machine — and so the stage's `@Environment(AppModel.self)` resolves.
@MainActor
private enum WelcomePreviewApp {
    static let model = AppModel(
        defaults: UserDefaults(suiteName: "mynah.welcome.preview") ?? .standard
    )
}

#Preview("What is this?") {
    WelcomePreviewPair {
        WhatIsMynahSheet {}
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.surface.canvas)
    }
    .frame(width: 1200, height: 620)
}

/// Both schemes at once. Every screen in this app has to be correct in dark
/// mode, and the only reliable way to keep it that way is to look at it every
/// time the light one changes.
private struct WelcomePreviewPair<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            content.environment(\.colorScheme, .light)
            content.environment(\.colorScheme, .dark)
        }
    }
}
