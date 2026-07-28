import SwiftUI

// MARK: - Stage 1

/// The first screen anyone sees, and therefore the whole first impression.
///
/// It asks for nothing. Four cards say what the thing is, the first of them
/// names Signal outright — a promise that arrives without its requirement is a
/// promise the owner discovers is false two screens later. The only commitment
/// on the screen is "Get started".
///
/// The headline used to be "Talk to Mynah from your phone", which is how you
/// reach it rather than what it is, and which the phone-linking stage already
/// says word for word. Two screens with one headline means one of them is
/// wasted, and this is the one that can afford to say the harder thing: what
/// this is *for*.
struct WelcomeStage: View {
    let titles: [String]
    let model: SetupModel

    @Environment(AppModel.self) private var app
    @State private var isExplaining = false

    var body: some View {
        StageShell(
            stageTitles: titles,
            currentIndex: SetupModel.Stage.welcome.rawValue,
            glyph: StageIllustration.mark(.welcome),
            title: "Mynah keeps track of your thinking.",
            // Assistant first, because everyone parses that instantly; the agents
            // are what make it different, not what make it understandable. "Out
            // loud, from your phone" is the medium and belongs after the point,
            // not in front of it.
            subtitle: "Tell it things, ask it things, and put your other agents to work — "
                + "out loud, from your phone."
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

/// The four things worth knowing before anything is asked of the owner.
///
/// Held as data rather than four inlined cards because this screen is almost
/// entirely copy, and copy is easier to weigh when it sits together.
///
/// Four is the count, and each one earns its place differently: one is the
/// requirement (Signal), two are what the thing is for, and one is where it
/// lives. Remembering and asking used to be two separate ideas on this screen
/// and are now one card, because they are one behaviour — it answers out of
/// what you already told it. A fifth card would turn a welcome into a feature
/// list.
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
        // Two verbs, one card. Owners were being told separately that it
        // remembers and that it answers questions, which reads as two features;
        // it is one thing, and the second half is only interesting *because* of
        // the first. "Ask it later" is what makes remembering worth anything.
        WelcomePoint(
            id: "memory",
            title: "Tell it things. Ask it things.",
            body: "Half-formed ideas, what you decided and why, something you want to come "
                + "back to on Thursday — say it and Mynah keeps it. Ask later and it answers "
                + "out of what you told it, and looks things up when the answer isn't yours "
                + "to begin with. You can read everything it remembers, and delete any of it."
        ),
        // The part nothing in this product used to admit.
        //
        // The appliance can already find the owner's other agents and hand work
        // to them — the tools are in the allowlist and the model is told it is
        // "the voice-operated manager of the owner's agent federation". But
        // nothing on any screen said so, so an owner used it as an assistant
        // with a good memory and never found the half that makes it different.
        //
        // Third rather than first, deliberately. "Agent manager" is accurate and
        // is jargon; leading with it makes this sound like infrastructure. The
        // two cards above are what someone already wants, and this is the thing
        // they did not know they could have.
        WelcomePoint(
            id: "agents",
            title: "It puts your other agents to work",
            // A sentence the owner could say out loud, rather than a description
            // of a capability. Nobody reads "supports delegation" and then knows
            // what to do with it; everybody reads the quoted line and does.
            body: "If you already run agents on SAGE, Mynah can find them by name and hand "
                + "them work. Say “ask my research agent to look into that” and it will — "
                + "then tell you what came back. If you don't run any, nothing here changes."
        ),
        WelcomePoint(
            id: "here",
            title: "It runs here, on this Mac",
            // Foreshadows stage 2 without pre-empting it. "Where it thinks is your
            // choice" is the promise the brain screen then keeps.
            //
            // What it deliberately does not say is that nothing leaves — a cloud
            // brain is offered on the next screen and recalled memories travel
            // with the question. "No account, no server of ours" is the strongest
            // claim that stays true whichever brain the owner picks.
            body: "Mynah answers from this machine and keeps answering after you close "
                + "this window. There's no account and no server of ours. Where it does "
                + "its thinking is your choice — that's the next screen."
        )
    ]
}

// MARK: - What is this?

/// The long answer, in the app.
///
/// Six plain sections, no product names for anything internal, no links out. An
/// owner who clicks "What is this?" is uncertain; handing them a browser tab at
/// that moment is handing them somewhere else to be.
///
/// SAGE is the one name that appears, and it is not an exception to that rule:
/// it is where the owner's *own* agents live, so an owner who has any already
/// knows the word, and an owner who has none is told in the same breath that
/// none of it applies to them.
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
        // Not "a private assistant". The word does no work here: the whole page
        // is an argument for it, and a product that has to assert it up front is
        // a product that cannot demonstrate it. "You decide where its thinking
        // happens", further down, is the demonstration and does not need the
        // adjective's help.
        ExplainerSection(
            id: "what",
            title: "An assistant that lives on this Mac",
            body: "Mynah runs on this computer — the one in front of you. It keeps track of "
                + "what you're working on, answers questions about it, and can hand work to "
                + "other agents you run. There's no website, no account to create, and "
                + "nobody else's machine involved unless you choose one on the next screen."
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
            title: "It remembers, and you can ask it things",
            body: "Over time Mynah builds up a picture of what matters to you — how you "
                + "like things done, who's who, what you're working on — and brings it "
                + "back when it's useful. Ask it about any of it later and it answers from "
                + "what you told it. If a question needs something you never told it, it "
                + "can search the web and use what it finds. Everything it remembers is "
                + "listed in the app, and you can delete any of it."
        ),
        // The half of the product that nothing used to admit. The tools are
        // wired and in the model's allowlist; an owner who never heard of them
        // used this as an assistant with a good memory and never found the rest.
        ExplainerSection(
            id: "agents",
            title: "It can put your other agents to work",
            body: "If you run other agents on SAGE, Mynah can find one by name, send it "
                + "something to do, and tell you what came back. Ask it to pass a question "
                + "to your research agent and it will. If you don't run any, nothing about "
                + "this changes how Mynah works."
        ),
        ExplainerSection(
            id: "where",
            title: "You decide where its thinking happens",
            body: "On the next screen you pick what does Mynah's thinking. One choice "
                + "keeps everything you say on this Mac. The others send what you say to "
                + "a company such as Google or Anthropic, which is usually faster and "
                + "sometimes free. Whichever you pick, you can change it later."
        ),
        // No figure. "Twenty seconds is normal" was measured against a local
        // model on a Mac mini and was removed from the Ready stage and the empty
        // state for being untrue of an API brain answering in three to nine
        // seconds. This was the last place still promising it. A number in an
        // interface is a promise that goes stale the moment the owner changes
        // their brain — which the previous screen invites them to do.
        ExplainerSection(
            id: "time",
            title: "It thinks before it answers",
            body: "Mynah thinks before it speaks, and looks through what it remembers "
                + "first. A brain running on this Mac takes noticeably longer than one you "
                + "reach over the internet. Either way, nothing has gone wrong while you're "
                + "waiting."
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
