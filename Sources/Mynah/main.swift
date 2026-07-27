import MynahMac

// The whole executable. Everything it runs lives in the MynahMac library.
//
// The split is not architectural taste — it is the fix for how a broken app
// shipped. `MynahMac` used to be an executable target, and nothing can import
// an executable, so it had zero tests. That is why `BrainSetupPlanner` could
// emit seven backend identifiers while `BrainFactory` handled four, and why the
// brain the app recommended with a sparkle on it threw on the owner's first
// question. The one test that should have caught it was checking the CLI's
// vocabulary instead, because the planner's was out of reach.
//
// A library target can be imported by `SageVoiceCoreTests`, so the drift that
// shipped is now expressible as an assertion.
MynahApp.main()
